import AppKit
import GhosttyKit

/// Owns the native UI for one `tmux -CC` session: a dedicated window
/// group where each tmux window is a native tab and each pane a native
/// split. The controller is the subordinate side of the sync: tmux
/// state (delivered as windows events) is authoritative, and native
/// close/focus/resize gestures are translated into tmux commands whose
/// effects come back as new windows events.
final class TmuxSessionController {
    let ghostty: Ghostty.App
    private(set) weak var hostView: Ghostty.SurfaceView?
    private(set) var router: UnsafeMutableRawPointer?
    private(set) var isTearingDown = false

    /// Tracks tmux-driven focus values we still expect to see echoed back
    /// from the native UI, so TmuxTerminalController.syncFocusToSurfaceTree
    /// (via consumeIfEcho) can recognize and swallow them instead of
    /// re-sending select-window/select-pane to tmux (loop suppression).
    /// See TmuxFocusEchoFilter's doc comment for why this has to be a set
    /// of values rather than a single one, and why it's a pure value
    /// comparison rather than a "focus operation in flight" timing flag.
    private var focusEchoFilter = TmuxFocusEchoFilter()

    /// A tmux focus request we could not fully honor when it arrived,
    /// kept verbatim so the next windows resync can replay it in full.
    /// See `deferredFocus` for exactly when a request is deferred.
    struct PendingFocus: Equatable {
        let windowId: UInt
        /// Preserved: replaying window-only would re-focus whichever pane
        /// the tab happens to have, which is precisely the pane tmux is
        /// moving *away* from in the split case.
        let paneId: UInt?
    }

    /// Focus notification that arrived before the UI it names existed
    /// (e.g. %session-window-changed racing the window-add resync, or
    /// %window-pane-changed racing the %layout-change for a new pane).
    private var pendingFocus: PendingFocus?

    /// tmux window id -> native tab controller.
    var windows: [UInt: TmuxTerminalController] = [:]
    /// tmux pane id -> its surface view. Panes are create-once: a pane
    /// id never comes back after its surface is gone (detached is a
    /// terminal state core-side and tmux never reuses ids).
    var panes: [UInt: Ghostty.SurfaceView] = [:]

    /// Each session gets its own tabbingIdentifier so its tabs are
    /// isolated from ordinary terminal windows and from other sessions.
    private let tabbingId = "com.mitchellh.ghostty.tmux." + UUID().uuidString

    init(
        ghostty: Ghostty.App,
        host: Ghostty.SurfaceView,
        router: UnsafeMutableRawPointer
    ) {
        self.ghostty = ghostty
        self.hostView = host
        self.router = router
        Ghostty.logger.info("tmux session attached")
    }

    // MARK: - Windows diff

    func apply(_ ev: Ghostty.TmuxWindows) {
        guard !isTearingDown else { return }
        let incoming = Dictionary(uniqueKeysWithValues: ev.windows.map { ($0.id, $0) })

        // tmux removed these windows: close their tabs without
        // commands or confirmation (tmux already acted).
        for (id, controller) in windows where incoming[id] == nil {
            windows[id] = nil
            controller.tmuxForceClose()
        }

        // Added or kept windows, in tmux order.
        for w in ev.windows {
            if let existing = windows[w.id] {
                existing.tmuxUpdate(
                    window: w,
                    nodes: ev.nodes,
                    preserveFocus: Self.shouldPreserveFocus(
                        pending: pendingFocus,
                        updatingWindowId: w.id)) // Task 9
            } else {
                addWindow(w, nodes: ev.nodes)
            }
        }

        prunePanes(keeping: ev)

        // A focus notification may have raced the resync that materialized
        // the window or the pane it names; replay it — in full, pane id
        // included — now that this resync has built both. Deliberately last:
        // the tree replacements above are what create the pane surfaces this
        // replay needs to find. applyFocus re-stashes if it still can't act,
        // so a request whose pane never shows up just retries harmlessly
        // (by then the tab is already selected, so the retry is a no-op).
        if let pending = pendingFocus, windows[pending.windowId] != nil {
            applyFocus(windowId: pending.windowId, paneId: pending.paneId)
        }
    }

