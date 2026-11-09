// What `select` takes, one case per row of step 2's table in `next-task.md`, per
// skip, and per side of pull request ownership.
//

import Testing

@testable import BoardCore

@Suite("Step 2: which item a tick takes")
struct SelectTests {

    static let allRoles: Set<Role> = [.orchestrator, .reviewer, .engineer, .designer]
    func agent(_ login: String = "agent-two", roles: Set<Role> = allRoles) -> SelectingAgent {
        SelectingAgent(login: login, roles: roles)
    }

    func pr(_ number: Int) -> PullRequestID {
        PullRequestID(repository: Coordinates.repository, number: number)
    }

    func card(_ number: Int, in column: String, design: Bool = false) -> CardFacts {
        CardFacts(number: number, column: column, assignees: [], isDesign: design)
    }

    /// A card with one open pull request, `number + 100`, opened by `opener`.
    func withPullRequest(
        _ number: Int, in column: String, opener: String = "agent-one",
        checks: CheckFacts = CheckFacts(), design: Bool = false
    ) -> CardFacts {
        var card = card(number, in: column, design: design)
        let id = pr(number + 100)
        card.pullRequests = [LinkedPullRequest(id: id, open: true, merged: false)]
        card.merge[id] = MergeFacts(
            headSHA: "abc123", branch: "f/7-work", mergeable: true, mergeableState: "blocked",
            draft: false, opener: opener)
        card.checks[id] = checks
        return card
    }

    // MARK: The table, right to left

