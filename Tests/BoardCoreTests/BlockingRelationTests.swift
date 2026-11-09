// What `add-blocker` and `remove-blocker` read out of a `blocked_by` listing.
//
// The rule under test is that a number and a database id stay paired. The
// endpoints take one of them in the path and the other in the prose a person
// writes, and the failure they invite is silent and destructive: a DELETE sent
// with the wrong identifier removes a relation that exists, on an issue nobody
// asked about, and reports success.
//

import Testing

@testable import BoardCore

@Suite("Blocking relations, as GitHub records them")
struct BlockingRelationTests {

    /// The listing shape `/issues/{number}/dependencies/blocked_by` returns,
    /// trimmed to the fields read, with invented numbers and ids.
    let listing = """
        [
          { "number": 8, "id": 1008, "state": "open" },
          { "number": 4, "id": 1004, "state": "closed" },
          { "number": 12, "id": 1012, "state": "open" }
        ]
        """

    @Test("Reads every relation, open or closed")
    func readsEveryRelation() {
        // Closed ones are kept, unlike in `blockers`. A relation that should not
        // stand is worth removing whether or not the issue behind it has since
        // closed, and a caller asking for one by number should be told the truth
        // about whether it is there.
        #expect(
            blockingRelations(inJSON: listing) == [
                BlockingRelation(number: 8, id: 1008),
                BlockingRelation(number: 4, id: 1004),
                BlockingRelation(number: 12, id: 1012),
            ])
    }

    @Test("The id a number carries is its own, not its neighbour's")
    func keepsThePairing() {
        // The bug the struct exists to prevent, asserted directly: the second
        // row's id belongs to the second row. A parse that read the two fields
        // into separate lists and zipped them would pass the count check above
        // and fail this one.
        let found = blockingRelations(inJSON: listing)
        #expect(found.first(where: { $0.number == 4 })?.id == 1004)
        #expect(found.first(where: { $0.number == 12 })?.id == 1012)
    }

    @Test("A row without an id is dropped rather than half-read")
    func dropsRowsMissingAnID() {
        // There is no useful thing to do with a relation whose id never arrived:
        // it cannot be deleted, and inventing a placeholder would put a number
        // where a path expects an id. Absent is the honest answer.
        let json = """
            [
              { "number": 8 },
              { "number": 12, "id": 1012 }
            ]
            """

        #expect(
            blockingRelations(inJSON: json) == [BlockingRelation(number: 12, id: 1012)])
    }

    @Test("Nothing at all reads as no relations")
    func emptyAndMalformed() {
        // An issue with no relations is the common case and must not look like a
        // failure; a body that is not a listing cannot be told apart from it
        // here, and the calls that matter fail on their own status first.
        #expect(blockingRelations(inJSON: "[]").isEmpty)
        #expect(blockingRelations(inJSON: "").isEmpty)
        #expect(blockingRelations(inJSON: "{\"message\":\"Not Found\"}").isEmpty)
    }
}
