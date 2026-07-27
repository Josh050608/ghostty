/// A pure description of a tmux window layout as a binary split tree:
/// tmux n-ary splits are folded right-associatively, with each split's
/// ratio derived from the children's sizes along the split axis. This
/// stays free of UI types so it is fully unit-testable; mapping pane
/// ids to SurfaceViews happens in TmuxSessionController.
enum TmuxSplitLayout: Equatable {
    case pane(id: UInt)
    indirect case split(
        direction: Direction,
        ratio: Double,
        left: TmuxSplitLayout,
        right: TmuxSplitLayout)

    enum Direction: Equatable {
        case horizontal
        case vertical
    }

    static func build(nodes: [Ghostty.TmuxNode], root: Int) -> TmuxSplitLayout? {
        guard root >= 0, root < nodes.count else { return nil }
        let node = nodes[root]
        switch node.kind {
        case .pane:
            return .pane(id: node.paneId)
        case .horizontal, .vertical:
            let dir: Direction = node.kind == .horizontal ? .horizontal : .vertical
            // The Zig flattener (serializeTmuxWindowsAlloc's post-order flattenLayout)
            // appends children BEFORE their parent, so for any split node at index `root`
            // the invariant `childrenStart + childrenLen <= root` holds. Enforcing it here
            // makes every recursive descent strictly decrease the maximum reachable index,
            // proving termination and preventing cycles where a node's children range
            // includes itself or an ancestor (which would cause infinite recursion).
            guard node.childrenLen >= 1,
                  node.childrenStart >= 0,
                  node.childrenStart + node.childrenLen <= nodes.count,
                  node.childrenStart + node.childrenLen <= root
            else { return nil }
            return buildRun(
                nodes: nodes, direction: dir,
                start: node.childrenStart, len: node.childrenLen)
        }
    }

    private static func buildRun(
        nodes: [Ghostty.TmuxNode],
        direction: Direction,
        start: Int,
        len: Int
    ) -> TmuxSplitLayout? {
        func axisSize(_ n: Ghostty.TmuxNode) -> Double {
            Double(direction == .horizontal ? n.width : n.height)
        }
        guard let first = build(nodes: nodes, root: start) else { return nil }
        if len == 1 { return first }
        guard let rest = buildRun(
            nodes: nodes, direction: direction,
            start: start + 1, len: len - 1) else { return nil }
        var total = 0.0
        for i in start..<(start + len) { total += axisSize(nodes[i]) }
        guard total > 0 else { return nil }
        return .split(
            direction: direction,
            ratio: axisSize(nodes[start]) / total,
            left: first,
            right: rest)
    }
}

// MARK: - Layout signature

extension TmuxSplitLayout {
    /// Returns a canonical string that captures the layout's pane ids,
    /// split directions, and split ratios (to 3 decimal places). Two layouts
    /// that are structurally identical and have the same pane ids and ratios
    /// produce equal strings. Used by TmuxTerminalController to skip redundant
    /// tree rebuilds when a windows event does not change the layout.
    func signature() -> String {
        switch self {
        case .pane(let id):
            return "p\(id)"
        case .split(let d, let r, let left, let right):
            let dir = d == .horizontal ? "h" : "v"
            return "\(dir)[\(String(format: "%.3f", r)):\(left.signature()),\(right.signature())]"
        }
    }
}