    private func addWindow(_ w: Ghostty.TmuxWindow, nodes: [Ghostty.TmuxNode]) {
        guard let layout = TmuxSplitLayout.build(nodes: nodes, root: w.root),
              let tree = makeTree(layout)
        else {
            Ghostty.logger.warning("tmux window \(w.id) layout invalid, skipped")
            return
        }

        let controller = TmuxTerminalController(
            ghostty,
            session: self,
            tmuxWindowId: w.id,
            tree: tree)
        controller.titleOverride = w.name
        windows[w.id] = controller

        // Force the window to load (via NIB) before we configure it.
        // TerminalController.window is loaded lazily on first access,
        // just like the newTab static does before calling showWindow.
        guard let window = controller.window else {
            Ghostty.logger.warning("tmux window \(w.id): window failed to load, skipped")
            return
        }

        window.isRestorable = false
        window.tabbingIdentifier = tabbingId

        // If another live tmux window exists for this session, join its
        // tab group. Prefer the last window in the tab group (matches
        // newTab "end" position behavior). The new controller is already
        // in `windows`, so we must exclude our own window or an unlucky
        // dictionary order makes us pick ourselves and skip grouping.
        if let groupWindow = anyLiveWindow(excluding: window) {
            if let lastInGroup = groupWindow.tabGroup?.windows.last {
                lastInGroup.addTabbedWindowSafely(window, ordered: .above)
            } else {
                groupWindow.addTabbedWindowSafely(window, ordered: .above)
            }
        }

        controller.showWindow(nil)
    }

    private func anyLiveWindow(excluding excluded: NSWindow? = nil) -> NSWindow? {
        windows.values.compactMap(\.window).first { $0 !== excluded }
    }

    /// Forget a tab whose window closed without tmux asking for it. Keeping the
    /// entry would let `anyLiveWindow` anchor the next tab onto a dead window.
    /// Identity-checked: a controller re-created for the same id must survive.
    func forget(windowId: UInt, controller: TmuxTerminalController) {
        guard windows[windowId] === controller else { return }
        windows[windowId] = nil
        // A dead window's controller will never call syncFocusToSurfaceTree
        // again, so any echo we were still expecting for it can never be
        // legitimately consumed — drop it rather than leave it dangling.
        focusEchoFilter.forget(windowId: windowId)
        // Same reasoning for a deferred focus request aimed at this window:
        // there is nothing left to replay it onto.
        if pendingFocus?.windowId == windowId { pendingFocus = nil }
    }

    /// Drop cached panes that no longer appear in any window's layout.
    /// Their views were already released by the tree replacements; the
    /// core marks them detached when the surface unregisters.
    private func prunePanes(keeping ev: Ghostty.TmuxWindows) {
        var live = Set<UInt>()
        for node in ev.nodes where node.kind == .pane { live.insert(node.paneId) }
        panes = panes.filter { live.contains($0.key) }
    }

    // MARK: - Focus (reverse: tmux -> native)

