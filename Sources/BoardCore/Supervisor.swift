import Foundation

// `tickwork loop <path>…`: the outer loop that wakes a model only for work. See
// docs/supervisor.md.
//
// Cheap detection and authoritative selection are two steps. A check is a
// conditional request that costs nothing while nothing has changed; a
// reconciliation is a fetch, `update` and `next`. Only a
// reconciliation selects, claims, repairs or resumes, so this file adds no rule
// about which work comes next.

// MARK: Seams

/// One conditional `GET`'s answer.
struct CheckResponse: Equatable {
    let status: Int
    /// Header names lowercased.
    let headers: [String: String]
    let body: String

    var etag: String? { headers["etag"] }
}

/// What the supervisor asks of GitHub.
protocol SupervisorGitHub {
    /// A `GET` of `path`, conditional on `etag` when there is one.
    func get(_ path: String, etag: String?) throws -> CheckResponse
    func viewer() throws -> String
    /// The REST path of the board's items, and its Status field's id.
    func project(owner: String, number: Int) throws -> (itemsPath: String, statusFieldID: Int)
    /// Every page of an issue's timeline, slurped.
    func timeline(of issue: Int, in repository: String) throws -> String
}

struct CommandResult: Equatable {
    let status: Int32
    let output: String
    let errors: String
}

/// Runs a command in a directory: `git` and the tool.
protocol CommandRunning {
    func run(_ arguments: [String], in directory: String) -> CommandResult
    /// The SHA-256 of a command's output, in hex. The output is piped straight
    /// into the hasher, so it is never held here. Throws when either fails.
    func sha256(ofOutput arguments: [String], in directory: String) throws -> String
}

protocol SupervisorClock: AnyObject {
    var now: Date { get }
    func sleep(until date: Date)
}

/// What a child is launched for.
struct ChildRequest: Equatable {
    let path: String
    /// The board's repository, which names the session.
    let repository: String
    /// `assignment`, or `merge` for an idle answer carrying a `MERGE` line.
    let reason: String
    /// Launch with `--thinking-display summarized`.
    let thinkingSummaries: Bool
}

protocol ChildProcess: AnyObject {
    /// `nil` while it runs.
    var exit: ChildExit? { get }
    /// Signals the child's whole process group.
    func signal(_ signal: Int32)
}

protocol ChildLaunching {
    /// `claude auth status --json`, in the child's environment.
    func authStatus() -> CommandResult
    func start(_ request: ChildRequest) throws -> ChildProcess
}

/// The tool this supervisor runs as: its `bin/tickwork` and the revision built there.
struct RunningTool: Equatable {
    let path: String
    let revision: String
}

/// Replaces this process with `sh <tool> <arguments…>`, throwing when it can't.
protocol ToolReplacing {
    func replace(tool: String, arguments: [String]) throws
}

/// Ends the supervisor, saying why.
struct SupervisorStop: Error, Equatable {
    let reason: String
}

/// A reconciliation that failed; only one that isn't `retry` needs a person.
struct ReconcileFailure: Error, Equatable {
    let message: String
    let retry: Bool
}

// MARK: Constants

enum SupervisorTiming {
    /// The login's check budget: a thirtieth of GitHub's secondary limit, below
    /// the rate measured clean.
    static let checksPerMinute = 30.0
    static let roundPeriod: TimeInterval = 15
    /// The most board pages across every path: a 30-second round.
    static let pageLimit = 15
    /// One orchestrator interval reconciliation in this period, across every
    /// repository the login orchestrates, about a third of the hourly REST limit.
    static let orchestratorTurn: TimeInterval = 5 * 60
    static let reconciliationInterval: TimeInterval = 10 * 60
    /// Below this many core requests left, interval reconciliations wait for the
    /// reset. A fifth of the hourly limit.
    static let rateFloor = 1_000
    static let firstBackoff: TimeInterval = 60
    static let longestBackoff: TimeInterval = 10 * 60
    static let secondaryPause: TimeInterval = 60
    /// How often a running child is looked at.
    static let childPoll: TimeInterval = 1
    /// Check failures in a row that back a repository's reconciliations off.
    static let failuresBeforeBackoff = 2

    /// A round's length for this many requests: never faster than the budget.
    static func roundLength(requests: Int) -> TimeInterval {
        max(roundPeriod, Double(requests) * 60 / checksPerMinute)
    }
}

private let pageSize = 100

// MARK: State

/// A doubling wait, from `firstBackoff` up to `longestBackoff`.
struct Backoff: Equatable {
    private(set) var step = 0
    private(set) var until: Date?
    /// The failure that engaged it last.
    private(set) var reason = ""

    mutating func engage(at now: Date, because reason: String) -> TimeInterval {
        step += 1
        self.reason = reason
        let wait = min(
            SupervisorTiming.firstBackoff * pow(2, Double(step - 1)),
            SupervisorTiming.longestBackoff)
        until = now.addingTimeInterval(wait)
        return wait
    }

    mutating func clear() { self = Backoff() }

    func holds(at now: Date) -> Bool { until.map { now < $0 } ?? false }
}

struct BoardCard: Equatable {
    let number: Int
    let status: String
    let updatedAt: String
}

struct WatchedPullRequest: Equatable {
    let id: PullRequestID
    var updatedAt: Date
}

/// The last answer from each of a ref's two check endpoints.
struct WatchedChecks: Equatable {
    let paths: CheckPaths
    var checkRuns: CheckResponse?
    var status: CheckResponse?

    /// Reads a round makes for one ref: its check runs and its statuses.
    static let requests = 2

    init(repository: String, ref: String) {
        paths = CheckPaths(repository: repository, ref: ref)
    }

    init(_ checks: RunningChecks) {
        self.init(repository: checks.pullRequest.repository, ref: checks.head)
    }

    /// Whether both answers are in and nothing in them is unfinished.
    func finished() throws -> Bool {
        guard let checkRuns, let status else { return false }
        return try !checkFacts(checkRunsJSON: checkRuns.body, statusJSON: status.body).unfinished
    }
}

final class SupervisedRepository {
    let path: String
    let configuration: LoopConfiguration
    let orchestrator: Bool
    let itemsPath: String
    let statusFieldID: Int

    var pageURLs: [String] = []
    var etags: [String?] = []
    var pageCards: [[BoardCard]] = []
    var dueSince: Date?
    var dueReasons: [String] = []
    var lastReconciled: Date?
    var backoff = Backoff()
    var checkFailures = 0
    var checkFailing: Failing?
    var lastChecked: Date?
    var lastChanged: Date?
    /// The last reconciliation's error, so the next to succeed reports recovering.
    var reconcileFailure: ReconcileFailure?
    /// The item `updated_at` each watched card's pull requests were resolved at.
    var resolved: [Int: String] = [:]
    /// Cards whose pull requests the last attempt couldn't read, so the next read to
    /// succeed reports recovering. Kept when a card leaves review, since nothing
    /// recovered.
    var watchFailed: [Int: Failing] = [:]
    /// The work and Git state the last child here was launched for, and how many
    /// children in a row have left it as they found it.
    var launchedEvidence: String?
    var noProgress = 0
    /// The last two children's endings, for the report when it parks.
    var results: [String] = []
    /// Stops calling `next` here until a restart: this assignment came back with
    /// no progress twice.
    var parked: SupervisorStatus.Assignment?
    /// `MERGE` lines two children left alone; idle answers carrying only these count
    /// as idle.
    var setAsideMerges: [String] = []
    /// Open pull requests of cards in the owner's review column, by issue.
    var watched: [Int: [WatchedPullRequest]] = [:]
    /// Heads whose checks were running when the last `next` passed their card over.
    var runningChecks: [(checks: RunningChecks, answers: WatchedChecks)] = []
    /// Whether the last `next` passed over work that can become takeable while
    /// the board stays as it is, which only an interval reconciliation sees.
    var waitsUnseen = true
    /// `main`'s checks, read while the repository is dormant on an orchestrator
    /// login, since only the repairs file a red `main`. Kept while it isn't, so
    /// the first read after compares with the last. Empty until the first read,
    /// which reconciles once if `main` has finished.
    var mainChecks: WatchedChecks

