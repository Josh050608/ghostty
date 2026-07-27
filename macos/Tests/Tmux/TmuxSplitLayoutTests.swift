import Testing
@testable import Ghostty
import GhosttyKit

@Suite struct TmuxSplitLayoutTests {
    private func pane(_ id: UInt, w: UInt = 80, h: UInt = 24) -> Ghostty.TmuxNode {
        node(kind: .pane, paneId: id, w: w, h: h)
    }

    private func node(
        kind: Ghostty.TmuxNode.Kind, paneId: UInt = 0,
        w: UInt, h: UInt, start: Int = 0, len: Int = 0
    ) -> Ghostty.TmuxNode {
        Ghostty.TmuxNode(
            kind: kind, paneId: paneId,
            width: w, height: h,
            childrenStart: start, childrenLen: len)
    }

    @Test func singlePane() {
        let layout = TmuxSplitLayout.build(nodes: [pane(1)], root: 0)
        #expect(layout == .pane(id: 1))
    }

    @Test func horizontalPairRatio() throws {
        // [pane0(w30), pane1(w90), H(children 0..2, w121)]
        let nodes = [
            pane(0, w: 30), pane(1, w: 90),
            node(kind: .horizontal, w: 121, h: 24, start: 0, len: 2),
        ]
        let layout = try #require(TmuxSplitLayout.build(nodes: nodes, root: 2))
        guard case .split(let dir, let ratio, let left, let right) = layout else {
            Issue.record("expected split"); return
        }
        #expect(dir == .horizontal)
        #expect(abs(ratio - 30.0 / 120.0) < 0.001)
        #expect(left == .pane(id: 0))
        #expect(right == .pane(id: 1))
    }

    @Test func threeWayFoldsRightAssociative() throws {
        // H[p0(40), p1(40), p2(40)] -> split(p0, split(p1, p2, 0.5), 1/3)
        let nodes = [
            pane(0, w: 40), pane(1, w: 40), pane(2, w: 40),
            node(kind: .horizontal, w: 122, h: 24, start: 0, len: 3),
        ]
        let layout = try #require(TmuxSplitLayout.build(nodes: nodes, root: 3))
        guard case .split(_, let ratio, let left, let right) = layout,
              case .split(_, let innerRatio, let innerL, let innerR) = right else {
            Issue.record("expected nested split"); return
        }
        #expect(left == .pane(id: 0))
        #expect(abs(ratio - 1.0 / 3.0) < 0.001)
        #expect(abs(innerRatio - 0.5) < 0.001)
        #expect(innerL == .pane(id: 1))
        #expect(innerR == .pane(id: 2))
    }

    @Test func nonContiguousCopiedSegment() throws {
        // Replicates Zig-side H[p1, V[p2, p3]] flattened output:
        // copied-segment children indices point to original positions.
        // [0]=p1 [1]=p2 [2]=p3 [3]=V(children 1..3) [4]=p1' (copy of 0)
        // [5]=V' (copy of 3, children still 1..3) [6]=H(children 4..6)
        let nodes = [
            pane(1, w: 40, h: 24), pane(2, w: 40, h: 11), pane(3, w: 40, h: 12),
            node(kind: .vertical, w: 40, h: 24, start: 1, len: 2),
            pane(1, w: 40, h: 24),
            node(kind: .vertical, w: 40, h: 24, start: 1, len: 2),
            node(kind: .horizontal, w: 81, h: 24, start: 4, len: 2),
        ]
        let layout = try #require(TmuxSplitLayout.build(nodes: nodes, root: 6))
        guard case .split(let dir, _, let left, let right) = layout,
              case .split(let innerDir, _, let innerL, let innerR) = right else {
            Issue.record("expected nested split"); return
        }
        #expect(dir == .horizontal)
        #expect(left == .pane(id: 1))
        #expect(innerDir == .vertical)
        #expect(innerL == .pane(id: 2))
        #expect(innerR == .pane(id: 3))
    }

    @Test func invalidIndicesReturnNil() {
        #expect(TmuxSplitLayout.build(nodes: [], root: 0) == nil)
        let bad = [node(kind: .horizontal, w: 80, h: 24, start: 5, len: 2)]
        #expect(TmuxSplitLayout.build(nodes: bad, root: 0) == nil)
        let empty = [node(kind: .horizontal, w: 80, h: 24, start: 0, len: 0)]
        #expect(TmuxSplitLayout.build(nodes: empty, root: 0) == nil)
    }
}
