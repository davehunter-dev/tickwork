import Foundation

// `repairs`: every repair `docs/repairs.md` describes, computed in
// one verb and printed as one labelled line per card.
//
// **Why a verb.** The repairs were prose a tick assembled by hand from REST
// calls, and hand assembly is where they went wrong: a list of cards typed out
// missed a new pull request, a search of recent pull requests missed old ones,
// and output filtered short lost the labels that said which card a line was
// about. `feedback` and `claim` became verbs for the same reason.
//
// It is three layers, so the rules can be tested without GitHub:
// - **parse:** turn GitHub's JSON into facts;
// - **decide:** a pure function from one card's facts to what should happen;
// - **act:** fetch, print, and with `--apply` make the moves and post notices.
//
// The rules themselves are unchanged. `docs/repairs.md` keeps the prose as the
// reason for each one.

// MARK: - Facts

/// A pull request, which may live in another repository than the board's issues:
/// a project may keep its pull requests in a repository of their own.
struct PullRequestID: Hashable {
    /// `owner/name`, in whatever case the source wrote it. GitHub matches it
    /// without case, so equality does too: a `PR:` line typed by hand names the
    /// same pull request as GitHub's canonical `full_name`.
    let repository: String
    let number: Int

    static func == (left: PullRequestID, right: PullRequestID) -> Bool {
        left.number == right.number && left.repository.lowercased() == right.repository.lowercased()
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(repository.lowercased())
        hasher.combine(number)
    }

    /// How a line names it: `#N` in the board's repository, `owner/name#N`
    /// anywhere else.
    var reference: String {
        repository.lowercased() == Coordinates.repository.lowercased()
            ? "#\(number)" : "\(repository)#\(number)"
    }
}

extension PullRequestID {
    /// Reads `owner/name#N`, or `#N` in `home`.
    init?(reference text: String, home: String) {
        let parts = text.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let number = Int(parts[1]) else { return nil }
        self.init(repository: parts[0].isEmpty ? home : String(parts[0]), number: number)
    }
}

/// One pull request that names an issue as its work.
struct LinkedPullRequest: Equatable {
    let id: PullRequestID
    let open: Bool
    let merged: Bool
}

/// What GitHub says about an open pull request: its merge, and who opened it.
struct MergeFacts: Equatable {
    let headSHA: String
    /// The pull request's head branch.
    let branch: String
    /// `nil` while GitHub is still working it out.
    let mergeable: Bool?
    let mergeableState: String
    let draft: Bool
    /// The pull request's one owner until it closes. See "One pull request, one
    /// owner" in `docs/loop.md`.
    let opener: String
    /// Whether GitHub's auto-merge is set, or the pull request has merged.
    var autoMergeSetOrMerged = false
    /// The branch it merges into, which the merge guard reads.
    var base = "main"
    /// Whether its conversation is locked.
    var locked = false
}

/// The latest run of each check, and the commit statuses, on one commit.
struct CheckFacts: Equatable {
    /// Names of checks and status contexts that failed or timed out.
    var failing: [String] = []
    /// `cancelled`, `stale` and `action_required` runs: `name conclusion`.
    var needsAPerson: [String] = []
    /// A check still running or queued, or a status still pending.
    var unfinished = false
    /// Whether any check ran or status was set at all.
    var ran = false

    /// Green as a settled parent needs it: something ran, and nothing failed,
    /// waits for a person or is unfinished.
    var green: Bool { ran && failing.isEmpty && needsAPerson.isEmpty && !unfinished }
}

/// The loop's last word on an issue in Needs Human, and what came after it.
struct BailOutFacts: Equatable {
    /// The issues and pull requests its `Blocked-on:` lines name.
    let blockedOn: [Int]
    /// The first line of the owner's newest comment after it, if any.
    let ownerAnswer: String?
}

/// Whether something a `Blocked-on:` line names has landed.
enum BlockerState: Equatable {
    case open
    case landed
    /// A pull request closed without merging: what was waited for is not coming.
    case abandoned
}

