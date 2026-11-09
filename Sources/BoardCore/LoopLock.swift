import Foundation

// One `tickwork loop` per operating-system user, whatever repositories each
// would supervise. Every loop under a user spends the same GitHub login's
// budget and the same Claude subscription, and two of them would claim and run
// children side by side, breaking the one-session rule. Other verbs never take
// the lock, so a person can still run `next`, `board` or `instructions` beside
// a running loop.
//
// The lock is `flock` on a file in the user's home directory. The kernel drops it
// when the holding process exits, however it exits, so a crash leaves nothing
// stale. It is opened close-on-exec, so neither a Claude child nor the tool a
// replacement `exec`s inherits it: the replacement takes it again as it starts.

/// Another loop already holds the lock.
struct LoopLockHeld: Error, Equatable {
    let path: String
    /// What the holder wrote when it took the lock, if it could be read.
    let holderPID: Int32?

    var message: String {
        let who = holderPID.map { "pid \($0)" } ?? "another process"
        return "another tickwork loop is already running as this user (\(who), lock \(path)); "
            + "stop it before starting another, or add this repository's path to it"
    }
}

/// The loop's lock, held until this process exits.
final class LoopLock {
    let path: String
    let descriptor: Int32

    /// Takes the lock at `path`, creating its directory and file as needed, and
    /// records this process's pid in it. Throws `LoopLockHeld` at once when
    /// another process holds it, never waiting, and `BoardError` when the file
    /// can't be opened.
    init(path: String) throws {
        let directory = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true)
        } catch {
            throw BoardError("can't create \(directory) for the loop's lock: \(error)")
        }
        let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw BoardError(
                "can't open the loop's lock \(path): \(String(cString: strerror(errno)))")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let reason = errno
            let holder = Self.recordedPID(descriptor)
            close(descriptor)
            guard reason == EWOULDBLOCK else {
                throw BoardError(
                    "can't lock \(path): \(String(cString: strerror(reason)))")
            }
            throw LoopLockHeld(path: path, holderPID: holder)
        }
        self.path = path
        self.descriptor = descriptor
        let pid = Data("\(getpid())\n".utf8)
        _ = ftruncate(descriptor, 0)
        _ = pid.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, pid.count, 0) }
    }

    deinit { close(descriptor) }

    private static func recordedPID(_ descriptor: Int32) -> Int32? {
        var buffer = [UInt8](repeating: 0, count: pidTextLimit)
        let count = pread(descriptor, &buffer, buffer.count, 0)
        guard count > 0 else { return nil }
        let text = String(decoding: buffer[0..<count], as: UTF8.self)
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Longer than any pid's digits and newline.
    private static let pidTextLimit = 32
}

/// The lock's path for the user this process runs as. It comes from the account's
/// home directory in the password database, not `HOME` or `XDG_CACHE_HOME`, so
/// a changed environment can't start a second loop as the same user.
func loopLockPath(userID: uid_t = getuid()) -> String? {
    guard let entry = getpwuid(userID), let home = entry.pointee.pw_dir else { return nil }
    return String(cString: home) + "/.cache/tickwork/loop.lock"
}
