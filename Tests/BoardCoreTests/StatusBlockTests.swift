// The status block's lines: each example in docs/supervisor-status.md at 80 and
// 40 columns, each repository state, and the width, focus and height rules.
//

import Foundation
import Testing

@testable import BoardCore

private typealias Status = SupervisorStatus

private let utc = TimeZone(identifier: "UTC")!
private let today = ISO8601DateFormatter().date(from: "2026-11-03T00:00:00Z")!

/// `"12:03:15"` or `"12:01"`, today.
private func at(_ clock: String) -> Date {
    let parts = clock.split(separator: ":").compactMap { Double($0) }
    let seconds = parts.count > 2 ? parts[2] : 0
    return today.addingTimeInterval(parts[0] * 3600 + parts[1] * 60 + seconds)
}

private func repository(
    _ name: String, _ state: Status.State, error: String? = nil, checked: String? = nil,
    failingSince: String? = nil, changed: String? = nil, due: Status.Due? = nil,
    next: Status.Next = .inTurn, setAside: [Int] = []
) -> Status.Repository {
    .init(
        name: "example-org/\(name)", state: state, error: error, checked: checked.map(at),
        failingSince: failingSince.map(at), changed: changed.map(at), due: due, next: next,
        setAsideMerges: setAside)
}

private func status(
    login state: Status.LoginState = .running, core: Int? = 4_976, limited: Bool = false,
    graphQL: Int? = 4_888, graphQLAt: String = "12:01", child: Status.Child? = nil,
    _ repositories: [Status.Repository]
) -> Status {
    .init(
        login: "agent", revision: "a02db1fb0c9d", state: state,
        core: core.map {
            .init(remaining: $0, limit: 5_000, reset: at("13:00"), limited: limited)
        },
        graphQL: graphQL.map {
            .init(budget: BudgetAnswer(remaining: $0, limit: 5_000), reported: at(graphQLAt))
        },
        child: child, repositories: repositories)
}

private func windows(
    _ fiveHour: Int, _ sevenDay: Int, at reported: String,
    fiveHourStatus: ClaudeWindows.Status = .allowed
) -> ClaudeWindows {
    .init(
        windows: [
            .init(name: "five_hour", percent: fiveHour, status: fiveHourStatus),
            .init(name: "seven_day", percent: sevenDay, status: .allowed),
        ], reported: at(reported))
}

private func child(_ name: String, since: String, issue: Int, role: String, task: String)
    -> Status.Child
{
    .init(
        repository: "example-org/\(name)", started: at(since), terminated: nil,
        purpose: .assignment(.init(issue: issue, role: role, task: task)))
}

private func columns(_ line: String) -> Int {
    line.reduce(0) { $0 + ($1.isASCII ? 1 : StatusBlock.nonASCIIColumns) }
}

private func unstyled(_ line: String) -> String {
    line.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
}

