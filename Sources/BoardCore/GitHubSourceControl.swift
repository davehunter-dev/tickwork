import Foundation

/// Pull requests and commits on GitHub. Every call names the repository it was
/// given, which may not be the board's.
///
/// Every read is REST but `formerBases`. The board spends the GraphQL budget, and
/// the merge guard checks it before that one query.
struct GitHubSourceControl: SourceControl {
    /// Whose reviews and comments are requests the loop must answer.
    let owner: String
    private let run: GitHubRunner
    /// RFC 3986's unreserved characters: what a query value keeps as it is. A
    /// branch may hold `#`, `&` or `+`, which would end or change the value.
    private static let queryValueCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    init(owner: String, run: @escaping GitHubRunner = GitHub.run) {
        self.owner = owner
        self.run = run
    }

    func mergeFacts(_ pullRequest: PullRequestID) throws -> MergeFacts {
        try BoardCore.mergeFacts(
            pullJSON: run(["api", "repos/\(pullRequest.repository)/pulls/\(pullRequest.number)"]))
    }

    func checks(in repository: String, at ref: String) throws -> CheckFacts {
        let paths = CheckPaths(repository: repository, ref: ref)
        return try checkFacts(
            checkRunsJSON: run(["api", paths.checkRuns]), statusJSON: run(["api", paths.status]))
    }

    /// Three reads: the owner's reviews; their line comments; and the
    /// conversation, which holds both their comments and the `Answering` lines
    /// that answer all three.
    func unansweredFeedback(_ pullRequest: PullRequestID) throws -> [String] {
        let repository = pullRequest.repository
        let reviews = try ownerReviewRequests(
            reviewsJSON: run([
                "api", "--paginate", "--slurp",
                "repos/\(repository)/pulls/\(pullRequest.number)/reviews?per_page=100",
            ]),
            owner: owner)
        let lines = try GitHub.rows(
            "repos/\(repository)/pulls/\(pullRequest.number)/comments",
            select: "select(.user.login == \"\(owner)\")",
            fields: ".html_url, .created_at", run: run)
        let conversation = try GitHub.comments(on: pullRequest.number, in: repository, run: run)

        let feedback =
            try reviews
            + lines.map { OwnerFeedback(url: $0[0], createdAt: try date($0[1])) }
            + conversation.filter { $0.author == owner }.map {
                OwnerFeedback(url: $0.url, createdAt: $0.createdAt)
            }

        return BoardCore.unansweredFeedback(feedback, conversation: conversation)
    }

    /// A pull request's events are on the issues endpoint under its own number.
    func events(on pullRequest: PullRequestID, since: Date) throws -> [TimelineEvent] {
        try timelineEvents(
            timelineJSON: run([
                "api", "--paginate", "--slurp",
                "repos/\(pullRequest.repository)/issues/\(pullRequest.number)/timeline?per_page=100",
            ])
        ).filter { $0.createdAt >= since }
    }

    func conversation(_ pullRequest: PullRequestID) throws -> [ConversationComment] {
        try GitHub.comments(on: pullRequest.number, in: pullRequest.repository, run: run)
    }

    func comment(on pullRequest: PullRequestID, body: String) throws {
        _ = try run([
            "pr", "comment", String(pullRequest.number), "--repo", pullRequest.repository,
            "--body", body,
        ])
    }

    func assign(_ pullRequest: PullRequestID, to login: String) throws {
        _ = try run([
            "pr", "edit", String(pullRequest.number), "--repo", pullRequest.repository,
            "--add-assignee", login,
        ])
    }

    func requestReview(_ pullRequest: PullRequestID, from login: String) throws {
        _ = try run([
            "pr", "edit", String(pullRequest.number), "--repo", pullRequest.repository,
            "--add-reviewer", login,
        ])
    }

