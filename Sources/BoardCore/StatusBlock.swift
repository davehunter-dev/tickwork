import Foundation

// The block `tickwork loop` pins below its log, as lines: a pure function of the
// snapshot, so every layout rule is tested without a terminal. See "The block"
// in docs/supervisor-status.md.

/// What the running child is doing, read from its stream rather than the supervisor.
struct ClaudeActivity: Equatable {
    /// The top-level session's current tool.
    var tool: String?
    /// The latest `rate_limit_event`'s, kept after the child exits.
    var windows: ClaudeWindows?
}

/// The subscription's usage windows, as one `rate_limit_event` reported them.
struct ClaudeWindows: Equatable {
    let windows: [Window]
    let reported: Date

    struct Window: Equatable {
        /// Such as `five_hour` or `seven_day`.
        let name: String
        let percent: Int
        let status: Status
    }

    enum Status: String, Equatable {
        case allowed
        case allowedWarning = "allowed_warning"
        case rejected
    }
}

/// Turns a snapshot into the block's lines, each cut to fit the width.
struct StatusBlock {
    let styled: Bool
    let timeZone: TimeZone

    /// Columns left free at the right, so a line never wraps.
    static let widthMargin = 1
    /// What a non-ASCII character counts as, so an emoji or `·` can cut a line early
    /// but never make it wrap.
    static let nonASCIIColumns = 2
    /// Repository names are padded to the longest, but never past this.
    static let longestNamePadding = 12
    /// The block takes at most one terminal row in this many.
    static let rowsPerBlockLine = 2
    static let revisionLength = 8

    private static let separator = " · "
    static let ellipsis = "…"

    func lines(
        _ status: SupervisorStatus, activity: ClaudeActivity, width: Int, height: Int, now: Date
    ) -> [String] {
        let times = Times(timeZone: timeZone, now: now)
        var lines = [loginLine(status, activity, times), budgetLine(status, activity, times)]
        let room = height / Self.rowsPerBlockLine
        lines += repositoryLines(status, activity, times, room: room - lines.count)
        return lines.prefix(room)
            .map { render(cut(flattened($0), to: width - Self.widthMargin)) }
    }

    // MARK: The lines

    private func loginLine(
        _ status: SupervisorStatus, _ activity: ClaudeActivity, _ times: Times
    ) -> Line {
        let state: Span
        switch status.state {
        case .stopped(let at, _):
            state = Span("STOPPED at \(times.clock(at))", .bad)
        case .paused(let until, .subscriptionLimit):
            let window = activity.windows?.windows.first { $0.status == .rejected }?.name
            state = Span(
                "PAUSED until \(times.minute(until)): Claude's \(window ?? "subscription") limit",
                .warning)
        case .paused(let until, let cause):
            let why =
                cause == .secondaryLimit
                ? "GitHub's secondary limit" : "Claude's ending was unclear"
            state = Span("PAUSED until \(times.clock(until)): \(why)", .warning)
        case .replacing(let revision):
            state = Span("updating to \(short(revision)) after Claude exits")
        case .running:
            state = Span("running")
        }
        let tool = ["tickwork", status.revision.map(short)].compactMap { $0 }.joined(separator: " ")
        return joined([[state], [Span(status.login)], [Span(tool)]])
    }

    private func budgetLine(
        _ status: SupervisorStatus, _ activity: ClaudeActivity, _ times: Times
    ) -> Line {
        var pieces: [Line] = []
        if let core = status.core {
            let budget = "GitHub core \(grouped(core.remaining))/\(grouped(core.limit))"
            pieces.append(
                core.limited
                    ? [Span("\(budget), intervals wait for \(times.minute(core.reset))", .warning)]
                    : [Span(budget)])
        } else {
            pieces.append([Span("GitHub core not read yet")])
        }
        if let graphQL = status.graphQL {
            let budget =
                "GraphQL \(grouped(graphQL.budget.remaining))"
                + " at \(times.minute(graphQL.reported))"
            pieces.append(
                graphQL.budget.remaining < readReserve
                    ? [Span("\(budget), reads wait for the reset", .warning)] : [Span(budget)])
        }
        if let claude = activity.windows {
            var piece = [Span("Claude")]
            for window in claude.windows {
                let usage = " \(windowNames[window.name] ?? window.name) \(window.percent)%"
                piece.append(
                    window.status == .allowedWarning
                        ? Span("\(usage) near limit", .warning) : Span(usage))
            }
            // While a child runs, its windows are current.
            if status.child == nil { piece.append(Span(" at \(times.minute(claude.reported))")) }
            pieces.append(piece)
        }
        return joined(pieces)
    }