/// Everything the rules read about one card.
struct CardFacts {
    let number: Int
    let column: String
    let assignees: [String]
    let isDesign: Bool
    var pullRequests: [LinkedPullRequest] = []
    /// For each open pull request.
    var merge: [PullRequestID: MergeFacts] = [:]
    var checks: [PullRequestID: CheckFacts] = [:]
    var unansweredFeedback: [PullRequestID: [String]] = [:]
    /// Set only for a card in Needs Human whose loop's newest comment is a bail-out.
    var bailOut: BailOutFacts?
    var blockers: [Int: BlockerState] = [:]
    /// Selection's facts: whether it is labelled `epic`, and the open issues GitHub
    /// records as blocking it.
    var isEpic = false
    var openBlockers: [Int] = []
    /// Set only when `lockConversations` is on and the issue isn't locked.
    var isUnlocked = false
    /// The url of each open pull request's Reviewer findings that nothing has
    /// answered: its newest `finish` marker, when that says `changes-requested`.
    var reviewerFindings: [PullRequestID: String] = [:]
    /// Open pull requests in Agent Review whose head carries an agent's approval.
    /// Selection reads it when `review.agentApproval` is on: they are merging, not
    /// waiting for review. The repairs read it where auto-merge isn't landing one.
    var agentApproved: Set<PullRequestID> = []
    /// The merge guard's verdict on each open pull request a merge path would act
    /// on: one GitHub reports `clean` in an unclaimed Human Review card, or one
    /// with auto-merge set.
    /// The guard's reads are paid only where a merge could follow.
    var mergeGuard: [PullRequestID: MergeGuardVerdict] = [:]
    /// What its parent asks of each open pull request that isn't into `main`, read
    /// on an unclaimed card in a review column or In Progress.
    var stack: [PullRequestID: StackFinding] = [:]
    /// Selection's second pass, on a `Ready` card: whether it carries `stack.label`,
    /// and, read only when it has one open blocker, what that blocker offers to
    /// stack on.
    var isStackable = false
    var stackParent: StackParent?
}

// MARK: - Decisions

/// What a repair asks for. Rendered as one line, and acted on with `--apply`.
enum RepairAction: Equatable {
    /// Move the card, and post `comment` on the issue afterwards if there is one.
    case move(from: String, to: String, reason: String, comment: String?)
    /// Something a person must look at; nothing is changed.
    case report(String)
    /// A clean pull request. Printed, never done: the policy guard blocks a merge
    /// from the loop.
    case merge(pullRequest: PullRequestID)
    /// Auto-merge set on a pull request the merge guard now stops. GitHub keeps
    /// it through a former parent reopening, since neither base nor head moves.
    case disableAutoMerge(pullRequest: PullRequestID, reason: String)
    /// Move the card to the owner's column, then assign the owner on the pull
    /// request and ask for their review, as `finish approved` does when the agent
    /// path can't land it.
    case handToOwner(pullRequest: PullRequestID, from: String, to: String, reason: String)
    /// A claim in Needs Human, removed without a notice.
    case releaseClaim(login: String)
    /// Somebody holds the card, so no repair fires on it this tick.
    case held(by: [String])
    case ok
}

