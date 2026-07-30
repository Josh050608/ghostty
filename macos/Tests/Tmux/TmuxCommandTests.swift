import AppKit
import Testing
@testable import Ghostty
import GhosttyKit

@Suite struct TmuxCommandTests {
    private func cValue(_ cmd: TmuxCommand) -> ghostty_tmux_command_s {
        var out: ghostty_tmux_command_s!
        cmd.withCValue { out = $0 }
        return out
    }

    @Test func killWindowFields() {
        let c = cValue(.killWindow(windowId: 3))
        #expect(c.tag == GHOSTTY_TMUX_COMMAND_KILL_WINDOW)
        #expect(c.id == 3)
        #expect(c.text == nil)
    }

    @Test func splitDirectionMapping() {
        // 右→ -h;左→ -h -b(width=1);下→ -v;上→ -v -b
        let right = cValue(.split(paneId: 7, direction: .right))
        #expect(right.tag == GHOSTTY_TMUX_COMMAND_SPLIT_HORIZONTAL)
        #expect(right.id == 7 && right.width == 0)

        let left = cValue(.split(paneId: 7, direction: .left))
        #expect(left.tag == GHOSTTY_TMUX_COMMAND_SPLIT_HORIZONTAL)
        #expect(left.width == 1)

        let down = cValue(.split(paneId: 7, direction: .down))
        #expect(down.tag == GHOSTTY_TMUX_COMMAND_SPLIT_VERTICAL)
        #expect(down.width == 0)

        let up = cValue(.split(paneId: 7, direction: .up))
        #expect(up.tag == GHOSTTY_TMUX_COMMAND_SPLIT_VERTICAL)
        #expect(up.width == 1)
    }

    @Test func renameMarshalsText() {
        var seen: String?
        TmuxCommand.renameWindow(windowId: 2, name: "dev ✅").withCValue { c in
            #expect(c.tag == GHOSTTY_TMUX_COMMAND_RENAME_WINDOW)
            #expect(c.id == 2)
            seen = c.text.map { String(cString: $0) }
        }
        #expect(seen == "dev ✅")
    }

    @Test func resizeFields() {
        let c = cValue(.resize(cols: 120, rows: 40))
        #expect(c.tag == GHOSTTY_TMUX_COMMAND_RESIZE)
        #expect(c.width == 120 && c.height == 40)
    }

    @Test func restoreAutomaticRenameFields() {
        let c = cValue(.restoreAutomaticRename(windowId: 5))
        #expect(c.tag == GHOSTTY_TMUX_COMMAND_AUTOMATIC_RENAME)
        #expect(c.id == 5)
        #expect(c.text == nil)
    }
}
