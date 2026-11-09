// `tickwork loop`: when it checks, when it reconciles, and what it does with
// `next`'s answer, over fakes for GitHub, commands, the clock and the child.
//

import Foundation
import Testing

@testable import BoardCore

// MARK: Fakes

final class FakeClock: SupervisorClock {
    var now = ISO8601DateFormatter().date(from: "2026-11-01T12:00:00Z")!
    func sleep(until date: Date) { if date > now { now = date } }
}

/// Boards and pull-request lists that answer `304` until a test changes them.
final class FakeSupervisorGitHub: SupervisorGitHub {
    struct Project {
        /// The repository every card here belongs to.
        let repository: String
        var pages: [[BoardCard]]
        var version = 0
    }

    struct PullList {
        var rows: [(number: Int, updatedAt: String)]
        var version = 0
    }

    var projects: [String: Project] = [:]
    var lists: [String: PullList] = [:]
    var timelines: [Int: String] = [:]
    /// Check runs and statuses by `owner/name@sha`, each answering `304` until changed.
    var commits: [String: (checkRuns: String, status: String, version: Int)] = [:]
    /// Answers every `GET` with this instead, while set, for `overrideCount` requests
    /// when that is set.
    var override: CheckResponse?
    var overrideCount: Int?
    var failing: Set<String> = []
    var rateRemaining = 4_000
    var rateReset = ISO8601DateFormatter().date(from: "2026-11-01T13:00:00Z")!
    private(set) var requests: [String] = []
    private(set) var timelineReads: [Int] = []

    static let fieldID = 7

    func itemsPath(_ number: Int) -> String { "orgs/example-org/projectsV2/\(number)/items" }

    func get(_ path: String, etag: String?) throws -> CheckResponse {
        requests.append(path)
        if let override, overrideCount.map({ $0 > 0 }) ?? true {
            overrideCount = overrideCount.map { $0 - 1 }
            return override
        }
        if failing.contains(where: path.contains) { throw BoardError("connection reset") }
        var headers = [
            "x-ratelimit-remaining": String(rateRemaining),
            "x-ratelimit-limit": "5000",
            "x-ratelimit-reset": String(Int(rateReset.timeIntervalSince1970)),
        ]
        if let base = projects.keys.first(where: { path.hasPrefix($0 + "?") }) {
            let project = projects[base]!
            let page = path.range(of: "&after=p").map { Int(path[$0.upperBound...])! } ?? 0
            let tag = "\"v\(project.version)p\(page)\""
            headers["etag"] = tag
            if etag == tag { return CheckResponse(status: 304, headers: headers, body: "") }
            if page + 1 < project.pages.count {
                headers["link"] =
                    "<https://api.github.com/\(base)?per_page=100&fields=7&after=p\(page + 1)>; rel=\"next\""
            }
            return CheckResponse(
                status: 200, headers: headers,
                body: itemsJSON(project.pages[page], in: project.repository))
        }
        if let repository = lists.keys.first(where: { path.hasPrefix("repos/\($0)/pulls") }) {
            let list = lists[repository]!
            let tag = "\"l\(list.version)\""
            headers["etag"] = tag
            if etag == tag { return CheckResponse(status: 304, headers: headers, body: "") }
            let rows = list.rows.map {
                "{\"number\":\($0.number),\"updated_at\":\"\($0.updatedAt)\"}"
            }
            return CheckResponse(
                status: 200, headers: headers, body: "[\(rows.joined(separator: ","))]")
        }
        if let key = commits.keys.first(where: { key in
            let parts = key.split(separator: "@")
            return path.hasPrefix("repos/\(parts[0])/commits/\(parts[1])/")
        }) {
            let commit = commits[key]!
            let statusRead = !path.contains("/check-runs")
            let tag = "\"\(statusRead ? "s" : "r")\(commit.version)\""
            headers["etag"] = tag
            if etag == tag { return CheckResponse(status: 304, headers: headers, body: "") }
            return CheckResponse(
                status: 200, headers: headers, body: statusRead ? commit.status : commit.checkRuns)
        }
        if path.contains("/commits/main/") {
            // A `main` no test arranged: no checks, never changing.
            headers["etag"] = "\"m\""
            if etag == "\"m\"" { return CheckResponse(status: 304, headers: headers, body: "") }
            let body =
                path.contains("/check-runs")
                ? #"{"check_runs":[]}"# : #"{"total_count":0,"statuses":[]}"#
            return CheckResponse(status: 200, headers: headers, body: body)
        }
        return CheckResponse(status: 404, headers: headers, body: "")
    }

    func viewer() throws -> String { "agent-one" }

    func project(owner: String, number: Int) throws -> (itemsPath: String, statusFieldID: Int) {
        (itemsPath(number), Self.fieldID)
    }

    func timeline(of issue: Int, in repository: String) throws -> String {
        timelineReads.append(issue)
        return timelines[issue] ?? "[]"
    }

    func change(_ number: Int, _ edit: (inout [[BoardCard]]) -> Void) {
        let base = itemsPath(number)
        edit(&projects[base]!.pages)
        projects[base]!.version += 1
    }

    private func itemsJSON(_ cards: [BoardCard], in repository: String) -> String {
        let items = cards.map { card in
            """
            {"content":{"number":\(card.number),\
            "repository_url":"https://api.github.com/repos/\(repository)"},"updated_at":"\(card.updatedAt)",\
            "fields":[{"id":\(Self.fieldID),"value":{"name":{"raw":"\(card.status)"}}}]}
            """
        }
        return "[\(items.joined(separator: ","))]"
    }
}

/// Clones, the tool's `update` and `next`, answered from what a test arranges.
final class FakeCommands: CommandRunning {
    /// `loop.json` on `origin/main` by path; a path without one is a workspace.
    var loops: [String: String] = [:]
    var notClones: Set<String> = []
    /// Clones whose `git fetch` fails after start.
    var failingFetches: Set<String> = []
    /// `next`'s answers by path, in order; `idle`, `backoff` once they run out.
    var answers: [String: [String]] = [:]
    /// The wrapper the supervisor runs its verbs through.
    var wrapper = SupervisorWorld.installedPath
    /// Whether `update` fails, as it does with no clone or a broken `main`.
    var failingUpdate = false
    private(set) var updateCalls: [String] = []
    /// Git state by path: `f/<issue>-…` refs, the branch `HEAD` is on, and the diff.
    var refs: [String: String] = [:]
    var heads: [String: String] = [:]
    var diffs: [String: String] = [:]
    /// Paths whose Git state can't be digested.
    var undigestable: Set<String> = []
    private(set) var nextCalls: [String] = []
    /// Runs as each `next` is called, so a test can let it take time.
    var onNext: () -> Void = {}

    func sha256(ofOutput arguments: [String], in directory: String) throws -> String {
        if undigestable.contains(directory) { throw BoardError("no SHA-256 command") }
        return "sha256(\(run(arguments, in: directory).output))"
    }

    /// Idle with a card blocked, perhaps by an issue on another board, so the
    /// repository keeps its interval.
    static let idle =
        #"{"schema":1,"kind":"idle","nextDelay":"backoff","repairs":[],"skipped":[{"issue":1,"#
        + ##""reason":"blocked","detail":"#9 open"}]}"##
    /// Idle with nothing passed over: no interval comes round for it.
    static let dormant = #"{"schema":1,"kind":"idle","nextDelay":"backoff","repairs":[]}"#

