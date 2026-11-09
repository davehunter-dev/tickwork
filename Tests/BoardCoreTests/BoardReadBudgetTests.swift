// What a board read costs, and what it leaves for the writes.
//
// A tick that refreshed the board once per column drained the hourly GraphQL
// budget, and the moves after it failed.
//

import Foundation
import Testing

@testable import BoardCore

@Suite("Board reads and the GraphQL budget")
struct BoardReadBudgetTests {

    @Test("Two refreshes inside the window cause one fetch")
    func refreshesCoalesce() {
        #expect(needsFetch(refresh: true, sinceFetched: nil, sinceWritten: nil))
        #expect(!needsFetch(refresh: true, sinceFetched: fetchRideWindow - 1, sinceWritten: 0))
    }

    @Test("A refresh after the window fetches again")
    func refreshAfterWindowFetches() {
        #expect(needsFetch(refresh: true, sinceFetched: fetchRideWindow, sinceWritten: 0))
    }

    @Test("A cached read fetches only once the cache has expired")
    func cachedReadUsesTheCache() {
        #expect(!needsFetch(refresh: false, sinceFetched: 60, sinceWritten: 60))
        #expect(needsFetch(refresh: false, sinceFetched: itemsTTL, sinceWritten: itemsTTL))
    }

    @Test("A move's write-through does not make a refresh believe an old fetch")
    func writeThroughIsNotAFetch() {
        #expect(needsFetch(refresh: true, sinceFetched: 120, sinceWritten: 0))
    }

    func budget(_ remaining: Int) -> GraphQLBudget {
        GraphQLBudget(remaining: remaining, limit: 5_000, reset: Date(timeIntervalSince1970: 0))
    }

    @Test("A read below the reserve is refused, naming what is left")
    func readBelowReserveRefuses() {
        #expect(throws: BoardError.self) { try budget(readReserve - 1).requireReadReserve() }
        do {
            try budget(412).requireReadReserve()
        } catch let error as BoardError {
            #expect(error.message.contains("412 of 5000"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("A read at the reserve runs")
    func readAtReserveRuns() throws {
        try budget(readReserve).requireReadReserve()
    }

    @Test("The rate limit's GraphQL half is read")
    func parsesRateLimit() throws {
        let json = """
            {"resources": {"core": {"limit": 5000, "remaining": 4999, "reset": 1},
                           "graphql": {"limit": 5000, "remaining": 3812, "reset": 1760627100}}}
            """
        #expect(
            try GraphQLBudget.parse(json)
                == GraphQLBudget(
                    remaining: 3812, limit: 5000, reset: Date(timeIntervalSince1970: 1_760_627_100))
        )
    }

    func item(_ number: Int, _ status: String, _ assignees: [String] = []) -> Item {
        Item(
            id: "\(number)", number: number, title: "Issue \(number)", status: status,
            assignees: assignees)
    }

    @Test("working lists every column but Backlog and Done, with who holds each card")
    func workingListsTheWorkingColumns() {
        let board = Board(
            items: [
                item(1, "Backlog"), item(2, "Ready"),
                item(3, "In Progress", ["agent-one"]), item(4, "Done"),
            ],
            statusFieldID: "status", optionIDs: [:], columns: Workflow.standard.columns.all)

        let text = workingText(board, budget: budget(3812))

        #expect(!text.contains("#1 "))
        #expect(!text.contains("#4 "))
        #expect(text.contains("[Ready]\n   #2  Issue 2\n"))
        #expect(text.contains("   #3  Issue 3  (agent-one)\n"))
        #expect(text.hasSuffix("GraphQL budget: \(budget(3812).text)\n"))
    }

    @Test("A card's assignees are read from the board")
    func parsesAssignees() throws {
        let json = """
            {"items": [{"id": "a", "status": "Ready", "assignees": ["agent-two"],
                        "content": {"number": 7, "repository": "example-org/example", "title": "Seven"}},
                       {"id": "b", "status": "Ready", "content": {"number": 8, "repository": "example-org/example", "title": "Eight"}}]}
            """
        let items = try Board.parseItems(json, repository: "example-org/example")
        #expect(items.map(\.assignees) == [["agent-two"], []])
    }
}
