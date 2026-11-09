// What `repairs` decides for each card, from recorded GitHub responses.
//
// Each rule of step 1 in `next-task.md` has a case here. The JSON is GitHub's
// own shape, trimmed to the fields the rules read, so a test fails if the
// parsing drifts from the API as well as if the rule does.
//

import Foundation
import Testing

@testable import BoardCore

@Suite("The step-1 repairs")
struct RepairsTests {

    let loop: Set<String> = ["agent-one", "agent-two"]

    // MARK: Recorded responses

    static let fixtures = "example-org/fixtures"

    func home(_ number: Int) -> PullRequestID {
        PullRequestID(repository: Coordinates.repository, number: number)
    }

    func timeline(
        _ events: [(number: Int, state: String, merged: Bool, body: String)],
        in repository: String = Coordinates.repository, openedBy opener: String = "agent-one"
    ) -> String {
        let rows = events.map { event in
            let merged = event.merged ? "\"2026-10-20T16:37:00Z\"" : "null"
            return """
                {"event": "cross-referenced", "source": {"issue": {"number": \(event.number), \
                "state": "\(event.state)", "body": "\(event.body)", \
                "repository": {"full_name": "\(repository)"}, "user": {"login": "\(opener)"}, \
                "pull_request": {"merged_at": \(merged)}}}}
                """
        }
        return "[{\"event\": \"labeled\"}, " + rows.joined(separator: ", ") + "]"
    }

    func pull(
        mergeable: String = "true", state: String = "blocked", draft: Bool = false,
        openedBy opener: String = "agent-one", base: String = "main", autoMerge: Bool = false
    ) -> String {
        """
        {"head": {"sha": "abc123", "ref": "f/7-work"}, "base": {"ref": "\(base)"}, "user": {"login": "\(opener)"}, "mergeable": \(mergeable), "mergeable_state": "\(state)", "draft": \(draft), "auto_merge": \(autoMerge ? "{}" : "null")}
        """
    }

    func checkRuns(_ runs: [(name: String, conclusion: String)]) -> String {
        let rows = runs.map {
            "{\"name\": \"\($0.name)\", \"status\": \"completed\", \"conclusion\": \"\($0.conclusion)\"}"
        }
        return "{\"total_count\": \(runs.count), \"check_runs\": [" + rows.joined(separator: ", ")
            + "]}"
    }

    let noStatuses = #"{"state": "pending", "total_count": 0, "statuses": []}"#

    func reviewCard(
        _ column: String = "Human Review", design: Bool = false, timelineJSON: String,
        pullJSON: String? = nil, checks: String? = nil, unanswered: [String] = [],
        assignees: [String] = [], mergeGuard: MergeGuardVerdict = .passes
    ) throws -> CardFacts {
        var card = CardFacts(number: 7, column: column, assignees: assignees, isDesign: design)
        card.pullRequests = try linkedPullRequests(issue: 7, timelineJSON: timelineJSON)
        for pullRequest in card.pullRequests where pullRequest.open {
            card.merge[pullRequest.id] = try mergeFacts(pullJSON: pullJSON ?? pull())
            card.checks[pullRequest.id] = try checkFacts(
                checkRunsJSON: checks ?? checkRuns([("C++ tests", "success")]),
                statusJSON: noStatuses)
            card.unansweredFeedback[pullRequest.id] = unanswered
            card.mergeGuard[pullRequest.id] = mergeGuard
        }
        return card
    }

    func decide(_ card: CardFacts, redOnMain: [String: Set<String>] = [:]) -> [String] {
        repairs(for: card, redOnMain: redOnMain, loopLogins: loop).map {
            repairLine($0, card: card.number)
        }
    }

    // MARK: Pull requests

    @Test("The pull request read names its opener, who owns it")
    func opener() throws {
        #expect(try mergeFacts(pullJSON: pull()).opener == "agent-one")
    }

