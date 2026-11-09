import Foundation

// The two seams between the loop's rules and the services they act on. See
// "Provider seams" in docs/orchestration-in-swift.md.
//
// **The issue repository and the source repository stay apart.** A
// `BoardProvider` is built for `loop.json`'s `repository` and `project` and takes
// no repository argument, so nothing can point it at a pull request's
// repository. `SourceControl` takes its repository in every call. A project may
// track its issues in one repository and keep its code in another.

/// The board and the issue repository behind it.
protocol BoardProvider {
    /// The cards and columns, from a cache unless `refresh` asks for a fresh read.
    func snapshot(refresh: Bool) throws -> Board
    func budget() throws -> GraphQLBudget

    /// Moves a card, refusing when `expected` names a column it is not in.
    func move(_ issue: Int, to column: String, from expected: String?) throws

    /// The login this provider acts as.
    func viewer() throws -> String
    /// Read, add, read back: see `ClaimResult`.
    func claim(_ issue: Int, as login: String) throws -> ClaimResult
    func release(_ issue: Int, login: String) throws
    /// Every open issue somebody is assigned to, pull requests excluded.
    func claimedIssues() throws -> [ClaimedIssue]

    func labels(of issue: Int) throws -> [String]
    /// Whether the issue's conversation is locked.
    func isLocked(_ issue: Int) throws -> Bool
    func comment(on issue: Int, body: String) throws
    /// From anyone, oldest first.
    func comments(on issue: Int) throws -> [ConversationComment]
    /// The issue's timeline, oldest first, keeping only the kinds `TimelineEvent`
    /// names.
    func events(on issue: Int, since: Date) throws -> [TimelineEvent]
    /// The issue's card moving between this board's columns, oldest first.
    func statusChanges(on issue: Int, since: Date) throws -> [StatusChange]
    /// The pull requests, in any repository, that name the issue as their work.
    func linkedPullRequests(of issue: Int) throws -> [LinkedPullRequest]
    /// The pull request, read directly, if it names the issue as its work.
    func linkedPullRequest(_ id: PullRequestID, of issue: Int) throws -> LinkedPullRequest?

    func createIssue(_ draft: IssueDraft) throws -> Int
    /// Puts the issue on the board unless it is already there, and answers its
    /// column, or nil when it has none yet. A project's own add workflow may have
    /// put it in a column the loop does not read.
    func addToBoard(_ issue: Int) throws -> String?
    /// Sets the column of a card `addToBoard` answered for, whichever column it
    /// is in now.
    func place(_ issue: Int, in column: String) throws
    func closeIssue(_ issue: Int) throws
    func hasOpenIssue(titled title: String) throws -> Bool
    /// Issues `login` opened at or after `since`, in every state.
    func issues(createdBy login: String, since: Date) throws -> [IssueSummary]
    func openIssues(limit: Int) throws -> [IssueSummary]
    /// Every issue and pull request number, in every state.
    func issueNumbers(limit: Int) throws -> Set<Int>
    func existence(of number: Int) -> IssueExistence

    /// What still holds the issue, by either record: see `GitHubBoard.blockers`.
    func blockers(of issue: Int) throws -> [Int]
    /// Whether an issue or pull request a `Blocked-on:` line names has landed.
    func landing(of number: Int) throws -> BlockerState
    /// `false` when the relation was already there.
    func addBlocker(_ blocker: Int, to issue: Int) throws -> Bool
    /// `false` when there was no such relation.
    func removeBlocker(_ blocker: Int, from issue: Int) throws -> Bool
}

/// Pull requests and commits, in whichever repository each lives.
protocol SourceControl {
    func mergeFacts(_ pullRequest: PullRequestID) throws -> MergeFacts
    /// The checks and statuses on `ref`, a commit or a branch.
    func checks(in repository: String, at ref: String) throws -> CheckFacts
    /// The urls of the owner's feedback that nothing has answered, oldest first.
    func unansweredFeedback(_ pullRequest: PullRequestID) throws -> [String]
    /// The pull request's timeline, oldest first, keeping only the kinds
    /// `TimelineEvent` names.
    func events(on pullRequest: PullRequestID, since: Date) throws -> [TimelineEvent]
    /// The pull request's conversation, from anyone, oldest first.
    func conversation(_ pullRequest: PullRequestID) throws -> [ConversationComment]
    func comment(on pullRequest: PullRequestID, body: String) throws
    func assign(_ pullRequest: PullRequestID, to login: String) throws
    func requestReview(_ pullRequest: PullRequestID, from login: String) throws
    /// Locks the pull request's conversation.
    func lock(_ pullRequest: PullRequestID) throws

