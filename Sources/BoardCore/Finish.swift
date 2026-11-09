import Foundation

// `finish` and the helper verbs: the end of a tick and its mid-tick writes, each
// against the token `next` printed. See "During the tick" and "End of tick" in
// docs/orchestration-in-swift.md.
//
// **Every write is proven before it is skipped.** A write counts as done only
// when GitHub shows it, attributed to this login since the claim, so running
// the same `finish` again after a failure does only what is left, and a write
// another actor made is never taken as this one's.

/// What a tick says it did, instead of naming a column.
enum Outcome: String, CaseIterable {
    case submitted, decomposed, approved
    case changesRequested = "changes-requested"
    case blocked
    case needsHuman = "needs-human"
    case unable
}

/// What the agent passes `finish`.
struct FinishRequest {
    let token: ClaimToken
    let outcome: Outcome
    /// `--pr`, which links the issue.
    var pullRequest: PullRequestID? = nil
    /// `--new`: this pass opened the pull request, so the issue gets its `PR:` line.
    var isNew = false
    /// `--body-file`'s contents.
    var body: String? = nil
    /// `--answering`: the feedback urls the comment answers.
    var answering: [String] = []
    /// `--on`: what a `blocked` outcome waits for.
    var blockers: [Int] = []
    /// `--head`: the commit an `approved` review judged. The agent-approved path
    /// approves this commit, and only while it is still the head.
    var head: String? = nil
}

/// Where `finish` and the helper verbs act, from `loop.json`.
struct FinishContext {
    /// `loop.json`'s `repository`, where every issue write goes.
    let issueRepository: String
    /// Whose review an `approved` outcome requests.
    let owner: String
    /// The names the outcomes' columns and the design label go by.
    var workflow = Workflow.standard
    /// `review.agentApproval`, which may let an independent review approve.
    var agentApproval: AgentApproval? = nil
    /// `merge.auto`: an approved pull request in the issue repository, whose
    /// `allow_auto_merge` `next` checked, is set to auto-merge.
    var autoMerge = false
    /// `stack.label`: a task `decompose` files from an issue carrying it carries it
    /// too.
    var stackLabel: String? = nil
    /// `lockConversations`: `--pr` locks the pull request before any other write.
    var lockConversations = false
}

// MARK: - Answers

struct FinishedAnswer: Encodable, Equatable {
    var schema = answerSchema
    var kind = "finished"
    let issue: Int
    let outcome: String
    let done: [String]
    var nextDelay = "now"
}

struct RefusedAnswer: Encodable, Equatable {
    var schema = answerSchema
    var kind = "refused"
    let issue: Int
    /// `claim` or `move`.
    let stage: String
    /// The column the card was found in, for a refused move.
    let found: String?
    let done: [String]
    let message: String
}

struct RejectedAnswer: Encodable, Equatable {
    var schema = answerSchema
    var kind = "rejected"
    let issue: Int
    let message: String
}

struct IncompleteAnswer: Encodable, Equatable {
    var schema = answerSchema
    var kind = "incomplete"
    let issue: Int
    let outcome: String
    let done: [String]
    let pending: [String]
    let message: String
    var retry = true
}

enum FinishAnswer: Equatable {
    case finished(FinishedAnswer)
    case refused(RefusedAnswer)
    case rejected(RejectedAnswer)
    case incomplete(IncompleteAnswer)

    var json: String {
        switch self {
        case .finished(let answer): encodeAnswer(answer)
        case .refused(let answer): encodeAnswer(answer)
        case .rejected(let answer): encodeAnswer(answer)
        case .incomplete(let answer): encodeAnswer(answer)
        }
    }
}

func encodeAnswer<Answer: Encodable>(_ answer: Answer) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(answer)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
}

// MARK: - Markers

/// The hidden last line of a comment `finish` posts.
func finishMarker(_ outcome: Outcome, _ token: ClaimToken) -> String {
    "\(finishMarkerPrefix)\(outcome.rawValue) \(token.text) -->"
}

/// The hidden last line of an issue `file-issue` or `decompose` files.
func issueMarker(_ token: ClaimToken, key: String) -> String {
    "<!-- tickwork:issue \(token.text) \(key) -->"
}

