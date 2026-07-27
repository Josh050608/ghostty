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

    /// tmux window id -> native tab controller (Task 8).
    var windows: [UInt: TmuxTerminalController] = [:]
    /// tmux pane id -> its surface view. Panes are create-once: a pane
    /// id never comes back after its surface is gone (detached is a
    /// terminal state core-side and tmux never reuses ids).
    var panes: [UInt: Ghostty.SurfaceView] = [:]

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

    func apply(_ ev: Ghostty.TmuxWindows) {
        guard !isTearingDown else { return }
        // Task 8 implements the diff; log for now.
        Ghostty.logger.info("tmux windows event count=\(ev.windows.count)")
    }

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

    private func releaseRouter() {
        guard let router else { return }
        ghostty_tmux_router_release(router)
        self.router = nil
    }

    deinit {
        releaseRouter()
    }
}

/// A TerminalController for one tmux window (= one native tab in the
/// session's dedicated window group). Task 8+ fill in construction,
/// close mapping and resize.
class TmuxTerminalController: TerminalController {
    weak var session: TmuxSessionController?
    var tmuxWindowId: UInt = 0
    private var forceClosing = false

    /// Close this window bypassing tmux command mapping and
    /// confirmations (used during session teardown or after tmux
    /// itself removed the window).
    func tmuxForceClose() {
        forceClosing = true
        window?.close()
    }
}
