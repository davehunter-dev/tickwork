//
// Dave Hunter – ©️ 2024
//
// `loop.json`'s optional `lockConversations`: its shape, `next` claiming only
// locked issues, and `finish --pr` locking the pull request before anything else.
//

import Foundation
import Testing

@testable import BoardCore

@Suite("Conversation locking")
struct LockConversationsTests {

    static let on = #", "lockConversations": true"#
    static let off = #", "lockConversations": false"#

    // MARK: loop.json

    @Test("lockConversations is read when present, and off when absent")
    func configuration() throws {
        func read(_ settings: String) throws -> Bool {
            try JSONDecoder().decode(
                LoopConfiguration.self, from: Data(StackOptInTests.arrangement(settings).utf8)
            ).lockConversations
        }
        #expect(try read(Self.on))
        #expect(try read(Self.off) == false)
        #expect(try read("") == false)
    }

    @Test("check-loop's rules accept true, false and absence, and refuse anything else")
    func shape() throws {
        for settings in [Self.on, Self.off, ""] {
            #expect(loopProblems(in: try StackOptInTests.document(settings)).isEmpty)
        }
        for value in [#""true""#, "1", "null", "{}"] {
            #expect(
                loopProblems(in: try StackOptInTests.document(#", "lockConversations": "# + value))
                    == ["lockConversations: not true or false"])
        }
    }

    // MARK: Selection

    static let columns = ["Agent Review", "In Progress", "In Design", "Ready"]

    func board(_ items: [Item]) -> FakeBoard {
        let board = NextTests().board(items)
        for item in items where item.status == "In Design" {
            board.labels[item.number] = ["type:design"]
        }
        return board
    }

    func items() -> [Item] {
        Self.columns.enumerated().map { NextTests().item($0.offset + 1, $0.element) }
    }

    @Test("With the option absent or false, selection reads no lock", arguments: ["", off])
    func noLockRead(_ settings: String) {
        let board = board([NextTests().item(7, "Ready")])
        let answer = NextTests().run(
            NextTests().request(arrangement: StackOptInTests.arrangement(settings)), board)
        guard case .assignment(let assignment) = answer else {
            Issue.record("expected an assignment: \(answer)")
            return
        }
        #expect(assignment.issue.number == 7)
        #expect(board.lockReads.isEmpty)
    }

    @Test("With it on, an unlocked issue is skipped as unlocked in every column")
    func unlockedSkipped() {
        let board = board(items())
        let answer = NextTests().run(
            NextTests().request(arrangement: StackOptInTests.arrangement(Self.on)), board)
        guard case .idle(let idle) = answer else {
            Issue.record("expected idle: \(answer)")
            return
        }
        #expect(
            idle.skipped
                == (1...4).map { SkipAnswer(Skip(issue: $0, reason: .unlocked, detail: nil)) })
        #expect(board.assignees.isEmpty)
    }

    @Test("With it on, a locked issue is claimed", arguments: columns)
    func lockedClaimed(_ column: String) {
        let items = items()
        let board = board(items)
        let number = items.first { $0.status == column }!.number
        board.locked = [number]
        let answer = NextTests().run(
            NextTests().request(arrangement: StackOptInTests.arrangement(Self.on)), board)
        guard case .assignment(let assignment) = answer else {
            Issue.record("expected an assignment: \(answer)")
            return
        }
        #expect(assignment.issue.number == number)
        #expect(Set(assignment.skipped.map(\.reason)).isSubset(of: [SkipReason.unlocked.rawValue]))
    }

