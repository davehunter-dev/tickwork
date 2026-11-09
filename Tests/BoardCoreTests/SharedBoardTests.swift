// Several repositories can share one board, and their issue numbers collide.
// Each consumer reads, caches and moves only its own repository's cards.
//

import Foundation
import Testing

@testable import BoardCore

@Suite("A board several repositories share")
struct SharedBoardTests {

    static let fields = #"""
        {"fields": [{"name": "Status", "id": "status", "options": [
            {"name": "Ready", "id": "opt-ready"}, {"name": "Human Review", "id": "opt-review"},
            {"name": "Done", "id": "opt-done"}]}]}
        """#

    /// Both repositories' #7, as a read that ignored `repo:` would return them.
    static let items = #"""
        {"items": [
            {"id": "card-b7", "status": "Human Review",
             "content": {"number": 7, "repository": "example-org/b", "title": "B's seven"}},
            {"id": "card-a7", "status": "Ready",
             "content": {"number": 7, "repository": "example-org/a", "title": "A's seven"}},
            {"id": "card-b8", "status": "Human Review",
             "content": {"number": 8, "repository": "example-org/b", "title": "B's eight"}}]}
        """#

    /// A consumer of project `number` whose `loop.json` names `repository`.
    func configuration(_ repository: String, project number: Int) throws -> LoopConfiguration {
        let json = """
            {"repository": "\(repository)", "project": {"owner": "example-org", "number": \(number)},
             "owner": "example-owner", "mainRedLabels": [], "agents": []}
            """
        return try JSONDecoder().decode(LoopConfiguration.self, from: Data(json.utf8))
    }

    /// A board answering every item read with `items`, recording the calls that aren't reads.
    func board(
        _ configuration: LoopConfiguration, reads: @escaping () -> Void = {},
        edits: @escaping ([String]) -> Void = { _ in }
    ) -> GitHubBoard {
        GitHubBoard(configuration: configuration) { arguments in
            switch arguments.prefix(2) {
            case ["project", "item-list"]:
                reads()
                return Self.items
            case ["project", "field-list"]: return Self.fields
            case ["project", "view"]: return "project-id\n"
            default:
                edits(arguments)
                return ""
            }
        }
    }

    func clearCaches(project number: Int) {
        let temporary = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp"
        try? FileManager.default.removeItem(
            at: URL(fileURLWithPath: temporary).appendingPathComponent(
                "board-example-org-\(number)"))
    }

    @Test("A consumer sees only its own repository's cards, however loop.json cases the name")
    func ownCardsOnly() throws {
        clearCaches(project: 9180)
        defer { clearCaches(project: 9180) }

        let snapshot = try board(configuration("Example-Org/A", project: 9180))
            .snapshot(refresh: true)
        #expect(snapshot.items.map(\.id) == ["card-a7"])
        #expect(snapshot.column(of: 7) == "Ready")
        #expect(snapshot.item(number: 8) == nil)
    }

    @Test("A move takes this repository's card, not another's with the same number")
    func moveOwnCard() throws {
        clearCaches(project: 9181)
        defer { clearCaches(project: 9181) }

        var edits: [[String]] = []
        let consumer = board(
            try configuration("example-org/a", project: 9181), edits: { edits.append($0) })

        // B's #7 is in Human Review, and A's is not.
        #expect(throws: BoardError.self) { try consumer.move(7, to: "Done", from: "Human Review") }
        // B's #8 is no card of A's.
        #expect(throws: BoardError.self) { try consumer.move(8, to: "Done", from: nil) }
        #expect(edits.isEmpty)

        try consumer.move(7, to: "Human Review", from: "Ready")
        #expect(edits.count == 1)
        #expect(edits.first?.contains("card-a7") == true)
        #expect(edits.first?.contains("card-b7") == false)
    }

    @Test("Consumers of one board keep separate caches")
    func separateCaches() throws {
        clearCaches(project: 9182)
        defer { clearCaches(project: 9182) }

        var reads = 0
        let a = board(try configuration("example-org/a", project: 9182), reads: { reads += 1 })
        let b = board(try configuration("example-org/b", project: 9182), reads: { reads += 1 })

        #expect(try a.snapshot(refresh: false).items.map(\.id) == ["card-a7"])
        // B's read is its own, not A's cached one.
        #expect(try b.snapshot(refresh: false).items.map(\.id) == ["card-b7", "card-b8"])
        #expect(reads == 2)

        // A's move writes through to A's cache and leaves B's #7 where it was.
        try a.move(7, to: "Human Review", from: nil)
        let rereadA = board(
            try configuration("example-org/a", project: 9182), reads: { reads += 1 })
        let rereadB = board(
            try configuration("example-org/b", project: 9182), reads: { reads += 1 })
        #expect(try rereadA.snapshot(refresh: false).column(of: 7) == "Human Review")
        #expect(try rereadB.snapshot(refresh: false).column(of: 7) == "Human Review")
        #expect(try rereadB.snapshot(refresh: false).item(number: 7)?.id == "card-b7")
        #expect(reads == 2)
    }

    @Test("A card with a number and no repository is refused, not taken as this one's")
    func unownedCardRefused() {
        let json =
            #"{"items": [{"id": "x", "status": "Ready", "content": {"number": 7, "title": "?"}}]}"#
        #expect(throws: BoardError.self) {
            try Board.parseItems(json, repository: "example-org/a")
        }
    }
}
