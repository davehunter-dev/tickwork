// `loop.json`'s `workflow` object: reading it, the routes that follow its names,
// and the problems `check-loop` reports about it.
//

import Foundation
import Testing

@testable import BoardCore

@Suite("The workflow's column and label names")
struct WorkflowTests {

    /// Every column and label renamed, so a route that still uses today's names
    /// shows up as the wrong column.
    static let renamed: Workflow = {
        var workflow = Workflow()
        workflow.columns.backlog = "Inbox"
        workflow.columns.ready = "Queued"
        workflow.columns.design = "Designing"
        workflow.columns.work = "Building"
        workflow.columns.review = "Checking"
        workflow.columns.ownerReview = "Approving"
        workflow.columns.parked = "Waiting"
        workflow.columns.done = "Shipped"
        workflow.labels.design = "kind:design"
        workflow.labels.epic = "kind:epic"
        return workflow
    }()

    static let renamedJSON = """
        "workflow": {
          "columns": {
            "backlog": "Inbox", "ready": "Queued", "design": "Designing",
            "work": "Building", "review": "Checking", "ownerReview": "Approving",
            "parked": "Waiting", "done": "Shipped"
          },
          "labels": { "design": "kind:design", "epic": "kind:epic" }
        }
        """

    static func arrangement(_ workflow: String? = nil) -> String {
        let extra = workflow.map { ",\n\($0)" } ?? ""
        return """
            {
              "repository": "example-org/example",
              "project": { "owner": "example-org", "number": 1 },
              "owner": "example-owner",
              "agents": [{ "login": "agent-one", "roles": ["engineer"] }]\(extra)
            }
            """
    }

    static func decode(_ json: String) throws -> LoopConfiguration {
        try JSONDecoder().decode(LoopConfiguration.self, from: Data(json.utf8))
    }

    static func problems(_ json: String) throws -> [String] {
        let document = try JSONDecoder().decode(JSON.self, from: Data(json.utf8)).object ?? [:]
        return loopProblems(in: document)
    }

    // MARK: Reading it

