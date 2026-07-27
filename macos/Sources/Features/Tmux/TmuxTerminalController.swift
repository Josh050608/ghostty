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
    func tmuxUpdate(window w: Ghostty.TmuxWindow, nodes: [Ghostty.TmuxNode]) {
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
        if let fs = focusedSurface, newTree.contains(fs) {
            keepFocus = fs
        } else {
            keepFocus = newTree.root?.leftmostLeaf()
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
        window?.close()
    }

    // MARK: - Close mapping → tmux commands

    /// Confirms closure for surfaces that have running processes (needsConfirmQuit).
    /// If `surfaces` is empty the `onConfirm` block is executed immediately.
    /// Otherwise a standard close-confirmation alert is shown; `onConfirm` is only
    /// called if the user chooses to proceed.
    private func confirmTmux(
        surfaces: [Ghostty.SurfaceView],
        onConfirm: @escaping () -> Void
    ) {
        guard !surfaces.isEmpty else {
            onConfirm()
            return
        }
        confirmClose(
            messageText: "Close Terminal?",
            informativeText: "The terminal still has a running process. If you close the terminal the process will be killed."
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
        let needsConfirm = surfaceTree.filter { $0.needsConfirmQuit }
        confirmTmux(surfaces: needsConfirm) { [weak self] in
            guard let self, let session = self.session else { return }
            session.send(ghostty_tmux_command_s(
                tag: GHOSTTY_TMUX_COMMAND_KILL_WINDOW,
                id: UInt(self.tmuxWindowId),
                width: 0,
                height: 0))
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
        session.send(ghostty_tmux_command_s(
            tag: GHOSTTY_TMUX_COMMAND_DETACH,
            id: 0,
            width: 0,
            height: 0))
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
        // We gather all surface views in the node to check needsConfirmQuit.
        let surfaces: [Ghostty.SurfaceView] = Array(node)
        let needsConfirm = withConfirmation ? surfaces.filter { $0.needsConfirmQuit } : []

        // We need one representative pane id to send to tmux. Use the leftmost leaf view.
        let leafView = node.leftmostLeaf()
        guard let paneId = session.paneId(of: leafView) else {
            // Pane not mapped — fall back to super (may happen if the pane was
            // already removed by tmux before the gesture arrived).
            super.closeSurface(node, withConfirmation: withConfirmation)
            return
        }

        confirmTmux(surfaces: needsConfirm) { [weak self] in
            self?.session?.send(ghostty_tmux_command_s(
                tag: GHOSTTY_TMUX_COMMAND_KILL_PANE,
                id: UInt(paneId),
                width: 0,
                height: 0))
        }
    }

    // MARK: - Menu validation

    /// Disable "Close Other Tabs" and "Close Tabs on the Right" for live tmux
    /// sessions. Both actions reach `closeTabImmediately` → `window.close()` on
    /// OTHER tmux tab windows, locally closing them with no tmux command, which
    /// violates the tmux-authoritative invariant. Mapping them to batched
    /// kill-window is deferred; disabled here to preserve correct state.
    /// When torn down or force-closing we defer to super (normal close path).
    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard !forceClosing, let session, !session.isTearingDown else {
            return super.validateMenuItem(item)
        }
        switch item.action {
        case #selector(closeOtherTabs(_:)),
             #selector(closeTabsOnTheRight(_:)):
            return false
        default:
            return super.validateMenuItem(item)
        }
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

        // Fire and forget: tmux state is authoritative and any failure just
        // leaves tmux's active pane behind ours.
        session.send(ghostty_tmux_command_s(
            tag: GHOSTTY_TMUX_COMMAND_SELECT_PANE,
            id: UInt(paneId),
            width: 0,
            height: 0))
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

    /// Translate the content-view pixel bounds to a tmux client grid.
    /// Cell metrics come from any live pane surface (font is uniform across
    /// all panes); tmux drives per-pane dimensions via the layout it sends back.
    private func sendTmuxResize() {
        guard !forceClosing,
              let session, !session.isTearingDown,
              let window,
              let contentView = window.contentView,
              let anyPane = surfaceTree.first(where: { $0.surface != nil }),
              let surface = anyPane.surface
        else { return }

        let size = ghostty_surface_size(surface)
        guard size.cell_width_px > 0, size.cell_height_px > 0 else { return }
        let scale = window.backingScaleFactor
        let cols = Int((contentView.bounds.width * scale) / CGFloat(size.cell_width_px))
        let rows = Int((contentView.bounds.height * scale) / CGFloat(size.cell_height_px))
        session.sendResize(cols: cols, rows: rows)
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