    private func repositoryLines(
        _ status: SupervisorStatus, _ activity: ClaudeActivity, _ times: Times, room: Int
    ) -> [Line] {
        let names = displayNames(status.repositories.map(\.name))
        let padding = min(names.values.map(columns).max() ?? 0, Self.longestNamePadding)
        func line(_ repository: SupervisorStatus.Repository) -> Line {
            let name = names[repository.name] ?? repository.name
            let pad = String(repeating: " ", count: max(padding - columns(name), 0))
            return [Span("\(name)\(pad)  ")]
                + repositoryText(repository, status, activity, names, times)
        }

        // While a child runs, the block is about that run.
        if status.child != nil {
            let shown = status.repositories.filter { $0.state == .claude || needsAttention($0) }
            let quiet = status.repositories.count - shown.count
            return shown.map(line) + (quiet > 0 ? [[Span("+\(quiet) quiet")]] : [])
        }

        let lines = status.repositories.map(line)
        guard lines.count > room else { return lines }
        let folded = status.repositories.filter {
            $0.state == .idle && $0.failingSince == nil && $0.setAsideMerges.isEmpty
        }
        guard !folded.isEmpty else { return lines }
        let checked = folded.compactMap(\.checked).min().map { ", checked \(times.clock($0))" }
        return status.repositories.filter { !folded.contains($0) }.map(line)
            + [[Span("+\(folded.count) idle\(checked ?? "")")]]
    }

    private func repositoryText(
        _ repository: SupervisorStatus.Repository, _ status: SupervisorStatus,
        _ activity: ClaudeActivity, _ names: [String: String], _ times: Times
    ) -> Line {
        let needsYou = Span("needs you", .bad)
        var pieces: [Line] = []
        var showsNext = true
        switch repository.state {
        case .parked(let assignment):
            pieces.append([
                needsYou,
                Span(
                    "\(Self.separator)parked \(work(assignment)): no progress twice; "
                        + "release the claim, restart"),
            ])
        case .needsFix:
            pieces.append([
                needsYou,
                Span("\(Self.separator)needs a fix on main: \(repository.error ?? "")"),
            ])
        case .ended(let outcome, let purpose):
            showsNext = false
            pieces.append([Span("Claude ended, \(outcome)")])
            pieces.append([Span(self.purpose(purpose))])
        case .claude:
            showsNext = false
            if let child = status.child {
                if let terminated = child.terminated {
                    pieces.append([Span("stopping (time limit) since \(times.clock(terminated))")])
                } else {
                    pieces.append([Span("Claude since \(times.clock(child.started))")])
                }
                pieces.append([Span(purpose(child.purpose))])
                if child.terminated == nil, let tool = activity.tool { pieces.append([Span(tool)]) }
            } else {
                pieces.append([Span("Claude")])
            }
        case .reconciling(let since, let reasons):
            showsNext = false
            pieces.append([
                Span("reconciling since \(times.clock(since)): \(reasons.joined(separator: ", "))")
            ])
        case .backingOff(let until):
            // Its end is also when it is next due.
            showsNext = false
            pieces.append([
                Span("retry at \(times.clock(until)): \(repository.error ?? "")", .warning)
            ])
        case .failing:
            let since = repository.failingSince.map { " since \(times.clock($0))" } ?? ""
            pieces.append([
                Span("checks failing\(since): \(repository.error ?? "")", .warning)
            ])
        case .due(let hold):
            var text = "due" + (repository.due.map { " since \(times.clock($0.since))" } ?? "")
            switch hold {
            case .child(let other): text += ": waiting for Claude in \(names[other] ?? other)"
            case .pause: text += ": waiting for the pause"
            case .coreFloor: text += ": waiting for the core floor"
            case nil: break
            }
            pieces.append([Span(text)])
        case .idle:
            pieces.append([Span("idle")])
        }

        if !repository.setAsideMerges.isEmpty {
            let merges = repository.setAsideMerges.map { "#\($0)" }.joined(separator: ", ")
            pieces.append([needsYou, Span(": set aside merge \(merges)")])
        }
        // While a child runs, only its repository's freshness is about that run.
        if status.child != nil, repository.state != .claude { return joined(pieces) }
        if let checked = repository.checked {
            pieces.append(
                repository.failingSince == nil
                    ? [Span("checked \(times.clock(checked))")]
                    : [Span("last checked \(times.clock(checked))", .warning)])
        }
        if let changed = repository.changed {
            pieces.append([Span("changed \(times.clock(changed))")])
        }
        if showsNext {
            switch repository.next {
            case .at(let time): pieces.append([Span("next \(times.clock(time))")])
            case .after(let reset): pieces.append([Span("next after \(times.clock(reset))")])
            case .inTurn: pieces.append([Span("next in turn")])
            case .onChange: pieces.append([Span("next on a change")])
            }
        }
        return joined(pieces)
    }