    init(
        path: String, configuration: LoopConfiguration, orchestrator: Bool, itemsPath: String,
        statusFieldID: Int
    ) {
        self.path = path
        self.configuration = configuration
        self.orchestrator = orchestrator
        self.itemsPath = itemsPath
        self.statusFieldID = statusFieldID
        mainChecks = WatchedChecks(repository: configuration.repository, ref: "main")
    }

    var name: String { configuration.repository }
    var cards: [BoardCard] { pageCards.flatMap { $0 } }
    var firstPage: String { "\(itemsPath)?per_page=\(pageSize)&fields=\(statusFieldID)" }
}

/// A path the supervisor was given, sorted at start.
enum SupervisedPath: Equatable {
    case repository(String)
    case workspace(String)
}

// MARK: The supervisor

final class Supervisor {
    let github: SupervisorGitHub
    let commands: CommandRunning
    let clock: SupervisorClock
    let launcher: ChildLaunching
    let home: String
    /// `nil` for a build no installer made, which runs the installed tool's verbs
    /// and never replaces itself.
    let tool: RunningTool?
    /// The tool at `~/.cache/tickwork/tool/`, read after each update; `nil` while
    /// none is installed.
    let installed: () -> RunningTool?
    let replacer: ToolReplacing
    let emit: ([String: Any]) -> Void
    /// Told the status at the end of every `step` and before every reconciliation,
    /// on the supervisor's thread.
    let publishStatus: (SupervisorStatus) -> Void
    /// The `loop` flags it was started with, which a replacement starts with too.
    let flags: [String]

    private(set) var repositories: [SupervisedRepository] = []
    private(set) var workspaces: [String] = []
    private(set) var login = ""
    private var paths: [String] = []
    /// The installed tool, when it isn't this one. It runs before anything else
    /// once no child is running, so only the reconciliation that launched a child
    /// can leave it waiting.
    private var replacement: RunningTool?

    /// Pull-request list ETags, by repository.
    private var listETags: [String: String] = [:]
    private var started = Date.distantPast
    private var nextRound = Date.distantPast
    private var nextOrchestratorTurn = Date.distantFuture
    /// No GitHub read and no reconciliation before this.
    private var githubPause: GitHubPause?
    private var secondaryPauses = 0
    private var rateRemaining: Int?
    private var rateLimit: Int?
    private var rateReset: Date?
    private var graphQL: SupervisorStatus.GraphQLBudget?
    private var child: RunningChild?
    private var reconciling: (repository: SupervisedRepository, since: Date, reasons: [String])?
    /// No launch and no `next` before this: a subscription limit or an ambiguous end.
    private var loginPause: (until: Date, cause: SupervisorStatus.PauseCause)?
    private var ambiguityPauses = 0
    /// Children launch with `--thinking-display summarized` until one is refused it.
    /// Touched only in `step`, on the supervisor's thread.
    private var thinkingSummaries = true
    private var stopped: (at: Date, reason: String)?
    /// The child whose ending stopped the supervisor, for the last block.
    private var stoppedBy:
        (repository: SupervisedRepository, outcome: String, purpose: SupervisorStatus.Purpose)?
    let interrupted: () -> Int32?

    private final class RunningChild {
        let repository: SupervisedRepository
        let process: ChildProcess
        let started: Date
        let purpose: SupervisorStatus.Purpose
        let evidence: String
        let thinkingSummaries: Bool
        var terminated: Date?
        var killed = false
        init(
            repository: SupervisedRepository, process: ChildProcess, started: Date,
            purpose: SupervisorStatus.Purpose, evidence: String, thinkingSummaries: Bool
        ) {
            self.repository = repository
            self.process = process
            self.started = started
            self.purpose = purpose
            self.evidence = evidence
            self.thinkingSummaries = thinkingSummaries
        }
    }

    init(
        github: SupervisorGitHub, commands: CommandRunning, clock: SupervisorClock,
        launcher: ChildLaunching, home: String, tool: RunningTool?,
        installed: @escaping () -> RunningTool?, replacer: ToolReplacing,
        emit: @escaping ([String: Any]) -> Void,
        status: @escaping (SupervisorStatus) -> Void = { _ in }, flags: [String] = [],
        interrupted: @escaping () -> Int32? = { nil }
    ) {
        self.publishStatus = status
        self.flags = flags
        self.interrupted = interrupted
        self.github = github
        self.commands = commands
        self.clock = clock
        self.launcher = launcher
        self.home = home
        self.tool = tool
        self.installed = installed
        self.replacer = replacer
        self.emit = emit
    }

    // MARK: Start

    /// Sorts the paths, reads every board once, and makes every repository due.
    /// Throws `SupervisorStop` for an operator error: a path that isn't a clone,
    /// or more board pages than the budget allows.
    func start(paths: [String]) throws {
        guard !paths.isEmpty else { throw SupervisorStop(reason: "loop needs at least one path") }
        self.paths = paths
        let sorted = try paths.map(classify)
        login = try stopping { try github.viewer() }
        for path in sorted {
            switch path {
            case .workspace(let path): workspaces.append(path)
            case .repository(let path): repositories.append(try supervise(path))
            }
        }
        for repository in repositories {
            while case .limited(let limit) = try firstRead(repository) {
                pause(limit, at: clock.now)
                clock.sleep(until: githubPause?.until ?? clock.now)
            }
        }
        secondaryPauses = 0
        githubPause = nil
        let now = clock.now
        let pages = repositories.reduce(0) { $0 + $1.pageURLs.count }
        guard pages <= SupervisorTiming.pageLimit else {
            throw SupervisorStop(
                reason:
                    "the boards have \(pages) pages, more than the \(SupervisorTiming.pageLimit) "
                    + "a round can check within the budget")
        }
        for repository in repositories {
            repository.lastChecked = now
            discoverWatched(repository, everyCard: true)
            markDue(repository, "start", at: now)
        }
        started = now
        nextRound = now.addingTimeInterval(SupervisorTiming.roundLength(requests: roundRequests))
        nextOrchestratorTurn = now.addingTimeInterval(SupervisorTiming.orchestratorTurn)
        emit([
            "event": "start", "login": login, "repositories": repositories.map(\.path),
            "workspaces": workspaces,
            "note": "one session per login: run no /loop /next-task on \(login) beside this",
        ])
    }

    /// A board's first read. A secondary limit is answered for `start` to wait out;
    /// any other failure is an operator's to fix.
    private func firstRead(_ repository: SupervisedRepository) throws -> CheckOutcome {
        let outcome = checkPages(repository)
        if case .failed(let message) = outcome {
            throw SupervisorStop(reason: "\(repository.name)'s board can't be read: \(message)")
        }
        return outcome
    }

    private func classify(_ path: String) throws -> SupervisedPath {
        guard path.hasPrefix("/") else {
            throw SupervisorStop(reason: "\(path) is not an absolute path")
        }
        let fetch = commands.run(["git", "fetch", "-q", "origin"], in: path)
        guard fetch.status == 0 else {
            throw SupervisorStop(
                reason: "\(path) is not a clone with an origin: \(fetch.errors.trimmed)")
        }
        let hasLoop =
            commands.run(["git", "cat-file", "-e", "origin/main:loop.json"], in: path).status == 0
        return hasLoop ? .repository(path) : .workspace(path)
    }

