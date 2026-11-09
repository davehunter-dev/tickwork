// Read and move items on the project board, and claim what a tick is
// working.
//
// The board is the loop's state. An issue's column says which role owns it and
// what happens to it next, and its position within that column is its priority,
// set by hand. So `head Ready` is the selection rule in full — there is no
// milestone or issue-number tiebreak. See docs/loop.md.
//
// Callers reach this through `bin/tickwork`, which install.sh places beside the
// build of one commit. Nothing in the loop invokes this binary by name.
//
// Needs the `project` scope on the account it runs as: gh auth refresh -s project

import Foundation

let usage = """
    usage: tickwork show|working
           tickwork list|head|count <column>
           tickwork status|blockers <issue>
           tickwork feedback <issue>
           tickwork repairs [--apply]
           tickwork merge <pr>
           tickwork add-blocker|remove-blocker <issue> <blocker>
           tickwork audit-dependencies
           tickwork move <issue> <column> [--from <expected>]
           tickwork claim|release <issue>
           tickwork next [--roles <role,...>] [--preview]
           tickwork loop [--json] <path> [<path>...]
           tickwork finish --token T <outcome> [--pr <ref>] [--new] [--body-file F]
                           [--answering URL]... [--on N]...
           tickwork reply --token T --answering URL... --body-file F
           tickwork file-issue|decompose --token T --key K --title T --body-file F [--label L]...
           tickwork add-blocker|remove-blocker --token T --blocker N
           tickwork --refresh <command>
    """

func fail(_ message: String, status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("board: \(message)\n".utf8))
    exit(status)
}

func showUsage(status: Int32) -> Never {
    let handle = status == 0 ? FileHandle.standardOutput : FileHandle.standardError
    handle.write(Data((usage + "\n").utf8))
    exit(status)
}

