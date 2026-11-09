// In-memory stand-ins for the two provider seams. Reads answer from what a test
// arranges; writes are recorded for the test to assert.
//

import Foundation

@testable import BoardCore

final class FakeBoard: BoardProvider {
    var board = Board(items: [], statusFieldID: "status", optionIDs: [:], columns: [])
    var login = "agent-one"
    var labels: [Int: [String]] = [:]
    var comments: [Int: [ConversationComment]] = [:]
    var events: [Int: [TimelineEvent]] = [:]
    var statusChanges: [Int: [StatusChange]] = [:]
    var linked: [Int: [LinkedPullRequest]] = [:]
    var blockers: [Int: [Int]] = [:]
    var landings: [Int: BlockerState] = [:]
    var claimed: [ClaimedIssue] = []
    var issues: [IssueSummary] = []
    var budgetRemaining = 5_000
    /// Answers a claim on these issues as given, instead of taking it.
    var claimAnswers: [Int: ClaimResult] = [:]
    /// Runs after a claim takes, so a test can move the board under it.
    var afterClaim: ((Int) -> Void)?
    /// Reads and writes that throw, by name: `labels`, `events`,
    /// `linkedPullRequests`, `comment`, `move`, `release`, `close`.
    var failing: Set<String> = []
    /// When this fake's writes happen, which is after any claim a test arranges.
    var now = ISO8601DateFormatter().date(from: "2026-10-28T14:00:00Z")!
    private(set) var closed: [Int] = []
    /// Told of every write, so a test can see the order across both fakes.
    var onWrite: ((String) -> Void)?

    struct Move: Equatable {
        let issue: Int
        let to: String
        let from: String?
    }

    private(set) var moves: [Move] = []
    private(set) var posted: [(issue: Int, body: String)] = []
    private(set) var created: [IssueDraft] = []
    private(set) var released: [(issue: Int, login: String)] = []
    private(set) var assignees: [Int: [String]] = [:]

    func snapshot(refresh: Bool) throws -> Board { board }

    func budget() throws -> GraphQLBudget {
        GraphQLBudget(
            remaining: budgetRemaining, limit: 5_000, reset: Date(timeIntervalSince1970: 0))
    }

    func move(_ issue: Int, to column: String, from expected: String?) throws {
        if let expected, let card = board.item(number: issue), card.status != expected {
            throw BoardError("#\(issue) is in \(card.status), not \(expected)")
        }
        try fail("move")
        moves.append(Move(issue: issue, to: column, from: expected))
        onWrite?("move #\(issue) \(expected ?? "?") → \(column)")
        let from = board.item(number: issue)?.status
        update(issue) {
            Item(
                id: $0.id, number: $0.number, title: $0.title, status: column,
                assignees: $0.assignees)
        }
        statusChanges[issue, default: []].append(
            StatusChange(actor: login, from: from, to: column, createdAt: now))
    }

    /// Replaces one card on the board, as GitHub would show it after a write.
    func update(_ issue: Int, _ change: (Item) -> Item) {
        board = Board(
            items: board.items.map { $0.number == issue ? change($0) : $0 },
            statusFieldID: board.statusFieldID, optionIDs: board.optionIDs, columns: board.columns)
    }

    func viewer() throws -> String { login }

    func claim(_ issue: Int, as login: String) throws -> ClaimResult {
        if let answer = claimAnswers[issue] { return answer }
        let held = assignees[issue] ?? []
        guard held.isEmpty else { return .held(by: held) }
        assignees[issue] = [login]
        afterClaim?(issue)
        return .claimed
    }

    func release(_ issue: Int, login: String) throws {
        try fail("release")
        released.append((issue, login))
        onWrite?("release #\(issue)")
        assignees[issue]?.removeAll { $0 == login }
        update(issue) {
            Item(
                id: $0.id, number: $0.number, title: $0.title, status: $0.status,
                assignees: $0.assignees.filter { $0 != login })
        }
        events[issue, default: []].append(
            TimelineEvent(kind: .unassigned, actor: self.login, subject: login, createdAt: now))
    }

