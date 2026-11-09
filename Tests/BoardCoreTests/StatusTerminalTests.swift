// The status block on a terminal: what `HumanOutput` writes, applied to a model
// of the screen, is always the committed log followed by one current block. And
// the outputs without a block, `--json` and the plain log, are as they were.
//

import Foundation
import Testing

@testable import BoardCore

private typealias Status = SupervisorStatus

private let utc = TimeZone(identifier: "UTC")!
private let now = SupervisorWorld.start
private let standard = TerminalSize(columns: 80, rows: 24)

/// A terminal's grid under the four controls the block uses: carriage return, line
/// feed (which a terminal's output processing makes a return too), cursor up, and
/// erase to the end of the screen. Text wraps at the width; colour is ignored.
private final class ScreenModel {
    let width: Int
    private var grid: [[Character]] = [[]]
    private var row = 0
    private var column = 0
    private(set) var writes = 0

    init(width: Int) { self.width = width }

    func apply(_ text: String) {
        writes += 1
        var characters = Array(text)[...]
        while let character = characters.popFirst() {
            switch character {
            case "\u{1B}":
                #expect(characters.popFirst() == "[")
                var digits = ""
                while let next = characters.first, next.isNumber {
                    digits.append(characters.removeFirst())
                }
                let count = Int(digits) ?? 1
                switch characters.popFirst() {
                case "A": row = max(row - count, 0)
                case "J":
                    grid[row] = Array(grid[row].prefix(column))
                    grid.removeSubrange((row + 1)...)
                case "m": break
                case let other: Issue.record("unexpected control \(String(describing: other))")
                }
            case "\r":
                column = 0
            case "\n":
                newLine()
            default:
                if column == width { newLine() }
                while grid[row].count < column { grid[row].append(" ") }
                if column < grid[row].count {
                    grid[row][column] = character
                } else {
                    grid[row].append(character)
                }
                column += 1
            }
        }
    }

    private func newLine() {
        row += 1
        column = 0
        if row == grid.count { grid.append([]) }
    }

    /// Every row, without the empty one a cursor at a line's start leaves.
    var lines: [String] {
        let lines = grid.map { String($0) }
        return lines.last == "" ? Array(lines.dropLast()) : lines
    }
}

/// A block-mode output drawing on a screen model, at a fixed time and size.
private final class Terminal {
    let screen: ScreenModel
    var size: TerminalSize?
    lazy var output = HumanOutput(
        styled: false, timeZone: utc, now: { now }, size: { [unowned self] in self.size },
        write: { [unowned self] in screen.apply($0) })

    init(size: TerminalSize? = standard, screen: ScreenModel? = nil) {
        self.size = size
        self.screen = screen ?? ScreenModel(width: standard.columns)
    }

    func text(_ text: String) { output.claude(.text(text)) }
}

private func block(_ status: Status, tool: String? = nil) -> [String] {
    StatusBlock(styled: false, timeZone: utc).lines(
        status, activity: ClaudeActivity(tool: tool), width: standard.columns,
        height: standard.rows, now: now)
}

private func repository(_ name: String, _ state: Status.State) -> Status.Repository {
    .init(
        name: "example-org/\(name)", state: state, error: nil, checked: now, failingSince: nil,
        changed: nil, due: nil, next: .at(now.addingTimeInterval(60)), setAsideMerges: [])
}

private func status(
    _ state: Status.LoginState = .running, child: Bool = false,
    _ repositories: [Status.Repository] = [repository("a", .idle)]
) -> Status {
    .init(
        login: "agent", revision: "a02db1fb0c9d", state: state, core: nil, graphQL: nil,
        child: child
            ? .init(
                repository: "example-org/a", started: now, terminated: nil,
                purpose: .assignment(.init(issue: 41, role: "engineer", task: "start")))
            : nil,
        repositories: repositories)
}

private let idle = status()
private let running = status(child: true, [repository("a", .claude)])
private let stopped = status(.stopped(at: now, reason: "received signal 2"))

nonisolated(unsafe) private let launch: [String: Any] = [
    "event": "launch", "repository": "example-org/a", "reason": "assignment",
]
private let launchLine = "12:00:00 example-org/a: launching Claude for an assignment"

