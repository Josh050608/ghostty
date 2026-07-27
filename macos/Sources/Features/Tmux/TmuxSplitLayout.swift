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
            guard node.childrenLen >= 1,
                  node.childrenStart >= 0,
                  node.childrenStart + node.childrenLen <= nodes.count
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
