import Foundation

// `next`: the start of a tick as one verb. It loads and checks `loop.json`, runs
// the repairs when the tick holds `orchestrator`, resumes this login's own claim,
// selects, claims and re-checks, and prints one JSON answer. See "Start of tick"
// in docs/orchestration-in-swift.md.
//
// The instructions don't call it until the cut-over. `next --preview` reads and
// selects only, so it can run beside the live loop to check parity.

// MARK: - The token

/// Everything `finish` needs to re-check a claim, as `~`-separated plain text,
/// so nothing is stored locally and an interrupted tick loses nothing.
struct ClaimToken: Equatable {
    static let version = "tw1"
    private static let separator = "~"
    /// What a column or branch may keep as it is inside a token: a space or a `~`
    /// would end the field.
    private static let fieldCharacters = CharacterSet.alphanumerics

    let login: String
    /// The issue repository, `loop.json`'s `repository`.
    let repository: String
    let issue: Int
    let role: Role
    let task: TickTask
    /// The column the card was taken from.
    let column: String
    /// The `assigned` event `next` read back.
    let claimedAt: Date
    /// A stacked start's parent branch, the base `finish submitted` requires. An
    /// optional last field, so a token without it reads as before.
    let stackBranch: String?

    var text: String {
        let fields = [
            Self.version, login, repository, String(issue), role.rawValue, task.rawValue,
            Self.encoded(column), ISO8601DateFormatter().string(from: claimedAt),
        ]
        return (fields + (stackBranch.map { [Self.encoded($0)] } ?? []))
            .joined(separator: Self.separator)
    }

    private static func encoded(_ field: String) -> String {
        field.addingPercentEncoding(withAllowedCharacters: fieldCharacters) ?? field
    }

    init(
        login: String, repository: String, issue: Int, role: Role, task: TickTask, column: String,
        claimedAt: Date, stackBranch: String? = nil
    ) {
        self.login = login
        self.repository = repository
        self.issue = issue
        self.role = role
        self.task = task
        self.column = column
        self.claimedAt = claimedAt
        self.stackBranch = stackBranch
    }

    init(parsing text: String) throws {
        let fields = text.components(separatedBy: Self.separator)
        let stackBranch = fields.count == 9 ? fields[8].removingPercentEncoding : nil
        guard fields.count == 8 || stackBranch != nil, fields[0] == Self.version,
            let issue = Int(fields[3]), let role = Role(rawValue: fields[4]),
            let task = TickTask(rawValue: fields[5]), let column = fields[6].removingPercentEncoding
        else { throw BoardError("not a \(Self.version) claim token: \(text)") }
        self.init(
            login: fields[1], repository: fields[2], issue: issue, role: role, task: task,
            column: column, claimedAt: try date(fields[7]), stackBranch: stackBranch)
    }
}

// MARK: - Answers

/// The shape every answer's `schema` names. A change a reader must notice raises it.
let answerSchema = 1

struct BudgetAnswer: Encodable, Equatable {
    let remaining: Int
    let limit: Int
}

struct SkipAnswer: Encodable, Equatable {
    let issue: Int
    let reason: String
    let detail: String?

    init(_ skip: Skip) {
        issue = skip.issue
        reason = skip.reason.rawValue
        detail = skip.detail
    }
}

struct IssueAnswer: Encodable, Equatable {
    let number: Int
    let repository: String
    let title: String
    /// The `type:` label's value, if the issue has one.
    let type: String?
    let labels: [String]
    let url: String
}

struct PullRequestAnswer: Encodable, Equatable {
    /// `owner/name#N`.
    let ref: String
    let branch: String
    /// The head commit when the item was assigned: what an `approved` review
    /// passes as `--head` when it judged that commit.
    let head: String
    /// `nil` while GitHub is still working it out.
    let mergeable: Bool?
    /// `green`, `red` or `running`.
    let checks: String
}

struct FindingAnswer: Encodable, Equatable {
    /// `check`, `conflict`, `behind`, `owner-feedback`, `reviewer-findings`,
    /// `restack` or `stack-broken`.
    let kind: String
    var url: String? = nil
    var detail: String? = nil
    /// A `restack`'s new base: a commit, or `main`.
    var onto: String? = nil
    /// Whether a `restack` also changes the base to `main`.
    var retarget: Bool? = nil
}