/// The hidden last line of a `reply`, naming what it answers.
func replyMarker(_ token: ClaimToken, answering: [String]) -> String {
    "<!-- tickwork:reply \(token.text) \(answering.joined(separator: " ")) -->"
}

/// Whether `comments` hold one by `login` ending with `marker`.
private func carries(_ comments: [ConversationComment], marker: String, by login: String) -> Bool {
    comments.contains { comment in
        comment.author == login
            && comment.body.split(separator: "\n").last.map {
                $0.trimmingCharacters(in: .whitespaces) == marker
            } == true
    }
}

// MARK: - Writes

/// One write `finish` makes, in the order an outcome makes them.
enum FinishWrite: Equatable {
    case issueComment(String)
    case pullRequestComment(PullRequestID, String)
    case move(to: String)
    case assignOwner(PullRequestID)
    case requestReview(PullRequestID)
    /// A real `APPROVE` of `commit`, carrying the outcome's text, on the agent-approved path.
    case approve(PullRequestID, commit: String, String)
    /// Locks the pull request before any other write, with `lockConversations` on.
    case lock(PullRequestID)
    case autoMerge(PullRequestID)
    case close
    case release

    func label(from column: String) -> String {
        switch self {
        case .issueComment(let body):
            "comment \(body.split(separator: "\n").first.map(String.init) ?? "")"
        case .pullRequestComment(let id, _): "comment on \(id.repository)#\(id.number)"
        case .move(let to): "move \(column) → \(to)"
        case .assignOwner(let id): "assign the owner on \(id.repository)#\(id.number)"
        case .requestReview(let id): "request the owner's review on \(id.repository)#\(id.number)"
        case .approve(let id, _, _): "approve \(id.repository)#\(id.number)"
        case .autoMerge(let id): "set auto-merge on \(id.repository)#\(id.number)"
        case .lock(let id): "lock \(id.repository)#\(id.number)"
        case .close: "close"
        case .release: "release"
        }
    }
}

/// Who GitHub names as the project's own workflows. A card's move by it from
/// `Ready` into the work column, when a pull request links, is part of an
/// engineer's ordinary pass rather than somebody taking the card.
let projectAutomationLogin = "github-project-automation"

/// Who an `approved` outcome hands the pull request to.
enum ApprovalPath: Equatable {
    /// The owner reviews it.
    case owner
    /// The agent-approved path is open, and the agent's approval of `commit` is
    /// still to be submitted. What follows it depends on GitHub's answer to it.
    case agentPending(commit: String)
    /// The agent's approval of `commit` is on the pull request. `accepted` is
    /// whether GitHub's `reviewDecision` is then `APPROVED` and the merge guard
    /// passes. If it isn't, a path still needs a code owner the agents aren't, or
    /// the guard stops the merge, so the owner reviews it after all.
    case agentApproved(commit: String, accepted: Bool)
}

/// The comment text and write order each outcome makes, which are today's prose's.
/// With `lock`, a `--pr` outcome locks the pull request first.
func finishWrites(
    _ request: FinishRequest, isDesign: Bool, workflow: Workflow = .standard,
    approval: ApprovalPath = .owner, autoMerge: Bool = false, lock: Bool = false
) -> [FinishWrite] {
    let writes = outcomeWrites(
        request, isDesign: isDesign, workflow: workflow, approval: approval, autoMerge: autoMerge)
    guard lock, let id = request.pullRequest, !writes.isEmpty else { return writes }
    return [.lock(id)] + writes
}

