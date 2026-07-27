import GhosttyKit

extension Ghostty {
    /// A tmux control mode event delivered via GHOSTTY_ACTION_TMUX.
    /// All payloads are deep copies: the C arrays are only valid during
    /// the action callback.
    ///
    /// @unchecked Sendable: the router pointer is an opaque token never
    /// dereferenced in Swift — it is only passed to the thread-safe C APIs
    /// ghostty_tmux_router_command and ghostty_tmux_router_release.
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
                    guard let w = TmuxWindow(from: cw[i]) else { return nil }
                    windows.append(w)
                }
            }
            if let cn = c.nodes {
                for i in 0..<Int(c.nodes_len) {
                    guard let node = TmuxNode(from: cn[i]) else { return nil }
                    nodes.append(node)
                }
            }
            // Window roots must be valid node indices. Int(exactly:) already
            // rejects values > Int.max, so root is never negative here.
            for w in windows where w.root >= nodes.count { return nil }
        }
    }

    struct TmuxWindow: Equatable, Sendable {
        var id: UInt
        var name: String
        var width: UInt
        var height: UInt
        var root: Int

        init?(from c: ghostty_action_tmux_window_s) {
            guard let root = Int(exactly: c.root) else { return nil }
            id = UInt(c.id)
            name = String(cString: c.name)
            width = UInt(c.width)
            height = UInt(c.height)
            self.root = root
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

        /// Memberwise initializer for testing and internal construction.
        init(
            kind: Kind,
            paneId: UInt = 0,
            x: UInt = 0,
            y: UInt = 0,
            width: UInt,
            height: UInt,
            childrenStart: Int = 0,
            childrenLen: Int = 0
        ) {
            self.kind = kind
            self.paneId = paneId
            self.x = x
            self.y = y
            self.width = width
            self.height = height
            self.childrenStart = childrenStart
            self.childrenLen = childrenLen
        }

        init?(from c: ghostty_action_tmux_node_s) {
            switch c.kind {
            case GHOSTTY_ACTION_TMUX_NODE_KIND_PANE: kind = .pane
            case GHOSTTY_ACTION_TMUX_NODE_KIND_HORIZONTAL: kind = .horizontal
            case GHOSTTY_ACTION_TMUX_NODE_KIND_VERTICAL: kind = .vertical
            default: return nil
            }
            guard let childrenStart = Int(exactly: c.children_start),
                  let childrenLen = Int(exactly: c.children_len) else { return nil }
            paneId = UInt(c.pane_id)
            x = UInt(c.x)
            y = UInt(c.y)
            width = UInt(c.width)
            height = UInt(c.height)
            self.childrenStart = childrenStart
            self.childrenLen = childrenLen
        }
    }
}
