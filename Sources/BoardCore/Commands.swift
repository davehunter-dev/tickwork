import Foundation

/// Every column the board is read for, in the order work flows through them.
func show(_ board: Board, workflow: Workflow = .standard) {
    print(columnsText(board, columns: workflow.columns.read), terminator: "")
}

/// Every column a tick can take work from or repair, which is every column read
/// but the untriaged, with who holds each card and what the budget
/// has left. A tick reads this once, where it would otherwise read a column at a
/// time.
func workingText(_ board: Board, budget: GraphQLBudget, workflow: Workflow = .standard)
    -> String
{
    let columns = workflow.columns.read.filter { $0 != workflow.columns.backlog }
    return columnsText(board, columns: columns, assignees: true)
        + "GraphQL budget: \(budget.text)\n"
}

private func columnsText(_ board: Board, columns: [String], assignees: Bool = false) -> String {
    var text = ""
    for column in columns {
        let cards = board.items.filter { $0.status == column }
        guard !cards.isEmpty else { continue }
        text += "[\(column)]\n"
        for card in cards {
            let holder =
                assignees && !card.assignees.isEmpty
                ? "  (\(card.assignees.joined(separator: ", ")))" : ""
            text += "   #\(card.number)  \(card.title)\(holder)\n"
        }
        text += "\n"
    }
    return text
}

/// A Markdown heading's text, normalised, or `nil` where the line is not one.
///
/// **Normalised rather than matched against one spelling**, because the
/// section used to be found by comparing a trimmed, lowercased line against the
/// literal `"## dependencies"`. `##   Dependencies` is valid Markdown, reads
/// identically to a person, and matched nothing. Every dependency under such a
/// heading went unrecognised, with no error to say so, and the card read as
/// unblocked while its blockers were still open. `blockers` exists so that work
/// is never started on top of an unmerged dependency, and a heading it fails to
/// recognise lets exactly that happen without anyone noticing.
///
/// **The level is not part of the answer either.** `### Dependencies` had the
/// same shape and the same silence. What the heading says is the question; how
/// deeply it is nested is not, and no reader of an issue would think otherwise.
///
/// **Whitespace after the hashes is required, and that is what keeps `#303` out.**
/// A bare reference at the start of a line begins with `#` and would otherwise
/// read as a heading called `303` — ending the section it sits in, and taking
/// every number after it with it. Markdown requires the space for the same
/// reason.
func headingText(_ line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("#") else { return nil }

    let afterHashes = trimmed.drop(while: { $0 == "#" })
    guard let first = afterHashes.first, first == " " || first == "\t" else { return nil }

    // `split` on whitespace drops the empty runs, so any amount of it between the
    // words collapses to one and the comparison has a single spelling to make.
    return
        afterHashes
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
        .lowercased()
}

/// The issue numbers a `## Dependencies` section names.
///
/// `AGENTS.md` gives that section's format as `#N`, so this reads exactly that
/// and nothing else. A section reaching the end of the body takes the rest of it;
/// any other heading ends it.
///
/// Prose naming no number — "the Swift projection child" — yields nothing, and
/// that is not a parser to improve. A dependency the loop can act on is a number,
/// and a section without one is invisible here however carefully it is worded;
/// `dependencyDrift` below is what makes that visible rather than silent.
func dependenciesNamedInBody(_ body: String) -> [Int] {
    let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard let start = lines.firstIndex(where: { headingText($0) == "dependencies" }) else {
        return []
    }

    var numbers: [Int] = []
    var seen: Set<Int> = []
    for line in lines[(start + 1)...] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Any heading ends the section, found the same way the start was. Two
        // notions of "heading" in one function is how the start came to accept
        // one spelling while the end accepted a family of them.
        if headingText(line) != nil { break }

        // `Part of #N.` is the epic link, which `AGENTS.md` puts at the foot of
        // an issue — so it lands inside this section whenever Dependencies is the
        // last heading, which is where the template puts it.
        //
        // **An epic is never a dependency, and reading one as a blocker is worse
        // than missing a real one.** An epic closes when its children do, so a
        // child that reported its own epic would be held by something that
        // cannot close until the child itself has: every child of every open
        // epic, blocked forever, by a line the author wrote to say where the
        // work belongs. The chain this was written for only escaped it because
        // its epic happened to be closed already.
        if trimmed.lowercased().hasPrefix("part of") { continue }

        var digits = ""
        var reading = false
        for character in line {
            if character == "#" {
                reading = true
                digits = ""
                continue
            }
            if reading, character.isNumber {
                digits.append(character)
                continue
            }
            if reading {
                if let number = Int(digits), seen.insert(number).inserted { numbers.append(number) }
                reading = false
                digits = ""
            }
        }
        if reading, let number = Int(digits), seen.insert(number).inserted {
            numbers.append(number)
        }
    }
    return numbers
}

