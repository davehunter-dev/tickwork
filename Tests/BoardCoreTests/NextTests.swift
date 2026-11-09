// `next` over the fakes: each answer kind and error stage, resuming a claim, the
// claim races, `--preview`'s reads, and authorship that can't be completed.
//

import Foundation
import Testing

@testable import BoardCore

@Suite("next")
struct NextTests {

    static let repository = Coordinates.repository
    static let claimTime = ISO8601DateFormatter().date(from: "2026-10-28T13:49:02Z")!

    /// The sample `loop.json`, which `Coordinates` reads too: agent-one holds
    /// reviewer, engineer and designer, and agent-two orchestrator, reviewer and
    /// engineer.
    static let arrangement: String = {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("loop.json").path)
        {
            directory.deleteLastPathComponent()
        }
        return try! String(
            contentsOf: directory.appendingPathComponent("loop.json"), encoding: .utf8)
    }()

    func request(
        roles: Set<Role>? = nil, preview: Bool = false, arrangement: String = arrangement
    ) -> NextRequest {
        NextRequest(
            arrangementJSON: arrangement, roles: roles, preview: preview, revision: "1f0c56fb")
    }

    func item(_ number: Int, _ column: String, assignees: [String] = []) -> Item {
        Item(
            id: "item-\(number)", number: number, title: "Issue \(number)", status: column,
            assignees: assignees)
    }

    /// A board of `items`, where a claim records an `assigned` event at `claimTime`.
    func board(_ items: [Item], login: String = "agent-one") -> FakeBoard {
        let board = FakeBoard()
        board.login = login
        board.board = Board(
            items: items, statusFieldID: "status", optionIDs: [:],
            columns: Workflow.standard.columns.all)
        for item in items {
            board.events[item.number] = [
                TimelineEvent(
                    kind: .assigned, actor: login, subject: login, createdAt: Self.claimTime)
            ]
        }
        return board
    }

    func pr(_ number: Int) -> PullRequestID {
        PullRequestID(repository: "example-org/fixtures", number: number)
    }

    /// Links an open pull request to `issue`, with its facts arranged.
    func link(
        _ id: PullRequestID, to issue: Int, board: FakeBoard, source: FakeSourceControl,
        opener: String = "agent-two", mergeable: Bool = true
    ) {
        board.linked[issue] = [LinkedPullRequest(id: id, open: true, merged: false)]
        source.merge[id] = MergeFacts(
            headSHA: "abc123", branch: "f/\(issue)-work", mergeable: mergeable,
            mergeableState: mergeable ? "blocked" : "dirty", draft: false, opener: opener)
    }

    func run(
        _ request: NextRequest, _ board: FakeBoard,
        _ source: FakeSourceControl = FakeSourceControl(),
        repairs: [String] = []
    ) -> NextAnswer {
        next(request, board: board, source: source) { repairs }
    }

    // MARK: The token

    @Test("The token round-trips every field, the column URL-encoded")
    func tokenRoundTrips() throws {
        let token = ClaimToken(
            login: "agent-one", repository: "example-org/example", issue: 7, role: .engineer,
            task: .addressFindings, column: "In Progress", claimedAt: Self.claimTime)
        #expect(
            token.text
                == "tw1~agent-one~example-org/example~7~engineer~address-findings~In%20Progress~2026-10-28T13:49:02Z"
        )
        #expect(try ClaimToken(parsing: token.text) == token)
    }

    @Test("A token with a field missing or a role it doesn't know is refused")
    func badTokens() {
        #expect(throws: BoardError.self) { try ClaimToken(parsing: "tw1~agent-one~a/b~7~engineer") }
        #expect(throws: BoardError.self) {
            try ClaimToken(parsing: "tw1~agent-one~a/b~7~janitor~start~Ready~2026-10-28T13:49:02Z")
        }
    }

    // MARK: Assignments

    @Test("A fresh Ready item comes back as an assignment with the documented fields")
    func readyAssignment() throws {
        let board = board([item(7, "Ready")])
        board.labels[7] = ["type:feature", "area:build"]
        guard case .assignment(let answer) = run(request(), board) else {
            Issue.record("expected an assignment")
            return
        }
        #expect(answer.kind == "assignment")
        #expect(answer.schema == 1)
        #expect(answer.role == "engineer")
        #expect(answer.task == "start")
        #expect(!answer.resumed)
        #expect(answer.tickwork == "1f0c56fb")
        #expect(answer.budget == BudgetAnswer(remaining: 5_000, limit: 5_000))
        #expect(
            answer.issue
                == IssueAnswer(
                    number: 7, repository: Self.repository, title: "Issue 7", type: "feature",
                    labels: ["type:feature", "area:build"],
                    url: "https://github.com/\(Self.repository)/issues/7"))
        #expect(answer.pullRequest == nil)
        #expect(answer.instructions == "engineer")
        #expect(answer.outcomes == ["submitted", "blocked", "needs-human", "unable"])
        #expect(
            try ClaimToken(parsing: answer.token)
                == ClaimToken(
                    login: "agent-one", repository: Self.repository, issue: 7, role: .engineer,
                    task: .start, column: "Ready", claimedAt: Self.claimTime))
        #expect(board.moves.isEmpty)
    }

    @Test("A review lists the pull request and the reviewer's outcomes")
    func reviewAssignment() throws {
        let board = board([item(7, "Agent Review")])
        let source = FakeSourceControl()
        link(pr(31), to: 7, board: board, source: source)
        guard case .assignment(let answer) = run(request(), board, source) else {
            Issue.record("expected an assignment")
            return
        }
        #expect(answer.task == "review")
        #expect(
            answer.pullRequest
                == PullRequestAnswer(
                    ref: "example-org/fixtures#31", branch: "f/7-work", head: "abc123",
                    mergeable: true, checks: "green"))
        #expect(
            answer.outcomes == [
                "approved", "changes-requested", "blocked", "needs-human", "unable",
            ])
        #expect(answer.findings.isEmpty)
    }

    @Test(
        "An assignment's checks are red when the newest run of a check did not pass",
        arguments: [
            ("cancelled", "red"), ("stale", "red"), ("action_required", "red"),
            ("success", "green"),
        ])
    func assignmentChecksJudgeTheNewestRun(conclusion: String, checks: String) throws {
        let board = board([item(7, "Agent Review")])
        let source = FakeSourceControl()
        link(pr(31), to: 7, board: board, source: source)
        let runs = #"""
            {"check_runs": [
              {"id": 10, "name": "Required", "status": "completed", "conclusion": "success"},
              {"id": 20, "name": "Required", "status": "completed", "conclusion": "\#(conclusion)"}
            ]}
            """#
        source.checks["example-org/fixtures@abc123"] = try checkFacts(
            checkRunsJSON: runs, statusJSON: #"{"total_count": 0, "statuses": []}"#)
        guard case .assignment(let answer) = run(request(), board, source) else {
            Issue.record("expected an assignment")
            return
        }
        #expect(answer.pullRequest?.checks == checks)
    }

    @Test("Findings list the conflict, the owner's feedback and the Reviewer's marked findings")
    func findings() throws {
        let board = board([item(7, "In Progress")])
        let source = FakeSourceControl()
        let id = pr(31)
        link(id, to: 7, board: board, source: source, opener: "agent-one", mergeable: false)
        let review = "https://github.com/example-org/fixtures/pull/31#issuecomment-9"
        source.feedback[id] = [
            "https://github.com/example-org/fixtures/pull/31#pullrequestreview-1"
        ]
        source.conversation[id] = [
            ConversationComment(
                author: "agent-two", url: review, createdAt: Self.claimTime,
                body: "Two findings.\n<!-- tickwork:finish changes-requested tw1~agent-two~x -->")
        ]
        guard case .assignment(let answer) = run(request(), board, source) else {
            Issue.record("expected an assignment")
            return
        }
        #expect(answer.task == "address-findings")
        #expect(
            answer.findings == [
                FindingAnswer(kind: "conflict", detail: "does not merge with main"),
                FindingAnswer(
                    kind: "owner-feedback",
                    url: "https://github.com/example-org/fixtures/pull/31#pullrequestreview-1"),
                FindingAnswer(kind: "reviewer-findings", url: review),
            ])
    }

    @Test("A line comment stays outstanding after a push until finish names it")
    func lineCommentAnsweredByFinish() throws {
        let board = board([item(7, "In Progress")])
        let source = FakeSourceControl()
        let id = pr(31)
        link(id, to: 7, board: board, source: source, opener: "agent-one")
        let line = "https://github.com/example-org/fixtures/pull/31#discussion_r4"
        source.ownerFeedback[id] = [OwnerFeedback(url: line, createdAt: Self.claimTime)]
        guard case .assignment(let answer) = run(request(), board, source) else {
            Issue.record("expected an assignment")
            return
        }
        #expect(answer.findings == [FindingAnswer(kind: "owner-feedback", url: line)])
        board.update(7) {
            Item(
                id: $0.id, number: $0.number, title: $0.title, status: $0.status,
                assignees: ["agent-one"])
        }

        source.merge[id] = MergeFacts(
            headSHA: "def456", branch: "f/7-work", mergeable: true, mergeableState: "blocked",
            draft: false, opener: "agent-one")
        #expect(try source.unansweredFeedback(id) == [line])

        var request = FinishRequest(
            token: try ClaimToken(parsing: answer.token), outcome: .submitted)
        request.pullRequest = id
        request.body = "Fixed the line."
        request.answering = [line]
        let finished = finish(
            request, board: board, source: source,
            context: FinishContext(
                issueRepository: Self.repository, owner: Coordinates.ownerLogin))
        guard case .finished = finished else {
            Issue.record("expected finished, got \(finished)")
            return
        }
        #expect(source.conversation[id]?.last?.body.contains("Answering \(line).") == true)
        #expect(try source.unansweredFeedback(id).isEmpty)
    }

    @Test("A design pull request in In Design is left to the agent that opened it")
    func designRevisionLeftToItsOpener() {
        let board = board([item(7, "In Design"), item(8, "Ready")])
        let source = FakeSourceControl()
        link(pr(31), to: 7, board: board, source: source, opener: "agent-two")
        guard case .assignment(let answer) = run(request(), board, source) else {
            Issue.record("expected an assignment")
            return
        }
        #expect(answer.issue.number == 8)
        #expect(
            answer.skipped == [
                SkipAnswer(Skip(issue: 7, reason: .openedByAnotherAgent, detail: "agent-two"))
            ])
    }

    @Test("A submitted marker after the Reviewer's settles their findings")
    func submittedSettlesFindings() {
        let marked = { (outcome: String, url: String) in
            ConversationComment(
                author: "agent-one", url: url, createdAt: Self.claimTime,
                body: "Body\n<!-- tickwork:finish \(outcome) tw1~x -->")
        }
        #expect(
            outstandingReviewerFindings(in: [
                marked("changes-requested", "a"), marked("submitted", "b"),
            ])
                == nil)
        #expect(outstandingReviewerFindings(in: [marked("changes-requested", "a")]) == "a")
    }

    // MARK: Resuming and other logins' claims

    @Test("This agent's own claim in a working column comes back first, resumed")
    func resumesOwnClaim() throws {
        let board = board([
            item(3, "Agent Review"), item(7, "In Progress", assignees: ["agent-one"]),
        ])
        let source = FakeSourceControl()
        link(pr(30), to: 3, board: board, source: source)
        guard case .assignment(let answer) = run(request(), board, source) else {
            Issue.record("expected an assignment")
            return
        }
        #expect(answer.issue.number == 7)
        #expect(answer.resumed)
        #expect(board.released.isEmpty)
    }

    @Test("Another login's claim is skipped and named")
    func otherClaimSkipped() {
        let board = board([item(7, "Ready", assignees: ["agent-two"]), item(8, "Ready")])
        guard case .assignment(let answer) = run(request(), board) else {
            Issue.record("expected an assignment")
            return
        }
        #expect(answer.issue.number == 8)
        #expect(
            answer.skipped == [SkipAnswer(Skip(issue: 7, reason: .claimed, detail: "agent-two"))])
    }

    @Test("A lost claim race moves on to the next candidate and records the skip")
    func lostRace() {
        let board = board([item(7, "Ready"), item(8, "Ready")])
        board.claimAnswers[7] = .held(by: ["agent-one", "agent-two"])
        guard case .assignment(let answer) = run(request(), board) else {
            Issue.record("expected an assignment")
            return
        }
        #expect(answer.issue.number == 8)
        #expect(answer.skipped.map(\.reason) == ["claimed"])
    }

    @Test("A card that moved under the claim is released and skipped")
    func movedUnderTheClaim() {
        let board = board([item(7, "Ready"), item(8, "Ready")])
        board.afterClaim = { issue in
            guard issue == 7 else { return }
            board.board = Board(
                items: [self.item(7, "In Progress"), self.item(8, "Ready")],
                statusFieldID: "status", optionIDs: [:], columns: Workflow.standard.columns.all)
        }
        guard case .assignment(let answer) = run(request(), board) else {
            Issue.record("expected an assignment")
            return
        }
        #expect(answer.issue.number == 8)
        #expect(board.released.map(\.issue) == [7])
        #expect(
            answer.skipped == [
                SkipAnswer(Skip(issue: 7, reason: .moved, detail: "now in In Progress"))
            ])
    }

    // MARK: Idle

    @Test("Nothing takeable is idle, with every skip and a backoff")
    func idle() {
        let board = board([item(7, "Ready"), item(8, "Ready")])
        board.blockers[7] = [3]
        board.labels[8] = ["epic"]
        #expect(
            run(request(), board)
                == .idle(
                    IdleAnswer(
                        tickwork: "1f0c56fb", budget: BudgetAnswer(remaining: 5_000, limit: 5_000),
                        repairs: [],
                        skipped: [
                            SkipAnswer(Skip(issue: 7, reason: .blocked, detail: "#3 open")),
                            SkipAnswer(Skip(issue: 8, reason: .epic, detail: nil)),
                        ],
                        notes: ["gave up orchestrator: loop.json does not give it to agent-one"],
                        nextDelay: "backoff")))
    }

    @Test("The orchestrator's repairs run and are reported, and a move makes the delay now")
    func orchestratorRepairs() {
        let board = board([], login: "agent-two")
        guard
            case .idle(let answer) = run(
                request(), board, repairs: ["MOVE #4 …", "#4 -> In Progress"])
        else {
            Issue.record("expected idle")
            return
        }
        #expect(answer.repairs == ["MOVE #4 …", "#4 -> In Progress"])
        #expect(answer.nextDelay == "now")
    }

    @Test("A tick left with no roles is idle and says so")
    func noRoles() {
        guard case .idle(let answer) = run(request(roles: [.orchestrator]), board([])) else {
            Issue.record("expected idle")
            return
        }
        #expect(
            answer.notes == [
                "gave up orchestrator: loop.json does not give it to agent-one",
                "this tick holds no roles",
            ])
    }

    @Test("An unlisted login runs as a single agent and says so")
    func unlisted() {
        let board = board([item(7, "Ready")], login: "agent-nine")
        guard case .assignment(let answer) = run(request(roles: [.engineer]), board) else {
            Issue.record("expected an assignment")
            return
        }
        #expect(answer.notes == ["running unlisted: loop.json lists no agent agent-nine"])
    }

    // MARK: Errors

    @Test("An invalid loop.json is an error at that stage, before anything is read")
    func invalidArrangement() {
        let broken = Self.arrangement.replacingOccurrences(of: "\"designer\"", with: "\"janitor\"")
        guard case .error(let answer) = run(request(arrangement: broken), board([item(7, "Ready")]))
        else {
            Issue.record("expected an error")
            return
        }
        #expect(answer.stage == .loopJSON)
        #expect(answer.message.contains("janitor"))
        #expect(!answer.retry)
    }

    @Test("A column the workflow names that the board lacks is an error, before any claim")
    func boardLacksColumn() {
        let board = board([item(7, "Ready")])
        board.board = Board(
            items: board.board.items, statusFieldID: "status", optionIDs: [:],
            columns: Workflow.standard.columns.all.filter { $0 != "Needs Human" })
        guard case .error(let answer) = run(request(), board) else {
            Issue.record("expected an error")
            return
        }
        #expect(answer.stage == .loopJSON)
        #expect(answer.message.contains("workflow.columns.parked: Needs Human"))
        #expect(board.assignees.isEmpty)
    }

    @Test("A budget below the read reserve is an error at the budget stage")
    func budget() {
        let board = board([item(7, "Ready")])
        board.budgetRemaining = 10
        guard case .error(let answer) = run(request(), board) else {
            Issue.record("expected an error")
            return
        }
        #expect(answer.stage == .budget)
        #expect(answer.retry)
        #expect(board.assignees.isEmpty)
    }

    @Test("A failed read before the claim is a provider error with nothing changed")
    func providerBeforeClaim() {
        let board = board([item(7, "Ready")])
        board.failing = ["labels"]
        guard case .error(let answer) = run(request(), board) else {
            Issue.record("expected an error")
            return
        }
        #expect(answer.stage == .provider)
        #expect(answer.retry)
        #expect(board.assignees.isEmpty)
        #expect(board.released.isEmpty)
    }

    @Test("A failed read after the claim releases it before answering")
    func providerAfterClaim() {
        let board = board([item(7, "Ready")])
        board.failing = ["events"]
        guard case .error(let answer) = run(request(), board) else {
            Issue.record("expected an error")
            return
        }
        #expect(answer.stage == .provider)
        #expect(board.released.map(\.issue) == [7])
    }

    @Test("A claim that doesn't take is a claim-permission error")
    func claimPermission() {
        let board = board([item(7, "Ready")])
        board.claimAnswers[7] = .didNotTake
        guard case .error(let answer) = run(request(), board) else {
            Issue.record("expected an error")
            return
        }
        #expect(answer.stage == .claimPermission)
        #expect(!answer.retry)
    }

    // MARK: Preview

    @Test("Preview selects and writes nothing through either seam, and runs no repairs")
    func previewWritesNothing() {
        let board = board([item(7, "Ready")], login: "agent-two")
        let source = FakeSourceControl()
        var repairsRan = false
        let answer = next(request(preview: true), board: board, source: source) {
            repairsRan = true
            return []
        }
        #expect(
            answer
                == .preview(
                    PreviewAnswer(
                        tickwork: "1f0c56fb", budget: BudgetAnswer(remaining: 5_000, limit: 5_000),
                        skipped: [],
                        notes: ["gave up designer: loop.json does not give it to agent-two"],
                        issue: 7, role: "engineer", task: "start")))
        #expect(!repairsRan)
        #expect(board.assignees.isEmpty)
        #expect(board.moves.isEmpty)
        #expect(board.posted.isEmpty)
        #expect(board.created.isEmpty)
        #expect(board.released.isEmpty)
        // SourceControl has no write: every call it took was a read.
        #expect(source.repositories.isEmpty)
    }

    @Test("Every answer prints as JSON carrying its schema and kind")
    func json() throws {
        let answer = NextAnswer.error(
            ErrorAnswer(stage: .claimPermission, message: "m", retry: false))
        let object =
            try JSONSerialization.jsonObject(with: Data(answer.json.utf8)) as? [String: Any]
        #expect(object?["schema"] as? Int == 1)
        #expect(object?["kind"] as? String == "error")
        #expect(object?["stage"] as? String == "claim-permission")
    }
}