    private func supervise(_ path: String) throws -> SupervisedRepository {
        let configuration = try stopping {
            try LoopConfiguration.fromMain {
                commands.run(["git", "show", "origin/main:loop.json"], in: path).output
            }
        }
        let project = try stopping {
            try github.project(
                owner: configuration.project.owner, number: configuration.project.number)
        }
        let roles = configuration.agents.first { $0.login == login }?.roles ?? []
        return SupervisedRepository(
            path: path, configuration: configuration,
            orchestrator: roles.contains(Role.orchestrator.rawValue),
            itemsPath: project.itemsPath, statusFieldID: project.statusFieldID)
    }

    private func stopping<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as BoardError {
            throw SupervisorStop(reason: error.message)
        }
    }

    // MARK: Running

    /// Runs until `deadline`, or for ever without one. Returns when a
    /// `SupervisorStop` ends it, having reported why.
    func run(until deadline: Date? = nil) {
        do {
            while deadline.map({ clock.now < $0 }) ?? true {
                let wake = try step()
                if wake > clock.now { clock.sleep(until: min(wake, deadline ?? wake)) }
            }
        } catch {
            let reason = (error as? SupervisorStop)?.reason ?? "\(error)"
            stopped = (clock.now, reason)
            emit(["event": "stop", "reason": reason])
            publishStatus(status(at: clock.now))
        }
    }

    /// One pass: a child's exit, a round, the intervals, then at most one
    /// reconciliation. Answers when the next pass is due.
    func step() throws -> Date {
        defer { publishStatus(status(at: clock.now)) }
        if let signal = interrupted() { try shutdown(signal) }
        let now = clock.now
        // A GitHub pause holds GitHub reads, never the child's time limit.
        if let running = child {
            if let exit = running.process.exit {
                try childExited(running, exit, at: now)
            } else {
                enforceTimeLimit(running, at: now)
            }
        }
        if let pausedUntil = githubPause?.until, now < pausedUntil {
            guard child != nil else { return pausedUntil }
            return min(pausedUntil, now.addingTimeInterval(SupervisorTiming.childPoll))
        }
        githubPause = nil

        // Not during a pause: the new process would start with none.
        if child == nil, let replacement { try replace(with: replacement) }
        if now >= nextRound { round(at: now) }
        if githubPause != nil { return clock.now }
        intervals(at: now)

        let loginPaused = loginPause.map { now < $0.until } ?? false
        if child == nil, !loginPaused, let repository = nextDue(at: now) {
            try reconcile(repository)
            return clock.now
        }
        return wake(at: now)
    }

    // MARK: The child's lifecycle

    private func childExited(_ running: RunningChild, _ exit: ChildExit, at now: Date) throws {
        child = nil
        let repository = running.repository
        // Refused the flag before doing anything: not an ending, so it is launched
        // again without it, once, since the relaunch can't be refused the same way.
        if running.thinkingSummaries, rejectedThinkingFlag(exit) {
            thinkingSummaries = false
            emit([
                "event": "thinking-unavailable", "repository": repository.name,
                "detail": exit.firstError ?? "",
            ])
            try launch(running.purpose, running.evidence, for: repository)
            return
        }
        var outcome = classifyChild(exit, timedOut: running.terminated != nil)
        // An ending that could be a lost login is checked against the login.
        switch outcome {
        case .done, .limit, .authentication:
            break
        case .transient, .crash, .ambiguous:
            if let refusal = subscriptionRefusal(launcher.authStatus()) {
                outcome = .authentication(refusal)
            }
        }
        var event: [String: Any] = [
            "event": "child-exit", "repository": repository.name, "outcome": outcome.name,
            "status": Int(exit.status),
        ]
        switch outcome {
        case .authentication(let detail), .transient(let detail), .ambiguous(let detail):
            event["detail"] = detail
        case .done, .limit, .crash:
            break
        }
        event.merge(childUsage(exit)) { current, _ in current }
        emit(event)
        repository.results = Array((repository.results + [outcome.name]).suffix(2))
        markDue(repository, "child exited", at: now)
        rebaseline(repository)

        switch outcome {
        case .done:
            ambiguityPauses = 0
        case .limit(let until):
            // A refused child did nothing, so it isn't counted against the work.
            repository.launchedEvidence = nil
            pauseLogin(until: until, cause: .subscriptionLimit)
        case .authentication(let detail):
            stoppedBy = (repository, outcome.name, running.purpose)
            throw SupervisorStop(
                reason: "authentication failed (\(detail)); the claim stays for the next start")
        case .transient(let detail):
            backOff(repository, because: "Claude ended transient: \(detail)", at: now)
        case .crash:
            backOff(repository, because: "Claude crashed", at: now)
        case .ambiguous:
            let wait = min(
                ChildTiming.firstAmbiguityPause * pow(2, Double(ambiguityPauses)),
                ChildTiming.longestAmbiguityPause)
            ambiguityPauses += 1
            pauseLogin(until: now.addingTimeInterval(wait), cause: .ambiguousEnding)
        }
    }

    /// An earlier pause than the one already held changes nothing.
    private func pauseLogin(until: Date, cause: SupervisorStatus.PauseCause) {
        if until >= loginPause?.until ?? until { loginPause = (until, cause) }
        emit([
            "event": "pause", "reason": cause.rawValue,
            "until": ISO8601DateFormatter().string(from: loginPause?.until ?? until),
        ])
    }

    /// SIGTERM at the time limit, then SIGKILL after the grace.
    private func enforceTimeLimit(_ running: RunningChild, at now: Date) {
        if running.terminated == nil,
            now >= running.started.addingTimeInterval(ChildTiming.timeLimit)
        {
            running.terminated = now
            running.process.signal(SIGTERM)
            emit(["event": "time-limit", "repository": running.repository.name])
        } else if let terminated = running.terminated, !running.killed,
            now >= terminated.addingTimeInterval(ChildTiming.grace)
        {
            running.killed = true
            running.process.signal(SIGKILL)
        }
    }

    /// Passes a signal the supervisor received to the child, gives it the grace
    /// to exit, kills what is left, and stops. The claim is resumed on the next
    /// start.
    private func shutdown(_ signal: Int32) throws {
        if let running = child {
            running.process.signal(signal)
            let deadline = clock.now.addingTimeInterval(ChildTiming.grace)
            while running.process.exit == nil, clock.now < deadline {
                clock.sleep(
                    until: min(deadline, clock.now.addingTimeInterval(SupervisorTiming.childPoll)))
            }
            if running.process.exit == nil { running.process.signal(SIGKILL) }
        }
        throw SupervisorStop(reason: "received signal \(signal)")
    }

    /// The soonest thing still to come. Anything already past was acted on this
    /// pass or is held, by a child, a backoff or the rate floor, so it is not
    /// waited on again.
    private func wake(at now: Date) -> Date {
        var times = [nextRound]
        if child != nil { times.append(now.addingTimeInterval(SupervisorTiming.childPoll)) }
        if let loginPause { times.append(loginPause.until) }
        if repositories.contains(where: { $0.orchestrator && needsInterval($0) }) {
            times.append(nextOrchestratorTurn)
        }
        for repository in repositories {
            if !repository.orchestrator, let time = intervalTime(repository) { times.append(time) }
            if repository.dueSince != nil, let until = repository.backoff.until {
                times.append(until)
            }
        }
        if floorHolds(at: now), let rateReset { times.append(rateReset) }
        return times.filter { $0 > now }.min() ?? now.addingTimeInterval(SupervisorTiming.childPoll)
    }

    /// Of the repositories due and not backing off, the one due longest; ties go
    /// to argument order. Below the rate floor, a repository due only for its interval waits for the
    /// reset, while one with any other reason goes ahead.
    private func nextDue(at now: Date) -> SupervisedRepository? {
        let floor = floorHolds(at: now)
        return repositories.filter {
            $0.dueSince != nil && $0.parked == nil && !$0.backoff.holds(at: now)
                && !(floor && $0.dueReasons.allSatisfy { $0 == "interval" })
        }
        .min { $0.dueSince! < $1.dueSince! }
    }

    /// Each reason is recorded once. A repository whose child is running comes due
    /// only when the child exits, so a long child can't hold its place in line.
    private func markDue(_ repository: SupervisedRepository, _ reason: String, at now: Date) {
        guard child?.repository !== repository else { return }
        if repository.dueSince == nil { repository.dueSince = now }
        if !repository.dueReasons.contains(reason) { repository.dueReasons.append(reason) }
    }

    // MARK: Rounds

    private var watchedLists: [String] {
        Set(repositories.flatMap { $0.watched.values.flatMap { $0.map(\.id.repository) } }).sorted()
    }

    private var roundRequests: Int {
        repositories.reduce(0) {
            let checked = $1.runningChecks.count + (watchesMain($1) ? 1 : 0)
            return $0 + $1.pageURLs.count + checked * WatchedChecks.requests
        } + watchedLists.count
    }

    /// A dormant orchestrator repository has no interval to see `main` go red.
    private func watchesMain(_ repository: SupervisedRepository) -> Bool {
        repository.orchestrator && !needsInterval(repository)
    }

    /// Every board page and watched list. A repository's failure count moves once
    /// a round, from all of its checks together, so one source succeeding can't
    /// hide another failing.
    private func round(at now: Date) {
        var failures: [ObjectIdentifier: String] = [:]
        for repository in repositories {
            switch checkPages(repository) {
            case .unchanged:
                break
            case .changed:
                markDue(repository, "board changed", at: now)
                discoverWatched(repository, everyCard: false)
            case .failed(let message):
                failures[ObjectIdentifier(repository)] = message
            case .limited(let limit):
                pause(limit, at: now)
                return
            }
        }
        for list in watchedLists {
            switch checkPullRequests(in: list, at: now) {
            case .limited(let limit):
                pause(limit, at: now)
                return
            case .failed(let message):
                for repository in repositories where repository.watches(list) {
                    failures[ObjectIdentifier(repository)] = message
                }
            case .unchanged, .changed:
                break
            }
        }
        for repository in repositories where failures[ObjectIdentifier(repository)] == nil {
            for check in [checkRunningChecks, checkMain] {
                let outcome = check(repository, now)
                if case .limited(let limit) = outcome {
                    pause(limit, at: now)
                    return
                }
                if case .failed(let message) = outcome {
                    failures[ObjectIdentifier(repository)] = message
                    break
                }
            }
        }
        for repository in repositories {
            if let message = failures[ObjectIdentifier(repository)] {
                checkFailed(repository, message, at: now)
                continue
            }
            repository.lastChecked = now
            if repository.checkFailures > 0 {
                repository.checkFailures = 0
                repository.checkFailing = nil
                emit(["event": "check-recovered", "repository": repository.name])
            }
        }
        secondaryPauses = 0
        nextRound = now.addingTimeInterval(SupervisorTiming.roundLength(requests: roundRequests))
    }

    /// Backs off once per retry: a repository already waiting out a backoff keeps
    /// its deadline, so a lasting failure still retries at the capped interval.
    private func checkFailed(_ repository: SupervisedRepository, _ message: String, at now: Date) {
        repository.checkFailures += 1
        repository.checkFailing = Failing(
            since: repository.checkFailing?.since ?? now, message: message)
        emit(["event": "check-failed", "repository": repository.name, "message": message])
        let retryPending =
            repository.backoff.holds(at: now)
            || (repository.dueSince != nil && repository.backoff.until != nil)
        markDue(repository, "check failed", at: now)
        if repository.checkFailures >= SupervisorTiming.failuresBeforeBackoff, !retryPending {
            let wait = repository.backoff.engage(at: now, because: message)
            emit(["event": "backoff", "repository": repository.name, "seconds": Int(wait)])
        }
    }

    /// Until the later of the limits the response names: the secondary limit's
    /// wait, doubling while it repeats, and the exhausted core limit's reset.
    private func pause(_ limit: GitHubLimit, at now: Date) {
        var pause: GitHubPause?
        var wait: TimeInterval = 0
        if let retryAfter = limit.retryAfter {
            wait = retryAfter * pow(2, Double(secondaryPauses))
            secondaryPauses += 1
            pause = GitHubPause(until: now.addingTimeInterval(wait), cause: .secondaryLimit)
        }
        if let reset = limit.coreReset, reset > pause?.until ?? .distantPast {
            pause = GitHubPause(until: reset, cause: .coreLimit)
        }
        guard let pause else { return }
        githubPause = pause
        nextRound = pause.until
        if pause.cause == .coreLimit {
            emit([
                "event": "core-limit", "until": ISO8601DateFormatter().string(from: pause.until),
            ])
        } else {
            emit(["event": "secondary-limit", "seconds": Int(wait)])
        }
    }

    /// Whether the core requests left are below the floor, before their reset.
    private func floorHolds(at now: Date) -> Bool {
        guard let remaining = rateRemaining, let reset = rateReset else { return false }
        return remaining < SupervisorTiming.rateFloor && now < reset
    }

    /// Whether anything in a repository can move while its board stays as it is,
    /// which only an interval reconciliation sees. On an orchestrator login that
    /// is also any card the repairs follow there: a claim going stale, a pull
    /// request's checks, conflicts and activity, and a parked card's blocker
    /// landing. A dormant repository waits for a check to wake it.
    private func needsInterval(_ repository: SupervisedRepository) -> Bool {
        if repository.waitsUnseen { return true }
        guard repository.orchestrator else { return false }
        let columns = repository.configuration.workflow.columns
        let followed: Set = [
            columns.design, columns.work, columns.review, columns.ownerReview, columns.parked,
        ]
        return repository.cards.contains { followed.contains($0.status) }
    }

    /// The orchestrator repository an interval turn would pick now: the one
    /// reconciled longest ago that isn't dormant or running the child.
    private var orchestratorTurnRepository: SupervisedRepository? {
        repositories.filter {
            $0.orchestrator && $0 !== child?.repository && needsInterval($0)
        }.min {
            ($0.lastReconciled ?? .distantPast) < ($1.lastReconciled ?? .distantPast)
        }
    }

    /// `nil` before the first reconciliation, which `start` already made due, and
    /// while the repository is dormant.
    private func intervalTime(_ repository: SupervisedRepository) -> Date? {
        guard needsInterval(repository) else { return nil }
        return repository.lastReconciled?.addingTimeInterval(
            SupervisorTiming.reconciliationInterval)
    }

    /// The interval reconciliations: one orchestrator repository in turn every
    /// `orchestratorTurn`, any other every `reconciliationInterval`, none for a
    /// dormant repository, and none below the rate floor before its reset.
    private func intervals(at now: Date) {
        if floorHolds(at: now) { return }
        if now >= nextOrchestratorTurn {
            nextOrchestratorTurn = now.addingTimeInterval(SupervisorTiming.orchestratorTurn)
            if let turn = orchestratorTurnRepository { markDue(turn, "interval", at: now) }
        }
        for repository in repositories where !repository.orchestrator {
            if let time = intervalTime(repository), now >= time {
                markDue(repository, "interval", at: now)
            }
        }
    }

    // MARK: Checks

    enum CheckOutcome: Equatable {
        case unchanged
        case changed
        case failed(String)
        case limited(GitHubLimit)
    }

    /// What a refusal says about GitHub's limits. At least one is set.
    struct GitHubLimit: Equatable {
        /// The secondary limit's wait.
        var retryAfter: TimeInterval?
        /// When the exhausted core limit resets.
        var coreReset: Date?
    }

    private struct GitHubPause {
        let until: Date
        let cause: SupervisorStatus.PauseCause
    }

    /// Every page of the board, each with its stored ETag. A page that answers
    /// `200` replaces its cards and the cursor of the page after it.
    private func checkPages(_ repository: SupervisedRepository) -> CheckOutcome {
        var changed = false
        var index = 0
        var url: String? = repository.pageURLs.first ?? repository.firstPage
        while let page = url {
            let etag = index < repository.etags.count ? repository.etags[index] : nil
            let response: CheckResponse
            do {
                response = try github.get(page, etag: etag)
            } catch {
                return .failed((error as? BoardError)?.message ?? "\(error)")
            }
            noteRate(response)
            switch response.status {
            case 304:
                url = index + 1 < repository.pageURLs.count ? repository.pageURLs[index + 1] : nil
            case 200:
                let cards: [BoardCard]
                do {
                    cards = try boardCards(
                        itemsJSON: response.body, statusFieldID: repository.statusFieldID,
                        repository: repository.name)
                } catch {
                    return .failed((error as? BoardError)?.message ?? "\(error)")
                }
                changed = true
                repository.lastChanged = clock.now
                repository.store(page: index, url: page, etag: response.etag, cards: cards)
                url = nextLink(response.headers["link"])
                if url == nil, repository.pageURLs.count > index + 1 {
                    repository.truncate(after: index)
                }
            default:
                if let limit = githubLimit(response) {
                    return .limited(limit)
                }
                return .failed("HTTP \(response.status) for \(page)")
            }
            index += 1
        }
        return changed ? .changed : .unchanged
    }

    /// One page of a repository's pull requests, newest change first. A watched
    /// pull request on it newer than its baseline makes its board's repository due.
    private func checkPullRequests(in list: String, at now: Date) -> CheckOutcome {
        let path = "repos/\(list)/pulls?state=all&sort=updated&direction=desc&per_page=\(pageSize)"
        let response: CheckResponse
        do {
            response = try github.get(path, etag: listETags[list])
        } catch {
            return .failed((error as? BoardError)?.message ?? "\(error)")
        }
        noteRate(response)
        switch response.status {
        case 304:
            return .unchanged
        case 200:
            listETags[list] = response.etag
            guard let rows = try? jsonArray(response.body) else {
                return .failed("the pull requests of \(list) are not a list")
            }
            var updated: [Int: Date] = [:]
            for row in rows {
                if let number = row["number"] as? Int, let text = row["updated_at"] as? String,
                    let when = try? date(text)
                {
                    updated[number] = when
                }
            }
            for repository in repositories {
                for (issue, pulls) in repository.watched {
                    for (index, pull) in pulls.enumerated() where pull.id.repository == list {
                        guard let when = updated[pull.id.number], when > pull.updatedAt else {
                            continue
                        }
                        repository.watched[issue]?[index].updatedAt = when
                        markDue(repository, "pull request \(list)#\(pull.id.number)", at: now)
                    }
                }
            }
            return .changed
        default:
            if let limit = githubLimit(response) { return .limited(limit) }
            return .failed("HTTP \(response.status) for \(path)")
        }
    }

    /// The check runs and statuses at each head a card in review was passed over
    /// for. A head with nothing unfinished makes its board's repository due, once,
    /// and is dropped, so the reconciliation that follows decides what is next.
    private func checkRunningChecks(_ repository: SupervisedRepository, at now: Date)
        -> CheckOutcome
    {
        var finished: [RunningChecks] = []
        for index in repository.runningChecks.indices {
            var watched = repository.runningChecks[index].answers
            if let failure = refresh(&watched) { return failure }
            repository.runningChecks[index].answers = watched
            do {
                if try watched.finished() {
                    finished.append(repository.runningChecks[index].checks)
                }
            } catch {
                return .failed((error as? BoardError)?.message ?? "\(error)")
            }
        }
        repository.runningChecks.removeAll { finished.contains($0.checks) }
        for checks in finished {
            let pull = checks.pullRequest
            markDue(repository, "checks finished \(pull.repository)#\(pull.number)", at: now)
        }
        return finished.isEmpty ? .unchanged : .changed
    }

    /// `main`'s check runs and statuses, while the repository is dormant on an
    /// orchestrator login. An answer that changes to nothing unfinished makes it
    /// due, so the repairs file a check that went red after the last board
    /// change. A first answer with nothing unfinished counts as a change: the
    /// reconciliation before it may have read `main` while it was still running.
    private func checkMain(_ repository: SupervisedRepository, at now: Date) -> CheckOutcome {
        guard watchesMain(repository) else { return .unchanged }
        let before = repository.mainChecks
        var watched = before
        if let failure = refresh(&watched) { return failure }
        repository.mainChecks = watched
        do {
            guard watched != before, try watched.finished() else { return .unchanged }
        } catch {
            return .failed((error as? BoardError)?.message ?? "\(error)")
        }
        markDue(repository, "main checks finished", at: now)
        return .changed
    }

    /// Both of a ref's check answers, each a conditional request, so an unchanged
    /// one is a `304` that costs no rate limit.
    private func refresh(_ watched: inout WatchedChecks) -> CheckOutcome? {
        for (path, answer) in [
            (watched.paths.checkRuns, \WatchedChecks.checkRuns),
            (watched.paths.status, \WatchedChecks.status),
        ] {
            let response: CheckResponse
            do {
                response = try github.get(path, etag: watched[keyPath: answer]?.etag)
            } catch {
                return .failed((error as? BoardError)?.message ?? "\(error)")
            }
            noteRate(response)
            switch response.status {
            case 304: break
            case 200: watched[keyPath: answer] = response
            default:
                if let limit = githubLimit(response) { return .limited(limit) }
                return .failed("HTTP \(response.status) for \(path)")
            }
        }
        return nil
    }

    /// A `403` or `429` that is the secondary limit, saying so or carrying
    /// `retry-after`, or an exhausted core limit with a reset still to come.
    private func githubLimit(_ response: CheckResponse) -> GitHubLimit? {
        guard response.status == 403 || response.status == 429 else { return nil }
        var limit = GitHubLimit()
        if let retry = response.headers["retry-after"] {
            limit.retryAfter = TimeInterval(retry.trimmed) ?? SupervisorTiming.secondaryPause
        } else if response.body.lowercased().contains("secondary rate limit") {
            limit.retryAfter = SupervisorTiming.secondaryPause
        }
        let rate = self.rate(response)
        if rate.remaining == 0, let reset = rate.reset, reset > clock.now {
            limit.coreReset = reset
        }
        return limit.retryAfter == nil && limit.coreReset == nil ? nil : limit
    }

    private func rate(_ response: CheckResponse) -> (remaining: Int?, reset: Date?) {
        (
            response.headers["x-ratelimit-remaining"].flatMap { Int($0.trimmed) },
            response.headers["x-ratelimit-reset"].flatMap { Double($0.trimmed) }.map {
                Date(timeIntervalSince1970: $0)
            }
        )
    }

    private func noteRate(_ response: CheckResponse) {
        let rate = self.rate(response)
        if let remaining = rate.remaining { rateRemaining = remaining }
        if let reset = rate.reset { rateReset = reset }
        if let limit = response.headers["x-ratelimit-limit"].flatMap({ Int($0.trimmed) }) {
            rateLimit = limit
        }
    }

    /// Checks once more and keeps the ETags, so the loop's own writes don't
    /// trigger a reconciliation each.
    /// Skipped during a GitHub pause; the first round after it reads the pages.
    private func rebaseline(_ repository: SupervisedRepository) {
        if let pausedUntil = githubPause?.until, clock.now < pausedUntil { return }
        switch checkPages(repository) {
        case .changed: discoverWatched(repository, everyCard: false)
        case .limited(let limit): pause(limit, at: clock.now)
        case .unchanged, .failed: break
        }
    }

    // MARK: Pull requests in the owner's review

    /// On an orchestrator login, resolves the pull requests of cards that entered
    /// the owner's review column or changed there, or of every such card when
    /// `everyCard`. Cards that left it drop theirs.
    private func discoverWatched(_ repository: SupervisedRepository, everyCard: Bool) {
        guard repository.orchestrator else { return }
        let column = repository.configuration.workflow.columns.ownerReview
        let reviewing = repository.cards.filter { $0.status == column }
        let numbers = Set(reviewing.map(\.number))
        for issue in repository.watched.keys where !numbers.contains(issue) {
            repository.watched[issue] = nil
        }
        for card in reviewing {
            let known = repository.resolved[card.number]
            guard everyCard || known != card.updatedAt else { continue }
            do {
                let json = try github.timeline(of: card.number, in: repository.name)
                repository.watched[card.number] = try watchedPullRequests(
                    issue: card.number, timelineJSON: json, home: repository.name,
                    agents: Set(repository.configuration.agents.map(\.login)),
                    owner: repository.configuration.owner
                ) { id in
                    let path = "repos/\(id.repository)/pulls/\(id.number)"
                    let response = try github.get(path, etag: nil)
                    noteRate(response)
                    guard response.status == 200 else {
                        throw BoardError("HTTP \(response.status) for \(path)")
                    }
                    return response.body
                }
                repository.resolved[card.number] = card.updatedAt
                if repository.watchFailed.removeValue(forKey: card.number) != nil {
                    emit([
                        "event": "watch-recovered", "repository": repository.name,
                        "issue": card.number,
                    ])
                }
            } catch {
                let message = (error as? BoardError)?.message ?? "\(error)"
                repository.watchFailed[card.number] = Failing(
                    since: repository.watchFailed[card.number]?.since ?? clock.now,
                    message: message)
                emit([
                    "event": "watch-failed", "repository": repository.name, "issue": card.number,
                    "message": message,
                ])
            }
        }
    }

    // MARK: Reconciliation

    /// Fetch, `update` and `next`, then what the answer asks.
    private func reconcile(_ repository: SupervisedRepository) throws {
        let now = clock.now
        let reasons = repository.dueReasons
        repository.dueSince = nil
        repository.dueReasons = []
        repository.lastReconciled = now
        reconciling = (repository, now, reasons)
        publishStatus(status(at: now))
        defer {
            reconciling = nil
            rebaseline(repository)
            if reasons.contains("interval") { discoverWatched(repository, everyCard: true) }
        }

        let answer: NextOutcome
        do {
            answer = try nextAnswer(repository)
        } catch let failure as ReconcileFailure {
            report(failure, for: repository, at: now)
            return
        }
        if let budget = answer.budget { graphQL = .init(budget: budget, reported: clock.now) }

        var event: [String: Any] = [
            "event": "reconcile", "repository": repository.name, "reasons": reasons,
            "kind": answer.kind, "revision": answer.revision,
        ]
        if !answer.merges.isEmpty { event["merges"] = answer.merges }
        emit(event)

        var gitState = ""
        let assignment = answer.assignment
        do {
            switch answer.kind {
            case "assignment":
                gitState = try issueGitState(assignment?.issue)
            case "idle":
                break
            default:
                throw ReconcileFailure(message: answer.message, retry: answer.retry)
            }
        } catch let failure as ReconcileFailure {
            report(failure, for: repository, at: now)
            return
        }
        succeeded(repository)
        repository.watch(answer.runningChecks)
        repository.waitsUnseen = answer.waitsUnseen

        if let assignment {
            let work = answer.work ?? ""
            let evidence = work + "\n" + gitState
            if progressed(repository, evidence) {
                try launch(.assignment(assignment), evidence, for: repository)
            } else {
                repository.parked = assignment
                emit([
                    "event": "parked", "repository": repository.name, "work": work,
                    "results": repository.results,
                    "note": "the same assignment came back twice with no progress; a person "
                        + "decides, for example by releasing the claim, then restarts",
                ])
            }
        } else if !answer.merges.isEmpty && answer.merges != repository.setAsideMerges {
            let evidence = "MERGE\n" + answer.merges.joined(separator: "\n")
            if progressed(repository, evidence) {
                repository.setAsideMerges = []
                try launch(
                    .merge(issues: answer.merges.compactMap(mergeIssue)), evidence,
                    for: repository)
            } else {
                repository.setAsideMerges = answer.merges
                repository.launchedEvidence = nil
                repository.noProgress = 0
                emit(["event": "set-aside", "repository": repository.name, "merges": answer.merges])
            }
        } else {
            repository.launchedEvidence = nil
            repository.noProgress = 0
            if answer.nextDelay == "now" { markDue(repository, "now", at: now) }
        }
    }

    /// Whether the work came back changed since the last child was launched for
    /// it. The same work with the same evidence, `noProgressLimit` children in a
    /// row, has not progressed.
    private func progressed(_ repository: SupervisedRepository, _ evidence: String) -> Bool {
        if repository.launchedEvidence == evidence {
            repository.noProgress += 1
        } else {
            repository.noProgress = 0
        }
        return repository.noProgress < ChildTiming.noProgressLimit
    }

    /// The issue's Git state in every path, workspaces fetched first. A
    /// repository is read as its last reconciliation fetched it.
    private func issueGitState(_ issue: Int?) throws -> String {
        guard let issue else { return "" }
        let workspaceStates = try workspaces.map { path -> String in
            let fetch = commands.run(["git", "fetch", "-q", "origin"], in: path)
            guard fetch.status == 0 else {
                throw ReconcileFailure(
                    message: "fetch of workspace \(path) failed: \(fetch.errors.trimmed)",
                    retry: true)
            }
            return "\(path)\n" + (try gitState(of: issue, in: path, commands: commands))
        }
        let repositoryStates = try repositories.map {
            "\($0.path)\n" + (try gitState(of: issue, in: $0.path, commands: commands))
        }
        return (repositoryStates + workspaceStates).joined(separator: "\n")
    }

    /// Ends what a failed reconciliation started. A backoff a failing check started
    /// stays until the checks pass.
    private func succeeded(_ repository: SupervisedRepository) {
        if repository.checkFailures == 0, repository.backoff != Backoff() {
            repository.backoff.clear()
            emit(["event": "backoff-cleared", "repository": repository.name])
        }
        if repository.reconcileFailure != nil {
            repository.reconcileFailure = nil
            emit(["event": "reconcile-recovered", "repository": repository.name])
        }
    }

    private func backOff(
        _ repository: SupervisedRepository, because reason: String, at now: Date
    ) {
        let wait = repository.backoff.engage(at: now, because: reason)
        markDue(repository, "retry", at: now)
        emit(["event": "backoff", "repository": repository.name, "seconds": Int(wait)])
    }

    /// Launches only once `claude auth status` says the child bills the
    /// subscription; anything else stops the supervisor.
    private func launch(
        _ purpose: SupervisorStatus.Purpose, _ evidence: String,
        for repository: SupervisedRepository
    ) throws {
        if let refusal = subscriptionRefusal(launcher.authStatus()) {
            throw SupervisorStop(reason: refusal)
        }
        let reason =
            switch purpose {
            case .assignment: "assignment"
            case .merge: "merge"
            }
        emit(["event": "launch", "repository": repository.name, "reason": reason])
        repository.launchedEvidence = evidence
        let request = ChildRequest(
            path: repository.path, repository: repository.name, reason: reason,
            thinkingSummaries: thinkingSummaries)
        child = RunningChild(
            repository: repository, process: try launcher.start(request), started: clock.now,
            purpose: purpose, evidence: evidence, thinkingSummaries: thinkingSummaries)
    }

    private func report(
        _ failure: ReconcileFailure, for repository: SupervisedRepository, at now: Date
    ) {
        repository.reconcileFailure = failure
        emit([
            "event": "error", "repository": repository.name, "message": failure.message,
            "retry": failure.retry,
        ])
        if failure.retry { backOff(repository, because: failure.message, at: now) }
    }

    /// Runs the installed tool in this process's place, with the same arguments.
    /// Nothing carries across: it starts as any supervisor does.
    private func replace(with new: RunningTool) throws {
        emit([
            "event": "replace", "from": tool?.revision ?? "", "to": new.revision, "tool": new.path,
        ])
        try replacer.replace(tool: new.path, arguments: ["loop"] + flags + paths)
        throw SupervisorStop(reason: "replaced by \(new.path)")
    }

    private struct NextOutcome {
        let kind: String
        let revision: String
        let nextDelay: String
        let merges: [String]
        let message: String
        let retry: Bool
        /// The assignment's work, for the no-progress rule.
        let work: String?
        let assignment: SupervisorStatus.Assignment?
        let budget: BudgetAnswer?
        /// What `checks-running` skips name, which the next rounds watch.
        let runningChecks: [RunningChecks]
        let waitsUnseen: Bool
    }

    // MARK: Status

    /// What the supervisor is doing at `now`, from its own state alone.
    func status(at now: Date) -> SupervisorStatus {
        SupervisorStatus(
            login: login, revision: tool?.revision, state: loginState(at: now),
            core: rateRemaining.flatMap { remaining in
                guard let rateLimit, let rateReset else { return nil }
                return .init(
                    remaining: remaining, limit: rateLimit, reset: rateReset,
                    limited: floorHolds(at: now))
            },
            graphQL: graphQL,
            child: child.map {
                .init(
                    repository: $0.repository.name, started: $0.started,
                    terminated: $0.terminated, purpose: $0.purpose)
            },
            repositories: repositories.map { status(of: $0, at: now) })
    }

    /// The later of a GitHub pause and a login pause, since nothing moves until both end.
    private func loginState(at now: Date) -> SupervisorStatus.LoginState {
        if let stopped { return .stopped(at: stopped.at, reason: stopped.reason) }
        var pauses: [(until: Date, cause: SupervisorStatus.PauseCause)] = []
        if let githubPause { pauses.append((githubPause.until, githubPause.cause)) }
        if let loginPause { pauses.append(loginPause) }
        if let pause = pauses.filter({ now < $0.until }).max(by: { $0.until < $1.until }) {
            return .paused(until: pause.until, cause: pause.cause)
        }
        if let replacement { return .replacing(revision: replacement.revision) }
        return .running
    }

    private func status(of repository: SupervisedRepository, at now: Date)
        -> SupervisorStatus.Repository
    {
        // A card that left review keeps its failure for the recovery report, but
        // nothing is being watched there any more.
        let reviewing = Set(
            repository.cards.filter {
                $0.status == repository.configuration.workflow.columns.ownerReview
            }.map(\.number))
        let watchFailures = repository.watchFailed.filter { reviewing.contains($0.key) }
            .sorted { $0.key < $1.key }.map(\.value)
        let failures = [repository.checkFailing].compactMap { $0 } + watchFailures
        let backingOff = repository.backoff.holds(at: now)

        let state: SupervisorStatus.State
        if let parked = repository.parked {
            state = .parked(parked)
        } else if repository.reconcileFailure?.retry == false {
            state = .needsFix
        } else if let stoppedBy, stoppedBy.repository === repository {
            state = .ended(outcome: stoppedBy.outcome, purpose: stoppedBy.purpose)
        } else if child?.repository === repository {
            state = .claude
        } else if let reconciling, reconciling.repository === repository {
            state = .reconciling(since: reconciling.since, reasons: reconciling.reasons)
        } else if backingOff, let until = repository.backoff.until {
            state = .backingOff(until: until)
        } else if !failures.isEmpty {
            state = .failing
        } else if repository.dueSince != nil {
            state = .due(waitingFor: hold(repository, at: now))
        } else {
            state = .idle
        }

        return SupervisorStatus.Repository(
            name: repository.name, state: state,
            error: repository.reconcileFailure?.message ?? failures.first?.message
                ?? (backingOff ? repository.backoff.reason : nil),
            checked: repository.lastChecked,
            failingSince: failures.map(\.since).min(),
            changed: repository.lastChanged,
            due: repository.dueSince.map { .init(since: $0, reasons: repository.dueReasons) },
            next: nextReconciliation(repository, at: now),
            setAsideMerges: repository.setAsideMerges.compactMap(mergeIssue))
    }

    /// What keeps a due repository from reconciling, as `step` decides it.
    private func hold(_ repository: SupervisedRepository, at now: Date) -> SupervisorStatus.Hold? {
        if let child { return .child(repository: child.repository.name) }
        let paused = [githubPause?.until, loginPause?.until].contains {
            $0.map { now < $0 } ?? false
        }
        if paused { return .pause }
        if floorHolds(at: now), repository.dueReasons.allSatisfy({ $0 == "interval" }) {
            return .coreFloor
        }
        return nil
    }

    /// While backing off, its end alone, since `nextDue` holds the repository until
    /// then. Otherwise the interval, or the orchestrator turn for the repository
    /// it would pick now, and after the reset while the floor holds an earlier time.
    private func nextReconciliation(_ repository: SupervisedRepository, at now: Date)
        -> SupervisorStatus.Next
    {
        if repository.backoff.holds(at: now), let until = repository.backoff.until {
            return .at(until)
        }
        guard needsInterval(repository) else { return .onChange }
        let time: Date
        if repository.orchestrator {
            guard orchestratorTurnRepository === repository else { return .inTurn }
            time = nextOrchestratorTurn
        } else {
            time =
                intervalTime(repository)
                ?? started.addingTimeInterval(SupervisorTiming.reconciliationInterval)
        }
        if floorHolds(at: now), let rateReset, time < rateReset { return .after(rateReset) }
        return .at(time)
    }

    private func nextAnswer(_ repository: SupervisedRepository) throws -> NextOutcome {
        let fetch = commands.run(["git", "fetch", "-q", "origin"], in: repository.path)
        guard fetch.status == 0 else {
            throw ReconcileFailure(message: "fetch failed: \(fetch.errors.trimmed)", retry: true)
        }
        let wrapper = tool?.path ?? installedToolPath(home: home)
        let update = commands.run(["sh", wrapper, "update"], in: repository.path)
        if update.status != 0 {
            emit([
                "event": "update-failed", "repository": repository.name,
                "message": update.errors.trimmed,
            ])
        }
        // HOME can carry a `//` that the wrapper's `pwd` normalises away.
        let new = installed()
        if let tool, let new,
            standardizedPath(new.path) != standardizedPath(tool.path)
                || new.revision != tool.revision
        {
            replacement = new
        }
        // `next` runs through `wrapper`, so the installed tool answers when that is
        // where `wrapper` points, even once `update` has put a new revision there.
        let answering =
            new.flatMap { standardizedPath($0.path) == standardizedPath(wrapper) ? $0 : nil }
            ?? tool
        let next = commands.run(["sh", wrapper, "next"], in: repository.path)
        guard
            let object = try? JSONSerialization.jsonObject(with: Data(next.output.utf8))
                as? [String: Any]
        else {
            throw ReconcileFailure(
                message: "next answered no JSON: \(next.errors.trimmed)", retry: true)
        }
        guard object["schema"] as? Int == answerSchema else {
            throw ReconcileFailure(
                message: "next answered schema \(object["schema"] ?? "none"), which this "
                    + "supervisor doesn't read", retry: false)
        }
        let repairs = object["repairs"] as? [String] ?? []
        let merges = repairs.filter { $0.hasPrefix("MERGE ") }
        let kind = object["kind"] as? String ?? ""
        return NextOutcome(
            kind: kind,
            revision: answering?.revision ?? "",
            nextDelay: object["nextDelay"] as? String ?? "",
            merges: merges,
            message: object["message"] as? String ?? "",
            retry: object["retry"] as? Bool ?? false,
            work: assignmentWork(object),
            assignment: kind == "assignment" ? assignmentSummary(object) : nil,
            budget: budgetAnswer(object["budget"]),
            runningChecks: runningChecks(skipped: object["skipped"]),
            // A merge left alone waits on the pull request, not the board.
            waitsUnseen: !merges.isEmpty || waitsUnseen(skipped: object["skipped"]))
    }
}

