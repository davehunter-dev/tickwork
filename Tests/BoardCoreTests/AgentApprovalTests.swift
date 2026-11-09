// `loop.json` read from `main`, the label-gated agent approval and native
// auto-merge: their settings, `check-loop`'s refusals, every path an `approved`
// outcome can take, and `next`'s guards.
//

import Foundation
import Testing

@testable import BoardCore

@Suite("Agent approval and auto-merge")
struct AgentApprovalTests {

    static let repository = Coordinates.repository
    static let owner = Coordinates.ownerLogin
    static let label = "agent-approvable"
    static let claimTime = ISO8601DateFormatter().date(from: "2026-10-28T13:49:02Z")!
    static let labelTime = ISO8601DateFormatter().date(from: "2026-10-28T12:00:00Z")!
    /// In the issue repository, whose ruleset `next` checks.
    static let pullRequest = PullRequestID(repository: repository, number: 31)
    static let head = "abc123"

    static func context(appliedBy: [String] = [], autoMerge: Bool = false) -> FinishContext {
        FinishContext(
            issueRepository: repository, owner: owner,
            agentApproval: AgentApproval(label: label, appliedBy: appliedBy), autoMerge: autoMerge)
    }

    /// A card in review by agent-one, its pull request opened by agent-two, green,
    /// and labelled by `labelledBy`.
    final class World {
        let board = FakeBoard()
        let source = FakeSourceControl()
        var log: [String] = []

        init(labelledBy: String? = AgentApprovalTests.owner, opener: String = "agent-two") {
            board.board = Board(
                items: [
                    Item(
                        id: "item-7", number: 7, title: "Issue 7", status: "Agent Review",
                        assignees: ["agent-one"])
                ],
                statusFieldID: "status", optionIDs: [:], columns: [])
            board.labels[7] =
                ["type:feature"] + (labelledBy == nil ? [] : [AgentApprovalTests.label])
            board.events[7] =
                (labelledBy.map {
                    [
                        TimelineEvent(
                            kind: .labeled, actor: $0, subject: AgentApprovalTests.label,
                            createdAt: AgentApprovalTests.labelTime)
                    ]
                } ?? [])
                + [
                    TimelineEvent(
                        kind: .assigned, actor: "agent-one", subject: "agent-one",
                        createdAt: AgentApprovalTests.claimTime)
                ]
            board.linked[7] = [
                LinkedPullRequest(id: AgentApprovalTests.pullRequest, open: true, merged: false)
            ]
            source.merge[AgentApprovalTests.pullRequest] = MergeFacts(
                headSHA: AgentApprovalTests.head, branch: "f/7-work", mergeable: true,
                mergeableState: "blocked", draft: false, opener: opener)
            board.onWrite = { [unowned self] in self.log.append($0) }
            source.onWrite = { [unowned self] in self.log.append($0) }
        }

        func finish(_ context: FinishContext) -> FinishAnswer {
            BoardCore.finish(
                AgentApprovalTests.approved, board: board, source: source, context: context)
        }
    }

    static let approved: FinishRequest = {
        var request = FinishRequest(
            token: ClaimToken(
                login: "agent-one", repository: repository, issue: 7, role: .reviewer,
                task: .review, column: "Agent Review", claimedAt: claimTime),
            outcome: .approved)
        request.pullRequest = pullRequest
        request.head = head
        request.body = "Checked every criterion."
        return request
    }()

    static let ref = "\(repository)#31"
    static let toOwner = [
        "assign \(ref) \(owner)", "request \(ref) \(owner)", "move #7 Agent Review → Human Review",
    ]

    // MARK: Settings

    @Test("Both features are off when loop.json leaves them out")
    func offByDefault() throws {
        let configuration = try JSONDecoder().decode(
            LoopConfiguration.self, from: Data(NextTests.arrangement.utf8))
        #expect(configuration.agentApproval == nil)
        #expect(!configuration.autoMerge)
    }

    @Test("review.agentApproval and merge.auto are read, appliedBy defaulting to none")
    func settingsRead() throws {
        let json = NextTests.arrangement.replacingOccurrences(
            of: "\"agents\":",
            with: """
                "review": { "agentApproval": { "label": "agent-approvable" } },
                "merge": { "auto": true, "method": "squash" },
                "agents":
                """)
        let configuration = try JSONDecoder().decode(LoopConfiguration.self, from: Data(json.utf8))
        #expect(configuration.agentApproval == AgentApproval(label: "agent-approvable"))
        #expect(configuration.autoMerge)
    }

