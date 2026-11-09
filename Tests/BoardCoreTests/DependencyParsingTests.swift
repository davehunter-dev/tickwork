// What `blockers` reads out of an issue body.
//
// This is string handling: it decides whether a card
// is held, it is invisible when it is wrong, and the one bug it has already had
// printed nothing where it should have printed a number. Every case below is
// one a tick walks through on its way past a `Ready` item.
//

import Testing

@testable import BoardCore

@Suite("Dependencies declared in an issue body")
struct DependencyParsingTests {

    @Test("Reads the numbers a Dependencies section names")
    func readsDeclaredNumbers() {
        let body = """
            ## Scope

            Something.

            ## Dependencies

            #303, #304
            """

        #expect(dependenciesNamedInBody(body) == [303, 304])
    }

    @Test("Ignores the epic link, which sits inside the section")
    func ignoresTheEpicLink() {
        // The bug this was opened for. `AGENTS.md` puts `Part of #N.` at the
        // foot of an issue, so it lands inside Dependencies whenever that is the
        // last heading — which is where the template puts it. An epic closes
        // when its children do, so a child reporting its own epic would be held
        // by something that cannot close until the child has.
        let body = """
            ## Dependencies

            #303, #304

            Part of #299.
            """

        #expect(dependenciesNamedInBody(body) == [303, 304])
    }

    @Test("An epic link alone leaves nothing behind")
    func epicLinkAlone() {
        // The shape that made the bug invisible: it printed nothing only because
        // the epic was already closed, so the wrong answer and the right one looked
        // the same.
        let body = """
            ## Dependencies

            Part of #299.
            """

        #expect(dependenciesNamedInBody(body).isEmpty)
    }

    @Test("The section ends at the next heading")
    func sectionEndsAtNextHeading() {
        let body = """
            ## Dependencies

            #303

            ## Out of scope

            Not #999, which is a different piece of work.
            """

        #expect(dependenciesNamedInBody(body) == [303])
    }

    // The sequencing guidance: later work a task enables is Related,
    // never a blocker, and the task template puts that section after this one.
    @Test("Work a task enables, in Related, is not read as a blocker")
    func relatedIsNotABlocker() {
        let body = """
            ## Dependencies

            - #1048

            ## Related

            Enables #980, implemented with this effort rather than after it.
            """

        #expect(dependenciesNamedInBody(body) == [1048])
    }

    @Test("A number named twice is reported once")
    func numberNamedTwice() {
        let body = """
            ## Dependencies

            #303, and #303 again because it carries both halves.
            """

        #expect(dependenciesNamedInBody(body) == [303])
    }

    @Test("A body with no Dependencies section names nothing")
    func noSection() {
        let body = """
            ## Scope

            Something that depends on #303 in passing, which is not a
            declaration and must not be read as one.
            """

        #expect(dependenciesNamedInBody(body).isEmpty)
    }

    @Test("Prose naming no number names nothing")
    func proseWithoutNumbers() {
        // A real issue body says this. It is not a parser to improve — the drift
        // line is what makes it visible rather than silent — but it must not
        // throw or invent a number.
        let body = """
            ## Dependencies

            The Swift projection child.
            """

        #expect(dependenciesNamedInBody(body).isEmpty)
    }

    @Test("An empty body names nothing")
    func emptyBody() {
        #expect(dependenciesNamedInBody("").isEmpty)
    }

    @Test("The heading is matched whatever its case and surrounding whitespace")
    func headingCaseAndSurroundingWhitespace() {
        let body = """
              ## DEPENDENCIES

            #303
            """

        #expect(dependenciesNamedInBody(body) == [303])
    }

    @Test("A heading with extra spacing inside it is matched")
    func headingWithInternalSpacing() {
        // This once asserted the opposite: `##   Deps` is
        // valid Markdown and reads identically to a person, and matching one
        // spelling meant every dependency under it was silently ignored.
        let body = """
            ##   Dependencies

            #303
            """

        #expect(dependenciesNamedInBody(body) == [303])
    }

    @Test("The heading is matched at any level")
    func headingAtAnyLevel() {
        // Same shape and same silence as the spacing case: what the heading says
        // is the question, and how deeply it is nested is not.
        let body = """
            ### Dependencies

            #303
            """

        #expect(dependenciesNamedInBody(body) == [303])
    }

    @Test("A bare reference at the start of a line is not a heading")
    func aReferenceIsNotAHeading() {
        // The guard that makes normalising safe. `#303` begins with `#` and would
        // otherwise read as a heading called `303`, ending the section it sits in
        // and taking every number after it — which would be this fix causing the
        // exact failure it exists to remove.
        let body = """
            ## Dependencies

            #303
            #304
            """

        #expect(dependenciesNamedInBody(body) == [303, 304])
    }

