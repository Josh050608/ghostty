import AppKit
import GhosttyKit

/// A TerminalController for one tmux window (= one native tab in the
/// session's dedicated window group). Wraps a pre-built SplitTree of
/// pane surfaces that were constructed by TmuxSessionController.
class TmuxTerminalController: TerminalController {
    private(set) weak var session: TmuxSessionController?
    private(set) var tmuxWindowId: UInt = 0
    private var forceClosing = false
    private var pendingResize: DispatchWorkItem?

    convenience init(
        _ ghostty: Ghostty.App,
        session: TmuxSessionController,
        tmuxWindowId: UInt,
        tree: SplitTree<Ghostty.SurfaceView>
    ) {
        self.init(ghostty, withBaseConfig: nil, withSurfaceTree: tree, parent: nil)
        self.session = session
        self.tmuxWindowId = tmuxWindowId
    }

    /// Update window state from a new tmux windows event.
    /// Rebuilds the split tree when the layout signature changes; SurfaceViews
    /// are reused by pane id (via session.makeTree) so content never flashes.
    func tmuxUpdate(
        window w: Ghostty.TmuxWindow,
        nodes: [Ghostty.TmuxNode],
        preserveFocus: Bool = true
    ) {
        if titleOverride != w.name { titleOverride = w.name }

        guard let session,
              let layout = TmuxSplitLayout.build(nodes: nodes, root: w.root)
        else { return }

        // Skip rebuild when pane structure and ratios are unchanged.
        if treeSignature(surfaceTree) == layout.signature() { return }

        guard let newTree = session.makeTree(layout) else { return }

        // Preserve focus on the same pane if it still exists in the new tree;
        // otherwise fall back to the first leaf.
        let keepFocus: Ghostty.SurfaceView?
        if preserveFocus, let fs = focusedSurface, newTree.contains(fs) {
            keepFocus = fs
        } else if preserveFocus {
            keepFocus = newTree.root?.leftmostLeaf()
        } else {
            keepFocus = nil
        }

        // tmux is authoritative; layout rebuilds must not enter the undo stack.
        undoManager?.disableUndoRegistration()
        defer { undoManager?.enableUndoRegistration() }
        replaceSurfaceTree(
            newTree,
            moveFocusTo: keepFocus,
            moveFocusFrom: focusedSurface,
            undoAction: nil)

        // After each layout update (including the first), align the tmux
        // client size with the current native window bounds so the grid
        // stays in sync even before the user resizes the window.
        scheduleTmuxResize()
    }

    /// Close this window bypassing tmux command mapping and confirmations
    /// (used during session teardown or after tmux itself removed the window).
    func tmuxForceClose() {
        forceClosing = true
        // Cancel any pending resize work item so we don't extend the controller's
        // lifetime unnecessarily after the window has been force-closed.
        pendingResize?.cancel()
        pendingResize = nil
        window?.close()
    }

    // MARK: - Close mapping → tmux commands

    /// Confirms a destructive tmux close (kill-window / kill-pane).
    /// tmux panes have no local process, so needsConfirmQuit can never
    /// detect a running program in them; because a kill is irreversible
    /// we always confirm unless the caller explicitly opted out.
    private func confirmTmux(
        required: Bool,
        informativeText: String,
        onConfirm: @escaping () -> Void
    ) {
        guard required else {
            onConfirm()
            return
        }
        confirmClose(
            messageText: "Close Terminal?",
            informativeText: informativeText
        ) {
            onConfirm()
        }
    }

    /// Tab close (⌘W / tab close button) → kill-window.
    /// The tab disappears when tmux confirms via the next windows event.
    @IBAction override func closeTab(_ sender: Any?) {
        guard !forceClosing, let session, !session.isTearingDown else {
            super.closeTab(sender)
            return
        }
        confirmTmux(
            required: true,
            informativeText: "This will kill the tmux window and any processes running in it. Close the window with the red button instead to detach and keep the session alive."
        ) { [weak self] in
            guard let self, let session = self.session else { return }
            session.send(.killWindow(windowId: UInt(self.tmuxWindowId)))
        }
    }

    /// Window close (red button / ⌘⇧W) → detach-client.
    /// The tmux session survives (detached) and %exit tears down every tab.
    /// No confirmation — detach is non-destructive; the session is preserved.
    @IBAction override func closeWindow(_ sender: Any?) {
        guard !forceClosing, let session, !session.isTearingDown else {
            super.closeWindow(sender)
            return
        }
        session.send(.detach)
    }

