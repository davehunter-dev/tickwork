import Foundation

/// A failure with something the operator can act on.
///
/// Every exit from this tool that is not success comes through here, so the
/// wording is in one place and a caller reading a log gets the same shape of
/// message whatever went wrong.
struct BoardError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    /// Whether `gh` refused because the thing asked for is not there, rather
    /// than because the asking failed.
    ///
    /// **Matched on the message, and conservative on purpose.** `gh` writes
    /// `gh: Not Found (HTTP 404)` and there is no exit code that separates a 404
    /// from a rate limit or a dropped connection — every HTTP error leaves with
    /// the same status. So the format is what there is to read.
    ///
    /// The direction that matters is which way it fails. A caller uses this to
    /// tell "this does not exist" from "I could not find out", and if the
    /// wording ever changes this answers `false` — which reports a number as
    /// unconfirmed rather than as missing. The safe half is the default.
    var isNotFound: Bool { message.contains("(HTTP 404)") }
}

/// Running `gh`, which is the only way this program reaches GitHub.
///
/// A thin wrapper on purpose. The loop already depends on `gh` being installed
/// and authenticated, and reimplementing its auth against the REST and GraphQL
/// APIs would be a second thing to keep working for no gain.
enum GitHub {
    /// Runs `gh` with these arguments and returns what it wrote to stdout.
    ///
    /// Throws with whatever it wrote to stderr, because `gh`'s own message about
    /// a missing scope or a rate limit is more use than anything this could say
    /// about it.
    static func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["gh"] + arguments

        let result: CommandResult
        do {
            result = try runPiped(process)
        } catch {
            throw BoardError("could not run gh: \(error.localizedDescription)")
        }

        guard result.status == 0 else {
            let reason = result.errors.trimmingCharacters(in: .whitespacesAndNewlines)
            throw BoardError(
                reason.isEmpty ? "gh \(arguments.joined(separator: " ")) failed" : reason)
        }

        return result.output
    }
}

/// Runs `process` with its stdout and stderr piped, both read to the end at
/// once, since a full pipe stops the child while nobody reads it.
///
/// Every end is closed here rather than on deallocation. Darwin autoreleases a
/// pipe's handles, and `tickwork loop`'s main thread never drains a pool, so
/// each command leaked two descriptors until no pipe could open and every launch
/// failed with "Bad file descriptor".
func runPiped(_ process: Process) throws -> CommandResult {
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    defer { closeEveryEnd(out, err) }
    try process.run()
    let errors = Drained()
    // A thread of its own, not a dispatch queue: a caller on a Swift concurrency
    // thread blocks it here, and once every such thread is blocked, dispatch
    // may start no thread for a queued block, and the wait never ends.
    let drained = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        errors.data = err.fileHandleForReading.readDataToEndOfFile()
        drained.signal()
    }
    let output = out.fileHandleForReading.readDataToEndOfFile()
    drained.wait()
    process.waitUntilExit()
    return CommandResult(
        status: process.terminationStatus, output: String(decoding: output, as: UTF8.self),
        errors: String(decoding: errors.data, as: UTF8.self))
}

/// Closes both ends of each pipe, whether or not a launch already closed one.
func closeEveryEnd(_ pipes: Pipe...) {
    for pipe in pipes {
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()
    }
}

/// What one pipe held: written once by the thread that drained it, and read only
/// after that thread signals.
private final class Drained: @unchecked Sendable {
    var data = Data()
}

/// How a GitHub implementation reaches `gh`. Injected so a test can record the
/// calls and answer them.
typealias GitHubRunner = ([String]) throws -> String

extension GitHub {
    /// One JSON array of strings per matching row, read over every page.
    static func rows(
        _ path: String, query: String = "", select: String, fields: String, run: GitHubRunner
    ) throws -> [[String]] {
        let parameters = query.isEmpty ? "per_page=100" : "\(query)&per_page=100"
        let output = try run([
            "api", "--paginate", "\(path)?\(parameters)",
            "--jq", ".[] | \(select) | [\(fields)] | @json",
        ])
        return try output.split(separator: "\n").map {
            try JSONDecoder().decode([String].self, from: Data($0.utf8))
        }
    }

    /// Every comment on an issue, or on a pull request's conversation, from anyone,
    /// oldest first.
    ///
    /// `issues/<PR>/comments` is a pull request's conversation; `pulls/<PR>/comments`
    /// is its diff. Unfiltered, because it holds both the owner's comments and the
    /// replies that answer them.
    static func comments(on number: Int, in repository: String, run: GitHubRunner) throws
        -> [ConversationComment]
    {
        try rows(
            "repos/\(repository)/issues/\(number)/comments",
            select: "select(true)",
            fields: ".user.login, .html_url, .created_at, .body", run: run
        ).map {
            ConversationComment(author: $0[0], url: $0[1], createdAt: try date($0[2]), body: $0[3])
        }
    }
}
