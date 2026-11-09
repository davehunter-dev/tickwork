// The tool's project coordinates come from `loop.json`, not from constants. A sample project shows each one is read.
//

import Foundation
import Testing

@testable import BoardCore

@Suite("The loop's arrangement, read from loop.json")
struct ConfigurationTests {

    let sample = """
        {
          "repository": "example-org/widgets",
          "project": { "owner": "example-org", "number": 7 },
          "owner": "widget-owner",
          "mainRedLabels": ["area:ci", "priority:high"],
          "agents": [
            { "login": "agent-one", "roles": ["orchestrator", "reviewer", "engineer"] },
            { "login": "agent-two", "roles": ["reviewer", "designer"] }
          ]
        }
        """

    /// A fresh directory holding `files`, removed by the caller.
    func directory(with files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loop-configuration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, contents) in files {
            try Data(contents.utf8).write(to: root.appendingPathComponent(name))
        }
        return root
    }

    @Test("Every coordinate is read from the file")
    func coordinates() throws {
        let configuration = try JSONDecoder().decode(
            LoopConfiguration.self, from: Data(sample.utf8))
        #expect(configuration.repository == "example-org/widgets")
        #expect(configuration.project == .init(owner: "example-org", number: 7))
        #expect(configuration.owner == "widget-owner")
        #expect(configuration.mainRedLabels == ["area:ci", "priority:high"])
        #expect(configuration.agents.map(\.login) == ["agent-one", "agent-two"])
    }

    @Test("A file without mainRedLabels adds no label to type:bug")
    func noMainRedLabels() throws {
        let trimmed = sample.replacingOccurrences(
            of: "\"mainRedLabels\": [\"area:ci\", \"priority:high\"],", with: "")
        let configuration = try JSONDecoder().decode(
            LoopConfiguration.self, from: Data(trimmed.utf8))
        #expect(configuration.mainRedLabels.isEmpty)
    }

    @Test("A file the tool can't read is an error that names it, not a default")
    func unreadable() throws {
        let root = try directory(with: ["loop.json": #"{"repository": "example-org/widgets"}"#])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: BoardError.self) {
            try LoopConfiguration.read(file: root.appendingPathComponent("loop.json"))
        }
    }
}
