import AppKit

/// Implemented by window controllers whose window is a tab of a live tmux
/// session. tmux is authoritative for those tabs.
protocol TmuxManagedWindow: AnyObject {
    /// True while the tab is backed by a live tmux session. False once the
    /// session is tearing down or the tab is force-closing, because those
    /// paths close the window locally on purpose.
    var isTmuxManaged: Bool { get }
}

extension NSWindow {
    /// True when this window is a tab of a live tmux session.
    var isTmuxManaged: Bool {
        (windowController as? TmuxManagedWindow)?.isTmuxManaged ?? false
    }
}

enum TmuxTabGuard {
    /// True when a tab group holds any live tmux tab, which makes the batch
    /// close actions ("Close Other Tabs", "Close Tabs to the Right") unsafe.
    ///
    /// Those actions close their victims with `closeTabImmediately`, i.e. a
    /// bare `window.close()` that sends tmux nothing, so a tmux tab caught in
    /// the sweep would vanish from the GUI while its window lives on in the
    /// server. Guarding the acting controller is not enough: an ordinary tab
    /// can share a group with tmux tabs (a session's first window joins the
    /// frontmost window's tab group, and ⌘T inside a tmux tab adds a local
    /// one), and the sweep runs over every tab in the group regardless of who
    /// started it. Mapping the sweep onto batched kill-window commands is a
    /// feature gap we accept for now; diverging from tmux is not.
    static func blocksBatchClose(_ windows: [NSWindow]) -> Bool {
        windows.contains(where: \.isTmuxManaged)
    }
}