extension SupervisedRepository {
    /// Watches exactly these heads, keeping the answers of those already watched.
    func watch(_ heads: [RunningChecks]) {
        runningChecks = heads.map { head in
            runningChecks.first { $0.checks == head } ?? (head, WatchedChecks(head))
        }
    }

    func watches(_ list: String) -> Bool {
        watched.values.contains { $0.contains { $0.id.repository == list } }
    }

    func store(page index: Int, url: String, etag: String?, cards: [BoardCard]) {
        if index < pageURLs.count {
            pageURLs[index] = url
            etags[index] = etag
            pageCards[index] = cards
        } else {
            pageURLs.append(url)
            etags.append(etag)
            pageCards.append(cards)
        }
    }

    func truncate(after index: Int) {
        pageURLs.removeSubrange((index + 1)...)
        etags.removeSubrange((index + 1)...)
        pageCards.removeSubrange((index + 1)...)
    }
}

// MARK: Parsing

/// `repository`'s cards on one REST page of project items: issue number, Status
/// and the item's `updated_at`. Another repository's cards on a shared board are
/// left out, since their numbers mean other issues.
func boardCards(itemsJSON json: String, statusFieldID: Int, repository: String) throws
    -> [BoardCard]
{
    try jsonArray(json).compactMap { item in
        guard let content = item["content"] as? [String: Any],
            let number = content["number"] as? Int,
            let updated = item["updated_at"] as? String
        else { return nil }
        guard let cardRepository = itemRepository(content) else {
            throw BoardError("the board's card for #\(number) names no repository")
        }
        guard sameRepository(cardRepository, repository) else { return nil }
        let fields = item["fields"] as? [[String: Any]] ?? []
        let status = fields.first { $0["id"] as? Int == statusFieldID }
        let name = (status?["value"] as? [String: Any])?["name"] as? [String: Any]
        return BoardCard(number: number, status: name?["raw"] as? String ?? "", updatedAt: updated)
    }
}

