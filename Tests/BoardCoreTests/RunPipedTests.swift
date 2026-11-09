// `runPiped`, the one way a command's output is read: it must not need a thread
// beyond its caller's that the system may never start.
//

import Foundation
import Testing

@testable import BoardCore

/// Enough callers to block every Swift concurrency thread, with more queued.
private let callersPerProcessor = 2

@Suite("Running a command with its output piped")
struct RunPipedTests {

    @Test("Every concurrency thread can wait on a command at once")
    func everyThreadWaiting() async throws {
        let callers = ProcessInfo.processInfo.activeProcessorCount * callersPerProcessor
        let results = try await withThrowingTaskGroup(of: CommandResult.self) { group in
            for _ in 0..<callers {
                group.addTask {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/bin/sh")
                    // The pause keeps each caller waiting until every thread is.
                    process.arguments = ["-c", "sleep 1; echo out; echo err >&2"]
                    return try runPiped(process)
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(results.count == callers)
        #expect(results.allSatisfy { $0.output == "out\n" && $0.errors == "err\n" })
    }
}