    /// Split pane close → kill-pane.
    /// Intercepted here only when a non-root node is being closed (split pane).
    /// Root-node close is routed by TerminalController.closeSurface to closeTab/closeWindow
    /// which are already overridden above.
    override func closeSurface(
        _ node: SplitTree<Ghostty.SurfaceView>.Node,
        withConfirmation: Bool = true
    ) {
        // Let the teardown / force-close path fall through to super.
        guard !forceClosing, let session, !session.isTearingDown else {
            super.closeSurface(node, withConfirmation: withConfirmation)
            return
        }

        // Root-node closures are routed by TerminalController.closeSurface to
        // closeTab or closeWindow (both already overridden), so let super handle them.
        if surfaceTree.root == node {
            super.closeSurface(node, withConfirmation: withConfirmation)
            return
        }

        // Non-root: this is a split pane. Find the pane id and kill-pane.
        // We need one representative pane id to send to tmux. Use the leftmost leaf view.
        let leafView = node.leftmostLeaf()
        guard let paneId = session.paneId(of: leafView) else {
            // Pane not mapped — fall back to super (may happen if the pane was
            // already removed by tmux before the gesture arrived).
            super.closeSurface(node, withConfirmation: withConfirmation)
            return
        }

        confirmTmux(
            required: withConfirmation,
            informativeText: "This will kill the tmux pane and any processes running in it."
        ) { [weak self] in
            self?.session?.send(.killPane(paneId: paneId))
        }
    }

    // MARK: - Batch close → kill-window

    /// "Close Other Tabs" / "Close Tabs to the Right" caught this tab: map it
    /// to a batched kill-window instead of the default local close (see
    /// TmuxBatchClose). Torn down or force-closing tabs are closed locally on
    /// purpose, so they report `.local` like an ordinary tab.
    override var batchCloseDisposition: BatchCloseDisposition {
        guard isTmuxManaged, let session else { return .local }
        return .tmuxKill(session: session, windowId: UInt(tmuxWindowId))
    }

    /// Drop ourselves from the session's window table once our window is gone.
    /// A stale entry makes `anyLiveWindow` hand a closed window to the next
    /// `addWindow`, which tabs the new window onto a dead one and drags it back
    /// on screen as a ghost, splitting the session across two native windows.
    /// Identity-checked so a re-created controller for the same id is kept.
    override func windowWillClose(_ notification: Notification) {
        session?.forget(windowId: tmuxWindowId, controller: self)
        super.windowWillClose(notification)
    }

    // MARK: - Tmux ownership

    /// tmux owns this tab until the session tears down or we force-close it;
    /// both of those paths close the window locally on purpose.
    var isTmuxManaged: Bool {
        guard !forceClosing, let session else { return false }
        return !session.isTearingDown
    }

    // MARK: - Focus → select-pane

    /// Override syncFocusToSurfaceTree (called from focusedSurface.didSet in Base)
    /// to fire a select-pane command whenever the focused pane changes.
    ///
    /// We use this hook rather than overriding the stored property focusedSurface
    /// itself because Swift does not allow adding a didSet observer to an inherited
    /// stored property in a subclass — only computed-property overrides are allowed,
    /// and those would lose the base's own didSet logic. Overriding this method gives
    /// us a clean, guaranteed call-site that fires on every focus change including
    /// window-activation events.
    override func syncFocusToSurfaceTree() {
        super.syncFocusToSurfaceTree()

        // Only send select-pane when the window actually gained key status;
        // skip when this hook fires because the window just resigned key.
        guard window?.isKeyWindow == true else { return }

        guard !forceClosing,
              let session, !session.isTearingDown,
              let view = focusedSurface,
              let paneId = session.paneId(of: view)
        else { return }

        // Echo suppression by value, not by timing: if this (window, pane)
        // pair is one that TmuxSessionController.applyFocus is still
        // expecting to see reflected back from the native UI — either the
        // literal target it asked for, or a same-window wildcard when
        // tmux didn't name a pane, or a pre-registered stale value from a
        // tab switch racing Ghostty.moveFocus — this firing is that change
        // landing rather than a genuine user-driven one, so it's swallowed
        // instead of being sent back to tmux. See TmuxFocusEchoFilter's
        // doc comment for why this has to be a value comparison against a
        // small set rather than a single "focus operation in flight" flag.
        if session.consumeIfEcho((windowId: tmuxWindowId, paneId: paneId)) { return }

        // select-pane alone does not switch tmux's current window;
        // send select-window first so tmux-side focus fully follows.
        session.send(.selectWindow(windowId: UInt(tmuxWindowId)))
        session.send(.selectPane(paneId: paneId))
    }

    // MARK: - Native window resize → tmux client size

    /// Called by the window delegate machinery (Base already calls super chain).
    override func windowDidResize(_ notification: Notification) {
        super.windowDidResize(notification)
        scheduleTmuxResize()
    }