/// The `owner/name` a REST project item's content belongs to. An issue carries
/// `repository_url`; a pull request carries none, and names its repository
/// under `base.repo`.
private func itemRepository(_ content: [String: Any]) -> String? {
    if let url = content["repository_url"] as? String {
        let name = url.components(separatedBy: "/repos/").last
        return name == url ? nil : name
    }
    let base = content["base"] as? [String: Any]
    return (base?["repo"] as? [String: Any])?["full_name"] as? String
}

/// The heads `next`'s `checks-running` skips name. A skip whose detail isn't a list
/// of them, as from a revision that named none, is left to the interval.
func runningChecks(skipped: Any?) -> [RunningChecks] {
    let skips = skipped as? [[String: Any]] ?? []
    return skips.flatMap { skip -> [RunningChecks] in
        guard skip["reason"] as? String == SkipReason.checksRunning.rawValue,
            let detail = skip["detail"] as? String
        else { return [] }
        return RunningChecks.list(detail) ?? []
    }
}

/// Skips whose card can't become takeable without its board changing: an epic is
/// never taken, and the rest end in a card move or a review that moves it.
private let announcedSkips: Set<String> = Set(
    [SkipReason.epic, .openedByThisAgent, .openedByAnotherAgent, .moved, .merging].map(
        \.rawValue))