    @Test("A merged design moves to In Progress for its decomposition")
    func mergedDesign() throws {
        let card = try reviewCard(
            design: true, timelineJSON: timeline([(20, "closed", true, "Part of #7.")]))
        #expect(decide(card) == ["MOVE #7 Human Review → In Progress (design PR #20 merged)"])
    }

    @Test("A design merged after an approval sent it to In Design still moves on")
    func mergedDesignInDesign() throws {
        let card = try reviewCard(
            "In Design", design: true, timelineJSON: timeline([(20, "closed", true, "Part of #7.")])
        )
        #expect(decide(card) == ["MOVE #7 In Design → In Progress (design PR #20 merged)"])
    }

    @Test("In Design is left alone while a design pull request is open, or a designer holds it")
    func inDesignOtherwiseUntouched() throws {
        let followUp = try reviewCard(
            "In Design", design: true,
            timelineJSON: timeline([
                (20, "closed", true, "Part of #7."), (21, "open", false, "Part of #7."),
            ]))
        #expect(decide(followUp) == ["ok #7"])

        let claimed = try reviewCard(
            "In Design", design: true,
            timelineJSON: timeline([(20, "closed", true, "Part of #7.")]),
            assignees: ["designer"])
        #expect(decide(claimed) == ["HELD #7 by designer"])

        let unmerged = try reviewCard(
            "In Design", design: true, timelineJSON: timeline([(20, "open", false, "Part of #7.")]))
        #expect(decide(unmerged) == ["ok #7"])
    }

    @Test("A merged code pull request with the issue still open is reported, not moved")
    func mergedCode() throws {
        let card = try reviewCard(timelineJSON: timeline([(21, "closed", true, "Refs #7.")]))
        #expect(decide(card) == ["REPORT #7 PR #21 merged and the issue is still open"])
    }

    @Test("A pull request is matched by its body whatever its number, so an old one is found")
    func oldPullRequestIsFound() throws {
        let card = try reviewCard(
            timelineJSON: timeline([
                (12, "open", false, "Closes #7.\\n\\nOld work."),
                (900, "open", false, "Found while implementing #7."),
            ]))
        #expect(card.pullRequests.map(\.id.number) == [12])
    }

    @Test("A pull request counts as the item's only if one of loop.json's agents opened it")
    func onlyAnAgentsPullRequestCounts() throws {
        let events =
            timeline([(12, "open", false, "Closes #7.")]).dropLast() + ", "
            + timeline([(13, "open", false, "Part of #7.")], openedBy: "a-stranger").dropFirst()
        let linked = try linkedPullRequests(issue: 7, timelineJSON: String(events))
        #expect(linked == [LinkedPullRequest(id: home(12), open: true, merged: false)])
    }

    @Test("A stranger's pull request neither sends the card to review nor holds it")
    func strangersPullRequestIsIgnored() throws {
        let strangers = timeline([(13, "open", false, "Part of #7.")], openedBy: "a-stranger")
        let ready = try reviewCard(
            "Ready", timelineJSON: strangers, pullJSON: pull(openedBy: "a-stranger"))
        #expect(ready.pullRequests.isEmpty)
        #expect(decide(ready) == ["ok #7"])
        let selection = select(
            from: [ready], agent: SelectingAgent(login: "agent-one", roles: [.engineer]))
        #expect(selection.pick == Pick(issue: 7, role: .engineer, task: .start))
        #expect(selection.skipped.isEmpty)
    }