/// A stacked start's parent: what it branches from and the base it targets.
struct StackAnswer: Encodable, Equatable {
    /// The parent issue.
    let parent: Int
    /// The parent's pull request, `owner/name#N`.
    let pullRequest: String
    /// That pull request's branch, the stacked pull request's base.
    let branch: String
    /// Its head when chosen, which the work branches from.
    let head: String

    init(_ base: StackBase) {
        parent = base.parent
        pullRequest = "\(base.pullRequest.repository)#\(base.pullRequest.number)"
        branch = base.branch
        head = base.head
    }
}

struct AssignmentAnswer: Encodable, Equatable {
    var schema = answerSchema
    var kind = "assignment"
    let token: String
    let tickwork: String?
    let budget: BudgetAnswer
    let repairs: [String]
    let skipped: [SkipAnswer]
    let notes: [String]
    let role: String
    let resumed: Bool
    let issue: IssueAnswer
    let task: String
    /// Set only on a stacked start.
    var stack: StackAnswer? = nil
    let pullRequest: PullRequestAnswer?
    let findings: [FindingAnswer]
    let instructions: String
    let outcomes: [String]
}

struct PreviewAnswer: Encodable, Equatable {
    var schema = answerSchema
    var kind = "preview"
    let tickwork: String?
    let budget: BudgetAnswer
    let skipped: [SkipAnswer]
    let notes: [String]
    /// The rest is absent when nothing would be taken.
    let issue: Int?
    let role: String?
    let task: String?
}

struct IdleAnswer: Encodable, Equatable {
    var schema = answerSchema
    var kind = "idle"
    let tickwork: String?
    let budget: BudgetAnswer?
    let repairs: [String]
    let skipped: [SkipAnswer]
    let notes: [String]
    /// `now` after repairs that changed the board, `backoff` otherwise.
    let nextDelay: String
}

/// Where `next` stopped, and what an agent does about it.
enum ErrorStage: String, Encodable {
    /// The file is invalid, so no role can be trusted.
    case loopJSON = "loop.json"
    /// GraphQL is below the read reserve.
    case budget
    /// A read or write failed.
    case provider
    /// The claim did not take, so the login lacks write access.
    case claimPermission = "claim-permission"
    /// `review.agentApproval` is on, and the repository's ruleset can't be read or
    /// doesn't make an agent's approval safe.
    case unsafeRuleset = "unsafe-ruleset"
    /// A `loop.json` setting the repository's own settings don't allow.
    case config
}

struct ErrorAnswer: Encodable, Equatable {
    var schema = answerSchema
    var kind = "error"
    let stage: ErrorStage
    let message: String
    let retry: Bool
}

enum NextAnswer: Equatable {
    case assignment(AssignmentAnswer)
    case preview(PreviewAnswer)
    case idle(IdleAnswer)
    case error(ErrorAnswer)

