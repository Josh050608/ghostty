import AppKit
import Testing
@testable import Ghostty

@MainActor
@Suite struct TmuxTabGuardTests {
    /// Stand-in for TmuxTerminalController. The real controller needs a live
    /// Ghostty.App and a surface tree; the guard reads nothing but this one bit.
    private final class StubTmuxController: NSWindowController, TmuxManagedWindow {
        let isTmuxManaged: Bool

        init(window: NSWindow, managed: Bool) {
            self.isTmuxManaged = managed
            super.init(window: window)
        }

        required init?(coder: NSCoder) { fatalError("not used in tests") }
    }

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true)
    }

    @Test func ordinaryGroupAllowsBatchClose() {
        #expect(!TmuxTabGuard.blocksBatchClose([makeWindow(), makeWindow()]))
    }

    @Test func liveTmuxTabBlocksBatchClose() {
        let plain = makeWindow()
        let tmux = makeWindow()
        let controller = StubTmuxController(window: tmux, managed: true)

        withExtendedLifetime(controller) {
            #expect(TmuxTabGuard.blocksBatchClose([plain, tmux]))
        }
    }

    /// A tmux tab that is tearing down (or force-closing) is closed locally on
    /// purpose, so it must not keep blocking the ordinary tabs around it.
    @Test func tornDownTmuxTabAllowsBatchClose() {
        let tmux = makeWindow()
        let controller = StubTmuxController(window: tmux, managed: false)

        withExtendedLifetime(controller) {
            #expect(!TmuxTabGuard.blocksBatchClose([tmux]))
        }
    }
}