    @Test("select skips an unlocked card in every column, and the second pass passes it over")
    func selectSkips() {
        let agent = SelectingAgent(login: "agent-one", roles: [.reviewer, .engineer, .designer])
        for column in Self.columns {
            var card = CardFacts(
                number: 7, column: column, assignees: [], isDesign: column == "In Design")
            card.isUnlocked = true
            #expect(
                select(from: [card], agent: agent)
                    == Selection(
                        pick: nil, skipped: [Skip(issue: 7, reason: .unlocked, detail: nil)]))
        }
        var labelled = CardFacts(number: 7, column: "Ready", assignees: [], isDesign: false)
        labelled.isStackable = true
        labelled.isUnlocked = true
        labelled.openBlockers = [3]
        labelled.stackParent = .base(
            StackBase(
                parent: 3, pullRequest: PullRequestID(repository: "example-org/example", number: 4),
                branch: "f/3-parent", head: "abc123"))
        #expect(
            selectStacked(from: [labelled], agent: agent) == Selection(pick: nil, skipped: []))
    }

    // MARK: finish --pr

    static let ref = "example-org/fixtures#31"

    func finish(_ world: FinishTests.World, lock: Bool) -> FinishAnswer {
        var context = FinishTests.context
        context.lockConversations = lock
        return BoardCore.finish(
            FinishTests.request(.submitted).0, board: world.board, source: world.source,
            context: context)
    }

    @Test("With the option off, finish --pr locks nothing")
    func offLocksNothing() {
        let world = FinishTests.World(column: "In Progress")
        guard case .finished = finish(world, lock: false) else {
            Issue.record("expected finished")
            return
        }
        #expect(!world.source.writes.contains { $0.hasPrefix("lock") })
    }

    @Test("With it on, finish --pr locks an unlocked pull request before its other writes")
    func locksFirst() {
        let world = FinishTests.World(column: "In Progress")
        guard case .finished(let answer) = finish(world, lock: true) else {
            Issue.record("expected finished")
            return
        }
        #expect(
            world.log == [
                "lock \(Self.ref)", "comment #7", "comment \(Self.ref)",
                "move #7 In Progress → Agent Review", "release #7",
            ])
        #expect(answer.done.first == "lock \(Self.ref)")
    }

    @Test("With it on, a pull request already locked is left alone")
    func leavesLocked() {
        let world = FinishTests.World(column: "In Progress")
        world.source.merge[FinishTests.pullRequest]?.locked = true
        guard case .finished = finish(world, lock: true) else {
            Issue.record("expected finished")
            return
        }
        #expect(!world.source.writes.contains { $0.hasPrefix("lock") })
        #expect(world.log.first == "comment #7")
    }

    @Test("With it on, a failed lock writes nothing and answers incomplete, and a re-run finishes")
    func failedLock() {
        let world = FinishTests.World(column: "In Progress")
        world.source.failing = ["lock"]
        guard case .incomplete(let answer) = finish(world, lock: true) else {
            Issue.record("expected incomplete")
            return
        }
        #expect(world.log.isEmpty)
        #expect(answer.done.isEmpty)
        #expect(answer.pending.first == "lock \(Self.ref)")

        world.source.failing = []
        guard case .finished = finish(world, lock: true) else {
            Issue.record("expected finished on the re-run")
            return
        }
        #expect(world.log.first == "lock \(Self.ref)")
    }

    @Test(
        "With it on, a card moved under the tick still has its pull request locked before the comments"
    )
    func locksWhenCardMoved() {
        let world = FinishTests.World(column: "In Progress")
        world.board.login = "agent-two"
        try? world.board.move(7, to: "Needs Human", from: "In Progress")
        world.board.login = "agent-one"
        world.log = []
        guard case .refused(let answer) = finish(world, lock: true) else {
            Issue.record("expected refused")
            return
        }
        #expect(answer.stage == "move")
        #expect(
            world.log == ["lock \(Self.ref)", "comment #7", "comment \(Self.ref)", "release #7"])
    }

    @Test(
        "With it on, an agent's approval GitHub doesn't show yet answers incomplete, approving once"
    )
    func approvalNotShownYet() {
        let world = AgentApprovalTests.World()
        world.source.hideNextApproval = true
        var context = AgentApprovalTests.context()
        context.lockConversations = true
        guard case .incomplete = world.finish(context) else {
            Issue.record("expected incomplete")
            return
        }
        let ref = AgentApprovalTests.ref
        #expect(world.log == ["lock \(ref)", "approve \(ref)"])
    }
}