/// The repairs one card needs, in `docs/repairs.md`'s order. A repair that moves the
/// card stops the ones after it, because they were judged against a snapshot the
/// move has just made stale.
///
/// `redOnMain` names the checks and statuses failing on `main`, by repository. A
/// pull request failing only those of its own repository has nothing of its own
/// to fix.
func repairs(
    for card: CardFacts, redOnMain: [String: Set<String>], loopLogins: Set<String>,
    workflow: Workflow = .standard
) -> [RepairAction] {
    let columns = workflow.columns
    if card.column == columns.parked {
        return needsHumanRepairs(for: card, loopLogins: loopLogins, workflow: workflow)
    }
    guard workflow.reviewColumns.contains(card.column) || card.column == columns.design else {
        return [.ok]
    }

    let open = card.pullRequests.filter(\.open)
    // First, and whoever holds the card, because GitHub would merge it on an
    // approval whatever else this pass decides.
    let disarmed: [PullRequestID: String] = Dictionary(
        uniqueKeysWithValues: open.compactMap { pullRequest in
            let id = pullRequest.id
            guard card.merge[id]?.autoMergeSetOrMerged == true, let verdict = card.mergeGuard[id],
                verdict != .passes
            else { return nil }
            return (id, verdict.reason)
        })
    var actions: [RepairAction] = open.compactMap { pullRequest in
        disarmed[pullRequest.id].map {
            .disableAutoMerge(pullRequest: pullRequest.id, reason: $0)
        }
    }

    // The claim guard. In Human Review an assignee is the owner taking the card
    // by hand, which has to stop a merge as much as a move. In In Design it is a
    // designer at work.
    if !card.assignees.isEmpty {
        return actions + [.held(by: card.assignees)]
    }

    let back = workflow.workColumn(isDesign: card.isDesign)
    // Armed auto-merge would land the pull request on an approval while it is
    // reworked, so it is turned off before the card moves.
    func sendBack(_ id: PullRequestID, reason: String) -> [RepairAction] {
        let armed = card.merge[id]?.autoMergeSetOrMerged == true && disarmed[id] == nil
        let unarm: [RepairAction] =
            armed ? [.disableAutoMerge(pullRequest: id, reason: reason)] : []
        return actions + unarm + [.move(from: card.column, to: back, reason: reason, comment: nil)]
    }

    // An approval with a comment sends a design to In Design, and the owner can
    // merge it there. Nothing else here is In Design's.
    if card.column == columns.design || card.column == columns.ownerReview, card.isDesign,
        open.isEmpty, let merged = card.pullRequests.first(where: \.merged)
    {
        return [
            .move(
                from: card.column, to: columns.work,
                reason: "design PR \(merged.id.reference) merged", comment: nil)
        ]
    }
    guard workflow.reviewColumns.contains(card.column) else { return [.ok] }

    if open.isEmpty {
        if let merged = card.pullRequests.first(where: \.merged) {
            return [.report("PR \(merged.id.reference) merged and the issue is still open")]
        }
        return [.report("no pull request names it with Closes, Refs or Part of")]
    }

    for pullRequest in open {
        let id = pullRequest.id
        let name = "PR \(id.reference)"
        let verdict = card.mergeGuard[id]
        let checks = card.checks[id] ?? CheckFacts()
        let red = redOnMain[id.repository] ?? []

        let ownFailures = checks.failing.filter { !red.contains($0) }
        if !ownFailures.isEmpty {
            return sendBack(id, reason: "\(name) fails \(ownFailures.joined(separator: ", "))")
        }
        let mainFailures = checks.failing.filter { red.contains($0) }
        if !mainFailures.isEmpty {
            actions.append(
                .report(
                    "\(name) fails \(mainFailures.joined(separator: ", ")), red on main too"))
        }

        if let unanswered = card.unansweredFeedback[id], !unanswered.isEmpty {
            return sendBack(
                id,
                reason: "unanswered owner feedback on \(name): "
                    + unanswered.joined(separator: " "))
        }

        if let merge = card.merge[id], merge.base != "main" {
            // Its conflict and behind compare it with its parent's branch, which
            // moves whenever the parent is reworked; the parent decides instead.
            if let finding = card.stack[id] {
                return sendBack(id, reason: "\(name) \(finding.reason)")
            }
        } else if let merge = card.merge[id] {
            if merge.mergeable == false {
                return sendBack(id, reason: "\(name) does not merge")
            }
            if merge.mergeableState == "behind" {
                return sendBack(id, reason: "\(name) is behind main")
            }
        }

        checks.needsAPerson.forEach { actions.append(.report("\(name) has \($0)")) }

        if let merge = card.merge[id] {
            if merge.draft {
                actions.append(.report("\(name) is a draft"))
            } else {
                let mergeable =
                    card.column == columns.ownerReview && merge.mergeableState == "clean"
                // Auto-merge is the only way an agent-approved card in Agent Review
                // lands, and `next` skips it as merging, so with auto-merge off,
                // whenever and however it was turned off, it goes to the owner,
                // whose column's `MERGE` repair lands it once the guard passes.
                let stranded =
                    card.column == columns.review && card.agentApproved.contains(id)
                    && (!merge.autoMergeSetOrMerged || disarmed[id] != nil)
                switch verdict {
                case .restack(let reason):
                    return sendBack(id, reason: "\(name) must restack onto main: \(reason)")
                case _ where stranded:
                    let why = verdict.map { $0 == .passes ? "" : ": \($0.reason)" } ?? ""
                    return actions + [
                        .handToOwner(
                            pullRequest: id, from: card.column, to: columns.ownerReview,
                            reason: "auto-merge on \(name) is off\(why)")
                    ]
                case .passes:
                    if mergeable { actions.append(.merge(pullRequest: id)) }
                case .held(let reason):
                    actions.append(.report("\(name) is held: \(reason)"))
                case nil:
                    if mergeable {
                        actions.append(.report("\(name) is held: the merge guard wasn't read"))
                    }
                }
            }
        }
    }
    return actions.isEmpty ? [.ok] : actions
}