    /// Apply a tmux-side focus change (from %window-pane-changed /
    /// %session-window-changed) to the native UI.
    ///
    /// A focus notification can reference an id we don't recognize *yet* —
    /// Task 4's viewer intentionally does not filter unknown ids, because
    /// tmux announces the new focus before it announces the structure that
    /// contains it. Both shapes of that race are deferred rather than
    /// dropped, and replayed by `apply(_:)`:
    ///  1. Unknown window id: `windows[windowId]` fails. %session-window-changed
    ///     for a ⌘T-created window arrives before the window-add resync that
    ///     materializes it.
    ///  2. Known window, unresolvable pane id: `panes[paneId]` is missing, or
    ///     the view exists but isn't in *this* window's current split tree.
    ///     This is the deterministic split case: `split-window` makes tmux emit
    ///     %window-pane-changed(@W, %new) *before* the %layout-change that
    ///     creates %new's surface. Dropping it here left focus on the old pane
    ///     and — worse — let the subsequent windows resync push the *stale*
    ///     pane back to tmux via replaceSurfaceTree/syncFocusToSurfaceTree,
    ///     overriding the active-pane choice tmux had just made.
    ///
    /// A deferred request still switches the native tab immediately when it
    /// can; only the pane move waits. See `deferredFocus` for the decision.
    func applyFocus(windowId: UInt, paneId: UInt?) {
        guard !isTearingDown else { return }
        guard let controller = windows[windowId], let window = controller.window else {
            pendingFocus = Self.deferredFocus(
                windowId: windowId,
                paneId: paneId,
                windowExists: false,
                canMoveFocus: false)
            return
        }

        // Decide what will actually happen before registering any expected
        // echoes below — mirrors the guards used further down verbatim, so
        // "will an operation run" and "did an operation run" can never
        // disagree.
        let willSwitchTab = window.tabGroup.map { $0.selectedWindow !== window } ?? false
        let moveFocusTarget: Ghostty.SurfaceView? = paneId.flatMap { pid in
            guard let view = panes[pid], controller.surfaceTree.contains(view) else { return nil }
            return view
        }
        let willMoveFocus = moveFocusTarget != nil

        pendingFocus = Self.deferredFocus(
            windowId: windowId,
            paneId: paneId,
            windowExists: true,
            canMoveFocus: willMoveFocus)

        // What to expect is a pure decision given the above — see
        // TmuxFocusEchoFilter.expectedEntries for why a no-op registers
        // nothing and the stale-pane entry only applies when a tab switch
        // is actually about to happen.
        focusEchoFilter.register(TmuxFocusEchoFilter.expectedEntries(
            windowId: windowId,
            paneId: paneId,
            willSwitchTab: willSwitchTab,
            willMoveFocus: willMoveFocus,
            currentPaneId: controller.focusedSurface.flatMap { self.paneId(of: $0) }
        ))

        // Select the native tab without stealing key from another app.
        if willSwitchTab, let tabGroup = window.tabGroup {
            tabGroup.selectedWindow = window
        }

        // Focus the pane's surface when we know it and it is actually part
        // of this window's current split tree (defense #2 above).
        if let moveFocusTarget {
            Ghostty.moveFocus(to: moveFocusTarget)
        }
    }

    /// Decides what `applyFocus` must stash for a later replay, given what
    /// it has already determined it can actually do to the native UI right
    /// now.
    ///
    /// Pure and independent of AppKit/`TmuxSessionController` for the same
    /// reason `TmuxFocusEchoFilter.expectedEntries` is: this decision was
    /// wrong in two ways before, and both are asserted directly here rather
    /// than needing a real `NSWindow`/`NSTabGroup` — a request whose window
    /// was missing kept only the window id (so the replay re-focused
    /// whatever pane that tab already had), and a request whose *pane* was
    /// missing was dropped outright instead of deferred.
    ///
    /// - Parameters:
    ///   - windowExists: the request's window has a materialized tab.
    ///   - canMoveFocus: the request's pane resolved to a surface that is
    ///     part of that window's current split tree.
    /// - Returns: the request to replay on the next windows resync, or nil
    ///   if it was fully honored.
    static func deferredFocus(
        windowId: UInt,
        paneId: UInt?,
        windowExists: Bool,
        canMoveFocus: Bool
    ) -> PendingFocus? {
        // No tab yet: none of the request can be honored.
        guard windowExists else {
            return .init(windowId: windowId, paneId: paneId)
        }

        // The tab exists and the request names a pane we cannot act on yet.
        // The tab switch happens now; the pane move waits for the layout
        // that materializes the pane. Keeping the pane id is the whole
        // point — replaying window-only would land on the stale pane.
        if paneId != nil, !canMoveFocus {
            return .init(windowId: windowId, paneId: paneId)
        }

        // Fully honored (or window-only request, which has nothing to wait
        // for): stop deferring, so a later unrelated resync can't replay it.
        return nil
    }