private func outcomeWrites(
    _ request: FinishRequest, isDesign: Bool, workflow: Workflow, approval: ApprovalPath,
    autoMerge: Bool
) -> [FinishWrite] {
    let columns = workflow.columns
    let marker = finishMarker(request.outcome, request.token)
    let answering = request.answering.map { "Answering \($0)." }
    func text(_ parts: [String]) -> String {
        (parts.filter { !$0.isEmpty } + [marker]).joined(separator: "\n\n")
    }
    let body = request.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    switch request.outcome {
    case .submitted:
        guard let id = request.pullRequest else { return [] }
        var writes: [FinishWrite] = []
        if request.isNew {
            writes.append(.issueComment(text(["PR: \(id.reference)"])))
        }
        if !body.isEmpty {
            writes.append(
                .pullRequestComment(id, text([body, answering.joined(separator: "\n")])))
        }
        return writes + [.move(to: columns.review), .release]
    case .decomposed:
        return [.close, .release]
    case .approved:
        guard let id = request.pullRequest else { return [] }
        let review = text([body, answering.joined(separator: "\n")])
        let merging: [FinishWrite] = autoMerge ? [.autoMerge(id)] : []
        let toOwner: [FinishWrite] =
            [.assignOwner(id), .requestReview(id), .move(to: columns.ownerReview)] + merging
            + [.release]
        switch approval {
        case .owner:
            return [.pullRequestComment(id, review)] + toOwner
        case .agentPending(let commit):
            return [.approve(id, commit: commit, review)]
        case .agentApproved(let commit, accepted: true):
            // The card stays in review: `next` skips it as merging.
            return [.approve(id, commit: commit, review)] + merging + [.release]
        case .agentApproved(let commit, accepted: false):
            return [.approve(id, commit: commit, review)] + toOwner
        }
    case .changesRequested:
        guard let id = request.pullRequest else { return [] }
        return [
            .pullRequestComment(id, text([body, answering.joined(separator: "\n")])),
            .move(to: workflow.workColumn(isDesign: isDesign)), .release,
        ]
    case .blocked:
        let lines = request.blockers.map { "Blocked-on: #\($0)" }.joined(separator: "\n")
        return [
            .issueComment(text(["Bailing out: \(body)", lines])), .move(to: columns.parked),
            .release,
        ]
    case .needsHuman:
        return [
            .issueComment(text(["Bailing out: \(body)"])), .move(to: columns.parked), .release,
        ]
    case .unable:
        return [
            .issueComment(text(["Bailing out: unable to proceed.", body])),
            .move(to: columns.parked), .release,
        ]
    }
}

// MARK: - finish

