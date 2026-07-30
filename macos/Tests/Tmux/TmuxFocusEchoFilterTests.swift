import Testing
@testable import Ghostty

@Suite struct TmuxFocusEchoFilterTests {
    typealias Entry = TmuxFocusEchoFilter.Entry

    @Test func exactMatchIsConsumedOnce() {
        var filter = TmuxFocusEchoFilter()
        filter.register([Entry(windowId: 1, paneId: 5)])

        #expect(filter.consumeIfEcho(Entry(windowId: 1, paneId: 5)) == true)
        // Consume-once: the same value fired a second time (no intervening
        // register) is no longer recognized as an echo.
        #expect(filter.consumeIfEcho(Entry(windowId: 1, paneId: 5)) == false)
    }

    @Test func nilPaneEntryIsAWindowLevelWildcard() {
        // Mirrors %session-window-changed: tmux names a window but no
        // pane, yet the native echo always names some concrete pane (the
        // window's currently focused surface).
        var filter = TmuxFocusEchoFilter()
        filter.register([Entry(windowId: 1, paneId: nil)])

        #expect(filter.consumeIfEcho(Entry(windowId: 1, paneId: 42)) == true)
    }

    @Test func doubleEchoOfSameValueFirstSwallowedSecondPassesThrough() {
        var filter = TmuxFocusEchoFilter()
        filter.register([Entry(windowId: 3, paneId: 9)])

        // First observation of this value: recognized as the expected echo.
        #expect(filter.consumeIfEcho(Entry(windowId: 3, paneId: 9)) == true)
        // A second, independent firing of the identical value (e.g. from
        // windowDidBecomeKey's own resync) is treated as a real send, not
        // silently swallowed forever.
        #expect(filter.consumeIfEcho(Entry(windowId: 3, paneId: 9)) == false)
    }

    @Test func differentWindowNeverFalsePositives() {
        var filter = TmuxFocusEchoFilter()
        filter.register([Entry(windowId: 1, paneId: 5)])

        // Same pane id, different window: must not match.
        #expect(filter.consumeIfEcho(Entry(windowId: 2, paneId: 5)) == false)
        // The original entry is still pending since nothing consumed it.
        #expect(filter.consumeIfEcho(Entry(windowId: 1, paneId: 5)) == true)
    }

    @Test func nilWildcardDoesNotLeakAcrossWindows() {
        var filter = TmuxFocusEchoFilter()
        filter.register([Entry(windowId: 1, paneId: nil)])

        #expect(filter.consumeIfEcho(Entry(windowId: 2, paneId: 1)) == false)
    }

    @Test func staleTabSwitchArtifactIsSwallowedAlongsideTargetPane() {
        // Reproduces the cross-tab race: applyFocus(windowId: 7, paneId: 2)
        // is asked for while the window's native focus is still on pane 1.
        // Both the stale pane-1 report (from windowDidBecomeKey's early
        // resync) and the eventual pane-2 settle must be swallowed — if
        // either leaks through as a real send, either tmux's requested
        // focus gets clobbered (stale echo unswallowed) or a real user
        // action nearby could get masked (target unswallowed).
        var filter = TmuxFocusEchoFilter()
        filter.register([
            Entry(windowId: 7, paneId: 2),
            Entry(windowId: 7, paneId: 1),
        ])

        // First sync round: windowDidBecomeKey fires before moveFocus
        // lands, reporting the still-stale pane 1.
        #expect(filter.consumeIfEcho(Entry(windowId: 7, paneId: 1)) == true)
        // Second sync round: moveFocus has landed, reporting pane 2.
        #expect(filter.consumeIfEcho(Entry(windowId: 7, paneId: 2)) == true)
        // Nothing left pending.
        #expect(filter.pending.isEmpty)
    }

    @Test func registerReplacesRatherThanAppends() {
        var filter = TmuxFocusEchoFilter()
        filter.register([Entry(windowId: 1, paneId: 1)])
        filter.register([Entry(windowId: 2, paneId: 2)])

        // The first window's entry was dropped, not merged.
        #expect(filter.consumeIfEcho(Entry(windowId: 1, paneId: 1)) == false)
        #expect(filter.consumeIfEcho(Entry(windowId: 2, paneId: 2)) == true)
    }

    @Test func forgetDropsOnlyEntriesForThatWindow() {
        var filter = TmuxFocusEchoFilter()
        filter.register([
            Entry(windowId: 1, paneId: 1),
            Entry(windowId: 2, paneId: 2),
        ])

        filter.forget(windowId: 1)

        #expect(filter.consumeIfEcho(Entry(windowId: 1, paneId: 1)) == false)
        #expect(filter.consumeIfEcho(Entry(windowId: 2, paneId: 2)) == true)
    }

    @Test func clearDropsEverything() {
        var filter = TmuxFocusEchoFilter()
        filter.register([
            Entry(windowId: 1, paneId: 1),
            Entry(windowId: 2, paneId: nil),
        ])

        filter.clear()

        #expect(filter.pending.isEmpty)
        #expect(filter.consumeIfEcho(Entry(windowId: 1, paneId: 1)) == false)
        #expect(filter.consumeIfEcho(Entry(windowId: 2, paneId: 99)) == false)
    }

    // MARK: - expectedEntries (the applyFocus registration decision)

    @Test func noOpApplyFocusRegistersEmptySet() {
        // Window W is already tmux's selected tab and no pane move
        // applies (e.g. a %session-window-changed for the window the
        // native UI already shows) — applyFocus changes nothing, so
        // nothing should be registered. A stale wildcard/target entry left
        // over from this would otherwise sit forever and swallow the
        // user's next, unrelated click in this window.
        let entries = TmuxFocusEchoFilter.expectedEntries(
            windowId: 1,
            paneId: nil,
            willSwitchTab: false,
            willMoveFocus: false,
            currentPaneId: 9)
        #expect(entries.isEmpty)

        var filter = TmuxFocusEchoFilter()
        filter.register(entries)
        // Nothing registered means nothing is ever recognized as an echo,
        // regardless of what candidate shows up next — including the
        // window's current pane, a wildcard-shaped nil, or anything else.
        #expect(filter.consumeIfEcho(Entry(windowId: 1, paneId: 9)) == false)
        #expect(filter.consumeIfEcho(Entry(windowId: 1, paneId: nil)) == false)
        #expect(filter.consumeIfEcho(Entry(windowId: 1, paneId: 3)) == false)
    }

    @Test func moveFocusOnlyDoesNotRegisterStaleEntry() {
        // Window W is already the selected tab (no tabGroup.selectedWindow
        // assignment will happen), but applyFocus is moving focus to a
        // different pane within it. Since no tab switch occurs, the
        // windowDidBecomeKey race that the stale-pane entry exists for
        // cannot happen here — registering pane 1 (the pre-change focus)
        // anyway would swallow the user's most likely next click, a click
        // back onto pane 1.
        let entries = TmuxFocusEchoFilter.expectedEntries(
            windowId: 7,
            paneId: 2,
            willSwitchTab: false,
            willMoveFocus: true,
            currentPaneId: 1)
        #expect(entries == [Entry(windowId: 7, paneId: 2)])

        var filter = TmuxFocusEchoFilter()
        filter.register(entries)
        // The stale pane (1) was never registered, so a genuine click back
        // onto it is sent normally, not swallowed.
        #expect(filter.consumeIfEcho(Entry(windowId: 7, paneId: 1)) == false)
        // The actual target (2) is still recognized as the expected echo.
        #expect(filter.consumeIfEcho(Entry(windowId: 7, paneId: 2)) == true)
    }
}
