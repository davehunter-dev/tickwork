// `finish` and the helper verbs over the fakes: each outcome's comment text and
// write order, a re-run after a failure at every write, writes done by another
// actor, the checks that reject, and idempotent issue filing.
//

import Foundation
import Testing

@testable import BoardCore

@Suite("finish")
struct FinishTests {

    static let issueRepository = Coordinates.repository
    static let owner = Coordinates.ownerLogin
    static let claimTime = ISO8601DateFormatter().date(from: "2026-10-28T13:49:02Z")!
    static let pullRequest = PullRequestID(repository: "example-org/fixtures", number: 31)
    static let feedback = "https://github.com/example-org/fixtures/pull/31#pullrequestreview-5"
    static let context = FinishContext(issueRepository: issueRepository, owner: owner)

    /// The board, the source and the order every write landed in across both.
    final class World {
        let board = FakeBoard()
        let source = FakeSourceControl()
        var log: [String] = []

        init(column: String, design: Bool = false) {
            board.board = Board(
                items: [
                    Item(
                        id: "item-7", number: 7, title: "Issue 7", status: column,
                        assignees: ["agent-one"])
                ],
                statusFieldID: "status", optionIDs: [:], columns: [])
            board.labels[7] = design ? ["type:design"] : ["type:feature"]
            board.events[7] = [
                TimelineEvent(
                    kind: .assigned, actor: "agent-one", subject: "agent-one",
                    createdAt: FinishTests.claimTime)
            ]
            board.linked[7] = [
                LinkedPullRequest(id: FinishTests.pullRequest, open: true, merged: false)
            ]
            source.merge[FinishTests.pullRequest] = MergeFacts(
                headSHA: "abc123", branch: "f/7-work", mergeable: true, mergeableState: "blocked",
                draft: false, opener: "agent-one")
            source.feedback[FinishTests.pullRequest] = [FinishTests.feedback]
            board.onWrite = { [unowned self] in self.log.append($0) }
            source.onWrite = { [unowned self] in self.log.append($0) }
        }

        func finish(_ request: FinishRequest) -> FinishAnswer {
            BoardCore.finish(request, board: board, source: source, context: FinishTests.context)
        }
    }

    static func token(_ role: Role, _ task: TickTask, _ column: String) -> ClaimToken {
        ClaimToken(
            login: "agent-one", repository: issueRepository, issue: 7, role: role, task: task,
            column: column, claimedAt: claimTime)
    }

    /// A request for each outcome with the arguments it takes, and the column the
    /// token was taken from.
    static func request(_ outcome: Outcome) -> (FinishRequest, column: String) {
        switch outcome {
        case .submitted:
            var request = FinishRequest(
                token: token(.engineer, .addressFindings, "In Progress"), outcome: outcome)
            request.pullRequest = pullRequest
            request.isNew = true
            request.body = "Fixed both findings."
            request.answering = [feedback]
            return (request, "In Progress")
        case .decomposed:
            return (
                FinishRequest(token: token(.engineer, .decompose, "In Progress"), outcome: outcome),
                "In Progress"
            )
        case .approved, .changesRequested:
            var request = FinishRequest(
                token: token(.reviewer, .review, "Agent Review"), outcome: outcome)
            request.pullRequest = pullRequest
            request.body = "Checked the order of writes."
            request.answering = [feedback]
            return (request, "Agent Review")
        case .blocked:
            var request = FinishRequest(
                token: token(.engineer, .start, "In Progress"), outcome: outcome)
            request.body = "the registry is on an unmerged branch."
            request.blockers = [12, 13]
            return (request, "In Progress")
        case .needsHuman:
            var request = FinishRequest(
                token: token(.engineer, .start, "In Progress"), outcome: outcome)
            request.body = "two readings of the criteria. Which one?"
            return (request, "In Progress")
        case .unable:
            var request = FinishRequest(
                token: token(.engineer, .start, "In Progress"), outcome: outcome)
            request.body = "gh is denied the project scope."
            return (request, "In Progress")
        }
    }

    static func marker(_ outcome: Outcome) -> String {
        finishMarker(outcome, request(outcome).0.token)
    }

    // MARK: Text and order