    var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data: Data?
        switch self {
        case .assignment(let answer): data = try? encoder.encode(answer)
        case .preview(let answer): data = try? encoder.encode(answer)
        case .idle(let answer): data = try? encoder.encode(answer)
        case .error(let answer): data = try? encoder.encode(answer)
        }
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

// MARK: - The request

struct NextRequest {
    /// `origin/main:loop.json`, the file every verb reads.
    let arrangementJSON: String
    /// `--roles`; `nil` asks for all four.
    let roles: Set<Role>?
    let preview: Bool
    /// The Tickwork revision this build is, when its `revision` file says.
    let revision: String?
}

/// A failure at a stage the answer names.
private struct NextFailure: Error {
    let stage: ErrorStage
    let message: String
    let retry: Bool
}

// MARK: - next

/// The whole of `next`. Every failure is an `error` answer, and a failure after
/// the claim releases it first.
///
/// `runRepairs` is the repairs with `--apply`, returning their lines. It runs
/// only when the tick holds `orchestrator` and is not a preview.
func next(
    _ request: NextRequest, board: BoardProvider, source: SourceControl,
    runRepairs: () throws -> [String]
) -> NextAnswer {
    var tick = Tick(request: request, board: board, source: source)
    do {
        return try tick.run(runRepairs: runRepairs)
    } catch {
        let failure =
            error as? NextFailure
            ?? NextFailure(
                stage: .provider, message: (error as? BoardError)?.message ?? "\(error)",
                retry: true)
        var message = failure.message
        if let held = tick.claimed {
            do {
                try board.release(held, login: tick.login)
            } catch {
                message += "; releasing #\(held) failed too: \(error)"
            }
        }
        return .error(ErrorAnswer(stage: failure.stage, message: message, retry: failure.retry))
    }
}

/// One `next`, with what it has learned so far.
private struct Tick {
    let request: NextRequest
    let board: BoardProvider
    let source: SourceControl
    var login = ""
    /// The issue this tick holds a claim on, so a failure can release it.
    var claimed: Int?
    var notes: [String] = []
    var skipped: [Skip] = []
    var repairLines: [String] = []
    var gatherer: Gatherer
    /// The names `origin/main`'s `loop.json` gives the columns and labels.
    var workflow = Workflow.standard
    /// `origin/main`'s `loop.json` `repository`, which the token names.
    var repository = ""

    init(request: NextRequest, board: BoardProvider, source: SourceControl) {
        self.request = request
        self.board = board
        self.source = source
        gatherer = Gatherer(board: board, source: source)
    }

    mutating func run(runRepairs: () throws -> [String]) throws -> NextAnswer {
        let arrangement = try loadArrangement(request.arrangementJSON)
        repository = arrangement.repository
        workflow = arrangement.workflow
        gatherer.workflow = workflow
        gatherer.stackLabel = arrangement.stackLabel
        gatherer.lockConversations = arrangement.lockConversations
        login = try board.viewer()
        let roles = heldRoles(arrangement)

        let budget = try board.budget()
        do {
            try budget.requireReadReserve()
        } catch let error as BoardError {
            throw NextFailure(stage: .budget, message: error.message, retry: true)
        }
        let budgetAnswer = BudgetAnswer(remaining: budget.remaining, limit: budget.limit)
        try requireRepositorySettings(arrangement)
        if arrangement.agentApproval != nil {
            gatherer.agentLogins = Set(arrangement.agents.map(\.login))
        }

        guard !roles.isEmpty else {
            notes.append("this tick holds no roles")
            return idle(budgetAnswer)
        }
        if roles.contains(.orchestrator) && !request.preview {
            repairLines = try runRepairs()
        }

        let snapshot = try board.snapshot(refresh: true)
        // `check-loop` runs offline, so the board is where a column is checked.
        let missing = workflowColumnProblems(workflow, boardColumns: snapshot.columns)
        guard missing.isEmpty else {
            throw NextFailure(
                stage: .loopJSON, message: missing.joined(separator: "; "), retry: false)
        }
        let agent = SelectingAgent(login: login, roles: roles)

        if !request.preview,
            let resumed = try resume(snapshot: snapshot, agent: agent, budget: budgetAnswer)
        {
            return resumed
        }

        for item in candidates(in: snapshot) {
            guard let role = try role(for: item), roles.contains(role) else { continue }
            guard let pick = try choose(item, agent: agent) else { continue }
            if let answer = try take(item, pick, budget: budgetAnswer) { return answer }
        }
        // The second pass, only once the first has found nothing.
        if gatherer.stackLabel != nil, roles.contains(.engineer) {
            for item in snapshot.items where item.status == workflow.columns.ready {
                guard let pick = try chooseStacked(item, agent: agent) else { continue }
                if let answer = try take(item, pick, budget: budgetAnswer) { return answer }
            }
        }

        if request.preview {
            return .preview(
                PreviewAnswer(
                    tickwork: request.revision, budget: budgetAnswer,
                    skipped: skipped.map(SkipAnswer.init), notes: notes, issue: nil, role: nil,
                    task: nil))
        }
        return idle(budgetAnswer)
    }