    private func scheduleTmuxResize() {
        pendingResize?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.sendTmuxResize() }
        pendingResize = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    /// Translate the usable content area to a tmux client grid.
    /// Cell metrics come from any live pane surface (font is uniform across
    /// all panes); tmux drives per-pane dimensions via the layout it sends back.
    ///
    /// We use `window.contentLayoutRect` (in points) rather than
    /// `contentView.bounds` to get the area that excludes the titlebar.
    /// For a standard window `contentLayoutRect` stops below the titlebar.
    /// For `HiddenTitlebarTerminalWindow` (window-decorations=false,
    /// styleMask includes .fullSizeContentView) the class overrides
    /// `contentLayoutRect` to return the full frame height (lines 100-104 of
    /// HiddenTitlebarTerminalWindow.swift), so both window styles produce the
    /// correct usable rect without any special-casing here.
    private func sendTmuxResize() {
        guard !forceClosing,
              let session, !session.isTearingDown,
              let window,
              let anyPane = surfaceTree.first(where: { $0.surface != nil }),
              let surface = anyPane.surface
        else { return }

        let size = ghostty_surface_size(surface)
        guard size.cell_width_px > 0, size.cell_height_px > 0 else { return }
        let scale = window.backingScaleFactor
        let layoutRect = window.contentLayoutRect
        let cols = Int((layoutRect.width * scale) / CGFloat(size.cell_width_px))
        let rows = Int((layoutRect.height * scale) / CGFloat(size.cell_height_px))
        session.sendResize(cols: cols, rows: rows)
    }

    // MARK: - Reverse create (plan 3)

    /// ⌘T / File>New Tab / tab-bar "+" on a tmux tab creates a real tmux
    /// window. The new native tab materializes from the window-add /
    /// layout-change resync; focus follows via reverse focus (%session-
    /// window-changed). No local tab is ever created for a live session.
    override func requestNewTab(withBaseConfig config: Ghostty.SurfaceConfiguration? = nil) {
        guard isTmuxManaged, let session else {
            super.requestNewTab(withBaseConfig: config)
            return
        }
        session.send(.newWindow)
    }

    /// Split gestures on a tmux pane become split-window commands; the
    /// new pane materializes from the layout-change resync. Returns nil:
    /// no local SurfaceView is created.
    override func newSplit(
        at oldView: Ghostty.SurfaceView,
        direction: SplitTree<Ghostty.SurfaceView>.NewDirection,
        baseConfig config: Ghostty.SurfaceConfiguration? = nil
    ) -> Ghostty.SurfaceView? {
        guard isTmuxManaged, let session else {
            return super.newSplit(at: oldView, direction: direction, baseConfig: config)
        }
        guard let paneId = session.paneId(of: oldView) else { return nil }
        session.send(.split(paneId: paneId, direction: direction))
        return nil
    }

    // MARK: - Rename → rename-window

    /// GUI rename on a tmux tab becomes rename-window; the native title
    /// updates when tmux echoes %window-renamed (no optimistic local set).
    ///
    /// A non-empty title maps to rename-window (which, as tmux's standard
    /// behavior, also turns automatic-rename OFF for that window — expected
    /// and left alone). nil/empty maps to restoring automatic-rename instead
    /// of rename-window "": tmux would still turn automatic-rename off and
    /// echo back an empty name, permanently blanking the tab with no GUI
    /// path to re-enable it. Restoring automatic-rename instead lets tmux
    /// regenerate the name itself and echo %window-renamed, so the dialog's
    /// "leave blank to restore the default" text is actually true.
    override func userDidSetTitleOverride(_ title: String?) {
        guard isTmuxManaged, let session else {
            super.userDidSetTitleOverride(title)
            return
        }
        if let title, !title.isEmpty {
            session.send(.renameWindow(windowId: UInt(tmuxWindowId), name: title))
        } else {
            session.send(.restoreAutomaticRename(windowId: UInt(tmuxWindowId)))
        }
    }

    // MARK: - Signature helpers

    /// Produces a canonical string signature for the current SplitTree by
    /// looking up each leaf view's pane id via the session cache. Leaves
    /// whose pane id is unknown (not in session.panes) get "p?" which
    /// guarantees inequality against any valid layout signature and forces
    /// a rebuild when the mapping is stale.
    private func treeSignature(_ t: SplitTree<Ghostty.SurfaceView>) -> String {
        // Empty tree returns "" which never matches a layout signature, so a
        // rebuild is always forced — the safe direction.
        guard let root = t.root else { return "" }
        return nodeSignature(root)
    }

    private func nodeSignature(_ node: SplitTree<Ghostty.SurfaceView>.Node) -> String {
        switch node {
        case .leaf(let view):
            if let paneId = session?.paneId(of: view) {
                return "p\(paneId)"
            }
            return "p?"
        case .split(let split):
            let dir = split.direction == .horizontal ? "h" : "v"
            return "\(dir)[\(String(format: "%.3f", split.ratio)):\(nodeSignature(split.left)),\(nodeSignature(split.right))]"
        }
    }
}