/// The whole of `finish`.
///
/// `afterApproving` is set on the one run that follows submitting an agent's
/// approval, which reads GitHub's decision on it and does the rest.
func finish(
    _ request: FinishRequest, board: BoardProvider, source: SourceControl, context: FinishContext,
    afterApproving: Bool = false
) -> FinishAnswer {
    let token = request.token
    let issue = token.issue
    func rejected(_ message: String) -> FinishAnswer {
        .rejected(RejectedAnswer(issue: issue, message: message))
    }

    // The checks every run makes: whose token, which repository, which outcome.
    let login: String
    do {
        login = try board.viewer()
    } catch {
        return incomplete(request, done: [], pending: [], error)
    }
    guard token.login == login else {
        return rejected("the token is \(token.login)'s, and this is \(login)")
    }
    guard token.repository == context.issueRepository else {
        return rejected(
            "the token names \(token.repository), and loop.json's repository is \(context.issueRepository)"
        )
    }
    guard outcomes(token.role, token.task).contains(request.outcome.rawValue) else {
        return rejected(
            "\(request.outcome.rawValue) is not an outcome for \(token.role.rawValue) "
                + "on \(token.task.rawValue)")
    }
    if let missing = missingArgument(request) {
        return rejected(missing)
    }

    var state: ProofState
    do {
        state = try ProofState.read(
            request, login: login, context: context, board: board, source: source)
    } catch {
        return incomplete(request, done: [], pending: [], error)
    }
    // GitHub hasn't shown the approval this run just submitted. Submitting again
    // would be a second one, so the agent runs `finish` again instead.
    if afterApproving,
        let approveIndex = state.writes.firstIndex(where: {
            if case .approve = $0 { true } else { false }
        }),
        !state.proven[approveIndex]
    {
        return incomplete(
            request, writes: state.writes, proven: state.proven, from: state.takenFrom,
            BoardError("GitHub doesn't show the approval yet; run finish again"))
    }
    guard state.claimedAt == token.claimedAt else {
        return rejected(
            "the claim this token names is not \(login)'s newest on #\(issue); "
                + "a later claim's token finishes it")
    }

    // A first run checks its inputs. A re-run's own first run already did, when
    // they still held, so they are not checked again.
    if !state.isRerun {
        do {
            if let problem = try inputProblem(request, board: board, source: source) {
                return rejected(problem)
            }
        } catch {
            return incomplete(request, done: [], pending: [], error)
        }
    }

    let writes = state.writes
    let from = state.takenFrom
    let done = { writes.indices.filter { state.proven[$0] }.map { writes[$0].label(from: from) } }

    // The claim gone, with no release of this token's to show for it.
    let releaseIndex = writes.firstIndex(of: .release)
    let releaseProven = releaseIndex.map { state.proven[$0] } ?? false
    if !state.claimHeld && !releaseProven {
        return .refused(
            RefusedAnswer(
                issue: issue, stage: "claim", found: nil, done: done(),
                message: state.holders.isEmpty
                    ? "the claim was removed by someone else; nothing was written"
                    : "#\(issue) is held by \(state.holders.joined(separator: ", ")); nothing was written"
            ))
    }

    // The card somewhere this token didn't move it: post the work, release, stop.
    let moveIndex = writes.firstIndex { if case .move = $0 { true } else { false } }
    if let moveIndex, !state.proven[moveIndex], !state.cardWhereTaken {
        let keep = writes.indices.filter { index in
            !state.proven[index]
                && {
                    switch writes[index] {
                    case .lock, .issueComment, .pullRequestComment: true
                    case .release: state.claimHeld
                    default: false
                    }
                }()
        }
        do {
            for index in keep {
                try perform(
                    writes[index], request, from: from, board: board, source: source,
                    context: context)
                state.proven[index] = true
            }
        } catch {
            return incomplete(request, writes: writes, proven: state.proven, from: from, error)
        }
        return .refused(
            RefusedAnswer(
                issue: issue, stage: "move", found: state.column, done: done(),
                message: "the card moved under the tick; nothing was retried"))
    }

    for index in writes.indices where !state.proven[index] {
        do {
            try perform(
                writes[index], request, from: from, board: board, source: source, context: context)
            state.proven[index] = true
        } catch {
            return incomplete(request, writes: writes, proven: state.proven, from: from, error)
        }
        // What follows an agent's approval depends on GitHub's decision on it,
        // which a fresh read finds. Every write is proven first, so this repeats nothing.
        if case .approve = writes[index] {
            return finish(
                request, board: board, source: source, context: context, afterApproving: true)
        }
    }
    return .finished(
        FinishedAnswer(issue: issue, outcome: request.outcome.rawValue, done: done()))
}

private func missingArgument(_ request: FinishRequest) -> String? {
    let outcome = request.outcome
    let needsPR: Set<Outcome> = [.submitted, .approved, .changesRequested]
    let needsBody: Set<Outcome> = [.approved, .changesRequested, .blocked, .needsHuman, .unable]
    if needsPR.contains(outcome), request.pullRequest == nil {
        return "\(outcome.rawValue) needs --pr"
    }
    if needsBody.contains(outcome),
        (request.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
        return "\(outcome.rawValue) needs --body-file"
    }
    if request.head != nil, outcome != .approved {
        return "--head is the commit an approved review judged, and this is \(outcome.rawValue)"
    }
    if outcome == .blocked, request.blockers.isEmpty {
        return "blocked needs --on and at least one issue or pull request"
    }
    return nil
}

