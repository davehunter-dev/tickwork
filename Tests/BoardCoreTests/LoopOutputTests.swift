import Foundation
import Testing

@testable import BoardCore

private func delta(_ text: String, parent: String? = nil) -> String {
    let parentField = parent.map { "\"\($0)\"" } ?? "null"
    return #"{"type":"stream_event","parent_tool_use_id":"#
        + parentField
        + #","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"#
        + "\"\(text)\"}}}"
}

private let blockStop =
    #"{"type":"stream_event","parent_tool_use_id":null,"event":{"type":"content_block_stop","index":0}}"#

/// A renderer at a fixed time in UTC, and everything it wrote.
private final class Screen {
    var written = ""
    lazy var output = HumanOutput(
        styled: styled, timeZone: TimeZone(identifier: "UTC")!, now: { SupervisorWorld.start },
        write: { [unowned self] in written += $0 })
    let styled: Bool
    init(styled: Bool = false) { self.styled = styled }

    func show(_ events: [[String: Any]]) { events.forEach(output.event) }
    var lines: [String] { written.split(separator: "\n").map(String.init) }
}

private let repository = "example-org/a"

// Recorded with `claude` 2.1.316 and the child's flags in /private/tmp/probe, with
// fields Tickwork doesn't read removed.
private let probe = "/private/tmp/probe"
private let recordedCall =
    #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_01GKi3u5GfX5dnAKtUZH9JLG","name":"Bash","input":{"command":"echo hi","description":"Say hi"}}]},"parent_tool_use_id":null}"#
private let recordedRead =
    #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_019C98eq8aQvHN4HLXi1RdGP","name":"Read","input":{"file_path":"/private/tmp/probe/notes.txt"}}]},"parent_tool_use_id":null}"#
private let recordedSubagentCall =
    #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_01XvnJjw5sxSQEb4veAe7Kx9","name":"Bash","input":{"command":"grep -n \"line\" /private/tmp/probe/notes.txt; echo \"---\"; wc -l < /private/tmp/probe/notes.txt","description":"Search notes.txt for \"line\" and count total lines"}}]},"parent_tool_use_id":"toolu_018e4r3G8R8FtFZoFrqKuqEJ","agent_id":"a2add25643cd78a53"}"#
private let recordedFailure =
    #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"Exit code 2\n\"/definitely/missing\": No such file or directory (os error 2)","is_error":true,"tool_use_id":"toolu_012yHUb3QzbdVkZzeWs5MAmG"}]},"parent_tool_use_id":null}"#
private let recordedSuccess =
    #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_01GKi3u5GfX5dnAKtUZH9JLG","type":"tool_result","content":"hi","is_error":false}]},"parent_tool_use_id":null}"#
private let recordedReadResult =
    #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_019C98eq8aQvHN4HLXi1RdGP","type":"tool_result","content":"1\tline one\n2\tline two\n3\t"}]},"parent_tool_use_id":null}"#
/// A subagent's result with array content, as recorded, but failed.
private let arrayFailure =
    #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_01WXdrGW4Tru77jpYL96oze6","type":"tool_result","content":[{"type":"text","text":"Permission denied\n\nby the classifier"},{"type":"image","source":{}},{"type":"text","text":"try again"}],"is_error":true}]},"parent_tool_use_id":"toolu_018e4r3G8R8FtFZoFrqKuqEJ","agent_id":"a2add25643cd78a53"}"#
private let recordedTaskEnd =
    #"{"type":"system","subtype":"task_notification","task_id":"a2add25643cd78a53","tool_use_id":"toolu_018e4r3G8R8FtFZoFrqKuqEJ","status":"completed","usage":{"total_tokens":17895,"tool_uses":3,"duration_ms":6900}}"#