    @Test("Without workflow, every name is today's")
    func absentIsStandard() throws {
        let workflow = try Self.decode(Self.arrangement()).workflow
        #expect(workflow == .standard)
        #expect(
            workflow.columns.all == [
                "Backlog", "Ready", "In Design", "In Progress", "Agent Review", "Human Review",
                "Needs Human", "Done",
            ])
        #expect(workflow.labels.design == "type:design")
        #expect(workflow.labels.epic == "epic")
    }

    @Test("A key left out keeps today's name")
    func partialKeepsDefaults() throws {
        let workflow = try Self.decode(
            Self.arrangement(#""workflow": { "columns": { "parked": "Waiting" } }"#)
        ).workflow
        var expected = Workflow.standard
        expected.columns.parked = "Waiting"
        #expect(workflow == expected)
    }

    @Test("Every renamed column and label is read")
    func everyNameRead() throws {
        #expect(try Self.decode(Self.arrangement(Self.renamedJSON)).workflow == Self.renamed)
        #expect(try Self.problems(Self.arrangement(Self.renamedJSON)).isEmpty)
    }

    // MARK: finish's outcomes

    func token(_ role: Role, _ task: TickTask, _ column: String) -> ClaimToken {
        ClaimToken(
            login: "agent-one", repository: Coordinates.repository, issue: 7, role: role,
            task: task, column: column, claimedAt: Date(timeIntervalSince1970: 0))
    }

    func moves(_ request: FinishRequest, design: Bool = false) -> [String] {
        finishWrites(request, isDesign: design, workflow: Self.renamed).compactMap {
            if case .move(let to) = $0 { to } else { nil }
        }
    }

    @Test("Each outcome moves the card to the renamed column")
    func outcomesRouteToRenamed() {
        let pullRequest = PullRequestID(repository: "example-org/fixtures", number: 31)
        func request(_ outcome: Outcome, _ role: Role, _ task: TickTask) -> FinishRequest {
            var request = FinishRequest(token: token(role, task, "Building"), outcome: outcome)
            request.pullRequest = pullRequest
            request.body = "Why."
            request.blockers = [12]
            return request
        }
        #expect(moves(request(.submitted, .engineer, .start)) == ["Checking"])
        #expect(moves(request(.approved, .reviewer, .review)) == ["Approving"])
        #expect(moves(request(.changesRequested, .reviewer, .review)) == ["Building"])
        #expect(
            moves(request(.changesRequested, .reviewer, .review), design: true) == ["Designing"])
        #expect(moves(request(.blocked, .engineer, .start)) == ["Waiting"])
        #expect(moves(request(.needsHuman, .engineer, .start)) == ["Waiting"])
        #expect(moves(request(.unable, .engineer, .start)) == ["Waiting"])
        #expect(moves(request(.decomposed, .engineer, .decompose)).isEmpty)
    }

    @Test("finish reads the design label and the ready column by their new names")
    func finishReadsRenamedNames() {
        let board = FakeBoard()
        let source = FakeSourceControl()
        let claimTime = Date(timeIntervalSince1970: 0)
        board.board = Board(
            items: [
                Item(
                    id: "item-7", number: 7, title: "Seven", status: "Queued",
                    assignees: ["agent-one"])
            ],
            statusFieldID: "status", optionIDs: [:], columns: [])
        board.labels[7] = ["kind:design"]
        board.events[7] = [
            TimelineEvent(
                kind: .assigned, actor: "agent-one", subject: "agent-one", createdAt: claimTime)
        ]
        let pullRequest = PullRequestID(repository: "example-org/fixtures", number: 31)
        board.linked[7] = [LinkedPullRequest(id: pullRequest, open: true, merged: false)]
        // The project's automation takes the card from the ready column into the
        // design's work column when its pull request links.
        board.login = projectAutomationLogin
        try? board.move(7, to: "Designing", from: "Queued")
        board.login = "agent-one"

        var request = FinishRequest(
            token: token(.designer, .design, "Queued"), outcome: .submitted)
        request.pullRequest = pullRequest
        let context = FinishContext(
            issueRepository: Coordinates.repository, owner: Coordinates.ownerLogin,
            workflow: Self.renamed)
        guard
            case .finished(let answer) = finish(
                request, board: board, source: source, context: context)
        else {
            Issue.record("expected finished")
            return
        }
        #expect(answer.done.contains("move Designing → Checking"))
    }

    // MARK: The repairs

    func decide(_ card: CardFacts) -> [RepairAction] {
        repairs(for: card, redOnMain: [:], loopLogins: ["agent-one"], workflow: Self.renamed)
    }

    func withPullRequest(
        in column: String, design: Bool = false, failing: [String] = [],
        mergeable: Bool = true, state: String = "blocked", unanswered: [String] = []
    ) -> CardFacts {
        var card = CardFacts(number: 7, column: column, assignees: [], isDesign: design)
        let id = PullRequestID(repository: Coordinates.repository, number: 31)
        card.pullRequests = [LinkedPullRequest(id: id, open: true, merged: false)]
        card.merge[id] = MergeFacts(
            headSHA: "abc123", branch: "f/7-work", mergeable: mergeable, mergeableState: state,
            draft: false, opener: "agent-one")
        card.checks[id] = CheckFacts(failing: failing)
        card.unansweredFeedback[id] = unanswered
        card.mergeGuard[id] = .passes
        return card
    }

    func destination(_ actions: [RepairAction]) -> String? {
        for action in actions {
            if case .move(_, let to, _, _) = action { return to }
        }
        return nil
    }

    @Test("Each repair that sends a card back routes it to the renamed column")
    func repairsRouteToRenamed() {
        for column in ["Checking", "Approving"] {
            #expect(
                destination(decide(withPullRequest(in: column, failing: ["tests"]))) == "Building")
            #expect(
                destination(decide(withPullRequest(in: column, design: true, failing: ["tests"])))
                    == "Designing")
            #expect(
                destination(decide(withPullRequest(in: column, unanswered: ["u"]))) == "Building")
            #expect(
                destination(decide(withPullRequest(in: column, mergeable: false))) == "Building")
            #expect(destination(decide(withPullRequest(in: column, state: "behind"))) == "Building")
        }
        #expect(
            decide(withPullRequest(in: "Approving", state: "clean"))
                == [
                    .merge(
                        pullRequest: PullRequestID(repository: Coordinates.repository, number: 31))
                ])
        #expect(decide(withPullRequest(in: "Checking", state: "clean")) == [.ok])

        // A merged design waiting in the design column or in owner review.
        for column in ["Designing", "Approving"] {
            var design = CardFacts(number: 7, column: column, assignees: [], isDesign: true)
            design.pullRequests = [
                LinkedPullRequest(
                    id: PullRequestID(repository: Coordinates.repository, number: 31), open: false,
                    merged: true)
            ]
            #expect(destination(decide(design)) == "Building")
        }

        // Today's column names are not this workflow's, so they are left alone.
        #expect(decide(withPullRequest(in: "Agent Review", failing: ["tests"])) == [.ok])
    }

    @Test("The parked column's repairs read and route by its new name")
    func parkedRepairs() {
        func parked(
            _ comments: [(String, String)], blockers: [Int: BlockerState] = [:],
            assignees: [String] = []
        ) -> CardFacts {
            var card = CardFacts(
                number: 7, column: "Waiting", assignees: assignees, isDesign: false)
            card.bailOut = bailOutFacts(
                comments: comments.enumerated().map { index, comment in
                    ConversationComment(
                        author: comment.0, url: "u\(index)",
                        createdAt: Date(timeIntervalSince1970: TimeInterval(index)), body: comment.1
                    )
                },
                loopLogins: ["agent-one"], owner: "example-owner")
            card.blockers = blockers
            return card
        }
        let answered = decide(
            parked([("agent-one", "Bailing out: A or B?"), ("example-owner", "B")]))
        #expect(
            answered == [
                .move(
                    from: "Waiting", to: "Building", reason: "the owner answered the bail-out",
                    comment: "Answer received: B")
            ])
        let cleared = decide(
            parked(
                [("agent-one", "Bailing out: waiting.\nBlocked-on: #12")], blockers: [12: .landed]))
        #expect(destination(cleared) == "Building")

        #expect(
            decide(parked([], assignees: ["agent-one"])) == [.releaseClaim(login: "agent-one")])
    }

    // MARK: select

    @Test("Selection reads the columns and labels by their new names")
    func selectionReadsRenamed() {
        let agent = SelectingAgent(
            login: "agent-one", roles: [.engineer, .designer, .reviewer])
        func card(_ number: Int, _ column: String, design: Bool = false) -> CardFacts {
            CardFacts(number: number, column: column, assignees: [], isDesign: design)
        }
        func pick(_ cards: [CardFacts]) -> Pick? {
            select(from: cards, agent: agent, workflow: Self.renamed).pick
        }

        #expect(pick([card(1, "Queued"), card(2, "Building")])?.issue == 2)
        #expect(pick([card(1, "Queued"), card(2, "Designing")])?.issue == 2)
        #expect(pick([card(1, "Queued", design: true)])?.role == .designer)
        #expect(pick([card(1, "Queued")])?.task == .start)
        #expect(pick([card(1, "Ready")]) == nil)

        var blocked = card(1, "Queued")
        blocked.openBlockers = [9]
        #expect(pick([blocked]) == nil)
    }

    @Test("next reads the names from origin/main's loop.json, epic label included")
    func nextReadsRenamed() {
        let arrangement = NextTests.arrangement.replacingOccurrences(
            of: "\"agents\":", with: Self.renamedJSON + ",\n  \"agents\":")
        let board = FakeBoard()
        board.board = Board(
            items: [0, 1, 2].map { number in
                Item(
                    id: "item-\(number)", number: number, title: "Issue \(number)",
                    status: number == 0 ? "Ready" : "Queued", assignees: [])
            },
            statusFieldID: "status", optionIDs: [:], columns: Self.renamed.columns.all)
        board.labels[1] = ["kind:epic"]
        board.labels[2] = ["kind:design"]
        let request = NextRequest(
            arrangementJSON: arrangement, roles: nil, preview: true, revision: nil)
        guard
            case .preview(let answer) = next(
                request, board: board, source: FakeSourceControl(), runRepairs: { [] })
        else {
            Issue.record(
                "expected a preview: \(next(request, board: board, source: FakeSourceControl()) { [] })"
            )
            return
        }
        #expect(answer.issue == 2)
        #expect(answer.role == "designer")
        #expect(answer.task == "design")
        #expect(answer.skipped.map(\.issue) == [1])
        #expect(answer.skipped.map(\.reason) == ["epic"])
    }

    // MARK: check-loop

    @Test("An unknown key anywhere in workflow is refused and named")
    func unknownKeys() throws {
        let problems = try Self.problems(
            Self.arrangement(
                """
                "workflow": {
                  "columns": { "parked": "Waiting", "triage": "Inbox" },
                  "labels": { "bug": "type:bug" },
                  "transitions": {}
                }
                """))
        #expect(
            problems == [
                "workflow.transitions: not a key it takes (columns, labels)",
                "workflow.columns.triage: not a key it takes "
                    + "(backlog, ready, design, work, review, ownerReview, parked, done)",
                "workflow.labels.bug: not a key it takes (design, epic)",
            ])
    }

    @Test("A workflow, columns or name of the wrong type is refused")
    func wrongTypes() throws {
        #expect(
            try Self.problems(Self.arrangement(#""workflow": []"#)) == ["workflow: not an object"])
        #expect(
            try Self.problems(Self.arrangement(#""workflow": { "columns": "Ready" }"#))
                == ["workflow.columns: not an object"])
        #expect(
            try Self.problems(Self.arrangement(#""workflow": { "labels": { "epic": "" } }"#))
                == ["workflow.labels.epic: not a non-empty string"])
    }

    @Test("Each column the board doesn't have is named")
    func missingColumns() {
        let board = ["Inbox", "Queued", "Designing", "Building", "Checking", "Shipped"]
        #expect(
            workflowColumnProblems(Self.renamed, boardColumns: board) == [
                "workflow.columns.ownerReview: Approving is not a column on the board "
                    + "(\(board.joined(separator: ", ")))",
                "workflow.columns.parked: Waiting is not a column on the board "
                    + "(\(board.joined(separator: ", ")))",
            ])
        #expect(
            workflowColumnProblems(
                Self.renamed, boardColumns: board + ["Approving", "Waiting"]
            ).isEmpty)
    }

    @Test("working hides the renamed backlog and done, and shows the rest in workflow order")
    func workingRenamed() throws {
        let item = { (number: Int, status: String) in
            Item(
                id: "\(number)", number: number, title: "Issue \(number)", status: status,
                assignees: [])
        }
        let board = Board(
            items: [item(1, "Inbox"), item(2, "Building"), item(3, "Queued"), item(4, "Shipped")],
            statusFieldID: "status", optionIDs: [:], columns: Self.renamed.columns.all.reversed())
        let budget = GraphQLBudget(
            remaining: 5_000, limit: 5_000, reset: Date(timeIntervalSince1970: 0))
        let text = workingText(board, budget: budget, workflow: Self.renamed)
        #expect(!text.contains("#1 "))
        #expect(!text.contains("#4 "))
        let queued = try #require(text.range(of: "[Queued]"))
        let building = try #require(text.range(of: "[Building]"))
        #expect(queued.lowerBound < building.lowerBound)
        // A column the workflow doesn't name is never the loop's to show.
        let standard = workingText(board, budget: budget)
        #expect(!standard.contains("[Inbox]"))
    }
}
