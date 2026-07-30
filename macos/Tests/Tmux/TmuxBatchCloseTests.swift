import Testing
@testable import Ghostty

/// `TmuxBatchClose.partition` is a pure function: it only reads each
/// candidate's declared `batchCloseDisposition`, so it's tested here with
/// lightweight protocol stubs (no AppKit, no real `TerminalController` or
/// `TmuxSessionController` — both need a live NIB / Ghostty.App to construct,
/// which is not something any test in this suite does; see
/// TmuxFocusEchoFilterTests for the same pattern applied to another pure
/// tmux helper).
@Suite struct TmuxBatchCloseTests {
    /// Stands in for a real tmux session. `TmuxBatchClose` only needs
    /// reference identity (for grouping) and a place to forward `send` to,
    /// both of which `TmuxKillTarget` captures without pulling in
    /// `TmuxSessionController`'s real dependencies.
    private final class FakeSession: TmuxKillTarget {
        private(set) var sent: [TmuxCommand] = []
        func send(_ cmd: TmuxCommand) { sent.append(cmd) }
    }

    /// Stub `BatchCloseParticipant` with a fixed, test-supplied disposition.
    private final class StubParticipant: BatchCloseParticipant {
        let batchCloseDisposition: BatchCloseDisposition
        init(_ disposition: BatchCloseDisposition) {
            self.batchCloseDisposition = disposition
        }
    }

    @Test func allLocalReturnsAllInLocalBucket() {
        let candidates: [any BatchCloseParticipant] = [
            StubParticipant(.local),
            StubParticipant(.local),
        ]

        let (local, kills) = TmuxBatchClose.partition(candidates)

        #expect(local.count == 2)
        #expect(kills.isEmpty)
    }

    @Test func killsGroupBySession() {
        let sessionA = FakeSession()
        let sessionB = FakeSession()
        let candidates: [any BatchCloseParticipant] = [
            StubParticipant(.tmuxKill(session: sessionA, windowId: 1)),
            StubParticipant(.tmuxKill(session: sessionA, windowId: 2)),
            StubParticipant(.tmuxKill(session: sessionB, windowId: 3)),
        ]

        let (local, kills) = TmuxBatchClose.partition(candidates)

        #expect(local.isEmpty)
        #expect(kills.count == 2)
        #expect(kills[0].windowIds == [1, 2])
        #expect(kills[1].windowIds == [3])
    }

    @Test func mixedPartition() {
        let session = FakeSession()
        let candidates: [any BatchCloseParticipant] = [
            StubParticipant(.local),
            StubParticipant(.tmuxKill(session: session, windowId: 1)),
            StubParticipant(.tmuxKill(session: session, windowId: 2)),
        ]

        let (local, kills) = TmuxBatchClose.partition(candidates)

        #expect(local.count == 1)
        #expect(kills.count == 1)
        #expect(kills[0].windowIds == [1, 2])
    }
}