/// Prints what still holds an issue, one number a line. Nothing printed means
/// nothing is holding it.
func blockers(of issue: Int, on board: BoardProvider) throws {
    try board.blockers(of: issue).forEach { print($0) }
}

/// Says on stderr when the two records disagree about something still open.
///
/// **Only what is still open, because the rest degrades into noise as the work
/// lands.** A declared dependency that has closed needs no relation: entering one
/// against merged work changes no reader's answer. Reporting it anyway is not one
/// stale line but the steady state — every issue in a chain would acquire a
/// permanent warning as its predecessors merged, printed on every candidate a
/// tick walks past, until the line that finally reports a *live* missing relation
/// arrives in a stream nobody has been able to act on for weeks. A warning that is
/// usually noise is read as noise on the day it is not, and that day is the whole
/// of what this verb is about.
///
/// **What that gives up is catching a typo'd number**, which is neither open nor
/// a relation and is therefore now silent here. Telling a typo from a closed
/// dependency needs a call per number to ask whether it exists at all — on the
/// skip's path, for every closed predecessor of every candidate, out of the
/// GraphQL budget that moving a card also needs. That is the wrong trade for a
/// one-time authoring mistake, which wants an audit rather than a line printed
/// thousands of times in the hope somebody reads one.
///
/// **Stderr, and never stdout.** The skip reads this verb's stdout and treats
/// anything there as a blocker, so a warning printed beside the numbers would
/// hold an item that nothing is holding. It goes where a person reading a tick's
/// output will see it and the parser will not.
///
/// Reported rather than repaired. Entering the relation is a write to somebody
/// else's issue, and a verb the skip calls on every candidate item is the last
/// place that should be making one.
func reportDependencyDrift(on issue: Int, openDeclared: [Int], related: [Int]) {
    let missing = openDeclared.filter { !related.contains($0) }
    guard !missing.isEmpty else { return }
    let list = missing.map { "#\($0)" }.joined(separator: ", ")
    FileHandle.standardError.write(
        Data(
            ("board: #\(issue) declares \(list) in ## Dependencies, still open, "
                + "and GitHub records no blocking relation for them; "
                + "add them so every reader of the board agrees\n").utf8))
}

/// A blocking relation as GitHub records it: the number a person writes, and the
/// database id its endpoints take.
///
/// **Two identifiers for one issue, and the endpoints do not agree on which.**
/// The relation is read and written under `/issues/<number>/dependencies/`, but
/// the blocker inside it is named by `id` — so the DELETE path is the one place
/// where passing the number a person wrote would name a different issue
/// entirely, silently and successfully. Carrying the pair together is what keeps
/// that from being a bug somebody finds by deleting the wrong edge.
struct BlockingRelation: Equatable {
    let number: Int
    let id: Int
}

/// The relations a `blocked_by` listing carries.
///
/// Parsed here rather than shaped by `--jq`, for the reason `declarations` gives
/// one function down: the rule is worth a test and the call around it is not.
func blockingRelations(inJSON json: String) -> [BlockingRelation] {
    guard let data = json.data(using: .utf8),
        let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { return [] }

    return rows.compactMap { row in
        guard let number = row["number"] as? Int, let id = row["id"] as? Int else { return nil }
        return BlockingRelation(number: number, id: id)
    }
}

/// Enters a blocking relation, so the record the board acts on agrees with the
/// `## Dependencies` prose beside it.
///
/// **Why this is a verb rather than the REST call it wraps.** The account the
/// loop runs as denies `gh api` any line carrying a write flag — see "What a
/// consumer's accounts need" in docs/loop.md — and that denial is anchored on
/// the flags rather than on the endpoint, deliberately, because no allow pattern can
/// say "read only". So it catches a dependency write along with the merges it
/// was written for, and no permit can carve one out: a denial beats a grant and
/// a glob cannot say "except here". This verb is the sanctioned exception, and
/// its shape is the argument for it — it can write a blocking relation and
/// nothing else, where a loosened pattern would have to permit every other write
/// that spells itself the same way.
///
/// **Idempotent, and says which it did.** A tick that files an issue, enters
/// three relations and fails on the fourth is re-run from the top, so a verb
/// that refused an entry already made would turn one transient failure into a
/// card nobody can repair. Adding what is already there is the same desired
/// state, arrived at twice.
func addBlocker(_ blocker: Int, of issue: Int, on board: BoardProvider) throws {
    guard blocker != issue else {
        throw BoardError("#\(issue) cannot block itself")
    }
    if try board.addBlocker(blocker, to: issue) {
        print("#\(issue) blocked by #\(blocker)")
    } else {
        print("#\(issue) already blocked by #\(blocker)")
    }
}