    /// The answer for a pick: a preview, or the assignment once the claim holds.
    /// `nil` when the claim didn't, so the next card is tried.
    private mutating func take(_ item: Item, _ pick: Pick, budget: BudgetAnswer) throws
        -> NextAnswer?
    {
        if request.preview {
            return .preview(
                PreviewAnswer(
                    tickwork: request.revision, budget: budget,
                    skipped: skipped.map(SkipAnswer.init), notes: notes, issue: pick.issue,
                    role: pick.role.rawValue, task: pick.task.rawValue))
        }
        guard let claimedAt = try claim(item, pick) else { return nil }
        return .assignment(
            try assignment(pick, item: item, claimedAt: claimedAt, resumed: false, budget: budget))
    }

    private func idle(_ budget: BudgetAnswer?) -> NextAnswer {
        .idle(
            IdleAnswer(
                tickwork: request.revision, budget: budget, repairs: repairLines,
                skipped: skipped.map(SkipAnswer.init), notes: notes,
                nextDelay: repairsChangedTheBoard(repairLines) ? "now" : "backoff"))
    }

    /// The repository settings `loop.json`'s optional features rely on.
    private func requireRepositorySettings(_ arrangement: LoopConfiguration) throws {
        let repository = arrangement.repository
        if arrangement.agentApproval != nil {
            let shortfalls: [String]
            do {
                shortfalls = try source.mainRules(in: repository).shortfalls
            } catch {
                throw NextFailure(
                    stage: .unsafeRuleset,
                    message:
                        "review.agentApproval is on, and \(repository)'s rules for main can't be read: "
                        + ((error as? BoardError)?.message ?? "\(error)"),
                    retry: false)
            }
            guard shortfalls.isEmpty else {
                throw NextFailure(
                    stage: .unsafeRuleset,
                    message: "review.agentApproval is on, but on \(repository)'s main "
                        + shortfalls.joined(separator: ", "),
                    retry: false)
            }
        }
        if arrangement.autoMerge, try !source.allowsAutoMerge(in: repository) {
            throw NextFailure(
                stage: .config,
                message: "merge.auto is on, but \(repository) doesn't allow auto-merge",
                retry: false)
        }
    }

    // MARK: loop.json and roles

    private func loadArrangement(_ json: String) throws -> LoopConfiguration {
        let data = Data(json.utf8)
        let document: [String: JSON]?
        do {
            document = try JSONDecoder().decode(JSON.self, from: data).object
        } catch {
            throw NextFailure(stage: .loopJSON, message: "not valid JSON: \(error)", retry: false)
        }
        guard let document else {
            throw NextFailure(
                stage: .loopJSON, message: "the document is not an object", retry: false)
        }
        let problems = loopProblems(in: document)
        guard problems.isEmpty else {
            throw NextFailure(
                stage: .loopJSON, message: problems.joined(separator: "; "), retry: false)
        }
        do {
            return try JSONDecoder().decode(LoopConfiguration.self, from: data)
        } catch {
            throw NextFailure(stage: .loopJSON, message: "\(error)", retry: false)
        }
    }

    /// The roles asked for that `loop.json` gives this login. A login it doesn't
    /// list is a single agent and keeps them all.
    private mutating func heldRoles(_ arrangement: LoopConfiguration) -> Set<Role> {
        let asked = request.roles ?? Set(Role.allCases)
        guard let entry = arrangement.agents.first(where: { $0.login == login }) else {
            notes.append("running unlisted: loop.json lists no agent \(login)")
            return asked
        }
        let given = Set(entry.roles.compactMap(Role.init(rawValue:)))
        for role in Role.allCases where asked.contains(role) && !given.contains(role) {
            notes.append("gave up \(role.rawValue): loop.json does not give it to \(login)")
        }
        return asked.intersection(given)
    }

    // MARK: Choosing

    /// The cards selection reads, in the order it reads them: right to left, and
    /// by priority within each column.
    private func candidates(in snapshot: Board) -> [Item] {
        workflow.selectionOrder.flatMap { column in
            snapshot.items.filter { $0.status == column.column }
        }
    }

    /// The role a card's column asks for, reading labels only for `Ready`.
    private mutating func role(for item: Item) throws -> Role? {
        guard let column = workflow.selectionOrder.first(where: { $0.column == item.status }) else {
            return nil
        }
        if let role = column.role { return role }
        return try gatherer.labels(of: item.number).contains(workflow.labels.design)
            ? .designer : .engineer
    }