/// What a first run checks before writing anything.
private func inputProblem(_ request: FinishRequest, board: BoardProvider, source: SourceControl)
    throws -> String?
{
    if let id = request.pullRequest {
        // Read directly: the timeline holds no cross-reference to a locked issue,
        // and the `PR:` line that would record one is this finish's to write.
        guard try board.linkedPullRequest(id, of: request.token.issue) != nil else {
            return "\(id.repository)#\(id.number) does not link #\(request.token.issue)"
        }
        // A stacked start opened against `main` while its parent is open is what
        // nothing else would catch.
        if request.outcome == .submitted, let branch = request.token.stackBranch {
            let base = try source.mergeFacts(id).base
            guard base == branch else {
                return "\(id.repository)#\(id.number) is based on \(base), and this stacked "
                    + "start's must be its parent's branch, \(branch)"
            }
        }
        if !request.answering.isEmpty {
            let outstanding = Set(try source.unansweredFeedback(id))
            if let stale = request.answering.first(where: { !outstanding.contains($0) }) {
                return
                    "--answering \(stale) is not outstanding feedback on \(id.repository)#\(id.number)"
            }
        }
    }
    // The design's rule: at least one of them still open, so there is something
    // to wait for.
    if !request.blockers.isEmpty,
        try !request.blockers.contains(where: { try board.landing(of: $0) == .open })
    {
        let named = request.blockers.map { "#\($0)" }.joined(separator: ", ")
        return "none of \(named) is open, so there is nothing to wait for"
    }
    return nil
}

/// Whether `reviews` hold this token's approval: an `APPROVE` of `commit` by
/// `login` whose last line is the marker.
private func approvalSubmitted(
    _ reviews: [PullRequestReview], of commit: String, marker: String, by login: String
) -> Bool {
    reviews.contains { review in
        review.author == login && review.state == "APPROVED" && review.commit == commit
            && review.body.split(separator: "\n").last.map {
                $0.trimmingCharacters(in: .whitespaces) == marker
            } == true
    }
}

/// Whether an `approved` outcome may take the agent-approved path: every one of
/// these holds.
/// - The pull request is in the issue repository, whose ruleset `next` checked.
/// - The issue carries the label, and whoever applied it last is the owner or
///   in `appliedBy`.
/// - The review is independent: the reviewer didn't open the pull request.
/// - The commit the review judged is still the head, and every check on it is green.
private func agentPathOpen(
    _ id: PullRequestID, reviewed head: String, labels: [String], events: [TimelineEvent],
    approval: AgentApproval, login: String, context: FinishContext, source: SourceControl
) throws -> Bool {
    guard id.repository == context.issueRepository, labels.contains(approval.label) else {
        return false
    }
    let merge = try source.mergeFacts(id)
    guard merge.headSHA == head, merge.opener != login else { return false }
    let labelled = events.last { $0.kind == .labeled && $0.subject == approval.label }
    guard approval.counts(labelled?.actor, owner: context.owner) else { return false }
    let checks = try source.checks(in: id.repository, at: head)
    return checks.failing.isEmpty && checks.needsAPerson.isEmpty && !checks.unfinished
}

/// What GitHub shows about this token's writes, the claim and the card.
private struct ProofState {
    var writes: [FinishWrite]
    var proven: [Bool]
    var isRerun: Bool
    /// The newest `assigned` event naming this login.
    var claimedAt: Date?
    var holders: [String]
    var claimHeld: Bool
    var column: String
    /// The column the move starts from: where the claim found the card, or the
    /// work column the project's automation moved it to.
    var takenFrom: String
    var cardWhereTaken: Bool