/// A seeded generator, so a failing sequence replays.
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

@Suite("tickwork loop: the status block on a terminal")
struct StatusTerminalTests {

    @Test("A delta split mid-line around a status change stays whole, above one block")
    func splitDelta() {
        let terminal = Terminal()
        terminal.output.status(idle)
        #expect(terminal.screen.lines == block(idle))
        terminal.output.event(launch)
        terminal.text("Reading the ")
        #expect(terminal.screen.lines == [launchLine] + block(idle))
        terminal.output.status(running)
        #expect(terminal.screen.lines == [launchLine] + block(running))
        terminal.text("board.\nNext")
        #expect(terminal.screen.lines == [launchLine, "Reading the board."] + block(running))
        terminal.output.claude(.blockEnd)
        #expect(
            terminal.screen.lines == [launchLine, "Reading the board.", "Next"] + block(running))
    }

    @Test("A paragraph longer than the width is committed a row at a time, at its spaces")
    func longParagraph() {
        let terminal = Terminal()
        terminal.output.status(idle)
        let words = (1...30).map { "word\($0)" }
        terminal.text(words.joined(separator: " "))
        let committed = terminal.screen.lines.dropLast(block(idle).count)
        #expect(committed.count >= 2)
        #expect(committed.allSatisfy { $0.count <= standard.columns && !$0.hasSuffix(" ") })
        terminal.output.claude(.blockEnd)
        let log = Array(terminal.screen.lines.dropLast(block(idle).count))
        #expect(log.joined(separator: " ") == words.joined(separator: " "))
        #expect(terminal.screen.lines.suffix(block(idle).count) == block(idle)[...])
    }

    @Test("A word longer than the width is cut at the width")
    func longWord() {
        let terminal = Terminal()
        terminal.text(String(repeating: "x", count: 90) + "\n")
        #expect(terminal.screen.lines == [String(repeating: "x", count: 80), "xxxxxxxxxx"])
    }

    @Test("The child's stderr waits behind Claude's partial row, then is committed dimmed")
    func childErrors() {
        let terminal = Terminal()
        terminal.output.status(running)
        terminal.output.childError("before")
        terminal.text("Half a ")
        terminal.output.childError("warning: something")
        #expect(terminal.screen.lines == ["before"] + block(running))
        terminal.text("line\nNext")
        terminal.output.claude(.blockEnd)
        #expect(
            terminal.screen.lines
                == ["before", "Half a line", "warning: something", "Next"] + block(running))
    }

    @Test("With the block drawn, thinking rows are dim one by one and end at the block's end")
    func thinkingRows() {
        let screen = ScreenModel(width: standard.columns)
        var raw = ""
        let output = HumanOutput(
            styled: true, timeZone: utc, now: { now }, size: { standard },
            write: {
                raw += $0
                screen.apply($0)
            })
        output.status(running)
        output.claude(.text("Half"))
        output.claude(.thinking(String(repeating: "word ", count: 20)))
        output.childError("warning: something")
        output.claude(.thinking("done"))
        output.claude(.blockEnd)
        output.claude(.text("Reply\n"))
        let lead = "thinking (summary): "
        let first = lead + Array(repeating: "word", count: 12).joined(separator: " ")
        let second = Array(repeating: "word", count: 8).joined(separator: " ") + " done"
        let rows = Array(screen.lines.prefix(5))
        #expect(rows == ["Half", first, second, "warning: something", "Reply"])
        for row in [first, second] { #expect(raw.contains("\u{1B}[2m\(row)\u{1B}[0m\n")) }
        #expect(raw.contains("Reply\n") && !raw.contains("\u{1B}[2mReply"))
    }

    @Test("A child that exits mid-thinking doesn't dim the next child's reply")
    func thinkingEndsWithTheChild() {
        let screen = ScreenModel(width: standard.columns)
        var raw = ""
        let output = HumanOutput(
            styled: true, timeZone: utc, now: { now }, size: { standard },
            write: {
                raw += $0
                screen.apply($0)
            })
        output.status(running)
        output.claude(.thinking("Cut off"))
        output.event(["event": "child-exit", "repository": "example-org/a", "outcome": "done"])
        output.claude(.text("Half"))
        output.event(["event": "child-exit", "repository": "example-org/a", "outcome": "done"])
        output.claude(.thinking("Next"))
        output.claude(.blockEnd)
        #expect(raw.contains("\u{1B}[2mthinking (summary): Cut off\u{1B}[0m\n"))
        #expect(raw.contains("Half\n") && !raw.contains("\u{1B}[2mHalf"))
        #expect(raw.contains("\u{1B}[2mthinking (summary): Next\u{1B}[0m\n"))
    }

    @Test("An event waits behind Claude's partial row; the child's exit commits both")
    func eventsWait() {
        let terminal = Terminal()
        terminal.output.status(running)
        terminal.text("Half a ")
        terminal.output.event(["event": "secondary-limit", "seconds": 60])
        let paused = "12:00:00 GitHub's secondary rate limit: pausing 1m"
        #expect(terminal.screen.lines == block(running))
        terminal.text("line\n")
        #expect(terminal.screen.lines == ["Half a line", paused] + block(running))

        terminal.text("Cut off")
        terminal.output.childError("killed")
        terminal.output.event([
            "event": "child-exit", "repository": "example-org/a", "outcome": "done",
        ])
        #expect(
            terminal.screen.lines
                == [
                    "Half a line", paused, "Cut off", "killed",
                    "12:00:00 example-org/a: Claude finished",
                ]
                + block(running))
    }

    @Test("A tool start redraws the block naming it; the child's exit clears it")
    func tool() {
        let terminal = Terminal()
        terminal.output.status(running)
        terminal.output.claude(.tool("Bash"))
        #expect(terminal.screen.lines == block(running, tool: "Bash"))
        #expect(terminal.screen.lines.contains { $0.contains("Bash") })
        terminal.output.event([
            "event": "child-exit", "repository": "example-org/a", "outcome": "done",
        ])
        terminal.output.status(idle)
        #expect(terminal.screen.lines == ["12:00:00 example-org/a: Claude finished"] + block(idle))
    }

    @Test("A stop erases the block, prints the stop line, then the last block as lines")
    func stop() {
        let terminal = Terminal()
        terminal.output.status(running)
        terminal.text("Partial")
        terminal.output.event(["event": "stop", "reason": "received signal 2"])
        #expect(terminal.screen.lines == ["Partial", "12:00:00 Stopped: received signal 2"])
        terminal.output.status(stopped)
        #expect(
            terminal.screen.lines
                == ["Partial", "12:00:00 Stopped: received signal 2"] + block(stopped))
        #expect(terminal.screen.lines.contains("STOPPED at 12:00:00 · agent · tickwork a02db1fb"))
        let writes = terminal.screen.writes
        terminal.output.status(idle)
        #expect(terminal.screen.writes == writes)
    }

    @Test("A replacement erases the block, and the new process draws its own below")
    func replacement() {
        let terminal = Terminal()
        terminal.output.status(idle)
        terminal.output.event(["event": "replace", "from": "abc", "to": "def", "tool": "t"])
        let replaced = "12:00:00 Replacing tickwork abc with def"
        #expect(terminal.screen.lines == [replaced])
        let writes = terminal.screen.writes
        terminal.output.status(idle)
        #expect(terminal.screen.writes == writes)

        let next = Terminal(screen: terminal.screen)
        next.output.status(running)
        #expect(next.screen.lines == [replaced] + block(running))
    }

    @Test("An unchanged snapshot writes nothing; a changed one or a new width redraws")
    func redrawsOnlyChanges() {
        let terminal = Terminal()
        terminal.output.status(idle)
        #expect(terminal.screen.writes == 1)
        terminal.output.status(idle)
        terminal.output.claude(.tool(""))
        terminal.output.claude(.tool(""))
        #expect(terminal.screen.writes == 1)
        terminal.output.status(running)
        #expect(terminal.screen.writes == 2)
        terminal.output.status(running)
        #expect(terminal.screen.writes == 2)
        terminal.size = TerminalSize(columns: 60, rows: 24)
        terminal.output.status(running)
        #expect(terminal.screen.writes == 3)
    }

    @Test(
        "A size query that fails keeps the last size; one with no first answer gets the plain log")
    func failedSizeQuery() {
        let terminal = Terminal(size: TerminalSize(columns: 60, rows: 24))
        terminal.output.status(idle)
        let writes = terminal.screen.writes
        terminal.size = nil
        terminal.output.status(idle)
        #expect(terminal.screen.writes == writes)
        terminal.text(String(repeating: "x", count: 70))
        #expect(terminal.screen.lines.first == String(repeating: "x", count: 60))

        let unmeasured = Terminal(size: nil)
        unmeasured.output.status(running)
        unmeasured.text("Plain")
        #expect(unmeasured.screen.lines == ["Plain"])
        #expect(!unmeasured.output.drawsBlock)
        let (output, written) = output(["TERM": "xterm"], terminal: true, size: nil)
        output.childErrors("warning: something")
        #expect(written.errors == "warning: something\n")
    }

    @Test("After any sequence of events, text, stderr and snapshots, one block ends the screen")
    func anySequence() {
        var random = SplitMix(state: 54)
        let snapshots = [
            idle, running, status(.running, [repository("a", .idle), repository("b", .idle)]),
        ]
        let words = [
            "a", "longer", "word", "of", "text", "—", "über",
            "x" + String(repeating: "y", count: 85),
        ]
        let terminal = Terminal()
        var current: Status?
        var tool: String?
        var log: [String] = []
        for _ in 0..<500 {
            switch Int.random(in: 0..<7, using: &random) {
            case 0, 1:
                let count = Int.random(in: 1...12, using: &random)
                let text = (0..<count).map { _ in words.randomElement(using: &random)! }
                    .joined(separator: " ")
                terminal.text(Bool.random(using: &random) ? text + "\n" : text + " ")
            case 2: terminal.output.claude(.blockEnd)
            case 3: terminal.output.childError("stderr line")
            case 4:
                terminal.output.event(
                    Bool.random(using: &random)
                        ? launch
                        : ["event": "child-exit", "repository": "example-org/a", "outcome": "done"])
                tool = nil
            case 5:
                tool = ["Bash", "Read"].randomElement(using: &random)
                terminal.output.claude(.tool(tool!))
            default:
                current = snapshots.randomElement(using: &random)
                terminal.output.status(current!)
            }
            let expected = current.map { block($0, tool: tool) } ?? []
            let lines = terminal.screen.lines
            #expect(Array(lines.suffix(expected.count)) == expected)
            let committed = Array(lines.dropLast(expected.count))
            #expect(Array(committed.prefix(log.count)) == log, "the log above only grows")
            #expect(committed.allSatisfy { $0.count <= standard.columns })
            log = committed
        }
    }

    // MARK: Outputs without a block

    /// What the output wrote to stdout, as `value`, and to stderr, as `errors`.
    private final class Written: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        private var errorText = ""
        func append(_ more: String) {
            lock.lock()
            defer { lock.unlock() }
            text += more
        }
        func appendError(_ more: String) {
            lock.lock()
            defer { lock.unlock() }
            errorText += more
        }
        var value: String {
            lock.lock()
            defer { lock.unlock() }
            return text
        }
        var errors: String {
            lock.lock()
            defer { lock.unlock() }
            return errorText
        }
    }

    private func output(
        json: Bool = false, _ environment: [String: String], terminal: Bool,
        size: TerminalSize? = standard
    )
        -> (LoopOutput, Written)
    {
        let written = Written()
        let output = LoopOutput(
            json: json, environment: environment, stdoutIsTerminal: terminal, size: { size },
            now: { now }, timeZone: utc, write: { written.append($0) },
            writeError: { written.appendError($0) })
        return (output, written)
    }

    private func feed(_ output: LoopOutput) {
        output.status(running)
        output.emit(launch)
        output.stream(.text("Reading "))
        output.stream(.tool("Bash"))
        output.status(running)
        output.stream(.text("the board."))
        output.stream(.blockEnd)
        output.status(idle)
    }

    @Test(
        "With the block drawn, an activity line ends Claude's partial row and is cut to the width")
    func activityLines() {
        let terminal = Terminal()
        terminal.output.status(running)
        terminal.text("Running the ")
        terminal.output.claude(.call(name: "Bash", detail: "Run the tests", subagent: false))
        terminal.output.claude(
            .failure(String(repeating: "x", count: 200), subagent: false))
        let cut = "    failed: " + String(repeating: "x", count: standard.columns - 14) + "…"
        #expect(
            terminal.screen.lines
                == ["Running the ", "  Bash: Run the tests", cut] + block(running))
        #expect(displayColumns(cut) == standard.columns)
    }

    @Test("--json prints the same for a stream with activity lines")
    func jsonIgnoresActivity() {
        let (plain, expected) = output(json: true, [:], terminal: false)
        feed(plain)
        let (output, written) = output(json: true, [:], terminal: false)
        output.stream(.call(name: "Bash", detail: "Run the tests", subagent: false))
        feed(output)
        output.stream(.failure("Exit code 1", subagent: true))
        output.stream(.taskEnd(status: "completed", usage: nil))
        #expect(written.value == expected.value)
    }

    @Test("--json prints its event lines and nothing else, and passes stderr through unchanged")
    func json() {
        let (output, written) = output(json: true, ["TERM": "xterm-256color"], terminal: true)
        feed(output)
        output.childErrors("error: unknown option '--thinking-display'")
        #expect(written.value == jsonLine(launch, at: now))
        #expect(written.value.hasPrefix(#"{"event":"launch","reason":"assignment""#))
        #expect(written.errors == "error: unknown option '--thinking-display'\n")
    }

    @Test("Without a terminal, or with TERM empty or dumb, the plain log is as it was")
    func plainLog() {
        for (environment, terminal, styled) in [
            (["TERM": "xterm-256color"], false, false), (["TERM": "dumb"], true, true),
            ([:], true, true), (["TERM": "dumb", "NO_COLOR": "1"], true, false),
        ] {
            let (output, written) = output(environment, terminal: terminal)
            feed(output)
            var plain = ""
            let human = HumanOutput(
                styled: styled, timeZone: utc, now: { now }, write: { plain += $0 })
            human.event(launch)
            human.claude(.text("Reading the board."))
            human.claude(.blockEnd)
            #expect(written.value == plain)
            #expect(written.value.hasSuffix("Reading the board.\n"))
            #expect(!written.value.contains("\u{1B}[J"))
            #expect(!written.value.contains("tickwork a02db1fb"))
            output.childErrors("\u{1B}[31mwarning\u{1B}[0m: something")
            #expect(written.errors == "\u{1B}[31mwarning\u{1B}[0m: something\n")
            #expect(written.value == plain)
        }
    }

    @Test("NO_COLOR keeps the block, without colour or markers")
    func noColour() {
        let (output, written) = output(["TERM": "xterm", "NO_COLOR": "1"], terminal: true)
        feed(output)
        let screen = ScreenModel(width: standard.columns)
        screen.apply(written.value)
        #expect(screen.lines == [launchLine, "Reading the board."] + block(idle))
        #expect(!written.value.contains("\u{1B}[2m") && !written.value.contains("\u{1B}[3"))
        #expect(!written.value.contains("🚀"))
        output.childErrors("warning: something")
        #expect(written.value.contains("warning: something\n"))
        #expect(written.errors.isEmpty)
    }

    @Test("The block needs a terminal whose TERM is set and isn't dumb")
    func blockChoice() {
        #expect(loopOutputHasBlock(environment: ["TERM": "xterm"], stdoutIsTerminal: true))
        #expect(!loopOutputHasBlock(environment: ["TERM": "xterm"], stdoutIsTerminal: false))
        #expect(!loopOutputHasBlock(environment: ["TERM": "dumb"], stdoutIsTerminal: true))
        #expect(!loopOutputHasBlock(environment: ["TERM": ""], stdoutIsTerminal: true))
        #expect(!loopOutputHasBlock(environment: [:], stdoutIsTerminal: true))
    }
}