private func needsHumanRepairs(
    for card: CardFacts, loopLogins: Set<String>, workflow: Workflow
) -> [RepairAction] {
    var actions: [RepairAction] = card.assignees
        .filter { loopLogins.contains($0) }
        .map { RepairAction.releaseClaim(login: $0) }

    guard let bailOut = card.bailOut else { return actions.isEmpty ? [.ok] : actions }
    let back = workflow.workColumn(isDesign: card.isDesign)
    let parked = workflow.columns.parked

    // The owner answering wins over a blocker landing: it is the more specific
    // signal, and it may say something about the work the landing does not.
    if let answer = bailOut.ownerAnswer {
        actions.append(
            .move(
                from: parked, to: back, reason: "the owner answered the bail-out",
                comment: "Answer received: \(answer)"))
        return actions
    }

    guard !bailOut.blockedOn.isEmpty else { return actions.isEmpty ? [.ok] : actions }
    let states = bailOut.blockedOn.map { ($0, card.blockers[$0] ?? .open) }
    let abandoned = states.filter { $0.1 == .abandoned }.map(\.0)
    if !abandoned.isEmpty {
        actions.append(
            .report(
                "blocked on "
                    + abandoned.map { "PR #\($0)" }.joined(separator: ", ")
                    + ", closed without merging"))
        return actions
    }
    if states.allSatisfy({ $0.1 == .landed }) {
        let landed = bailOut.blockedOn.map { "#\($0)" }.joined(separator: ", ")
        actions.append(
            .move(
                from: parked, to: back, reason: "\(landed) landed",
                comment: "Blocker cleared: \(landed) landed."))
    }
    return actions.isEmpty ? [.ok] : actions
}

/// One printed line, naming the card. Every line starts with a word a tick can
/// match and the card's number, so nothing is ever read without its label.
func repairLine(_ action: RepairAction, card: Int) -> String {
    switch action {
    case .move(let from, let to, let reason, _), .handToOwner(_, let from, let to, let reason):
        return "MOVE #\(card) \(from) → \(to) (\(reason))"
    case .report(let text):
        return "REPORT #\(card) \(text)"
    case .merge(let pullRequest):
        return "MERGE #\(card) PR \(pullRequest.reference) is clean"
    case .disableAutoMerge(let pullRequest, let reason):
        return "UNARM #\(card) auto-merge on PR \(pullRequest.reference) (\(reason))"
    case .releaseClaim(let login):
        return "RELEASE #\(card) claim by \(login) in Needs Human"
    case .held(let logins):
        return "HELD #\(card) by \(logins.joined(separator: ", "))"
    case .ok:
        return "ok #\(card)"
    }
}

/// The lines for one card, and with `apply` each action handed to `perform`,
/// whose answer, if any, is printed after the action's own line. Without
/// `apply`, `perform` is never called, which is the whole of the dry run's
/// promise: nothing on GitHub changes.
func repairLines(
    for card: CardFacts, redOnMain: [String: Set<String>], loopLogins: Set<String>, apply: Bool,
    workflow: Workflow = .standard, perform: (RepairAction) throws -> String?
) rethrows -> [String] {
    var lines: [String] = []
    for action in repairs(
        for: card, redOnMain: redOnMain, loopLogins: loopLogins, workflow: workflow)
    {
        lines.append(repairLine(action, card: card.number))
        if apply, let outcome = try perform(action) {
            lines.append(outcome)
        }
    }
    return lines
}

// MARK: - Claims over an hour old

/// How long a claim may stand before it is reported. Longer than any tick has
/// taken, and short enough that a night of running does not hide one.
let staleClaimAge: TimeInterval = 3_600

/// What opens a stale-claim notice, so the next tick can tell it has posted one.
let staleClaimNoticePrefix = "Claim notice:"

/// Whether a claim taken at `assignedAt` wants a notice now: it is over the age,
/// and no notice has been posted since it was taken.
func needsStaleClaimNotice(assignedAt: Date, newestNotice: Date?, now: Date) -> Bool {
    guard now.timeIntervalSince(assignedAt) > staleClaimAge else { return false }
    guard let newestNotice else { return true }
    return newestNotice < assignedAt
}

// MARK: - Parsing GitHub's answers