    @Test("Each outcome writes today's text in today's order", arguments: Outcome.allCases)
    func textAndOrder(_ outcome: Outcome) throws {
        let (request, column) = Self.request(outcome)
        let world = World(column: column)
        guard case .finished = world.finish(request) else {
            Issue.record("expected finished: \(world.finish(request))")
            return
        }
        let marker = Self.marker(outcome)
        let issueBodies = world.board.posted.map(\.body)
        let pullRequestBodies = (world.source.conversation[Self.pullRequest] ?? []).map(\.body)
        let ref = "example-org/fixtures#31"

        switch outcome {
        case .submitted:
            #expect(
                world.log == [
                    "comment #7", "comment \(ref)", "move #7 In Progress → Agent Review",
                    "release #7",
                ])
            #expect(issueBodies == ["PR: \(ref)\n\n\(marker)"])
            #expect(
                pullRequestBodies == [
                    "Fixed both findings.\n\nAnswering \(Self.feedback).\n\n\(marker)"
                ])
        case .decomposed:
            #expect(world.log == ["close #7", "release #7"])
        case .approved:
            #expect(
                world.log == [
                    "comment \(ref)", "assign \(ref) \(Self.owner)",
                    "request \(ref) \(Self.owner)", "move #7 Agent Review → Human Review",
                    "release #7",
                ])
            #expect(
                pullRequestBodies == [
                    "Checked the order of writes.\n\nAnswering \(Self.feedback).\n\n\(marker)"
                ])
        case .changesRequested:
            #expect(
                world.log == [
                    "comment \(ref)", "move #7 Agent Review → In Progress", "release #7",
                ])
        case .blocked:
            #expect(
                world.log == ["comment #7", "move #7 In Progress → Needs Human", "release #7"])
            #expect(
                issueBodies == [
                    "Bailing out: the registry is on an unmerged branch.\n\n"
                        + "Blocked-on: #12\nBlocked-on: #13\n\n\(marker)"
                ])
        case .needsHuman:
            #expect(
                issueBodies == [
                    "Bailing out: two readings of the criteria. Which one?\n\n\(marker)"
                ])
            #expect(
                world.log == ["comment #7", "move #7 In Progress → Needs Human", "release #7"])
        case .unable:
            #expect(
                issueBodies == [
                    "Bailing out: unable to proceed.\n\ngh is denied the project scope.\n\n\(marker)"
                ])
            #expect(
                world.log == ["comment #7", "move #7 In Progress → Needs Human", "release #7"])
        }
    }

    @Test("A design's findings go back to In Design")
    func designFindings() {
        let world = World(column: "Agent Review", design: true)
        _ = world.finish(Self.request(.changesRequested).0)
        #expect(world.log.contains("move #7 Agent Review → In Design"))
    }

    // MARK: Recovery

    /// The fake failure that stops each write.
    static func failure(_ entry: String) -> (board: String?, source: String?) {
        switch entry.split(separator: " ").first {
        case "comment": entry.contains("#7") ? ("comment", nil) : (nil, "comment")
        case "move": ("move", nil)
        case "release": ("release", nil)
        case "close": ("close", nil)
        case "assign": (nil, "assign")
        case "request": (nil, "request")
        default: (nil, nil)
        }
    }

    @Test(
        "A failure at each write answers incomplete, and the re-run does only what is left",
        arguments: Outcome.allCases)
    func rerunAfterEachFailure(_ outcome: Outcome) throws {
        let (request, column) = Self.request(outcome)
        let reference = World(column: column)
        _ = reference.finish(request)
        let writes = reference.log

        for (index, write) in writes.enumerated() {
            let world = World(column: column)
            let stop = Self.failure(write)
            if let name = stop.board { world.board.failing.insert(name) }
            if let name = stop.source { world.source.failing.insert(name) }

            guard case .incomplete(let first) = world.finish(request) else {
                Issue.record("\(outcome.rawValue): no incomplete when \(write) failed")
                continue
            }
            #expect(first.done.count == index, "\(outcome.rawValue) at \(write)")
            #expect(first.retry)
            #expect(world.log == Array(writes.prefix(index)))

            world.board.failing = []
            world.source.failing = []
            // The answered feedback is no longer outstanding once the comment is up.
            if index > 0 { world.source.feedback[Self.pullRequest] = [] }
            guard case .finished(let second) = world.finish(request) else {
                Issue.record("\(outcome.rawValue): the re-run after \(write) did not finish")
                continue
            }
            #expect(world.log == writes, "\(outcome.rawValue) at \(write)")
            #expect(second.done.count == writes.count)
        }
    }

    @Test("Running finish again after it finished writes nothing more")
    func secondRunWritesNothing() {
        let (request, column) = Self.request(.blocked)
        let world = World(column: column)
        _ = world.finish(request)
        let writes = world.log
        guard case .finished = world.finish(request) else {
            Issue.record("expected finished")
            return
        }
        #expect(world.log == writes)
    }

    @Test("A re-run with the same --answering after the comment posted is not rejected")
    func rerunWithAnswering() {
        let (request, column) = Self.request(.changesRequested)
        let world = World(column: column)
        world.board.failing = ["move"]
        _ = world.finish(request)
        world.board.failing = []
        world.source.feedback[Self.pullRequest] = []
        guard case .finished = world.finish(request) else {
            Issue.record("expected finished")
            return
        }
    }

    // MARK: Writes by another actor

    @Test("A move another actor made is refused; the work is posted and the claim released")
    func moveByAnother() {
        let (request, column) = Self.request(.needsHuman)
        let world = World(column: column)
        world.board.login = "agent-two"
        try? world.board.move(7, to: "Needs Human", from: column)
        world.board.login = "agent-one"
        world.log = []
        guard case .refused(let answer) = world.finish(request) else {
            Issue.record("expected refused")
            return
        }
        #expect(answer.stage == "move")
        #expect(answer.found == "Needs Human")
        #expect(world.log == ["comment #7", "release #7"])
    }

    @Test("A claim another actor removed is refused with nothing written")
    func releaseByAnother() {
        let (request, column) = Self.request(.submitted)
        let world = World(column: column)
        world.board.update(7) {
            Item(id: $0.id, number: $0.number, title: $0.title, status: $0.status, assignees: [])
        }
        world.board.events[7, default: []].append(
            TimelineEvent(
                kind: .unassigned, actor: Self.owner, subject: "agent-one",
                createdAt: world.board.now))
        guard case .refused(let answer) = world.finish(request) else {
            Issue.record("expected refused")
            return
        }
        #expect(answer.stage == "claim")
        #expect(world.log.isEmpty)
    }

    @Test("A comment carrying this token's marker by someone else is not this run's")
    func commentByAnother() {
        let (request, column) = Self.request(.unable)
        let world = World(column: column)
        world.board.comments[7] = [
            ConversationComment(
                author: "agent-two", url: "u", createdAt: world.board.now,
                body: "copied\n\n\(Self.marker(.unable))")
        ]
        guard case .finished = world.finish(request) else {
            Issue.record("expected finished")
            return
        }
        #expect(world.log.first == "comment #7")
    }

    @Test("The owner assigned by someone else is still assigned and requested by this run")
    func assignmentByAnother() {
        let (request, column) = Self.request(.approved)
        let world = World(column: column)
        world.source.events[Self.pullRequest] = [
            TimelineEvent(
                kind: .assigned, actor: "agent-two", subject: Self.owner, createdAt: world.board.now
            )
        ]
        _ = world.finish(request)
        #expect(world.log.contains("assign example-org/fixtures#31 \(Self.owner)"))
    }

    @Test("The owner's review requested by someone else is still requested by this run")
    func reviewRequestByAnother() {
        let (request, column) = Self.request(.approved)
        let world = World(column: column)
        world.source.events[Self.pullRequest] = [
            TimelineEvent(
                kind: .reviewRequested, actor: "agent-two", subject: Self.owner,
                createdAt: world.board.now)
        ]
        guard case .finished = world.finish(request) else {
            Issue.record("expected finished")
            return
        }
        #expect(world.log.contains("request example-org/fixtures#31 \(Self.owner)"))
    }

    /// The owner closing a design issue by hand is ordinary. `gh issue close` on
    /// a closed issue says so and succeeds, so the close is made again and the
    /// outcome finishes.
    @Test("A design issue someone else closed is closed again, and decomposed finishes")
    func closeByAnother() {
        let (request, column) = Self.request(.decomposed)
        let world = World(column: column)
        world.board.events[7, default: []].append(
            TimelineEvent(
                kind: .closed, actor: Self.owner, subject: nil, createdAt: world.board.now))
        guard case .finished = world.finish(request) else {
            Issue.record("expected finished")
            return
        }
        #expect(world.log == ["close #7", "release #7"])
    }

    @Test("The project's automation moving a Ready card into In Progress is not a refusal")
    func automationMove() {
        var (request, _) = Self.request(.submitted)
        request = FinishRequest(
            token: Self.token(.engineer, .start, "Ready"), outcome: .submitted,
            pullRequest: Self.pullRequest, isNew: true)
        let world = World(column: "Ready")
        world.board.login = projectAutomationLogin
        try? world.board.move(7, to: "In Progress", from: "Ready")
        world.board.login = "agent-one"
        world.log = []
        guard case .finished(let answer) = world.finish(request) else {
            Issue.record("expected finished")
            return
        }
        #expect(answer.done.contains("move In Progress → Agent Review"))
        #expect(world.log.contains("move #7 In Progress → Agent Review"))
    }

    // MARK: Rejections

    @Test("Each failed check rejects with nothing written")
    func rejections() {
        func rejected(_ change: (inout FinishRequest, World) -> Void) -> Bool {
            var (request, column) = Self.request(.changesRequested)
            let world = World(column: column)
            change(&request, world)
            if case .rejected = world.finish(request) { return world.log.isEmpty }
            return false
        }
        #expect(rejected { _, world in world.board.login = "agent-two" })
        #expect(
            rejected { request, _ in
                request = FinishRequest(
                    token: ClaimToken(
                        login: "agent-one", repository: "example-org/other", issue: 7,
                        role: .reviewer, task: .review, column: "Agent Review",
                        claimedAt: Self.claimTime), outcome: .changesRequested,
                    pullRequest: Self.pullRequest, body: "b")
            })
        #expect(
            rejected { request, _ in
                request = FinishRequest(
                    token: request.token, outcome: .submitted, pullRequest: Self.pullRequest)
            })
        #expect(rejected { request, _ in request.answering = ["https://example.test/elsewhere"] })
        #expect(
            rejected { request, _ in
                request.pullRequest = PullRequestID(repository: "example-org/fixtures", number: 99)
            })
        #expect(rejected { request, _ in request.body = nil })
        #expect(
            rejected { _, world in
                world.board.events[7, default: []].append(
                    TimelineEvent(
                        kind: .assigned, actor: "agent-one", subject: "agent-one",
                        createdAt: world.board.now))
            })
    }

    @Test("blocked needs one open blocker, and is rejected only when none is")
    func blockedNeedsOneOpen() {
        let (request, column) = Self.request(.blocked)
        let oneOpen = World(column: column)
        oneOpen.board.landings[13] = .landed
        guard case .finished = oneOpen.finish(request) else {
            Issue.record("expected finished with #12 still open")
            return
        }
        let noneOpen = World(column: column)
        noneOpen.board.landings[12] = .landed
        noneOpen.board.landings[13] = .landed
        guard case .rejected(let answer) = noneOpen.finish(request) else {
            Issue.record("expected rejected")
            return
        }
        #expect(answer.message.contains("#12, #13"))
        #expect(noneOpen.log.isEmpty)
    }

    @Test(
        "Every issue write lands on the issue's board, and every pull-request write in its repository"
    )
    func repositories() {
        let (request, column) = Self.request(.approved)
        let world = World(column: column)
        _ = world.finish(request)
        #expect(Set(world.source.repositories) == ["example-org/fixtures"])
        #expect(world.board.moves.map(\.issue) == [7])
    }

    // MARK: Helper verbs

    @Test("file-issue retried with its key returns the same issue, even closed; two keys file two")
    func fileIssueIdempotent() {
        let world = World(column: "In Progress")
        let token = Self.token(.engineer, .start, "In Progress")
        let file = { (key: String) in
            fileIssue(
                token: token, key: key, title: "Socket timeout", body: "It times out.",
                labels: ["type:bug"], decomposing: false, board: world.board,
                context: Self.context)
        }
        let first = file("gap-socket-timeout")
        #expect(first.kind == "filed")
        #expect(first.existing == false)
        #expect(
            world.board.created.first?.body
                == "Found while implementing #7.\n\nIt times out.\n\n"
                + issueMarker(token, key: "gap-socket-timeout"))
        // `issues(createdBy:since:)` lists every state, so a closed one is found too.
        let again = file("gap-socket-timeout")
        #expect(again.number == first.number)
        #expect(again.existing == true)
        let other = file("gap-socket-retry")
        #expect(other.number != first.number)
        #expect(world.board.created.count == 2)
    }

    @Test("file-issue and decompose put a new issue in Backlog over the board's own default")
    func filedIntoBacklog() {
        let world = World(column: "In Progress")
        for task in [TickTask.start, .decompose] {
            let token = Self.token(.engineer, task, "In Progress")
            let number = fileIssue(
                token: token, key: "gap-\(task.rawValue)", title: "Gap", body: "b", labels: [],
                decomposing: task == .decompose, board: world.board, context: Self.context
            ).number!
            #expect(world.board.cards[number] == "Backlog")
        }
        #expect(world.board.placed.map(\.column) == ["Backlog", "Backlog"])
    }

    @Test("A retried file-issue places a card left in Intake, and leaves one the owner moved")
    func retriedPlacement() throws {
        let world = World(column: "In Progress")
        let token = Self.token(.engineer, .start, "In Progress")
        let file = {
            fileIssue(
                token: token, key: "gap", title: "Gap", body: "b", labels: [],
                decomposing: false, board: world.board, context: Self.context)
        }
        let number = try #require(file().number)
        // A tick that died after filing, with the project's add workflow done.
        world.board.cards[number] = "Intake"
        #expect(file().existing == true)
        #expect(world.board.cards[number] == "Backlog")
        world.board.cards[number] = "Ready"
        _ = file()
        #expect(world.board.cards[number] == "Ready")
        #expect(world.board.placed.count == 2)
    }

    @Test("decompose files a task linked to the design, and only for a decompose task")
    func decompose() {
        let world = World(column: "In Progress")
        let token = Self.token(.engineer, .decompose, "In Progress")
        let answer = fileIssue(
            token: token, key: "task-1", title: "Task", body: "Do it.", labels: [],
            decomposing: true, board: world.board, context: Self.context)
        #expect(answer.kind == "filed")
        #expect(world.board.created.first?.body.hasPrefix("Part of #7.\n\n") == true)
        let wrong = fileIssue(
            token: Self.token(.engineer, .start, "In Progress"), key: "task-1", title: "Task",
            body: "Do it.", labels: [], decomposing: true, board: world.board,
            context: Self.context)
        #expect(wrong.kind == "rejected")
    }

    @Test("reply answers outstanding feedback once, with its Answering lines")
    func replyOnce() {
        let world = World(column: "In Progress")
        let token = Self.token(.engineer, .addressFindings, "In Progress")
        let answer = reply(
            token: token, answering: [Self.feedback], body: "Done.", board: world.board,
            source: world.source, context: Self.context)
        #expect(answer.kind == "replied")
        #expect(
            world.source.conversation[Self.pullRequest]?.first?.body
                == "Done.\n\nAnswering \(Self.feedback).\n\n"
                + replyMarker(token, answering: [Self.feedback]))
        world.source.feedback[Self.pullRequest] = []
        let again = reply(
            token: token, answering: [Self.feedback], body: "Done.", board: world.board,
            source: world.source, context: Self.context)
        #expect(again.existing == true)
        #expect(world.source.conversation[Self.pullRequest]?.count == 1)
        let stale = reply(
            token: token, answering: ["https://example.test/other"], body: "x", board: world.board,
            source: world.source, context: Self.context)
        #expect(stale.kind == "rejected")
    }

    @Test("A helper verb on a claim no longer held is rejected")
    func helperNeedsClaim() {
        let world = World(column: "In Progress")
        world.board.update(7) {
            Item(id: $0.id, number: $0.number, title: $0.title, status: $0.status, assignees: [])
        }
        let answer = changeBlocker(
            token: Self.token(.engineer, .start, "In Progress"), blocker: 3, adding: true,
            board: world.board, context: Self.context)
        #expect(answer.kind == "rejected")
        #expect(world.board.blockers[7] == nil)
    }
}