    func run(_ arguments: [String], in directory: String) -> CommandResult {
        func answer(_ status: Int32, _ output: String = "", _ errors: String = "") -> CommandResult
        {
            CommandResult(status: status, output: output, errors: errors)
        }
        switch arguments.prefix(2) {
        case ["git", "fetch"]:
            return notClones.union(failingFetches).contains(directory)
                ? answer(128, "", "not a git repository") : answer(0)
        case ["git", "cat-file"]:
            let hasLoop = loops[directory] != nil && arguments.last == "origin/main:loop.json"
            return answer(hasLoop ? 0 : 1)
        case ["git", "show"]:
            return answer(0, loops[directory] ?? "")
        case ["git", "for-each-ref"]:
            return answer(0, refs[directory] ?? "")
        case ["git", "symbolic-ref"]:
            return answer(0, (heads[directory] ?? "main") + "\n")
        case ["git", "diff"]:
            return answer(0, diffs[directory] ?? "")
        case ["git", "ls-files"], ["git", "hash-object"]:
            return answer(0)
        case ["sh", wrapper] where arguments.last == "update":
            updateCalls.append(directory)
            return failingUpdate
                ? answer(1, "", "tickwork: fetching Tickwork failed") : answer(0)
        default:
            #expect(arguments == ["sh", wrapper, "next"])
            nextCalls.append(directory)
            onNext()
            let queued = answers[directory] ?? []
            guard let first = queued.first else { return answer(0, Self.idle) }
            answers[directory] = Array(queued.dropFirst())
            return answer(0, first)
        }
    }
}

/// A child that exits when its time is up, writing the lines it was given, or
/// on SIGKILL, or on SIGTERM unless it ignores it.
final class FakeChild: ChildProcess {
    let clock: FakeClock
    var exitAt: Date?
    let lines: [String]
    let status: Int32
    let firstError: String?
    var ignoresTerm = false
    private(set) var signals: [Int32] = []
    private var signaled = false

    init(clock: FakeClock, exitAt: Date?, lines: [String], status: Int32, firstError: String?) {
        self.clock = clock
        self.exitAt = exitAt
        self.lines = lines
        self.status = status
        self.firstError = firstError
    }

    var exit: ChildExit? {
        guard let exitAt, clock.now >= exitAt else { return nil }
        return signaled
            ? ChildExit(
                status: signals.last ?? 0, signaled: true, lines: lines, firstError: firstError)
            : ChildExit(status: status, signaled: false, lines: lines, firstError: firstError)
    }

    func signal(_ signal: Int32) {
        signals.append(signal)
        guard exit == nil, signal == SIGKILL || !ignoresTerm else { return }
        signaled = true
        exitAt = clock.now
    }
}

final class FakeLauncher: ChildLaunching {
    static let done =
        #"{"type":"result","subtype":"success","is_error":false,"num_turns":3,"duration_ms":1000,"total_cost_usd":0.5,"usage":{"input_tokens":10},"modelUsage":{}}"#
    static let subscription = CommandResult(
        status: 0,
        output: #"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty"}"#,
        errors: "")

    let clock: FakeClock
    /// `nil` runs a child until it is signalled.
    var duration: TimeInterval? = 120
    /// Each child's stream and exit status, in launch order; `done` and 0 after.
    var endings: [(lines: [String], status: Int32)] = []
    /// Each child's first stderr line, in launch order; none after.
    var firstErrors: [String?] = []
    var auth = subscription
    var ignoresTerm = false
    private(set) var started: [ChildRequest] = []
    private(set) var children: [FakeChild] = []
    private(set) var authChecks = 0
    /// Told the launch's index, so a test can change the world as a child would.
    var onStart: ((Int) -> Void)?
    init(clock: FakeClock) { self.clock = clock }

    func authStatus() -> CommandResult {
        authChecks += 1
        return auth
    }

    func start(_ request: ChildRequest) throws -> ChildProcess {
        started.append(request)
        let ending: (lines: [String], status: Int32) =
            endings.isEmpty ? ([Self.done], 0) : endings.removeFirst()
        let child = FakeChild(
            clock: clock, exitAt: duration.map { clock.now.addingTimeInterval($0) },
            lines: ending.lines, status: ending.status,
            firstError: firstErrors.isEmpty ? nil : firstErrors.removeFirst())
        child.ignoresTerm = ignoresTerm
        children.append(child)
        onStart?(children.count - 1)
        return child
    }
}

/// Records the replacement it was asked for, where the real one would `exec`.
final class FakeReplacer: ToolReplacing {
    private(set) var requests: [(tool: String, arguments: [String])] = []
    func replace(tool: String, arguments: [String]) throws {
        requests.append((tool, arguments))
    }
}

// MARK: The world

final class SupervisorWorld {
    let clock = FakeClock()
    let github = FakeSupervisorGitHub()
    let commands = FakeCommands()
    let replacer = FakeReplacer()
    lazy var launcher = FakeLauncher(clock: clock)
    private(set) var events: [[String: Any]] = []
    private(set) var statuses: [SupervisorStatus] = []
    static let installedPath = "/home/agent/.cache/tickwork/tool/bin/tickwork"
    /// What the supervisor runs as, and what `tool/` holds after each update. Set
    /// before the supervisor is first used.
    var tool: RunningTool? = RunningTool(path: installedPath, revision: "abc-revision")
    var installed: RunningTool? = RunningTool(path: installedPath, revision: "abc-revision")
    lazy var supervisor: Supervisor = {
        commands.wrapper = tool?.path ?? Self.installedPath
        return Supervisor(
            github: github, commands: commands, clock: clock, launcher: launcher,
            home: "/home/agent", tool: tool, installed: { [unowned self] in installed },
            replacer: replacer, emit: { [unowned self] in self.events.append($0) },
            status: { [unowned self] in self.statuses.append($0) }, flags: flags,
            interrupted: { [unowned self] in
                signalAt.flatMap { self.clock.now >= $0 ? SIGTERM : nil }
            })
    }()
    /// When the supervisor receives SIGTERM.
    var signalAt: Date?
    var flags: [String] = []

    static let start = ISO8601DateFormatter().date(from: "2026-11-01T12:00:00Z")!

    /// A repository at `/work/<name>` whose board is project `number`.
    func repository(
        _ name: String, number: Int, roles: [String] = ["engineer"],
        pages: [[BoardCard]] = [[BoardCard(number: 1, status: "Ready", updatedAt: "t0")]]
    ) {
        let roleList = roles.map { "\"\($0)\"" }.joined(separator: ",")
        commands.loops["/work/\(name)"] = """
            {"repository":"example-org/\(name)","project":{"owner":"example-org","number":\(number)},
             "owner":"example-owner","agents":[{"login":"agent-one","roles":[\(roleList)]}]}
            """
        github.projects[github.itemsPath(number)] = .init(
            repository: "example-org/\(name)", pages: pages)
    }

    func start(_ names: [String]) throws {
        try supervisor.start(paths: names.map { "/work/\($0)" })
    }

    /// Runs the supervisor for this long on the fake clock.
    func run(for seconds: TimeInterval) {
        supervisor.run(until: clock.now.addingTimeInterval(seconds))
    }

    func events(_ name: String) -> [[String: Any]] {
        events.filter { $0["event"] as? String == name }
    }

    /// The reasons each reconciliation of `repository` gave, in order.
    func reasons(_ repository: String) -> [[String]] {
        events("reconcile").filter { $0["repository"] as? String == "example-org/\(repository)" }
            .map { $0["reasons"] as? [String] ?? [] }
    }

