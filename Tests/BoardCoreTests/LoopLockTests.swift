// One `tickwork loop` per user: the lock refuses a second loop, frees itself when
// its holder ends however it ends, and stays out of the processes a loop starts.
//

import Foundation
import Testing

@testable import BoardCore

private func lockPath() -> String {
    NSTemporaryDirectory() + "tickwork-lock-\(UUID().uuidString)/loop.lock"
}

/// Runs `/bin/sleep` holding a copy of `descriptor`, as a process that inherited
/// the lock would.
private func sleeper(holding descriptor: Int32) throws -> pid_t {
    #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t?
    #else
        var actions = posix_spawn_file_actions_t()
    #endif
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    // `dup2` clears close-on-exec on the copy, so the child keeps it, but only
    // onto another number: onto itself it does nothing, and the copy closes at exec.
    let target = descriptor == inheritedDescriptor ? inheritedDescriptor + 1 : inheritedDescriptor
    posix_spawn_file_actions_adddup2(&actions, descriptor, target)
    let arguments = ["/bin/sleep", "\(sleepSeconds)"]
    let argv = arguments.map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    var pid: pid_t = 0
    let result = posix_spawn(&pid, "/bin/sleep", &actions, nil, argv, environ)
    guard result == 0 else { throw BoardError("posix_spawn failed: \(result)") }
    return pid
}

private let inheritedDescriptor: Int32 = 3

/// Takes the lock at `path` once nothing holds it. A process another test is
/// spawning holds a copy of every descriptor until it execs, close-on-exec or not,
/// so a free lock can read as held for a moment; one that kept it holds it for
/// `sleepSeconds`.
private func lockOnceFree(_ path: String) throws -> LoopLock {
    let deadline = Date().addingTimeInterval(spawnWindowLimit)
    while true {
        do {
            return try LoopLock(path: path)
        } catch is LoopLockHeld where Date() < deadline {
            Thread.sleep(forTimeInterval: spawnWindowPoll)
        }
    }
}

/// Far longer than a spawn takes to exec, and far shorter than `sleepSeconds`.
private let spawnWindowLimit: TimeInterval = 2
private let spawnWindowPoll: TimeInterval = 0.01
/// Longer than any test runs; each test kills its sleeper.
private let sleepSeconds = 60

private func kill(_ pid: pid_t) {
    _ = Foundation.kill(pid, SIGKILL)
    var status: Int32 = 0
    _ = waitpid(pid, &status, 0)
}

@Suite("tickwork loop: one per user")
struct LoopLockTests {

    @Test("A second loop is refused at once, naming the first one's pid")
    func refusesSecond() throws {
        let path = lockPath()
        let first = try LoopLock(path: path)
        #expect(throws: LoopLockHeld(path: path, holderPID: getpid())) {
            try LoopLock(path: path)
        }
        withExtendedLifetime(first) {}
    }

    @Test("The refusal says what to do")
    func refusalIsActionable() {
        let message = LoopLockHeld(path: "/x/loop.lock", holderPID: 42).message
        #expect(message.contains("pid 42"))
        #expect(message.contains("/x/loop.lock"))
        #expect(message.contains("stop it"))
    }

    @Test("A loop starts once the first has ended")
    func restartsAfterRelease() throws {
        let path = lockPath()
        var first: LoopLock? = try LoopLock(path: path)
        withExtendedLifetime(first) {}
        first = nil
        _ = try lockOnceFree(path)
    }

    @Test("A lock file left with a pid in it blocks nothing")
    func staleFileIsFree() throws {
        let path = lockPath()
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try "99999\n".write(toFile: path, atomically: true, encoding: .utf8)
        let lock = try LoopLock(path: path)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "\(getpid())\n")
        withExtendedLifetime(lock) {}
    }

    @Test("A lock is free again when the process holding it is killed")
    func freedByDeath() throws {
        let path = lockPath()
        var lock: LoopLock? = try LoopLock(path: path)
        let pid = try sleeper(holding: lock!.descriptor)
        defer { kill(pid) }
        lock = nil
        // The sleeper still holds it.
        #expect(throws: LoopLockHeld.self) { try LoopLock(path: path) }
        kill(pid)
        _ = try lockOnceFree(path)
    }

    @Test("A process the loop starts doesn't inherit the lock")
    func childrenDontHoldIt() throws {
        let path = lockPath()
        var lock: LoopLock? = try LoopLock(path: path)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["\(sleepSeconds)"]
        try child.run()
        defer {
            child.terminate()
            child.waitUntilExit()
        }
        withExtendedLifetime(lock) {}
        lock = nil
        _ = try lockOnceFree(path)
    }

    @Test("The path is the user's own, from the account rather than the environment")
    func pathIsPerUser() throws {
        let mine = try #require(loopLockPath())
        let home = String(cString: try #require(getpwuid(getuid())?.pointee.pw_dir))
        #expect(mine == home + "/.cache/tickwork/loop.lock")
        if getuid() != 0 {
            #expect(loopLockPath(userID: 0) != mine)
        }
    }
}