/// The whole of the `board` command.
///
/// It lives here rather than in the executable so that the parsing and the
/// command bodies can be tested: an executable target's `main.swift` carries
/// top-level code, and nothing can import that. `Sources/board` is a two-line
/// shell over this.
public func run() -> Never {
    // Before anything reads the arrangement: every verb acts by main's file.
    Coordinates.readsMain = true

    var arguments = Array(CommandLine.arguments.dropFirst())
    guard !arguments.isEmpty else { showUsage(status: 2) }

    if arguments[0] == "-h" || arguments[0] == "--help" { showUsage(status: 0) }

    // The supervisor reads each path's own loop.json, not the working directory's.
    if arguments[0] == "loop" {
        guard arguments.count > 1 else { showUsage(status: 2) }
        runLoop(Array(arguments.dropFirst()))
    }

    // Every tick opens with `working` or `show`, so that is the read that must not
    // be a cached one: it is where a tick finds out what the owner did since the
    // last one. Everything after it in the same tick is welcome to the copy it
    // left behind.
    var refresh = ["show", "working", "--refresh"].contains(arguments[0])
    if arguments[0] == "--refresh" {
        arguments.removeFirst()
        guard !arguments.isEmpty else { showUsage(status: 2) }
    }

    let command = arguments[0]
    let provider = GitHubBoard(configuration: Coordinates.configuration)
    let source = GitHubSourceControl(owner: Coordinates.ownerLogin)

    // `move`'s optional `--from` is parsed before the board is loaded, because
    // it asks for a fresh board. A flag that asks whether the board has moved is
    // the wrong place to economise on asking GitHub — the item list is cached for
    // three minutes, and a reviewer reads the board, reads a pull request,
    // comments and moves well inside that, so a guard answering from the cache
    // would agree with the caller in exactly the case it exists to refuse.
    var expectedColumn: String?
    var apply = false
    if command == "repairs" {
        // The repairs read the whole board and act on it, so they ask for a fresh
        // one, as `working` does.
        refresh = true
        if arguments.count == 2 && arguments[1] == "--apply" {
            apply = true
        } else if arguments.count != 1 {
            showUsage(status: 2)
        }
    }
    if command == "move" {
        if arguments.count == 5 && arguments[3] == "--from" {
            expectedColumn = arguments[4]
            arguments = Array(arguments.prefix(3))
            refresh = true
        } else if arguments.count != 3 {
            showUsage(status: 2)
        }
    }

    func issueNumber(_ text: String) -> Int {
        guard let number = Int(text.hasPrefix("#") ? String(text.dropFirst()) : text) else {
            fail("not an issue number: \(text)")
        }
        return number
    }

    do {
        switch command {
        // `blockers`, `claim` and `release` read or write the issue rather than the
        // project, so they need neither the board nor the `project` scope that
        // reading it requires.
        case "blockers":
            guard arguments.count == 2 else { showUsage(status: 2) }
            try blockers(of: issueNumber(arguments[1]), on: provider)

        // The two writes that keep the relation and the prose in step. They read
        // and write the issue's dependencies, so like `blockers` they need
        // neither the board nor the `project` scope.
        //
        // **These exist because the loop account cannot make the call itself**,
        // and `addBlocker` carries the argument for why a verb is the right
        // shape of exception rather than a loosened denial — see there.
        // The token forms of the helper verbs, and `finish`. Each answers in JSON.
        case "finish", "reply", "file-issue", "decompose":
            print(tokenVerb(command, Array(arguments.dropFirst()), board: provider, source: source))

        case "add-blocker", "remove-blocker":
            if arguments.contains("--token") {
                print(
                    tokenVerb(
                        command, Array(arguments.dropFirst()), board: provider, source: source))
                break
            }
            guard arguments.count == 3 else { showUsage(status: 2) }
            let issue = issueNumber(arguments[1])
            let blocker = issueNumber(arguments[2])
            if command == "add-blocker" {
                try addBlocker(blocker, of: issue, on: provider)
            } else {
                try removeBlocker(blocker, of: issue, on: provider)
            }

        // Reads the issue and its pull requests over REST, like `blockers`, so it
        // needs no board and no `project` scope.
        case "feedback":
            guard arguments.count == 2 else { showUsage(status: 2) }
            try feedback(on: issueNumber(arguments[1]), board: provider, source: source)

        // Answers in JSON, its own failures included, and checks the budget itself.
        case "next":
            let request = nextRequest(Array(arguments.dropFirst()))
            let answer = BoardCore.next(request, board: provider, source: source) {
                var lines: [String] = []
                try repairs(
                    snapshot: provider.snapshot(refresh: true), board: provider, source: source,
                    apply: true
                ) { lines.append($0) }
                return lines
            }
            print(answer.json)

        // A `MERGE` line's write. It reads one pull request and the budget, not
        // the board.
        case "merge":
            guard arguments.count == 2 else { showUsage(status: 2) }
            print(
                try guardedMerge(
                    pullRequestReference(arguments[1]), board: provider, source: source))

        case "claim":
            guard arguments.count == 2 else { showUsage(status: 2) }
            try claim(issueNumber(arguments[1]), on: provider)

        case "release":
            guard arguments.count == 2 else { showUsage(status: 2) }
            try release(issueNumber(arguments[1]), on: provider)

        // Reads issues rather than the project, like the three above, so it
        // needs no board and no `project` scope. Deliberately not reached from
        // `blockers`: the skip's per-candidate cost is what this verb exists to
        // stay off — see `auditDependencies`.
        case "audit-dependencies":
            guard arguments.count == 1 else { showUsage(status: 2) }
            try auditDependencies(on: provider)

        default:
            // A read checks what it would leave for the writes before it spends
            // any of it. `move` is the write it protects, so it does not check.
            var budget: GraphQLBudget?
            if command != "move" {
                budget = try provider.budget()
                try budget?.requireReadReserve()
            }
            let board = try provider.snapshot(refresh: refresh)

            switch command {
            case "show":
                guard arguments.count == 1 else { showUsage(status: 2) }
                show(board, workflow: Coordinates.workflow)

            case "working":
                guard arguments.count == 1, let budget else { showUsage(status: 2) }
                print(
                    workingText(board, budget: budget, workflow: Coordinates.workflow),
                    terminator: "")

            case "list", "head", "count":
                guard arguments.count == 2 else { showUsage(status: 2) }
                try board.requireColumn(arguments[1])
                try Coordinates.workflow.columns.requireRead(arguments[1])
                let numbers = board.items.filter { $0.status == arguments[1] }.map(\.number)
                switch command {
                case "list": numbers.forEach { print($0) }
                case "head": if let first = numbers.first { print(first) }
                default: print(numbers.count)
                }

            case "status":
                guard arguments.count == 2 else { showUsage(status: 2) }
                print(board.column(of: issueNumber(arguments[1])))

            case "repairs":
                try repairs(snapshot: board, board: provider, source: source, apply: apply)

            case "move":
                let issue = issueNumber(arguments[1])
                try provider.move(issue, to: arguments[2], from: expectedColumn)
                print("#\(issue) -> \(arguments[2])")

            default:
                fail("unknown command: \(command)")
            }
        }
    } catch let error as BoardError {
        fail(error.message)
    } catch {
        fail(error.localizedDescription)
    }

    exit(0)
}