/// When the issue was last claimed. The events span every timeline page, since a
/// claim taken on every tick soon runs an issue past one.
func latestAssignment(in events: [TimelineEvent]) -> Date? {
    events.filter { $0.kind == .assigned }.map(\.createdAt).max()
}

func latestAssignment(timelineJSON json: String) throws -> Date? {
    latestAssignment(in: try timelineEvents(timelineJSON: json))
}

/// The pull requests an issue's timeline shows naming it as their work, from a
/// `timeline` page's cross-references. Matched by body, so a pull request of any
/// age is found, unlike a search of recent ones, and in any repository.
///
/// Only one `agents` opened counts: the agent that opened a pull request owns it,
/// so anyone else's, such as a stranger's fork, is left for the owner by hand.
func linkedPullRequests(
    issue: Int, timelineJSON json: String, home: String = Coordinates.repository,
    agents: Set<String> = loopLogins()
) throws -> [LinkedPullRequest] {
    let events = try jsonArray(json)
    var seen: Set<PullRequestID> = []
    return events.compactMap { event in
        guard event["event"] as? String == "cross-referenced",
            let source = (event["source"] as? [String: Any])?["issue"] as? [String: Any],
            let pull = source["pull_request"] as? [String: Any],
            let number = source["number"] as? Int,
            let repository = (source["repository"] as? [String: Any])?["full_name"] as? String,
            let opener = (source["user"] as? [String: Any])?["login"] as? String,
            agents.contains(opener),
            linksIssue(
                issue, body: source["body"] as? String ?? "", from: repository, home: home)
        else { return nil }
        let id = PullRequestID(repository: repository, number: number)
        guard seen.insert(id).inserted else { return nil }
        return LinkedPullRequest(
            id: id, open: source["state"] as? String == "open", merged: pull["merged_at"] is String)
    }
}

/// The line `finish --new` comments on an issue, and the owner may write by hand,
/// to record a pull request as the issue's work. The lookups read it because
/// GitHub writes no cross-reference onto a locked issue.
let recordedPullRequestPrefix = "PR: "

/// Whose `PR:` lines count: the agents', and the owner's.
func recordingLogins() -> Set<String> {
    loopLogins().union([Coordinates.ownerLogin])
}

/// The pull requests an issue's timeline records with a `PR: <ref>` line in a
/// comment by one of `authors`, oldest first. A comment carries no state, so
/// each is still to be read and judged by `pullRequestLink`.
func recordedPullRequests(
    timelineJSON json: String, home: String = Coordinates.repository,
    authors: Set<String> = recordingLogins()
) throws -> [PullRequestID] {
    var found: [PullRequestID] = []
    for event in try jsonArray(json) where event["event"] as? String == "commented" {
        guard let author = (event["user"] as? [String: Any])?["login"] as? String,
            authors.contains(author), let body = event["body"] as? String
        else { continue }
        for line in body.split(separator: "\n") {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(recordedPullRequestPrefix),
                let id = PullRequestID(
                    reference: String(line.dropFirst(recordedPullRequestPrefix.count)), home: home),
                !found.contains(id)
            else { continue }
            found.append(id)
        }
    }
    return found
}

/// The fields of a pull request that decide whether it links an issue.
private struct PullRequestLinkFields: Decodable {
    struct User: Decodable {
        let login: String
    }
    struct Base: Decodable {
        struct Repository: Decodable {
            let full_name: String
        }
        let repo: Repository
    }
    let number: Int
    let state: String
    let merged_at: String?
    let updated_at: String
    let body: String?
    let user: User
    let base: Base
}

/// A pull request read directly, linking `issue` on a cross-reference's terms:
/// one of `agents` opened it and its body names the issue. Nil when it doesn't.
func pullRequestLink(
    issue: Int, pullJSON json: String, home: String = Coordinates.repository,
    agents: Set<String> = loopLogins()
) throws -> (link: LinkedPullRequest, updatedAt: Date)? {
    let pull: PullRequestLinkFields
    do {
        pull = try JSONDecoder().decode(PullRequestLinkFields.self, from: Data(json.utf8))
    } catch {
        throw BoardError("a pull request came back as something this could not read: \(error)")
    }
    let repository = pull.base.repo.full_name
    guard agents.contains(pull.user.login),
        linksIssue(issue, body: pull.body ?? "", from: repository, home: home)
    else { return nil }
    let link = LinkedPullRequest(
        id: PullRequestID(repository: repository, number: pull.number),
        open: pull.state == "open", merged: pull.merged_at != nil)
    return (link, try date(pull.updated_at))
}

