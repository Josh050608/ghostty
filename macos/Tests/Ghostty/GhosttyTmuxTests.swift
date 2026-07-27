import Testing
@testable import Ghostty
import GhosttyKit

@Suite struct GhosttyTmuxTests {
    @Test func windowsDeepCopy() throws {
        var nodes = [ghostty_action_tmux_node_s(
            kind: GHOSTTY_ACTION_TMUX_NODE_KIND_PANE,
            pane_id: 5, x: 0, y: 0, width: 80, height: 24,
            children_start: 0, children_len: 0)]
        let name = strdup("my editor")!
        defer { free(name) }
        var windows = [ghostty_action_tmux_window_s(
            id: 3, name: name, width: 80, height: 24, root: 0)]

        let copied: Ghostty.TmuxWindows? = windows.withUnsafeBufferPointer { wp in
            nodes.withUnsafeBufferPointer { np in
                Ghostty.TmuxWindows(from: ghostty_action_tmux_windows_s(
                    windows: wp.baseAddress, windows_len: 1,
                    nodes: np.baseAddress, nodes_len: 1))
            }
        }
        let w = try #require(copied)
        #expect(w.windows.count == 1)
        #expect(w.windows[0].id == 3)
        #expect(w.windows[0].name == "my editor")
        #expect(w.windows[0].root == 0)
        #expect(w.nodes.count == 1)
        #expect(w.nodes[0].kind == .pane)
        #expect(w.nodes[0].paneId == 5)
    }

    @Test func nodeRejectsUnknownKind() {
        let bad = ghostty_action_tmux_node_s(
            kind: ghostty_action_tmux_node_kind_e(rawValue: 99),
            pane_id: 0, x: 0, y: 0, width: 0, height: 0,
            children_start: 0, children_len: 0)
        #expect(Ghostty.TmuxNode(from: bad) == nil)
    }

    @Test func windowsRejectsNegativeRoot() throws {
        var nodes = [ghostty_action_tmux_node_s(
            kind: GHOSTTY_ACTION_TMUX_NODE_KIND_PANE,
            pane_id: 5, x: 0, y: 0, width: 80, height: 24,
            children_start: 0, children_len: 0)]
        let name = strdup("test")!
        defer { free(name) }
        // Use UInt.max as root, which wraps to -1 as Int
        var windows = [ghostty_action_tmux_window_s(
            id: 1, name: name, width: 80, height: 24, root: UInt.max)]

        let copied: Ghostty.TmuxWindows? = windows.withUnsafeBufferPointer { wp in
            nodes.withUnsafeBufferPointer { np in
                Ghostty.TmuxWindows(from: ghostty_action_tmux_windows_s(
                    windows: wp.baseAddress, windows_len: 1,
                    nodes: np.baseAddress, nodes_len: 1))
            }
        }
        #expect(copied == nil)
    }
}
