/// Suppresses tmux-driven focus applications from being echoed back to
/// tmux as select-window/select-pane commands, by tracking the set of
/// native focus values we still expect to observe as a consequence of a
/// call to `TmuxSessionController.applyFocus` and consuming them by value.
///
/// This is deliberately a pure value-comparison filter with zero timing
/// assumptions: `Ghostty.moveFocus` and the SwiftUI `@FocusedValue`
/// plumbing that eventually calls `syncFocusToSurfaceTree` both settle an
/// unknown, unbounded number of run-loop turns after `applyFocus` returns,
/// so nothing about *when* a candidate arrives can be used to decide
/// whether it's an echo. Whether it's an echo is entirely a question of
/// *what value* it carries relative to what we last told the native UI to
/// focus.
///
/// A single remembered value is not enough to cover every echo shape a
/// tmux-driven `applyFocus` can produce, which is why this holds a small
/// set of pending entries rather than one:
///
///  - tmux's own "select this window" notifications
///    (`%session-window-changed`) don't name a pane, so `applyFocus` is
///    called with `paneId == nil`. The eventual native echo always names
///    some concrete pane (whichever surface the window happens to have
///    focused), so an exact-match-only record could never consume it —
///    every plain tmux-side window switch would leak a spurious
///    select-window/select-pane back to tmux. A `paneId == nil` entry is
///    therefore a window-level wildcard: it matches any pane in that
///    window.
///  - When `applyFocus(windowId: W, paneId: P2)` asks to move focus to a
///    *different* pane than the one currently focused in that window
///    (P1), the tab's own `windowDidBecomeKey` (triggered by the
///    `tabGroup.selectedWindow` assignment) can fire and call
///    `syncFocusToSurfaceTree` *before* `Ghostty.moveFocus`'s asynchronous
///    work has actually landed P2 — so that first sync round reports the
///    stale P1 as "currently focused". Left unswallowed this sends
///    select-pane(P1) to tmux, clobbering the very focus tmux just asked
///    for. `applyFocus` pre-registers `(W, P1)` alongside `(W, P2)` so
///    this artifact is recognized and consumed instead of forwarded.
struct TmuxFocusEchoFilter {
    /// A focus value we expect to see echoed back from the native UI as a
    /// consequence of an `applyFocus` call, plus what should happen when
    /// it is observed.
    struct Entry: Equatable {
        let windowId: UInt
        /// nil matches any pane in `windowId` (window-level wildcard, for
        /// tmux notifications that didn't specify a pane).
        let paneId: UInt?
    }

    private(set) var pending: [Entry] = []

    /// Replace all still-pending echoes with a fresh set for a new
    /// tmux-driven focus application.
    ///
    /// This replaces rather than appends: if an earlier `applyFocus` call
    /// registered entries whose echoes never arrived (e.g. a focus
    /// notification was superseded by a newer one before the native UI
    /// settled), carrying them forward risks incorrectly consuming an
    /// unrelated future echo, or masking a genuine user action that
    /// happens to coincide with the stale value.
    ///
    /// This is a real trade-off, not a free lunch: if the superseded
    /// call's echo does eventually arrive after being dropped here, it is
    /// no longer recognized and gets sent to tmux as a real command. That
    /// send is a no-op only if tmux's own state has, by then, already
    /// converged on the newer request; if it hasn't, the send is a stale
    /// but real reselect. This is accepted as the narrower, lower-probability
    /// risk compared to letting discarded entries accumulate indefinitely
    /// and silently swallow unrelated future echoes forever.
    mutating func register(_ entries: [Entry]) {
        pending = entries
    }

    /// Checks whether `candidate` matches a still-pending echo and, if so,
    /// consumes it (removes it from the pending set) and returns true.
    ///
    /// Consumed once, not held indefinitely: if the same value needs to be
    /// swallowed a second time (e.g. `syncFocusToSurfaceTree` legitimately
    /// fires more than once for a single `applyFocus`), the second firing
    /// is treated as a real send. That send is harmless — tmux no-ops a
    /// reselect of a pane/window it already considers active — whereas
    /// holding the entry indefinitely would risk swallowing a later,
    /// genuine user-driven focus change that happens to produce the same
    /// value, leaving tmux's active pane silently out of sync with the
    /// native UI with no future correction.
    mutating func consumeIfEcho(_ candidate: Entry) -> Bool {
        guard let index = pending.firstIndex(where: { entry in
            entry.windowId == candidate.windowId &&
                (entry.paneId == nil || entry.paneId == candidate.paneId)
        }) else { return false }
        pending.remove(at: index)
        return true
    }

    /// Drop any pending echoes for a window that's gone (mirrors
    /// `TmuxSessionController.forget`): a closed window's controller will
    /// never call `syncFocusToSurfaceTree` again, so entries naming it can
    /// never be legitimately consumed and would otherwise sit forever.
    mutating func forget(windowId: UInt) {
        pending.removeAll { $0.windowId == windowId }
    }

    /// Drop everything (session teardown).
    mutating func clear() {
        pending.removeAll()
    }
}