private let quietLines = [
    #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":""}]},"parent_tool_use_id":null}"#,
    #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Steps 1–4 ran in order."}]},"parent_tool_use_id":null}"#,
    #"{"type":"system","subtype":"task_started","task_id":"a2add25643cd78a53","tool_use_id":"toolu_018e4r3G8R8FtFZoFrqKuqEJ","description":"Count lines","subagent_type":"general-purpose","task_type":"local_agent"}"#,
    #"{"type":"system","subtype":"task_progress","task_id":"a2add25643cd78a53","tool_use_id":"toolu_018e4r3G8R8FtFZoFrqKuqEJ","description":"Reading notes.txt","usage":{"total_tokens":16001,"tool_uses":1,"duration_ms":3693},"last_tool_name":"Read"}"#,
    #"{"type":"system","subtype":"thinking_tokens","estimated_tokens":50,"estimated_tokens_delta":50}"#,
    #"{"type":"system","subtype":"status","status":"requesting"}"#,
    #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"command\": \"echo hi\""}},"parent_tool_use_id":null}"#,
]

// Recorded with `claude` 2.1.316, the child's flags and `--thinking-display
// summarized`, with fields Tickwork doesn't read removed: a thinking block's
// first deltas, its signature and end, then the reply.
private let recordedThinking = [
    #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"I'm working out the T","estimated_tokens":null}},"parent_tool_use_id":null}"#,
    #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"ribonacci sequence values","estimated_tokens":null}},"parent_tool_use_id":null}"#,
    #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":" up","estimated_tokens":null}},"parent_tool_use_id":null}"#,
    #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"elided"}},"parent_tool_use_id":null}"#,
    #"{"type":"stream_event","event":{"type":"content_block_stop","index":0},"parent_tool_use_id":null}"#,
    #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"927"}},"parent_tool_use_id":null}"#,
    #"{"type":"stream_event","event":{"type":"content_block_stop","index":1},"parent_tool_use_id":null}"#,
]