    static func read(
        _ request: FinishRequest, login: String, context: FinishContext,
        board: BoardProvider, source: SourceControl
    ) throws -> ProofState {
        let token = request.token
        let issue = token.issue
        let owner = context.owner
        let workflow = context.workflow
        let labels = try board.labels(of: issue)
        let isDesign = labels.contains(workflow.labels.design)
        let since = token.claimedAt
        let events = try board.events(on: issue, since: .distantPast)
        let marker = finishMarker(request.outcome, token)

        // Auto-merge and the agent-approved path are the merges an `approved`
        // outcome can start, and both wait on the merge guard. A pull request it
        // stops goes to the owner, and the merge repair holds or sends it back.
        // Neither acts on another repository's pull request, and the agent path
        // needs `--head`, so the guard isn't read for either.
        let sameRepository = request.pullRequest?.repository == context.issueRepository
        let autoMerge = context.autoMerge && sameRepository
        let agentPathPossible =
            context.agentApproval != nil && request.head != nil && sameRepository
        var guardPasses = false
        if request.outcome == .approved, let id = request.pullRequest,
            autoMerge || agentPathPossible
        {
            guardPasses =
                try mergeGuard(id, merge: source.mergeFacts(id), board: board, source: source)
                == .passes
        }

        var approval = ApprovalPath.owner
        var reviews: [PullRequestReview] = []
        if request.outcome == .approved, let id = request.pullRequest, let head = request.head,
            let agentApproval = context.agentApproval
        {
            reviews = try source.reviews(id)
            if approvalSubmitted(reviews, of: head, marker: marker, by: login) {
                approval = .agentApproved(
                    commit: head,
                    accepted: try guardPasses && source.reviewDecision(id) == "APPROVED")
            } else if guardPasses,
                try agentPathOpen(
                    id, reviewed: head, labels: labels, events: events, approval: agentApproval,
                    login: login, context: context, source: source)
            {
                approval = .agentPending(commit: head)
            }
        }
        let writes = finishWrites(
            request, isDesign: isDesign, workflow: workflow, approval: approval,
            autoMerge: autoMerge && guardPasses, lock: context.lockConversations)
        let claimedAt = events.filter { $0.kind == .assigned && $0.subject == login }
            .map(\.createdAt).max()
        let recent = events.filter { $0.createdAt >= since }
        let moves = try board.statusChanges(on: issue, since: since)
        let issueComments = try board.comments(on: issue)
        var pullRequestComments: [PullRequestID: [ConversationComment]] = [:]
        var pullRequestEvents: [PullRequestID: [TimelineEvent]] = [:]
        var merging: [PullRequestID: Bool] = [:]
        var locked: [PullRequestID: Bool] = [:]
        for write in writes {
            switch write {
            case .pullRequestComment(let id, _) where pullRequestComments[id] == nil:
                pullRequestComments[id] = try source.conversation(id)
            case .assignOwner(let id), .requestReview(let id):
                if pullRequestEvents[id] == nil {
                    pullRequestEvents[id] = try source.events(on: id, since: since)
                }
            case .autoMerge(let id):
                merging[id] = try source.mergeFacts(id).autoMergeSetOrMerged
            case .lock(let id):
                locked[id] = try source.mergeFacts(id).locked
            default:
                break
            }
        }

        let snapshot = try board.snapshot(refresh: true)
        let holders = snapshot.item(number: issue)?.assignees ?? []
        let column = snapshot.column(of: issue)

        let proven = writes.map { write -> Bool in
            switch write {
            case .issueComment:
                return carries(issueComments, marker: marker, by: login)
            case .pullRequestComment(let id, _):
                return carries(pullRequestComments[id] ?? [], marker: marker, by: login)
            case .move(let to):
                return moves.contains { $0.actor == login && $0.to == to }
            case .assignOwner(let id):
                return (pullRequestEvents[id] ?? []).contains {
                    $0.kind == .assigned && $0.actor == login && $0.subject == owner
                }
            case .requestReview(let id):
                return (pullRequestEvents[id] ?? []).contains {
                    $0.kind == .reviewRequested && $0.actor == login && $0.subject == owner
                }
            case .approve(_, let commit, _):
                return approvalSubmitted(reviews, of: commit, marker: marker, by: login)
            case .autoMerge(let id):
                return merging[id] ?? false
            case .lock(let id):
                return locked[id] ?? false
            case .close:
                return recent.contains { $0.kind == .closed && $0.actor == login }
            case .release:
                return recent.contains {
                    $0.kind == .unassigned && $0.actor == login && $0.subject == login
                }
            }
        }
        let isRerun = writes.indices.contains { index in
            switch writes[index] {
            case .issueComment, .pullRequestComment, .approve: proven[index]
            default: false
            }
        }

        // The automation's move from `ready` into the work column is the one move
        // by somebody else that leaves the card where this token expects it.
        let automated =
            token.column == workflow.columns.ready
            && column == workflow.workColumn(isDesign: isDesign)
            && !moves.isEmpty
            && moves.allSatisfy { $0.actor == projectAutomationLogin || $0.actor == login }
            && moves.contains {
                $0.actor == projectAutomationLogin && $0.from == token.column && $0.to == column
            }
        return ProofState(
            writes: writes, proven: proven, isRerun: isRerun, claimedAt: claimedAt,
            holders: holders, claimHeld: holders.contains(login), column: column,
            takenFrom: automated ? column : token.column,
            cardWhereTaken: column == token.column || automated)
    }
}

