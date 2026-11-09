// The merge guard, on its own and on each merge path: the `MERGE` repair,
// `finish approved`'s auto-merge and the agent-approved path.
//

import Foundation
import Testing

@testable import BoardCore

@Suite("The merge guard")
struct MergeGuardTests {

    static let repository = Coordinates.repository
    static let pullRequest = PullRequestID(repository: repository, number: 31)
    static let ref = "\(repository)#31"
    static let head = "abc123"
    static let parentBranch = "f/6-parent"
    static let parentMerge = "m1"

    static func facts(base: String = "main", state: String = "clean") -> MergeFacts {
        MergeFacts(
            headSHA: head, branch: "f/7-work", mergeable: true, mergeableState: state,
            draft: false, opener: "agent-two", base: base)
    }

    /// A former parent from `parentBranch`, in the state given.
    static func retargeted(_ source: FakeSourceControl, parent: BranchPullRequest) {
        source.formerBases[pullRequest] = [parentBranch]
        source.branchPulls["\(repository)@\(parentBranch)"] = [parent]
    }

    static let openParent = BranchPullRequest(number: 6, open: true, mergeCommit: nil)
    static let mergedParent = BranchPullRequest(number: 6, open: false, mergeCommit: parentMerge)
    static let abandonedParent = BranchPullRequest(number: 6, open: false, mergeCommit: nil)

    func verdict(_ source: FakeSourceControl, board: FakeBoard = FakeBoard(), base: String = "main")
        throws -> MergeGuardVerdict
    {
        try mergeGuard(
            Self.pullRequest, merge: Self.facts(base: base), board: board, source: source)
    }

    // MARK: The guard

