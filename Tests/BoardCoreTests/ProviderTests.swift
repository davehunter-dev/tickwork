// The provider seams: which repository each call lands in, and the timeline
// events later steps prove their writes with.
//
// The timelines are recorded from GitHub, trimmed to the fields read and with the
// logins replaced by the sample's.
//

import Foundation
import Testing

@testable import BoardCore

@Suite("The provider seams")
struct ProviderTests {

    static let issues = Coordinates.repository
    static let code = "example-org/fixtures"

    func at(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    // MARK: Recorded timelines

    /// An issue claimed, moved and released by two agents, then closed by the
    /// owner, with the project's own automation moving it too. The fifth row is
    /// GitHub's whole status-change event, so what it carries is visible.
    static let issueTimeline = """
        [[
        {"event":"labeled","actor":{"login":"example-owner"},"created_at":"2026-10-26T23:56:41Z","label":{"name":"type:feature","color":"a2eeef"}},
        {"event":"added_to_project_v2","actor":{"login":"github-project-automation[bot]"},"created_at":"2026-10-26T23:56:42Z"},
        {"event":"assigned","actor":{"login":"agent-one"},"created_at":"2026-10-27T00:17:55Z","assignee":{"login":"agent-one"}},
        {"event":"unassigned","actor":{"login":"agent-one"},"created_at":"2026-10-27T00:19:33Z","assignee":{"login":"agent-one"}},
        {"id":34317837505,"node_id":"PVTISC_lADOThVFwM8AAAABaKAL8M8AAAAH_YCkwQ","actor":{"login":"agent-one"},"event":"project_v2_item_status_changed","commit_id":null,"commit_url":null,"created_at":"2026-10-27T00:19:33Z","performed_via_github_app":null}
        ],[
        {"event":"assigned","actor":{"login":"agent-two"},"created_at":"2026-10-28T13:34:43Z","assignee":{"login":"agent-two"}},
        {"event":"unassigned","actor":{"login":"agent-two"},"created_at":"2026-10-28T13:38:03Z","assignee":{"login":"agent-two"}},
        {"event":"closed","actor":{"login":"example-owner"},"created_at":"2026-10-28T14:58:33Z"},
        {"event":"project_v2_item_status_changed","actor":{"login":"github-project-automation[bot]"},"created_at":"2026-10-28T14:58:35Z"}
        ]]
        """

    /// A pull request an agent asked the owner to review, and another agent then
    /// assigned to them. GitHub's `reviewed` row has no `actor` or `created_at`.
    static let pullRequestTimeline = """
        [[
        {"event":"review_requested","actor":{"login":"agent-one"},"created_at":"2026-10-28T13:51:07Z","requested_reviewer":{"login":"example-owner"}},
        {"event":"assigned","actor":{"login":"agent-two"},"created_at":"2026-10-28T15:18:05Z","assignee":{"login":"example-owner"}},
        {"event":"reviewed","actor":null,"user":{"login":"example-owner"},"submitted_at":"2026-10-28T16:00:00Z"}
        ]]
        """

    /// An issue's moves as GraphQL records them, over two pages: added to the
    /// board by the project's automation, made ready by the owner, moved on by the
    /// automation when a pull request linked, then by two agents. The last row of
    /// the first page is not recorded: it is the same kind of move on another
    /// owner's project, which an issue can also be on.
    static let statusChangeTimeline = """
        [{"data":{"repository":{"issue":{"timelineItems":{
        "pageInfo":{"hasNextPage":true,"endCursor":"Y3Vyc29yOjQ="},
        "nodes":[
        {"createdAt":"2026-10-28T16:53:03Z","actor":{"login":"github-project-automation"},"previousStatus":"","status":"Backlog","project":{"number":1,"owner":{"login":"example-org"}}},
        {"createdAt":"2026-10-28T17:35:41Z","actor":{"login":"example-owner"},"previousStatus":"Backlog","status":"Ready","project":{"number":1,"owner":{"login":"example-org"}}},
        {"createdAt":"2026-10-28T18:00:13Z","actor":{"login":"github-project-automation"},"previousStatus":"Ready","status":"In Progress","project":{"number":1,"owner":{"login":"example-org"}}},
        {"createdAt":"2026-10-28T18:01:00Z","actor":{"login":"example-owner"},"previousStatus":"Todo","status":"Done","project":{"number":1,"owner":{"login":"another-org"}}}
        ]}}}}},
        {"data":{"repository":{"issue":{"timelineItems":{
        "pageInfo":{"hasNextPage":false,"endCursor":"Y3Vyc29yOjc="},
        "nodes":[
        {"createdAt":"2026-10-28T18:04:07Z","actor":{"login":"agent-one"},"previousStatus":"In Progress","status":"Agent Review","project":{"number":1,"owner":{"login":"example-org"}}},
        {"createdAt":"2026-10-28T18:09:11Z","actor":{"login":"agent-two"},"previousStatus":"Agent Review","status":"Human Review","project":{"number":1,"owner":{"login":"example-org"}}},
        {"createdAt":"2026-10-28T18:21:14Z","actor":{"login":"agent-two"},"previousStatus":"Human Review","status":"In Progress","project":{"number":1,"owner":{"login":"example-org"}}},
        {"createdAt":"2026-10-28T18:22:23Z","actor":{"login":"agent-one"},"previousStatus":"In Progress","status":"Needs Human","project":{"number":1,"owner":{"login":"example-org"}}}
        ]}}}}}]
        """

    @Test("Each proof event on an issue is read with its actor, across pages")
    func issueProofEvents() throws {
        let events = try timelineEvents(timelineJSON: Self.issueTimeline)
        #expect(
            events == [
                TimelineEvent(
                    kind: .labeled, actor: "example-owner", subject: "type:feature",
                    createdAt: at("2026-10-26T23:56:41Z")),
                TimelineEvent(
                    kind: .assigned, actor: "agent-one", subject: "agent-one",
                    createdAt: at("2026-10-27T00:17:55Z")),
                TimelineEvent(
                    kind: .unassigned, actor: "agent-one", subject: "agent-one",
                    createdAt: at("2026-10-27T00:19:33Z")),
                TimelineEvent(
                    kind: .assigned, actor: "agent-two", subject: "agent-two",
                    createdAt: at("2026-10-28T13:34:43Z")),
                TimelineEvent(
                    kind: .unassigned, actor: "agent-two", subject: "agent-two",
                    createdAt: at("2026-10-28T13:38:03Z")),
                TimelineEvent(
                    kind: .closed, actor: "example-owner", subject: nil,
                    createdAt: at("2026-10-28T14:58:33Z")),
            ])
    }