private func perform(
    _ write: FinishWrite, _ request: FinishRequest, from column: String, board: BoardProvider,
    source: SourceControl, context: FinishContext
) throws {
    let issue = request.token.issue
    switch write {
    case .issueComment(let body):
        try board.comment(on: issue, body: body)
    case .pullRequestComment(let id, let body):
        try source.comment(on: id, body: body)
    case .move(let to):
        try board.move(issue, to: to, from: column)
    case .assignOwner(let id):
        try source.assign(id, to: context.owner)
    case .requestReview(let id):
        try source.requestReview(id, from: context.owner)
    case .approve(let id, let commit, let body):
        try source.approve(id, commit: commit, body: body)
    case .autoMerge(let id):
        try source.enableAutoMerge(id)
    case .lock(let id):
        try source.lock(id)
    case .close:
        try board.closeIssue(issue)
    case .release:
        try board.release(issue, login: request.token.login)
    }
}

private func incomplete(
    _ request: FinishRequest, writes: [FinishWrite], proven: [Bool], from: String, _ error: Error
) -> FinishAnswer {
    incomplete(
        request,
        done: writes.indices.filter { proven[$0] }.map { writes[$0].label(from: from) },
        pending: writes.indices.filter { !proven[$0] }.map { writes[$0].label(from: from) },
        error)
}

private func incomplete(_ request: FinishRequest, done: [String], pending: [String], _ error: Error)
    -> FinishAnswer
{
    .incomplete(
        IncompleteAnswer(
            issue: request.token.issue, outcome: request.outcome.rawValue, done: done,
            pending: pending, message: (error as? BoardError)?.message ?? "\(error)"))
}

// MARK: - Helper verbs

/// What a helper verb answers.
struct HelperAnswer: Encodable, Equatable {
    var schema = answerSchema
    /// `filed`, `replied`, `blocker` or `rejected`.
    let kind: String
    let issue: Int
    /// The issue filed, for `filed`.
    var number: Int? = nil
    /// Whether an earlier run had already done it.
    var existing: Bool? = nil
    /// Whether a blocker verb changed the relation.
    var changed: Bool? = nil
    var message: String? = nil

    var json: String { encodeAnswer(self) }

    static func rejected(_ issue: Int, _ message: String) -> HelperAnswer {
        HelperAnswer(kind: "rejected", issue: issue, message: message)
    }
}

/// The checks every helper verb makes: whose token, which repository, and the
/// claim still this token's.
private func helperProblem(_ token: ClaimToken, board: BoardProvider, context: FinishContext)
    throws -> String?
{
    let login = try board.viewer()
    guard token.login == login else { return "the token is \(token.login)'s, and this is \(login)" }
    guard token.repository == context.issueRepository else {
        return
            "the token names \(token.repository), and loop.json's repository is \(context.issueRepository)"
    }
    let claimedAt = try board.events(on: token.issue, since: .distantPast)
        .filter { $0.kind == .assigned && $0.subject == login }.map(\.createdAt).max()
    let holders = try board.snapshot(refresh: true).item(number: token.issue)?.assignees ?? []
    guard claimedAt == token.claimedAt, holders.contains(login) else {
        return "\(login) no longer holds the claim this token names on #\(token.issue)"
    }
    return nil
}

/// Runs a helper verb's checks, then its body. A failed read is a rejection
/// naming it, since nothing was written.
private func helper(
    _ token: ClaimToken, board: BoardProvider, context: FinishContext,
    _ body: () throws -> HelperAnswer
) -> HelperAnswer {
    do {
        if let problem = try helperProblem(token, board: board, context: context) {
            return .rejected(token.issue, problem)
        }
        return try body()
    } catch {
        return .rejected(token.issue, (error as? BoardError)?.message ?? "\(error)")
    }
}

