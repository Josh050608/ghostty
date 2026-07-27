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
    /// Layout rebuilding (Task 9) is deferred; for now we just keep the title fresh.
    func tmuxUpdate(window: Ghostty.TmuxWindow, nodes: [Ghostty.TmuxNode]) {
        // Task 9 will rebuild the split tree here.
        titleOverride = window.name
    }

    /// Close this window bypassing tmux command mapping and confirmations
    /// (used during session teardown or after tmux itself removed the window).
    func tmuxForceClose() {
        forceClosing = true
        window?.close()
    }
}
