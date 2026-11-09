// Finding an issue's pull requests through its `PR:` lines, which is the only
// link a locked issue keeps: GitHub writes no cross-reference onto one.
//

import Foundation
import Testing

@testable import BoardCore

@Suite("Pull requests recorded by a PR: line")
struct RecordedLinkTests {

    static let other = "example-org/fixtures"

    static func comment(_ body: String, by author: String) -> String {
        let body = body.replacingOccurrences(of: "\n", with: "\\n")
        return #"{"event": "commented", "user": {"login": "\#(author)"}, "body": "\#(body)"}"#
    }

    static func pull(
        _ number: Int, in repository: String = Coordinates.repository, state: String = "open",
        body: String = "Closes #7.", openedBy opener: String = "agent-one",
        merged: Bool = false
    ) -> String {
        let mergedAt = merged ? #""2026-11-01T12:00:00Z""# : "null"
        return """
            {"number": \(number), "state": "\(state)", "merged_at": \(mergedAt),
             "updated_at": "2026-11-01T11:00:00Z", "body": "\(body)",
             "user": {"login": "\(opener)"}, "base": {"repo": {"full_name": "\(repository)"}}}
            """
    }

    static func home(_ number: Int) -> PullRequestID {
        PullRequestID(repository: Coordinates.repository, number: number)
    }

    @Test("PR: lines by an agent or the owner are read, in either form, once each")
    func readsRecordedLines() throws {
        let json =
            "[["
            + [
                Self.comment("PR: #12\n\n<!-- tickwork:finish -->", by: "agent-one"),
                Self.comment("PR: \(Self.other)#3", by: "example-owner"),
                Self.comment("PR: #12", by: "agent-two"),
                Self.comment("PR: #40", by: "a-stranger"),
                Self.comment("See PR: #41, and PR: soon", by: "agent-one"),
            ].joined(separator: ",") + "]]"
        #expect(
            try recordedPullRequests(timelineJSON: json)
                == [Self.home(12), PullRequestID(repository: Self.other, number: 3)])
    }

    @Test("A pull request read directly links on a cross-reference's terms")
    func judgesAPullRequest() throws {
        let read = try #require(
            try pullRequestLink(issue: 7, pullJSON: Self.pull(12, merged: true)))
        #expect(read.link == LinkedPullRequest(id: Self.home(12), open: true, merged: true))
        #expect(read.updatedAt == (try date("2026-11-01T11:00:00Z")))
        #expect(
            try pullRequestLink(issue: 7, pullJSON: Self.pull(12, openedBy: "a-stranger")) == nil)
        #expect(try pullRequestLink(issue: 7, pullJSON: Self.pull(12, body: "Closes #8.")) == nil)
        // A bare `#7` in another repository is that repository's own issue.
        #expect(try pullRequestLink(issue: 7, pullJSON: Self.pull(3, in: Self.other)) == nil)
    }

    @Test("A locked issue's pull request is found through its PR: line")
    func boardFindsRecordedPullRequest() throws {
        var calls: [String] = []
        let board = GitHubBoard(configuration: Coordinates.configuration) { arguments in
            let line = arguments.joined(separator: " ")
            calls.append(line)
            if line.contains("issues/7/timeline") {
                return "[[" + Self.comment("PR: #12", by: "agent-one") + "]]"
            }
            if line.hasSuffix("pulls/12") { return Self.pull(12) }
            return ""
        }
        #expect(
            try board.linkedPullRequests(of: 7)
                == [LinkedPullRequest(id: Self.home(12), open: true, merged: false)])
        #expect(calls.filter { $0.hasSuffix("pulls/12") }.count == 1)
    }

    @Test("A pull request both cross-referenced and recorded is read from the timeline alone")
    func crossReferenceIsNotRead() throws {
        var pullReads = 0
        let board = GitHubBoard(configuration: Coordinates.configuration) { arguments in
            let line = arguments.joined(separator: " ")
            if line.contains("/timeline") {
                return """
                    [[{"event": "cross-referenced", "source": {"issue": {"number": 12,
                    "state": "open", "body": "Closes #7.",
                    "repository": {"full_name": "\(Coordinates.repository)"},
                    "user": {"login": "agent-one"}, "pull_request": {"merged_at": null}}}},
                    \(Self.comment("PR: #12", by: "agent-one"))]]
                    """
            }
            if line.contains("/pulls/") { pullReads += 1 }
            return ""
        }
        #expect(try board.linkedPullRequests(of: 7).map(\.id) == [Self.home(12)])
        #expect(pullReads == 0)
    }

    @Test("finish's check reads the pull request itself, not the issue's timeline")
    func finishCheckReadsThePullRequest() throws {
        var calls: [String] = []
        let board = GitHubBoard(configuration: Coordinates.configuration) { arguments in
            let line = arguments.joined(separator: " ")
            calls.append(line)
            return line.hasSuffix("pulls/12") ? Self.pull(12) : ""
        }
        #expect(try board.linkedPullRequest(Self.home(12), of: 7) != nil)
        #expect(try board.linkedPullRequest(Self.home(12), of: 8) == nil)
        #expect(!calls.contains { $0.contains("/timeline") })
    }

    @Test("The supervisor watches an open recorded pull request, with its own updated_at")
    func supervisorWatchesRecorded() throws {
        let json =
            "["
            + [
                Self.comment("PR: #12", by: "example-owner"),
                Self.comment("PR: #13", by: "agent-one"),
            ].joined(separator: ",") + "]"
        let watched = try watchedPullRequests(
            issue: 7, timelineJSON: json, home: Coordinates.repository, agents: ["agent-one"],
            owner: "example-owner"
        ) { id in
            id.number == 12 ? Self.pull(12) : Self.pull(13, state: "closed")
        }
        #expect(
            watched == [
                WatchedPullRequest(
                    id: Self.home(12), updatedAt: try date("2026-11-01T11:00:00Z"))
            ])
    }
}
