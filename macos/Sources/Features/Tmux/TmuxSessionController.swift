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
                existing.tmuxUpdate(window: w, nodes: ev.nodes) // Task 9
            } else {
                addWindow(w, nodes: ev.nodes)
            }
        }

        prunePanes(keeping: ev)
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
    }

    /// Drop cached panes that no longer appear in any window's layout.
    /// Their views were already released by the tree replacements; the
    /// core marks them detached when the surface unregisters.
    private func prunePanes(keeping ev: Ghostty.TmuxWindows) {
        var live = Set<UInt>()
        for node in ev.nodes where node.kind == .pane { live.insert(node.paneId) }
        panes = panes.filter { live.contains($0.key) }
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
        releaseRouter()
        Ghostty.logger.info("tmux session ended")
    }

    func send(_ cmd: ghostty_tmux_command_s) {
        guard let router else { return }
        ghostty_tmux_router_command(router, cmd)
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
        send(ghostty_tmux_command_s(
            tag: GHOSTTY_TMUX_COMMAND_RESIZE,
            id: 0,
            width: UInt(cols),
            height: UInt(rows)))
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
