import Foundation

// The supervisor's child: how one ended, whether it will bill the subscription,
// and whether the work it left moved. See "The child" in docs/supervisor.md.

/// How a child process finished: its exit and the stream lines the supervisor
/// reads, `rate_limit_event` and `result`. Every other line is dropped as read.
struct ChildExit: Equatable {
    let status: Int32
    /// Ended by a signal rather than by exiting.
    let signaled: Bool
    let lines: [String]
    /// The first line the child wrote to stderr.
    var firstError: String? = nil
}

enum ChildOutcome: Equatable {
    case done
    /// The subscription refused a request; nothing is launched or claimed until
    /// the latest reset among the refusals.
    case limit(until: Date)
    case authentication(String)
    case transient(String)
    /// Stopped by the supervisor at the time limit.
    case crash
    case ambiguous(String)

    var name: String {
        switch self {
        case .done: "done"
        case .limit: "limit"
        case .authentication: "authentication"
        case .transient: "transient"
        case .crash: "crash"
        case .ambiguous: "ambiguous"
        }
    }
}

enum ChildTiming {
    static let timeLimit: TimeInterval = 2 * 60 * 60
    /// Between SIGTERM and SIGKILL, at the time limit and on the supervisor's
    /// own exit.
    static let grace: TimeInterval = 30
    static let firstAmbiguityPause: TimeInterval = 30 * 60
    static let longestAmbiguityPause: TimeInterval = 4 * 60 * 60
    /// Children in a row that left the same work before it is set aside: one
    /// crash or interrupted tick is tolerated.
    static let noProgressLimit = 2
}

/// The variables that would bill something other than the subscription.
let billingVariables = [
    "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK",
    "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
]

/// The child's environment: the supervisor's, without `billingVariables`.
func childEnvironment(_ environment: [String: String]) -> [String: String] {
    environment.filter { !billingVariables.contains($0.key) }
}

/// `claude -p "/next-task"`, never `--bare`, which reads only an API key.
/// `--thinking-display summarized`, which `claude --help` doesn't list, is the
/// only way found to get thinking text in the headless stream.
func childCommand(repository: String, thinkingSummaries: Bool) -> [String] {
    [
        "claude", "-p", "/next-task", "--output-format", "stream-json", "--verbose",
        "--include-partial-messages",
        "--permission-mode", "auto", "--permission-prompts", "none",
    ] + (thinkingSummaries ? ["--thinking-display", "summarized"] : []) + [
        "--name", "tickwork \(repository)",
    ]
}

/// Whether `claude` refused `--thinking-display` at startup: it exited non-zero
/// before writing a stream line, and its first stderr line is an option error
/// naming the flag, as both `unknown option` and an invalid argument are.
func rejectedThinkingFlag(_ exit: ChildExit) -> Bool {
    guard !exit.signaled, exit.status != 0, exit.lines.isEmpty, let line = exit.firstError
    else { return false }
    return line.hasPrefix("error: ") && line.contains("'--thinking-display")
}

/// Why `claude auth status --json` doesn't promise subscription billing, or
/// `nil` when it does.
func subscriptionRefusal(_ result: CommandResult) -> String? {
    guard result.status == 0,
        let status = try? JSONSerialization.jsonObject(with: Data(result.output.utf8))
            as? [String: Any]
    else {
        let errors = result.errors.trimmingCharacters(in: .whitespacesAndNewlines)
        return "claude auth status failed: \(errors.isEmpty ? result.output : errors)"
    }
    let loggedIn = status["loggedIn"] as? Bool == true
    let method = status["authMethod"] as? String ?? "none"
    let provider = status["apiProvider"] as? String ?? "none"
    guard loggedIn, method == "claude.ai", provider == "firstParty" else {
        return "claude auth status reports loggedIn \(loggedIn), authMethod \(method), "
            + "apiProvider \(provider); a child runs only on a claude.ai subscription"
    }
    return nil
}

/// Whether a stream line is one the supervisor reads.
func isReadLine(_ line: String) -> Bool {
    guard line.contains("\"type\""),
        let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    else { return false }
    return ["result", "rate_limit_event"].contains(object["type"] as? String ?? "")
}

private func objects(_ lines: [String]) -> [[String: Any]] {
    lines.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
}

/// The `result` line, if the child wrote one.
func resultLine(_ exit: ChildExit) -> [String: Any]? {
    objects(exit.lines).last { $0["type"] as? String == "result" }
}