/// Removes a blocking relation that should not stand.
///
/// **The half with no backstop, which is why it is the more important of the
/// two.** `blockers` reads the `## Dependencies` section as well as the relation,
/// so a dependency entered only as prose still holds the card and the drift is
/// merely reported. Nothing plays that role in reverse: there is no sentence an
/// author can write that unsays a relation, so a wrong one holds the card until
/// something deletes it. One card sat in `Ready` behind another for exactly that
/// reason, with its own body denying the edge in as many words and the
/// design it came from having moved the criteria
/// that carried it — every record a person reads agreed, and the card stayed put.
///
func removeBlocker(_ blocker: Int, of issue: Int, on board: BoardProvider) throws {
    // Idempotent in the same direction as `addBlocker`, and for the same reason:
    // not-there is the state the caller asked for.
    if try board.removeBlocker(blocker, from: issue) {
        print("#\(issue) no longer blocked by #\(blocker)")
    } else {
        print("#\(issue) is not blocked by #\(blocker)")
    }
}

/// Takes the claim, and says what happened rather than assuming it worked.
///
/// **Read, add, read back, in that order, and the last one is not optional.**
/// `--add-assignee` adds rather than refuses, so two agents that read the same
/// empty list can each land a name and neither call fails. The read back is what
/// settles it, and it has three answers: this login alone means the item is
/// ours; this login among others means somebody arrived first; this login absent
/// means the claim did not take, which is what an account without write access
/// looks like, because GitHub drops such an assignee silently.
func claim(_ issue: Int, on board: BoardProvider) throws {
    let me = try board.viewer()
    // A refusal is thrown rather than printed, so it leaves by the same door as
    // every other one: stderr, with the prefix, and an exit code. A caller
    // capturing stdout to log which agent took an item should never find the
    // reason it did not there.
    switch try board.claim(issue, as: me) {
    case .claimed:
        print("#\(issue) claimed by \(me)")
    case .held(let holders):
        throw BoardError("held by \(holders.joined(separator: ", "))")
    case .didNotTake:
        throw BoardError("the claim did not take; this account may have no write access")
    }
}

/// Gives the claim back.
///
/// Every column belongs to a role, so a claim left on a card handed to another
/// role is a card that role will never take. A claim covers the tick holding it
/// rather than the life of the item.
func release(_ issue: Int, on board: BoardProvider) throws {
    try board.release(issue, login: board.viewer())
    print("#\(issue) released")
}

/// One open issue and the dependency numbers its body names.
struct DeclaredDependencies: Equatable {
    let issue: Int
    let declared: [Int]
}

/// Which declared numbers name nothing in this repository.
///
/// A pure function over what the reads found, so the rule can be asserted
/// without reaching GitHub — the calls around it are the part that cannot be
/// tested and this is the part worth testing.
///
/// **`known` is every number that resolves to an issue or a pull request**,
/// rather than every open one: depending on closed work is ordinary and correct,
/// and a number is a typo only when nothing of that number exists at all. That
/// is the whole difference between this verb and the drift line `blockers`
/// prints, which can only afford to know what is open.
///
/// An issue naming nothing wrong contributes no row, so a clean board produces
/// an empty result rather than a row per issue saying it is fine.
func unknownDependencies(
    in declarations: [DeclaredDependencies], known: Set<Int>
) -> [DeclaredDependencies] {
    declarations.compactMap { declaration in
        let unknown = declaration.declared.filter { !known.contains($0) }
        guard !unknown.isEmpty else { return nil }
        return DeclaredDependencies(issue: declaration.issue, declared: unknown)
    }
}

/// The declarations an issue listing carries, as `gh issue list --json` gives it.
///
/// Parsed here rather than shaped by `jq`, because a body is arbitrary prose:
/// every separator a `--jq` template could put between the number and the body
/// is one an issue body may legally contain, and the parse would then split in
/// the middle of somebody's sentence. JSON already delimits it.
func declarations(inIssueListing json: String) -> [DeclaredDependencies] {
    declarations(in: (try? issueSummaries(listingJSON: json)) ?? [])
}