/// The block's lines, checked against the width whatever the test asserts.
private func lines(
    _ status: Status, _ activity: ClaudeActivity = .init(), width: Int = 80, height: Int = 40,
    styled: Bool = false, now: String = "12:05"
) -> [String] {
    let lines = StatusBlock(styled: styled, timeZone: utc).lines(
        status, activity: activity, width: width, height: height, now: at(now))
    for line in lines { #expect(columns(unstyled(line)) < width, "\(line)") }
    return lines
}

@Suite("tickwork loop: the status block")
struct StatusBlockTests {

    // MARK: The design's examples

    private let idle = status([
        repository(
            "app", .idle, checked: "12:03:15", changed: "11:58:02", next: .at(at("12:05:00")))
    ])
    private let idleActivity = ClaudeActivity(windows: windows(12, 11, at: "11:40"))

    @Test("One repository, idle")
    func idleExample() {
        #expect(
            lines(idle, idleActivity) == [
                "running · agent · tickwork a02db1fb",
                // 82 columns with each `·` counted as two, so it is cut.
                "GitHub core 4,976/5,000 · GraphQL 4,888 at 12:01 · Claude 5h 12% 7d 11% at …",
                "app  idle · checked 12:03:15 · changed 11:58:02 · next 12:05:00",
            ])
        #expect(
            lines(idle, idleActivity, width: 40) == [
                "running · agent · tickwork a02db1fb",
                "GitHub core 4,976/5,000 · GraphQL 4,…",
                "app  idle · checked 12:03:15 · chan…",
            ])
    }

    @Test("A dormant repository waits for a change, not a time")
    func dormantExample() {
        let dormant = status([
            repository("app", .idle, checked: "12:03:15", changed: "11:58:02", next: .onChange)
        ])
        #expect(
            lines(dormant, idleActivity).last
                == "app  idle · checked 12:03:15 · changed 11:58:02 · next on a change")
    }

    @Test("Reconciling")
    func reconcilingExample() {
        let reconciling = status([
            repository(
                "app", .reconciling(since: at("12:03:16"), reasons: ["board changed"]),
                checked: "12:03:15")
        ])
        #expect(
            lines(reconciling)[2]
                == "app  reconciling since 12:03:16: board changed · checked 12:03:15")
        #expect(lines(reconciling, width: 40)[2] == "app  reconciling since 12:03:16: boar…")
    }

    private func running(_ state: Status.LoginState = .running, core: Int = 4_861) -> Status {
        status(
            login: state, core: core, limited: core < 1_000, graphQL: 4_850, graphQLAt: "12:03",
            child: child("app", since: "12:03:20", issue: 41, role: "engineer", task: "start"),
            [
                repository("app", .claude, checked: "12:04:47"),
                repository(
                    "tools", .due(waitingFor: .child(repository: "example-org/app")),
                    checked: "12:04:47", due: .init(since: at("12:03:30"), reasons: ["interval"])),
            ])
    }

    @Test("Claude running in one repository while another is due, folded away")
    func claudeRunningExample() {
        let activity = ClaudeActivity(tool: "Bash", windows: windows(14, 11, at: "12:04"))
        #expect(
            lines(running(), activity) == [
                "running · agent · tickwork a02db1fb",
                "GitHub core 4,861/5,000 · GraphQL 4,850 at 12:03 · Claude 5h 14% 7d 11%",
                "app    Claude since 12:03:20 · #41 engineer/start · Bash · checked 12:04:47",
                "+1 quiet",
            ])
        #expect(
            lines(running(), activity, width: 40) == [
                "running · agent · tickwork a02db1fb",
                "GitHub core 4,861/5,000 · GraphQL 4,…",
                "app    Claude since 12:03:20 · #41 e…",
                "+1 quiet",
            ])
    }

    @Test("GitHub's secondary limit, then a low core budget")
    func pausedAndLimitedExample() {
        let activity = ClaudeActivity(tool: "Read", windows: windows(14, 11, at: "12:04"))
        let paused = running(.paused(until: at("12:06:47"), cause: .secondaryLimit))
        #expect(
            lines(paused, activity) == [
                "PAUSED until 12:06:47: GitHub's secondary limit · agent · tickwork a02db1fb",
                "GitHub core 4,861/5,000 · GraphQL 4,850 at 12:03 · Claude 5h 14% 7d 11%",
                "app    Claude since 12:03:20 · #41 engineer/start · Read · checked 12:04:47",
                "+1 quiet",
            ])
        #expect(
            lines(paused, activity, width: 40) == [
                "PAUSED until 12:06:47: GitHub's secon…",
                "GitHub core 4,861/5,000 · GraphQL 4,…",
                "app    Claude since 12:03:20 · #41 e…",
                "+1 quiet",
            ])
        let limited = running(core: 812)
        #expect(
            lines(limited, activity)[1]
                == "GitHub core 812/5,000, intervals wait for 13:00 · GraphQL 4,850 at 12:03 · …")
        #expect(lines(limited, activity, width: 40)[1] == "GitHub core 812/5,000, intervals wait…")
    }

    @Test("Local errors and parking")
    func errorsExample() {
        let errors = status(
            core: 4_700, graphQL: 4_800, graphQLAt: "12:40",
            [
                repository(
                    "app", .parked(.init(issue: 57, role: "engineer", task: "address-findings")),
                    checked: "12:40:15"),
                repository(
                    "tools", .backingOff(until: at("12:49:00")),
                    error: "fetch failed: Could not resolve host", checked: "12:40:15",
                    failingSince: "12:44:00", next: .at(at("12:49:00"))),
            ])
        let activity = ClaudeActivity(windows: windows(31, 23, at: "12:38"))
        #expect(
            lines(errors, activity) == [
                "running · agent · tickwork a02db1fb",
                "GitHub core 4,700/5,000 · GraphQL 4,800 at 12:40 · Claude 5h 31% 7d 23% at …",
                "app    needs you · parked #57 engineer/address-findings: no progress twice; …",
                "tools  retry at 12:49:00: fetch failed: Could not resolve host · last checke…",
            ])
        #expect(
            lines(errors, activity, width: 40) == [
                "running · agent · tickwork a02db1fb",
                "GitHub core 4,700/5,000 · GraphQL 4,…",
                "app    needs you · parked #57 engine…",
                "tools  retry at 12:49:00: fetch faile…",
            ])
    }

    @Test("Claude's limit")
    func claudeLimitExample() {
        let paused = status(
            login: .paused(until: at("14:00"), cause: .subscriptionLimit), core: 4_700,
            graphQL: 4_800,
            graphQLAt: "12:40",
            [
                repository(
                    "app", .due(waitingFor: .pause), checked: "12:52:18",
                    due: .init(since: at("12:51:03"), reasons: ["child exited"])),
                repository("tools", .idle, checked: "12:52:18", next: .at(at("12:58:00"))),
            ])
        let activity = ClaudeActivity(
            windows: windows(100, 23, at: "12:51", fiveHourStatus: .rejected))
        #expect(
            lines(paused, activity, now: "12:53") == [
                "PAUSED until 14:00: Claude's five_hour limit · agent · tickwork a02db1fb",
                "GitHub core 4,700/5,000 · GraphQL 4,800 at 12:40 · Claude 5h 100% 7d 23% at…",
                "app    due since 12:51:03: waiting for the pause · checked 12:52:18 · next …",
                "tools  idle · checked 12:52:18 · next 12:58:00",
            ])
        #expect(
            lines(paused, activity, width: 40, now: "12:53") == [
                "PAUSED until 14:00: Claude's five_hou…",
                "GitHub core 4,700/5,000 · GraphQL 4,…",
                "app    due since 12:51:03: waiting fo…",
                "tools  idle · checked 12:52:18 · ne…",
            ])
    }

    @Test("A stop: the final block, headed STOPPED at T")
    func stopExample() {
        let stopped = status(
            login: .stopped(at: at("12:55:02"), reason: "authentication failed"), core: 4_700,
            graphQL: 4_800, graphQLAt: "12:40",
            [
                repository(
                    "app",
                    .ended(
                        outcome: "authentication",
                        purpose: .assignment(
                            .init(issue: 57, role: "engineer", task: "address-findings")))),
                repository("tools", .idle, checked: "12:54:48", next: .at(at("12:58:00"))),
            ])
        let activity = ClaudeActivity(windows: windows(31, 23, at: "12:54"))
        #expect(
            lines(stopped, activity, now: "12:55:02") == [
                "STOPPED at 12:55:02 · agent · tickwork a02db1fb",
                "GitHub core 4,700/5,000 · GraphQL 4,800 at 12:40 · Claude 5h 31% 7d 23% at …",
                "app    Claude ended, authentication · #57 engineer/address-findings",
                "tools  idle · checked 12:54:48 · next 12:58:00",
            ])
        #expect(
            lines(stopped, activity, width: 40, now: "12:55:02") == [
                "STOPPED at 12:55:02 · agent · tickw…",
                "GitHub core 4,700/5,000 · GraphQL 4,…",
                "app    Claude ended, authentication …",
                "tools  idle · checked 12:54:48 · ne…",
            ])
    }

    // MARK: Each repository state

    private enum Marking { case needsYou, recovers, none }

    private func expectState(
        _ repository: Status.Repository, _ text: String, _ marking: Marking,
        child: Status.Child? = nil, activity: ClaudeActivity = .init(),
        others: [Status.Repository] = [], sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let block = status(child: child, [repository] + others)
        let plain = lines(block, activity, width: 200)[2]
        #expect(plain == "app  \(text)", sourceLocation: sourceLocation)
        let styled = lines(block, activity, width: 200, styled: true)[2]
        #expect(unstyled(styled) == plain, sourceLocation: sourceLocation)
        switch marking {
        case .needsYou:
            #expect(styled.contains("\u{1B}[31mneeds you\u{1B}[0m"), sourceLocation: sourceLocation)
        case .recovers:
            #expect(styled.contains("\u{1B}[33m"), sourceLocation: sourceLocation)
            #expect(!styled.contains("\u{1B}[31m"), sourceLocation: sourceLocation)
        case .none:
            #expect(!styled.contains("\u{1B}"), sourceLocation: sourceLocation)
        }
    }

    @Test("Parked needs you")
    func parked() {
        expectState(
            repository(
                "app", .parked(.init(issue: 57, role: "engineer", task: "address-findings")),
                checked: "12:04:00", next: .at(at("12:10:00"))),
            "needs you · parked #57 engineer/address-findings: no progress twice; "
                + "release the claim, restart · checked 12:04:00 · next 12:10:00", .needsYou)
    }

    @Test("A next error that isn't retryable needs you, with its message")
    func needsFix() {
        expectState(
            repository("app", .needsFix, error: "origin/main has no loop.json"),
            "needs you · needs a fix on main: origin/main has no loop.json · next in turn",
            .needsYou)
    }

    @Test("Claude running names the assignment and the current tool")
    func claudeForAssignment() {
        expectState(
            repository("app", .claude, checked: "12:04:47", changed: "12:03:10"),
            "Claude since 12:03:20 · #41 engineer/start · Bash · checked 12:04:47 · "
                + "changed 12:03:10", .none,
            child: child("app", since: "12:03:20", issue: 41, role: "engineer", task: "start"),
            activity: .init(tool: "Bash"))
    }

    @Test("Claude merging names each MERGE line's issue")
    func claudeMerging() {
        expectState(
            repository("app", .claude),
            "Claude since 12:03:20 · merging #4, #5", .none,
            child: .init(
                repository: "example-org/app", started: at("12:03:20"), terminated: nil,
                purpose: .merge(issues: [4, 5])))
    }

    @Test("Claude past the time limit is stopping, since SIGTERM was sent")
    func claudeStopping() {
        expectState(
            repository("app", .claude),
            "stopping (time limit) since 14:03:20 · #41 engineer/start", .none,
            child: .init(
                repository: "example-org/app", started: at("12:03:20"),
                terminated: at("14:03:20"),
                purpose: .assignment(.init(issue: 41, role: "engineer", task: "start"))),
            activity: .init(tool: "Bash"))
    }

    @Test("Reconciling gives its reasons")
    func reconciling() {
        expectState(
            repository(
                "app", .reconciling(since: at("12:03:16"), reasons: ["board changed", "interval"])),
            "reconciling since 12:03:16: board changed, interval", .none)
    }

    @Test("Backing off recovers, at its retry time")
    func backingOff() {
        expectState(
            repository(
                "app", .backingOff(until: at("12:49:00")), error: "fetch failed",
                checked: "12:48:00", next: .at(at("12:49:00"))),
            "retry at 12:49:00: fetch failed · checked 12:48:00", .recovers)
    }

    @Test("Failing checks recover, and the last good round is last checked")
    func failing() {
        expectState(
            repository(
                "app", .failing, error: "HTTP 502", checked: "12:03:15", failingSince: "12:03:30",
                next: .at(at("12:10:00"))),
            "checks failing since 12:03:30: HTTP 502 · last checked 12:03:15 · next 12:10:00",
            .recovers)
    }

    @Test("Due says what holds it")
    func due() {
        let since = Status.Due(since: at("12:03:30"), reasons: ["interval"])
        let holds: [(Status.Hold?, String)] = [
            (.child(repository: "example-org/ui"), ": waiting for Claude in ui"),
            (.pause, ": waiting for the pause"),
            (.coreFloor, ": waiting for the core floor"),
            (nil, ""),
        ]
        for (hold, text) in holds {
            expectState(
                repository("app", .due(waitingFor: hold), due: since, next: .after(at("13:00"))),
                "due since 12:03:30\(text) · next after 13:00:00", .none,
                others: [repository("ui", .idle)])
        }
    }

    @Test("Idle")
    func idleState() {
        expectState(repository("app", .idle), "idle · next in turn", .none)
    }

    @Test("Set-aside merges need you, after the state")
    func setAside() {
        expectState(
            repository("app", .idle, setAside: [4, 5]),
            "idle · needs you: set aside merge #4, #5 · next in turn", .needsYou)
    }

    @Test("The child that stopped the supervisor names its ending")
    func ended() {
        expectState(
            repository(
                "app",
                .ended(outcome: "authentication", purpose: .merge(issues: [4]))),
            "Claude ended, authentication · merging #4", .none)
    }

    // MARK: The login and budget lines

    @Test("An ambiguous ending pauses, and a pending replacement names its revision")
    func loginStates() {
        #expect(
            lines(status(login: .paused(until: at("12:35:00"), cause: .ambiguousEnding), []))[0]
                == "PAUSED until 12:35:00: Claude's ending was unclear · agent · tickwork a02db…")
        #expect(
            lines(status(login: .replacing(revision: "0123456789ab"), []))[0]
                == "updating to 01234567 after Claude exits · agent · tickwork a02db1fb")
        #expect(
            lines(status(login: .paused(until: at("14:00"), cause: .subscriptionLimit), []))[0]
                == "PAUSED until 14:00: Claude's subscription limit · agent · tickwork a02db1fb")
    }

    @Test("A pause past today carries its date")
    func pauseOnAnotherDay() {
        let until = at("14:00").addingTimeInterval(2 * 24 * 3600)
        #expect(
            lines(status(login: .paused(until: until, cause: .subscriptionLimit), []))[0]
                .hasPrefix("PAUSED until Nov 5 14:00: "))
    }

    @Test("Limited budgets and a near-limit window take the warning colour and say so")
    func limits() {
        let low = status(core: 812, limited: true, graphQL: 900, [])
        let activity = ClaudeActivity(
            windows: windows(91, 40, at: "12:04", fiveHourStatus: .allowedWarning))
        let line = lines(low, activity, width: 200, styled: true)[1]
        #expect(
            unstyled(line)
                == "GitHub core 812/5,000, intervals wait for 13:00 · "
                + "GraphQL 900 at 12:01, reads wait for the reset · "
                + "Claude 5h 91% near limit 7d 40% at 12:04")
        #expect(line.contains("\u{1B}[33mGitHub core 812/5,000, intervals wait for 13:00\u{1B}[0m"))
        #expect(line.contains("\u{1B}[33mGraphQL 900 at 12:01, reads wait for the reset\u{1B}[0m"))
        #expect(line.contains("\u{1B}[33m 5h 91% near limit\u{1B}[0m"))
    }

    @Test("Budgets not yet read")
    func unreadBudgets() {
        #expect(lines(status(core: nil, graphQL: nil, []))[1] == "GitHub core not read yet")
    }

    // MARK: Width

    @Test("No line reaches the width, non-ASCII counted as two columns")
    func width() {
        let wide = status([
            repository("app", .failing, error: String(repeating: "読み込み失敗 🚫 ", count: 10)),
            repository("tools", .backingOff(until: at("12:49:00")), error: "ok · 🚫 · ok"),
        ])
        for width in [12, 20, 39, 40, 41, 80, 81] {
            for line in lines(wide, width: width) { #expect(columns(line) <= width - 1) }
        }
        let cut = lines(wide, width: 40)[2]
        #expect(cut == "app    checks failing: 読み込み失敗 …")
    }

    @Test("Line breaks and other control characters in an error become one space")
    func multiLineError() {
        let block = status([
            repository(
                "app", .needsFix,
                error:
                    "fetch failed: ssh: Could not resolve hostname\r\nfatal: no remote\n\tagain\u{1B}"
            )
        ])
        #expect(
            lines(block, width: 200)[2]
                == "app  needs you · needs a fix on main: fetch failed: ssh: Could not resolve hostname "
                + "fatal: no remote again · next in turn")
    }

    @Test("A line exactly one column short of the width is left whole")
    func exactFit() {
        let block = status([repository("app", .idle)])
        let line = "app  idle · next in turn"
        #expect(lines(block, width: columns(line) + 1)[2] == line)
        #expect(lines(block, width: columns(line))[2] == "app  idle · next in t…")
    }

    @Test("Names drop the owner unless two would match, and pad to the longest up to 12")
    func names() {
        let block = Status(
            login: "agent", revision: nil, state: .running, core: nil, graphQL: nil, child: nil,
            repositories: [
                .init(
                    name: "one/app", state: .idle, error: nil, checked: nil, failingSince: nil,
                    changed: nil, due: nil, next: .inTurn, setAsideMerges: []),
                .init(
                    name: "two/app", state: .idle, error: nil, checked: nil, failingSince: nil,
                    changed: nil, due: nil, next: .inTurn, setAsideMerges: []),
                .init(
                    name: "one/a-very-long-name", state: .idle, error: nil, checked: nil,
                    failingSince: nil, changed: nil, due: nil, next: .inTurn, setAsideMerges: []),
            ])
        #expect(
            lines(block) == [
                "running · agent · tickwork",
                "GitHub core not read yet",
                "one/app       idle · next in turn",
                "two/app       idle · next in turn",
                "a-very-long-name  idle · next in turn",
            ])
    }

    // MARK: While a child runs

    @Test(
        "Only the active repository and those needing attention keep a line, and only it is dated")
    func quietWhileChildRuns() {
        let block = status(
            child: child("app", since: "12:03:20", issue: 41, role: "engineer", task: "start"),
            [
                repository("app", .claude, checked: "12:04:47", changed: "12:01:00"),
                repository("idle", .idle, checked: "12:04:00"),
                repository(
                    "flaky", .backingOff(until: at("12:10:00")), error: "fetch failed",
                    checked: "12:04:00"),
                repository("due", .due(waitingFor: .child(repository: "example-org/app"))),
                repository(
                    "stuck", .parked(.init(issue: 7, role: "engineer", task: "start"))),
                repository(
                    "busy", .reconciling(since: at("12:04:00"), reasons: ["interval"])),
                repository("broken", .failing, error: "HTTP 500"),
                repository("merges", .idle, setAside: [9]),
            ])
        #expect(
            lines(block, width: 200).dropFirst(2) == [
                "app     Claude since 12:03:20 · #41 engineer/start · checked 12:04:47 · changed 12:01:00",
                "flaky   retry at 12:10:00: fetch failed",
                "stuck   needs you · parked #7 engineer/start: no progress twice; "
                    + "release the claim, restart",
                "broken  checks failing: HTTP 500",
                "merges  idle · needs you: set aside merge #9",
                "+3 quiet",
            ])
    }

    @Test("With nothing else to say, the active repository stands alone")
    func noneQuiet() {
        let block = status(
            child: child("app", since: "12:03:20", issue: 41, role: "engineer", task: "start"),
            [repository("app", .claude)])
        #expect(lines(block).count == 3)
    }

    // MARK: Height

    @Test("Past half the rows, idle repositories with nothing failing fold into one line")
    func heightFold() {
        let block = status([
            repository("a", .idle, checked: "12:04:10"),
            repository(
                "b", .failing, error: "HTTP 500", checked: "12:03:00", failingSince: "12:03:30"),
            repository("c", .idle, checked: "12:04:05"),
            repository("d", .idle, setAside: [3]),
            repository("e", .idle, checked: "12:04:20"),
        ])
        #expect(lines(block, height: 14).count == 7)
        #expect(
            lines(block, height: 13).dropFirst(2) == [
                "b  checks failing since 12:03:30: HTTP 500 · last checked 12:03:00 · next i…",
                "d  idle · needs you: set aside merge #3 · next in turn",
                "+3 idle, checked 12:04:05",
            ])
        #expect(lines(block, height: 6).count == 3)
    }

    // MARK: Styling

    @Test("Without styling the lines carry no escape sequences and keep their words")
    func noColour() {
        let block = status(
            login: .paused(until: at("12:06:47"), cause: .secondaryLimit), core: 812, limited: true,
            [
                repository(
                    "app", .parked(.init(issue: 57, role: "engineer", task: "start")),
                    setAside: [4]),
                repository(
                    "tools", .failing, error: "HTTP 502", checked: "12:03:15",
                    failingSince: "12:03:30"),
            ])
        let activity = ClaudeActivity(
            windows: windows(91, 40, at: "12:04", fiveHourStatus: .allowedWarning))
        let plain = lines(block, activity, width: 300)
        let styled = lines(block, activity, width: 300, styled: true)
        #expect(plain.allSatisfy { !$0.contains("\u{1B}") })
        #expect(styled.contains { $0.contains("\u{1B}") })
        #expect(styled.map(unstyled) == plain)
        let text = plain.joined(separator: "\n")
        for words in [
            "PAUSED until", "intervals wait", "near limit", "needs you · parked",
            "needs you: set aside", "checks failing", "last checked",
        ] {
            #expect(text.contains(words), "\(words)")
        }
    }
}
