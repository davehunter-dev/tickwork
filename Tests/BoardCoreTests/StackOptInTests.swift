// `loop.json`'s optional `stack`: read when present and absent otherwise, its
// shape and repository checks, and `decompose` copying its label.
//

import Foundation
import Testing

@testable import BoardCore

@Suite("The stack opt-in")
struct StackOptInTests {

    static let stacked = #", "stack": { "label": "stackable" }"#

    /// `NextTests.arrangement` with `settings` added before `agents`.
    static func arrangement(_ settings: String = "") -> String {
        guard !settings.isEmpty else { return NextTests.arrangement }
        return NextTests.arrangement.replacingOccurrences(
            of: "\"agents\":", with: String(settings.dropFirst(2)) + ",\n  \"agents\":")
    }

    static func document(_ settings: String = "") throws -> [String: JSON] {
        try JSONDecoder().decode(JSON.self, from: Data(arrangement(settings).utf8)).object ?? [:]
    }

    // MARK: loop.json

    @Test("stack.label is read when present, and none when absent")
    func configuration() throws {
        let stacked = try JSONDecoder().decode(
            LoopConfiguration.self, from: Data(Self.arrangement(Self.stacked).utf8))
        #expect(stacked.stackLabel == "stackable")
        let plain = try JSONDecoder().decode(
            LoopConfiguration.self, from: Data(Self.arrangement().utf8))
        #expect(plain.stackLabel == nil)
    }

    @Test("A malformed stack is refused by path, and a well-formed one passes")
    func shape() throws {
        #expect(loopProblems(in: try Self.document(Self.stacked)).isEmpty)
        #expect(
            loopProblems(in: try Self.document(#", "stack": "stackable""#))
                == ["stack: not an object"])
        #expect(
            loopProblems(in: try Self.document(#", "stack": { "label": "" }"#))
                == ["stack.label: missing, or not a non-empty string"])
        #expect(
            loopProblems(in: try Self.document(#", "stack": { "label": "s", "depth": 2 }"#))
                == ["stack.depth: not a key it takes (label)"])
    }

    // MARK: The repository

    /// A `gh` answering a label read and the `delete_branch_on_merge` read, and
    /// logging what it was asked.
    final class FakeGitHub {
        /// The repository's spelling of the label, or nil when it has none.
        var labelName: String? = "stackable"
        var deletesBranches = "false"
        var calls: [[String]] = []

        func run(_ arguments: [String]) throws -> String {
            calls.append(arguments)
            if arguments[1].contains("/labels/") {
                guard let labelName else { throw BoardError("gh: Not Found (HTTP 404)") }
                return labelName + "\n"
            }
            return deletesBranches + "\n"
        }
    }

    @Test("Without stack, the repository isn't read")
    func offlineWithoutStack() throws {
        let github = FakeGitHub()
        #expect(stackRepositoryProblems(in: try Self.document(), gh: github.run).isEmpty)
        #expect(github.calls.isEmpty)
    }

    @Test("An existing label with delete_branch_on_merge off passes")
    func passes() throws {
        let github = FakeGitHub()
        #expect(
            stackRepositoryProblems(in: try Self.document(Self.stacked), gh: github.run).isEmpty)
        #expect(github.calls.count == 2)
    }

    @Test("A missing label and delete_branch_on_merge on are each named")
    func refuses() throws {
        let github = FakeGitHub()
        github.labelName = nil
        github.deletesBranches = "true"
        let problems = stackRepositoryProblems(in: try Self.document(Self.stacked), gh: github.run)
        #expect(problems.count == 2)
        #expect(problems[0].hasPrefix("stack.label: stackable is not a label in"))
        #expect(problems[1].contains("delete_branch_on_merge on"))
    }

    @Test("A label found in another case is refused, giving the repository's spelling")
    func labelCase() throws {
        let github = FakeGitHub()
        github.labelName = "Stackable"
        let problems = stackRepositoryProblems(in: try Self.document(Self.stacked), gh: github.run)
        #expect(
            problems == [
                "stack.label: stackable is spelled Stackable in example-org/example, and labels match exactly"
            ])
    }

    @Test("A setting that can't be read is refused rather than passed")
    func unreadableSetting() throws {
        let github = FakeGitHub()
        github.deletesBranches = "null"
        let problems = stackRepositoryProblems(in: try Self.document(Self.stacked), gh: github.run)
        #expect(problems.count == 1)
        #expect(problems[0].contains("can't read"))
    }

    @Test("A label is read by its path-encoded name")
    func encodedLabel() throws {
        let github = FakeGitHub()
        _ = stackRepositoryProblems(
            in: try Self.document(#", "stack": { "label": "stack me/now" }"#), gh: github.run)
        #expect(github.calls.first?[1].hasSuffix("/labels/stack%20me%2Fnow") == true)
    }

    // MARK: decompose

    func decomposed(issueLabels: [String], stackLabel: String?) -> [String]? {
        let world = FinishTests.World(column: "In Progress")
        world.board.labels[7] = issueLabels
        var context = FinishTests.context
        context.stackLabel = stackLabel
        let answer = fileIssue(
            token: FinishTests.token(.engineer, .decompose, "In Progress"), key: "task-1",
            title: "Task", body: "Do it.", labels: ["type:feature"], decomposing: true,
            board: world.board, context: context)
        #expect(answer.kind == "filed")
        return world.board.created.first?.labels
    }

    @Test("decompose from a labelled issue files the task with the label")
    func copiesLabel() {
        #expect(
            decomposed(issueLabels: ["type:design", "stackable"], stackLabel: "stackable")
                == ["type:feature", "stackable"])
    }

    @Test("decompose from an unlabelled issue, or with stack unset, doesn't add it")
    func leavesLabel() {
        #expect(
            decomposed(issueLabels: ["type:design"], stackLabel: "stackable") == ["type:feature"])
        #expect(
            decomposed(issueLabels: ["type:design", "stackable"], stackLabel: nil)
                == ["type:feature"])
    }

    @Test("file-issue never copies the label")
    func fileIssueLeavesLabel() {
        let world = FinishTests.World(column: "In Progress")
        world.board.labels[7] = ["stackable"]
        var context = FinishTests.context
        context.stackLabel = "stackable"
        _ = fileIssue(
            token: FinishTests.token(.engineer, .start, "In Progress"), key: "gap", title: "Gap",
            body: "A gap.", labels: ["type:bug"], decomposing: false, board: world.board,
            context: context)
        #expect(world.board.created.first?.labels == ["type:bug"])
    }
}