/// How a child ended, from the stream's fields and never its prose.
func classifyChild(_ exit: ChildExit, timedOut: Bool) -> ChildOutcome {
    let rejected = objects(exit.lines).filter { line in
        line["type"] as? String == "rate_limit_event"
            && (line["rate_limit_info"] as? [String: Any])?["status"] as? String == "rejected"
    }
    let resets = rejected.compactMap {
        ($0["rate_limit_info"] as? [String: Any])?["resetsAt"] as? Double
    }
    // A refusal with no reset can't be timed, so it pauses as an unclear ending does.
    if resets.count < rejected.count {
        return .ambiguous("a rejected rate-limit event names no reset")
    }
    if let until = resets.max() { return .limit(until: Date(timeIntervalSince1970: until)) }
    if timedOut { return .crash }
    guard let result = resultLine(exit) else {
        return .ambiguous(
            exit.signaled ? "killed by signal \(exit.status), with no result" : "no result line")
    }
    let isError = result["is_error"] as? Bool ?? true
    let status = result["api_error_status"] as? Int
    if !isError, exit.status == 0, !exit.signaled { return .done }
    switch status {
    case 401, 403:
        return .authentication("the API answered \(status!)")
    case .some(let code) where code == 529 || (500..<600).contains(code):
        return .transient("the API answered \(code)")
    default:
        let subtype = result["subtype"] as? String ?? "none"
        return .ambiguous(
            "is_error \(isError), subtype \(subtype), api_error_status "
                + "\(status.map(String.init) ?? "none"), exit \(exit.status)")
    }
}

/// What a child's result line reports about its use, for the event log. Every
/// field is present, and `null` where the child left no result to report it.
func childUsage(_ exit: ChildExit) -> [String: Any] {
    let result = resultLine(exit) ?? [:]
    let fields = ["usage", "modelUsage", "num_turns", "duration_ms", "total_cost_usd"]
    return Dictionary(uniqueKeysWithValues: fields.map { ($0, result[$0] ?? NSNull()) })
}

// MARK: Progress

/// The work an assignment names, from `next`'s answer: issue, role, task, the
/// column its token was claimed in, the pull request and the unanswered
/// findings. `nil` for anything that isn't an assignment.
func assignmentWork(_ answer: [String: Any]) -> String? {
    guard answer["kind"] as? String == "assignment",
        let issue = (answer["issue"] as? [String: Any])?["number"] as? Int
    else { return nil }
    // The pull request by its head alone: its checks and mergeability change without
    // the child doing anything.
    let pullRequest = answer["pullRequest"] as? [String: Any]
    let column = (try? ClaimToken(parsing: answer["token"] as? String ?? ""))?.column ?? ""
    func canonical(_ value: Any?) -> String {
        guard let value, JSONSerialization.isValidJSONObject(value),
            let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        else { return "none" }
        return String(decoding: data, as: UTF8.self)
    }
    return [
        "#\(issue)", answer["role"] as? String ?? "", answer["task"] as? String ?? "", column,
        "pr \(pullRequest?["ref"] as? String ?? "none") \(pullRequest?["head"] as? String ?? "none")",
        "findings \(canonical(answer["findings"]))",
    ].joined(separator: " ")
}

/// The issue's Git state in one clone: every local and `origin` branch named
/// `f/<issue>-…` with its commit, and, where `HEAD` is on one, the
/// uncommitted changes and untracked files as SHA-256 digests, so the evidence is
/// fixed-size and holds no working-tree content. Throws when a digest can't be
/// taken.
func gitState(of issue: Int, in path: String, commands: CommandRunning) throws -> String {
    func git(_ arguments: [String]) -> String { commands.run(["git"] + arguments, in: path).output }
    func digest(_ arguments: [String]) throws -> String {
        do {
            return try commands.sha256(ofOutput: ["git"] + arguments, in: path)
        } catch {
            throw SupervisorStop(reason: "the Git state of \(path) can't be digested: \(error)")
        }
    }
    let prefix = "f/\(issue)-"
    let refs = git([
        "for-each-ref", "--format=%(refname) %(objectname)", "refs/heads/\(prefix)*",
        "refs/remotes/origin/\(prefix)*",
    ])
    let head = git(["symbolic-ref", "-q", "--short", "HEAD"])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard head.hasPrefix(prefix) else { return refs }
    // The names, NUL-separated, and the regular files' blob hashes in the same order.
    // `hash-object` refuses the rest: a nested repository, listed as `name/`, and a
    // symbolic link to a directory or to nothing. Those count by name alone.
    let listUntracked = ["ls-files", "--others", "--exclude-standard", "-z"]
    let untracked = git(listUntracked).split(separator: "\0").map(String.init).filter {
        let attributes = try? FileManager.default.attributesOfItem(atPath: "\(path)/\($0)")
        return attributes?[.type] as? FileAttributeType == .typeRegular
    }
    return [
        refs, "HEAD \(head)", "diff \(try digest(["diff", "HEAD", "--binary"]))",
        "untracked \(try digest(listUntracked)) \(try digest(["hash-object", "--"] + untracked))",
    ].joined(separator: "\n")
}