    func claimedIssues() throws -> [ClaimedIssue] { claimed }
    func labels(of issue: Int) throws -> [String] {
        try fail("labels")
        return labels[issue] ?? []
    }

    var locked: Set<Int> = []
    /// Every issue whose lock was read, in order.
    private(set) var lockReads: [Int] = []

    func isLocked(_ issue: Int) throws -> Bool {
        lockReads.append(issue)
        return locked.contains(issue)
    }

    private func fail(_ read: String) throws {
        if failing.contains(read) { throw BoardError("\(read) failed: HTTP 502") }
    }

    func comment(on issue: Int, body: String) throws {
        try fail("comment")
        posted.append((issue, body))
        onWrite?("comment #\(issue)")
        let url =
            "https://github.com/example-org/example/issues/\(issue)#issuecomment-\(posted.count)"
        comments[issue, default: []].append(
            ConversationComment(author: login, url: url, createdAt: now, body: body))
    }

    func closeIssue(_ issue: Int) throws {
        try fail("close")
        closed.append(issue)
        onWrite?("close #\(issue)")
        events[issue, default: []].append(
            TimelineEvent(kind: .closed, actor: login, subject: nil, createdAt: now))
    }

    func comments(on issue: Int) throws -> [ConversationComment] { comments[issue] ?? [] }

    func events(on issue: Int, since: Date) throws -> [TimelineEvent] {
        try fail("events")
        return (events[issue] ?? []).filter { $0.createdAt >= since }
    }

    func statusChanges(on issue: Int, since: Date) throws -> [StatusChange] {
        (statusChanges[issue] ?? []).filter { $0.createdAt >= since }
    }

    func linkedPullRequests(of issue: Int) throws -> [LinkedPullRequest] {
        try fail("linkedPullRequests")
        return linked[issue] ?? []
    }

    func createIssue(_ draft: IssueDraft) throws -> Int {
        created.append(draft)
        onWrite?("create \(draft.title)")
        issues.append(IssueSummary(number: 1_000 + created.count, body: draft.body))
        return 1_000 + created.count
    }

    /// Each issue's column on the board, nil for one with no column yet. An issue
    /// absent here has no card until `addToBoard` adds one.
    var cards: [Int: String?] = [:]
    private(set) var placed: [(issue: Int, column: String)] = []

    func addToBoard(_ issue: Int) throws -> String? {
        if cards[issue] == nil { cards[issue] = .some(nil) }
        return cards[issue] ?? nil
    }

    func place(_ issue: Int, in column: String) throws {
        cards[issue] = column
        placed.append((issue, column))
        onWrite?("place #\(issue) \(column)")
    }

    func hasOpenIssue(titled title: String) throws -> Bool {
        created.contains { $0.title == title }
    }

    func issues(createdBy login: String, since: Date) throws -> [IssueSummary] { issues }
    func openIssues(limit: Int) throws -> [IssueSummary] { issues }
    func issueNumbers(limit: Int) throws -> Set<Int> { Set(issues.map(\.number)) }

    func existence(of number: Int) -> IssueExistence {
        issues.contains { $0.number == number } ? .exists : .missing
    }

    func blockers(of issue: Int) throws -> [Int] { blockers[issue] ?? [] }
    func landing(of number: Int) throws -> BlockerState { landings[number] ?? .open }

    func addBlocker(_ blocker: Int, to issue: Int) throws -> Bool {
        guard !(blockers[issue] ?? []).contains(blocker) else { return false }
        blockers[issue, default: []].append(blocker)
        return true
    }

    func removeBlocker(_ blocker: Int, from issue: Int) throws -> Bool {
        guard (blockers[issue] ?? []).contains(blocker) else { return false }
        blockers[issue]?.removeAll { $0 == blocker }
        return true
    }
}