    @Test("Paged timelines are read as JSON, so a body is never rewritten")
    func pagedTimeline() throws {
        let pages = """
            [[{"event": "cross-referenced", "source": {"issue": {"number": 12, "state": "open",
               "body": "Closes #7.\\n\\nA list ][ in prose", "repository": {"full_name": "example-org/example"}, "user": {"login": "agent-two"}, "pull_request": {"merged_at": null}}}}],
             [{"event": "cross-referenced", "source": {"issue": {"number": 13, "state": "closed",
               "body": "Refs #7.", "repository": {"full_name": "example-org/example"}, "user": {"login": "agent-two"}, "pull_request": {"merged_at": "2026-10-20T16:37:00Z"}}}}]]
            """
        let linked = try linkedPullRequests(issue: 7, timelineJSON: pages)
        #expect(
            linked == [
                LinkedPullRequest(id: home(12), open: true, merged: false),
                LinkedPullRequest(id: home(13), open: false, merged: true),
            ])
    }

    @Test("A pull request in another repository is found when it names the issue in full")
    func otherRepositoryIsFound() throws {
        let card = try reviewCard(
            timelineJSON: timeline(
                [
                    (3, "open", false, "Closes example-org/example#7.\\n\\nSchemas."),
                    (4, "open", false, "Closes #7."),
                ], in: Self.fixtures))
        #expect(
            card.pullRequests.map(\.id) == [PullRequestID(repository: Self.fixtures, number: 3)])
    }

    @Test("Owner feedback on a pull request in another repository routes the card")
    func otherRepositoryFeedback() throws {
        let card = try reviewCard(
            timelineJSON: timeline(
                [(3, "open", false, "Closes example-org/example#7.")], in: Self.fixtures),
            unanswered: ["https://github.com/example-org/fixtures/pull/3#review"])
        #expect(
            decide(card) == [
                "MOVE #7 Human Review → In Progress (unanswered owner feedback on "
                    + "PR example-org/fixtures#3: "
                    + "https://github.com/example-org/fixtures/pull/3#review)"
            ])
    }

    @Test("A check is red on main only when it is red on its own repository's main")
    func redOnMainIsPerRepository() throws {
        let card = try reviewCard(
            timelineJSON: timeline(
                [(3, "open", false, "Closes example-org/example#7.")], in: Self.fixtures),
            checks: checkRuns([("Required", "failure")]))
        #expect(
            decide(card, redOnMain: [Coordinates.repository: ["Required"]]) == [
                "MOVE #7 Human Review → In Progress "
                    + "(PR example-org/fixtures#3 fails Required)"
            ])
        #expect(
            decide(card, redOnMain: [Self.fixtures: ["Required"]]) == [
                "REPORT #7 PR example-org/fixtures#3 fails Required, red on main too"
            ])
    }

    @Test("A clean pull request in another repository is named in full for the merge")
    func otherRepositoryMerge() throws {
        let card = try reviewCard(
            timelineJSON: timeline(
                [(3, "open", false, "Closes example-org/example#7.")], in: Self.fixtures),
            pullJSON: pull(state: "clean"))
        #expect(
            decide(card) == ["MERGE #7 PR example-org/fixtures#3 is clean"])
    }

    @Test("A card in a review column with no pull request says so")
    func noPullRequest() throws {
        let card = try reviewCard("Agent Review", timelineJSON: timeline([]))
        #expect(decide(card) == ["REPORT #7 no pull request names it with Closes, Refs or Part of"])
    }

    @Test("A failing check routes the card by its type")
    func failingCheck() throws {
        let card = try reviewCard(
            design: true, timelineJSON: timeline([(22, "open", false, "Part of #7.")]),
            checks: checkRuns([("Formatting", "failure")]))
        #expect(decide(card) == ["MOVE #7 Human Review → In Design (PR #22 fails Formatting)"])
    }

    @Test("A check red on main too is reported, not routed")
    func redOnMainToo() throws {
        let card = try reviewCard(
            timelineJSON: timeline([(23, "open", false, "Closes #7.")]),
            checks: checkRuns([("Web e2e", "failure")]))
        #expect(
            decide(card, redOnMain: [Coordinates.repository: ["Web e2e"]]) == [
                "REPORT #7 PR #23 fails Web e2e, red on main too"
            ])
    }

    @Test("A cancelled check is reported and nothing moves")
    func cancelledCheck() throws {
        let card = try reviewCard(
            "Agent Review", timelineJSON: timeline([(24, "open", false, "Closes #7.")]),
            checks: checkRuns([("Swift tests", "cancelled")]))
        #expect(decide(card) == ["REPORT #7 PR #24 has Swift tests cancelled"])
    }

    @Test("A branch behind main routes the card, though it has no conflict")
    func behind() throws {
        let card = try reviewCard(
            timelineJSON: timeline([(25, "open", false, "Closes #7.")]),
            pullJSON: pull(mergeable: "true", state: "behind"))
        #expect(decide(card) == ["MOVE #7 Human Review → In Progress (PR #25 is behind main)"])
    }

    @Test("A conflict routes the card, and an undecided mergeable does not")
    func conflict() throws {
        let conflicting = try reviewCard(
            timelineJSON: timeline([(26, "open", false, "Closes #7.")]),
            pullJSON: pull(mergeable: "false", state: "dirty"))
        #expect(
            decide(conflicting) == ["MOVE #7 Human Review → In Progress (PR #26 does not merge)"])

        let undecided = try reviewCard(
            timelineJSON: timeline([(26, "open", false, "Closes #7.")]),
            pullJSON: pull(mergeable: "null", state: "unknown"))
        #expect(decide(undecided) == ["ok #7"])
    }

    // A restack the merge guard finds is disarmed by the guard's own repair; see
    // `MergeGuardTests`.
    @Test("Every repair that sends a pull request back turns its armed auto-merge off first")
    func sendBackUnarms() throws {
        let timelineJSON = timeline([(31, "open", false, "Closes #7.")])
        var stacked = try reviewCard(
            timelineJSON: timelineJSON, pullJSON: pull(base: "f/6-parent", autoMerge: true))
        stacked.stack[home(31)] = .broken("its parent closed")
        let cards: [(CardFacts, String)] = [
            (
                try reviewCard(
                    timelineJSON: timelineJSON, pullJSON: pull(autoMerge: true),
                    checks: checkRuns([("Swift tests", "failure")])),
                "PR #31 fails Swift tests"
            ),
            (
                try reviewCard(
                    timelineJSON: timelineJSON, pullJSON: pull(autoMerge: true),
                    unanswered: ["https://x/pull/31#pullrequestreview-1"]),
                "unanswered owner feedback on PR #31: https://x/pull/31#pullrequestreview-1"
            ),
            (
                try reviewCard(
                    timelineJSON: timelineJSON,
                    pullJSON: pull(mergeable: "false", state: "dirty", autoMerge: true)),
                "PR #31 does not merge"
            ),
            (
                try reviewCard(
                    timelineJSON: timelineJSON, pullJSON: pull(state: "behind", autoMerge: true)),
                "PR #31 is behind main"
            ),
            (stacked, "PR #31 has a broken stack: its parent closed"),
        ]
        for (card, reason) in cards {
            #expect(
                decide(card) == [
                    "UNARM #7 auto-merge on PR #31 (\(reason))",
                    "MOVE #7 Human Review → In Progress (\(reason))",
                ])
        }
    }

    @Test("A draft is reported and never merged")
    func draft() throws {
        let card = try reviewCard(
            timelineJSON: timeline([(27, "open", false, "Closes #7.")]),
            pullJSON: pull(state: "clean", draft: true))
        #expect(decide(card) == ["REPORT #7 PR #27 is a draft"])
    }

    @Test("A clean pull request in Human Review is printed for merging")
    func clean() throws {
        let card = try reviewCard(
            timelineJSON: timeline([(28, "open", false, "Closes #7.")]),
            pullJSON: pull(state: "clean"))
        #expect(decide(card) == ["MERGE #7 PR #28 is clean"])
    }

    @Test("An approval is not a request; a change request is, and it outranks the merge")
    func approvalAgainstChangeRequest() throws {
        let reviews = """
            [[{"user": {"login": "example-owner"}, "state": "APPROVED", "body": "",
               "html_url": "https://x/pull/29#pullrequestreview-1", "submitted_at": "2026-10-20T10:00:00Z"},
              {"user": {"login": "example-owner"}, "state": "CHANGES_REQUESTED", "body": "",
               "html_url": "https://x/pull/29#pullrequestreview-2", "submitted_at": "2026-10-20T11:00:00Z"},
              {"user": {"login": "agent-two"}, "state": "COMMENTED", "body": "Review: clean.",
               "html_url": "https://x/pull/29#pullrequestreview-3", "submitted_at": "2026-10-20T12:00:00Z"}]]
            """
        let requests = try ownerReviewRequests(reviewsJSON: reviews, owner: "example-owner")
        #expect(requests.map(\.url) == ["https://x/pull/29#pullrequestreview-2"])

        let card = try reviewCard(
            timelineJSON: timeline([(29, "open", false, "Closes #7.")]),
            pullJSON: pull(state: "clean"),
            unanswered: requests.map(\.url))
        #expect(
            decide(card) == [
                "MOVE #7 Human Review → In Progress "
                    + "(unanswered owner feedback on PR #29: https://x/pull/29#pullrequestreview-2)"
            ])
    }

    @Test("A claimed card is never moved, and its line names who holds it")
    func claimedCardIsHeld() throws {
        let card = try reviewCard(
            timelineJSON: timeline([(30, "open", false, "Closes #7.")]),
            checks: checkRuns([("Formatting", "failure")]), assignees: ["example-owner"])
        #expect(decide(card) == ["HELD #7 by example-owner"])
    }

    @Test("A pending commit status with no statuses is not a pending check")
    func noStatusesIsNotPending() throws {
        let facts = try checkFacts(checkRunsJSON: checkRuns([]), statusJSON: noStatuses)
        #expect(!facts.unfinished)
        let failing = try checkFacts(
            checkRunsJSON: checkRuns([]),
            statusJSON:
                #"{"state": "failure", "total_count": 1, "statuses": [{"context": "ci/x", "state": "failure"}]}"#
        )
        #expect(failing.failing == ["ci/x"])
    }

    @Test("A check's run in a superseded suite is not judged beside its replacement")
    func supersededRunIsIgnored() throws {
        let runs = #"""
            {"total_count": 4, "check_runs": [
              {"id": 20, "name": "Required", "status": "completed", "conclusion": "success"},
              {"id": 21, "name": "Tests", "status": "queued"},
              {"id": 10, "name": "Required", "status": "completed", "conclusion": "failure"},
              {"id": 11, "name": "Tests", "status": "completed", "conclusion": "cancelled"}
            ]}
            """#
        let facts = try checkFacts(checkRunsJSON: runs, statusJSON: noStatuses)
        #expect(facts.failing.isEmpty)
        #expect(facts.needsAPerson.isEmpty)
        #expect(facts.unfinished)
    }

    // MARK: Needs Human

    func comment(_ author: String, _ minute: Int, _ body: String) -> ConversationComment {
        ConversationComment(
            author: author, url: "https://x/issues/7#issuecomment-\(minute)",
            createdAt: Date(timeIntervalSince1970: TimeInterval(minute * 60)), body: body)
    }

    func needsHuman(
        _ comments: [ConversationComment], blockers: [Int: BlockerState] = [:],
        assignees: [String] = []
    )
        -> CardFacts
    {
        var card = CardFacts(
            number: 7, column: "Needs Human", assignees: assignees, isDesign: false)
        card.bailOut = bailOutFacts(comments: comments, loopLogins: loop, owner: "example-owner")
        card.blockers = blockers
        return card
    }

    @Test("An answered bail-out returns to work and spends the question")
    func answeredBailOut() {
        let card = needsHuman([
            comment("agent-one", 1, "PR: #40"),
            comment("agent-two", 2, "Bailing out: which of A or B?"),
            comment("example-owner", 3, "B, please.\nAnd keep it small."),
        ])
        let actions = repairs(for: card, redOnMain: [:], loopLogins: loop)
        #expect(
            actions == [
                .move(
                    from: "Needs Human", to: "In Progress",
                    reason: "the owner answered the bail-out",
                    comment: "Answer received: B, please.")
            ])
    }

    @Test("Work the owner parked, with no bail-out newest, is left alone")
    func parkedWorkStays() {
        let card = needsHuman([
            comment("agent-two", 1, "Bailing out: which?"),
            comment("agent-one", 2, "Answer received: A"),
            comment("example-owner", 3, "Parking this for now."),
        ])
        #expect(decide(card) == ["ok #7"])
    }

    @Test("A bail-out whose blockers have all landed returns to work")
    func clearedBlocker() {
        let card = needsHuman(
            [
                comment(
                    "agent-one", 1,
                    "Bailing out: the registry is on an unmerged PR.\nBlocked-on: #304")
            ],
            blockers: [304: .landed])
        #expect(
            repairs(for: card, redOnMain: [:], loopLogins: loop) == [
                .move(
                    from: "Needs Human", to: "In Progress", reason: "#304 landed",
                    comment: "Blocker cleared: #304 landed.")
            ])
    }

    @Test("A blocker closed without merging is reported, and the card waits")
    func abandonedBlocker() {
        let card = needsHuman(
            [
                comment(
                    "agent-one", 1,
                    "Bailing out: waiting.\nBlocked-on: #304\nBlocked-on: #305")
            ],
            blockers: [304: .landed, 305: .abandoned])
        #expect(decide(card) == ["REPORT #7 blocked on PR #305, closed without merging"])
    }

    @Test("A loop agent's claim in Needs Human is removed; the owner's is not")
    func needsHumanClaims() {
        let card = needsHuman([], assignees: ["agent-one", "example-owner"])
        #expect(decide(card) == ["RELEASE #7 claim by agent-one in Needs Human"])
    }

    // MARK: Claims and the dry run

    @Test("A claim over an hour old gets one notice, and a new claim another")
    func oldClaim() {
        let taken = Date(timeIntervalSince1970: 0)
        let later = taken.addingTimeInterval(staleClaimAge + 60)
        #expect(
            !needsStaleClaimNotice(
                assignedAt: taken, newestNotice: nil, now: taken.addingTimeInterval(600)))
        #expect(needsStaleClaimNotice(assignedAt: taken, newestNotice: nil, now: later))
        #expect(
            !needsStaleClaimNotice(
                assignedAt: taken, newestNotice: taken.addingTimeInterval(10), now: later))
        #expect(
            needsStaleClaimNotice(
                assignedAt: taken.addingTimeInterval(20),
                newestNotice: taken.addingTimeInterval(10),
                now: later.addingTimeInterval(60)))
    }

    @Test("A claim's time is the newest assignment across every timeline page")
    func assignmentAcrossPages() throws {
        let pages = """
            [[{"event": "assigned", "created_at": "2026-10-20T09:00:00Z"},
              {"event": "labeled", "created_at": "2026-10-20T09:30:00Z"}],
             [{"event": "assigned", "created_at": "2026-10-21T10:00:00Z"}]]
            """
        #expect(
            try latestAssignment(timelineJSON: pages)
                == ISO8601DateFormatter().date(from: "2026-10-21T10:00:00Z"))
        #expect(try latestAssignment(timelineJSON: "[[]]") == nil)
    }

    @Test("Without --apply nothing is performed")
    func dryRunPerformsNothing() throws {
        let card = try reviewCard(
            timelineJSON: timeline([(31, "open", false, "Closes #7.")]),
            checks: checkRuns([("Formatting", "failure")]))
        var performed = 0
        let lines = repairLines(for: card, redOnMain: [:], loopLogins: loop, apply: false) { _ in
            performed += 1
            return nil
        }
        #expect(performed == 0)
        #expect(lines == ["MOVE #7 Human Review → In Progress (PR #31 fails Formatting)"])

        _ = repairLines(for: card, redOnMain: [:], loopLogins: loop, apply: true) { _ in
            performed += 1
            return nil
        }
        #expect(performed == 1)
    }
}
