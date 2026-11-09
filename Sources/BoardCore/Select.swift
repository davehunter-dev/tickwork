import Foundation

// `select`: which item a tick takes and in which role, as a pure function over
// the board's cards and their facts.
//
// It follows the repairs' layers: `next` gathers the facts and this decides.
// "How `next` chooses a tick's item" in `docs/loop.md` keeps each rule's reason.

enum Role: String, CaseIterable {
    case orchestrator, reviewer, engineer, designer
}

/// What kind of pass the chosen item is, from facts the tick already reads.
enum TickTask: String {
    /// A fresh item.
    case start
    /// An open pull request with something against it: a red check of its own, a
    /// conflict, a branch behind `main`, the owner's unanswered feedback, or the
    /// Reviewer's.
    case addressFindings = "address-findings"
    /// An open pull request with nothing against it, for the Engineer to judge.
    case assessExisting = "assess-existing"
    /// A design whose pull request has merged, owing its tasks.
    case decompose
    case review
    case design
}

/// Why an item a role could take was passed over.
enum SkipReason: String {
    case epic
    case claimed
    case blocked
    case checksRunning = "checks-running"
    /// In `Agent Review`: this agent opened the pull request, so another reviews it.
    case openedByThisAgent = "opened-by-this-agent"
    /// In `In Design` or `In Progress`: another agent opened the pull request, so
    /// its corrections are that agent's.
    case openedByAnotherAgent = "opened-by-another-agent"
    /// Claimed, then found somewhere else when the board was read again.
    case moved
    /// An agent's approval is on its head, so GitHub is merging it.
    case merging
    /// Labelled to stack, but the second pass can't: the detail names the condition.
    case notStackable = "not-stackable"
    /// `lockConversations` is on and the owner hasn't locked the issue.
    case unlocked
}

struct Skip: Equatable {
    let issue: Int
    let reason: SkipReason
    let detail: String?
}

/// A pull request whose checks are unfinished, at the head they run on. A
/// `checks-running` skip's detail lists them, which the supervisor watches until
/// they finish.
struct RunningChecks: Hashable {
    let pullRequest: PullRequestID
    let head: String

    static let separator = ", "

    /// `owner/name#N@sha`.
    var text: String { "\(pullRequest.repository)#\(pullRequest.number)@\(head)" }

    /// Every entry of a `checks-running` detail, or none if any can't be read.
    static func list(_ detail: String) -> [RunningChecks]? {
        let entries = detail.components(separatedBy: separator).map { entry -> RunningChecks? in
            guard let hash = entry.lastIndex(of: "#"), let at = entry.lastIndex(of: "@"),
                hash < at, let number = Int(entry[entry.index(after: hash)..<at])
            else { return nil }
            let head = String(entry[entry.index(after: at)...])
            return head.isEmpty
                ? nil
                : RunningChecks(
                    pullRequest: PullRequestID(
                        repository: String(entry[..<hash]), number: number), head: head)
        }
        return entries.contains(nil) ? nil : entries.compactMap { $0 }
    }
}

/// Who is selecting: its login and the roles this tick holds.
struct SelectingAgent {
    let login: String
    let roles: Set<Role>
}

struct Pick: Equatable {
    let issue: Int
    let role: Role
    let task: TickTask
    /// Set on a stacked start: what it branches from and targets.
    var stack: StackBase? = nil
}

struct Selection: Equatable {
    /// Nil when nothing can be taken: the tick is idle.
    let pick: Pick?
    let skipped: [Skip]
}

/// The item and role this tick takes, from `cards` in board order, which is
/// priority within each column.
///
/// `redOnMain` names the checks failing on each repository's `main`, which are
/// not a pull request's own findings.
func select(
    from cards: [CardFacts], agent: SelectingAgent, redOnMain: [String: Set<String>] = [:],
    workflow: Workflow = .standard
) -> Selection {
    var skipped: [Skip] = []
    for (column, columnRole) in workflow.selectionOrder {
        for card in cards where card.column == column {
            let role = columnRole ?? readyRole(for: card)
            guard agent.roles.contains(role) else { continue }
            if let skip = skip(card, workflow: workflow) {
                skipped.append(skip)
                continue
            }
            if let pick = pick(
                card, role: role, agent: agent, redOnMain: redOnMain, workflow: workflow,
                skipped: &skipped)
            {
                return Selection(pick: pick, skipped: skipped)
            }
        }
    }
    return Selection(pick: nil, skipped: skipped)
}