    @Test("A base other than main is held, with nothing read")
    func notMain() throws {
        let source = FakeSourceControl()
        #expect(
            try verdict(source, base: "f/6-parent") == .held("its base is f/6-parent, not main"))
        #expect(source.guardReads.isEmpty)
    }

    @Test("A pull request never retargeted passes on the one query")
    func neverRetargeted() throws {
        let source = FakeSourceControl()
        #expect(try verdict(source) == .passes)
        #expect(source.guardReads == ["bases #31"])
    }

    @Test("An open former parent holds it, with no compare")
    func openParentHolds() throws {
        let source = FakeSourceControl()
        Self.retargeted(source, parent: Self.openParent)
        #expect(try verdict(source) == .held("former parent PR #6 is open"))
        #expect(source.guardReads == ["bases #31", "pulls \(Self.parentBranch)"])
    }

    @Test("A merged former parent the head contains passes")
    func containedPasses() throws {
        let source = FakeSourceControl()
        Self.retargeted(source, parent: Self.mergedParent)
        #expect(try verdict(source) == .passes)
        #expect(
            source.guardReads == [
                "bases #31", "pulls \(Self.parentBranch)",
                "compare \(Self.parentMerge)...\(Self.head)",
            ])
    }

    @Test("A merged former parent the head doesn't contain is a restack")
    func uncontainedRestacks() throws {
        let source = FakeSourceControl()
        Self.retargeted(source, parent: Self.mergedParent)
        source.behind["\(Self.repository)@\(Self.parentMerge)...\(Self.head)"] = 2
        #expect(
            try verdict(source)
                == .restack("former parent PR #6 merged as m1, which the head doesn't contain"))
    }

    @Test("A former parent closed without merging is ignored")
    func abandonedIgnored() throws {
        let source = FakeSourceControl()
        Self.retargeted(source, parent: Self.abandonedParent)
        #expect(try verdict(source) == .passes)
        #expect(source.guardReads == ["bases #31", "pulls \(Self.parentBranch)"])
    }

    @Test("Below readReserve the query is refused and the pull request held")
    func budgetRefused() throws {
        let source = FakeSourceControl()
        let board = FakeBoard()
        board.budgetRemaining = readReserve - 1
        guard case .held(let reason) = try verdict(source, board: board) else {
            Issue.record("expected held")
            return
        }
        #expect(reason.contains("former bases aren't read"))
        #expect(source.guardReads.isEmpty)
    }

    @Test("Former bases are read from both kinds of base change, across pages")
    func bothEventTypes() throws {
        let json = """
            [{"data": {"repository": {"pullRequest": {"timelineItems": {
              "pageInfo": {"hasNextPage": true, "endCursor": "x"},
              "nodes": [{"previousRefName": "f/5-first"}]}}}}},
             {"data": {"repository": {"pullRequest": {"timelineItems": {
              "pageInfo": {"hasNextPage": false, "endCursor": null},
              "nodes": [{"oldBase": "f/6-parent"}]}}}}}]
            """
        #expect(try formerBases(timelineJSON: json) == ["f/5-first", "f/6-parent"])
    }

    @Test("A pulls?head= answer names each pull request's state, merge commit, head and base")
    func branchPullsParsed() throws {
        let json = """
            [[{"number": 6, "state": "closed", "merged_at": "2026-10-28T12:00:00Z", "merge_commit_sha": "m1",
               "head": {"sha": "a2"}, "base": {"ref": "main"}, "draft": false, "body": "Closes #6."},
              {"number": 5, "state": "closed", "merged_at": null, "merge_commit_sha": "t1",
               "head": {"sha": "a1"}, "base": {"ref": "f/4-first"}, "draft": false, "body": null},
              {"number": 8, "state": "open", "merged_at": null, "merge_commit_sha": "t2",
               "head": {"sha": "a3"}, "base": {"ref": "main"}, "draft": true, "body": ""}]]
            """
        #expect(
            try branchPullRequests(pullsJSON: json) == [
                BranchPullRequest(
                    number: 6, open: false, mergeCommit: "m1", head: "a2", body: "Closes #6."),
                BranchPullRequest(
                    number: 5, open: false, mergeCommit: nil, head: "a1", base: "f/4-first"),
                BranchPullRequest(number: 8, open: true, mergeCommit: nil, head: "a3", draft: true),
            ])
    }

    @Test("The pull request read names its base")
    func baseRead() throws {
        let json = """
            {"head": {"sha": "abc123", "ref": "f/7-work"}, "base": {"ref": "f/6-parent"}, "user": {"login": "agent-one"}, "mergeable": true, "mergeable_state": "clean"}
            """
        #expect(try mergeFacts(pullJSON: json).base == "f/6-parent")
    }

    // MARK: The MERGE repair

    /// Runs the repairs over a card in `column`, Human Review unless given, whose
    /// pull request is `state`, clean unless given, with auto-merge set if
    /// `autoMerge`. Pass `board` to run them again over the same board.
    func repair(
        _ source: FakeSourceControl, board: FakeBoard? = nil, base: String = "main",
        budget: Int = 5_000, state: String = "clean", autoMerge: Bool = false,
        column: String = "Human Review", assignees: [String] = []
    ) throws -> (lines: [String], moves: [FakeBoard.Move]) {
        let board =
            board
            ?? {
                let board = FakeBoard()
                board.board = Board(
                    items: [
                        Item(
                            id: "a", number: 7, title: "Seven", status: column,
                            assignees: assignees)
                    ],
                    statusFieldID: "status", optionIDs: [:], columns: [])
                return board
            }()
        board.budgetRemaining = budget
        board.linked[7] = [LinkedPullRequest(id: Self.pullRequest, open: true, merged: false)]
        source.merge[Self.pullRequest] = Self.facts(base: base, state: state)
        source.merge[Self.pullRequest]?.autoMergeSetOrMerged = autoMerge
        var lines: [String] = []
        try repairs(
            snapshot: board.board, board: board, source: source, apply: true,
            emit: { lines.append($0) })
        return (lines, board.moves)
    }

    @Test("The MERGE repair prints a guarded pull request for merging")
    func repairMerges() throws {
        let source = FakeSourceControl()
        Self.retargeted(source, parent: Self.mergedParent)
        #expect(try repair(source).lines == ["MERGE #7 PR #31 is clean"])
    }

    @Test("The MERGE repair never merges a pull request whose base isn't main")
    func repairNotMain() throws {
        // Its parent is open and unsettled, so the restack repair has nothing to say.
        let source = FakeSourceControl()
        source.branchPulls["\(Self.repository)@f/6-parent"] = [Self.openParent]
        let result = try repair(source, base: "f/6-parent")
        #expect(result.lines == ["REPORT #7 PR #31 is held: its base is f/6-parent, not main"])
        #expect(result.moves.isEmpty)
    }

    @Test("An open former parent holds the card and moves nothing")
    func repairHolds() throws {
        let source = FakeSourceControl()
        Self.retargeted(source, parent: Self.openParent)
        let result = try repair(source)
        #expect(result.lines == ["REPORT #7 PR #31 is held: former parent PR #6 is open"])
        #expect(result.moves.isEmpty)
    }

    @Test("An uncontained merged former parent sends the card back to restack onto main")
    func repairSendsBack() throws {
        let source = FakeSourceControl()
        Self.retargeted(source, parent: Self.mergedParent)
        source.behind["\(Self.repository)@\(Self.parentMerge)...\(Self.head)"] = 1
        let result = try repair(source)
        #expect(
            result.lines == [
                "#7 -> In Progress",
                "MOVE #7 Human Review → In Progress (PR #31 must restack onto main: "
                    + "former parent PR #6 merged as m1, which the head doesn't contain)",
            ])
        #expect(result.moves == [.init(issue: 7, to: "In Progress", from: "Human Review")])
    }

    @Test("A pull request sent back to work has its armed auto-merge turned off before the move")
    func repairUnarmsBeforeSendingBack() throws {
        let source = FakeSourceControl()
        let board = Self.agentReviewBoard()
        var log: [String] = []
        source.onWrite = { log.append($0) }
        board.onWrite = { log.append($0) }
        let result = try repair(source, board: board, state: "behind", autoMerge: true)
        #expect(
            result.lines == [
                "#7 -> In Progress",
                "UNARM #7 auto-merge on PR #31 (PR #31 is behind main)",
                "MOVE #7 Agent Review → In Progress (PR #31 is behind main)",
            ])
        #expect(
            log == [
                "disable auto-merge \(Self.repository)#31", "move #7 Agent Review → In Progress",
            ])
    }

    @Test("A pull request sent back to work with auto-merge off makes no disable write")
    func repairSendsBackUnarmed() throws {
        let source = FakeSourceControl()
        let result = try repair(source, state: "behind")
        #expect(result.moves == [.init(issue: 7, to: "In Progress", from: "Human Review")])
        #expect(source.writes.isEmpty)
    }

    @Test("A dry run that would send an armed pull request back writes nothing")
    func repairDryRunUnarmsNothing() throws {
        let source = FakeSourceControl()
        let board = Self.agentReviewBoard()
        board.linked[7] = [LinkedPullRequest(id: Self.pullRequest, open: true, merged: false)]
        source.merge[Self.pullRequest] = Self.facts(state: "behind")
        source.merge[Self.pullRequest]?.autoMergeSetOrMerged = true
        var lines: [String] = []
        try repairs(
            snapshot: board.board, board: board, source: source, apply: false,
            emit: { lines.append($0) })
        #expect(
            lines == [
                "UNARM #7 auto-merge on PR #31 (PR #31 is behind main)",
                "MOVE #7 Agent Review → In Progress (PR #31 is behind main)",
            ])
        #expect(source.writes.isEmpty)
        #expect(board.moves.isEmpty)
    }

    @Test("Auto-merge set on a pull request the guard sends back is turned off first")
    func repairUnarmsBeforeRestack() throws {
        let source = FakeSourceControl()
        Self.retargeted(source, parent: Self.mergedParent)
        source.behind["\(Self.repository)@\(Self.parentMerge)...\(Self.head)"] = 1
        let result = try repair(source, state: "blocked", autoMerge: true)
        let reason = "former parent PR #6 merged as m1, which the head doesn't contain"
        #expect(
            result.lines == [
                "#7 -> In Progress",
                "UNARM #7 auto-merge on PR #31 (\(reason))",
                "MOVE #7 Human Review → In Progress (PR #31 must restack onto main: \(reason))",
            ])
        #expect(source.writes == ["disable auto-merge #31"])
    }

    /// A board holding #7 in Agent Review, assigned to `assignees`.
    static func agentReviewBoard(assignees: [String] = []) -> FakeBoard {
        let board = FakeBoard()
        board.board = Board(
            items: [
                Item(
                    id: "a", number: 7, title: "Seven", status: "Agent Review",
                    assignees: assignees)
            ],
            statusFieldID: "status", optionIDs: [:], columns: [])
        return board
    }

    /// The loop's agent approval on the head.
    static func approveAsAgent(_ source: FakeSourceControl) {
        source.reviews[pullRequest] = [
            PullRequestReview(author: "agent-two", state: "APPROVED", commit: head, body: "")
        ]
    }

    @Test("An agent-approved card whose auto-merge is turned off goes to the owner, who lands it")
    func repairHandsAgentApprovalToOwner() throws {
        let source = FakeSourceControl()
        let board = Self.agentReviewBoard()
        Self.approveAsAgent(source)
        Self.retargeted(source, parent: Self.openParent)
        let reason = "former parent PR #6 is open"
        let held = try repair(source, board: board, state: "blocked", autoMerge: true)
        #expect(
            held.lines == [
                "#7 -> Human Review",
                "UNARM #7 auto-merge on PR #31 (\(reason))",
                "MOVE #7 Agent Review → Human Review (auto-merge on PR #31 is off: \(reason))",
            ])
        #expect(held.moves == [.init(issue: 7, to: "Human Review", from: "Agent Review")])
        #expect(
            source.writes == [
                "disable auto-merge #31", "assign #31 \(Coordinates.ownerLogin)",
                "request #31 \(Coordinates.ownerLogin)",
            ])

        // The parent closes again, and the agent's approval leaves it clean.
        Self.retargeted(source, parent: Self.abandonedParent)
        #expect(try repair(source, board: board).lines == ["MERGE #7 PR #31 is clean"])
    }

    @Test("An agent-approved card claimed when it was disarmed goes to the owner once released")
    func repairHandsOverAfterClaim() throws {
        let source = FakeSourceControl()
        Self.approveAsAgent(source)
        Self.retargeted(source, parent: Self.openParent)
        let claimed = try repair(
            source, board: Self.agentReviewBoard(assignees: ["someone"]), state: "blocked",
            autoMerge: true)
        #expect(
            claimed.lines == [
                "UNARM #7 auto-merge on PR #31 (former parent PR #6 is open)",
                "HELD #7 by someone",
            ])
        #expect(claimed.moves.isEmpty)

        // Released, with auto-merge off and the parent closed again.
        Self.retargeted(source, parent: Self.abandonedParent)
        let board = Self.agentReviewBoard()
        let released = try repair(source, board: board)
        #expect(
            released.lines == [
                "#7 -> Human Review",
                "MOVE #7 Agent Review → Human Review (auto-merge on PR #31 is off)",
            ])
        #expect(released.moves == [.init(issue: 7, to: "Human Review", from: "Agent Review")])
        #expect(try repair(source, board: board).lines == ["MERGE #7 PR #31 is clean"])
    }

    @Test("An agent-approved card in Agent Review with auto-merge already off goes to the owner")
    func repairHandsOverWithoutDisarm() throws {
        let source = FakeSourceControl()
        Self.approveAsAgent(source)
        let result = try repair(source, board: Self.agentReviewBoard())
        #expect(
            result.lines == [
                "#7 -> Human Review",
                "MOVE #7 Agent Review → Human Review (auto-merge on PR #31 is off)",
            ])
        #expect(
            source.writes == [
                "assign #31 \(Coordinates.ownerLogin)", "request #31 \(Coordinates.ownerLogin)",
            ])
    }

    @Test("An Agent Review card landing on auto-merge, or with no agent approval, stays")
    func repairLeavesAgentReview() throws {
        let landing = FakeSourceControl()
        Self.approveAsAgent(landing)
        let armed = try repair(
            landing, board: Self.agentReviewBoard(), state: "blocked", autoMerge: true)
        #expect(armed.lines == ["ok #7"])

        let unapproved = FakeSourceControl()
        Self.retargeted(unapproved, parent: Self.openParent)
        let disarmed = try repair(
            unapproved, board: Self.agentReviewBoard(), state: "blocked", autoMerge: true)
        #expect(
            disarmed.lines == [
                "UNARM #7 auto-merge on PR #31 (former parent PR #6 is open)",
                "REPORT #7 PR #31 is held: former parent PR #6 is open",
            ])
        #expect(disarmed.moves.isEmpty)
    }

    @Test("A claimed card's auto-merge is turned off before the claim holds it")
    func repairUnarmsClaimed() throws {
        let source = FakeSourceControl()
        Self.retargeted(source, parent: Self.openParent)
        let owner = Coordinates.ownerLogin
        let result = try repair(source, state: "blocked", autoMerge: true, assignees: [owner])
        #expect(
            result.lines == [
                "UNARM #7 auto-merge on PR #31 (former parent PR #6 is open)",
                "HELD #7 by \(owner)",
            ])
        #expect(source.writes == ["disable auto-merge #31"])
        #expect(result.moves.isEmpty)
    }

    @Test("Auto-merge on a pull request the guard passes is left alone, clean or not")
    func repairLeavesPassingAutoMerge() throws {
        let source = FakeSourceControl()
        #expect(try repair(source, state: "blocked", autoMerge: true).lines == ["ok #7"])
        #expect(source.guardReads == ["bases #31"])
        #expect(source.writes.isEmpty)
    }

    @Test("A blocked pull request without auto-merge pays no guard read")
    func repairBlockedReadsNothing() throws {
        let source = FakeSourceControl()
        Self.retargeted(source, parent: Self.openParent)
        #expect(try repair(source, state: "blocked").lines == ["ok #7"])
        #expect(source.guardReads.isEmpty)
    }

    @Test("Below readReserve nothing merges on that pass")
    func repairBudget() throws {
        let source = FakeSourceControl()
        let result = try repair(source, budget: readReserve - 1)
        #expect(result.lines.count == 1)
        #expect(result.lines.first?.hasPrefix("REPORT #7 PR #31 is held: ") == true)
        #expect(source.guardReads.isEmpty)
    }

    // MARK: finish approved

    static let approved: FinishRequest = {
        var request = FinishRequest(
            token: ClaimToken(
                login: "agent-one", repository: repository, issue: 7, role: .reviewer,
                task: .review, column: "Agent Review", claimedAt: AgentApprovalTests.claimTime),
            outcome: .approved)
        request.pullRequest = pullRequest
        request.head = head
        request.body = "Checked every criterion."
        return request
    }()

    /// What `finish approved` wrote, through auto-merge alone or the agent path.
    func approve(agentPath: Bool, base: String = "main", arrange: (FakeSourceControl) -> Void)
        -> [String]
    {
        let world = AgentApprovalTests.World()
        world.source.merge[Self.pullRequest] = MergeFacts(
            headSHA: Self.head, branch: "f/7-work", mergeable: true, mergeableState: "blocked",
            draft: false, opener: "agent-two", base: base)
        arrange(world.source)
        let context =
            agentPath
            ? AgentApprovalTests.context(autoMerge: true)
            : FinishContext(
                issueRepository: Self.repository, owner: Coordinates.ownerLogin, autoMerge: true)
        guard
            case .finished = BoardCore.finish(
                Self.approved, board: world.board, source: world.source, context: context)
        else {
            Issue.record("expected finished")
            return []
        }
        return world.log
    }

    static let toOwner = [
        "assign \(ref) \(Coordinates.ownerLogin)", "request \(ref) \(Coordinates.ownerLogin)",
        "move #7 Agent Review → Human Review",
    ]

    @Test(
        "finish approved neither auto-merges nor agent-approves what the guard stops",
        arguments: [false, true], ["not main", "open parent", "uncontained parent"])
    func finishGuarded(_ agentPath: Bool, _ stop: String) {
        let log = approve(agentPath: agentPath, base: stop == "not main" ? "f/6-parent" : "main") {
            source in
            switch stop {
            case "open parent":
                Self.retargeted(source, parent: Self.openParent)
            case "uncontained parent":
                Self.retargeted(source, parent: Self.mergedParent)
                source.behind["\(Self.repository)@\(Self.parentMerge)...\(Self.head)"] = 1
            default: break
            }
        }
        #expect(log == ["comment \(Self.ref)"] + Self.toOwner + ["release #7"], "\(stop)")
    }

    @Test("An agent approval already on the head goes to the owner when the guard stops it")
    func finishGuardedAfterApproval() {
        let marker = finishMarker(.approved, Self.approved.token)
        let log = approve(agentPath: true) { source in
            Self.retargeted(source, parent: Self.openParent)
            source.reviews[Self.pullRequest] = [
                PullRequestReview(
                    author: "agent-one", state: "APPROVED", commit: Self.head,
                    body: "Checked every criterion.\n\(marker)")
            ]
            source.decision[Self.pullRequest] = "APPROVED"
        }
        #expect(log == Self.toOwner + ["release #7"])
    }

    @Test(
        "finish approved auto-merges, on either path, what the guard passes",
        arguments: [false, true])
    func finishPasses(_ agentPath: Bool) {
        let log = approve(agentPath: agentPath) { Self.retargeted($0, parent: Self.mergedParent) }
        #expect(
            log
                == (agentPath
                    ? ["approve \(Self.ref)", "auto-merge \(Self.ref)", "release #7"]
                    : ["comment \(Self.ref)"] + Self.toOwner + [
                        "auto-merge \(Self.ref)", "release #7",
                    ]))
    }

    @Test("Auto-merge set while a former parent was closed is turned off when it reopens")
    func reopenedParentUnarms() throws {
        let world = AgentApprovalTests.World()
        world.source.merge[Self.pullRequest] = Self.facts(state: "blocked")
        Self.retargeted(world.source, parent: Self.abandonedParent)
        let context = FinishContext(
            issueRepository: Self.repository, owner: Coordinates.ownerLogin, autoMerge: true)
        guard
            case .finished = BoardCore.finish(
                Self.approved, board: world.board, source: world.source, context: context)
        else {
            Issue.record("expected finished")
            return
        }
        #expect(world.log.contains("auto-merge \(Self.ref)"))

        world.source.branchPulls["\(Self.repository)@\(Self.parentBranch)"] = [Self.openParent]
        var lines: [String] = []
        try repairs(
            snapshot: world.board.board, board: world.board, source: world.source, apply: true,
            emit: { lines.append($0) })
        #expect(
            lines == [
                "UNARM #7 auto-merge on PR #31 (former parent PR #6 is open)",
                "REPORT #7 PR #31 is held: former parent PR #6 is open",
            ])
        #expect(world.source.writes.last == "disable auto-merge #31")
        #expect(world.source.merge[Self.pullRequest]?.autoMergeSetOrMerged == false)
    }

    @Test(
        "finish approved reads no guard where neither merge path can act",
        arguments: ["no head", "another repository"])
    func finishSkipsGuard(_ case: String) {
        let world = AgentApprovalTests.World()
        var request = Self.approved
        var context = AgentApprovalTests.context()
        if `case` == "no head" {
            request.head = nil
        } else {
            let elsewhere = PullRequestID(repository: "example-org/elsewhere", number: 31)
            request.pullRequest = elsewhere
            world.board.linked[7] = [LinkedPullRequest(id: elsewhere, open: true, merged: false)]
            world.source.merge[elsewhere] = Self.facts()
            context = AgentApprovalTests.context(autoMerge: true)
        }
        Self.retargeted(world.source, parent: Self.openParent)
        guard
            case .finished = BoardCore.finish(
                request, board: world.board, source: world.source, context: context)
        else {
            Issue.record("expected finished")
            return
        }
        #expect(world.source.guardReads.isEmpty, "\(`case`)")
        #expect(!world.log.contains { $0.hasPrefix("auto-merge") || $0.hasPrefix("approve") })
    }

    // MARK: The merge verb

    @Test("The merge verb merges a guarded pull request at the head it read")
    func verbMerges() throws {
        let source = FakeSourceControl()
        source.merge[Self.pullRequest] = Self.facts()
        Self.retargeted(source, parent: Self.mergedParent)
        #expect(
            try guardedMerge(Self.pullRequest, board: FakeBoard(), source: source)
                == "merged PR #31 at \(Self.head)")
        #expect(source.writes == ["merge #31 at \(Self.head)"])
    }

    @Test("The merge verb refuses a former parent that reopened after the MERGE line")
    func verbRefusesReopened() {
        let source = FakeSourceControl()
        source.merge[Self.pullRequest] = Self.facts()
        Self.retargeted(source, parent: Self.openParent)
        let error = #expect(throws: BoardError.self) {
            try guardedMerge(Self.pullRequest, board: FakeBoard(), source: source)
        }
        #expect(error?.message == "PR #31 is held: former parent PR #6 is open")
        #expect(source.writes.isEmpty)
    }

    @Test("The merge verb refuses what isn't clean before reading the guard")
    func verbRefusesUnclean() {
        let source = FakeSourceControl()
        source.merge[Self.pullRequest] = Self.facts(state: "blocked")
        let error = #expect(throws: BoardError.self) {
            try guardedMerge(Self.pullRequest, board: FakeBoard(), source: source)
        }
        #expect(error?.message == "PR #31 is blocked, not clean")
        #expect(source.guardReads.isEmpty)
        #expect(source.writes.isEmpty)
    }

    // MARK: next

    @Test(
        "An In Progress pull request with an uncontained merged former parent has a restack finding"
    )
    func nextFinding() throws {
        let tests = NextTests()
        let board = tests.board([tests.item(7, "In Progress")])
        let source = FakeSourceControl()
        let id = tests.pr(31)
        tests.link(id, to: 7, board: board, source: source, opener: "agent-one")
        source.formerBases[id] = [Self.parentBranch]
        source.branchPulls["\(id.repository)@\(Self.parentBranch)"] = [Self.mergedParent]
        source.behind["\(id.repository)@\(Self.parentMerge)...abc123"] = 1
        guard case .assignment(let answer) = tests.run(tests.request(), board, source) else {
            Issue.record("expected an assignment")
            return
        }
        #expect(answer.task == "address-findings")
        #expect(
            answer.findings == [
                FindingAnswer(
                    kind: "restack",
                    detail:
                        "former parent PR example-org/fixtures#6 merged as m1, which the head doesn't contain",
                    onto: "main", retarget: false)
            ])
    }
}