    /// Every review on the pull request, oldest first.
    func reviews(_ pullRequest: PullRequestID) throws -> [PullRequestReview]
    /// Submits an `APPROVE` review of `commit`, with `body`, so it never covers a
    /// later push.
    func approve(_ pullRequest: PullRequestID, commit: String, body: String) throws
    /// GitHub's `reviewDecision`: `APPROVED`, `CHANGES_REQUESTED`,
    /// `REVIEW_REQUIRED`, or empty when the repository requires no review.
    func reviewDecision(_ pullRequest: PullRequestID) throws -> String
    /// Turns on GitHub's native squash auto-merge. GitHub merges at once when the
    /// pull request already meets every requirement.
    func enableAutoMerge(_ pullRequest: PullRequestID) throws
    /// Turns auto-merge off, for a pull request the merge guard now stops.
    func disableAutoMerge(_ pullRequest: PullRequestID) throws
    /// Squash-merges the pull request, and only while `head` is its head.
    func merge(_ pullRequest: PullRequestID, head: String) throws
    /// The repository's `allow_auto_merge` setting.
    func allowsAutoMerge(in repository: String) throws -> Bool
    /// The rules every ruleset applies to `main`.
    func mainRules(in repository: String) throws -> BranchRules

    /// Every branch the pull request was based on before a retarget, oldest first.
    /// The one GraphQL read here: GitHub keeps former bases only in GraphQL's
    /// timeline. The merge guard checks the budget before it asks.
    func formerBases(_ pullRequest: PullRequestID) throws -> [String]
    /// The pull requests, in every state, whose head is `branch` in `repository`.
    func pullRequests(in repository: String, from branch: String) throws -> [BranchPullRequest]
    /// How many commits `base` has that `head` doesn't.
    func behindBy(in repository: String, base: String, head: String) throws -> Int
}

/// One review on a pull request.
struct PullRequestReview: Equatable {
    let author: String?
    /// `APPROVED`, `CHANGES_REQUESTED`, `COMMENTED` or `DISMISSED`.
    let state: String
    /// The commit the review was made on.
    let commit: String?
    let body: String
}

/// Whether one of `agents` approved `head`: what makes an Agent Review card
/// merging rather than waiting for review.
func agentApproved(_ reviews: [PullRequestReview], head: String, agents: Set<String>) -> Bool {
    reviews.contains { review in
        review.state == "APPROVED" && review.commit == head
            && review.author.map(agents.contains) == true
    }
}

/// The reviews in a `--paginate --slurp`ed reviews answer, oldest first.
func pullRequestReviews(reviewsJSON json: String) throws -> [PullRequestReview] {
    try jsonArray(json).map { review in
        PullRequestReview(
            author: (review["user"] as? [String: Any])?["login"] as? String,
            state: review["state"] as? String ?? "",
            commit: review["commit_id"] as? String,
            body: review["body"] as? String ?? "")
    }
}

/// What every ruleset requires of a pull request into `main`, combined.
struct BranchRules: Equatable {
    var requiredApprovals = 0
    var requiresCodeOwnerReview = false
    var requiresLastPushApproval = false
    var requiredChecks = 0

    /// What falls short of what makes an agent's approval safe: one approval, a
    /// code owner's review, approval of the last push, and a required check.
    var shortfalls: [String] {
        var missing: [String] = []
        if requiredApprovals < 1 { missing.append("no approval is required") }
        if !requiresCodeOwnerReview { missing.append("a code owner's review is not required") }
        if !requiresLastPushApproval { missing.append("the last push need not be approved") }
        if requiredChecks < 1 { missing.append("no status check is required") }
        return missing
    }
}

/// The rules on a `rules/branches/main` answer, strictest of each kind.
func branchRules(rulesJSON json: String) throws -> BranchRules {
    var rules = BranchRules()
    for rule in try jsonArray(json) {
        let parameters = rule["parameters"] as? [String: Any] ?? [:]
        switch rule["type"] as? String {
        case "pull_request":
            rules.requiredApprovals = max(
                rules.requiredApprovals, parameters["required_approving_review_count"] as? Int ?? 0)
            rules.requiresCodeOwnerReview =
                rules.requiresCodeOwnerReview
                || parameters["require_code_owner_review"] as? Bool == true
            rules.requiresLastPushApproval =
                rules.requiresLastPushApproval
                || parameters["require_last_push_approval"] as? Bool == true
        case "required_status_checks":
            rules.requiredChecks += (parameters["required_status_checks"] as? [Any])?.count ?? 0
        default:
            break
        }
    }
    return rules
}

/// The three answers a claim can have.
enum ClaimResult: Equatable {
    case claimed
    /// Somebody else holds it, whether they were there first or arrived alongside.
    case held(by: [String])
    /// GitHub dropped the assignee, which is what an account without write access
    /// looks like.
    case didNotTake
}