    @Test("The owner's labelling always counts, and appliedBy adds to it")
    func whoCounts() {
        let approval = AgentApproval(label: Self.label, appliedBy: ["agent-two"])
        #expect(approval.counts(Self.owner, owner: Self.owner))
        #expect(approval.counts("agent-two", owner: Self.owner))
        #expect(!approval.counts("agent-one", owner: Self.owner))
        #expect(!approval.counts(nil, owner: Self.owner))
        #expect(!AgentApproval(label: Self.label).counts("agent-two", owner: Self.owner))
    }

    @Test("The arrangement comes from main, and a missing one is an error, not a fallback")
    func fromMain() throws {
        let configuration = try LoopConfiguration.fromMain { NextTests.arrangement }
        #expect(configuration.repository == Self.repository)
        #expect(throws: BoardError.self) { try LoopConfiguration.fromMain { "" } }
    }

    @Test("check-loop refuses each malformed setting, by path")
    func checkLoopRefuses() throws {
        func problems(_ settings: String) throws -> [String] {
            let json = NextTests.arrangement.replacingOccurrences(
                of: "\"agents\":", with: settings + ",\n  \"agents\":")
            let document = try JSONDecoder().decode(JSON.self, from: Data(json.utf8)).object ?? [:]
            return loopProblems(in: document)
        }
        let merging = #", "merge": { "auto": true, "method": "squash" }"#
        #expect(
            try problems(
                #""review": { "agentApproval": { "label": "go" }, "skip": true }"# + merging)
                == ["review.skip: not a key it takes (agentApproval)"])
        #expect(
            try problems(
                #""review": { "agentApproval": { "appliedBy": ["agent-two"] } }"# + merging)
                == ["review.agentApproval.label: missing, or not a non-empty string"])
        #expect(
            try problems(
                #""review": { "agentApproval": { "label": "go", "appliedBy": "agent-two" } }"#
                    + merging)
                == ["review.agentApproval.appliedBy: not an array of logins"])
        #expect(
            try problems(#""merge": { "auto": true, "method": "rebase" }"#)
                == ["merge.method: missing, or not squash, the one method Tickwork sets"])
        #expect(
            try problems(#""merge": { "auto": "yes", "method": "squash" }"#)
                == ["merge.auto: missing, or not true or false"])
        #expect(try problems(#""merge": { "auto": false, "method": "squash" }"#).isEmpty)
        #expect(
            try problems(#""review": { "agentApproval": { "label": "go" } }"#)
                == ["review.agentApproval: needs merge.auto true, which lands what it approves"])
        #expect(
            try problems(
                #""review": { "agentApproval": { "label": "go" } }, "merge": { "auto": false, "method": "squash" }"#
            ) == ["review.agentApproval: needs merge.auto true, which lands what it approves"])
        #expect(
            try problems(#""review": { "agentApproval": { "label": "go" } }"# + merging).isEmpty)
    }

    // MARK: Rules

    @Test("A ruleset's rules for main are read, strictest of each kind")
    func rulesRead() throws {
        let rules = try branchRules(
            rulesJSON: """
                [
                  {"type": "pull_request", "parameters": {"required_approving_review_count": 1,
                    "require_code_owner_review": true, "require_last_push_approval": true}},
                  {"type": "required_status_checks", "parameters": {
                    "required_status_checks": [{"context": "fixture-validation"}]}},
                  {"type": "deletion"}
                ]
                """)
        #expect(rules.shortfalls.isEmpty)
        #expect(
            BranchRules().shortfalls == [
                "no approval is required", "a code owner's review is not required",
                "the last push need not be approved", "no status check is required",
            ])
    }

    // MARK: finish approved

    @Test("An independent, green, owner-labelled review approves and leaves the card to merge")
    func agentApproves() {
        let world = World()
        guard case .finished(let answer) = world.finish(Self.context()) else {
            Issue.record("expected finished: \(world.finish(Self.context()))")
            return
        }
        #expect(world.log == ["approve \(Self.ref)", "release #7"])
        #expect(answer.done == ["approve \(Self.ref)", "release"])
        let review = world.source.reviews[Self.pullRequest]?.last
        #expect(review?.state == "APPROVED")
        #expect(review?.commit == Self.head)
        #expect(review?.body.hasSuffix(finishMarker(.approved, Self.approved.token)) == true)
    }

    @Test(
        "Without the reviewed commit, or once a push has moved the head, the owner reviews it",
        arguments: [nil, "def456"])
    func headNotReviewed(_ head: String?) {
        let world = World()
        var request = Self.approved
        request.head = head
        guard
            case .finished = BoardCore.finish(
                request, board: world.board, source: world.source, context: Self.context())
        else {
            Issue.record("expected finished")
            return
        }
        #expect(world.log == ["comment \(Self.ref)"] + Self.toOwner + ["release #7"])
        #expect(world.source.reviews[Self.pullRequest] == nil)
    }

    @Test("A re-run after a push proves the approval of the reviewed commit, and approves nothing")
    func rerunAfterPush() {
        let world = World()
        world.board.failing = ["release"]
        guard case .incomplete = world.finish(Self.context()) else {
            Issue.record("expected incomplete")
            return
        }
        world.board.failing = []
        world.source.merge[Self.pullRequest] = MergeFacts(
            headSHA: "def456", branch: "f/7-work", mergeable: true, mergeableState: "blocked",
            draft: false, opener: "agent-two")
        world.source.checks["\(Self.repository)@def456"] = CheckFacts()
        guard case .finished = world.finish(Self.context()) else {
            Issue.record("expected finished")
            return
        }
        #expect(world.source.reviews[Self.pullRequest]?.map(\.commit) == [Self.head])
        #expect(world.log == ["approve \(Self.ref)", "release #7"])
    }

    @Test("--head belongs to an approved review alone")
    func headOnlyForApproved() {
        let world = World()
        var request = Self.approved
        request = FinishRequest(token: request.token, outcome: .changesRequested)
        request.pullRequest = Self.pullRequest
        request.body = "One finding."
        request.head = Self.head
        guard
            case .rejected(let answer) = BoardCore.finish(
                request, board: world.board, source: world.source, context: Self.context())
        else {
            Issue.record("expected rejected")
            return
        }
        #expect(answer.message.contains("--head"))
    }

    @Test("With auto-merge on, the agent's approval sets it")
    func agentApprovesAndMerges() {
        let world = World()
        guard case .finished = world.finish(Self.context(autoMerge: true)) else {
            Issue.record("expected finished")
            return
        }
        #expect(world.log == ["approve \(Self.ref)", "auto-merge \(Self.ref)", "release #7"])
    }

    @Test("When GitHub still wants a code owner after the agent approves, the owner reviews it")
    func decisionFallsBack() {
        let world = World()
        world.source.decisionAfterApproval[Self.pullRequest] = "REVIEW_REQUIRED"
        guard case .finished = world.finish(Self.context()) else {
            Issue.record("expected finished")
            return
        }
        #expect(world.log == ["approve \(Self.ref)"] + Self.toOwner + ["release #7"])
    }

    @Test(
        "Each unmet condition leaves today's owner review",
        arguments: ["unlabelled", "labelled by an agent", "its opener reviewing", "a red check"])
    func ownerPath(_ condition: String) {
        let world: World
        switch condition {
        case "unlabelled": world = World(labelledBy: nil)
        case "labelled by an agent": world = World(labelledBy: "agent-two")
        case "its opener reviewing": world = World(opener: "agent-one")
        default:
            world = World()
            world.source.checks["\(Self.repository)@\(Self.head)"] = CheckFacts(failing: [
                "Required"
            ])
        }
        guard case .finished = world.finish(Self.context()) else {
            Issue.record("expected finished: \(condition)")
            return
        }
        #expect(
            world.log == ["comment \(Self.ref)"] + Self.toOwner + ["release #7"], "\(condition)")
        #expect(world.source.reviews[Self.pullRequest] == nil, "\(condition)")
    }

    @Test("A label applied by a login appliedBy names opens the path")
    func appliedByCounts() {
        let world = World(labelledBy: "agent-two")
        guard case .finished = world.finish(Self.context(appliedBy: ["agent-two"])) else {
            Issue.record("expected finished")
            return
        }
        #expect(world.log == ["approve \(Self.ref)", "release #7"])
    }

    @Test(
        "A pull request in another repository goes to the owner, without auto-merge"
    )
    func otherRepository() {
        let world = World()
        let elsewhere = PullRequestID(repository: "example-org/fixtures", number: 31)
        world.board.linked[7] = [LinkedPullRequest(id: elsewhere, open: true, merged: false)]
        world.source.merge[elsewhere] = world.source.merge[Self.pullRequest]
        var request = Self.approved
        request.pullRequest = elsewhere
        guard
            case .finished = BoardCore.finish(
                request, board: world.board, source: world.source,
                context: Self.context(autoMerge: true))
        else {
            Issue.record("expected finished")
            return
        }
        #expect(world.source.reviews[elsewhere] == nil)
        #expect(!world.log.contains("auto-merge example-org/fixtures#31"))
        #expect(world.log.first == "comment example-org/fixtures#31")
    }

    @Test("Auto-merge on the owner's path is set as the card moves to them")
    func ownerPathMerges() {
        let world = World(labelledBy: nil)
        guard case .finished = world.finish(Self.context(autoMerge: true)) else {
            Issue.record("expected finished")
            return
        }
        #expect(
            world.log == ["comment \(Self.ref)"] + Self.toOwner + [
                "auto-merge \(Self.ref)", "release #7",
            ])
    }

    @Test("Running finish again after the agent's approval repeats nothing")
    func rerun() {
        let world = World()
        _ = world.finish(Self.context(autoMerge: true))
        let first = world.log
        guard case .finished = world.finish(Self.context(autoMerge: true)) else {
            Issue.record("expected finished")
            return
        }
        #expect(world.log == first)
        #expect(world.source.reviews[Self.pullRequest]?.count == 1)
    }

    // MARK: next

    func nextAnswer(_ settings: String, source: FakeSourceControl) -> NextAnswer {
        let arrangement = NextTests.arrangement.replacingOccurrences(
            of: "\"agents\":", with: settings + ",\n  \"agents\":")
        let board = FakeBoard()
        board.board = Board(
            items: [], statusFieldID: "status", optionIDs: [:],
            columns: Workflow.standard.columns.all)
        return next(
            NextRequest(arrangementJSON: arrangement, roles: nil, preview: true, revision: nil),
            board: board, source: source, runRepairs: { [] })
    }

    static let approvalSettings =
        #""review": { "agentApproval": { "label": "agent-approvable" } }, "merge": { "auto": true, "method": "squash" }"#

    @Test("next stops at unsafe-ruleset when main's rules are weaker or can't be read")
    func unsafeRuleset() {
        let weak = FakeSourceControl()
        weak.rules[Self.repository] = BranchRules(requiredApprovals: 1, requiredChecks: 1)
        guard case .error(let answer) = nextAnswer(Self.approvalSettings, source: weak) else {
            Issue.record("expected an error")
            return
        }
        #expect(answer.stage == .unsafeRuleset)
        #expect(answer.message.contains("a code owner's review is not required"))

        let unreadable = FakeSourceControl()
        unreadable.unreadableRules = [Self.repository]
        guard case .error(let other) = nextAnswer(Self.approvalSettings, source: unreadable) else {
            Issue.record("expected an error")
            return
        }
        #expect(other.stage == .unsafeRuleset)
    }

    @Test("next stops at config when merge.auto is on and the repository forbids auto-merge")
    func autoMergeForbidden() {
        let source = FakeSourceControl()
        source.autoMergeAllowed[Self.repository] = false
        guard
            case .error(let answer) = nextAnswer(
                #""merge": { "auto": true, "method": "squash" }"#, source: source)
        else {
            Issue.record("expected an error")
            return
        }
        #expect(answer.stage == .config)
    }

    @Test("A safe ruleset and allowed auto-merge let next carry on")
    func safeSettings() {
        let answer = nextAnswer(
            Self.approvalSettings,
            source: FakeSourceControl())
        if case .error(let error) = answer {
            Issue.record("expected no error: \(error)")
        }
    }

    // MARK: select

    @Test("A card whose head carries an agent's approval is skipped as merging")
    func merging() {
        var card = CardFacts(number: 7, column: "Agent Review", assignees: [], isDesign: false)
        card.pullRequests = [LinkedPullRequest(id: Self.pullRequest, open: true, merged: false)]
        card.agentApproved = [Self.pullRequest]
        let selection = select(
            from: [card],
            agent: SelectingAgent(login: "agent-one", roles: [.reviewer]))
        #expect(selection.pick == nil)
        #expect(selection.skipped == [Skip(issue: 7, reason: .merging, detail: nil)])
    }
}