/// The fields of a pull request that the merge rules read, decoded by type.
private struct PullRequestMergeFields: Decodable {
    struct Head: Decodable {
        let sha: String
        let ref: String
    }
    struct Base: Decodable {
        let ref: String
    }
    struct User: Decodable {
        let login: String
    }
    /// Its fields aren't read: being there is the answer.
    struct AutoMerge: Decodable {}
    let head: Head
    let base: Base
    let user: User
    let mergeable: Bool?
    let mergeable_state: String?
    let draft: Bool?
    let auto_merge: AutoMerge?
    let merged: Bool?
    let locked: Bool?
}

func mergeFacts(pullJSON json: String) throws -> MergeFacts {
    let pull: PullRequestMergeFields
    do {
        pull = try JSONDecoder().decode(PullRequestMergeFields.self, from: Data(json.utf8))
    } catch {
        throw BoardError("a pull request came back as something this could not read: \(error)")
    }
    return MergeFacts(
        headSHA: pull.head.sha,
        branch: pull.head.ref,
        mergeable: pull.mergeable,
        mergeableState: pull.mergeable_state ?? "unknown",
        draft: pull.draft ?? false,
        opener: pull.user.login,
        autoMergeSetOrMerged: pull.auto_merge != nil || pull.merged == true,
        base: pull.base.ref, locked: pull.locked ?? false)
}

/// The check runs and commit statuses on one commit, judging only the newest run
/// of each check name.
///
/// **`filter=latest` is newest per check suite, not per name.** A workflow run
/// cancelled by a newer one on the same commit leaves its own suite behind, so
/// its failure comes back beside the replacement's pass. Run ids increase, so
/// the highest id of a name is its newest run.
///
/// **A status's `pending` means something only above zero statuses.** GitHub
/// answers `pending` for a commit with none at all, so the count decides.
func checkFacts(checkRunsJSON: String, statusJSON: String) throws -> CheckFacts {
    var facts = CheckFacts()
    let runs = try jsonObject(checkRunsJSON)["check_runs"] as? [[String: Any]] ?? []
    func checkName(_ run: [String: Any]) -> String { run["name"] as? String ?? "?" }
    func runID(_ run: [String: Any]) -> Int { run["id"] as? Int ?? 0 }
    facts.ran = !runs.isEmpty
    let newestID = Dictionary(runs.map { (checkName($0), runID($0)) }, uniquingKeysWith: max)
    for run in runs where newestID[checkName(run)] == runID(run) {
        let name = checkName(run)
        guard run["status"] as? String == "completed" else {
            facts.unfinished = true
            continue
        }
        switch run["conclusion"] as? String ?? "" {
        case "failure", "timed_out": facts.failing.append(name)
        case let conclusion where ["cancelled", "stale", "action_required"].contains(conclusion):
            facts.needsAPerson.append("\(name) \(conclusion)")
        default: break
        }
    }

    let status = try jsonObject(statusJSON)
    if status["total_count"] as? Int ?? 0 > 0 {
        facts.ran = true
        for entry in status["statuses"] as? [[String: Any]] ?? [] {
            let context = entry["context"] as? String ?? "?"
            switch entry["state"] as? String ?? "" {
            case "failure", "error": facts.failing.append(context)
            case "pending": facts.unfinished = true
            default: break
            }
        }
    }
    return facts
}

/// What a bail-out in Needs Human is waiting for, from the issue's comments
/// oldest first: the loop's newest comment must open `Bailing out:`, and the
/// owner's comments after it are the answer.
func bailOutFacts(comments: [ConversationComment], loopLogins: Set<String>, owner: String)
    -> BailOutFacts?
{
    guard let newestLoop = comments.lastIndex(where: { loopLogins.contains($0.author) }),
        comments[newestLoop].body.hasPrefix("Bailing out:")
    else { return nil }

    let blockedOn = comments[newestLoop].body.split(separator: "\n").compactMap { line -> Int? in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("Blocked-on: #") else { return nil }
        return Int(trimmed.dropFirst("Blocked-on: #".count).prefix(while: \.isNumber))
    }
    let answer = comments[(newestLoop + 1)...].last { $0.author == owner }
    let firstLine = answer.flatMap {
        $0.body.split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) }
    }
    return BailOutFacts(blockedOn: blockedOn, ownerAnswer: firstLine)
}