/// `file-issue` and `decompose`: one issue per key, in the issue repository,
/// found again by its marker in any state rather than filed twice.
func fileIssue(
    token: ClaimToken, key: String, title: String, body: String, labels: [String],
    decomposing: Bool, board: BoardProvider, context: FinishContext
) -> HelperAnswer {
    if decomposing && token.task != .decompose {
        return .rejected(
            token.issue, "decompose is for a decompose task, and this is \(token.task.rawValue)")
    }
    return helper(token, board: board, context: context) {
        let marker = issueMarker(token, key: key)
        let filed = try board.issues(createdBy: token.login, since: token.claimedAt)
        if let existing = filed.first(where: { carriesLine($0.body, marker) }) {
            try fileInBacklog(existing.number, board: board, workflow: context.workflow)
            return HelperAnswer(
                kind: "filed", issue: token.issue, number: existing.number, existing: true)
        }
        let opening =
            decomposing ? "Part of #\(token.issue)." : "Found while implementing #\(token.issue)."
        let text = [opening, body.trimmingCharacters(in: .whitespacesAndNewlines), marker]
            .joined(separator: "\n\n")
        var labels = labels
        if decomposing, let stack = context.stackLabel, !labels.contains(stack),
            try board.labels(of: token.issue).contains(stack)
        {
            labels.append(stack)
        }
        let number = try board.createIssue(IssueDraft(title: title, body: text, labels: labels))
        try fileInBacklog(number, board: board, workflow: context.workflow)
        return HelperAnswer(kind: "filed", issue: token.issue, number: number, existing: false)
    }
}

/// Puts an issue the loop filed in Backlog, where the loop can see it but not
/// take it, whatever column a project's add workflow gives new issues. A card
/// already in a column the loop names stays there, so a retry never undoes a
/// move made since.
private func fileInBacklog(_ issue: Int, board: BoardProvider, workflow: Workflow) throws {
    let column = try board.addToBoard(issue)
    if let column, workflow.columns.all.contains(column) { return }
    try board.place(issue, in: workflow.columns.backlog)
}

private func carriesLine(_ body: String, _ line: String) -> Bool {
    body.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == line }
}

/// `add-blocker` and `remove-blocker`, on the token's issue.
func changeBlocker(
    token: ClaimToken, blocker: Int, adding: Bool, board: BoardProvider, context: FinishContext
) -> HelperAnswer {
    helper(token, board: board, context: context) {
        guard blocker != token.issue else {
            return .rejected(token.issue, "#\(token.issue) cannot block itself")
        }
        let changed =
            adding
            ? try board.addBlocker(blocker, to: token.issue)
            : try board.removeBlocker(blocker, from: token.issue)
        return HelperAnswer(kind: "blocker", issue: token.issue, changed: changed)
    }
}

/// `reply`: a comment on the issue's pull request answering outstanding
/// feedback, one `Answering` line per url.
func reply(
    token: ClaimToken, answering: [String], body: String, board: BoardProvider,
    source: SourceControl, context: FinishContext
) -> HelperAnswer {
    guard !answering.isEmpty else { return .rejected(token.issue, "reply needs --answering") }
    return helper(token, board: board, context: context) {
        let marker = replyMarker(token, answering: answering)
        let open = try board.linkedPullRequests(of: token.issue).filter(\.open).map(\.id)
        for id in open where carries(try source.conversation(id), marker: marker, by: token.login) {
            return HelperAnswer(kind: "replied", issue: token.issue, existing: true)
        }
        for id in open {
            let outstanding = Set(try source.unansweredFeedback(id))
            guard answering.allSatisfy(outstanding.contains) else { continue }
            let lines = answering.map { "Answering \($0)." }.joined(separator: "\n")
            try source.comment(
                on: id,
                body: [body.trimmingCharacters(in: .whitespacesAndNewlines), lines, marker]
                    .joined(separator: "\n\n"))
            return HelperAnswer(kind: "replied", issue: token.issue, existing: false)
        }
        return .rejected(
            token.issue,
            "no open pull request on #\(token.issue) has all of these as outstanding feedback")
    }
}