final class FakeSourceControl: SourceControl {
    var merge: [PullRequestID: MergeFacts] = [:]
    /// Keyed by `repository@ref`.
    var checks: [String: CheckFacts] = [:]
    /// Unanswered urls, returned as they are.
    var feedback: [PullRequestID: [String]] = [:]
    /// Owner feedback the conversation below answers by naming it, as on GitHub.
    var ownerFeedback: [PullRequestID: [OwnerFeedback]] = [:]
    var events: [PullRequestID: [TimelineEvent]] = [:]
    var conversation: [PullRequestID: [ConversationComment]] = [:]
    var login = "agent-one"
    /// Writes that throw, by name: `comment`, `assign`, `request`, `lock`.
    var failing: Set<String> = []
    var now = ISO8601DateFormatter().date(from: "2026-10-28T14:00:00Z")!

    /// Every repository a call named, in order.
    private(set) var repositories: [String] = []
    /// Every write, as `verb pull-request [subject]`.
    private(set) var writes: [String] = []
    var onWrite: ((String) -> Void)?

    private func write(_ verb: String, _ pullRequest: PullRequestID) throws {
        if failing.contains(verb) { throw BoardError("\(verb) failed: HTTP 502") }
        repositories.append(pullRequest.repository)
    }

    func comment(on pullRequest: PullRequestID, body: String) throws {
        try write("comment", pullRequest)
        writes.append("comment \(pullRequest.reference)")
        onWrite?("comment \(pullRequest.repository)#\(pullRequest.number)")
        let count = (conversation[pullRequest] ?? []).count + 1
        conversation[pullRequest, default: []].append(
            ConversationComment(
                author: login,
                url:
                    "https://github.com/\(pullRequest.repository)/pull/\(pullRequest.number)#issuecomment-\(count)",
                createdAt: now, body: body))
    }

    func assign(_ pullRequest: PullRequestID, to login: String) throws {
        try write("assign", pullRequest)
        writes.append("assign \(pullRequest.reference) \(login)")
        onWrite?("assign \(pullRequest.repository)#\(pullRequest.number) \(login)")
        events[pullRequest, default: []].append(
            TimelineEvent(kind: .assigned, actor: self.login, subject: login, createdAt: now))
    }

    func requestReview(_ pullRequest: PullRequestID, from login: String) throws {
        try write("request", pullRequest)
        writes.append("request \(pullRequest.reference) \(login)")
        onWrite?("request \(pullRequest.repository)#\(pullRequest.number) \(login)")
        events[pullRequest, default: []].append(
            TimelineEvent(kind: .reviewRequested, actor: self.login, subject: login, createdAt: now)
        )
    }

    func lock(_ pullRequest: PullRequestID) throws {
        try write("lock", pullRequest)
        writes.append("lock \(pullRequest.reference)")
        onWrite?("lock \(pullRequest.repository)#\(pullRequest.number)")
        merge[pullRequest]?.locked = true
    }

    func mergeFacts(_ pullRequest: PullRequestID) throws -> MergeFacts {
        repositories.append(pullRequest.repository)
        guard let facts = merge[pullRequest] else {
            throw BoardError("no merge facts arranged for \(pullRequest.reference)")
        }
        return facts
    }

    func checks(in repository: String, at ref: String) throws -> CheckFacts {
        repositories.append(repository)
        return checks["\(repository)@\(ref)"] ?? CheckFacts()
    }

    func unansweredFeedback(_ pullRequest: PullRequestID) throws -> [String] {
        repositories.append(pullRequest.repository)
        let named = BoardCore.unansweredFeedback(
            ownerFeedback[pullRequest] ?? [], conversation: conversation[pullRequest] ?? [])
        return (feedback[pullRequest] ?? []) + named
    }

    func events(on pullRequest: PullRequestID, since: Date) throws -> [TimelineEvent] {
        repositories.append(pullRequest.repository)
        return (events[pullRequest] ?? []).filter { $0.createdAt >= since }
    }

    func conversation(_ pullRequest: PullRequestID) throws -> [ConversationComment] {
        repositories.append(pullRequest.repository)
        return conversation[pullRequest] ?? []
    }