    /// A tree replacement normally restores the pane that was focused before
    /// the layout changed. Do not schedule that stale restore when tmux has
    /// already announced a different active pane for this window: `apply(_:)`
    /// replays the pending request after the new pane surface is in the tree.
    /// Scheduling both asynchronous moves lets the old restore win the race.
    static func shouldPreserveFocus(
        pending: PendingFocus?,
        updatingWindowId: UInt
    ) -> Bool {
        pending?.windowId != updatingWindowId
    }

    /// Checks whether `candidate` (the (window, pane) pair a
    /// syncFocusToSurfaceTree call is about to send to tmux) matches a
    /// focus value we're still expecting to see echoed back from a prior
    /// `applyFocus` and, if so, consumes it — see
    /// `TmuxFocusEchoFilter.consumeIfEcho` for the matching and
    /// consume-once semantics.
    func consumeIfEcho(_ candidate: (windowId: UInt, paneId: UInt?)) -> Bool {
        focusEchoFilter.consumeIfEcho(.init(windowId: candidate.windowId, paneId: candidate.paneId))
    }

    // MARK: - Pane surface factory

    /// Get or create the surface view for a tmux pane. Create-once:
    /// once a pane's surface is gone the id never comes back (tmux
    /// does not reuse ids), so a cache hit is always the live view.
    func surfaceView(forPane id: UInt) -> Ghostty.SurfaceView? {
        if let view = panes[id] { return view }
        guard let app = ghostty.app else { return nil }
        var config = Ghostty.SurfaceConfiguration()
        config.tmuxRouter = router
        config.tmuxPaneId = id
        let view = Ghostty.SurfaceView(app, baseConfig: config)
        panes[id] = view
        return view
    }

    func paneId(of view: Ghostty.SurfaceView) -> UInt? {
        panes.first(where: { $0.value === view })?.key
    }

    // MARK: - Tree construction

    func makeTree(_ layout: TmuxSplitLayout) -> SplitTree<Ghostty.SurfaceView>? {
        guard let node = makeNode(layout) else { return nil }
        return SplitTree(root: node, zoomed: nil)
    }

    private func makeNode(_ layout: TmuxSplitLayout) -> SplitTree<Ghostty.SurfaceView>.Node? {
        switch layout {
        case .pane(let id):
            guard let view = surfaceView(forPane: id) else { return nil }
            return .leaf(view: view)
        case .split(let direction, let ratio, let left, let right):
            guard let l = makeNode(left), let r = makeNode(right) else { return nil }
            let splitDir: SplitTree<Ghostty.SurfaceView>.Direction =
                direction == .horizontal ? .horizontal : .vertical
            return .split(.init(
                direction: splitDir,
                ratio: ratio,
                left: l,
                right: r))
        }
    }

    // MARK: - Session lifecycle

    /// End of session (%exit or host death): close every native window
    /// without emitting tmux commands, then drop our router reference.
    func teardown() {
        guard !isTearingDown else { return }
        isTearingDown = true
        for (_, controller) in windows { controller.tmuxForceClose() }
        windows.removeAll()
        panes.removeAll()
        pendingFocus = nil
        focusEchoFilter.clear()
        releaseRouter()
        Ghostty.logger.info("tmux session ended")
    }

    func send(_ cmd: TmuxCommand) {
        guard let router else { return }
        cmd.withCValue { ghostty_tmux_router_command(router, $0) }
    }

    // MARK: - Resize deduplication

    private var lastResize: (cols: Int, rows: Int)? = nil

    /// Send refresh-client -C, deduplicating repeats: every tab shares
    /// the same client size, so tab switches and duplicate resize events
    /// would otherwise spam tmux.
    func sendResize(cols: Int, rows: Int) {
        guard !isTearingDown, cols > 1, rows > 1 else { return }
        if let last = lastResize, last == (cols, rows) { return }
        lastResize = (cols, rows)
        send(.resize(cols: UInt(cols), rows: UInt(rows)))
    }

    private func releaseRouter() {
        guard let router else { return }
        ghostty_tmux_router_release(router)
        self.router = nil
    }

    deinit {
        releaseRouter()
    }
}
