// Selection's second pass: when it runs, what it takes, each condition that
// makes a labelled card not stackable, the assignment's `stack`, and
// `finish submitted`'s base check on a stacked start.
//

import Foundation
import Testing

@testable import BoardCore

@Suite("Choosing stacked work")
struct StackSelectionTests {

    static let repository = "example-org/fixtures"
    static let parentPR = PullRequestID(repository: repository, number: 105)
    static let agent = SelectingAgent(login: "agent-one", roles: [.engineer, .reviewer])

    // MARK: select

    static func ready(
        _ number: Int, blockers: [Int] = [], stackable: Bool = true, parent: StackParent? = nil
    ) -> CardFacts {
        var card = CardFacts(number: number, column: "Ready", assignees: [], isDesign: false)
        card.openBlockers = blockers
        card.isStackable = stackable
        card.stackParent = parent
        return card
    }

    static let base = StackBase(parent: 5, pullRequest: parentPR, branch: "f/5-parent", head: "p1")

    @Test("It takes the first labelled card whose one blocker it can stack on")
    func takesTheFirstStackable() {
        let cards = [
            Self.ready(6, blockers: [5], stackable: false),
            Self.ready(7, blockers: [5], parent: .base(Self.base)),
            Self.ready(8, blockers: [5], parent: .base(Self.base)),
        ]
        let selection = selectStacked(from: cards, agent: Self.agent)
        #expect(selection.pick == Pick(issue: 7, role: .engineer, task: .start, stack: Self.base))
        #expect(!selection.skipped.contains { $0.reason == .notStackable })
    }

