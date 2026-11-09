// The board is read only for the columns the loop works, so finished work and
// personal columns can grow without reaching the fetch limit.
//

import Foundation
import Testing

@testable import BoardCore

@Suite("Which columns the board is read for")
struct BoardColumnsReadTests {

    func rows(_ count: Int) -> String {
        let row =
            #"{"id": "a", "status": "Ready", "content": {"number": 1, "repository": "example-org/example", "title": "One"}}"#
        return #"{"items": ["# + Array(repeating: row, count: count).joined(separator: ",") + "]}"
    }

    func item(_ number: Int, _ status: String) -> Item {
        Item(
            id: "\(number)", number: number, title: "Issue \(number)", status: status, assignees: []
        )
    }

    @Test("Every column the loop names is read, Backlog included, and Done is not")
    func readColumns() {
        let columns = Workflow.standard.columns
        #expect(
            columns.read == [
                "Backlog", "Ready", "In Design", "In Progress", "Agent Review", "Human Review",
                "Needs Human",
            ])
    }

    @Test("A renamed Done is the one left out")
    func renamedDone() throws {
        let json = #"{"columns": {"done": "Shipped", "backlog": "Inbox"}}"#
        let workflow = try JSONDecoder().decode(Workflow.self, from: Data(json.utf8))
        #expect(workflow.columns.read.first == "Inbox")
        #expect(!workflow.columns.read.contains("Shipped"))
        // Today's name for it is now a column the loop does not name.
        #expect(!workflow.columns.read.contains("Done"))
    }

    @Test("The fetch filters on the repository and the read columns, each quoted")
    func fetchFilters() throws {
        let board = GitHubBoard(configuration: Coordinates.configuration, run: { _ in "" })
        let arguments = try board.itemListArguments()
        let query = try #require(arguments.firstIndex(of: "--query")).advanced(by: 1)
        #expect(
            arguments[query]
                == #"repo:example-org/example status:"Backlog","Ready","In Design","In Progress","Agent Review","Human Review","Needs Human""#
        )
        #expect(arguments.contains(String(itemFetchLimit)))
    }

    @Test("A column name the filter cannot quote is refused")
    func quoteRefused() {
        #expect(throws: BoardError.self) { try Board.statusQuery(["Ready", #"The "Big" One"#]) }
    }

    @Test("A fetch one short of the limit is believed, and one at it is not")
    func truncationBoundary() throws {
        try Board.requireUnderFetchLimit(rows(itemFetchLimit - 1))
        #expect(throws: BoardError.self) { try Board.requireUnderFetchLimit(rows(itemFetchLimit)) }
    }

    @Test("A draft card counts toward the limit though it is no Item")
    func draftsCount() throws {
        let draft = #"{"id": "d", "status": "Ready", "content": {"title": "Draft"}}"#
        let json =
            #"{"items": ["# + Array(repeating: draft, count: itemFetchLimit).joined(separator: ",")
            + "]}"
        #expect(try Board.parseItems(json, repository: "example-org/example").isEmpty)
        #expect(throws: BoardError.self) { try Board.requireUnderFetchLimit(json) }
    }

    @Test("A card the read did not return says so rather than claiming no column")
    func unreadCard() {
        let board = Board(
            items: [item(1, "Ready")], statusFieldID: "status", optionIDs: [:], columns: [])
        #expect(board.column(of: 1) == "Ready")
        #expect(board.column(of: 2) == "(not in a column the loop reads)")
    }

    @Test("A card moves into Done, which the read leaves out, by the field list's option")
    func moveIntoDone() throws {
        // A project of its own, so the cache under it holds only this test's read.
        let json = #"""
            {"repository": "example-org/example", "project": {"owner": "example-org", "number": 9170},
             "owner": "example-owner", "mainRedLabels": [], "agents": []}
            """#
        let configuration = try JSONDecoder().decode(LoopConfiguration.self, from: Data(json.utf8))
        let cache = Cache(
            owner: "example-org", projectNumber: 9170, repository: "example-org/example")
        try? FileManager.default.removeItem(at: cache.directory)
        defer { try? FileManager.default.removeItem(at: cache.directory) }

        var edits: [[String]] = []
        let board = GitHubBoard(configuration: configuration) { arguments in
            switch arguments.prefix(2) {
            case ["project", "item-list"]:
                return
                    #"{"items": [{"id": "card-7", "status": "Human Review", "content": {"number": 7, "repository": "example-org/example", "title": "Seven"}}]}"#
            case ["project", "field-list"]:
                return #"""
                    {"fields": [{"name": "Status", "id": "status", "options": [
                        {"name": "Human Review", "id": "opt-review"}, {"name": "Done", "id": "opt-done"}]}]}
                    """#
            case ["project", "view"]:
                return "project-id\n"
            default:
                edits.append(arguments)
                return ""
            }
        }

        try board.move(7, to: "Done", from: "Human Review")

        #expect(edits.count == 1)
        #expect(edits.first?.contains("opt-done") == true)
        #expect(edits.first?.contains("card-7") == true)
    }

    @Test("An issue is added to the board, read for its column, and placed by its card")
    func addAndPlace() throws {
        // A project of its own, so the cache under it holds only this test's read.
        let json = #"""
            {"repository": "example-org/example", "project": {"owner": "example-org", "number": 9171},
             "owner": "example-owner", "mainRedLabels": [], "agents": []}
            """#
        let configuration = try JSONDecoder().decode(LoopConfiguration.self, from: Data(json.utf8))
        let cache = Cache(
            owner: "example-org", projectNumber: 9171, repository: "example-org/example")
        try? FileManager.default.removeItem(at: cache.directory)
        defer { try? FileManager.default.removeItem(at: cache.directory) }

        var calls: [[String]] = []
        let board = GitHubBoard(configuration: configuration) { arguments in
            calls.append(arguments)
            switch arguments.prefix(2) {
            case ["project", "item-add"]:
                return "card-12\n"
            case ["api", "graphql"]:
                return "Intake\n"
            case ["project", "item-list"]:
                return #"{"items": []}"#
            case ["project", "field-list"]:
                return #"""
                    {"fields": [{"name": "Status", "id": "status", "options": [
                        {"name": "Intake", "id": "opt-intake"}, {"name": "Backlog", "id": "opt-backlog"}]}]}
                    """#
            case ["project", "view"]:
                return "project-id\n"
            default:
                return ""
            }
        }

        #expect(try board.addToBoard(12) == "Intake")
        let add = try #require(calls.first)
        #expect(add.contains("https://github.com/example-org/example/issues/12"))
        #expect(calls[1].contains("id=card-12"))

        try board.place(12, in: "Backlog")
        let edit = try #require(calls.last)
        #expect(edit.prefix(2) == ["project", "item-edit"])
        #expect(edit.contains("card-12") && edit.contains("opt-backlog"))
        #expect(throws: BoardError.self) { try board.place(12, in: "Someday") }
    }

    @Test("An add that races the project's add workflow is asked again for the card it made")
    func addRacingWorkflow() throws {
        let json = #"""
            {"repository": "example-org/example", "project": {"owner": "example-org", "number": 9172},
             "owner": "example-owner", "mainRedLabels": [], "agents": []}
            """#
        let configuration = try JSONDecoder().decode(LoopConfiguration.self, from: Data(json.utf8))

        var adds = 0
        let board = GitHubBoard(configuration: configuration) { arguments in
            switch arguments.prefix(2) {
            case ["project", "item-add"]:
                adds += 1
                if adds == 1 {
                    throw BoardError(
                        "GraphQL: Content already exists in this project (addProjectV2ItemById)")
                }
                return "card-12\n"
            case ["api", "graphql"]:
                #expect(arguments.contains("id=card-12"))
                return "Intake\n"
            default:
                return ""
            }
        }

        #expect(try board.addToBoard(12) == "Intake")
        #expect(adds == 2)
    }

    @Test("Listing Done or a personal column is refused rather than answered with none")
    func unreadColumnRefused() throws {
        let columns = Workflow.standard.columns
        try columns.requireRead("Backlog")
        #expect(throws: BoardError.self) { try columns.requireRead("Done") }
        #expect(throws: BoardError.self) { try columns.requireRead("Someday") }
    }
}
