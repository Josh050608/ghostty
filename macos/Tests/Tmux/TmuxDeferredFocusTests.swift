import Testing
@testable import Ghostty

/// Covers `TmuxSessionController.deferredFocus`, the decision that keeps a
/// tmux focus notification alive when it names UI that tmux has announced
/// but not yet described.
///
/// The interesting case is deterministic and was previously dropped on the
/// floor: `split-window` makes tmux emit %window-pane-changed(@W, %new)
/// *before* the %layout-change that creates %new. Focus therefore stayed on
/// the old pane, and the windows resync that followed then pushed that stale
/// pane back to tmux as a select-pane, overriding tmux's own choice.
@Suite struct TmuxDeferredFocusTests {
    typealias Pending = TmuxSessionController.PendingFocus

    @Test func unknownWindowDefersWholeRequest() {
        // %session-window-changed for a ⌘T-created window, racing the
        // window-add resync. The pane id must survive the round trip:
        // replaying window-only would re-focus whatever pane that tab
        // already had.
        let pending = TmuxSessionController.deferredFocus(
            windowId: 9,
            paneId: 4,
            windowExists: false,
            canMoveFocus: false)
        #expect(pending == Pending(windowId: 9, paneId: 4))
    }

    @Test func unknownWindowWithoutPaneDefersWindowOnly() {
        let pending = TmuxSessionController.deferredFocus(
            windowId: 9,
            paneId: nil,
            windowExists: false,
            canMoveFocus: false)
        #expect(pending == Pending(windowId: 9, paneId: nil))
    }

    @Test func knownWindowUnknownPaneDefersInsteadOfDropping() {
        // The regression: the tab exists, but the pane tmux just focused
        // does not exist yet (or is not in this window's current tree).
        // Before, this returned no pending state at all and the pane move
        // was lost.
        let pending = TmuxSessionController.deferredFocus(
            windowId: 3,
            paneId: 11,
            windowExists: true,
            canMoveFocus: false)
        #expect(pending == Pending(windowId: 3, paneId: 11))
    }

    @Test func fullyAppliedRequestDefersNothing() {
        let pending = TmuxSessionController.deferredFocus(
            windowId: 3,
            paneId: 11,
            windowExists: true,
            canMoveFocus: true)
        #expect(pending == nil)
    }

    @Test func windowOnlyRequestOnKnownWindowDefersNothing() {
        // %session-window-changed names no pane, so there is nothing to
        // wait for once the tab exists. Deferring anyway would leave a
        // request that a later, unrelated resync would replay.
        let pending = TmuxSessionController.deferredFocus(
            windowId: 3,
            paneId: nil,
            windowExists: true,
            canMoveFocus: false)
        #expect(pending == nil)
    }

    @Test func replayOfDeferredSplitRequestIsIdempotentThenClears() {
        // Walks the split timeline the way applyFocus drives it.
        //
        // 1. %window-pane-changed(@7, %12) lands before the layout: the tab
        //    is there, the pane is not.
        var pending = TmuxSessionController.deferredFocus(
            windowId: 7,
            paneId: 12,
            windowExists: true,
            canMoveFocus: false)
        #expect(pending == Pending(windowId: 7, paneId: 12))

        // 2. A resync arrives that still doesn't contain the pane (e.g. an
        //    unrelated window changed). Replaying re-defers the identical
        //    request rather than degrading it to window-only.
        pending = TmuxSessionController.deferredFocus(
            windowId: pending!.windowId,
            paneId: pending!.paneId,
            windowExists: true,
            canMoveFocus: false)
        #expect(pending == Pending(windowId: 7, paneId: 12))

        // 3. The %layout-change resync materializes %12; the replay now
        //    resolves and the deferred request is consumed, so no later
        //    resync can replay it again.
        pending = TmuxSessionController.deferredFocus(
            windowId: pending!.windowId,
            paneId: pending!.paneId,
            windowExists: true,
            canMoveFocus: true)
        #expect(pending == nil)
    }

    @Test func windowThatDisappearsBeforeReplayLeavesRequestUnresolved() {
        // If the window vanishes between defer and replay, the request is
        // still window-shaped rather than silently satisfied — the caller
        // (forget/teardown) is what drops it, not this decision.
        let pending = TmuxSessionController.deferredFocus(
            windowId: 5,
            paneId: 2,
            windowExists: false,
            canMoveFocus: false)
        #expect(pending == Pending(windowId: 5, paneId: 2))
    }
}
