// The supervisor's child: billing, how it ended, what each ending does, the time
// limit, signals, and the no-progress rule.
//

import Foundation
import Testing

@testable import BoardCore

private func result(isError: Bool, status: Int? = nil, subtype: String = "success") -> String {
    let code = status.map(String.init) ?? "null"
    return
        #"{"type":"result","subtype":"\#(subtype)","is_error":\#(isError),"api_error_status":\#(code)}"#
}

private func rateLimit(_ status: String, resetsAt: Date) -> String {
    let reset = Int(resetsAt.timeIntervalSince1970)
    return
        #"{"type":"rate_limit_event","rate_limit_info":{"status":"\#(status)","rateLimitType":"five_hour","resetsAt":\#(reset)}}"#
}

private let merge =
    ##"{"schema":1,"kind":"idle","nextDelay":"backoff","repairs":["MERGE #4 PR #9 is clean"]}"##
private let otherMerge =
    ##"{"schema":1,"kind":"idle","nextDelay":"backoff","repairs":["MERGE #5 PR #10 is clean"]}"##

private func auth(_ json: String, status: Int32 = 0) -> CommandResult {
    CommandResult(status: status, output: json, errors: status == 0 ? "" : "not logged in")
}

@Suite("tickwork loop: the child")
struct SupervisorChildTests {

    // MARK: Billing

    @Test("The child's environment drops every billing variable, and the command never uses --bare")
    func scrubsEnvironment() {
        var environment = ["PATH": "/usr/bin", "HOME": "/home/agent"]
        for name in billingVariables { environment[name] = "x" }
        #expect(childEnvironment(environment) == ["PATH": "/usr/bin", "HOME": "/home/agent"])
        let command = childCommand(repository: "example-org/a", thinkingSummaries: false)
        #expect(!command.contains("--bare"))
        #expect(Array(command.prefix(3)) == ["claude", "-p", "/next-task"])
        #expect(command.contains("stream-json"))
        #expect(command.contains("--include-partial-messages"))
        #expect(command.suffix(2) == ["--name", "tickwork example-org/a"])
        #expect(!command.contains("--thinking-display"))
    }

    @Test("Thinking summaries add --thinking-display summarized and nothing else")
    func thinkingFlag() {
        let plain = childCommand(repository: "example-org/a", thinkingSummaries: false)
        let thinking = childCommand(repository: "example-org/a", thinkingSummaries: true)
        let flag = thinking.firstIndex(of: "--thinking-display")
        #expect(flag.map { thinking[$0 + 1] } == "summarized")
        #expect(thinking.filter { !["--thinking-display", "summarized"].contains($0) } == plain)
    }