    /// The pick `select` makes of one card, recording any skip.
    private mutating func choose(_ item: Item, agent: SelectingAgent) throws -> Pick? {
        let selection = select(
            from: [try gatherer.facts(for: item)], agent: agent, redOnMain: gatherer.redOnMain,
            workflow: workflow)
        skipped += selection.skipped
        return selection.pick
    }

    /// The second pass's pick of one `Ready` card, recording any skip. The parent
    /// is read only for a labelled card with one open blocker.
    private mutating func chooseStacked(_ item: Item, agent: SelectingAgent) throws -> Pick? {
        var card = try gatherer.facts(for: item)
        if card.isStackable, !card.isDesign, !card.isEpic, card.assignees.isEmpty,
            !card.isUnlocked, card.openBlockers.count == 1
        {
            card.stackParent = try gatherer.stackParent(card.openBlockers[0])
        }
        let selection = selectStacked(from: [card], agent: agent, workflow: workflow)
        skipped += selection.skipped
        return selection.pick
    }

    /// Claims the card and checks the board again. `nil`, with a skip recorded,
    /// when somebody got there first or the card moved.
    private mutating func claim(_ item: Item, _ pick: Pick) throws -> Date? {
        switch try board.claim(item.number, as: login) {
        case .held(let holders):
            skipped.append(
                Skip(
                    issue: item.number, reason: .claimed,
                    detail: holders.joined(separator: ", ")))
            return nil
        case .didNotTake:
            throw NextFailure(
                stage: .claimPermission,
                message: "the claim on #\(item.number) did not take; "
                    + "\(login) may have no write access",
                retry: false)
        case .claimed:
            claimed = item.number
        }

        let fresh = try board.snapshot(refresh: true)
        let found = fresh.column(of: item.number)
        if found != item.status {
            try giveBack(
                item.number, Skip(issue: item.number, reason: .moved, detail: "now in \(found)"))
            return nil
        }
        // A stacked start still has its one parent open, and any other start none.
        if item.status == workflow.columns.ready {
            let open = try board.blockers(of: item.number)
            let expected = pick.stack.map { [$0.parent] } ?? []
            if open != expected {
                try giveBack(
                    item.number,
                    Skip(
                        issue: item.number, reason: pick.stack == nil ? .blocked : .notStackable,
                        detail: open.isEmpty
                            ? "no blocker is open now"
                            : open.map { "#\($0)" }.joined(separator: ", ") + " open"))
                return nil
            }
        }
        return try claimTime(of: item.number)
    }

    private mutating func giveBack(_ issue: Int, _ skip: Skip) throws {
        try board.release(issue, login: login)
        claimed = nil
        skipped.append(skip)
    }

    /// The newest `assigned` event naming this login: what tells this claim from
    /// an earlier one by the same login.
    private func claimTime(of issue: Int) throws -> Date {
        let assignments = try board.events(on: issue, since: .distantPast).filter {
            $0.kind == .assigned && $0.subject == login
        }
        guard let newest = assignments.map(\.createdAt).max() else {
            throw BoardError("#\(issue) is claimed by \(login) but shows no assignment to it")
        }
        return newest
    }

    /// This login's own claim on a card in a working column, taken back first
    /// (change 1). A claim `select` would no longer pick is released.
    private mutating func resume(snapshot: Board, agent: SelectingAgent, budget: BudgetAnswer)
        throws -> NextAnswer?
    {
        for item in candidates(in: snapshot) where item.assignees.contains(login) {
            guard item.assignees == [login] else {
                notes.append(
                    "#\(item.number) is claimed by \(item.assignees.joined(separator: ", ")) "
                        + "as well as \(login), so it is not resumed")
                continue
            }
            guard let role = try role(for: item), agent.roles.contains(role) else {
                notes.append(
                    "\(login) holds #\(item.number) in \(item.status), "
                        + "which this tick's roles do not take")
                continue
            }
            let unclaimed = Item(
                id: item.id, number: item.number, title: item.title, status: item.status,
                assignees: [])
            claimed = item.number
            // A stacked start is blocked by its parent, so only the second pass
            // would still pick it.
            var pick = try choose(unclaimed, agent: agent)
            if pick == nil, gatherer.stackLabel != nil {
                pick = try chooseStacked(unclaimed, agent: agent)
            }
            guard let pick else {
                try board.release(item.number, login: login)
                claimed = nil
                continue
            }
            return .assignment(
                try assignment(
                    pick, item: item, claimedAt: claimTime(of: item.number), resumed: true,
                    budget: budget))
        }
        return nil
    }