    @Test("The REST timeline's status change names no column, so it is not read")
    func restStatusChangeNamesNoColumn() throws {
        let pages =
            try JSONSerialization.jsonObject(with: Data(Self.issueTimeline.utf8))
            as! [[[String: Any]]]
        let whole = pages[0][4]
        #expect(whole["event"] as? String == "project_v2_item_status_changed")
        #expect(
            Set(whole.keys) == [
                "id", "node_id", "actor", "event", "commit_id", "commit_url", "created_at",
                "performed_via_github_app",
            ])
    }

    @Test("Each move is read with its actor and both columns, across pages, on this board only")
    func statusChangeProofs() throws {
        let changes = try statusChanges(
            timelineJSON: Self.statusChangeTimeline, projectOwner: "example-org", projectNumber: 1)
        func move(_ actor: String, _ from: String?, _ to: String, _ time: String) -> StatusChange {
            StatusChange(actor: actor, from: from, to: to, createdAt: at(time))
        }
        #expect(
            changes == [
                move("github-project-automation", nil, "Backlog", "2026-10-28T16:53:03Z"),
                move("example-owner", "Backlog", "Ready", "2026-10-28T17:35:41Z"),
                move("github-project-automation", "Ready", "In Progress", "2026-10-28T18:00:13Z"),
                move("agent-one", "In Progress", "Agent Review", "2026-10-28T18:04:07Z"),
                move("agent-two", "Agent Review", "Human Review", "2026-10-28T18:09:11Z"),
                move("agent-two", "Human Review", "In Progress", "2026-10-28T18:21:14Z"),
                move("agent-one", "In Progress", "Needs Human", "2026-10-28T18:22:23Z"),
            ])
    }

    @Test("Each proof event on a pull request is read with its actor and subject")
    func pullRequestProofEvents() throws {
        #expect(
            try timelineEvents(timelineJSON: Self.pullRequestTimeline) == [
                TimelineEvent(
                    kind: .reviewRequested, actor: "agent-one", subject: "example-owner",
                    createdAt: at("2026-10-28T13:51:07Z")),
                TimelineEvent(
                    kind: .assigned, actor: "agent-two", subject: "example-owner",
                    createdAt: at("2026-10-28T15:18:05Z")),
            ])
    }

    @Test("A claim's time is the newest assignment in the recorded timeline")
    func claimTimeFromRecording() throws {
        #expect(
            latestAssignment(in: try timelineEvents(timelineJSON: Self.issueTimeline))
                == at("2026-10-28T13:34:43Z"))
    }

    // MARK: Which repository each call lands in

    /// Answers `gh` calls by their shape and records every one.
    final class Recorder {
        private(set) var calls: [[String]] = []
        private var claimedBy: String?

        func run(_ arguments: [String]) throws -> String {
            calls.append(arguments)
            let line = arguments.joined(separator: " ")
            func has(_ text: String) -> Bool { line.contains(text) }

            if has("api user") { return "agent-one\n" }
            if has("api graphql") { return ProviderTests.statusChangeTimeline }
            if has("--add-assignee") {
                claimedBy = arguments.last
                return ""
            }
            if has("--json assignees") { return claimedBy.map { "\($0)\n" } ?? "" }
            if has("/timeline") {
                return """
                    [[{"event": "cross-referenced", "source": {"issue": {"number": 31,
                    "state": "open", "body": "Closes \(ProviderTests.issues)#7.",
                    "repository": {"full_name": "\(ProviderTests.code)"},
                    "user": {"login": "agent-one"},
                    "pull_request": {"merged_at": null}}}}]]
                    """
            }
            if has("/comments") { return "" }
            if has("/reviews") { return "[[]]" }
            if has("/check-runs") { return #"{"total_count": 0, "check_runs": []}"# }
            if has("/status") { return #"{"state": "pending", "total_count": 0, "statuses": []}"# }
            if has("/pulls/31") {
                return
                    #"{"head": {"sha": "abc123", "ref": "f/7-work"}, "base": {"ref": "main"}, "user": {"login": "agent-one"}, "mergeable": true, "mergeable_state": "blocked"}"#
            }
            if has("dependencies/blocked_by") && !has("-F") && !has("DELETE") {
                return #"[{"number": 3, "id": 33}]"#
            }
            if has("--jq .id") { return "44\n" }
            if has("blockedBy,body") { return "3\u{0}body" }
            if has("issue create") {
                return "https://github.com/\(ProviderTests.issues)/issues/9\n"
            }
            if has("--json number,body") { return "[]" }
            if has("issues/3 --jq .number") { return "3\n" }
            if line.hasSuffix("issues/3") { return #"{"state": "open"}"# }
            return ""
        }

        /// Every repository a call names, by path, `--repo`, search qualifier or
        /// GraphQL `owner` and `name` variables.
        static func repositories(in arguments: [String]) -> Set<String> {
            var found: Set<String> = []
            func variable(_ name: String) -> String? {
                arguments.first { $0.hasPrefix("\(name)=") }.map {
                    String($0.dropFirst(name.count + 1))
                }
            }
            if let owner = variable("owner"), let name = variable("name") {
                found.insert("\(owner)/\(name)")
            }
            for (index, argument) in arguments.enumerated() {
                if argument == "--repo", index + 1 < arguments.count {
                    found.insert(arguments[index + 1])
                }
                for marker in ["repos/", "repo:"] {
                    for piece in argument.components(separatedBy: marker).dropFirst() {
                        let parts = piece.split(separator: "/", maxSplits: 2)
                        guard parts.count >= 2 else { continue }
                        let name = parts[1].prefix { !"/? ".contains($0) }
                        found.insert("\(parts[0])/\(name)")
                    }
                }
            }
            return found
        }
    }

    @Test(
        "With the issue in one repository and its pull request in another, each seam's calls land in its own"
    )
    func callsLandInTheirOwnRepository() throws {
        let boardCalls = Recorder()
        let sourceCalls = Recorder()
        let board = GitHubBoard(configuration: Coordinates.configuration, run: boardCalls.run)
        let source = GitHubSourceControl(owner: Coordinates.ownerLogin, run: sourceCalls.run)
        #expect(Self.issues != Self.code)

        let linked = try board.linkedPullRequests(of: 7)
        #expect(linked.map(\.id) == [PullRequestID(repository: Self.code, number: 31)])
        _ = try board.labels(of: 7)
        try board.comment(on: 7, body: "PR: \(Self.code)#31")
        _ = try board.comments(on: 7)
        _ = try board.events(on: 7, since: .distantPast)
        #expect(try board.statusChanges(on: 7, since: .distantPast).count == 7)
        #expect(try board.claim(7, as: "agent-one") == .claimed)
        try board.release(7, login: "agent-one")
        _ = try board.claimedIssues()
        #expect(try board.createIssue(IssueDraft(title: "Gap", body: "b", labels: [])) == 9)
        _ = try board.hasOpenIssue(titled: "Gap")
        _ = try board.issues(createdBy: "agent-one", since: .distantPast)
        _ = try board.openIssues(limit: 10)
        _ = try board.issueNumbers(limit: 10)
        #expect(board.existence(of: 3) == .exists)
        #expect(try board.blockers(of: 7) == [3])
        #expect(try board.landing(of: 3) == .open)
        #expect(try board.addBlocker(5, to: 7))
        #expect(try board.removeBlocker(3, from: 7))
        try board.closeIssue(7)

        let pullRequest = linked[0].id
        let head = try source.mergeFacts(pullRequest).headSHA
        _ = try source.checks(in: pullRequest.repository, at: head)
        _ = try source.unansweredFeedback(pullRequest)
        _ = try source.events(on: pullRequest, since: .distantPast)
        _ = try source.conversation(pullRequest)
        try source.comment(on: pullRequest, body: "Findings.")
        try source.assign(pullRequest, to: "example-owner")
        try source.requestReview(pullRequest, from: "example-owner")

        for call in boardCalls.calls where call != ["api", "user", "--jq", ".login"] {
            #expect(Recorder.repositories(in: call) == [Self.issues], "\(call)")
        }
        for call in sourceCalls.calls {
            #expect(Recorder.repositories(in: call) == [Self.code], "\(call)")
        }
    }

    @Test("A former base's branch is encoded as a query value, so it asks about that head alone")
    func branchQueryEncoded() throws {
        var calls: [[String]] = []
        let source = GitHubSourceControl(owner: Coordinates.ownerLogin) {
            calls.append($0)
            return "[[]]"
        }
        _ = try source.pullRequests(in: Self.code, from: "f/6 feat#2&a+b")
        let owner = Self.code.split(separator: "/")[0]
        #expect(
            calls.last?.last
                == "repos/\(Self.code)/pulls?head=\(owner):f%2F6%20feat%232%26a%2Bb&state=all&per_page=100"
        )
    }

    @Test("The guarded merge is bound to its head, and auto-merge is turned off by name")
    func mergeWritesShaped() throws {
        var calls: [[String]] = []
        let source = GitHubSourceControl(owner: Coordinates.ownerLogin) {
            calls.append($0)
            return ""
        }
        let pullRequest = PullRequestID(repository: Self.code, number: 31)
        try source.merge(pullRequest, head: "abc123")
        try source.disableAutoMerge(pullRequest)
        #expect(
            calls == [
                [
                    "pr", "merge", "31", "--repo", Self.code, "--squash", "--match-head-commit",
                    "abc123",
                ],
                ["pr", "merge", "31", "--repo", Self.code, "--disable-auto"],
            ])
    }

    // MARK: The repairs over fakes

    @Test("The repairs read the pull request where it lives and act on the issue's board")
    func repairsOverFakes() throws {
        let board = FakeBoard()
        board.board = Board(
            items: [
                Item(id: "a", number: 7, title: "Seven", status: "Agent Review", assignees: [])
            ],
            statusFieldID: "status", optionIDs: [:], columns: [])
        let pullRequest = PullRequestID(repository: Self.code, number: 31)
        board.linked[7] = [LinkedPullRequest(id: pullRequest, open: true, merged: false)]

        let source = FakeSourceControl()
        source.merge[pullRequest] = MergeFacts(
            headSHA: "abc123", branch: "f/7-work", mergeable: true, mergeableState: "blocked",
            draft: false, opener: "agent-one")
        source.checks["\(Self.code)@abc123"] = CheckFacts(failing: ["Formatting"])

        try repairs(snapshot: board.board, board: board, source: source, apply: true)

        #expect(board.moves == [.init(issue: 7, to: "In Progress", from: "Agent Review")])
        #expect(Set(source.repositories) == [Self.issues, Self.code])
        #expect(source.repositories.filter { $0 == Self.issues }.count == 1)
    }
}