    static let refusals = [
        auth(#"{"loggedIn":false,"authMethod":"claude.ai","apiProvider":"firstParty"}"#),
        auth(#"{"loggedIn":true,"authMethod":"apiKey","apiProvider":"firstParty"}"#),
        auth(#"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"bedrock"}"#),
        auth("", status: 1),
    ]

    @Test("Anything but a claude.ai subscription stops the supervisor before any launch")
    func billingGate() throws {
        #expect(subscriptionRefusal(FakeLauncher.subscription) == nil)
        for refusal in Self.refusals {
            let world = SupervisorWorld()
            world.repository("a", number: 1)
            world.launcher.auth = refusal
            world.commands.answers["/work/a"] = [assignment(1)]
            try world.start(["a"])
            world.run(for: 60)
            #expect(world.launcher.started.isEmpty)
            #expect((world.events("stop").first?["reason"] as? String)?.contains("claude") == true)
        }
    }

    // MARK: Classification

    @Test("Each ending is classified from the stream's fields")
    func classifies() {
        let reset = SupervisorWorld.start.addingTimeInterval(3_600)
        func classify(
            _ lines: [String], status: Int32 = 0, signaled: Bool = false, timedOut: Bool = false
        )
            -> ChildOutcome
        {
            classifyChild(
                ChildExit(status: status, signaled: signaled, lines: lines), timedOut: timedOut)
        }
        #expect(classify([result(isError: false)]) == .done)
        #expect(
            classify(
                [
                    rateLimit("rejected", resetsAt: reset.addingTimeInterval(-60)),
                    rateLimit("rejected", resetsAt: reset), result(isError: true, status: 429),
                ], status: 1) == .limit(until: reset))
        #expect(classify([rateLimit("allowed", resetsAt: reset), result(isError: false)]) == .done)
        #expect(classify([], status: SIGKILL, signaled: true, timedOut: true) == .crash)
        #expect(
            classify([result(isError: true, status: 401)], status: 1)
                == .authentication("the API answered 401"))
        #expect(
            classify([result(isError: true, status: 403)], status: 1)
                == .authentication("the API answered 403"))
        #expect(
            classify([result(isError: true, status: 503)], status: 1)
                == .transient("the API answered 503"))
        #expect(
            classify([result(isError: true, status: 529)], status: 1)
                == .transient("the API answered 529"))
        #expect(classify([result(isError: true, status: 429)], status: 1).name == "ambiguous")
        #expect(
            classify([result(isError: true, subtype: "error_max_turns")], status: 1).name
                == "ambiguous")
        #expect(classify([result(isError: false)], status: 1).name == "ambiguous")
        #expect(classify([]) == .ambiguous("no result line"))
        #expect(
            classify(
                [#"{"type":"rate_limit_event","rate_limit_info":{"status":"rejected"}}"#], status: 1
            )
                == .ambiguous("a rejected rate-limit event names no reset"))
        #expect(classify([], status: SIGSEGV, signaled: true).name == "ambiguous")
    }

    @Test("Only result and rate-limit lines are kept")
    func keepsReadLines() {
        #expect(isReadLine(result(isError: false)))
        #expect(isReadLine(rateLimit("allowed", resetsAt: SupervisorWorld.start)))
        #expect(!isReadLine(#"{"type":"assistant","message":{}}"#))
        #expect(!isReadLine("not json"))
    }

    // MARK: The thinking flag refused

    /// The two forms `claude` 2.1.316 refuses an option with, recorded with a
    /// misspelt name and value.
    static let thinkingRejections = [
        "error: unknown option '--thinking-display'",
        "error: option '--thinking-display <display>' argument 'summarized' is invalid. "
            + "Allowed choices are omitted, summarized.",
    ]
    static let otherStartupError = "error: unknown option '--permission-prompts'"

    @Test("Only a startup option error naming --thinking-display is a refused flag")
    func recognisesRejection() {
        func exit(
            _ firstError: String?, status: Int32 = 1, signaled: Bool = false,
            lines: [String] = []
        ) -> ChildExit {
            ChildExit(status: status, signaled: signaled, lines: lines, firstError: firstError)
        }
        for line in Self.thinkingRejections {
            #expect(rejectedThinkingFlag(exit(line)))
            #expect(!rejectedThinkingFlag(exit(line, status: 0)))
            #expect(!rejectedThinkingFlag(exit(line, status: SIGTERM, signaled: true)))
            #expect(!rejectedThinkingFlag(exit(line, lines: [result(isError: true)])))
            #expect(!rejectedThinkingFlag(exit("warning: " + line)))
        }
        #expect(!rejectedThinkingFlag(exit(Self.otherStartupError)))
        #expect(!rejectedThinkingFlag(exit(nil)))
    }

    @Test(
        "A refused flag relaunches the child once without it, warns once, and drops it for the run",
        arguments: thinkingRejections)
    func thinkingFallback(_ rejection: String) throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        world.launcher.endings = [([], 1)]
        world.launcher.firstErrors = [rejection]
        world.commands.answers["/work/a"] = [assignment(1), assignment(1, head: "c1")]
        try world.start(["a"])
        world.run(for: 125)
        #expect(world.launcher.started.map(\.thinkingSummaries) == [true, false])
        let warnings = world.events("thinking-unavailable")
        #expect(warnings.count == 1)
        #expect(warnings.first?["detail"] as? String == rejection)
        #expect(warnings.first?["repository"] as? String == "example-org/a")
        #expect(world.events("child-exit").isEmpty)
        #expect(world.events("launch").count == 2)
        #expect(world.commands.nextCalls.count == 1)

        world.run(for: 400)
        #expect(world.events("child-exit").map { $0["outcome"] as? String } == ["done", "done"])
        #expect(world.launcher.started.map(\.thinkingSummaries) == [true, false, false])
        #expect(world.events("thinking-unavailable").count == 1)
        #expect(world.events("pause").isEmpty && world.events("parked").isEmpty)
    }

    @Test("The relaunched child failing the same way is classified as any ending is")
    func relaunchClassified() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        world.launcher.endings = [([], 1), ([], 1)]
        world.launcher.firstErrors = Array(repeating: Self.thinkingRejections[0], count: 2)
        world.commands.answers["/work/a"] = [assignment(1)]
        try world.start(["a"])
        world.run(for: 300)
        #expect(world.launcher.started.count == 2)
        #expect(world.events("thinking-unavailable").count == 1)
        let exit = try #require(world.events("child-exit").first)
        #expect(exit["outcome"] as? String == "ambiguous")
        #expect(exit["detail"] as? String == "no result line")
        #expect(world.events("pause").count == 1)
    }

    @Test("Another startup error, or a child that wrote a result, is classified as before")
    func otherEndingsUnchanged() throws {
        for (lines, firstError, outcome) in [
            ([String](), Self.otherStartupError, "ambiguous"),
            ([result(isError: true, status: 503)], Self.thinkingRejections[0], "transient"),
        ] {
            let world = SupervisorWorld()
            world.repository("a", number: 1)
            world.launcher.endings = [(lines, 1)]
            world.launcher.firstErrors = [firstError]
            world.commands.answers["/work/a"] = [assignment(1)]
            try world.start(["a"])
            world.run(for: 150)
            #expect(world.launcher.started.count == 1)
            #expect(world.events("thinking-unavailable").isEmpty)
            #expect(world.events("child-exit").map { $0["outcome"] as? String } == [outcome])
        }
    }

    // MARK: What each ending does

    @Test("A subscription limit pauses every launch and next call until the latest reset")
    func limitPauses() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        let reset = SupervisorWorld.start.addingTimeInterval(60 * 60)
        world.launcher.endings = [([rateLimit("rejected", resetsAt: reset)], 1)]
        world.commands.answers["/work/a"] = [assignment(1), assignment(1, head: "c1")]
        try world.start(["a"])
        world.run(for: 59 * 60)
        #expect(world.commands.nextCalls.count == 1)
        #expect(world.events("pause").first?["reason"] as? String == "subscription limit")
        world.run(for: 2 * 60)
        #expect(world.commands.nextCalls.count == 2)
        #expect(world.launcher.started.count == 2)
    }

    @Test("An ambiguous ending pauses the login 30 minutes, doubling to 4 hours; done resets it")
    func ambiguityPauses() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        world.launcher.duration = 1
        let unclear = ([result(isError: true, subtype: "error_during_execution")], Int32(1))
        world.launcher.endings =
            Array(repeating: unclear, count: 6) + [([FakeLauncher.done], 0), unclear]
        world.commands.answers["/work/a"] = (0..<8).map { assignment(1, head: "c\($0)") }
        try world.start(["a"])
        world.run(for: 16 * 60 * 60)
        let pauses = world.events("pause").compactMap { $0["until"] as? String }
            .compactMap { ISO8601DateFormatter().date(from: $0) }
        let launches = world.events("child-exit").count
        #expect(launches == 8)
        #expect(pauses.count == 7)
        // Each pause starts a second after its child launched.
        let starts = world.launcher.children.map { $0.exitAt! }
        let lengths = zip(starts, pauses).map { Int($1.timeIntervalSince($0) / 60) }
        #expect(lengths == [30, 60, 120, 240, 240, 240, 30])
    }

    @Test("A transient API failure backs the repository off")
    func transientBacksOff() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        world.launcher.endings = [([result(isError: true, status: 503)], 1)]
        world.commands.answers["/work/a"] = [assignment(1), assignment(1, head: "c1")]
        try world.start(["a"])
        world.run(for: 150)
        #expect(world.events("child-exit").first?["outcome"] as? String == "transient")
        #expect(world.events("backoff").first?["seconds"] as? Int == 60)
        #expect(world.events("pause").isEmpty)
    }

    @Test(
        "An authentication failure, or a login lost during an unclear ending, stops the supervisor")
    func authenticationStops() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        world.launcher.endings = [([result(isError: true, status: 401)], 1)]
        world.commands.answers["/work/a"] = [assignment(1)]
        try world.start(["a"])
        world.run(for: 150)
        #expect(
            (world.events("stop").first?["reason"] as? String)?.contains("authentication") == true)

        let lost = SupervisorWorld()
        lost.repository("a", number: 1)
        lost.launcher.endings = [([], 1)]
        lost.commands.answers["/work/a"] = [assignment(1)]
        lost.launcher.onStart = { _ in lost.launcher.auth = Self.refusals[0] }
        try lost.start(["a"])
        lost.run(for: 150)
        #expect(lost.events("child-exit").first?["outcome"] as? String == "authentication")
        #expect(lost.events("stop").count == 1)
    }

    @Test("Each child's exit event carries its usage")
    func logsUsage() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        world.commands.answers["/work/a"] = [assignment(1)]
        try world.start(["a"])
        world.run(for: 150)
        let exit = try #require(world.events("child-exit").first)
        #expect(exit["outcome"] as? String == "done")
        #expect(exit["num_turns"] as? Int == 3)
        #expect(exit["total_cost_usd"] as? Double == 0.5)
        #expect(exit["duration_ms"] as? Int == 1000)
        #expect((exit["usage"] as? [String: Any])?["input_tokens"] as? Int == 10)
        #expect(exit["modelUsage"] != nil)
    }

    // MARK: Time and signals

    @Test("At the time limit the child's group gets SIGTERM, then SIGKILL after the grace")
    func timeLimit() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        world.launcher.duration = nil
        world.launcher.endings = [([], 0)]
        world.launcher.ignoresTerm = true
        world.commands.answers["/work/a"] = [assignment(1)]
        try world.start(["a"])
        world.run(for: 2 * 60 * 60 + 5)
        let child = try #require(world.launcher.children.first)
        #expect(child.signals == [SIGTERM])
        world.run(for: 30)
        #expect(child.signals == [SIGTERM, SIGKILL])
        world.run(for: 2)
        let exit = try #require(world.events("child-exit").first)
        #expect(exit["outcome"] as? String == "crash")
        for field in ["usage", "modelUsage", "num_turns", "duration_ms", "total_cost_usd"] {
            #expect(exit[field] is NSNull, "\(field) is null with no result line")
        }
        #expect(world.events("backoff").first?["seconds"] as? Int == 60)
    }

    @Test("A GitHub pause holds no part of the time limit, and the child's exit reads no page")
    func timeLimitDuringPause() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        world.launcher.duration = nil
        world.launcher.ignoresTerm = true
        world.commands.answers["/work/a"] = [assignment(1)]
        try world.start(["a"])
        world.run(for: 2 * 60 * 60 - 120)
        world.github.override = CheckResponse(
            status: 429, headers: ["retry-after": "3600"], body: "")
        world.run(for: 60)
        try #require(world.events("secondary-limit").count == 1)
        let requests = world.github.requests.count
        let child = try #require(world.launcher.children.first)
        world.run(for: 65)
        #expect(child.signals == [SIGTERM])
        world.run(for: 30)
        #expect(child.signals == [SIGTERM, SIGKILL])
        world.run(for: 2)
        #expect(world.events("child-exit").first?["outcome"] as? String == "crash")
        #expect(world.github.requests.count == requests)
    }

    @Test("A signal to the supervisor reaches the child before the supervisor stops")
    func forwardsSignals() throws {
        for ignores in [false, true] {
            let world = SupervisorWorld()
            world.repository("a", number: 1)
            world.launcher.duration = nil
            world.launcher.ignoresTerm = ignores
            world.commands.answers["/work/a"] = [assignment(1)]
            world.signalAt = SupervisorWorld.start.addingTimeInterval(60)
            try world.start(["a"])
            world.run(for: 120)
            let child = try #require(world.launcher.children.first)
            #expect(child.signals == (ignores ? [SIGTERM, SIGKILL] : [SIGTERM]))
            #expect(
                world.events("stop").first?["reason"] as? String == "received signal \(SIGTERM)")
        }
    }

    // MARK: The real child

    private func waitForExit(_ child: SpawnedChild) -> ChildExit? {
        for _ in 0..<200 {
            if let exit = child.exit { return exit }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
    }

    @Test("A spawned child runs in its own directory and process group, keeping only read lines")
    func spawnsChild() throws {
        let directory = FileManager.default.temporaryDirectory.path
        let child = try SpawnedChild(
            command: [
                "sh", "-c",
                #"pwd >&2; printf '%s\n' '{"type":"assistant"}' '{"type":"result","is_error":false}'"#,
            ],
            directory: directory, environment: ["PATH": "/usr/bin:/bin"])
        #expect(getpgid(child.pid) == child.pid || child.exit != nil)
        let exit = try #require(waitForExit(child))
        #expect(
            exit
                == ChildExit(
                    status: 0, signaled: false, lines: [#"{"type":"result","is_error":false}"#],
                    firstError: directory))
    }

    @Test("A spawned child passes on Claude's text and keeps it out of the read lines")
    func spawnedChildText() throws {
        final class Collected: @unchecked Sendable {
            let lock = NSLock()
            var pieces: [ClaudeStream] = []
        }
        let collected = Collected()
        let delta =
            #"{"type":"stream_event","parent_tool_use_id":null,"event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}}"#
        let child = try SpawnedChild(
            command: ["printf", "%s\n", delta, #"{"type":"result","is_error":false}"#],
            directory: "/", environment: ["PATH": "/usr/bin:/bin"],
            onStream: { piece in
                collected.lock.lock()
                collected.pieces.append(piece)
                collected.lock.unlock()
            })
        let exit = try #require(waitForExit(child))
        #expect(exit.lines == [#"{"type":"result","is_error":false}"#])
        collected.lock.lock()
        defer { collected.lock.unlock() }
        #expect(collected.pieces == [.text("Hi")])
    }

    @Test("The child's stderr is a pipe read by line, and its first line is kept")
    func spawnedChildErrors() throws {
        final class Lines: @unchecked Sendable {
            let lock = NSLock()
            var lines: [String] = []
        }
        let collected = Lines()
        let command = ["sh", "-c", "test -p /dev/fd/2 && echo pipe >&2; printf two >&2"]
        let piped = try SpawnedChild(
            command: command, directory: "/", environment: ["PATH": "/usr/bin:/bin"],
            onError: { line in
                collected.lock.lock()
                collected.lines.append(line)
                collected.lock.unlock()
            })
        let exit = try #require(waitForExit(piped))
        collected.lock.lock()
        #expect(collected.lines == ["pipe", "two"])
        collected.lock.unlock()
        #expect(exit.firstError == "pipe")

        let silent = try SpawnedChild(
            command: ["true"], directory: "/", environment: ["PATH": "/usr/bin:/bin"])
        #expect(try #require(waitForExit(silent)).firstError == nil)
    }

    @Test("A command run or refused leaves no descriptor open")
    func commandsCloseTheirPipes() {
        func openDescriptors() -> Int {
            (0..<getdtablesize()).filter { fcntl($0, F_GETFD) != -1 }.count
        }
        // A leak opens two per command, and other tests running alongside
        // hold far fewer than this many at once.
        let commands = 100
        // Linux's Foundation leaks its own socket pair when it refuses a
        // launch, so only Darwin is asked to refuse.
        #if canImport(Darwin)
            let directories = ["/", "/nonexistent-\(UUID().uuidString)"]
        #else
            let directories = ["/"]
        #endif
        let before = openDescriptors()
        for index in 0..<commands {
            _ = ProcessCommands().run(["true"], in: directories[index % directories.count])
        }
        #expect(openDescriptors() - before < commands)
    }

    @Test("A signal reaches the spawned child's group")
    func signalsSpawnedChild() throws {
        let child = try SpawnedChild(
            command: ["sleep", "30"], directory: "/", environment: ["PATH": "/usr/bin:/bin"])
        #expect(getpgid(child.pid) == child.pid)
        child.signal(SIGTERM)
        let exit = try #require(waitForExit(child))
        #expect(exit == ChildExit(status: SIGTERM, signaled: true, lines: []))
    }

    // MARK: No progress

    @Test("The same assignment back twice with nothing changed parks only that repository")
    func parksStuckAssignment() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        world.repository("b", number: 2)
        world.commands.answers["/work/a"] = Array(repeating: assignment(1), count: 5)
        world.commands.answers["/work/b"] = [Self.later, assignment(2)]
        try world.start(["a", "b"])
        world.run(for: 30 * 60)
        #expect(world.launcher.started.filter { $0.path == "/work/a" }.count == 2)
        let parked = try #require(world.events("parked").first)
        #expect(parked["repository"] as? String == "example-org/a")
        #expect(parked["results"] as? [String] == ["done", "done"])
        #expect(world.commands.nextCalls.filter { $0 == "/work/a" }.count == 3)
        #expect(world.launcher.started.contains { $0.path == "/work/b" })
    }

    static let later = FakeCommands.idle

    @Test("Checks or mergeability changing under an unmoved head is no progress")
    func pullRequestStateIsNotProgress() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        world.commands.answers["/work/a"] = [
            assignment(1, checks: "pending", mergeable: "null"), assignment(1, checks: "green"),
            assignment(1, checks: "red", mergeable: "false"),
        ]
        try world.start(["a"])
        world.run(for: 20 * 60)
        #expect(world.launcher.started.count == 2)
        #expect(world.events("parked").count == 1)
    }

    @Test("A moved head or an answered finding is progress")
    func pullRequestProgress() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        world.commands.answers["/work/a"] = [
            assignment(1, head: "c0"), assignment(1, head: "c0"), assignment(1, head: "c1"),
            assignment(1, head: "c1", findings: ["u1"]),
            assignment(1, head: "c1", findings: ["u1"]),
            assignment(1, head: "c1"),
        ]
        try world.start(["a"])
        world.run(for: 20 * 60)
        #expect(world.launcher.started.count == 6)
        #expect(world.events("parked").isEmpty)
    }

    @Test("A branch or commit in a workspace, or a change to the working tree, is progress")
    func gitProgress() throws {
        let branches = SupervisorWorld()
        branches.repository("a", number: 1)
        branches.commands.answers["/work/a"] = Array(repeating: assignment(1), count: 4)
        branches.launcher.onStart = { index in
            branches.commands.refs["/work/tools"] = "refs/heads/f/1-supervisor c\(index)\n"
        }
        try branches.supervisor.start(paths: ["/work/a", "/work/tools"])
        branches.run(for: 20 * 60)
        #expect(branches.launcher.started.count == 4)
        #expect(branches.events("parked").isEmpty)

        let tree = SupervisorWorld()
        tree.repository("a", number: 1)
        tree.commands.heads["/work/a"] = "f/1-supervisor"
        tree.commands.answers["/work/a"] = Array(repeating: assignment(1), count: 4)
        tree.launcher.onStart = { index in tree.commands.diffs["/work/a"] = "diff \(index)" }
        try tree.start(["a"])
        tree.run(for: 20 * 60)
        #expect(tree.launcher.started.count == 4)
        #expect(tree.events("parked").isEmpty)
    }

    @Test("A workspace that can't be fetched backs the repository off before any launch")
    func workspaceFetchFails() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        world.commands.answers["/work/a"] = [assignment(1), assignment(1)]
        try world.supervisor.start(paths: ["/work/a", "/work/tools"])
        world.commands.failingFetches = ["/work/tools"]
        world.run(for: 30)
        #expect(world.launcher.started.isEmpty)
        let error = try #require(world.events("error").first)
        #expect((error["message"] as? String)?.contains("/work/tools") == true)
        #expect(error["retry"] as? Bool == true)
        #expect(world.events("backoff").count == 1)

        world.commands.failingFetches = []
        world.run(for: 120)
        #expect(world.launcher.started.count == 1)
    }

    @Test("MERGE lines left alone twice are set aside; a changed set is new work")
    func setsAsideMerges() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        world.commands.answers["/work/a"] = [merge, merge, merge, merge, otherMerge]
        try world.start(["a"])
        world.run(for: 25 * 60)
        #expect(world.events("set-aside").count == 1)
        #expect(world.launcher.started.map(\.reason) == ["merge", "merge", "merge"])
        #expect(world.commands.nextCalls.count == 5)
    }

    // MARK: Git evidence

    /// A clone on `f/7-work` with one committed file.
    private func issueClone() throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("tickwork-evidence-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try "committed\n".write(toFile: "\(path)/tracked", atomically: true, encoding: .utf8)
        for command in [
            ["init", "-q", "-b", "f/7-work"], ["add", "tracked"],
            ["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", "c"],
        ] {
            let result = ProcessCommands().run(["git"] + command, in: path)
            try #require(result.status == 0, "\(result.errors)")
        }
        return path
    }

    @Test("Git evidence is stable, digests only, and moves with each working-tree change")
    func gitEvidence() throws {
        let path = try issueClone()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let commands = ProcessCommands()
        func evidence() throws -> String { try gitState(of: 7, in: path, commands: commands) }
        func write(_ text: String, _ name: String) throws {
            try text.write(toFile: "\(path)/\(name)", atomically: true, encoding: .utf8)
        }

        let clean = try evidence()
        #expect(try evidence() == clean)
        let digest = #"[0-9a-f]{64}"#
        #expect(clean.contains(try Regex(#"diff \#(digest)\n"#)))
        #expect(clean.contains(try Regex(#"\nuntracked \#(digest) \#(digest)$"#)))

        try write("secret-in-tracked\n", "tracked")
        let edited = try evidence()
        #expect(edited != clean)
        try write("secret-in-untracked\n", "new file")
        let untracked = try evidence()
        #expect(untracked != edited)
        try write("other-secret\n", "new file")
        let rewritten = try evidence()
        #expect(rewritten != untracked)
        try FileManager.default.moveItem(atPath: "\(path)/new file", toPath: "\(path)/renamed")
        let renamed = try evidence()
        #expect(renamed != rewritten)
        try write("ignored\n", ".git/info/exclude")
        try write("secret-in-ignored\n", "ignored")
        #expect(try evidence() == renamed)

        let retained = try evidence()
        for content in ["secret", "renamed", "new file"] { #expect(!retained.contains(content)) }
    }

    @Test("A nested repository or a symbolic link git can't hash is counted by name")
    func unhashableUntracked() throws {
        let path = try issueClone()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let commands = ProcessCommands()
        func evidence() throws -> String { try gitState(of: 7, in: path, commands: commands) }
        let files = FileManager.default

        let clean = try evidence()
        try files.createDirectory(atPath: "\(path)/Nested", withIntermediateDirectories: false)
        try #require(commands.run(["git", "init", "-q"], in: "\(path)/Nested").status == 0)
        let nested = try evidence()
        #expect(nested != clean)
        try files.createSymbolicLink(atPath: "\(path)/to-directory", withDestinationPath: "Nested")
        let linkedDirectory = try evidence()
        #expect(linkedDirectory != nested)
        try files.createSymbolicLink(atPath: "\(path)/dangling", withDestinationPath: "nowhere")
        let dangling = try evidence()
        #expect(dangling != linkedDirectory)
        try "new\n".write(toFile: "\(path)/beside", atomically: true, encoding: .utf8)
        let beside = try evidence()
        #expect(beside != dangling)
        try "rewritten\n".write(toFile: "\(path)/beside", atomically: true, encoding: .utf8)
        #expect(try evidence() != beside)
    }

    @Test("A missing or failing hasher, or a failing git command, is an error")
    func digestFailures() throws {
        let path = try issueClone()
        defer { try? FileManager.default.removeItem(atPath: path) }
        for hasher in [["tickwork-no-such-hasher"], ["true"], ["false"]] {
            #expect(throws: SupervisorStop.self) {
                try gitState(of: 7, in: path, commands: ProcessCommands(hasher: hasher))
            }
        }
        #expect(throws: BoardError.self) {
            try ProcessCommands().sha256(ofOutput: ["git", "diff", "no-such-revision"], in: path)
        }
    }

    @Test("Git state that can't be digested stops the supervisor before a launch")
    func undigestableStops() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        world.commands.heads["/work/a"] = "f/1-supervisor"
        world.commands.undigestable = ["/work/a"]
        world.commands.answers["/work/a"] = [assignment(1)]
        try world.start(["a"])
        world.run(for: 60)
        #expect(world.launcher.started.isEmpty)
        #expect(
            (world.events("stop").first?["reason"] as? String)?.contains("can't be digested")
                == true)
    }
}
