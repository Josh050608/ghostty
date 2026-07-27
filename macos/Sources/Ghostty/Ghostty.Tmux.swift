import GhosttyKit

extension Ghostty {
    /// A tmux control mode event delivered via GHOSTTY_ACTION_TMUX.
    /// All payloads are deep copies: the C arrays are only valid during
    /// the action callback.
    enum TmuxEvent: @unchecked Sendable {
        case attach(router: UnsafeMutableRawPointer)
        case windows(TmuxWindows)
        case exit
    }

    struct TmuxWindows: Equatable, Sendable {
        var windows: [TmuxWindow] = []
        var nodes: [TmuxNode] = []

        init?(from c: ghostty_action_tmux_windows_s) {
            if let cw = c.windows {
                for i in 0..<Int(c.windows_len) {
                    windows.append(TmuxWindow(from: cw[i]))
                }
            }
            if let cn = c.nodes {
                for i in 0..<Int(c.nodes_len) {
                    guard let node = TmuxNode(from: cn[i]) else { return nil }
                    nodes.append(node)
                }
            }
            // Window roots must be valid node indices (non-negative and within bounds).
            for w in windows where w.root < 0 || w.root >= nodes.count { return nil }
        }
    }

    struct TmuxWindow: Equatable, Sendable {
        var id: UInt
        var name: String
        var width: UInt
        var height: UInt
        var root: Int

        init(from c: ghostty_action_tmux_window_s) {
            id = UInt(c.id)
            name = String(cString: c.name)
            width = UInt(c.width)
            height = UInt(c.height)
            root = Int(c.root)
        }
    }

    struct TmuxNode: Equatable, Sendable {
        enum Kind: Equatable { case pane, horizontal, vertical }

        var kind: Kind
        var paneId: UInt
        var x: UInt
        var y: UInt
        var width: UInt
        var height: UInt
        var childrenStart: Int
        var childrenLen: Int

        init?(from c: ghostty_action_tmux_node_s) {
            switch c.kind {
            case GHOSTTY_ACTION_TMUX_NODE_KIND_PANE: kind = .pane
            case GHOSTTY_ACTION_TMUX_NODE_KIND_HORIZONTAL: kind = .horizontal
            case GHOSTTY_ACTION_TMUX_NODE_KIND_VERTICAL: kind = .vertical
            default: return nil
            }
            paneId = UInt(c.pane_id)
            x = UInt(c.x)
            y = UInt(c.y)
            width = UInt(c.width)
            height = UInt(c.height)
            childrenStart = Int(c.children_start)
            childrenLen = Int(c.children_len)
        }
    }
}