/// Whether any skip can end while the board stays as it is: a claim going stale,
/// a blocker on another board closing, checks finishing, a stack's parent
/// settling, or a reason this supervisor doesn't know.
func waitsUnseen(skipped: Any?) -> Bool {
    let skips = skipped as? [[String: Any]] ?? []
    return skips.contains { !announcedSkips.contains($0["reason"] as? String ?? "") }
}

/// The `rel="next"` url in a `Link` header, as a path `gh api` takes.
func nextLink(_ header: String?) -> String? {
    guard let header else { return nil }
    for part in header.split(separator: ",") where part.contains("rel=\"next\"") {
        guard let open = part.firstIndex(of: "<"), let close = part.firstIndex(of: ">") else {
            continue
        }
        var url = String(part[part.index(after: open)..<close])
        if let range = url.range(of: "://") {
            let rest = url[range.upperBound...]
            url = rest.firstIndex(of: "/").map { String(rest[rest.index(after: $0)...]) } ?? url
        }
        return url
    }
    return nil
}

/// The open pull requests the repairs' resolver finds for an issue, each with
/// the `updated_at` the same timeline carries as its baseline. One only a `PR:`
/// line records is read with `fetch`, which answers its REST body.
func watchedPullRequests(
    issue: Int, timelineJSON json: String, home: String, agents: Set<String>, owner: String,
    fetch: (PullRequestID) throws -> String
) throws
    -> [WatchedPullRequest]
{
    var updated: [PullRequestID: Date] = [:]
    for event in try jsonArray(json) where event["event"] as? String == "cross-referenced" {
        guard let source = (event["source"] as? [String: Any])?["issue"] as? [String: Any],
            let number = source["number"] as? Int,
            let repository = (source["repository"] as? [String: Any])?["full_name"] as? String,
            let text = source["updated_at"] as? String
        else { continue }
        updated[PullRequestID(repository: repository, number: number)] = try date(text)
    }
    let referenced = try linkedPullRequests(
        issue: issue, timelineJSON: json, home: home, agents: agents)
    let known = Set(referenced.map(\.id))
    var watched = referenced.filter(\.open).compactMap { pull in
        updated[pull.id].map { WatchedPullRequest(id: pull.id, updatedAt: $0) }
    }
    let recorded = try recordedPullRequests(
        timelineJSON: json, home: home, authors: agents.union([owner]))
    for id in recorded where !known.contains(id) {
        guard
            let read = try pullRequestLink(
                issue: issue, pullJSON: fetch(id), home: home, agents: agents),
            read.link.open
        else { continue }
        watched.append(WatchedPullRequest(id: read.link.id, updatedAt: read.updatedAt))
    }
    return watched
}

/// A `gh api -i` answer: status line, headers, then the body. `gh` exits non-zero
/// on a `304` but still writes it, so the status line is what is read.
func checkResponse(includedOutput output: String) -> CheckResponse? {
    let normalized = output.replacingOccurrences(of: "\r\n", with: "\n")
    let sections = normalized.components(separatedBy: "\n\n")
    guard let head = sections.first else { return nil }
    let lines = head.split(separator: "\n").map(String.init)
    guard let statusLine = lines.first, statusLine.hasPrefix("HTTP/") else { return nil }
    let parts = statusLine.split(separator: " ")
    guard parts.count >= 2, let status = Int(parts[1]) else { return nil }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
        guard let colon = line.firstIndex(of: ":") else { continue }
        headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmed
    }
    return CheckResponse(
        status: status, headers: headers, body: sections.dropFirst().joined(separator: "\n\n"))
}

extension StringProtocol {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// A path with `//`, `.` and `..` resolved as text, without following symlinks.
func standardizedPath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
}