struct ClaimedIssue: Equatable {
    let number: Int
    let holders: [String]
}

struct IssueDraft: Equatable {
    let title: String
    let body: String
    let labels: [String]
}

struct IssueSummary: Equatable {
    let number: Int
    let body: String
}

/// One event on an issue's or a pull request's timeline, of a kind a proof or a
/// claim reads.
///
/// A card's move is not one: the REST timeline's status change names no column.
/// See `StatusChange`.
struct TimelineEvent: Equatable {
    enum Kind: String {
        case assigned
        case unassigned
        case closed
        case reviewRequested = "review_requested"
        case labeled
    }

    let kind: Kind
    /// `nil` where GitHub shows none, such as a deleted account.
    let actor: String?
    /// The assignee, the reviewer requested, or the label applied.
    let subject: String?
    let createdAt: Date
}

/// The events of these kinds on a `--slurp`ed timeline, oldest first. Every other
/// kind is dropped before its fields are read, since they do not share a shape:
/// a `reviewed` row has no `created_at`.
func timelineEvents(timelineJSON json: String) throws -> [TimelineEvent] {
    try jsonArray(json).compactMap { row in
        guard let kind = (row["event"] as? String).flatMap(TimelineEvent.Kind.init(rawValue:))
        else { return nil }
        guard let created = row["created_at"] as? String else {
            throw BoardError("a \(kind.rawValue) event carries no time")
        }
        let person = (row["assignee"] ?? row["requested_reviewer"]) as? [String: Any]
        let label = (row["label"] as? [String: Any])?["name"] as? String
        return TimelineEvent(
            kind: kind,
            actor: (row["actor"] as? [String: Any])?["login"] as? String,
            subject: person?["login"] as? String ?? label,
            createdAt: try date(created))
    }
}

/// A card moving between columns, as GraphQL's `ProjectV2ItemStatusChangedEvent`
/// records it: by whom, and from and to which column. This is a move's proof.
struct StatusChange: Equatable {
    /// `nil` where GitHub shows none, such as a deleted account.
    let actor: String?
    /// `nil` when the card had no column, as when it was added to the board.
    let from: String?
    /// `nil` when the card was left with no column.
    let to: String?
    let createdAt: Date
}

/// The status changes on a `--paginate --slurp`ed `statusChangeQuery` answer that
/// belong to the project `owner`/`number`, oldest first. An issue can be on more
/// than one project, and only this board's columns mean anything here.
func statusChanges(timelineJSON json: String, projectOwner owner: String, projectNumber number: Int)
    throws -> [StatusChange]
{
    guard let pages = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
    else { throw BoardError("GitHub answered with something that is not a list of pages") }
    return try pages.flatMap { page -> [StatusChange] in
        let data = page["data"] as? [String: Any]
        let repository = data?["repository"] as? [String: Any]
        guard
            let issue = repository?["issue"] as? [String: Any],
            let items = issue["timelineItems"] as? [String: Any],
            let nodes = items["nodes"] as? [[String: Any]]
        else { throw BoardError("GitHub's status changes answer carries no timeline: \(page)") }
        return try nodes.compactMap { node in
            let project = node["project"] as? [String: Any]
            let projectOwner = (project?["owner"] as? [String: Any])?["login"] as? String
            guard project?["number"] as? Int == number, projectOwner == owner else { return nil }
            guard let created = node["createdAt"] as? String else {
                throw BoardError("a status change carries no time")
            }
            func column(_ key: String) -> String? {
                (node[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
            }
            return StatusChange(
                actor: (node["actor"] as? [String: Any])?["login"] as? String,
                from: column("previousStatus"), to: column("status"),
                createdAt: try date(created))
        }
    }
}

/// An issue's status changes, a page at a time, for `gh api graphql --paginate`.
let statusChangeQuery = """
    query($owner: String!, $name: String!, $number: Int!, $endCursor: String) {
      repository(owner: $owner, name: $name) {
        issue(number: $number) {
          timelineItems(first: 100, after: $endCursor,
                        itemTypes: [PROJECT_V2_ITEM_STATUS_CHANGED_EVENT]) {
            pageInfo { hasNextPage endCursor }
            nodes {
              ... on ProjectV2ItemStatusChangedEvent {
                createdAt
                actor { login }
                previousStatus
                status
                project { number owner { ... on User { login } ... on Organization { login } } }
              }
            }
          }
        }
      }
    }
    """

/// A card's column, by the board's Status field.
let itemStatusQuery = """
    query($id: ID!) {
      node(id: $id) {
        ... on ProjectV2Item {
          fieldValueByName(name: "Status") {
            ... on ProjectV2ItemFieldSingleSelectValue { name }
          }
        }
      }
    }
    """