private func readyRole(for card: CardFacts) -> Role {
    card.isDesign ? .designer : .engineer
}

/// The skips every column shares, and `Ready`'s blockers, which hold only new work.
private func skip(_ card: CardFacts, workflow: Workflow) -> Skip? {
    if card.isEpic {
        return Skip(issue: card.number, reason: .epic, detail: nil)
    }
    if !card.assignees.isEmpty {
        return Skip(
            issue: card.number, reason: .claimed,
            detail: card.assignees.joined(separator: ", "))
    }
    if card.isUnlocked {
        return Skip(issue: card.number, reason: .unlocked, detail: nil)
    }
    if card.column == workflow.columns.ready, !card.openBlockers.isEmpty {
        return Skip(
            issue: card.number, reason: .blocked,
            detail: card.openBlockers.map { "#\($0)" }.joined(separator: ", ") + " open")
    }
    return nil
}

private func pick(
    _ card: CardFacts, role: Role, agent: SelectingAgent, redOnMain: [String: Set<String>],
    workflow: Workflow, skipped: inout [Skip]
) -> Pick? {
    let open = card.pullRequests.filter(\.open).map(\.id)
    let openers = Set(open.compactMap { card.merge[$0]?.opener })
    if card.column == workflow.columns.review {
        if !open.isEmpty, open.allSatisfy(card.agentApproved.contains) {
            skipped.append(Skip(issue: card.number, reason: .merging, detail: nil))
            return nil
        }
        let running = open.filter { card.checks[$0]?.unfinished ?? false }.compactMap { id in
            card.merge[id].map { RunningChecks(pullRequest: id, head: $0.headSHA) }
        }
        if !running.isEmpty {
            skipped.append(
                Skip(
                    issue: card.number, reason: .checksRunning,
                    detail: running.map(\.text).joined(separator: RunningChecks.separator)))
            return nil
        }
        if openers.contains(agent.login) {
            skipped.append(Skip(issue: card.number, reason: .openedByThisAgent, detail: nil))
            return nil
        }
        return Pick(issue: card.number, role: .reviewer, task: .review)
    }
    let owners = openers.subtracting([agent.login])
    if !owners.isEmpty {
        skipped.append(
            Skip(
                issue: card.number, reason: .openedByAnotherAgent,
                detail: owners.sorted().joined(separator: ", ")))
        return nil
    }
    if card.column == workflow.columns.work {
        return Pick(issue: card.number, role: role, task: workTask(card, redOnMain: redOnMain))
    }
    return Pick(issue: card.number, role: role, task: role == .designer ? .design : .start)
}

/// The Engineer's pass on an item in `In Progress`.
private func workTask(_ card: CardFacts, redOnMain: [String: Set<String>]) -> TickTask {
    let open = card.pullRequests.filter(\.open).map(\.id)
    if open.isEmpty {
        return card.isDesign && card.pullRequests.contains(where: \.merged) ? .decompose : .start
    }
    let hasFindings = open.contains { id in
        let red = redOnMain[id.repository] ?? []
        // A stacked pull request's conflict and behind are its parent's to judge.
        let intoMain = card.merge[id].map { $0.base == "main" ? $0 : nil } ?? nil
        return (card.checks[id]?.failing ?? []).contains { !red.contains($0) }
            || !(card.unansweredFeedback[id] ?? []).isEmpty
            || card.reviewerFindings[id] != nil
            || card.mergeGuard[id]?.needsRestack == true
            || card.stack[id] != nil
            || intoMain?.mergeable == false
            || intoMain?.mergeableState == "behind"
    }
    return hasFindings ? .addressFindings : .assessExisting
}

// MARK: - Stacked work

