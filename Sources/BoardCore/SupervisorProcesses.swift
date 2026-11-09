import Foundation

// The real seams behind `Supervisor`: `gh`, processes and the wall clock.

struct GitHubSupervisorSeam: SupervisorGitHub {
    func get(_ path: String, etag: String?) throws -> CheckResponse {
        var arguments = ["api", "-i", path]
        if let etag { arguments += ["-H", "If-None-Match: \(etag)"] }
        let result = ProcessCommands().run(
            ["gh"] + arguments, in: FileManager.default.currentDirectoryPath)
        guard let response = checkResponse(includedOutput: result.output) else {
            let reason = result.errors.trimmingCharacters(in: .whitespacesAndNewlines)
            throw BoardError(reason.isEmpty ? "gh api \(path) answered nothing" : reason)
        }
        return response
    }

    func viewer() throws -> String {
        try GitHub.run(["api", "user", "--jq", ".login"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func project(owner: String, number: Int) throws -> (itemsPath: String, statusFieldID: Int) {
        let type = try GitHub.run(["api", "users/\(owner)", "--jq", ".type"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = "\(type == "Organization" ? "orgs" : "users")/\(owner)/projectsV2/\(number)"
        let id = try GitHub.run([
            "api", "\(base)/fields?per_page=100", "--jq", ".[] | select(.name == \"Status\") | .id",
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let fieldID = Int(id) else {
            throw BoardError("\(owner)'s project \(number) has no Status field this could read")
        }
        return ("\(base)/items", fieldID)
    }

    func timeline(of issue: Int, in repository: String) throws -> String {
        try GitHub.run([
            "api", "--paginate", "--slurp",
            "repos/\(repository)/issues/\(issue)/timeline?per_page=100",
        ])
    }
}

struct ProcessCommands: CommandRunning {
    func run(_ arguments: [String], in directory: String) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardInput = FileHandle.nullDevice
        do {
            return try runPiped(process)
        } catch {
            return CommandResult(status: -1, output: "", errors: error.localizedDescription)
        }
    }

    /// Reads standard input and prints its SHA-256 in hex as the first word.
    #if canImport(Darwin)
        static let platformHasher = ["shasum", "-a", "256"]
    #else
        static let platformHasher = ["sha256sum"]
    #endif
    var hasher = Self.platformHasher

    func sha256(ofOutput arguments: [String], in directory: String) throws -> String {
        func process(_ arguments: [String]) -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = arguments
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
            process.standardError = FileHandle.nullDevice
            return process
        }
        let source = process(arguments)
        let hash = process(hasher)
        let stream = Pipe()
        let digestPipe = Pipe()
        defer { closeEveryEnd(stream, digestPipe) }
        source.standardInput = FileHandle.nullDevice
        source.standardOutput = stream
        hash.standardInput = stream
        hash.standardOutput = digestPipe
        try hash.run()
        do {
            try source.run()
        } catch {
            hash.terminate()
            hash.waitUntilExit()
            throw error
        }
        // Only the two processes may hold the stream, or the hasher never sees its end.
        closeEveryEnd(stream)
        let printed = String(
            decoding: digestPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        source.waitUntilExit()
        hash.waitUntilExit()
        let command = arguments.joined(separator: " ")
        let digest = printed.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        let hexDigits = Set("0123456789abcdef")
        guard hash.terminationStatus == 0, digest.count == Self.sha256HexLength,
            digest.allSatisfy(hexDigits.contains)
        else {
            throw BoardError(
                "\(hasher.joined(separator: " ")) gave no SHA-256 of \(command) "
                    + "(exit \(hash.terminationStatus))")
        }
        // After the hasher: a missing hasher also stops the source with SIGPIPE.
        guard source.terminationStatus == 0 else {
            throw BoardError("\(command) exited \(source.terminationStatus)")
        }
        return digest
    }

    static let sha256HexLength = 64
}

/// The wall clock. A sleep ends early when the supervisor receives a signal, so
/// the next pass can pass it to the child.
final class SystemClock: SupervisorClock {
    let signals: SignalWatch
    init(signals: SignalWatch) { self.signals = signals }

    var now: Date { Date() }
    func sleep(until date: Date) {
        let wait = date.timeIntervalSinceNow
        guard wait > 0 else { return }
        if signals.received != nil {
            Thread.sleep(forTimeInterval: wait)
        } else {
            _ = signals.wake.wait(timeout: .now() + wait)
        }
    }
}

/// `body` under `lock`. `NSLock.withLock` isn't in every Foundation.
private func locked<T>(_ lock: NSLock, _ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
}

/// SIGINT and SIGTERM, caught rather than fatal, so the supervisor can pass them
/// to its child before it exits.
final class SignalWatch: @unchecked Sendable {
    let wake = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var firstSignal: Int32?
    private var sources: [DispatchSourceSignal] = []

    var received: Int32? { locked(lock) { firstSignal } }

    func install() {
        for caught in [SIGINT, SIGTERM] {
            signal(caught, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: caught, queue: .global())
            source.setEventHandler { [self] in
                locked(lock) { if firstSignal == nil { firstSignal = caught } }
                wake.signal()
            }
            source.resume()
            sources.append(source)
        }
    }
}

/// `claude`, launched in its own process group with the billing variables
/// removed from its environment.
struct ClaudeLauncher: ChildLaunching {
    let environment = childEnvironment(ProcessInfo.processInfo.environment)
    /// Told each piece of Claude's stream, on the child's stdout reader thread.
    let onStream: @Sendable (ClaudeStream) -> Void
    /// Told each line of the child's stderr, on a thread of its own.
    let onError: @Sendable (String) -> Void

    func authStatus() -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["claude", "auth", "status", "--json"]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        do {
            return try runPiped(process)
        } catch {
            return CommandResult(status: -1, output: "", errors: error.localizedDescription)
        }
    }

    func start(_ request: ChildRequest) throws -> ChildProcess {
        try SpawnedChild(
            command: childCommand(
                repository: request.repository, thinkingSummaries: request.thinkingSummaries),
            directory: request.path,
            environment: environment, onStream: onStream, onError: onError)
    }
}

/// A child in a process group of its own, so a signal reaches everything it
/// started. Its stdout is read on a thread of its own, keeping only the lines
/// the supervisor classifies and passing on Claude's stream. Its stderr is
/// piped and read line by line on another thread, keeping the first line.
///
/// `lock` guards `kept`, `firstError`, `openReaders` and `waitStatus`: the reader
/// threads write the first three, and `exit`, on the supervisor's thread, reads them.
final class SpawnedChild: ChildProcess, @unchecked Sendable {
    let pid: pid_t
    private let lock = NSLock()
    private var kept: [String] = []
    private var firstError: String?
    /// Its exit waits for every pipe to be read to the end.
    private var openReaders: Int
    private var waitStatus: Int32?

    init(
        command: [String], directory: String, environment: [String: String],
        onStream: @escaping @Sendable (ClaudeStream) -> Void = { _ in },
        onError: @escaping @Sendable (String) -> Void = { _ in }
    ) throws {
        let output = try Self.openPipe()
        let errors = try Self.openPipe()
        openReaders = 2
        // Darwin spells these as optional pointers, Glibc as structs.
        #if canImport(Darwin)
            var actions: posix_spawn_file_actions_t?
            var attributes: posix_spawnattr_t?
        #else
            var actions = posix_spawn_file_actions_t()
            var attributes = posix_spawnattr_t()
        #endif
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        for (ends, descriptor) in [(output, STDOUT_FILENO), (errors, STDERR_FILENO)] {
            posix_spawn_file_actions_adddup2(&actions, ends.write, descriptor)
            posix_spawn_file_actions_addclose(&actions, ends.read)
            posix_spawn_file_actions_addclose(&actions, ends.write)
        }
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // The supervisor ignores SIGINT and SIGTERM to pass them on, and an ignored
        // signal survives exec, so the child gets every default back.
        var defaults = sigset_t()
        sigfillset(&defaults)
        var unmasked = sigset_t()
        sigemptyset(&unmasked)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setsigmask(&attributes, &unmasked)
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)

        // `sh` changes into the clone and execs the command, keeping the pid and
        // so the process group; every argument stays a separate word.
        let arguments = ["/bin/sh", "-c", "cd -- \"$0\" && exec \"$@\"", directory] + command
        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var spawned: pid_t = 0
        let result = posix_spawn(&spawned, "/bin/sh", &actions, &attributes, argv, envp)
        for ends in [output, errors] { close(ends.write) }
        guard result == 0 else {
            for ends in [output, errors] { close(ends.read) }
            throw BoardError("could not launch claude: \(String(cString: strerror(result)))")
        }
        pid = spawned
        read(output.read) { [self] line in
            if isReadLine(line) { locked(lock) { kept.append(line) } }
            if let piece = claudeStream(line, directory: directory) { onStream(piece) }
        }
        read(errors.read) { [self] line in
            locked(lock) { if firstError == nil { firstError = line } }
            onError(line)
        }
    }

    private static func openPipe() throws -> (read: Int32, write: Int32) {
        var ends: [Int32] = [0, 0]
        guard pipe(&ends) == 0 else {
            throw BoardError("could not open a pipe for claude")
        }
        return (ends[0], ends[1])
    }

    /// Reads `descriptor` to its end on a thread of its own, a line at a time.
    private func read(_ descriptor: Int32, _ each: @escaping @Sendable (String) -> Void) {
        Thread.detachNewThread { [self] in
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            var pending = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                    each(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                    pending.removeSubrange(pending.startIndex...newline)
                }
            }
            if !pending.isEmpty { each(String(decoding: pending, as: UTF8.self)) }
            locked(lock) { openReaders -= 1 }
        }
    }

    var exit: ChildExit? {
        locked(lock) {
            if waitStatus == nil {
                var status: Int32 = 0
                if waitpid(pid, &status, WNOHANG) == pid { waitStatus = status }
            }
            guard let status = waitStatus, openReaders == 0 else { return nil }
            let signaled = status & 0x7f != 0 && status & 0x7f != 0x7f
            return ChildExit(
                status: signaled ? status & 0x7f : (status >> 8) & 0xff, signaled: signaled,
                lines: kept, firstError: firstError)
        }
    }

    func signal(_ signal: Int32) { _ = kill(-pid, signal) }
}

struct ExecReplacer: ToolReplacing {
    func replace(tool: String, arguments: [String]) throws {
        let argv = ["sh", tool] + arguments
        var cArguments = argv.map { strdup($0) } + [nil]
        execv("/bin/sh", &cArguments)
        let reason = String(cString: strerror(errno))
        cArguments.forEach { free($0) }
        throw BoardError("could not run \(tool): \(reason)")
    }
}

/// The `bin/tickwork` the wrapper ran this from, by the path it used, and the
/// revision its installer wrote beside it. `nil` outside an installed build.
func runningTool() -> RunningTool? {
    tool(at: URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent())
}

/// `~/.cache/tickwork/tool/bin/tickwork`, where install.sh puts the account's tool.
func installedToolPath(home: String) -> String {
    URL(fileURLWithPath: home).appendingPathComponent(".cache/tickwork/tool/bin/tickwork").path
}

/// The account's installed tool, or `nil` while none is.
func installedTool(home: String) -> RunningTool? {
    let wrapper = installedToolPath(home: home)
    guard FileManager.default.fileExists(atPath: wrapper) else { return nil }
    return tool(at: URL(fileURLWithPath: wrapper).deletingLastPathComponent())
}

private func tool(at bin: URL) -> RunningTool? {
    let file = bin.deletingLastPathComponent().appendingPathComponent("revision")
    guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
    return RunningTool(
        path: bin.appendingPathComponent("tickwork").path,
        revision: text.trimmingCharacters(in: .whitespacesAndNewlines))
}

/// `tickwork loop [--json] <path>…`.
func runLoop(_ arguments: [String]) -> Never {
    let json = arguments.first == "--json"
    let paths = json ? Array(arguments.dropFirst()) : arguments
    let output = LoopOutput(
        json: json, environment: ProcessInfo.processInfo.environment,
        stdoutIsTerminal: isatty(STDOUT_FILENO) != 0,
        write: { FileHandle.standardOutput.write(Data($0.utf8)) },
        writeError: { FileHandle.standardError.write(Data($0.utf8)) })
    let lock: LoopLock
    do {
        guard let path = loopLockPath() else {
            throw BoardError("can't find this user's home directory for the loop's lock")
        }
        lock = try LoopLock(path: path)
    } catch let held as LoopLockHeld {
        output.emit(["event": "stop", "reason": held.message])
        exit(1)
    } catch {
        output.emit(["event": "stop", "reason": (error as? BoardError)?.message ?? "\(error)"])
        exit(1)
    }
    withExtendedLifetime(lock) {
        supervise(paths: paths, json: json, output: output)
    }
}

/// The supervisor's whole life, under the loop's lock.
private func supervise(paths: [String], json: Bool, output: LoopOutput) -> Never {
    let signals = SignalWatch()
    signals.install()
    let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    let supervisor = Supervisor(
        github: GitHubSupervisorSeam(), commands: ProcessCommands(),
        clock: SystemClock(signals: signals),
        launcher: ClaudeLauncher(onStream: output.stream, onError: output.childErrors),
        home: home, tool: runningTool(), installed: { installedTool(home: home) },
        replacer: ExecReplacer(), emit: output.emit,
        status: output.status, flags: json ? ["--json"] : [], interrupted: { signals.received })
    do {
        try supervisor.start(paths: paths)
    } catch let stop as SupervisorStop {
        output.emit(["event": "stop", "reason": stop.reason])
        exit(1)
    } catch {
        output.emit(["event": "stop", "reason": "\(error)"])
        exit(1)
    }
    supervisor.run()
    exit(1)
}