/// The recorded stream as it is without the flag: every thinking delta empty.
private let thinkingWithoutFlag = recordedThinking.map {
    $0.replacingOccurrences(
        of: #""thinking":"[^"]*""#, with: #""thinking":"""#, options: .regularExpression)
}

private func call(_ input: [String: Any], name: String = "Tool", parent: String? = nil) -> String {
    let message: [String: Any] = [
        "type": "assistant", "parent_tool_use_id": parent ?? NSNull(),
        "message": ["content": [["type": "tool_use", "name": name, "input": input]]],
    ]
    let data = try! JSONSerialization.data(withJSONObject: message)
    return String(decoding: data, as: UTF8.self)
}

private func detail(_ input: [String: Any], directory: String? = nil) -> String? {
    guard case .call(_, let detail, _) = claudeStream(call(input), directory: directory) else {
        Issue.record("not a call")
        return nil
    }
    return detail
}

@Suite("tickwork loop: what it prints")
struct LoopOutputTests {

    @Test("Only the top-level session's text deltas and block ends are Claude's text")
    func readsText() {
        #expect(claudeStream(delta("Hello")) == .text("Hello"))
        #expect(claudeStream(blockStop) == .blockEnd)
        #expect(claudeStream(delta("from a subagent", parent: "toolu_1")) == nil)
        #expect(claudeStream(#"{"type":"assistant","message":{}}"#) == nil)
        #expect(claudeStream(FakeLauncher.done) == nil)
        #expect(claudeStream("not json") == nil)
    }

    @Test("A top-level tool start names its tool, and a rate-limit event its windows")
    func readsActivity() {
        // As `claude` 2.1.316 wrote them.
        let toolStart =
            #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"Bash","input":{}}},"parent_tool_use_id":null}"#
        #expect(claudeStream(toolStart) == .tool("Bash"))
        let subagent = toolStart.replacingOccurrences(
            of: #""parent_tool_use_id":null"#, with: #""parent_tool_use_id":"toolu_0""#)
        #expect(claudeStream(subagent) == nil)
        let textStart =
            #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}},"parent_tool_use_id":null}"#
        #expect(claudeStream(textStart) == nil)
        let usage =
            #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1793740200,"rateLimitType":"five_hour","unifiedWindows":{"seven_day":{"utilization":0.15,"resetsAt":1794031200,"status":"allowed"},"five_hour":{"utilization":0.904,"resetsAt":1793740200,"status":"allowed_warning"}}}}"#
        #expect(
            claudeStream(usage)
                == .windows([
                    .init(name: "five_hour", percent: 90, status: .allowedWarning),
                    .init(name: "seven_day", percent: 15, status: .allowed),
                ]))
        #expect(isReadLine(usage))
    }

    @Test("Claude's text streams as it arrives, and a supervisor line starts on its own")
    func streamsText() {
        let screen = Screen()
        screen.output.claude(.text("Reading "))
        screen.output.claude(.text("the board."))
        #expect(screen.written == "Reading the board.")
        screen.output.claude(.blockEnd)
        screen.output.claude(.text("Done"))
        screen.show([
            [
                "event": "child-exit", "repository": repository, "outcome": "done", "num_turns": 3,
                "duration_ms": 95_000,
            ]
        ])
        #expect(
            screen.lines == [
                "Reading the board.", "Done",
                "12:00:00 example-org/a: Claude finished (3 turns, 1m 35s)",
            ])
    }

    @Test("Top-level thinking deltas are read; empty ones and a subagent's are not")
    func readsThinking() {
        #expect(
            recordedThinking.map { claudeStream($0) } == [
                .thinking("I'm working out the T"), .thinking("ribonacci sequence values"),
                .thinking(" up"), nil, .blockEnd, .text("927"), .blockEnd,
            ])
        #expect(thinkingWithoutFlag.prefix(3).allSatisfy { claudeStream($0) == nil })
        let subagent = recordedThinking[0].replacingOccurrences(
            of: #""parent_tool_use_id":null"#, with: #""parent_tool_use_id":"toolu_0""#)
        #expect(claudeStream(subagent) == nil)
    }

    @Test("Thinking streams after its lead, dim when styled; empty deltas print nothing")
    func streamsThinking() {
        func render(_ lines: [String], styled: Bool) -> String {
            let screen = Screen(styled: styled)
            lines.compactMap { claudeStream($0) }.forEach(screen.output.claude)
            return screen.written
        }
        // A second block gets its own lead.
        let twice = recordedThinking + recordedThinking.prefix(1) + [recordedThinking[4]]
        #expect(
            render(twice, styled: false)
                == "thinking (summary): I'm working out the Tribonacci sequence values up\n927\n"
                + "thinking (summary): I'm working out the T\n")
        let dim = { (text: String) in "\u{1B}[2m\(text)\u{1B}[0m" }
        #expect(
            render(recordedThinking, styled: true)
                == dim("thinking (summary): I'm working out the T")
                + dim("ribonacci sequence values") + dim(" up") + "\n927\n")
        #expect(render(thinkingWithoutFlag, styled: true) == "927\n")
    }

    @Test("A child that exits mid-thinking leaves the next child's thinking its lead")
    func thinkingEndsWithTheChild() {
        let screen = Screen()
        screen.output.claude(.thinking("Cut off"))
        screen.show([
            ["event": "child-exit", "repository": repository, "outcome": "done"],
            ["event": "launch", "repository": repository, "purpose": "tick"],
        ])
        screen.output.claude(.thinking("Next"))
        screen.output.claude(.blockEnd)
        #expect(screen.lines.first == "thinking (summary): Cut off")
        #expect(screen.lines.last == "thinking (summary): Next")
    }

    @Test("An idle reconciliation and an allowed check print nothing")
    func quiet() {
        let screen = Screen()
        screen.show([
            [
                "event": "reconcile", "repository": repository, "reasons": ["interval"],
                "kind": "idle",
            ],
            [
                "event": "reconcile", "repository": repository, "reasons": ["board changed"],
                "kind": "assignment",
            ],
        ])
        #expect(screen.written.isEmpty)
    }

    @Test("A repeated failure prints once, and its recovery once")
    func coalescesFailures() {
        let screen = Screen()
        let failed: [String: Any] = [
            "event": "check-failed", "repository": repository, "message": "connection reset",
        ]
        screen.show([
            failed, failed, ["event": "backoff", "repository": repository, "seconds": 60], failed,
            ["event": "backoff", "repository": repository, "seconds": 120],
            ["event": "check-recovered", "repository": repository],
            ["event": "check-recovered", "repository": repository], failed,
        ])
        #expect(
            screen.lines == [
                "12:00:00 example-org/a: board check failed: connection reset",
                "12:00:00 example-org/a: backing off, retrying in 1m",
                "12:00:00 example-org/a: board checks recovered",
                "12:00:00 example-org/a: board check failed: connection reset",
            ])
    }

    @Test("A failing next prints once until a reconciliation succeeds")
    func nextRecovers() {
        let screen = Screen()
        let error: [String: Any] = [
            "event": "error", "repository": repository, "message": "fetch failed", "retry": true,
        ]
        screen.show([
            error, ["event": "backoff", "repository": repository, "seconds": 60],
            error, ["event": "backoff", "repository": repository, "seconds": 120],
            ["event": "backoff-cleared", "repository": repository],
            ["event": "reconcile-recovered", "repository": repository],
            ["event": "reconcile-recovered", "repository": repository],
            error, ["event": "backoff", "repository": repository, "seconds": 60],
        ])
        #expect(
            screen.lines == [
                "12:00:00 example-org/a: fetch failed",
                "12:00:00 example-org/a: backing off, retrying in 1m",
                "12:00:00 example-org/a: next answers again",
                "12:00:00 example-org/a: fetch failed",
                "12:00:00 example-org/a: backing off, retrying in 1m",
            ])
    }

    @Test("A Git-state failure after an assignment prints once, and its recovery once")
    func gitStateFailure() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        world.commands.answers["/work/a"] = Array(repeating: assignment(1), count: 4)
        try world.supervisor.start(paths: ["/work/a", "/work/tools"])
        world.commands.failingFetches = ["/work/tools"]
        world.run(for: 6 * 60)
        #expect(world.events("error").count == 3)
        world.commands.failingFetches = []
        world.run(for: 9 * 60)
        #expect(world.launcher.started.count == 1)

        let screen = Screen()
        screen.show(world.events.filter { $0["repository"] as? String == repository })
        #expect(
            Array(screen.lines.prefix(4)) == [
                "12:00:00 example-org/a: fetch of workspace /work/tools failed: "
                    + "not a git repository",
                "12:00:00 example-org/a: backing off, retrying in 1m",
                "12:00:00 example-org/a: next answers again",
                "12:00:00 example-org/a: launching Claude for an assignment",
            ])
    }

    @Test("A watch failure recovers only from its own issue's read, and prints again after")
    func watchRecovers() {
        let screen = Screen()
        let failed: [String: Any] = [
            "event": "watch-failed", "repository": repository, "issue": 5, "message": "timeout",
        ]
        let other: [String: Any] = [
            "event": "watch-failed", "repository": repository, "issue": 6, "message": "timeout",
        ]
        screen.show([
            failed, other, failed,
            ["event": "check-failed", "repository": repository, "message": "reset"],
            ["event": "check-recovered", "repository": repository], failed,
            ["event": "watch-recovered", "repository": repository, "issue": 5], other, failed,
        ])
        #expect(
            screen.lines == [
                "12:00:00 example-org/a: pull requests of #5 unreadable: timeout",
                "12:00:00 example-org/a: pull requests of #6 unreadable: timeout",
                "12:00:00 example-org/a: board check failed: reset",
                "12:00:00 example-org/a: board checks recovered",
                "12:00:00 example-org/a: pull requests of #5 readable again",
                "12:00:00 example-org/a: pull requests of #5 unreadable: timeout",
            ])
    }

    @Test("A backoff the supervisor cleared prints again when it comes back")
    func backoffFollowsSupervisor() {
        let screen = Screen()
        let crash: [[String: Any]] = [
            ["event": "child-exit", "repository": repository, "outcome": "crash", "status": 15],
            ["event": "backoff", "repository": repository, "seconds": 60],
        ]
        screen.show(crash + [["event": "backoff-cleared", "repository": repository]] + crash)
        #expect(
            screen.lines == [
                "12:00:00 example-org/a: Claude was stopped at the time limit",
                "12:00:00 example-org/a: backing off, retrying in 1m",
                "12:00:00 example-org/a: Claude was stopped at the time limit",
                "12:00:00 example-org/a: backing off, retrying in 1m",
            ])
    }

    @Test("Each state change has one line")
    func stateChanges() {
        let screen = Screen()
        screen.show([
            [
                "event": "start", "login": "agent-one", "repositories": ["/work/a"],
                "workspaces": ["/work/t"], "note": "one session per login",
            ],
            ["event": "launch", "repository": repository, "reason": "assignment"],
            ["event": "time-limit", "repository": repository],
            ["event": "child-exit", "repository": repository, "outcome": "crash", "status": 15],
            [
                "event": "child-exit", "repository": repository, "outcome": "ambiguous",
                "status": 1,
                "detail": "no result line",
            ],
            ["event": "pause", "reason": "ambiguous ending", "until": "2026-11-01T12:30:00Z"],
            ["event": "pause", "reason": "subscription limit", "until": "2026-11-02T03:00:00Z"],
            ["event": "secondary-limit", "seconds": 90],
            ["event": "core-limit", "until": "2026-11-01T13:00:00Z"],
            [
                "event": "parked", "repository": repository,
                "work": "#7 engineer start Ready pr none none findings []", "results": ["crash"],
            ],
            [
                "event": "thinking-unavailable", "repository": repository,
                "detail": "error: unknown option '--thinking-display'",
            ],
            [
                "event": "update-failed", "repository": repository,
                "message": "tickwork: fetching Tickwork failed",
            ],
            ["event": "replace", "from": "abc", "to": "def", "tool": "/t/bin/tickwork"],
            ["event": "stop", "reason": "received signal 2"],
        ])
        #expect(
            screen.lines == [
                "12:00:00 Started as agent-one on /work/a; workspaces /work/t. "
                    + "Run no /loop /next-task on agent-one beside this.",
                "12:00:00 example-org/a: launching Claude for an assignment",
                "12:00:00 example-org/a: Claude reached the 2h limit; stopping it",
                "12:00:00 example-org/a: Claude was stopped at the time limit",
                "12:00:00 example-org/a: Claude ended, ambiguous: no result line",
                "12:00:00 Paused for ambiguous ending until 12:30",
                "12:00:00 Paused for subscription limit until Nov 2 03:00",
                "12:00:00 GitHub's secondary rate limit: pausing 1m 30s",
                "12:00:00 GitHub's core rate limit is exhausted: pausing until 13:00",
                "12:00:00 example-org/a: parked #7 engineer start, unchanged after two children; "
                    + "release the claim and restart",
                "12:00:00 example-org/a: Claude rejected --thinking-display; "
                    + "thinking summaries are off until the loop restarts",
                "12:00:00 example-org/a: updating Tickwork failed, so the installed tool runs on: "
                    + "tickwork: fetching Tickwork failed",
                "12:00:00 Replacing tickwork abc with def",
                "12:00:00 Stopped: received signal 2",
            ])
    }

    @Test("A terminal gets colour and a marker; plain text has neither")
    func styling() {
        let launch: [String: Any] = [
            "event": "launch", "repository": repository, "reason": "merge",
        ]
        let styled = Screen(styled: true)
        styled.show([launch])
        #expect(
            styled.written
                == "\u{1B}[2m12:00:00\u{1B}[0m 🚀 \u{1B}[36mexample-org/a: launching Claude to merge\u{1B}[0m\n"
        )
        let plain = Screen()
        plain.show([launch])
        #expect(plain.written == "12:00:00 example-org/a: launching Claude to merge\n")
        #expect(!plain.written.contains("\u{1B}"))
    }

    @Test("Styling needs a terminal and no NO_COLOR")
    func stylingChoice() {
        #expect(loopOutputIsStyled(environment: [:], stdoutIsTerminal: true))
        #expect(!loopOutputIsStyled(environment: ["NO_COLOR": "1"], stdoutIsTerminal: true))
        #expect(loopOutputIsStyled(environment: ["NO_COLOR": ""], stdoutIsTerminal: true))
        #expect(!loopOutputIsStyled(environment: [:], stdoutIsTerminal: false))
    }

    @Test("Tool calls, failed results and task endings are read from recorded lines")
    func readsActivityLines() {
        #expect(
            claudeStream(recordedCall, directory: probe)
                == .call(name: "Bash", detail: "Say hi", subagent: false))
        #expect(
            claudeStream(recordedRead, directory: probe)
                == .call(name: "Read", detail: "notes.txt", subagent: false))
        #expect(
            claudeStream(recordedSubagentCall, directory: probe)
                == .call(
                    name: "Bash", detail: "Search notes.txt for \"line\" and count total lines",
                    subagent: true))
        #expect(
            claudeStream(recordedFailure)
                == .failure(
                    "Exit code 2 · \"/definitely/missing\": No such file or directory (os error 2)",
                    subagent: false))
        #expect(
            claudeStream(arrayFailure)
                == .failure("Permission denied · by the classifier · try again", subagent: true))
        let spacedFailure = recordedFailure.replacingOccurrences(
            of: #""is_error":true"#, with: #""is_error" : true"#)
        #expect(claudeStream(spacedFailure) == claudeStream(recordedFailure))
        #expect(claudeStream(recordedSuccess) == nil)
        #expect(claudeStream(recordedReadResult) == nil)
        #expect(
            claudeStream(recordedTaskEnd)
                == .taskEnd(status: "completed", usage: .init(tools: 3, milliseconds: 6900)))
        let withoutUsage = recordedTaskEnd.replacingOccurrences(
            of: #","usage":{"total_tokens":17895,"tool_uses":3,"duration_ms":6900}"#, with: "")
        #expect(claudeStream(withoutUsage) == .taskEnd(status: "completed", usage: nil))
        for line in quietLines { #expect(claudeStream(line) == nil, "\(line)") }
    }

    @Test("A call's detail is its first string in order, on one line, relative to the clone")
    func callDetails() {
        let keys = ["description", "file_path", "pattern", "url", "query", "skill", "command"]
        for (index, key) in keys.enumerated() {
            let input = Dictionary(uniqueKeysWithValues: keys[index...].map { ($0, "by \($0)") })
            #expect(detail(input) == "by \(key)")
        }
        #expect(detail(["description": 3, "command": "make"]) == "make")
        #expect(
            detail(["command": "swift build \\\n  -c release\n\nswift test"])
                == "swift build \\ -c release swift test")
        #expect(
            detail(["file_path": "/work/a/Sources/Parser.swift"], directory: "/work/a")
                == "Sources/Parser.swift")
        #expect(
            detail(["file_path": "/work/ab/Parser.swift"], directory: "/work/a")
                == "/work/ab/Parser.swift")
        #expect(detail(["command": "cat /work/a/x"], directory: "/work/a") == "cat /work/a/x")
        #expect(detail(["message": "handed back"]) == nil)
        #expect(
            claudeStream(call([:], name: "TaskStop"))
                == .call(name: "TaskStop", detail: nil, subagent: false))
    }

    @Test("Activity lines are indented by depth and cut at the plain log's width, unstyled")
    func activityRows() {
        let screen = Screen()
        screen.output.claude(.call(name: "Bash", detail: "Run the tests", subagent: false))
        screen.output.claude(.failure("", subagent: false))
        screen.output.claude(.call(name: "TaskStop", detail: nil, subagent: true))
        screen.output.claude(.failure("Exit code 1", subagent: true))
        screen.output.claude(.taskEnd(status: "failed", usage: nil))
        screen.output.claude(
            .call(name: "Bash", detail: String(repeating: "x", count: 300), subagent: false))
        let long =
            "  Bash: " + String(repeating: "x", count: HumanOutput.activityLineWidth - 10) + "…"
        #expect(
            screen.lines == [
                "  Bash: Run the tests", "    failed", "    TaskStop", "      failed: Exit code 1",
                "  task failed", long,
            ])
        #expect(displayColumns(long) == HumanOutput.activityLineWidth)
        #expect(!screen.written.contains("\u{1B}"))

        let styled = Screen(styled: true)
        styled.output.claude(
            .taskEnd(status: "completed", usage: .init(tools: 2, milliseconds: 6_000)))
        #expect(styled.written == "  \u{1B}[2mtask completed (2 tools, 6s)\u{1B}[0m\n")
    }

    @Test("An activity line arriving mid-reply ends the partial line first")
    func activityEndsPartialLine() {
        let screen = Screen()
        screen.output.claude(.text("Running the "))
        screen.output.claude(.call(name: "Bash", detail: "Run the tests", subagent: false))
        screen.output.claude(.text("tests passed."))
        screen.output.claude(.blockEnd)
        #expect(screen.written == "Running the \n  Bash: Run the tests\ntests passed.\n")
    }

    @Test("The design's example stream prints the design's transcript")
    func designExample() {
        let clone = "/work/a"
        func text(_ text: String) -> [String] { [delta(text), blockStop] }
        func result(_ content: String, parent: String? = nil) -> String {
            let message: [String: Any] = [
                "type": "user", "parent_tool_use_id": parent ?? NSNull(),
                "message": [
                    "content": [["type": "tool_result", "content": content, "is_error": true]]
                ],
            ]
            return String(
                decoding: try! JSONSerialization.data(withJSONObject: message), as: UTF8.self)
        }
        let agent = "toolu_agent"
        let stream: [String] =
            [
                call(
                    [
                        "command": "gh issue view 42 --comments",
                        "description": "Read the issue and its comments",
                    ], name: "Bash")
            ]
            + text("I'll take #42: the parser drops a trailing newline.")
            + [
                call(["file_path": "\(clone)/Sources/Parser.swift"], name: "Read"),
                call(
                    ["description": "Find every caller of parse(_:)", "prompt": "Find…"],
                    name: "Agent"),
                call(["pattern": #"parse\("#, "path": clone], name: "Grep", parent: agent),
                call(["file_path": "\(clone)/Sources/Loader.swift"], name: "Read", parent: agent),
                recordedTaskEnd.replacingOccurrences(of: "\"tool_uses\":3", with: "\"tool_uses\":2")
                    .replacingOccurrences(of: "6900", with: "6000"),
                call(["file_path": "\(clone)/Sources/Parser.swift"], name: "Edit"),
                call(["command": "swift test", "description": "Run the tests"], name: "Bash"),
                result("Exit code 1\nParser.swift:41: error: expected ';'"),
            ]
            + text("The test caught a missing semicolon; fixing it and running them again.")
            + [
                call(["file_path": "\(clone)/Sources/Parser.swift"], name: "Edit"),
                call(["command": "swift test", "description": "Run the tests"], name: "Bash"),
            ]
        let screen = Screen()
        screen.show([["event": "launch", "repository": repository, "reason": "assignment"]])
        for line in stream {
            if let piece = claudeStream(line, directory: clone) { screen.output.claude(piece) }
        }
        screen.show([
            [
                "event": "child-exit", "repository": repository, "outcome": "done",
                "num_turns": 31, "duration_ms": 321_000,
            ]
        ])
        #expect(
            screen.lines == [
                "12:00:00 example-org/a: launching Claude for an assignment",
                "  Bash: Read the issue and its comments",
                "I'll take #42: the parser drops a trailing newline.",
                "  Read: Sources/Parser.swift",
                "  Agent: Find every caller of parse(_:)",
                #"    Grep: parse\("#,
                "    Read: Sources/Loader.swift",
                "  task completed (2 tools, 6s)",
                "  Edit: Sources/Parser.swift",
                "  Bash: Run the tests",
                "    failed: Exit code 1 · Parser.swift:41: error: expected ';'",
                "The test caught a missing semicolon; fixing it and running them again.",
                "  Edit: Sources/Parser.swift",
                "  Bash: Run the tests",
                "12:00:00 example-org/a: Claude finished (31 turns, 5m 21s)",
            ])
    }

    @Test("Durations read as their two largest units")
    func durations() {
        #expect(duration(0) == "0s")
        #expect(duration(45) == "45s")
        #expect(duration(3_725) == "1h 2m")
        #expect(duration(7_200) == "2h")
    }
}