    func stopReason(_ body: () throws -> Void) -> String? {
        do {
            try body()
            return nil
        } catch let stop as SupervisorStop {
            return stop.reason
        } catch {
            return "\(error)"
        }
    }
}

/// An assignment as `next` answers it. A different `head` or `findings` is
/// different evidence for the no-progress rule.
func assignment(
    _ issue: Int, head: String = "c0", findings: [String] = [], checks: String = "green",
    mergeable: String = "true"
) -> String {
    let token = "tw1~agent-one~example-org/a~\(issue)~engineer~start~Ready~2026-11-01T12:00:00Z"
    let found = findings.map { "{\"kind\":\"owner-feedback\",\"url\":\"\($0)\"}" }
        .joined(separator: ",")
    return """
        {"schema":1,"kind":"assignment","resumed":false,"issue":{"number":\(issue)},\
        "role":"engineer","task":"start","token":"\(token)",\
        "pullRequest":{"branch":"f/\(issue)-x","checks":"\(checks)","head":"\(head)",\
        "mergeable":\(mergeable),"ref":"example-org/a#9"},"findings":[\(found)],"repairs":[]}
        """
}

// MARK: Tests

@Suite("tickwork loop: detection and reconciliation")
struct SupervisorTests {

    // MARK: Paths

    @Test("Repositories and workspaces are told apart, and the start event lists both")
    func classifiesPaths() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        try world.supervisor.start(paths: ["/work/a", "/work/tools"])
        #expect(world.supervisor.repositories.map(\.path) == ["/work/a"])
        #expect(world.supervisor.workspaces == ["/work/tools"])
        let start = try #require(world.events("start").first)
        #expect(start["repositories"] as? [String] == ["/work/a"])
        #expect(start["workspaces"] as? [String] == ["/work/tools"])
        #expect((start["note"] as? String)?.contains("one session per login") == true)
    }

    @Test("A workspace may come first, since no path's revision runs the supervisor")
    func workspaceFirst() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        try world.supervisor.start(paths: ["/work/tools", "/work/a"])
        #expect(world.supervisor.workspaces == ["/work/tools"])
        #expect(world.supervisor.repositories.map(\.path) == ["/work/a"])
    }

    @Test("A relative path or a path that isn't a clone refuses to start")
    func refusesBadPaths() {
        let relative = SupervisorWorld()
        relative.repository("a", number: 1)
        #expect(
            relative.stopReason { try relative.supervisor.start(paths: ["work/a"]) }?
                .contains("not an absolute path") == true)

        let notClone = SupervisorWorld()
        notClone.repository("a", number: 1)
        notClone.commands.notClones = ["/work/elsewhere"]
        #expect(
            notClone.stopReason {
                try notClone.supervisor.start(paths: ["/work/a", "/work/elsewhere"])
            }?.contains("not a clone") == true)
    }

    @Test("More than 15 board pages across every path refuses to start")
    func refusesTooManyPages() {
        let world = SupervisorWorld()
        let page = [BoardCard(number: 1, status: "Ready", updatedAt: "t0")]
        world.repository("a", number: 1, pages: Array(repeating: page, count: 8))
        world.repository("b", number: 2, pages: Array(repeating: page, count: 8))
        #expect(world.stopReason { try world.start(["a", "b"]) }?.contains("16 pages") == true)
    }

    // MARK: Triggers

    @Test("Start reconciles every repository, and an unchanged board then triggers nothing")
    func unchangedBoardIsQuiet() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        try world.start(["a"])
        world.run(for: 9 * 60)
        #expect(world.reasons("a") == [["start"]])
        #expect(world.commands.nextCalls == ["/work/a"])
    }

    @Test("A replacement keeps the loop's flags")
    func replacementKeepsFlags() throws {
        let world = SupervisorWorld()
        world.flags = ["--json"]
        world.repository("a", number: 1)
        world.installed = RunningTool(path: SupervisorWorld.installedPath, revision: "def")
        try world.start(["a"])
        world.run(for: 1)
        #expect(world.replacer.requests.first?.arguments == ["loop", "--json", "/work/a"])
    }

    @Test("A changed board page triggers a reconciliation within a round")
    func changedPageTriggers() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        try world.start(["a"])
        world.run(for: 20)
        world.github.change(1) { $0[0][0] = BoardCard(number: 1, status: "Ready", updatedAt: "t1") }
        world.run(for: 20)
        #expect(world.reasons("a") == [["start"], ["board changed"]])
    }

    @Test("A page count change triggers a reconciliation")
    func pageCountTriggers() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        try world.start(["a"])
        world.run(for: 20)
        world.github.change(1) {
            $0.append([BoardCard(number: 2, status: "Ready", updatedAt: "t1")])
        }
        world.run(for: 20)
        #expect(world.reasons("a").last == ["board changed"])
        #expect(world.supervisor.repositories[0].pageURLs.count == 2)
    }

    @Test("A failed check triggers a reconciliation, and failing again backs off")
    func failedCheckTriggers() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        try world.start(["a"])
        world.run(for: 20)
        world.github.failing = ["projectsV2/1"]
        world.run(for: 16)
        #expect(world.reasons("a").last == ["check failed"])
        world.run(for: 15)
        #expect(world.events("backoff").count == 1)
    }

    @Test("Checks passing again after a failure report the recovery once")
    func checkRecovery() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        try world.start(["a"])
        world.run(for: 20)
        world.github.failing = ["projectsV2/1"]
        world.run(for: 31)
        #expect(world.events("check-recovered").isEmpty)
        world.github.failing = []
        world.run(for: 60)
        #expect(world.events("check-recovered").count == 1)
    }

    @Test("nextDelay now makes the repository due again at once")
    func nextDelayNow() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        world.commands.answers["/work/a"] = [
            ##"{"schema":1,"kind":"idle","nextDelay":"now","repairs":["#4 -> Ready"]}"##
        ]
        try world.start(["a"])
        world.run(for: 5)
        #expect(world.reasons("a") == [["start"], ["now"]])
    }

    @Test("A child's exit makes its repository due")
    func childExitTriggers() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        world.commands.answers["/work/a"] = [assignment(1)]
        try world.start(["a"])
        world.run(for: 200)
        #expect(
            world.launcher.started == [
                ChildRequest(
                    path: "/work/a", repository: "example-org/a", reason: "assignment",
                    thinkingSummaries: true)
            ])
        #expect(world.reasons("a") == [["start"], ["child exited"]])
    }

    @Test("The round length keeps checks within 30 a minute")
    func roundLength() {
        #expect(SupervisorTiming.roundLength(requests: 4) == 15)
        #expect(SupervisorTiming.roundLength(requests: 7) == 15)
        #expect(SupervisorTiming.roundLength(requests: 15) == 30)
        #expect(SupervisorTiming.roundLength(requests: 17) == 34)
    }

    @Test("Rounds come at the budget's pace for the pages being checked")
    func roundPace() throws {
        let world = SupervisorWorld()
        let page = [BoardCard(number: 1, status: "Ready", updatedAt: "t0")]
        world.repository("a", number: 1, pages: Array(repeating: page, count: 10))
        try world.start(["a"])
        let before = world.github.requests.count
        world.run(for: 60)
        // Ten requests a round makes a 20-second round: three rounds a minute.
        #expect(world.github.requests.count - before == 30)
    }

    // MARK: Intervals

    @Test("Orchestrator repositories share one interval turn, the one reconciled longest ago first")
    func orchestratorTurns() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1, roles: ["orchestrator", "engineer"])
        world.repository("b", number: 2, roles: ["orchestrator", "engineer"])
        try world.start(["a", "b"])
        world.run(for: 20 * 60 + 1)
        let turns = world.events("reconcile").filter {
            ($0["reasons"] as? [String]) == ["interval"]
        }.map { $0["repository"] as? String ?? "" }
        #expect(turns == ["example-org/a", "example-org/b", "example-org/a", "example-org/b"])
    }

    @Test("Checks a review was passed over for wake its repository once, when they finish")
    func finishedChecksWakeReview() throws {
        let world = SupervisorWorld()
        let names = ["a", "b", "c", "d", "e"]
        for (index, name) in names.enumerated() {
            world.repository(name, number: index + 1, roles: ["orchestrator", "reviewer"])
        }
        func checkRuns(_ status: String) -> String {
            #"{"check_runs":[{"id":1,"name":"Required","status":"\#(status)","conclusion":null}]}"#
        }
        let noStatuses = #"{"total_count":0,"statuses":[]}"#
        world.github.commits["example-org/tools@c9"] = (checkRuns("in_progress"), noStatuses, 0)
        world.commands.answers["/work/e"] = [
            #"{"schema":1,"kind":"idle","nextDelay":"backoff","repairs":[],"skipped":[{"issue":5,"#
                + #""reason":"checks-running","detail":"example-org/tools#9@c9"}]}"#
        ]
        try world.start(names)
        world.run(for: 60)
        #expect(world.reasons("e") == [["start"]])

        world.github.commits["example-org/tools@c9"] = (
            #"{"check_runs":[{"id":1,"name":"Required","status":"completed","conclusion":"success"}]}"#,
            noStatuses, 1
        )
        world.run(for: 15)
        #expect(world.reasons("e") == [["start"], ["checks finished example-org/tools#9"]])
        #expect(world.supervisor.repositories[4].runningChecks.isEmpty)
        let reads = world.github.requests.filter { $0.contains("/commits/") }.count
        world.run(for: 120)
        #expect(world.reasons("e").count == 2)
        #expect(world.github.requests.filter { $0.contains("/commits/") }.count == reads)
    }

    @Test("A repository without orchestrator reconciles every ten minutes on its own clock")
    func plainInterval() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        try world.start(["a"])
        world.run(for: 30 * 60 + 1)
        #expect(world.reasons("a") == [["start"], ["interval"], ["interval"], ["interval"]])
    }

    @Test("Below the rate floor, interval reconciliations wait for the reset; triggered ones don't")
    func rateFloor() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        world.github.rateRemaining = 900
        try world.start(["a"])
        world.run(for: 11 * 60)
        #expect(world.reasons("a") == [["start"]])
        world.github.change(1) { $0[0][0] = BoardCard(number: 1, status: "Ready", updatedAt: "t1") }
        world.run(for: 20)
        #expect(world.reasons("a").last == ["board changed"])
        world.clock.now = world.github.rateReset
        world.run(for: 20)
        #expect(world.reasons("a").last == ["interval"])
    }

    // MARK: Dormant repositories

    @Test("An idle repository with nothing passed over takes no interval, and a change wakes it")
    func dormantRepository() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        world.commands.answers["/work/a"] = [FakeCommands.dormant]
        try world.start(["a"])
        world.run(for: 2 * 60 * 60)
        #expect(world.reasons("a") == [["start"]])
        #expect(try world.status(of: "a").next == .onChange)
        // Without orchestrator its `next` files nothing, so `main` isn't read.
        #expect(!world.github.requests.contains { $0.contains("/commits/main/") })

        world.github.change(1) { $0[0][0] = BoardCard(number: 1, status: "Ready", updatedAt: "t1") }
        world.run(for: 20)
        #expect(world.reasons("a") == [["start"], ["board changed"]])
        // That answer passed a card over as blocked, so the interval is back.
        world.run(for: 10 * 60)
        #expect(world.reasons("a").last == ["interval"])
    }

    @Test(
        "Skips the board announces the end of leave a repository dormant; any other keeps it",
        arguments: [
            ("epic", false), ("opened-by-this-agent", false), ("opened-by-another-agent", false),
            ("moved", false), ("merging", false), ("claimed", true), ("blocked", true),
            ("checks-running", true), ("not-stackable", true), ("a-later-reason", true),
        ])
    func skipsThatWaitUnseen(reason: String, waits: Bool) {
        #expect(waitsUnseen(skipped: [["issue": 1, "reason": reason]]) == waits)
        #expect(!waitsUnseen(skipped: nil))
    }

    @Test("A dormant orchestrator repository gives its turns to one the repairs still follow")
    func dormantOrchestratorTurns() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1, roles: ["orchestrator", "engineer"])
        world.repository(
            "b", number: 2, roles: ["orchestrator", "engineer"],
            pages: [[BoardCard(number: 3, status: "Agent Review", updatedAt: "t0")]])
        world.commands.answers["/work/a"] = Array(repeating: FakeCommands.dormant, count: 10)
        world.commands.answers["/work/b"] = Array(repeating: FakeCommands.dormant, count: 10)
        try world.start(["a", "b"])
        world.run(for: 20 * 60 + 1)
        // Its first read of `main` finds it finished, which reconciles once.
        #expect(world.reasons("a") == [["start"], ["main checks finished"]])
        #expect(world.reasons("b") == [["start"]] + Array(repeating: ["interval"], count: 4))
        #expect(try world.status(of: "a").next == .onChange)
    }

    @Test("main going red after the last merge wakes a dormant orchestrator repository, once")
    func redMainAfterLastMerge() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1, roles: ["orchestrator", "engineer"])
        world.commands.answers["/work/a"] = Array(repeating: FakeCommands.dormant, count: 10)
        func checkRuns(_ status: String, _ conclusion: String) -> String {
            #"{"check_runs":[{"id":1,"name":"Required","status":"\#(status)","conclusion":\#(conclusion)}]}"#
        }
        let noStatuses = #"{"total_count":0,"statuses":[]}"#
        world.github.commits["example-org/a@main"] = (
            checkRuns("completed", #""success""#), noStatuses, 0
        )
        try world.start(["a"])
        world.run(for: 60)
        // Its first read of `main` finds it finished, which reconciles once.
        #expect(world.reasons("a") == [["start"], ["main checks finished"]])

        // The last card merges: its move to Done reconciles while `main` runs.
        world.github.change(1) { $0[0][0] = BoardCard(number: 1, status: "Done", updatedAt: "t1") }
        world.github.commits["example-org/a@main"] = (
            checkRuns("in_progress", "null"), noStatuses, 1
        )
        world.run(for: 30 * 60)
        #expect(world.reasons("a") == [["start"], ["main checks finished"], ["board changed"]])

        world.github.commits["example-org/a@main"] = (
            checkRuns("completed", #""failure""#), noStatuses, 2
        )
        world.run(for: 15)
        #expect(world.reasons("a").suffix(2) == [["board changed"], ["main checks finished"]])

        // Dormant again: two hours of `main` unchanged cost no `next`, where the
        // board's GraphQL is spent.
        let nexts = world.commands.nextCalls.count
        world.run(for: 2 * 60 * 60)
        #expect(world.commands.nextCalls.count == nexts)
        #expect(world.reasons("a").count == 4)
    }

    @Test("main finishing red before a busy repository's first watch read is still filed")
    func redMainBeforeFirstWatchRead() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1, roles: ["orchestrator", "engineer"])
        // Busy: its first `next` passes a card over, so it keeps its interval and
        // doesn't read `main`.
        world.commands.answers["/work/a"] =
            [FakeCommands.idle]
            + Array(
                repeating: FakeCommands.dormant, count: 10)
        let noStatuses = #"{"total_count":0,"statuses":[]}"#
        world.github.commits["example-org/a@main"] = (
            #"{"check_runs":[{"id":1,"name":"Required","status":"in_progress","conclusion":null}]}"#,
            noStatuses, 0
        )
        try world.start(["a"])
        world.run(for: 60)
        #expect(!world.github.requests.contains { $0.contains("/commits/main/") })

        // The last card merges. The reconciliation for its move to Done reads
        // `main` running, and `main` finishes red before that `next` returns.
        world.commands.onNext = {
            world.github.commits["example-org/a@main"] = (
                #"{"check_runs":[{"id":1,"name":"Required","status":"completed","conclusion":"failure"}]}"#,
                noStatuses, 1
            )
        }
        world.github.change(1) { $0[0][0] = BoardCard(number: 1, status: "Done", updatedAt: "t1") }
        world.run(for: 30)
        #expect(world.reasons("a") == [["start"], ["board changed"], ["main checks finished"]])
    }

    @Test(
        "A parked card keeps its orchestrator repository's turns, since its blocker may land off the board"
    )
    func parkedCardKeepsTurns() throws {
        let world = SupervisorWorld()
        world.repository(
            "a", number: 1, roles: ["orchestrator", "engineer"],
            pages: [[BoardCard(number: 3, status: "Needs Human", updatedAt: "t0")]])
        world.commands.answers["/work/a"] = Array(repeating: FakeCommands.dormant, count: 10)
        try world.start(["a"])
        world.run(for: 20 * 60 + 1)
        #expect(world.reasons("a").count > 1)
        #expect(world.reasons("a").dropFirst().allSatisfy { $0 == ["interval"] })
    }

    static func timeline(_ pulls: [(repository: String, number: Int, updatedAt: String)]) -> String
    {
        let events = pulls.map { pull in
            """
            {"event":"cross-referenced","source":{"issue":{"number":\(pull.number),\
            "state":"open","body":"Closes example-org/a#5.","updated_at":"\(pull.updatedAt)",\
            "user":{"login":"agent-one"},\
            "pull_request":{"merged_at":null},"repository":{"full_name":"\(pull.repository)"}}}}
            """
        }
        return "[\(events.joined(separator: ","))]"
    }

    func reviewWorld(roles: [String] = ["orchestrator", "reviewer"]) throws -> SupervisorWorld {
        let world = SupervisorWorld()
        world.repository(
            "a", number: 1, roles: roles,
            pages: [[BoardCard(number: 5, status: "Human Review", updatedAt: "t0")]])
        world.github.timelines[5] = Self.timeline([
            ("example-org/tools", 17, "2026-11-01T11:00:00Z")
        ])
        world.github.lists["example-org/tools"] = .init(rows: [
            (17, "2026-11-01T11:00:00Z"), (18, "2026-11-01T11:30:00Z"),
        ])
        try world.start(["a"])
        world.run(for: 20)
        return world
    }

    @Test("A watched pull request changing triggers its board's repository")
    func watchedPullRequestTriggers() throws {
        let world = try reviewWorld()
        #expect(world.supervisor.repositories[0].watched[5]?.map(\.id.number) == [17])
        world.github.lists["example-org/tools"] = .init(
            rows: [(17, "2026-11-01T12:01:00Z"), (18, "2026-11-01T11:30:00Z")], version: 1)
        world.run(for: 15)
        #expect(world.reasons("a").last == ["pull request example-org/tools#17"])
    }

    @Test("Another pull request changing, or a watched one missing from the page, triggers nothing")
    func unwatchedChangesAreQuiet() throws {
        let world = try reviewWorld()
        world.github.lists["example-org/tools"] = .init(
            rows: [(18, "2026-11-01T12:01:00Z")], version: 1)
        world.run(for: 30)
        #expect(world.reasons("a") == [["start"]])
    }

    @Test("A card leaving the owner's review drops its pull requests and their list")
    func leavingReviewDropsWatch() throws {
        let world = try reviewWorld()
        world.github.change(1) { $0[0][0] = BoardCard(number: 5, status: "Done", updatedAt: "t1") }
        world.run(for: 15)
        #expect(world.supervisor.repositories[0].watched.isEmpty)
        let before = world.github.requests.filter { $0.contains("/pulls") }.count
        world.run(for: 60)
        #expect(world.github.requests.filter { $0.contains("/pulls") }.count == before)
    }

    @Test("A watched card's unreadable pull requests report recovering once, when they're read")
    func watchRecovers() throws {
        let world = try reviewWorld()
        let readable = world.github.timelines[5]
        world.github.timelines[5] = "not a timeline"
        world.github.change(1) {
            $0[0][0] = BoardCard(number: 5, status: "Human Review", updatedAt: "t1")
        }
        world.run(for: 15)
        world.github.change(1) {
            $0[0][0] = BoardCard(number: 5, status: "Human Review", updatedAt: "t2")
        }
        world.run(for: 15)
        #expect(world.events("watch-failed").count == 2)
        #expect(world.events("watch-recovered").isEmpty)
        world.github.timelines[5] = readable
        world.github.change(1) {
            $0[0][0] = BoardCard(number: 5, status: "Human Review", updatedAt: "t3")
        }
        world.run(for: 15)
        world.github.change(1) {
            $0[0][0] = BoardCard(number: 5, status: "Human Review", updatedAt: "t4")
        }
        world.run(for: 15)
        #expect(world.events("watch-recovered").map { $0["issue"] as? Int } == [5])
    }

    @Test("A login without orchestrator watches no pull requests")
    func nonOrchestratorWatchesNothing() throws {
        let world = try reviewWorld(roles: ["reviewer"])
        #expect(world.supervisor.repositories[0].watched.isEmpty)
        #expect(world.github.timelineReads.isEmpty)
        #expect(!world.github.requests.contains { $0.contains("/pulls") })
    }

    // MARK: Secondary limit

    @Test("A secondary-limit answer pauses every check and reconciliation, doubling on repeat")
    func secondaryLimit() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        try world.start(["a"])
        world.run(for: 20)
        world.github.override = CheckResponse(
            status: 403, headers: [:], body: "You have exceeded a secondary rate limit")
        world.run(for: 11)
        let afterFirst = world.github.requests.count
        world.run(for: 59)
        #expect(world.github.requests.count == afterFirst)
        world.run(for: 2)
        #expect(world.events("secondary-limit").map { $0["seconds"] as? Int } == [60, 120])
        #expect(world.commands.nextCalls.count == 1)
    }

    @Test("retry-after sets the pause")
    func retryAfter() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        try world.start(["a"])
        world.run(for: 20)
        world.github.override = CheckResponse(status: 429, headers: ["retry-after": "30"], body: "")
        world.run(for: 11)
        #expect(world.events("secondary-limit").first?["seconds"] as? Int == 30)
    }

    // MARK: Core limit

    static func coreExhausted(
        status: Int = 403, resetIn seconds: TimeInterval, headers: [String: String] = [:]
    ) -> CheckResponse {
        let reset = SupervisorWorld.start.addingTimeInterval(seconds)
        return CheckResponse(
            status: status,
            headers: headers.merging([
                "x-ratelimit-remaining": "0",
                "x-ratelimit-reset": String(Int(reset.timeIntervalSince1970)),
            ]) { $1 },
            body: "API rate limit exceeded")
    }

    @Test(
        "An exhausted core limit pauses checks and reconciliations until its reset, failing nothing"
    )
    func coreLimit() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        try world.start(["a"])
        world.run(for: 20)
        world.github.override = Self.coreExhausted(resetIn: 30 * 60)
        world.github.overrideCount = 1
        world.run(for: 11)
        let afterRefusal = world.github.requests.count
        let reconciliations = world.commands.nextCalls.count
        #expect(
            world.events("core-limit").map { $0["until"] as? String } == ["2026-11-01T12:30:00Z"])
        world.run(for: 30 * 60 - 32)
        #expect(world.github.requests.count == afterRefusal)
        #expect(world.commands.nextCalls.count == reconciliations)
        world.run(for: 2)
        #expect(world.github.requests.count > afterRefusal)
        #expect(world.events("check-failed").isEmpty)
        #expect(world.events("backoff").isEmpty)
        #expect(world.events("secondary-limit").isEmpty)
    }

    @Test(
        "A refusal naming both limits pauses until the later",
        arguments: [
            (retryAfter: 30, resetIn: 600.0, event: "core-limit"),
            (retryAfter: 3600, resetIn: 600.0, event: "secondary-limit"),
        ])
    func bothLimits(retryAfter: Int, resetIn: TimeInterval, event: String) throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        try world.start(["a"])
        world.run(for: 20)
        let refusedAt = world.clock.now.addingTimeInterval(10)
        world.github.override = Self.coreExhausted(
            status: 429, resetIn: resetIn, headers: ["retry-after": String(retryAfter)])
        world.github.overrideCount = 1
        world.run(for: 11)
        let afterRefusal = world.github.requests.count
        let until = max(
            refusedAt.addingTimeInterval(TimeInterval(retryAfter)),
            SupervisorWorld.start.addingTimeInterval(resetIn))
        world.run(for: until.timeIntervalSince(world.clock.now) - 1)
        #expect(world.github.requests.count == afterRefusal)
        #expect(world.events("core-limit").count + world.events("secondary-limit").count == 1)
        #expect(world.events(event).count == 1)
    }

    @Test("A 403 naming neither limit is still a check failure")
    func plainForbidden() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        try world.start(["a"])
        world.run(for: 20)
        world.github.override = CheckResponse(
            status: 403, headers: ["x-ratelimit-remaining": "12"], body: "Forbidden")
        world.github.overrideCount = 1
        world.run(for: 11)
        #expect(world.events("check-failed").count == 1)
        #expect(world.events("core-limit").isEmpty)
        #expect(world.events("secondary-limit").isEmpty)
    }

    // MARK: The answer table

    @Test("An assignment, or an idle answer with a MERGE line, launches a child")
    func launches() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        world.repository("b", number: 2)
        world.commands.answers["/work/a"] = [assignment(3)]
        world.commands.answers["/work/b"] = [
            #"{"schema":1,"kind":"idle","nextDelay":"backoff","repairs":["MERGE #4 PR #9 is clean"]}"#
        ]
        try world.start(["a", "b"])
        world.run(for: 300)
        #expect(
            world.launcher.started == [
                ChildRequest(
                    path: "/work/a", repository: "example-org/a", reason: "assignment",
                    thinkingSummaries: true),
                ChildRequest(
                    path: "/work/b", repository: "example-org/b", reason: "merge",
                    thinkingSummaries: true),
            ])
    }

    @Test("A retryable error backs off from one minute; a non-retryable one waits for a trigger")
    func errors() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        world.repository("b", number: 2)
        world.commands.answers["/work/a"] = Array(
            repeating:
                #"{"schema":1,"kind":"error","stage":"provider","message":"x","retry":true}"#,
            count: 3)
        world.commands.answers["/work/b"] = [
            #"{"schema":1,"kind":"error","stage":"loop.json","message":"bad","retry":false}"#
        ]
        try world.start(["a", "b"])
        world.run(for: 4 * 60)
        #expect(
            world.events("backoff").filter { $0["repository"] as? String == "example-org/a" }
                .map { $0["seconds"] as? Int } == [60, 120, 240])
        #expect(world.reasons("b") == [["start"]])
    }

    @Test("A Git-state failure keeps backing off, and only a success clears it and recovers")
    func gitStateFailureBacksOff() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        world.commands.answers["/work/a"] = Array(repeating: assignment(1), count: 4)
        try world.supervisor.start(paths: ["/work/a", "/work/tools"])
        world.commands.failingFetches = ["/work/tools"]
        world.run(for: 6 * 60)
        #expect(world.events("backoff").map { $0["seconds"] as? Int } == [60, 120, 240])
        #expect(world.events("backoff-cleared").isEmpty)
        #expect(world.events("reconcile-recovered").isEmpty)
        world.commands.failingFetches = []
        world.run(for: 9 * 60)
        #expect(world.events("backoff-cleared").count == 1)
        #expect(world.events("reconcile-recovered").count == 1)
    }

    @Test("An unknown schema is a non-retryable error")
    func unknownSchema() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        world.commands.answers["/work/a"] = [#"{"schema":2,"kind":"idle"}"#]
        try world.start(["a"])
        world.run(for: 5 * 60)
        let errors = world.events("error")
        #expect(errors.count == 1)
        #expect(errors.allSatisfy { $0["retry"] as? Bool == false })
        #expect(world.events("backoff").isEmpty)
        #expect(world.commands.nextCalls == ["/work/a"])
    }

    @Test("A failed update is reported, and the reconciliation goes on with the tool it has")
    func failedUpdateGoesOn() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        world.commands.failingUpdate = true
        try world.start(["a"])
        world.run(for: 1)
        let failed = try #require(world.events("update-failed").first)
        #expect(failed["repository"] as? String == "example-org/a")
        #expect(failed["message"] as? String == "tickwork: fetching Tickwork failed")
        #expect(world.commands.nextCalls == ["/work/a"])
        #expect(world.events("reconcile").count == 1)
        #expect(world.events("error").isEmpty)
        #expect(world.events("backoff").isEmpty)
    }

    // MARK: Fairness

    @Test("Of two repositories due, the one due longer goes first; ties go to argument order")
    func dueLongestFirst() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        world.repository("b", number: 2)
        try world.start(["b", "a"])
        world.run(for: 1)
        #expect(world.commands.nextCalls == ["/work/b", "/work/a"])
    }

    @Test("A busy repository alternates with one that came due while its child ran")
    func busyAlternates() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        world.repository("b", number: 2)
        world.commands.answers["/work/a"] = (1...3).map { assignment(1, head: "c\($0)") }
        try world.start(["a", "b"])
        world.run(for: 1)
        #expect(world.commands.nextCalls == ["/work/a"])
        world.run(for: 20)
        world.github.change(2) { $0[0][0] = BoardCard(number: 1, status: "Ready", updatedAt: "t1") }
        world.run(for: 120)
        #expect(world.commands.nextCalls == ["/work/a", "/work/b", "/work/a"])
    }

    @Test("A busy repository still alternates when its child outlives the interval")
    func longChildAlternates() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        world.repository("b", number: 2)
        world.launcher.duration = 12 * 60
        world.commands.answers["/work/a"] = (1...40).map { assignment(1, head: "c\($0)") }
        try world.start(["a", "b"])
        world.run(for: 3 * 60 * 60)
        let calls = world.commands.nextCalls.map { $0 == "/work/a" ? "a" : "b" }.joined()
        #expect(calls.hasPrefix("abab"))
        #expect(!calls.contains("aa"))
    }

    @Test("A repository waiting through a long child records each reason once")
    func reasonsOnce() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        world.repository("b", number: 2)
        world.launcher.duration = 30 * 60
        world.commands.answers["/work/a"] = [assignment(1)]
        try world.start(["b", "a"])
        world.run(for: 31 * 60)
        #expect(world.reasons("b") == [["start"], ["interval"]])
        // An assignment passes nothing over, so only its child's exit brings `a` round.
        #expect(world.reasons("a") == [["start"], ["child exited"]])
    }

    @Test("A watched list that keeps failing backs its repository off, though its board is fine")
    func persistentListFailureBacksOff() throws {
        let world = try reviewWorld()
        world.github.failing = ["/pulls"]
        let before = world.commands.nextCalls.count
        world.run(for: 4 * 60)
        #expect(world.events("backoff").map { $0["seconds"] as? Int }.prefix(2) == [60, 120])
        // Without a backoff this would be a reconciliation every round, sixteen.
        #expect(world.commands.nextCalls.count - before <= 4)
    }

    @Test("A board that keeps failing past the cap still retries every ten minutes")
    func persistentBoardFailureRetries() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        try world.start(["a"])
        world.run(for: 20)
        world.github.failing = ["projectsV2/1"]
        world.run(for: 60 * 60)
        let waits = world.events("backoff").compactMap { $0["seconds"] as? Int }
        #expect(waits.prefix(5) == [60, 120, 240, 480, 600])
        #expect(waits.count >= 8 && waits.dropFirst(4).allSatisfy { $0 == 600 })
        // A sliding deadline would hold every retry once the wait reached the cap.
        let retries = world.reasons("a").filter { $0.contains("check failed") }
        #expect(retries.count >= waits.count)
    }

    @Test("A board failing through its own long child keeps one backoff, not one a round")
    func failureDuringOwnChildKeepsBackoff() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        world.launcher.duration = 25 * 60
        world.commands.answers["/work/a"] = [assignment(1)]
        try world.start(["a"])
        world.run(for: 20)
        world.github.failing = ["projectsV2/1"]
        world.run(for: 60 * 60)
        let waits = world.events("backoff").compactMap { $0["seconds"] as? Int }
        #expect(waits.prefix(5) == [60, 120, 240, 480, 600])
        // A hold restarted every round of the child would log about a hundred.
        #expect(waits.count <= 10)
    }

    @Test("Interval work queued before the rate falls below the floor waits for the reset")
    func floorHoldsQueuedInterval() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        world.repository("b", number: 2)
        world.launcher.duration = 30 * 60
        world.github.rateReset = SupervisorWorld.start.addingTimeInterval(45 * 60)
        world.commands.answers["/work/a"] = [assignment(1)]
        try world.start(["b", "a"])
        world.run(for: 15 * 60)
        world.github.rateRemaining = 900
        world.run(for: 25 * 60)
        #expect(world.reasons("b") == [["start"]])
        #expect(world.reasons("a").last == ["child exited"])
        world.run(for: 6 * 60)
        #expect(world.reasons("b") == [["start"], ["interval"]])
    }

    @Test("A secondary limit on the first read pauses, then start goes on")
    func secondaryLimitAtStart() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        world.github.override = CheckResponse(status: 429, headers: ["retry-after": "30"], body: "")
        world.github.overrideCount = 2
        try world.start(["a"])
        #expect(world.events("secondary-limit").map { $0["seconds"] as? Int } == [30, 60])
        #expect(world.clock.now == SupervisorWorld.start.addingTimeInterval(90))
        #expect(world.events("start").count == 1)
        world.run(for: 1)
        #expect(world.reasons("a") == [["start"]])
    }

    // MARK: Self-update

    @Test("Every reconciliation updates before next, through the supervisor's own tool")
    func updatesBeforeNext() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        world.repository("b", number: 2)
        try world.start(["a", "b"])
        world.run(for: 1)
        #expect(world.commands.updateCalls == ["/work/a", "/work/b"])
        #expect(world.commands.nextCalls == ["/work/a", "/work/b"])
    }

    @Test("A newly installed revision replaces the supervisor with the same arguments")
    func newRevisionReplaces() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        world.repository("b", number: 2)
        try world.start(["a", "b"])
        world.run(for: 1)
        #expect(world.replacer.requests.isEmpty)
        world.installed = RunningTool(path: SupervisorWorld.installedPath, revision: "def")
        world.run(for: 15 * 60)
        #expect(world.replacer.requests.map(\.tool) == [SupervisorWorld.installedPath])
        #expect(world.replacer.requests.first?.arguments == ["loop", "/work/a", "/work/b"])
        let event = world.events("replace").first
        #expect(event?["from"] as? String == "abc-revision")
        #expect(event?["to"] as? String == "def")
    }

    @Test("The reconcile event names the revision of the tool that answered next")
    func reconcileNamesAnsweringRevision() throws {
        let updated = SupervisorWorld()
        updated.repository("a", number: 1)
        try updated.start(["a"])
        updated.installed = RunningTool(path: SupervisorWorld.installedPath, revision: "def")
        updated.run(for: 1)
        #expect(updated.events("reconcile").first?["revision"] as? String == "def")

        let uninstalledBuild = SupervisorWorld()
        uninstalledBuild.tool = nil
        uninstalledBuild.installed = RunningTool(
            path: SupervisorWorld.installedPath, revision: "def")
        uninstalledBuild.repository("a", number: 1)
        try uninstalledBuild.start(["a"])
        uninstalledBuild.run(for: 1)
        #expect(uninstalledBuild.events("reconcile").first?["revision"] as? String == "def")

        let elsewhere = SupervisorWorld()
        elsewhere.tool = RunningTool(
            path: "/home/agent/.cache/tickwork/0123abcd/bin/tickwork", revision: "abc-revision")
        elsewhere.installed = RunningTool(path: SupervisorWorld.installedPath, revision: "def")
        elsewhere.repository("a", number: 1)
        try elsewhere.start(["a"])
        elsewhere.run(for: 1)
        #expect(elsewhere.events("reconcile").first?["revision"] as? String == "abc-revision")
    }

    @Test("A supervisor running from another path is replaced by the installed tool")
    func otherPathReplaces() throws {
        let world = SupervisorWorld()
        world.tool = RunningTool(
            path: "/home/agent/.cache/tickwork/0123abcd/bin/tickwork", revision: "abc-revision")
        world.repository("a", number: 1)
        world.repository("b", number: 2)
        try world.start(["a", "b"])
        world.run(for: 1)
        #expect(world.replacer.requests.map(\.tool) == [SupervisorWorld.installedPath])
        // The fake returns where exec wouldn't, so the supervisor stops there.
        #expect(world.commands.nextCalls == ["/work/a"])
    }

    @Test("An unchanged tool, none installed, or a build no installer made replaces nothing")
    func nothingNewDoesNotReplace() throws {
        let unchanged = SupervisorWorld()
        unchanged.repository("a", number: 1)
        try unchanged.start(["a"])
        unchanged.run(for: 15 * 60)
        #expect(unchanged.reasons("a").count > 1)

        let uninstalled = SupervisorWorld()
        uninstalled.tool = RunningTool(
            path: "/home/agent/.cache/tickwork/0123abcd/bin/tickwork", revision: "abc-revision")
        uninstalled.installed = nil
        uninstalled.repository("a", number: 1)
        try uninstalled.start(["a"])
        uninstalled.run(for: 15 * 60)
        #expect(uninstalled.reasons("a").count > 1)

        let uninstalledBuild = SupervisorWorld()
        uninstalledBuild.tool = nil
        uninstalledBuild.installed = RunningTool(
            path: SupervisorWorld.installedPath, revision: "def")
        uninstalledBuild.repository("a", number: 1)
        try uninstalledBuild.start(["a"])
        uninstalledBuild.run(for: 15 * 60)
        #expect(uninstalledBuild.reasons("a").count > 1)

        for world in [unchanged, uninstalled, uninstalledBuild] {
            #expect(world.replacer.requests.isEmpty)
            #expect(world.events("replace").isEmpty)
        }
    }

    @Test("The installed tool spelled with a doubled slash is the same tool, and replaces nothing")
    func doubledSlashIsSameTool() throws {
        let world = SupervisorWorld()
        // As a HOME with a trailing slash spells it.
        world.installed = RunningTool(
            path: "/home/agent//.cache/tickwork/tool/bin/tickwork", revision: "abc-revision")
        world.repository("a", number: 1)
        try world.start(["a"])
        world.run(for: 15 * 60)
        #expect(world.replacer.requests.isEmpty)
        #expect(world.reasons("a").count > 1)
    }

    @Test("A new tool seen while a child runs replaces the supervisor only after it exits")
    func replacementWaitsForChild() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        world.installed = RunningTool(path: SupervisorWorld.installedPath, revision: "def")
        world.commands.answers["/work/a"] = [assignment(1)]
        world.launcher.duration = 120
        try world.start(["a"])
        world.run(for: 119)
        #expect(world.launcher.started.count == 1)
        #expect(world.replacer.requests.isEmpty)
        world.run(for: 2)
        #expect(world.replacer.requests.count == 1)
        #expect(world.events("child-exit").count == 1)
    }

    @Test("A replacement waiting on a child that exits during a GitHub pause waits for the pause")
    func replacementWaitsForPause() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        world.installed = RunningTool(path: SupervisorWorld.installedPath, revision: "def")
        world.commands.answers["/work/a"] = [assignment(1)]
        world.launcher.duration = 120
        try world.start(["a"])
        world.run(for: 30)
        world.github.override = CheckResponse(
            status: 429, headers: ["retry-after": "600"], body: "")
        world.run(for: 60)
        try #require(world.events("secondary-limit").count == 1)
        world.github.override = nil
        world.run(for: 60)
        #expect(world.events("child-exit").count == 1)
        #expect(world.replacer.requests.isEmpty)
        world.run(for: 600)
        #expect(world.replacer.requests.count == 1)
    }

    // MARK: Parsing

    @Test("gh api -i output is read for its status, headers and body, a 304 included")
    func readsIncludedOutput() throws {
        let response = try #require(
            checkResponse(
                includedOutput:
                    "HTTP/2.0 304 Not Modified\r\nEtag: \"abc\"\r\nX-Ratelimit-Remaining: 4991\r\n\r\n"
            ))
        #expect(response.status == 304)
        #expect(response.etag == "\"abc\"")
        #expect(response.headers["x-ratelimit-remaining"] == "4991")
        #expect(checkResponse(includedOutput: "gh: HTTP 304") == nil)
        let ok = try #require(checkResponse(includedOutput: "HTTP/2.0 200 OK\nEtag: x\n\n[1]"))
        #expect(ok.body == "[1]")
    }

    @Test("The next page comes from the Link header as a path")
    func readsNextLink() {
        let header =
            "<https://api.github.com/user/1/projectsV2/1/items?per_page=100&after=Y3>; rel=\"next\", "
            + "<https://api.github.com/user/1/projectsV2/1/items?per_page=100>; rel=\"first\""
        #expect(nextLink(header) == "user/1/projectsV2/1/items?per_page=100&after=Y3")
        #expect(nextLink("<https://api.github.com/x>; rel=\"prev\"") == nil)
        #expect(nextLink(nil) == nil)
    }

    @Test("A board page's cards carry their number, Status and item updated_at")
    func readsBoardCards() throws {
        let json = """
            [{"content":{"number":12,"repository_url":"https://api.github.com/repos/example-org/a"},
              "updated_at":"2026-11-01T10:00:00Z",
              "fields":[{"id":7,"value":{"name":{"raw":"Human Review","html":"Human Review"}}}]},
             {"content":{"number":13,"repository_url":"https://api.github.com/repos/example-org/a"},
              "updated_at":"2026-11-01T10:01:00Z","fields":[]}]
            """
        #expect(
            try boardCards(itemsJSON: json, statusFieldID: 7, repository: "example-org/a") == [
                BoardCard(number: 12, status: "Human Review", updatedAt: "2026-11-01T10:00:00Z"),
                BoardCard(number: 13, status: "", updatedAt: "2026-11-01T10:01:00Z"),
            ])
    }

    @Test("On a shared board, each repository's page holds only its own card of a number")
    func sharedBoardCards() throws {
        let json = """
            [{"content":{"number":5,"repository_url":"https://api.github.com/repos/example-org/a"},
              "updated_at":"2026-11-01T10:00:00Z",
              "fields":[{"id":7,"value":{"name":{"raw":"Ready"}}}]},
             {"content":{"number":5,"repository_url":"https://api.github.com/repos/example-org/b"},
              "updated_at":"2026-11-01T10:01:00Z",
              "fields":[{"id":7,"value":{"name":{"raw":"Human Review"}}}]}]
            """
        #expect(
            try boardCards(itemsJSON: json, statusFieldID: 7, repository: "example-org/a") == [
                BoardCard(number: 5, status: "Ready", updatedAt: "2026-11-01T10:00:00Z")
            ])
        // `loop.json` may spell the repository otherwise than GitHub does.
        #expect(
            try boardCards(itemsJSON: json, statusFieldID: 7, repository: "Example-Org/B") == [
                BoardCard(number: 5, status: "Human Review", updatedAt: "2026-11-01T10:01:00Z")
            ])
        // A pull request's content has no `repository_url`; its repository is its base's.
        let pullRequests = """
            [{"content":{"number":9,"base":{"repo":{"full_name":"example-org/a"}}},
              "updated_at":"2026-11-01T10:02:00Z","fields":[]},
             {"content":{"number":9,"base":{"repo":{"full_name":"example-org/b"}}},
              "updated_at":"2026-11-01T10:03:00Z","fields":[]}]
            """
        #expect(
            try boardCards(itemsJSON: pullRequests, statusFieldID: 7, repository: "example-org/a")
                == [BoardCard(number: 9, status: "", updatedAt: "2026-11-01T10:02:00Z")])
        let unowned = #"[{"content":{"number":5},"updated_at":"t0","fields":[]}]"#
        #expect(throws: BoardError.self) {
            try boardCards(itemsJSON: unowned, statusFieldID: 7, repository: "example-org/a")
        }
    }

    @Test("Watched pull requests are the resolver's open ones, with the timeline's updated_at")
    func readsWatchedPullRequests() throws {
        let json = SupervisorTests.timeline([
            ("example-org/tools", 17, "2026-11-01T11:00:00Z")
        ])
        let watched = try watchedPullRequests(
            issue: 5, timelineJSON: json, home: "example-org/a",
            agents: ["agent-one"], owner: "example-owner"
        ) { _ in throw BoardError("no pull request is read") }
        #expect(
            watched == [
                WatchedPullRequest(
                    id: PullRequestID(repository: "example-org/tools", number: 17),
                    updatedAt: try date("2026-11-01T11:00:00Z"))
            ])
        #expect(
            try watchedPullRequests(
                issue: 6, timelineJSON: json, home: "example-org/a",
                agents: ["agent-one"], owner: "example-owner"
            ) { _ in throw BoardError("no pull request is read") }.isEmpty)
    }
}
