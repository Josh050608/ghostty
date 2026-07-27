import AppKit
import GhosttyKit

/// A TerminalController for one tmux window (= one native tab in the
/// session's dedicated window group). Wraps a pre-built SplitTree of
/// pane surfaces that were constructed by TmuxSessionController.
class TmuxTerminalController: TerminalController {
    private(set) weak var session: TmuxSessionController?
    private(set) var tmuxWindowId: UInt = 0
    private var forceClosing = false

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

        replaceSurfaceTree(
            newTree,
            moveFocusTo: keepFocus,
            moveFocusFrom: focusedSurface,
            undoAction: nil)
    }

    /// Close this window bypassing tmux command mapping and confirmations
    /// (used during session teardown or after tmux itself removed the window).
    func tmuxForceClose() {
        forceClosing = true
        window?.close()
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

    // MARK: - Signature helpers

    /// Produces a canonical string signature for the current SplitTree by
    /// looking up each leaf view's pane id via the session cache. Leaves
    /// whose pane id is unknown (not in session.panes) get "p?" which
    /// guarantees inequality against any valid layout signature and forces
    /// a rebuild when the mapping is stale.
    private func treeSignature(_ t: SplitTree<Ghostty.SurfaceView>) -> String {
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