    var reviews: [PullRequestID: [PullRequestReview]] = [:]
    /// The next approval lands without GitHub showing it yet, as when its reviews lag.
    var hideNextApproval = false
    /// GitHub's `reviewDecision` once the agent has approved, `APPROVED` unless set.
    var decisionAfterApproval: [PullRequestID: String] = [:]
    var decision: [PullRequestID: String] = [:]
    /// Per repository; allowed unless set.
    var autoMergeAllowed: [String: Bool] = [:]
    /// Per repository; safe unless set.
    var rules: [String: BranchRules] = [:]
    /// Repositories whose rules can't be read.
    var unreadableRules: Set<String> = []

    func reviews(_ pullRequest: PullRequestID) throws -> [PullRequestReview] {
        repositories.append(pullRequest.repository)
        return reviews[pullRequest] ?? []
    }

    func approve(_ pullRequest: PullRequestID, commit: String, body: String) throws {
        try write("approve", pullRequest)
        writes.append("approve \(pullRequest.reference)")
        onWrite?("approve \(pullRequest.repository)#\(pullRequest.number)")
        if hideNextApproval {
            hideNextApproval = false
        } else {
            reviews[pullRequest, default: []].append(
                PullRequestReview(author: login, state: "APPROVED", commit: commit, body: body))
        }
        decision[pullRequest] = decisionAfterApproval[pullRequest] ?? "APPROVED"
    }

    func reviewDecision(_ pullRequest: PullRequestID) throws -> String {
        repositories.append(pullRequest.repository)
        return decision[pullRequest] ?? "REVIEW_REQUIRED"
    }

    func enableAutoMerge(_ pullRequest: PullRequestID) throws {
        try write("merge", pullRequest)
        writes.append("auto-merge \(pullRequest.reference)")
        onWrite?("auto-merge \(pullRequest.repository)#\(pullRequest.number)")
        merge[pullRequest]?.autoMergeSetOrMerged = true
    }

    func disableAutoMerge(_ pullRequest: PullRequestID) throws {
        try write("merge", pullRequest)
        writes.append("disable auto-merge \(pullRequest.reference)")
        merge[pullRequest]?.autoMergeSetOrMerged = false
    }

    func merge(_ pullRequest: PullRequestID, head: String) throws {
        try write("merge", pullRequest)
        writes.append("merge \(pullRequest.reference) at \(head)")
    }

    func allowsAutoMerge(in repository: String) throws -> Bool {
        repositories.append(repository)
        return autoMergeAllowed[repository] ?? true
    }

    /// The merge guard's facts. Former bases per pull request; the pull requests
    /// from each branch, keyed `repository@branch`; and how far behind each head
    /// is, keyed `repository@base...head` and 0 unless set.
    var formerBases: [PullRequestID: [String]] = [:]
    var branchPulls: [String: [BranchPullRequest]] = [:]
    var behind: [String: Int] = [:]
    /// Every guard read, as `bases #N`, `pulls branch` or `compare base...head`.
    private(set) var guardReads: [String] = []

    func formerBases(_ pullRequest: PullRequestID) throws -> [String] {
        repositories.append(pullRequest.repository)
        guardReads.append("bases \(pullRequest.reference)")
        return formerBases[pullRequest] ?? []
    }

    func pullRequests(in repository: String, from branch: String) throws -> [BranchPullRequest] {
        repositories.append(repository)
        guardReads.append("pulls \(branch)")
        return branchPulls["\(repository)@\(branch)"] ?? []
    }

    func behindBy(in repository: String, base: String, head: String) throws -> Int {
        repositories.append(repository)
        guardReads.append("compare \(base)...\(head)")
        return behind["\(repository)@\(base)...\(head)"] ?? 0
    }

    func mainRules(in repository: String) throws -> BranchRules {
        repositories.append(repository)
        if unreadableRules.contains(repository) { throw BoardError("HTTP 404: Not Found") }
        return rules[repository]
            ?? BranchRules(
                requiredApprovals: 1, requiresCodeOwnerReview: true, requiresLastPushApproval: true,
                requiredChecks: 1)
    }
}