    /// A state only a person ends, or one recovering by itself.
    private func needsAttention(_ repository: SupervisorStatus.Repository) -> Bool {
        if !repository.setAsideMerges.isEmpty { return true }
        switch repository.state {
        case .parked, .needsFix, .ended, .backingOff, .failing: return true
        case .claude, .reconciling, .due, .idle: return false
        }
    }

    private func purpose(_ purpose: SupervisorStatus.Purpose) -> String {
        switch purpose {
        case .assignment(let assignment): work(assignment)
        case .merge(let issues): "merging " + issues.map { "#\($0)" }.joined(separator: ", ")
        }
    }

    private func work(_ assignment: SupervisorStatus.Assignment) -> String {
        (assignment.issue.map { "#\($0) " } ?? "") + "\(assignment.role)/\(assignment.task)"
    }

    private func short(_ revision: String) -> String {
        String(revision.prefix(Self.revisionLength))
    }

    /// Each name without its owner, unless another would then read the same.
    private func displayNames(_ names: [String]) -> [String: String] {
        func bare(_ name: String) -> String { String(name.split(separator: "/").last ?? "") }
        let counts = Dictionary(names.map { (bare($0), 1) }, uniquingKeysWith: +)
        return Dictionary(
            names.map { ($0, counts[bare($0)] == 1 ? bare($0) : $0) },
            uniquingKeysWith: { first, _ in first })
    }

    // MARK: Spans

    private struct Span: Equatable {
        let text: String
        let tone: Tone?
        init(_ text: String, _ tone: Tone? = nil) {
            self.text = text
            self.tone = tone
        }
    }

    private typealias Line = [Span]

    private func joined(_ pieces: [Line]) -> Line {
        pieces.enumerated().flatMap { index, piece in
            index == 0 ? piece : [Span(Self.separator)] + piece
        }
    }

    private func columns(_ character: Character) -> Int { displayColumns(String(character)) }

    private func columns(_ text: String) -> Int { displayColumns(text) }

    /// The line with each run of line breaks and other control characters as one
    /// space, since an error such as a failed fetch's can span several lines.
    private func flattened(_ line: Line) -> Line {
        func isControl(_ character: Character) -> Bool {
            character.unicodeScalars.contains { $0.properties.generalCategory == .control }
        }
        return line.map { span in
            var text = ""
            var broken = false
            for character in span.text {
                if isControl(character) {
                    broken = true
                    continue
                }
                if broken, !text.isEmpty, text.last != " ", character != " " { text.append(" ") }
                broken = false
                text.append(character)
            }
            return Span(text, span.tone)
        }
    }

    /// The line, ending in `…` when it is longer than `limit` columns.
    private func cut(_ line: Line, to limit: Int) -> Line {
        guard line.reduce(0, { $0 + columns($1.text) }) > limit else { return line }
        var left = limit - columns(Self.ellipsis)
        var kept: Line = []
        for span in line {
            var text = ""
            for character in span.text {
                guard columns(character) <= left else { break }
                left -= columns(character)
                text.append(character)
            }
            if !text.isEmpty { kept.append(Span(text, span.tone)) }
            if text.count < span.text.count { break }
        }
        return kept + [Span(Self.ellipsis)]
    }

    private func render(_ line: Line) -> String {
        line.map { span in
            guard styled, let tone = span.tone else { return span.text }
            return "\u{1B}[\(tone.colour)m\(span.text)\u{1B}[0m"
        }.joined()
    }
}

private let windowNames = ["five_hour": "5h", "seven_day": "7d"]

/// `4976` as `4,976`.
private func grouped(_ number: Int) -> String {
    let digits = Array(String(number))
    return digits.enumerated().map { index, digit in
        index > 0 && (digits.count - index) % 3 == 0 ? ",\(digit)" : "\(digit)"
    }.joined()
}

/// A time later today by the clock alone, any other with its date too.
private struct Times {
    let timeZone: TimeZone
    let now: Date

    func clock(_ date: Date) -> String { format(date, "HH:mm:ss") }
    /// For budgets and Claude's windows, which move by the minute at most.
    func minute(_ date: Date) -> String { format(date, "HH:mm") }

    private func format(_ date: Date, _ time: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = calendar.isDate(date, inSameDayAs: now) ? time : "MMM d \(time)"
        return formatter.string(from: date)
    }
}

/// The columns `text` takes at most on a terminal.
func displayColumns(_ text: String) -> Int {
    text.reduce(0) { $0 + ($1.isASCII ? 1 : StatusBlock.nonASCIIColumns) }
}
