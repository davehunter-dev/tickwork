// `select` against boards recorded from a consumer's live loop, each with the
// pick its prose tick made. Logins and issue numbers are replaced, keeping
// every relation between them. Columns `select` never reads are recorded too,
// so a rule that starts reading one fails here.
//

import Testing

@testable import BoardCore

@Suite("Step 2 parity with the prose")
struct SelectParityTests {

    struct Recorded {
        let name: String
        let cards: [CardFacts]
        let agent: SelectingAgent
        /// What the prose tick took, and what it reported passing over.
        let prose: Selection
    }

    static let agentTwo = SelectingAgent(
        login: "agent-two", roles: [.orchestrator, .reviewer, .engineer])

    static func pr(_ number: Int) -> PullRequestID {
        PullRequestID(repository: Coordinates.repository, number: number)
    }

    static func card(
        _ number: Int, _ column: String, held: [String] = [], blockers: [Int] = [],
        design: Bool = false
    ) -> CardFacts {
        var card = CardFacts(number: number, column: column, assignees: held, isDesign: design)
        card.openBlockers = blockers
        return card
    }

    /// The `Ready` column both ticks saw: its topmost claimed, then a chain of
    /// tasks blocked on one another and on issues outside it.
    static let ready = [
        card(20, "Ready", held: ["agent-one"]),
        card(21, "Ready"),
        card(22, "Ready", blockers: [21, 20]),
        card(23, "Ready", blockers: [22, 20]),
        card(24, "Ready", blockers: [23, 22]),
        card(25, "Ready", blockers: [23, 21]),
        card(30, "Ready", blockers: [40]),
        card(31, "Ready", blockers: [41]),
        card(32, "Ready", blockers: [42]),
        card(33, "Ready", blockers: [43, 42]),
        card(34, "Ready", blockers: [32]),
        card(35, "Ready", blockers: [33, 41, 34]),
        card(36, "Ready", blockers: [42]),
    ]

    static let parked = [
        card(42, "Human Review"), card(44, "Human Review", design: true), card(45, "Human Review"),
        card(40, "Needs Human"), card(41, "Needs Human"), card(50, "Needs Human", design: true),
    ]

    /// The repairs had just sent the item back for the owner's review.
    static let ownerFeedback: Recorded = {
        var returned = card(10, "In Progress")
        let id = pr(110)
        returned.pullRequests = [LinkedPullRequest(id: id, open: true, merged: false)]
        returned.merge[id] = MergeFacts(
            headSHA: "73cc74f", branch: "f/7-work", mergeable: true, mergeableState: "blocked",
            draft: false, opener: "agent-two")
        returned.checks[id] = CheckFacts()
        returned.unansweredFeedback[id] = [
            "https://github.com/example-org/example/pull/110#pullrequestreview-1"
        ]
        return Recorded(
            name: "owner feedback", cards: ready + [returned] + parked, agent: agentTwo,
            prose: Selection(
                pick: Pick(issue: 10, role: .engineer, task: .addressFindings),
                skipped: []))
    }()

    /// The fix had just been pushed, and its checks were still running.
    static let checksRunning: Recorded = {
        var review = card(10, "Agent Review")
        let id = pr(110)
        review.pullRequests = [LinkedPullRequest(id: id, open: true, merged: false)]
        review.merge[id] = MergeFacts(
            headSHA: "848d4c7", branch: "f/7-work", mergeable: true, mergeableState: "blocked",
            draft: false, opener: "agent-one")
        var running = CheckFacts()
        running.unfinished = true
        review.checks[id] = running
        return Recorded(
            name: "checks running", cards: [review] + ready + parked, agent: agentTwo,
            prose: Selection(
                pick: Pick(issue: 21, role: .engineer, task: .start),
                skipped: [
                    Skip(
                        issue: 10, reason: .checksRunning,
                        detail: "\(Coordinates.repository)#110@848d4c7"),
                    Skip(issue: 20, reason: .claimed, detail: "agent-one"),
                ]))
    }()

    func expectParity(_ recorded: Recorded) {
        #expect(
            select(from: recorded.cards, agent: recorded.agent) == recorded.prose,
            "\(recorded.name)")
    }

    @Test func ownerFeedbackIsAddressed() { expectParity(Self.ownerFeedback) }

    @Test func runningChecksPassTheReviewToReady() { expectParity(Self.checksRunning) }
}