    // MARK: The assignment

    private mutating func assignment(
        _ pick: Pick, item: Item, claimedAt: Date, resumed: Bool, budget: BudgetAnswer
    ) throws -> AssignmentAnswer {
        let labels = try gatherer.labels(of: item.number)
        let token = ClaimToken(
            login: login, repository: repository, issue: item.number, role: pick.role,
            task: pick.task, column: item.status, claimedAt: claimedAt,
            stackBranch: pick.stack?.branch)

        var pullRequest: PullRequestAnswer?
        var findings: [FindingAnswer] = []
        let open = try gatherer.pullRequests(of: item.number).filter(\.open).map(\.id)
        for id in open {
            let merge = try gatherer.merge(id)
            let checks = try gatherer.checks(id, at: merge.headSHA)
            if pullRequest == nil {
                pullRequest = PullRequestAnswer(
                    ref: "\(id.repository)#\(id.number)", branch: merge.branch, head: merge.headSHA,
                    mergeable: merge.mergeable,
                    checks: checks.unfinished
                        ? "running"
                        : checks.failing.isEmpty && checks.needsAPerson.isEmpty ? "green" : "red")
            }
            if pick.role != .reviewer {
                findings += try gatherer.findings(id, merge: merge, checks: checks)
            }
        }

        return AssignmentAnswer(
            token: token.text, tickwork: request.revision, budget: budget, repairs: repairLines,
            skipped: skipped.map(SkipAnswer.init), notes: notes, role: pick.role.rawValue,
            resumed: resumed,
            issue: IssueAnswer(
                number: item.number, repository: repository, title: item.title,
                type: labels.first { $0.hasPrefix(typeLabelPrefix) }.map {
                    String($0.dropFirst(typeLabelPrefix.count))
                },
                labels: labels, url: "https://github.com/\(repository)/issues/\(item.number)"),
            task: pick.task.rawValue, stack: pick.stack.map(StackAnswer.init),
            pullRequest: pullRequest, findings: findings,
            instructions: pick.role.rawValue, outcomes: outcomes(pick.role, pick.task))
    }
}

let typeLabelPrefix = "type:"

/// What `finish` will accept for a role and task.
func outcomes(_ role: Role, _ task: TickTask) -> [String] {
    let bailOuts = ["blocked", "needs-human", "unable"]
    switch (role, task) {
    case (.reviewer, _): return ["approved", "changes-requested"] + bailOuts
    case (.engineer, .decompose): return ["decomposed"] + bailOuts
    default: return ["submitted"] + bailOuts
    }
}

/// Whether the repairs moved, filed, noticed or released anything, which makes
/// the tick one that did something.
func repairsChangedTheBoard(_ lines: [String]) -> Bool {
    let writes = ["#", "FILE ", "NOTICE ", "RELEASE "]
    return lines.contains { line in writes.contains { line.hasPrefix($0) } }
}

// MARK: - The finish marker

/// What starts the hidden last line of every comment `finish` posts.
let finishMarkerPrefix = "<!-- tickwork:finish "
private let markerSuffix = " -->"

/// The outcome a comment's `finish` marker names, if its last line is one.
func finishOutcome(in body: String) -> String? {
    guard
        let last = body.split(separator: "\n").last?.trimmingCharacters(in: .whitespaces),
        last.hasPrefix(finishMarkerPrefix), last.hasSuffix(markerSuffix)
    else { return nil }
    return last.dropFirst(finishMarkerPrefix.count).split(separator: " ").first.map(String.init)
}

/// The url of the Reviewer's findings nothing has answered: the newest marked
/// comment, when it says `changes-requested`. An engineer's `submitted` posts a
/// newer one, which settles them.
func outstandingReviewerFindings(in conversation: [ConversationComment]) -> String? {
    guard let newest = conversation.last(where: { finishOutcome(in: $0.body) != nil }),
        finishOutcome(in: newest.body) == "changes-requested"
    else { return nil }
    return newest.url
}

// MARK: - Gathering

/// The reads `next` makes, each at most once per run.
struct Gatherer {
    let board: BoardProvider
    let source: SourceControl
    /// The checks failing on each repository's `main`, read as repositories come up.
    private(set) var redOnMain: [String: Set<String>] = [:]
    private var labelCache: [Int: [String]] = [:]
    private var lockCache: [Int: Bool] = [:]
    private var linkedCache: [Int: [LinkedPullRequest]] = [:]
    private var mergeCache: [PullRequestID: MergeFacts] = [:]
    private var checksCache: [PullRequestID: CheckFacts] = [:]
    private var feedbackCache: [PullRequestID: [String]] = [:]
    private var reviewerCache: [PullRequestID: String?] = [:]
    private var guardCache: [PullRequestID: MergeGuardVerdict] = [:]
    private var stackCache: [PullRequestID: StackFinding?] = [:]
    private var ownerReviewCache: [Item]?
    private var blockerCache: [Int: [Int]] = [:]
    private var stackParentCache: [Int: StackParent] = [:]
    var workflow = Workflow.standard
    /// `stack.label`, which turns on selection's second pass.
    var stackLabel: String?
    /// `lockConversations`, which reads each candidate's lock.
    var lockConversations = false
    /// Every agent login, when `review.agentApproval` is on: whose approval on a
    /// head means the pull request is merging.
    var agentLogins: Set<String>?