    @Test("A heading ends the section whatever its level or spacing")
    func anyHeadingEndsTheSection() {
        let body = """
            ## Dependencies

            #303

            ###   Out of scope

            #999
            """

        #expect(dependenciesNamedInBody(body) == [303])
    }

    @Test("Order follows the body rather than the numbers")
    func orderFollowsTheBody() {
        // The caller prints these, and a reader comparing a report against an
        // issue should find them in the order the issue writes them.
        let body = """
            ## Dependencies

            #307, #304, #305
            """

        #expect(dependenciesNamedInBody(body) == [307, 304, 305])
    }
}

/// What the dependency audit reports, given what the two reads found.
///
/// The calls are the part that cannot be tested; this is the classification, and
/// it is the part that decides whether somebody is told about a typo. Its one
/// wrong answer would be calling a real issue missing, so both directions are
/// asserted rather than only the finding.
@Suite("Dependencies that name no issue")
struct UnknownDependencyTests {

    @Test("Reports a number nothing in the repository answers to")
    func reportsATypo() {
        let found = unknownDependencies(
            in: [DeclaredDependencies(issue: 250, declared: [3055])],
            known: [305, 306])

        #expect(found == [DeclaredDependencies(issue: 250, declared: [3055])])
    }

    @Test("Says nothing about a dependency that has closed")
    func closedIsNotMissing() {
        // The whole difference between this verb and the drift line `blockers`
        // prints: depending on finished work is ordinary, and only a number that
        // resolves to nothing at all is an authoring mistake.
        let found = unknownDependencies(
            in: [DeclaredDependencies(issue: 250, declared: [305])],
            known: [305])

        #expect(found.isEmpty)
    }

    @Test("Keeps the good numbers out of the report and the bad ones in")
    func reportsOnlyTheUnknownOnes() {
        let found = unknownDependencies(
            in: [DeclaredDependencies(issue: 250, declared: [305, 3055, 306])],
            known: [305, 306])

        #expect(found == [DeclaredDependencies(issue: 250, declared: [3055])])
    }

    @Test("An issue naming nothing wrong contributes no row")
    func aCleanBoardReportsNothing() {
        let found = unknownDependencies(
            in: [
                DeclaredDependencies(issue: 250, declared: [305]),
                DeclaredDependencies(issue: 251, declared: [250]),
            ],
            known: [305, 250])

        #expect(found.isEmpty)
    }

    @Test("Reads the declarations out of an issue listing rather than out of jq")
    func readsAListing() {
        // Parsed from JSON because a body is arbitrary prose: every separator a
        // `--jq` template could put between the number and the body is one a body
        // may legally contain.
        let listing = """
            [
              {"number": 250, "body": "## Dependencies\\n\\n#353, #3055\\n"},
              {"number": 251, "body": "No dependencies section at all."}
            ]
            """

        #expect(
            declarations(inIssueListing: listing)
                == [DeclaredDependencies(issue: 250, declared: [353, 3055])])
    }

    @Test("A 404 is not there; anything else is could not ask")
    func aFailureToAskIsNotAnAccusation() {
        // The distinction the audit rests on. `gh` leaves with the same exit
        // status for a 404 as for a rate limit or a dropped connection, so the
        // message is what separates them — and if that wording ever changes this
        // answers false, which reports a number as unconfirmed rather than as
        // missing. The safe half is the default.
        #expect(BoardError("gh: Not Found (HTTP 404)").isNotFound)

        #expect(BoardError("gh: API rate limit exceeded (HTTP 403)").isNotFound == false)
        #expect(BoardError("could not run gh: no such file").isNotFound == false)
        #expect(BoardError("dial tcp: lookup api.github.com: no such host").isNotFound == false)
        #expect(BoardError("gh: Bad credentials (HTTP 401)").isNotFound == false)
    }

    @Test("A body carrying a hash and a newline does not split the listing")
    func aBodyIsNotASeparator() {
        let listing = """
            [{"number": 250, "body": "Prose with #99 in it.\\n\\n## Dependencies\\n\\n#3055"}]
            """

        // The prose reference is outside the section, so only the declared one
        // is read — which is `dependenciesNamedInBody`'s rule, reached through
        // the listing parse rather than around it.
        #expect(
            declarations(inIssueListing: listing)
                == [DeclaredDependencies(issue: 250, declared: [3055])])
    }
}