func jsonObject(_ json: String) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    else {
        throw BoardError("GitHub answered with something that is not an object")
    }
    return object
}

/// The rows of a `gh api --paginate --slurp` answer, which is one array holding
/// each page's array. A single page's array is read as it is. Pages are
/// flattened as JSON rather than by joining text, so nothing inside a pull
/// request body can be rewritten on the way.
func jsonArray(_ json: String) throws -> [[String: Any]] {
    guard let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Any] else {
        throw BoardError("GitHub answered with something that is not a list")
    }
    if let pages = parsed as? [[Any]] {
        return pages.flatMap { $0.compactMap { $0 as? [String: Any] } }
    }
    return parsed.compactMap { $0 as? [String: Any] }
}

// MARK: - Fetching and acting

/// The logins `loop.json` lists. The file is required, since the tool reads the
/// project's coordinates from it too.
func loopLogins() -> Set<String> {
    Set(Coordinates.configuration.agents.map(\.login))
}

/// Every repair, one line per card, and with `apply` the moves, notices
/// and claim removals. Never a merge.
///
/// One board read, and everything else over REST, so the GraphQL budget is spent
/// only on the board, which the moves need too.
func repairs(
    snapshot: Board, board: BoardProvider, source: SourceControl, apply: Bool,
    emit: (String) -> Void = { print($0) }
) throws {
    let logins = loopLogins()
    let owner = Coordinates.ownerLogin
    let home = Coordinates.repository
    let workflow = Coordinates.workflow
    var redOnMain = [home: Set(try source.checks(in: home, at: "main").failing)]

    // Only the board's own repository files an issue for a red `main`: another
    // repository's `main` has no card here to own it.
    for check in (redOnMain[home] ?? []).sorted() {
        try fileMainFailure(check, board: board, apply: apply, emit: emit)
    }

    let ownerReview = snapshot.items.filter { $0.status == workflow.columns.ownerReview }
    let cards = snapshot.items.filter {
        workflow.reviewColumns.contains($0.status)
            || [workflow.columns.design, workflow.columns.parked].contains($0.status)
    }
    for item in cards {
        let card = try facts(
            for: item, board: board, source: source, loopLogins: logins, owner: owner,
            ownerReview: ownerReview, workflow: workflow)
        for pullRequest in card.pullRequests where pullRequest.open {
            let repository = pullRequest.id.repository
            if redOnMain[repository] == nil {
                redOnMain[repository] = Set(try source.checks(in: repository, at: "main").failing)
            }
        }
        let lines = try repairLines(
            for: card, redOnMain: redOnMain, loopLogins: logins, apply: apply, workflow: workflow
        ) { action in
            try perform(action, card: item.number, board: board, source: source, emit: emit)
        }
        lines.forEach(emit)
    }

    try reportStaleClaims(
        snapshot: snapshot, board: board, parked: workflow.columns.parked, apply: apply,
        emit: emit)
}

func facts(
    for item: Item, board: BoardProvider, source: SourceControl, loopLogins: Set<String>,
    owner: String, ownerReview: [Item], workflow: Workflow = .standard
) throws -> CardFacts {
    var card = CardFacts(
        number: item.number, column: item.status, assignees: item.assignees,
        isDesign: try board.labels(of: item.number).contains(workflow.labels.design))

    if item.status == workflow.columns.parked {
        let comments = try board.comments(on: item.number)
        card.bailOut = bailOutFacts(comments: comments, loopLogins: loopLogins, owner: owner)
        for blocker in card.bailOut?.blockedOn ?? [] {
            card.blockers[blocker] = try board.landing(of: blocker)
        }
        return card
    }

    card.pullRequests = try board.linkedPullRequests(of: item.number)
    // In Design needs only which pull requests merged, so it reads no further.
    for pullRequest in card.pullRequests
    where pullRequest.open && item.status != workflow.columns.design {
        let id = pullRequest.id
        let merge = try source.mergeFacts(id)
        card.merge[id] = merge
        card.checks[id] = try source.checks(in: id.repository, at: merge.headSHA)
        card.unansweredFeedback[id] = try source.unansweredFeedback(id)
        let clean =
            item.status == workflow.columns.ownerReview && merge.mergeableState == "clean"
            && !merge.draft
        // Auto-merge is read whoever holds the card, since a claim doesn't stop
        // GitHub merging it.
        if (item.assignees.isEmpty && clean) || merge.autoMergeSetOrMerged {
            card.mergeGuard[id] = try mergeGuard(id, merge: merge, board: board, source: source)
        }
        // A claim stops every repair, so a claimed card's parent isn't read.
        if item.assignees.isEmpty, merge.base != "main" {
            card.stack[id] = try stackFinding(
                id, merge: merge, ownerReview: ownerReview, source: source)
        }
        // Auto-merge that is set and passes is still landing it; otherwise an
        // agent's approval in Agent Review is a card nothing else lands.
        let landing = merge.autoMergeSetOrMerged && card.mergeGuard[id] == .passes
        if item.status == workflow.columns.review, !landing,
            agentApproved(try source.reviews(id), head: merge.headSHA, agents: loopLogins)
        {
            card.agentApproved.insert(id)
        }
    }
    return card
}