// See "Choosing stacked work" in docs/stacked-pull-requests.md.

/// What a stacked start branches from and targets: its parent issue, that
/// issue's pull request, and the pull request's branch and head when chosen.
struct StackBase: Equatable {
    let parent: Int
    let pullRequest: PullRequestID
    let branch: String
    let head: String
}

/// What a labelled `Ready` card's one open blocker offers to stack on.
enum StackParent: Equatable {
    case base(StackBase)
    /// Not stackable: names the condition that failed.
    case refused(String)
}

/// Selection's second pass: the first labelled, unclaimed `Ready` card, in board
/// order, with exactly one open blocker that it can stack on. Every other
/// labelled card is skipped as `not-stackable`, naming why.
///
/// Only the Engineer starts stacked work, since only a start branches.
func selectStacked(
    from cards: [CardFacts], agent: SelectingAgent, workflow: Workflow = .standard
) -> Selection {
    guard agent.roles.contains(.engineer) else { return Selection(pick: nil, skipped: []) }
    var skipped: [Skip] = []
    for card in cards
    where card.column == workflow.columns.ready && card.isStackable && !card.isDesign
        && !card.isEpic && card.assignees.isEmpty && !card.isUnlocked && !card.openBlockers.isEmpty
    {
        let reason: String
        switch card.stackParent {
        case .base(let base) where card.openBlockers == [base.parent]:
            return Selection(
                pick: Pick(issue: card.number, role: .engineer, task: .start, stack: base),
                skipped: skipped)
        case .refused(let why) where card.openBlockers.count == 1:
            reason = why
        default:
            reason =
                card.openBlockers.map { "#\($0)" }.joined(separator: ", ")
                + " are open, and a stack has one parent"
        }
        skipped.append(Skip(issue: card.number, reason: .notStackable, detail: reason))
    }
    return Selection(pick: nil, skipped: skipped)
}

/// Whether `parent`, a card's one open blocker, can be stacked on: its one open
/// pull request is settled, and following bases from it reaches `main`.
///
/// Reads the parent's pull requests, then its merge facts and checks, then one
/// `pulls?head=` per level of its stack. Never a write.
func stackParent(
    _ parent: Int, snapshot: Board, workflow: Workflow, board: BoardProvider, source: SourceControl
) throws -> StackParent {
    guard let card = snapshot.item(number: parent) else {
        return .refused("#\(parent) is not on the board")
    }
    guard card.status == workflow.columns.ownerReview else {
        return .refused("#\(parent) is in \(card.status)")
    }
    guard card.assignees.isEmpty else {
        return .refused("#\(parent) is claimed by \(card.assignees.joined(separator: ", "))")
    }
    let open = try board.linkedPullRequests(of: parent).filter(\.open).map(\.id)
    guard open.count == 1, let id = open.first else {
        return .refused(
            open.isEmpty
                ? "#\(parent) has no open pull request"
                : "#\(parent) has \(open.count) open pull requests")
    }
    let merge = try source.mergeFacts(id)
    let name = "#\(parent)'s PR \(id.reference)"
    guard !merge.draft else { return .refused("\(name) is a draft") }
    guard try source.checks(in: id.repository, at: merge.headSHA).green else {
        return .refused("\(name) is not green")
    }

    var seen: Set<String> = [merge.branch]
    var base = merge.base
    while base != "main" {
        guard seen.insert(base).inserted else {
            return .refused("#\(parent)'s stack loops at \(base)")
        }
        let fromBase = try source.pullRequests(in: id.repository, from: base)
        let openFromBase = fromBase.filter(\.open)
        guard openFromBase.count == 1, let below = openFromBase.first else {
            let seenThere =
                fromBase.isEmpty
                ? "no pull request is from it"
                : openFromBase.isEmpty
                    ? "its pull request is closed"
                    : "\(openFromBase.count) open pull requests are from it"
            return .refused("#\(parent)'s stack breaks at \(base): \(seenThere)")
        }
        base = below.base
    }
    return .base(
        StackBase(parent: parent, pullRequest: id, branch: merge.branch, head: merge.headSHA))
}