    @Test func agentReviewComesFirst() {
        let cards = [
            card(1, in: "Ready"), card(2, in: "In Design"), card(3, in: "In Progress"),
            withPullRequest(4, in: "Agent Review"),
        ]
        #expect(
            select(from: cards, agent: agent()).pick
                == Pick(issue: 4, role: .reviewer, task: .review))
    }

    @Test func inProgressComesBeforeDesignAndReady() {
        let cards = [card(1, in: "Ready"), card(2, in: "In Design"), card(3, in: "In Progress")]
        #expect(
            select(from: cards, agent: agent()).pick
                == Pick(issue: 3, role: .engineer, task: .start))
    }

    @Test func inDesignComesBeforeReady() {
        let cards = [card(1, in: "Ready"), card(2, in: "In Design", design: true)]
        #expect(
            select(from: cards, agent: agent()).pick
                == Pick(issue: 2, role: .designer, task: .design))
    }

    @Test func readyIsLastAndTakesTheTopmost() {
        let cards = [card(5, in: "Ready"), card(6, in: "Ready")]
        #expect(
            select(from: cards, agent: agent()).pick
                == Pick(issue: 5, role: .engineer, task: .start))
    }

    @Test func otherColumnsAreNeverTaken() {
        let cards = ["Backlog", "Human Review", "Needs Human", "Done"].enumerated().map {
            card($0.offset + 1, in: $0.element)
        }
        #expect(select(from: cards, agent: agent()) == Selection(pick: nil, skipped: []))
    }

    @Test func aColumnWhoseRoleTheTickDoesNotHoldIsPassedOver() {
        let cards = [withPullRequest(1, in: "Agent Review"), card(2, in: "In Progress")]
        #expect(
            select(from: cards, agent: agent(roles: [.engineer])).pick
                == Pick(issue: 2, role: .engineer, task: .start))
        #expect(select(from: cards, agent: agent(roles: [.orchestrator])).pick == nil)
    }

    // MARK: Ready by role

    @Test func readyGivesADesignToTheDesigner() {
        let cards = [card(1, in: "Ready"), card(2, in: "Ready", design: true)]
        #expect(
            select(from: cards, agent: agent(roles: [.designer])).pick
                == Pick(issue: 2, role: .designer, task: .design))
    }

    @Test func readyGivesTheRestToTheEngineer() {
        let cards = [card(1, in: "Ready", design: true), card(2, in: "Ready")]
        #expect(
            select(from: cards, agent: agent(roles: [.engineer])).pick
                == Pick(issue: 2, role: .engineer, task: .start))
    }

    @Test func readyGivesAnAgentHoldingBothTheTopmost() {
        let cards = [card(1, in: "Ready", design: true), card(2, in: "Ready")]
        #expect(
            select(from: cards, agent: agent()).pick
                == Pick(issue: 1, role: .designer, task: .design))
    }

    // MARK: Skips

    @Test func anEpicIsNeverTaken() {
        var epic = card(1, in: "Ready")
        epic.isEpic = true
        let selection = select(from: [epic, card(2, in: "Ready")], agent: agent())
        #expect(selection.pick?.issue == 2)
        #expect(selection.skipped == [Skip(issue: 1, reason: .epic, detail: nil)])
    }

    @Test func aClaimedItemIsSkippedAndItsHolderNamed() {
        let held = CardFacts(number: 1, column: "Ready", assignees: ["agent-one"], isDesign: false)
        let selection = select(from: [held, card(2, in: "Ready")], agent: agent())
        #expect(selection.pick?.issue == 2)
        #expect(selection.skipped == [Skip(issue: 1, reason: .claimed, detail: "agent-one")])
    }

    @Test func aReadyItemWithAnOpenBlockerIsSkipped() {
        var blocked = card(1, in: "Ready")
        blocked.openBlockers = [8, 9]
        let selection = select(from: [blocked, card(2, in: "Ready")], agent: agent())
        #expect(selection.pick?.issue == 2)
        #expect(selection.skipped == [Skip(issue: 1, reason: .blocked, detail: "#8, #9 open")])
    }

    @Test func aBlockerDoesNotHoldWorkAlreadyStarted() {
        var started = card(1, in: "In Progress")
        started.openBlockers = [8]
        #expect(select(from: [started], agent: agent()).pick?.issue == 1)
    }

    @Test func aReviewWhoseChecksAreRunningIsSkipped() {
        var running = CheckFacts()
        running.unfinished = true
        let cards = [withPullRequest(1, in: "Agent Review", checks: running), card(2, in: "Ready")]
        let selection = select(from: cards, agent: agent())
        #expect(selection.pick?.issue == 2)
        let detail = "\(Coordinates.repository)#101@abc123"
        #expect(selection.skipped == [Skip(issue: 1, reason: .checksRunning, detail: detail)])
        #expect(
            RunningChecks.list(detail) == [
                RunningChecks(pullRequest: pr(101), head: "abc123")
            ])
    }

    @Test func aCancelledCheckIsNotRunning() {
        var cancelled = CheckFacts()
        cancelled.needsAPerson = ["Build cancelled"]
        let cards = [withPullRequest(1, in: "Agent Review", checks: cancelled)]
        #expect(select(from: cards, agent: agent()).pick?.task == .review)
    }

    /// Nothing to read is still a review: the Reviewer sends it back, and an
    /// engineer starts it. Skipping it would leave it in Agent Review for good.
    @Test func aReviewWithNoOpenPullRequestIsTaken() {
        #expect(
            select(from: [card(1, in: "Agent Review")], agent: agent())
                == Selection(pick: Pick(issue: 1, role: .reviewer, task: .review), skipped: []))
    }

    @Test func nothingToTakeIsIdle() {
        #expect(select(from: [], agent: agent()) == Selection(pick: nil, skipped: []))
    }

    // MARK: Ownership

    @Test func anotherAgentsPullRequestIsReviewed() {
        let cards = [withPullRequest(1, in: "Agent Review", opener: "agent-one")]
        #expect(
            select(from: cards, agent: agent("agent-two")).pick
                == Pick(issue: 1, role: .reviewer, task: .review))
    }

    /// Whoever else pushed to it, the opener never reviews it, and nobody
    /// reviews it with a disclosure instead: it waits for an independent reviewer.
    @Test func itsOpenerNeverReviewsIt() {
        let cards = [
            withPullRequest(1, in: "Agent Review", opener: "agent-two"), card(2, in: "Ready"),
        ]
        let selection = select(from: cards, agent: agent("agent-two"))
        #expect(selection.pick?.issue == 2)
        #expect(selection.skipped == [Skip(issue: 1, reason: .openedByThisAgent, detail: nil)])
        #expect(select(from: [cards[0]], agent: agent("agent-two")).pick == nil)
    }

    @Test func itsOpenerTakesItsCorrections() {
        var returned = withPullRequest(1, in: "In Progress", opener: "agent-one")
        returned.reviewerFindings[pr(101)] = "https://example.invalid/findings"
        #expect(
            select(from: [returned], agent: agent("agent-one")).pick
                == Pick(issue: 1, role: .engineer, task: .addressFindings))
    }

    @Test func anotherAgentLeavesItsCorrectionsToItsOpener() {
        var returned = withPullRequest(1, in: "In Progress", opener: "agent-one")
        returned.reviewerFindings[pr(101)] = "https://example.invalid/findings"
        let selection = select(from: [returned, card(2, in: "Ready")], agent: agent("agent-two"))
        #expect(selection.pick?.issue == 2)
        #expect(
            selection.skipped == [
                Skip(issue: 1, reason: .openedByAnotherAgent, detail: "agent-one")
            ])
    }

    @Test func aDesignsRevisionsBelongToItsOpener() {
        let design = withPullRequest(1, in: "In Design", opener: "agent-one", design: true)
        #expect(
            select(from: [design], agent: agent("agent-one")).pick
                == Pick(issue: 1, role: .designer, task: .design))
        let selection = select(from: [design], agent: agent("agent-two"))
        #expect(selection.pick == nil)
        #expect(
            selection.skipped == [
                Skip(issue: 1, reason: .openedByAnotherAgent, detail: "agent-one")
            ])
    }

    @Test func anotherAgentLeavesAnInterruptedPullRequestToItsOpener() {
        let interrupted = withPullRequest(1, in: "In Progress", opener: "agent-one")
        #expect(select(from: [interrupted], agent: agent("agent-two")).pick == nil)
    }

    // MARK: The Engineer's task

    @Test func anOpenPullRequestWithNothingAgainstItIsAssessed() {
        #expect(
            select(
                from: [withPullRequest(1, in: "In Progress", opener: "agent-two")], agent: agent()
            ).pick?.task
                == .assessExisting)
    }

    @Test func eachKindOfFindingIsAddressed() {
        let id = pr(101)
        var red = withPullRequest(1, in: "In Progress", opener: "agent-two")
        red.checks[id]?.failing = ["Build"]
        var feedback = withPullRequest(1, in: "In Progress", opener: "agent-two")
        feedback.unansweredFeedback[id] = ["https://example.invalid/review"]
        var conflict = withPullRequest(1, in: "In Progress", opener: "agent-two")
        conflict.merge[id] = MergeFacts(
            headSHA: "abc123", branch: "f/7-work", mergeable: false, mergeableState: "dirty",
            draft: false, opener: "agent-two")
        var behind = withPullRequest(1, in: "In Progress", opener: "agent-two")
        behind.merge[id] = MergeFacts(
            headSHA: "abc123", branch: "f/7-work", mergeable: true, mergeableState: "behind",
            draft: false, opener: "agent-two")

        for card in [red, feedback, conflict, behind] {
            #expect(select(from: [card], agent: agent()).pick?.task == .addressFindings)
        }
    }

    @Test func aCheckRedOnMainIsNotTheItemsFinding() {
        var card = withPullRequest(1, in: "In Progress", opener: "agent-two")
        card.checks[pr(101)]?.failing = ["Build"]
        let redOnMain = [Coordinates.repository: Set(["Build"])]
        #expect(
            select(from: [card], agent: agent(), redOnMain: redOnMain).pick?.task
                == .assessExisting)
    }

    @Test func aMergedDesignIsDecomposed() {
        var design = card(1, in: "In Progress", design: true)
        design.pullRequests = [LinkedPullRequest(id: pr(101), open: false, merged: true)]
        #expect(
            select(from: [design], agent: agent()).pick
                == Pick(issue: 1, role: .engineer, task: .decompose))
    }
}
