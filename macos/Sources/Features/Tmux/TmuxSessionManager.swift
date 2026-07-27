import AppKit
import GhosttyKit

/// Routes tmux control mode events (posted by Ghostty.App from the
/// GHOSTTY_ACTION_TMUX action) to per-session controllers, keyed by
/// the host surface running `tmux -CC`.
final class TmuxSessionManager {
    static let shared = TmuxSessionManager()

    private var sessions: [ObjectIdentifier: TmuxSessionController] = [:]

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onTmuxEvent(_:)),
            name: Ghostty.Notification.ghosttyTmux,
            object: nil)
    }

    @objc private func onTmuxEvent(_ notification: Notification) {
        guard let host = notification.object as? Ghostty.SurfaceView,
              let event = notification.userInfo?[Ghostty.Notification.TmuxEventKey]
                as? Ghostty.TmuxEvent
        else { return }
        let key = ObjectIdentifier(host)

        switch event {
        case .attach(let router):
            guard sessions[key] == nil else {
                // Duplicate attach for a live session: we own the new
                // reference, give it back.
                ghostty_tmux_router_release(router)
                return
            }
            guard let appDelegate = NSApp.delegate as? AppDelegate else {
                ghostty_tmux_router_release(router)
                return
            }
            sessions[key] = TmuxSessionController(
                ghostty: appDelegate.ghostty,
                host: host,
                router: router)

        case .windows(let windows):
            sessions[key]?.apply(windows)

        case .exit:
            sessions[key]?.teardown()
            sessions[key] = nil
        }
    }
}
