// The restack repair: every row of "Keeping a stack current"'s table on its own,
// then through the repairs for Agent Review and Human Review, and through
// `next`'s findings for In Progress.
//

import Foundation
import Testing

@testable import BoardCore

@Suite("The restack repair")
struct RestackTests {

    static let repository = Coordinates.repository
    static let child = PullRequestID(repository: repository, number: 31)
    static let childHead = "c1"
    static let parentBranch = "f/6-parent"
    static let parentHead = "a2"

    static func childFacts(
        base: String = parentBranch, state: String = "dirty", opener: String = "agent-two"
    ) -> MergeFacts {
        MergeFacts(
            headSHA: childHead, branch: "f/7-child", mergeable: state != "dirty",
            mergeableState: state, draft: false, opener: opener, base: base)
    }

    static func item(_ number: Int, _ column: String, assignees: [String] = []) -> Item {
        Item(
            id: "item-\(number)", number: number, title: "Issue \(number)", status: column,
            assignees: assignees)
    }

    /// The parent's issue, #6, in the owner's column and unclaimed unless given.
    static let parentCard = item(6, "Human Review")

    static func openParent(draft: Bool = false) -> BranchPullRequest {
        BranchPullRequest(
            number: 6, open: true, mergeCommit: nil, head: parentHead, draft: draft,
            body: "Closes #6.")
    }

    /// A parent that settled: open, its checks green, and `contained` in the child.
    static func settle(_ source: FakeSourceControl, contained: Bool) {
        source.branchPulls["\(repository)@\(parentBranch)"] = [openParent()]
        source.checks["\(repository)@\(parentHead)"] = CheckFacts(ran: true)
        source.behind["\(repository)@\(parentHead)...\(childHead)"] = contained ? 0 : 2
    }

    func finding(
        _ source: FakeSourceControl, ownerReview: [Item] = [parentCard],
        base: String = parentBranch
    ) throws -> StackFinding? {
        try stackFinding(
            Self.child, merge: Self.childFacts(base: base), ownerReview: ownerReview,
            source: source)
    }

    // MARK: The table

    @Test("A pull request into main has nothing to restack, with nothing read")
    func intoMain() throws {
        let source = FakeSourceControl()
        #expect(try finding(source, base: "main") == nil)
        #expect(source.guardReads.isEmpty)
    }

    @Test(
        "An open parent that hasn't settled leaves the child waiting, with no compare",
        arguments: ["claimed", "Agent Review", "draft", "red", "no checks", "running"])
    func unsettledWaits(_ way: String) throws {
        let source = FakeSourceControl()
        Self.settle(source, contained: false)
        var ownerReview = [Self.parentCard]
        switch way {
        case "claimed": ownerReview = [Self.item(6, "Human Review", assignees: ["agent-two"])]
        case "Agent Review": ownerReview = []
        case "draft":
            source.branchPulls["\(Self.repository)@\(Self.parentBranch)"] = [
                Self.openParent(draft: true)
            ]
        case "red":
            source.checks["\(Self.repository)@\(Self.parentHead)"] = CheckFacts(
                failing: ["build"], ran: true)
        case "no checks": source.checks["\(Self.repository)@\(Self.parentHead)"] = CheckFacts()
        default:
            source.checks["\(Self.repository)@\(Self.parentHead)"] = CheckFacts(
                unfinished: true, ran: true)
        }
        #expect(try finding(source, ownerReview: ownerReview) == nil)
        #expect(source.guardReads == ["pulls \(Self.parentBranch)"])
    }