    init(board: BoardProvider, source: SourceControl) {
        self.board = board
        self.source = source
    }

    mutating func labels(of issue: Int) throws -> [String] {
        if let cached = labelCache[issue] { return cached }
        let labels = try board.labels(of: issue)
        labelCache[issue] = labels
        return labels
    }

    /// Read once per run, since the second pass reads `Ready` again.
    mutating func isLocked(_ issue: Int) throws -> Bool {
        if let cached = lockCache[issue] { return cached }
        let locked = try board.isLocked(issue)
        lockCache[issue] = locked
        return locked
    }

    mutating func pullRequests(of issue: Int) throws -> [LinkedPullRequest] {
        if let cached = linkedCache[issue] { return cached }
        let linked = try board.linkedPullRequests(of: issue)
        linkedCache[issue] = linked
        return linked
    }

    mutating func merge(_ id: PullRequestID) throws -> MergeFacts {
        if let cached = mergeCache[id] { return cached }
        let merge = try source.mergeFacts(id)
        mergeCache[id] = merge
        return merge
    }

    mutating func checks(_ id: PullRequestID, at head: String) throws -> CheckFacts {
        if let cached = checksCache[id] { return cached }
        let checks = try source.checks(in: id.repository, at: head)
        checksCache[id] = checks
        if redOnMain[id.repository] == nil {
            redOnMain[id.repository] = Set(try source.checks(in: id.repository, at: "main").failing)
        }
        return checks
    }

    mutating func unansweredFeedback(_ id: PullRequestID) throws -> [String] {
        if let cached = feedbackCache[id] { return cached }
        let feedback = try source.unansweredFeedback(id)
        feedbackCache[id] = feedback
        return feedback
    }

    mutating func reviewerFindings(_ id: PullRequestID) throws -> String? {
        if let cached = reviewerCache[id] { return cached }
        let url = outstandingReviewerFindings(in: try source.conversation(id))
        reviewerCache[id] = url
        return url
    }

    mutating func mergeGuard(_ id: PullRequestID, merge: MergeFacts) throws -> MergeGuardVerdict {
        if let cached = guardCache[id] { return cached }
        let verdict = try BoardCore.mergeGuard(id, merge: merge, board: board, source: source)
        guardCache[id] = verdict
        return verdict
    }