/// `next`'s arguments: `--roles a,b` and `--preview`, in either order.
private func nextRequest(_ arguments: [String]) -> NextRequest {
    var roles: Set<Role>?
    var preview = false
    var rest = arguments[...]
    while let argument = rest.popFirst() {
        switch argument {
        case "--preview":
            preview = true
        case "--roles":
            guard let list = rest.popFirst() else { showUsage(status: 2) }
            roles = Set(
                list.split(separator: ",").map { name in
                    guard let role = Role(rawValue: String(name)) else {
                        fail("not a role: \(name)")
                    }
                    return role
                })
        default:
            showUsage(status: 2)
        }
    }
    return NextRequest(
        arrangementJSON: mainArrangement(), roles: roles, preview: preview,
        revision: buildRevision())
}

/// `origin/main:loop.json`, the arrangement every verb reads. Empty when git can't
/// show it, which `next` then refuses as invalid.
func mainArrangement() -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git", "show", "origin/main:loop.json"]
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return "" }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : ""
}

/// How much of a revision an answer names it by.
private let revisionDisplayLength = 8

/// The revision install.sh built this from, written beside `bin/`. `nil` for a
/// build that came from anywhere else.
private func buildRevision() -> String? {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let file = executable.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("revision")
    guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
    let revision = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return revision.isEmpty ? nil : String(revision.prefix(revisionDisplayLength))
}

/// `finish` and the token forms of the helper verbs, parsed and run.
private func tokenVerb(
    _ command: String, _ arguments: [String], board: BoardProvider, source: SourceControl
) -> String {
    var options: [String: [String]] = [:]
    var flags: Set<String> = []
    var positional: [String] = []
    var rest = arguments[...]
    let valued: Set<String> = [
        "--token", "--pr", "--body-file", "--answering", "--on", "--key", "--title", "--label",
        "--blocker", "--head",
    ]
    while let argument = rest.popFirst() {
        if valued.contains(argument) {
            guard let value = rest.popFirst() else { fail("\(argument) needs a value") }
            options[argument, default: []].append(value)
        } else if argument.hasPrefix("--") {
            flags.insert(argument)
        } else {
            positional.append(argument)
        }
    }
    func one(_ name: String) -> String? { options[name]?.last }
    guard let tokenText = one("--token") else { fail("--token is required") }
    let token: ClaimToken
    do {
        token = try ClaimToken(parsing: tokenText)
    } catch {
        fail((error as? BoardError)?.message ?? "\(error)")
    }
    let body = one("--body-file").map { path -> String in
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            fail("could not read --body-file \(path)")
        }
        return text
    }
    let context = FinishContext(
        issueRepository: Coordinates.repository, owner: Coordinates.ownerLogin,
        workflow: Coordinates.workflow, agentApproval: Coordinates.configuration.agentApproval,
        autoMerge: Coordinates.configuration.autoMerge,
        stackLabel: Coordinates.configuration.stackLabel,
        lockConversations: Coordinates.configuration.lockConversations)

    switch command {
    case "finish":
        guard positional.count == 1, let outcome = Outcome(rawValue: positional[0]) else {
            fail(
                "finish takes one outcome: "
                    + Outcome.allCases.map(\.rawValue).joined(separator: ", "))
        }
        var request = FinishRequest(token: token, outcome: outcome)
        request.pullRequest = one("--pr").map(pullRequestReference)
        request.isNew = flags.contains("--new")
        request.body = body
        request.answering = options["--answering"] ?? []
        request.blockers = (options["--on"] ?? []).map(issueReference)
        request.head = one("--head")
        return finish(request, board: board, source: source, context: context).json
    case "reply":
        return reply(
            token: token, answering: options["--answering"] ?? [], body: body ?? "", board: board,
            source: source, context: context
        ).json
    case "file-issue", "decompose":
        guard let key = one("--key"), let title = one("--title"), let body else {
            fail("\(command) needs --key, --title and --body-file")
        }
        return fileIssue(
            token: token, key: key, title: title, body: body, labels: options["--label"] ?? [],
            decomposing: command == "decompose", board: board, context: context
        ).json
    default:
        guard let blocker = one("--blocker").map(issueReference) else {
            fail("\(command) needs --blocker")
        }
        return changeBlocker(
            token: token, blocker: blocker, adding: command == "add-blocker", board: board,
            context: context
        ).json
    }
}

private func issueReference(_ text: String) -> Int {
    guard let number = Int(text.hasPrefix("#") ? String(text.dropFirst()) : text) else {
        fail("not an issue number: \(text)")
    }
    return number
}

/// `owner/name#N`, or `#N` and `N` in the board's repository.
private func pullRequestReference(_ text: String) -> PullRequestID {
    PullRequestID(reference: text, home: Coordinates.repository)
        ?? PullRequestID(repository: Coordinates.repository, number: issueReference(text))
}