/// One issue per check red on `main`, titled exactly as `docs/repairs.md` says so
/// the title is the guard against filing it twice.
private func fileMainFailure(
    _ check: String, board: BoardProvider, apply: Bool, emit: (String) -> Void
) throws {
    let title = "\(check) is failing on main"
    guard !(try board.hasOpenIssue(titled: title)) else {
        emit("REPORT main \(title), already filed")
        return
    }
    emit("FILE main \(title)")
    guard apply else { return }
    _ = try board.createIssue(
        IssueDraft(
            title: title,
            body: "`\(check)` is red on `main`, so it is red on every open pull request too. "
                + "Filed by the loop's repairs. The branch that caused it has merged, so this card owns it.",
            labels: ["type:bug"] + Coordinates.configuration.mainRedLabels))
}

/// Makes one action happen, and says what became of it when that is not
/// simply done.
private func perform(
    _ action: RepairAction, card: Int, board: BoardProvider, source: SourceControl,
    emit: (String) -> Void
) throws -> String? {
    switch action {
    case .move(let from, let to, _, let comment):
        do {
            try board.move(card, to: to, from: from)
            emit("#\(card) -> \(to)")
        } catch let error as BoardError {
            // Reported and not retried: the card is where something else put it.
            return "REFUSED #\(card) \(error.message)"
        }
        if let comment {
            try board.comment(on: card, body: comment)
        }
        return nil
    case .releaseClaim(let login):
        try board.release(card, login: login)
        return nil
    case .disableAutoMerge(let pullRequest, _):
        try source.disableAutoMerge(pullRequest)
        return nil
    case .handToOwner(let pullRequest, let from, let to, _):
        // Moved first, so a card something else has just moved doesn't ask the
        // owner for a review it no longer needs.
        do {
            try board.move(card, to: to, from: from)
            emit("#\(card) -> \(to)")
        } catch let error as BoardError {
            return "REFUSED #\(card) \(error.message)"
        }
        try source.assign(pullRequest, to: Coordinates.ownerLogin)
        try source.requestReview(pullRequest, from: Coordinates.ownerLogin)
        return nil
    case .report, .merge, .held, .ok:
        return nil
    }
}

/// Claims over an hour old, on every open issue anywhere, with a notice posted
/// once per claim.
private func reportStaleClaims(
    snapshot: Board, board: BoardProvider, parked: String, apply: Bool,
    emit: (String) -> Void
) throws {
    let now = Date()
    for claimed in try board.claimedIssues() {
        let number = claimed.number
        let holders = claimed.holders.joined(separator: ", ")
        // Needs Human's claims are removed above rather than reported.
        if snapshot.item(number: number)?.status == parked { continue }
        guard
            let assignedAt = latestAssignment(in: try board.events(on: number, since: .distantPast))
        else { continue }
        let assigned = ISO8601DateFormatter().string(from: assignedAt)
        let notices = try board.comments(on: number).filter {
            $0.body.hasPrefix(staleClaimNoticePrefix)
        }
        guard
            needsStaleClaimNotice(
                assignedAt: assignedAt, newestNotice: notices.last?.createdAt, now: now)
        else { continue }

        emit("NOTICE #\(number) claimed by \(holders) since \(assigned)")
        guard apply else { continue }
        try board.comment(
            on: number,
            body: "\(staleClaimNoticePrefix) held by \(holders) since \(assigned), over an hour. "
                + "The loop cannot tell an abandoned claim from a slow one, so a person decides.")
    }
}