    /// What a stacked pull request's parent asks of it, judged against the cards
    /// in the owner's column.
    mutating func stackFinding(_ id: PullRequestID, merge: MergeFacts) throws -> StackFinding? {
        if let cached = stackCache[id] { return cached }
        if ownerReviewCache == nil {
            ownerReviewCache = try board.snapshot(refresh: false).items.filter {
                $0.status == workflow.columns.ownerReview
            }
        }
        let finding = try BoardCore.stackFinding(
            id, merge: merge, ownerReview: ownerReviewCache ?? [], source: source)
        stackCache[id] = finding
        return finding
    }

    /// Read once per run, since the second pass reads `Ready` again. The claim's
    /// re-check reads the board itself.
    mutating func blockers(of issue: Int) throws -> [Int] {
        if let cached = blockerCache[issue] { return cached }
        let open = try board.blockers(of: issue)
        blockerCache[issue] = open
        return open
    }

    /// What the parent issue offers a stacked start, read once per run however
    /// many cards it blocks.
    mutating func stackParent(_ parent: Int) throws -> StackParent {
        if let cached = stackParentCache[parent] { return cached }
        let found = try BoardCore.stackParent(
            parent, snapshot: try board.snapshot(refresh: false), workflow: workflow,
            board: board, source: source)
        stackParentCache[parent] = found
        return found
    }

    /// Everything against an open pull request, apart from checks red on `main` too.
    mutating func findings(_ id: PullRequestID, merge: MergeFacts, checks: CheckFacts) throws
        -> [FindingAnswer]
    {
        let red = redOnMain[id.repository] ?? []
        var findings = checks.failing.filter { !red.contains($0) }.map {
            FindingAnswer(kind: "check", detail: $0)
        }
        // A stacked pull request is judged against its parent, not its base.
        if merge.base != "main" {
            if let stack = try stackFinding(id, merge: merge) { findings.append(stack.answer) }
        } else {
            if merge.mergeable == false {
                findings.append(FindingAnswer(kind: "conflict", detail: "does not merge with main"))
            }
            if merge.mergeableState == "behind" {
                findings.append(FindingAnswer(kind: "behind", detail: "behind main"))
            }
        }
        findings += try unansweredFeedback(id).map {
            FindingAnswer(kind: "owner-feedback", url: $0)
        }
        if let url = try reviewerFindings(id) {
            findings.append(FindingAnswer(kind: "reviewer-findings", url: url))
        }
        if case .restack(let reason) = try mergeGuard(id, merge: merge) {
            findings.append(
                FindingAnswer(kind: "restack", detail: reason, onto: "main", retarget: false))
        }
        return findings
    }

    /// The facts `select` reads about one card, reading only what its column needs.
    mutating func facts(for item: Item) throws -> CardFacts {
        let labels = try labels(of: item.number)
        var card = CardFacts(
            number: item.number, column: item.status, assignees: item.assignees,
            isDesign: labels.contains(workflow.labels.design))
        card.isEpic = labels.contains(workflow.labels.epic)
        guard !card.isEpic, item.assignees.isEmpty else { return card }
        if lockConversations {
            card.isUnlocked = try !isLocked(item.number)
            guard !card.isUnlocked else { return card }
        }

        let columns = workflow.columns
        switch item.status {
        case columns.ready:
            card.openBlockers = try blockers(of: item.number)
            card.isStackable = stackLabel.map(labels.contains) ?? false
        case columns.design, columns.work, columns.review:
            card.pullRequests = try pullRequests(of: item.number)
            for id in card.pullRequests.filter(\.open).map(\.id) {
                let merge = try merge(id)
                card.merge[id] = merge
                guard item.status != columns.design else { continue }
                card.checks[id] = try checks(id, at: merge.headSHA)
                if item.status == columns.review, let agentLogins,
                    agentApproved(try source.reviews(id), head: merge.headSHA, agents: agentLogins)
                {
                    card.agentApproved.insert(id)
                }
                guard item.status == columns.work else { continue }
                card.unansweredFeedback[id] = try unansweredFeedback(id)
                card.reviewerFindings[id] = try reviewerFindings(id)
                card.mergeGuard[id] = try mergeGuard(id, merge: merge)
                card.stack[id] = try stackFinding(id, merge: merge)
            }
        default:
            break
        }
        return card
    }
}
