import Foundation

// What `tickwork loop` prints. `--json` prints the supervisor's events as they are;
// by default `HumanOutput` turns them into a line per state change and streams
// Claude's text between them, with the status block pinned below on a terminal.
// See "What it prints" in docs/supervisor.md.

/// What the loop shows from one of the child's `stream-json` lines.
enum ClaudeStream: Equatable {
    case text(String)
    /// The API's summary of the top-level session's thinking, streamed.
    case thinking(String)
    /// A content block ended, so the reply's next text starts on a line of its own.
    case blockEnd
    /// The top-level session started using this tool.
    case tool(String)
    /// A `rate_limit_event`'s usage windows.
    case windows([ClaudeWindows.Window])
    /// A tool call, complete, with the part of its input worth showing.
    case call(name: String, detail: String?, subagent: Bool)
    /// A tool result with `is_error`, its text lines joined.
    case failure(String, subagent: Bool)
    /// A subagent's or background task's ending.
    case taskEnd(status: String, usage: TaskUsage?)

    struct TaskUsage: Equatable {
        let tools: Int
        let milliseconds: Int
    }
}

/// The piece of the stream a line carries, if any. Text and the current tool come
/// from the top-level session only; tool calls and failures from subagents too.
/// A path in a call's detail loses `directory`, the child's working directory.
func claudeStream(_ line: String, directory: String? = nil) -> ClaudeStream? {
    guard
        [
            "\"stream_event\"", "\"rate_limit_event\"", "\"tool_use\"", "\"is_error\"",
            "\"task_notification\"",
        ]
        .contains(where: line.contains),
        let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    else { return nil }
    let subagent = !(object["parent_tool_use_id"] == nil || object["parent_tool_use_id"] is NSNull)
    switch object["type"] as? String {
    case "rate_limit_event":
        return usageWindows(object)
    case "stream_event":
        guard !subagent, let event = object["event"] as? [String: Any] else { return nil }
        return streamEvent(event)
    case "assistant":
        guard
            let call = contentBlocks(object).first(where: { $0["type"] as? String == "tool_use" }),
            let name = call["name"] as? String
        else { return nil }
        let detail = callDetail(call["input"] as? [String: Any] ?? [:], directory: directory)
        return .call(name: name, detail: detail, subagent: subagent)
    case "user":
        guard
            let result = contentBlocks(object).first(where: {
                $0["type"] as? String == "tool_result" && $0["is_error"] as? Bool == true
            })
        else { return nil }
        return .failure(failureText(result["content"]), subagent: subagent)
    case "system":
        guard object["subtype"] as? String == "task_notification",
            let status = object["status"] as? String
        else { return nil }
        let usage = object["usage"] as? [String: Any]
        guard let tools = usage?["tool_uses"] as? Int,
            let milliseconds = usage?["duration_ms"] as? Int
        else { return .taskEnd(status: status, usage: nil) }
        return .taskEnd(status: status, usage: .init(tools: tools, milliseconds: milliseconds))
    default:
        return nil
    }
}

private func streamEvent(_ event: [String: Any]) -> ClaudeStream? {
    switch event["type"] as? String {
    case "content_block_delta":
        guard let delta = event["delta"] as? [String: Any] else { return nil }
        switch delta["type"] as? String {
        case "text_delta":
            guard let text = delta["text"] as? String, !text.isEmpty else { return nil }
            return .text(text)
        case "thinking_delta":
            guard let thinking = delta["thinking"] as? String, !thinking.isEmpty else {
                return nil
            }
            return .thinking(thinking)
        default:
            return nil
        }
    case "content_block_stop":
        return .blockEnd
    case "content_block_start":
        guard let block = event["content_block"] as? [String: Any],
            block["type"] as? String == "tool_use", let name = block["name"] as? String
        else { return nil }
        return .tool(name)
    default:
        return nil
    }
}