func declarations(in issues: [IssueSummary]) -> [DeclaredDependencies] {
    issues.compactMap { issue in
        let declared = dependenciesNamedInBody(issue.body)
        return declared.isEmpty
            ? nil : DeclaredDependencies(issue: issue.number, declared: declared)
    }
}

/// The issues a `gh issue list --json number,body` listing carries. Parsed here
/// rather than shaped by `jq`, because a body is arbitrary prose: every separator
/// a `--jq` template could put between the number and the body is one an issue
/// body may legally contain. JSON already delimits it.
func issueSummaries(listingJSON json: String) throws -> [IssueSummary] {
    guard let rows = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
    else {
        throw BoardError("the issue listing came back as something this could not read")
    }
    return rows.compactMap { row in
        guard let number = row["number"] as? Int else { return nil }
        return IssueSummary(number: number, body: row["body"] as? String ?? "")
    }
}

/// Reports `## Dependencies` entries that name no issue in this repository.
///
/// **Off the skip's path, which is the whole point.** `blockers` runs on every
/// candidate a tick walks past, so it cannot afford a lookup per number and
/// therefore cannot tell a typo'd number from a closed dependency — both are
/// simply absent from the open set. This is the audit that can afford it: run by
/// hand or on a schedule, over the board once, spending the calls `blockers`
/// deliberately does not.
///
/// **Two listings, then a lookup only for what they could not settle.** One gives
/// every open issue's number and body, which is where the declarations are; the
/// other gives every number that exists, open or closed, which is what a
/// declaration is checked against. A number missing from the second is either a
/// typo or an issue past that listing's limit, and only those few are looked up
/// one at a time — so the cost is one call per genuinely suspicious number rather
/// than one per dependency on the board.
///
/// Reported and not repaired. Correcting a number is a write to somebody else's
/// issue, and which number was meant is a question only its author can answer.
func auditDependencies(on board: BoardProvider) throws {
    let limit = 1000
    let declared = declarations(in: try board.openIssues(limit: limit))
    var known = try board.issueNumbers(limit: limit)

    // A listing that came back exactly full may have been cut off, and here that
    // would report a real issue as a typo — the one wrong answer this verb must
    // not give. So the suspicious numbers are confirmed individually rather than
    // trusted to the listing.
    var unconfirmed: [Int] = []
    let suspicious = Set(declared.flatMap(\.declared)).subtracting(known)
    for number in suspicious.sorted() {
        switch board.existence(of: number) {
        case .exists:
            known.insert(number)
        case .unconfirmed:
            // Treated as existing for the report below, so a failure to ask
            // cannot become an accusation, and named separately so the audit is
            // honest about what it did not manage to check.
            known.insert(number)
            unconfirmed.append(number)
        case .missing:
            break
        }
    }

    let unknown = unknownDependencies(in: declared, known: known)

    // **How much was checked, always, and not only when something is wrong.**
    // A clean board and a parser that read nothing at all both produce an empty
    // result, and the whole value of an audit is knowing which one it is. The
    // counts are what tells them apart, so they are printed either way.
    let checked = declared.reduce(0) { $0 + $1.declared.count }
    print("checked \(checked) dependencies declared across \(declared.count) open issues")

    if !unconfirmed.isEmpty {
        let list = unconfirmed.map { "#\($0)" }.joined(separator: ", ")
        print("could not confirm \(list) — asked and got no answer, so not reported below")
    }

    guard !unknown.isEmpty else {
        print("none of them names a missing issue")
        return
    }

    for row in unknown.sorted(by: { $0.issue < $1.issue }) {
        let list = row.declared.sorted().map { "#\($0)" }.joined(separator: ", ")
        print("#\(row.issue) declares \(list) in ## Dependencies, naming no issue here")
    }
}

/// What a lookup found, with "could not ask" kept apart from "not there".
///
/// **Three answers rather than two, because collapsing them gives the one wrong
/// answer this verb exists to avoid.** A rate limit, a dropped connection or an
/// expired token would otherwise turn every real issue it touched into a
/// reported typo — and on a schedule that is not one bad number but every
/// suspicious number at once, in a report that is then confidently wrong. A
/// report that is wrong a few times is one nobody reads on the day it is right.
enum IssueExistence {
    case exists
    case missing
    case unconfirmed
}