    /// Issues and pull requests share the lock endpoint.
    func lock(_ pullRequest: PullRequestID) throws {
        _ = try run([
            "api", "--method", "PUT",
            "repos/\(pullRequest.repository)/issues/\(pullRequest.number)/lock",
        ])
    }

    func reviews(_ pullRequest: PullRequestID) throws -> [PullRequestReview] {
        try pullRequestReviews(
            reviewsJSON: run([
                "api", "--paginate", "--slurp",
                "repos/\(pullRequest.repository)/pulls/\(pullRequest.number)/reviews?per_page=100",
            ]))
    }

    func approve(_ pullRequest: PullRequestID, commit: String, body: String) throws {
        _ = try run([
            "api", "--method", "POST",
            "repos/\(pullRequest.repository)/pulls/\(pullRequest.number)/reviews",
            "-f", "commit_id=\(commit)", "-f", "event=APPROVE", "-f", "body=\(body)",
        ])
    }

    func reviewDecision(_ pullRequest: PullRequestID) throws -> String {
        try run([
            "pr", "view", String(pullRequest.number), "--repo", pullRequest.repository,
            "--json", "reviewDecision", "--jq", ".reviewDecision",
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func enableAutoMerge(_ pullRequest: PullRequestID) throws {
        _ = try run([
            "pr", "merge", String(pullRequest.number), "--repo", pullRequest.repository,
            "--auto", "--squash",
        ])
    }

    func disableAutoMerge(_ pullRequest: PullRequestID) throws {
        _ = try run([
            "pr", "merge", String(pullRequest.number), "--repo", pullRequest.repository,
            "--disable-auto",
        ])
    }

    func merge(_ pullRequest: PullRequestID, head: String) throws {
        _ = try run([
            "pr", "merge", String(pullRequest.number), "--repo", pullRequest.repository,
            "--squash", "--match-head-commit", head,
        ])
    }

    func allowsAutoMerge(in repository: String) throws -> Bool {
        try run(["api", "repos/\(repository)", "--jq", ".allow_auto_merge"])
            .trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    func mainRules(in repository: String) throws -> BranchRules {
        try branchRules(rulesJSON: run(["api", "repos/\(repository)/rules/branches/main"]))
    }

    func formerBases(_ pullRequest: PullRequestID) throws -> [String] {
        let parts = pullRequest.repository.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            throw BoardError("\(pullRequest.repository) is not owner/name")
        }
        return try BoardCore.formerBases(
            timelineJSON: run([
                "api", "graphql", "--paginate", "--slurp",
                "-F", "number=\(pullRequest.number)", "-f", "owner=\(parts[0])",
                "-f", "name=\(parts[1])", "-f", "query=\(formerBaseQuery)",
            ]))
    }

    /// The head is qualified by the repository's owner, so a fork's branch of the
    /// same name isn't counted.
    func pullRequests(in repository: String, from branch: String) throws -> [BranchPullRequest] {
        let owner = repository.split(separator: "/").first.map(String.init) ?? repository
        let head =
            branch.addingPercentEncoding(withAllowedCharacters: Self.queryValueCharacters) ?? branch
        return try branchPullRequests(
            pullsJSON: run([
                "api", "--paginate", "--slurp",
                "repos/\(repository)/pulls?head=\(owner):\(head)&state=all&per_page=100",
            ]))
    }

    func behindBy(in repository: String, base: String, head: String) throws -> Int {
        let answer = try run([
            "api", "repos/\(repository)/compare/\(base)...\(head)", "--jq", ".behind_by",
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let behind = Int(answer) else {
            throw BoardError("compare \(base)...\(head) in \(repository) answered \(answer)")
        }
        return behind
    }
}

/// The two reads `checkFacts` judges a commit from.
struct CheckPaths: Hashable {
    let checkRuns: String
    let status: String

    init(repository: String, ref: String) {
        let commit = "repos/\(repository)/commits/\(ref)"
        checkRuns = commit + "/check-runs?filter=latest&per_page=100"
        status = commit + "/status"
    }
}