    @Test("A settled parent whose head the child contains asks nothing")
    func settledContained() throws {
        let source = FakeSourceControl()
        Self.settle(source, contained: true)
        #expect(try finding(source) == nil)
        #expect(
            source.guardReads == [
                "pulls \(Self.parentBranch)", "compare \(Self.parentHead)...\(Self.childHead)",
            ])
    }

    @Test("A settled parent whose head the child lacks is a restack onto that head")
    func settledNotContained() throws {
        let source = FakeSourceControl()
        Self.settle(source, contained: false)
        #expect(
            try finding(source)
                == .restack(
                    onto: Self.parentHead, retarget: false,
                    reason: "parent PR #6 settled at a2, which the head doesn't contain"))
    }

    @Test("A parent merged into main is a restack onto main with a retarget")
    func mergedIntoMain() throws {
        let source = FakeSourceControl()
        source.branchPulls["\(Self.repository)@\(Self.parentBranch)"] = [
            BranchPullRequest(number: 6, open: false, mergeCommit: "m1", head: Self.parentHead)
        ]
        #expect(
            try finding(source)
                == .restack(
                    onto: "main", retarget: true, reason: "parent PR #6 merged into main as m1"))
        #expect(source.guardReads == ["pulls \(Self.parentBranch)"])
    }

    @Test(
        "Anything else is a broken stack naming what was seen",
        arguments: [
            ([], "no pull request is from f/6-parent"),
            (
                [BranchPullRequest(number: 6, open: false, mergeCommit: nil)],
                "from f/6-parent, PR #6 closed without merging"
            ),
            (
                [BranchPullRequest(number: 6, open: false, mergeCommit: "m1", base: "f/5-first")],
                "from f/6-parent, PR #6 merged into f/5-first"
            ),
            (
                [
                    BranchPullRequest(number: 6, open: true, mergeCommit: nil),
                    BranchPullRequest(number: 9, open: true, mergeCommit: nil),
                ],
                "from f/6-parent, PR #6 is open, PR #9 is open"
            ),
            (
                [
                    BranchPullRequest(number: 6, open: false, mergeCommit: "m1"),
                    BranchPullRequest(number: 9, open: false, mergeCommit: nil),
                ],
                "from f/6-parent, PR #6 merged into main, PR #9 closed without merging"
            ),
            (
                [
                    BranchPullRequest(number: 6, open: false, mergeCommit: "m1"),
                    BranchPullRequest(number: 9, open: false, mergeCommit: "m2", base: "f/5-first"),
                ],
                "from f/6-parent, PR #6 merged into main, PR #9 merged into f/5-first"
            ),
            (
                [
                    BranchPullRequest(number: 6, open: false, mergeCommit: "m1"),
                    BranchPullRequest(number: 9, open: false, mergeCommit: "m2"),
                ],
                "from f/6-parent, PR #6 merged into main, PR #9 merged into main"
            ),
        ])
    func broken(_ fromBase: [BranchPullRequest], _ seen: String) throws {
        let source = FakeSourceControl()
        source.branchPulls["\(Self.repository)@\(Self.parentBranch)"] = fromBase
        #expect(try finding(source) == .broken(seen))
    }

    // MARK: The repairs

    /// Runs the repairs over #7 in `column`, whose stacked pull request is
    /// `state`, beside the parent's card.
    func repair(
        _ source: FakeSourceControl, column: String = "Agent Review", assignees: [String] = [],
        base: String = parentBranch, state: String = "dirty"
    ) throws -> (lines: [String], board: FakeBoard) {
        let board = FakeBoard()
        board.board = Board(
            items: [Self.item(7, column, assignees: assignees), Self.parentCard],
            statusFieldID: "status", optionIDs: [:], columns: [])
        board.linked[7] = [LinkedPullRequest(id: Self.child, open: true, merged: false)]
        source.merge[Self.child] = Self.childFacts(base: base, state: state)
        var lines: [String] = []
        try repairs(
            snapshot: board.board, board: board, source: source, apply: true,
            emit: { lines.append($0) })
        return (lines.filter { $0.contains("#7") }, board)
    }

    @Test(
        "A stacked pull request never gets the conflict or behind reason",
        arguments: ["dirty", "behind"])
    func stackedNoConflictOrBehind(_ state: String) throws {
        let source = FakeSourceControl()
        source.branchPulls["\(Self.repository)@\(Self.parentBranch)"] = [Self.openParent()]
        let result = try repair(source, state: state)
        #expect(result.lines == ["ok #7"])
        #expect(result.board.moves.isEmpty)
    }

    @Test(
        "A pull request into main still gets the conflict and behind reasons",
        arguments: [("dirty", "does not merge"), ("behind", "is behind main")])
    func intoMainStillRouted(_ state: String, _ reason: String) throws {
        let result = try repair(FakeSourceControl(), base: "main", state: state)
        #expect(
            result.lines == [
                "#7 -> In Progress", "MOVE #7 Agent Review → In Progress (PR #31 \(reason))",
            ])
    }

    @Test(
        "A restack sends the card back from either review column, and writes nothing else",
        arguments: ["Agent Review", "Human Review"])
    func restackSendsBack(_ column: String) throws {
        let source = FakeSourceControl()
        Self.settle(source, contained: false)
        let result = try repair(source, column: column)
        #expect(
            result.lines == [
                "#7 -> In Progress",
                "MOVE #7 \(column) → In Progress (PR #31 must restack onto a2: "
                    + "parent PR #6 settled at a2, which the head doesn't contain)",
            ])
        #expect(result.board.moves == [.init(issue: 7, to: "In Progress", from: column)])
        #expect(source.writes.isEmpty)
        #expect(result.board.posted.isEmpty)
        #expect(result.board.created.isEmpty)
    }

    @Test("A merged parent sends the card back to restack onto main and retarget")
    func mergedParentSendsBack() throws {
        let source = FakeSourceControl()
        source.branchPulls["\(Self.repository)@\(Self.parentBranch)"] = [
            BranchPullRequest(number: 6, open: false, mergeCommit: "m1")
        ]
        let result = try repair(source, state: "clean")
        #expect(
            result.lines == [
                "#7 -> In Progress",
                "MOVE #7 Agent Review → In Progress (PR #31 must restack onto main and "
                    + "retarget to main: parent PR #6 merged into main as m1)",
            ])
        #expect(source.writes.isEmpty)
        #expect(result.board.posted.isEmpty)
    }

    @Test("A broken stack sends the card back naming what was seen, and writes nothing else")
    func brokenSendsBack() throws {
        let source = FakeSourceControl()
        source.branchPulls["\(Self.repository)@\(Self.parentBranch)"] = [
            BranchPullRequest(number: 6, open: false, mergeCommit: nil)
        ]
        let result = try repair(source, column: "Human Review")
        #expect(
            result.lines == [
                "#7 -> In Progress",
                "MOVE #7 Human Review → In Progress (PR #31 has a broken stack: "
                    + "from f/6-parent, PR #6 closed without merging)",
            ])
        #expect(source.writes.isEmpty)
        #expect(result.board.posted.isEmpty)
    }

    @Test("A claimed card's parent isn't read")
    func claimedNotRead() throws {
        let source = FakeSourceControl()
        Self.settle(source, contained: false)
        let result = try repair(source, assignees: ["agent-one"])
        #expect(result.lines == ["HELD #7 by agent-one"])
        #expect(!source.guardReads.contains("pulls \(Self.parentBranch)"))
    }

    // MARK: next

    /// `next` for #7 in In Progress, its stacked pull request `dirty`, beside the
    /// parent's card.
    func next(_ source: FakeSourceControl) -> NextAnswer {
        let tests = NextTests()
        let board = tests.board([tests.item(7, "In Progress"), Self.parentCard])
        board.linked[7] = [LinkedPullRequest(id: Self.child, open: true, merged: false)]
        source.merge[Self.child] = Self.childFacts(opener: "agent-one")
        return tests.run(tests.request(roles: [.engineer]), board, source)
    }

    @Test("In Progress, a stacked pull request waiting on its parent has no findings")
    func nextWaits() throws {
        let source = FakeSourceControl()
        source.branchPulls["\(Self.repository)@\(Self.parentBranch)"] = [Self.openParent()]
        guard case .assignment(let answer) = next(source) else {
            Issue.record("expected an assignment")
            return
        }
        #expect(answer.task == "assess-existing")
        #expect(answer.findings.isEmpty)
    }

    @Test("In Progress, a restack comes through next's findings with its base")
    func nextRestack() throws {
        let source = FakeSourceControl()
        Self.settle(source, contained: false)
        guard case .assignment(let answer) = next(source) else {
            Issue.record("expected an assignment")
            return
        }
        #expect(answer.task == "address-findings")
        #expect(
            answer.findings == [
                FindingAnswer(
                    kind: "restack",
                    detail: "parent PR #6 settled at a2, which the head doesn't contain",
                    onto: "a2", retarget: false)
            ])
    }

    @Test("In Progress, a merged parent's restack says to retarget")
    func nextRetarget() throws {
        let source = FakeSourceControl()
        source.branchPulls["\(Self.repository)@\(Self.parentBranch)"] = [
            BranchPullRequest(number: 6, open: false, mergeCommit: "m1")
        ]
        guard case .assignment(let answer) = next(source) else {
            Issue.record("expected an assignment")
            return
        }
        #expect(
            answer.findings == [
                FindingAnswer(
                    kind: "restack", detail: "parent PR #6 merged into main as m1", onto: "main",
                    retarget: true)
            ])
    }

    @Test("In Progress, a broken stack comes through next's findings")
    func nextBroken() throws {
        let source = FakeSourceControl()
        guard case .assignment(let answer) = next(source) else {
            Issue.record("expected an assignment")
            return
        }
        #expect(answer.task == "address-findings")
        #expect(
            answer.findings == [
                FindingAnswer(kind: "stack-broken", detail: "no pull request is from f/6-parent")
            ])
    }
}