    @Test("Two open blockers, or a refused parent, are skipped naming why")
    func skipsNameTheCondition() {
        let cards = [
            Self.ready(6, blockers: [4, 5]),
            Self.ready(7, blockers: [5], parent: .refused("#5 is in Agent Review")),
        ]
        let stacked = selectStacked(from: cards, agent: Self.agent)
        #expect(stacked.pick == nil)
        #expect(
            stacked.skipped == [
                Skip(
                    issue: 6, reason: .notStackable,
                    detail: "#4, #5 are open, and a stack has one parent"),
                Skip(issue: 7, reason: .notStackable, detail: "#5 is in Agent Review"),
            ])
    }

    @Test("Only the Engineer starts stacked work")
    func engineerOnly() {
        let cards = [Self.ready(7, blockers: [5], parent: .base(Self.base))]
        let reviewer = SelectingAgent(login: "agent-one", roles: [.reviewer, .designer])
        #expect(selectStacked(from: cards, agent: reviewer) == Selection(pick: nil, skipped: []))
    }

    // MARK: The parent

    /// A parent issue, 5, unclaimed in Human Review, its one open pull request
    /// green and into `base`.
    final class World {
        let board = FakeBoard()
        let source = FakeSourceControl()

        init(parentColumn: String = "Human Review", base: String = "main") {
            board.login = "agent-one"
            board.board = Board(
                items: [
                    Item(id: "i5", number: 5, title: "Parent", status: parentColumn, assignees: []),
                    Item(id: "i7", number: 7, title: "Child", status: "Ready", assignees: []),
                ],
                statusFieldID: "status", optionIDs: [:], columns: Workflow.standard.columns.all)
            board.labels[7] = ["type:feature", "stackable"]
            board.blockers[7] = [5]
            board.linked[5] = [LinkedPullRequest(id: parentPR, open: true, merged: false)]
            for issue in [5, 7] {
                board.events[issue] = [
                    TimelineEvent(
                        kind: .assigned, actor: "agent-one", subject: "agent-one",
                        createdAt: NextTests.claimTime)
                ]
            }
            var merge = MergeFacts(
                headSHA: "p1", branch: "f/5-parent", mergeable: true, mergeableState: "blocked",
                draft: false, opener: "agent-two")
            merge.base = base
            source.merge[parentPR] = merge
            source.checks["\(repository)@p1"] = CheckFacts(ran: true)
        }

        /// One open pull request from `branch` into `base`.
        func openPull(from branch: String, into base: String, number: Int) {
            source.branchPulls["\(repository)@\(branch)", default: []].append(
                BranchPullRequest(number: number, open: true, mergeCommit: nil, base: base))
        }

        func parent() throws -> StackParent {
            try stackParent(
                5, snapshot: board.board, workflow: .standard, board: board, source: source)
        }
    }

    @Test("A settled parent whose stack reaches main is a base, through every level")
    func reachesMain() throws {
        let world = World(base: "f/4-lower")
        world.openPull(from: "f/4-lower", into: "f/3-lowest", number: 104)
        world.openPull(from: "f/3-lowest", into: "main", number: 103)
        #expect(
            try world.parent()
                == .base(
                    StackBase(
                        parent: 5, pullRequest: Self.parentPR, branch: "f/5-parent", head: "p1")))
        #expect(world.source.guardReads == ["pulls f/4-lower", "pulls f/3-lowest"])
    }

    @Test("A parent that isn't settled is refused, naming what isn't")
    func unsettled() throws {
        #expect(
            try World(parentColumn: "Agent Review").parent() == .refused("#5 is in Agent Review"))

        let claimed = World()
        claimed.board.update(5) {
            Item(id: $0.id, number: 5, title: $0.title, status: $0.status, assignees: ["agent-two"])
        }
        #expect(try claimed.parent() == .refused("#5 is claimed by agent-two"))

        let draft = World()
        draft.source.merge[Self.parentPR] = MergeFacts(
            headSHA: "p1", branch: "f/5-parent", mergeable: true, mergeableState: "draft",
            draft: true, opener: "agent-two")
        #expect(try draft.parent() == .refused("#5's PR example-org/fixtures#105 is a draft"))

        let red = World()
        red.source.checks["\(Self.repository)@p1"] = CheckFacts(failing: ["test"], ran: true)
        #expect(try red.parent() == .refused("#5's PR example-org/fixtures#105 is not green"))

        let none = World()
        none.board.linked[5] = []
        #expect(try none.parent() == .refused("#5 has no open pull request"))
    }

    @Test("A stack that loops is refused at the branch seen twice")
    func cycle() throws {
        let world = World(base: "f/4-lower")
        world.openPull(from: "f/4-lower", into: "f/3-lowest", number: 104)
        world.openPull(from: "f/3-lowest", into: "f/4-lower", number: 103)
        #expect(try world.parent() == .refused("#5's stack loops at f/4-lower"))
    }

    @Test("A missing, closed or duplicated pull request breaks the stack")
    func breaks() throws {
        let missing = World(base: "f/4-lower")
        #expect(
            try missing.parent()
                == .refused("#5's stack breaks at f/4-lower: no pull request is from it"))

        let closed = World(base: "f/4-lower")
        closed.source.branchPulls["\(Self.repository)@f/4-lower"] = [
            BranchPullRequest(number: 104, open: false, mergeCommit: nil)
        ]
        #expect(
            try closed.parent()
                == .refused("#5's stack breaks at f/4-lower: its pull request is closed"))

        let duplicated = World(base: "f/4-lower")
        duplicated.openPull(from: "f/4-lower", into: "main", number: 104)
        duplicated.openPull(from: "f/4-lower", into: "main", number: 106)
        #expect(
            try duplicated.parent()
                == .refused("#5's stack breaks at f/4-lower: 2 open pull requests are from it"))
    }

    // MARK: next

    static let stacked = StackOptInTests.arrangement(StackOptInTests.stacked)

    func run(_ world: World, arrangement: String = stacked) -> NextAnswer {
        next(
            NextRequest(
                arrangementJSON: arrangement, roles: [.engineer], preview: false, revision: nil),
            board: world.board, source: world.source
        ) { [] }
    }

    @Test("next assigns a stacked start with its stack, and the token carries the branch")
    func assignment() throws {
        let world = World()
        guard case .assignment(let answer) = run(world) else {
            Issue.record("expected an assignment")
            return
        }
        #expect(answer.issue.number == 7)
        #expect(answer.task == "start")
        #expect(
            answer.stack
                == StackAnswer(
                    StackBase(
                        parent: 5, pullRequest: Self.parentPR, branch: "f/5-parent", head: "p1")))
        #expect(try ClaimToken(parsing: answer.token).stackBranch == "f/5-parent")
        #expect(answer.skipped.contains(Skip(issue: 7, reason: .blocked, detail: "#5 open").answer))
    }

    @Test("The second pass doesn't run when the first finds an item")
    func firstPassWins() {
        let world = World()
        world.board.board = Board(
            items: world.board.board.items + [
                Item(id: "i8", number: 8, title: "Unblocked", status: "Ready", assignees: [])
            ],
            statusFieldID: "status", optionIDs: [:], columns: Workflow.standard.columns.all)
        world.board.labels[8] = ["type:feature"]
        world.board.events[8] = world.board.events[7]
        guard case .assignment(let answer) = run(world) else {
            Issue.record("expected an assignment")
            return
        }
        #expect(answer.issue.number == 8)
        #expect(answer.stack == nil)
    }

    @Test("Without stack, next leaves a labelled blocked card alone")
    func idleWithoutStack() {
        guard case .idle = run(World(), arrangement: NextTests.arrangement) else {
            Issue.record("expected idle")
            return
        }
    }

    @Test("A stacked start whose parent closed before the claim is given back")
    func parentClosedBeforeClaim() {
        let world = World()
        world.board.afterClaim = { _ in world.board.blockers[7] = [] }
        guard case .idle(let answer) = run(world) else {
            Issue.record("expected idle")
            return
        }
        #expect(
            answer.skipped.last
                == Skip(issue: 7, reason: .notStackable, detail: "no blocker is open now").answer)
        #expect(world.board.released.map(\.issue) == [7])
    }

    @Test("This agent's interrupted stacked start is resumed with its stack")
    func resumed() throws {
        let world = World()
        world.board.update(7) {
            Item(id: $0.id, number: 7, title: $0.title, status: $0.status, assignees: ["agent-one"])
        }
        guard case .assignment(let answer) = run(world) else {
            Issue.record("expected an assignment")
            return
        }
        #expect(answer.resumed)
        #expect(answer.stack?.branch == "f/5-parent")
        #expect(world.board.released.isEmpty)
    }

    // MARK: The token

    @Test("A stacked start's token round-trips its branch, and an older token still reads")
    func token() throws {
        let token = ClaimToken(
            login: "agent-one", repository: "example-org/example", issue: 7, role: .engineer,
            task: .start, column: "Ready", claimedAt: NextTests.claimTime,
            stackBranch: "f/5-parent")
        #expect(token.text.hasSuffix("~2026-10-28T13:49:02Z~f%2F5%2Dparent"))
        #expect(try ClaimToken(parsing: token.text) == token)
        #expect(
            try ClaimToken(
                parsing: "tw1~agent-one~a/b~7~engineer~start~Ready~2026-10-28T13:49:02Z"
            ).stackBranch == nil)
    }

    // MARK: finish

    func submit(base: String) -> FinishAnswer {
        let world = FinishTests.World(column: "Ready")
        world.source.merge[FinishTests.pullRequest]?.base = base
        var request = FinishRequest(
            token: ClaimToken(
                login: "agent-one", repository: FinishTests.issueRepository, issue: 7,
                role: .engineer, task: .start, column: "Ready", claimedAt: FinishTests.claimTime,
                stackBranch: "f/5-parent"),
            outcome: .submitted)
        request.pullRequest = FinishTests.pullRequest
        request.isNew = true
        return world.finish(request)
    }

    @Test("finish submitted on a stacked start refuses another base, and finishes on its own")
    func finishChecksTheBase() {
        guard case .rejected(let rejected) = submit(base: "main") else {
            Issue.record("expected a rejection")
            return
        }
        #expect(
            rejected.message
                == "example-org/fixtures#31 is based on main, and this stacked start's must be "
                + "its parent's branch, f/5-parent")
        guard case .finished = submit(base: "f/5-parent") else {
            Issue.record("expected it to finish")
            return
        }
    }
}

extension Skip {
    fileprivate var answer: SkipAnswer { SkipAnswer(self) }
}