private func contentBlocks(_ object: [String: Any]) -> [[String: Any]] {
    (object["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
}

/// The input keys a call's detail is read from, first present wins.
private let detailKeys = [
    "description", "file_path", "pattern", "url", "query", "skill", "command",
]

private func callDetail(_ input: [String: Any], directory: String?) -> String? {
    guard let value = detailKeys.lazy.compactMap({ input[$0] as? String }).first else {
        return nil
    }
    let detail = oneLine(value, separator: " ")
    guard let directory, detail.hasPrefix(directory + "/") else { return detail }
    return String(detail.dropFirst(directory.count + 1))
}

/// A result's `content`: a string, or the `text` of each `text` block.
private func failureText(_ content: Any?) -> String {
    let text =
        content as? String
        ?? (content as? [[String: Any]] ?? []).compactMap {
            $0["type"] as? String == "text" ? $0["text"] as? String : nil
        }.joined(separator: "\n")
    return oneLine(text, separator: " · ")
}

/// `text`'s non-blank lines, trimmed and joined by `separator`.
private func oneLine(_ text: String, separator: String) -> String {
    text.split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
        .joined(separator: separator)
}

extension ClaudeStream {
    /// The activity line this piece prints, without its indent, and how deep it is
    /// indented: the top-level session's calls at 1, a subagent's at 2, a failure
    /// one deeper than the calls beside it. `nil` for anything else.
    var activity: (depth: Int, text: String)? {
        switch self {
        case .call(let name, let detail, let subagent):
            return (subagent ? 2 : 1, detail.map { "\(name): \($0)" } ?? name)
        case .failure(let text, let subagent):
            return (subagent ? 3 : 2, text.isEmpty ? "failed" : "failed: \(text)")
        case .taskEnd(let status, let usage):
            guard let usage else { return (1, "task \(status)") }
            let time = duration(TimeInterval(usage.milliseconds) / 1000)
            return (1, "task \(status) (\(usage.tools) tools, \(time))")
        case .text, .thinking, .blockEnd, .tool, .windows:
            return nil
        }
    }
}

/// `rate_limit_info.unifiedWindows`, by name, each `utilization` as a percentage.
/// A window whose status isn't one Claude Code documents is left out.
private func usageWindows(_ event: [String: Any]) -> ClaudeStream? {
    guard let info = event["rate_limit_info"] as? [String: Any],
        let windows = info["unifiedWindows"] as? [String: [String: Any]]
    else { return nil }
    let percent = 100.0
    return .windows(
        windows.sorted { $0.key < $1.key }.compactMap { name, window in
            guard let utilization = window["utilization"] as? Double,
                let status = (window["status"] as? String).flatMap(ClaudeWindows.Status.init)
            else { return nil }
            return .init(
                name: name, percent: Int((utilization * percent).rounded()), status: status)
        })
}

/// Styling only for a terminal, and never under `NO_COLOR`.
func loopOutputIsStyled(environment: [String: String], stdoutIsTerminal: Bool) -> Bool {
    stdoutIsTerminal && (environment["NO_COLOR"] ?? "").isEmpty
}

/// The status block needs a terminal that understands cursor movement, which
/// `TERM` empty or `dumb` says it doesn't.
func loopOutputHasBlock(environment: [String: String], stdoutIsTerminal: Bool) -> Bool {
    let term = environment["TERM"] ?? ""
    return stdoutIsTerminal && !term.isEmpty && term != "dumb"
}

struct TerminalSize: Equatable {
    let columns: Int
    let rows: Int

    /// Standard output's size now, or `nil` when `TIOCGWINSZ` doesn't say.
    static func current() -> TerminalSize? {
        var size = winsize()
        guard ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &size) == 0, size.ws_col > 0, size.ws_row > 0
        else { return nil }
        return TerminalSize(columns: Int(size.ws_col), rows: Int(size.ws_row))
    }
}

/// How `tickwork loop` prints, chosen once at its start: JSON lines, the plain
/// log, or the log with the status block below it.
struct LoopOutput {
    let emit: ([String: Any]) -> Void
    let stream: @Sendable (ClaudeStream) -> Void
    let status: (SupervisorStatus) -> Void
    /// Each line of the child's stderr: committed to the log when the block is
    /// drawn, and otherwise written to `writeError` unchanged.
    let childErrors: @Sendable (String) -> Void

    init(
        json: Bool, environment: [String: String], stdoutIsTerminal: Bool,
        size: @escaping () -> TerminalSize? = TerminalSize.current,
        now: @escaping () -> Date = Date.init,
        timeZone: TimeZone = .current, write: @escaping @Sendable (String) -> Void,
        writeError: @escaping @Sendable (String) -> Void
    ) {
        if json {
            emit = { write(jsonLine($0, at: now())) }
            stream = { _ in }
            status = { _ in }
            childErrors = { writeError($0 + "\n") }
            return
        }
        let block = loopOutputHasBlock(environment: environment, stdoutIsTerminal: stdoutIsTerminal)
        let human = HumanOutput(
            styled: loopOutputIsStyled(
                environment: environment, stdoutIsTerminal: stdoutIsTerminal),
            timeZone: timeZone, now: now, size: block ? size : nil, write: write)
        emit = human.event
        stream = { human.claude($0) }
        status = human.status
        if human.drawsBlock {
            childErrors = { human.childError($0) }
        } else {
            childErrors = { writeError($0 + "\n") }
        }
    }
}

/// An event as one JSON line, stamped with its time.
func jsonLine(_ event: [String: Any], at time: Date) -> String {
    var line = event
    line["time"] = ISO8601DateFormatter().string(from: time)
    guard
        let data = try? JSONSerialization.data(
            withJSONObject: line, options: [.sortedKeys, .withoutEscapingSlashes])
    else { return "" }
    return String(decoding: data, as: UTF8.self) + "\n"
}

enum Tone {
    case info, good, warning, bad

    var colour: String {
        switch self {
        case .info: "36"
        case .good: "32"
        case .warning: "33"
        case .bad: "31"
        }
    }
}

/// The human rendering of the supervisor's events, its status and Claude's stream.
///
/// Events and status snapshots arrive on the supervisor's thread, Claude's stream
/// on the child's stdout reader and its stderr on a thread of its own, so all of
/// them go through `lock`, which guards everything below it. A failure is printed
/// once until it changes or its recovery is printed.
///
/// **With a terminal `size`, the status block is pinned below the log.** It is
/// drawn with the cursor at the end of its last line, and every write is one
/// `write`: erase the block, add whole rows to the log, draw the block again.
/// Claude's partial line is held back until it is a whole row, so nothing but the
/// block is ever erased, and a stderr or event line arriving meanwhile waits
/// behind that row. Without a `size`, or when it gives no first answer, the plain
/// log streams Claude's text as it comes and a snapshot draws nothing.
final class HumanOutput: @unchecked Sendable {
    /// The plain log has no width, so an activity line is cut here: wide enough for
    /// a path and a description, narrow enough that a pasted script can't fill a CI log.
    static let activityLineWidth = 160
    /// Before thinking text: it is the API's summary, not the reasoning itself.
    static let thinkingLead = "thinking (summary): "
    private let styled: Bool
    private let timeZone: TimeZone
    private let now: () -> Date
    let drawsBlock: Bool
    private let measure: () -> TerminalSize?
    /// The last size `measure` gave, kept through a failed query so the block's
    /// rows are counted at a width the terminal has really had.
    private var lastSize: TerminalSize?
    private let write: (String) -> Void
    private let block: StatusBlock
    private let lock = NSLock()
    /// The plain log's cursor is at a line's start.
    private var atLineStart = true
    /// The failures printed for each repository since it last recovered.
    private var failures: [String: Set<Failure>] = [:]
    /// Claude's text not yet a whole row.
    private var held = ""
    /// Lines that arrived while `held` was a partial row, committed after it.
    private var waiting = ""
    private var snapshot: SupervisorStatus?
    private var activity = ClaudeActivity()
    /// Inside a thinking block: set by its lead, cleared at the block's end or
    /// when a child launches or exits, so a child killed mid-block doesn't leave
    /// it set for the next. Read and written under `lock`, by `claude` on the
    /// child's stdout reader thread and by `event` and `status` on the
    /// supervisor's.
    private var thinking = false
    /// The block's lines as they are on the screen, and the width they were drawn at.
    private var shown: [String] = []
    private var shownWidth = 0
    /// After a stop or a replacement nothing draws the block again.
    private var ended = false

    private enum Failure: Hashable {
        case check(String)
        case watch(issue: Int, message: String)
        case next(String)
        case backoff

        var isCheck: Bool {
            if case .check = self { true } else { false }
        }
        func watches(_ issue: Int) -> Bool {
            if case .watch(issue, _) = self { true } else { false }
        }
        var isNext: Bool {
            if case .next = self { true } else { false }
        }
    }

    init(
        styled: Bool, timeZone: TimeZone = .current, now: @escaping () -> Date = Date.init,
        size: (() -> TerminalSize?)? = nil, write: @escaping (String) -> Void
    ) {
        self.styled = styled
        self.timeZone = timeZone
        self.now = now
        measure = size ?? { nil }
        lastSize = size?()
        drawsBlock = lastSize != nil
        self.write = write
        block = StatusBlock(styled: styled, timeZone: timeZone)
    }

    /// The terminal's size, or `nil` for the plain log.
    private func terminalSize() -> TerminalSize? {
        guard drawsBlock else { return nil }
        if let measured = measure() { lastSize = measured }
        return lastSize
    }

    func claude(_ piece: ClaudeStream) {
        lock.lock()
        defer { lock.unlock() }
        let size = terminalSize()
        if let (depth, text) = piece.activity {
            let row = activityRow(depth, text, width: size?.columns ?? Self.activityLineWidth)
            if let size {
                draw(committing: flushed() + row, size)
            } else {
                endLine()
                write(row)
            }
            return
        }
        guard let size else {
            switch piece {
            case .text(let text):
                write(text)
                atLineStart = text.hasSuffix("\n")
            case .thinking(let text):
                if !thinking { endLine() }
                write(dim((thinking ? "" : Self.thinkingLead) + text))
                thinking = true
                atLineStart = text.hasSuffix("\n")
            case .blockEnd:
                thinking = false
                endLine()
            case .tool, .windows, .call, .failure, .taskEnd:
                break
            }
            return
        }
        switch piece {
        case .text(let text):
            held += text
            draw(committing: releasingWaiting(takeRows(width: size.columns)), size)
        case .thinking(let text):
            let before = thinking ? "" : flushed()
            if !thinking { held = Self.thinkingLead }
            thinking = true
            held += text
            draw(
                committing: before + releasingWaiting(dimRows(takeRows(width: size.columns))), size)
        case .blockEnd:
            draw(committing: flushed(), size)
            thinking = false
        case .tool(let name):
            activity.tool = name
            draw(size)
        case .windows(let windows):
            activity.windows = ClaudeWindows(windows: windows, reported: now())
            draw(size)
        case .call, .failure, .taskEnd:
            break
        }
    }

    /// An activity line indented two spaces a level, cut with `…` to `width`
    /// columns, and dim when styled.
    private func activityRow(_ depth: Int, _ text: String, width: Int) -> String {
        let indent = String(repeating: "  ", count: depth)
        var line = indent + text
        if displayColumns(line) > width {
            var left = width - displayColumns(StatusBlock.ellipsis)
            line =
                String(
                    line.prefix { character in
                        left -= displayColumns(String(character))
                        return left >= 0
                    }) + StatusBlock.ellipsis
        }
        return indent + dim(String(line.dropFirst(indent.count))) + "\n"
    }

    /// `text` in the dim style when styled.
    private func dim(_ text: String) -> String {
        styled ? "\u{1B}[2m\(text)\u{1B}[0m" : text
    }

    /// Each of `rows`' lines dim, so no row's style depends on the one before it.
    private func dimRows(_ rows: String) -> String {
        rows.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
            .map { dim(String($0)) + "\n" }.joined()
    }

    /// One line the child wrote to stderr, committed in the dim style.
    func childError(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let size = terminalSize() else { return }
        commitBehindClaude(dim(line) + "\n", size)
    }

    func event(_ event: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }
        let name = event["event"] as? String ?? ""
        let childChanged = ["launch", "child-exit"].contains(name)
        if childChanged { activity.tool = nil }
        // After the exit's line commits the dead child's held thinking, dim.
        defer { if childChanged { thinking = false } }
        guard let (marker, tone, text) = line(for: event) else { return }
        let time = clock(now())
        let line =
            styled
            ? "\u{1B}[2m\(time)\u{1B}[0m \(marker) \u{1B}[\(tone.colour)m\(text)\u{1B}[0m\n"
            : "\(time) \(text)\n"
        guard let size = terminalSize() else {
            endLine()
            write(line)
            return
        }
        // The new process a replacement `exec`s draws its own block.
        if ["stop", "replace"].contains(name) { ended = true }
        // After these no more of Claude's text comes to finish its row.
        if ["stop", "replace", "child-exit"].contains(name) {
            draw(committing: flushed() + line, size)
        } else {
            commitBehindClaude(line, size)
        }
    }

    /// A stopped supervisor's block is printed as ordinary lines, so the state at
    /// the stop stays in the scrollback.
    func status(_ status: SupervisorStatus) {
        lock.lock()
        defer { lock.unlock() }
        guard let size = terminalSize() else { return }
        snapshot = status
        guard case .stopped = status.state else {
            draw(size)
            return
        }
        ended = true
        draw(committing: flushed() + lines(status, size).map { $0 + "\n" }.joined(), size)
    }

    private func endLine() {
        if !atLineStart { write("\n") }
        atLineStart = true
    }

    private func lines(_ status: SupervisorStatus, _ size: TerminalSize) -> [String] {
        block.lines(status, activity: activity, width: size.columns, height: size.rows, now: now())
    }

    /// Erases the block, adds `text` to the log and draws the block again, in one
    /// write. Nothing is written when there is nothing to add and the block's lines
    /// and width are unchanged.
    private func draw(committing text: String = "", _ size: TerminalSize) {
        let lines = ended ? [] : snapshot.map { self.lines($0, size) } ?? []
        guard !text.isEmpty || lines != shown || size.columns != shownWidth else { return }
        var erase = ""
        if !shown.isEmpty {
            erase = "\r" + (shown.count > 1 ? "\u{1B}[\(shown.count - 1)A" : "") + "\u{1B}[J"
        }
        write(erase + text + lines.joined(separator: "\n"))
        shown = lines
        shownWidth = size.columns
    }

    /// Commits `line` now, or after Claude's partial row once that row is whole.
    private func commitBehindClaude(_ line: String, _ size: TerminalSize) {
        if held.isEmpty {
            draw(committing: line, size)
        } else {
            waiting += line
            draw(size)
        }
    }

    /// `rows` with the waiting lines after the first, the row they waited for.
    private func releasingWaiting(_ rows: String) -> String {
        guard !waiting.isEmpty, let end = rows.firstIndex(of: "\n") else { return rows }
        defer { waiting = "" }
        return String(rows[...end]) + waiting + rows[rows.index(after: end)...]
    }

    /// The held partial line as a row of its own and the lines waiting behind it,
    /// emptying both.
    private func flushed() -> String {
        defer { (held, waiting) = ("", "") }
        let row = held.isEmpty ? "" : (thinking ? dim(held) : held) + "\n"
        return row + waiting
    }

    /// The whole rows `held` starts with, each ending in a newline: up to a newline,
    /// or `width` columns broken at the last space. `held` keeps the rest.
    private func takeRows(width: Int) -> String {
        var rows = ""
        var row = ""
        for character in held {
            if character == "\n" {
                rows += row + "\n"
                row = ""
                continue
            }
            guard displayColumns(row) + displayColumns(String(character)) > width else {
                row.append(character)
                continue
            }
            if character == " " {
                rows += row + "\n"
                row = ""
            } else if let space = row.lastIndex(of: " "), space > row.startIndex {
                rows += row[..<space] + "\n"
                row = String(row[row.index(after: space)...]) + String(character)
            } else {
                rows += row + "\n"
                row = String(character)
            }
        }
        held = row
        return rows
    }

    /// The line an event prints, or `nil` for one that changes nothing a person
    /// watches for.
    private func line(for event: [String: Any]) -> (String, Tone, String)? {
        let repository = event["repository"] as? String ?? ""
        func string(_ key: String) -> String { event[key] as? String ?? "" }
        switch string("event") {
        case "start":
            let paths = (event["repositories"] as? [String] ?? []).joined(separator: ", ")
            let workspaces = event["workspaces"] as? [String] ?? []
            let also =
                workspaces.isEmpty ? "" : "; workspaces \(workspaces.joined(separator: ", "))"
            return (
                "▶️", .info,
                "Started as \(string("login")) on \(paths)\(also). "
                    + "Run no /loop /next-task on \(string("login")) beside this."
            )
        case "launch":
            let purpose = string("reason") == "merge" ? "to merge" : "for an assignment"
            return ("🚀", .info, "\(repository): launching Claude \(purpose)")
        case "child-exit":
            return childExit(event, repository)
        case "time-limit":
            let limit = duration(ChildTiming.timeLimit)
            return ("⚠️", .warning, "\(repository): Claude reached the \(limit) limit; stopping it")
        case "pause":
            return ("⏸️", .warning, "Paused for \(string("reason")) until \(until(string("until")))")
        case "secondary-limit":
            let seconds = TimeInterval(event["seconds"] as? Int ?? 0)
            return ("⏸️", .warning, "GitHub's secondary rate limit: pausing \(duration(seconds))")
        case "core-limit":
            return (
                "⏸️", .warning,
                "GitHub's core rate limit is exhausted: pausing until \(until(string("until")))"
            )
        case "check-failed":
            return failure(.check(string("message")), repository) {
                ("⚠️", .warning, "\(repository): board check failed: \(string("message"))")
            }
        case "watch-failed":
            let issue = event["issue"] as? Int ?? 0
            return failure(.watch(issue: issue, message: string("message")), repository) {
                (
                    "⚠️", .warning,
                    "\(repository): pull requests of #\(issue) unreadable: \(string("message"))"
                )
            }
        case "backoff":
            let seconds = TimeInterval(event["seconds"] as? Int ?? 0)
            return failure(.backoff, repository) {
                ("⏳", .warning, "\(repository): backing off, retrying in \(duration(seconds))")
            }
        case "watch-recovered":
            let issue = event["issue"] as? Int ?? 0
            return recovered(
                repository, { $0.watches(issue) }, "pull requests of #\(issue) readable again")
        case "check-recovered":
            return recovered(repository, \.isCheck, "board checks recovered")
        case "reconcile-recovered":
            return recovered(repository, \.isNext, "next answers again")
        case "backoff-cleared":
            failures[repository]?.remove(.backoff)
            return nil
        case "error":
            return failure(.next(string("message")), repository) {
                ("❌", .bad, "\(repository): \(string("message"))")
            }
        case "parked":
            let work = string("work").split(separator: " ").prefix(3).joined(separator: " ")
            return (
                "🅿️", .warning,
                "\(repository): parked \(work), unchanged after two children; "
                    + "release the claim and restart"
            )
        case "set-aside":
            let merges = (event["merges"] as? [String] ?? []).joined(separator: "; ")
            return ("🅿️", .warning, "\(repository): set aside unchanged merges: \(merges)")
        case "thinking-unavailable":
            return (
                "⚠️", .warning,
                "\(repository): Claude rejected --thinking-display; "
                    + "thinking summaries are off until the loop restarts"
            )
        case "update-failed":
            return (
                "⚠️", .warning,
                "\(repository): updating Tickwork failed, so the installed tool runs on: "
                    + string("message")
            )
        case "replace":
            return ("🔄", .info, "Replacing tickwork \(string("from")) with \(string("to"))")
        case "stop":
            return ("⏹️", .bad, "Stopped: \(string("reason"))")
        default:
            return nil
        }
    }

    private func childExit(_ event: [String: Any], _ repository: String) -> (String, Tone, String) {
        let outcome = event["outcome"] as? String ?? ""
        let detail = (event["detail"] as? String).map { ": \($0)" } ?? ""
        switch outcome {
        case "done":
            var facts: [String] = []
            if let turns = event["num_turns"] as? Int { facts.append("\(turns) turns") }
            if let milliseconds = event["duration_ms"] as? Int {
                facts.append(duration(TimeInterval(milliseconds) / 1000))
            }
            let summary = facts.isEmpty ? "" : " (\(facts.joined(separator: ", ")))"
            return ("✅", .good, "\(repository): Claude finished\(summary)")
        case "limit":
            return ("⏸️", .warning, "\(repository): Claude hit the subscription limit")
        case "crash":
            return ("⚠️", .warning, "\(repository): Claude was stopped at the time limit")
        default:
            return ("❌", .bad, "\(repository): Claude ended, \(outcome)\(detail)")
        }
    }

    /// Prints a failure the repository hasn't already printed since it recovered.
    private func failure(
        _ failure: Failure, _ repository: String, _ line: () -> (String, Tone, String)
    ) -> (String, Tone, String)? {
        guard failures[repository, default: []].insert(failure).inserted else { return nil }
        return line()
    }

    /// Ends the repository's failures of one kind, printing the recovery if any
    /// were printed.
    private func recovered(
        _ repository: String, _ kind: (Failure) -> Bool, _ text: String
    ) -> (String, Tone, String)? {
        let printed = failures[repository] ?? []
        guard printed.contains(where: kind) else { return nil }
        failures[repository] = printed.filter { !kind($0) }
        return ("✅", .good, "\(repository): \(text)")
    }

    private func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }

    private func clock(_ date: Date) -> String { formatter("HH:mm:ss").string(from: date) }

    /// A time later today by the clock alone, any other with its date.
    private func until(_ text: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: text) else { return text }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let sameDay = calendar.isDate(date, inSameDayAs: now())
        return formatter(sameDay ? "HH:mm" : "MMM d HH:mm").string(from: date)
    }
}

/// `90` as `1m 30s`, `7200` as `2h`.
func duration(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded())
    let (hours, minutes, rest) = (total / 3600, total % 3600 / 60, total % 60)
    let parts = [(hours, "h"), (minutes, "m"), (rest, "s")].filter { $0.0 > 0 }
        .map { "\($0.0)\($0.1)" }
    return parts.isEmpty ? "0s" : parts.prefix(2).joined(separator: " ")
}
