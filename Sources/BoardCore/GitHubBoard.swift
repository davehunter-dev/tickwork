import Foundation

/// The board as a GitHub project, and its issues in `loop.json`'s `repository`.
///
/// Every call names that repository or that project, and no other: a pull
/// request in another repository is `SourceControl`'s.
final class GitHubBoard: BoardProvider {
    let repository: String
    let projectOwner: String
    let projectNumber: Int
    let workflow: Workflow
    private let run: GitHubRunner
    private let cache: Cache

    /// The snapshot this run last read. `move` resolves the card and the column
    /// against it, as it always has, so a sweep of moves after one read costs that
    /// one read.
    private var lastSnapshot: Board?

    init(configuration: LoopConfiguration, run: @escaping GitHubRunner = GitHub.run) {
        repository = configuration.repository
        projectOwner = configuration.project.owner
        projectNumber = configuration.project.number
        workflow = configuration.workflow
        self.run = run
        cache = Cache(owner: projectOwner, projectNumber: projectNumber, repository: repository)
    }

    // MARK: The board

    func snapshot(refresh: Bool) throws -> Board {
        let itemsJSON: String
        if needsFetch(
            refresh: refresh, sinceFetched: cache.age(of: cache.fetched),
            sinceWritten: cache.age(of: cache.items))
        {
            itemsJSON = try run(itemListArguments())
            try Board.requireUnderFetchLimit(itemsJSON)
            try cache.write(itemsJSON, to: cache.items)
            try cache.touch(cache.fetched)
        } else {
            itemsJSON = try String(contentsOf: cache.items, encoding: .utf8)
        }

        let fieldsJSON: String
        if cache.fresh(cache.fields, within: fieldsTTL) {
            fieldsJSON = try String(contentsOf: cache.fields, encoding: .utf8)
        } else {
            fieldsJSON = try run([
                "project", "field-list", String(projectNumber),
                "--owner", projectOwner,
                "--format", "json",
            ])
            try cache.write(fieldsJSON, to: cache.fields)
        }

        let status = try Board.parseStatusField(fieldsJSON)
        let board = Board(
            items: try Board.parseItems(itemsJSON, repository: repository),
            statusFieldID: status.id,
            optionIDs: status.options,
            columns: status.order
        )
        lastSnapshot = board
        return board
    }

    /// The read of every card of `repository` in `Workflow.Columns.read`. Scoped
    /// to the repository so another's cards on a shared board do not count
    /// toward the fetch limit.
    func itemListArguments() throws -> [String] {
        [
            "project", "item-list", String(projectNumber),
            "--owner", projectOwner,
            "--query", "repo:\(repository) " + (try Board.statusQuery(workflow.columns.read)),
            "--limit", String(itemFetchLimit),
            "--format", "json",
        ]
    }

    func budget() throws -> GraphQLBudget {
        try GraphQLBudget.parse(run(["api", "rate_limit"]))
    }

    /// Without a snapshot already read, reads one: fresh when `expected` is given,
    /// because a flag asking whether the board has moved is the wrong place to
    /// believe a cache.
    func move(_ issue: Int, to column: String, from expected: String?) throws {
        let board = try lastSnapshot ?? snapshot(refresh: expected != nil)
        try board.requireColumn(column)

        guard let card = board.item(number: issue) else {
            throw BoardError("#\(issue) is not in a column the loop reads")
        }

        // Refuse rather than overwrite. A caller always knows which column it is
        // moving a card out of, so a card that is somewhere else is one something
        // has already moved deliberately — a repair routing a red check, or another
        // agent finishing the item — and a second opinion arriving a moment late is
        // exactly the clobber this is here to prevent.
        if let expected {
            try board.requireColumn(expected)
            guard card.status == expected else {
                throw BoardError(
                    "#\(issue) is in \(card.status), not \(expected); refusing to move it to \(column)"
                )
            }
        }

        guard let optionID = board.optionIDs[column] else {
            throw BoardError("no such column: \(column)")
        }

        _ = try run([
            "project", "item-edit", "--id", card.id, "--project-id", try projectID(),
            "--field-id", board.statusFieldID, "--single-select-option-id", optionID,
        ])

        // Write the move through to the cached board rather than dropping it, and
        // refetching to learn what we just did would cost more than everything else
        // this command spends put together.
        //
        // What makes that safe is not "the only thing moving cards during a tick is
        // this tick", which several agents make false. It is that a `--from` move has
        // just fetched, or ridden a fetch seconds old, so the cache is the freshest
        // read available plus the one change this caller knows about.
        try writeThrough(issue: issue, column: column)
    }

    private func projectID() throws -> String {
        try run([
            "project", "view", String(projectNumber),
            "--owner", projectOwner, "--format", "json", "-q", ".id",
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func writeThrough(issue: Int, column: String) throws {
        guard let json = try? String(contentsOf: cache.items, encoding: .utf8),
            let data = json.data(using: .utf8),
            var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            var rows = root["items"] as? [[String: Any]]
        else {
            // The move itself succeeded, so this is a cache that will be refetched
            // rather than a failure worth stopping for.
            return
        }

        for index in rows.indices {
            guard let content = rows[index]["content"] as? [String: Any],
                content["number"] as? Int == issue,
                let cardRepository = content["repository"] as? String,
                sameRepository(cardRepository, repository)
            else {
                continue
            }
            rows[index]["status"] = column
        }
        root["items"] = rows

        guard let updated = try? JSONSerialization.data(withJSONObject: root),
            let text = String(data: updated, encoding: .utf8)
        else {
            return
        }
        try cache.write(text, to: cache.items)
    }

    // MARK: Claims

    func viewer() throws -> String {
        try run(["api", "user", "--jq", ".login"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The claim is GitHub's assignee field, so it is arbitrated where every agent
    /// can see it rather than in something the loop invented for itself.
    private func assignees(of issue: Int) throws -> [String] {
        let output = try run([
            "issue", "view", "--repo", repository, String(issue), "--json", "assignees",
            "--jq", ".assignees[].login",
        ])
        return output.split(separator: "\n").map(String.init)
    }

    /// **Read, add, read back, in that order, and the last one is not optional.**
    /// `--add-assignee` adds rather than refuses, so two agents that read the same
    /// empty list can each land a name and neither call fails. The read back is what
    /// settles it.
    func claim(_ issue: Int, as login: String) throws -> ClaimResult {
        let held = try assignees(of: issue)
        guard held.isEmpty else { return .held(by: held) }

        _ = try run([
            "issue", "edit", String(issue), "--repo", repository, "--add-assignee", login,
        ])

        let after = try assignees(of: issue)
        guard after.contains(login) else { return .didNotTake }

        let others = after.filter { $0 != login }
        guard others.isEmpty else {
            // First come rather than a tie-break, because the add and the read are
            // not one operation: whoever arrived first read only themselves and has
            // already started, so a tie-break would let the second agent keep an item
            // already being worked. First come is the only rule that reads the same
            // from both sides.
            _ = try? release(issue, login: login)
            return .held(by: others)
        }
        return .claimed
    }

    func release(_ issue: Int, login: String) throws {
        _ = try run([
            "issue", "edit", String(issue), "--repo", repository, "--remove-assignee", login,
        ])
    }

    func claimedIssues() throws -> [ClaimedIssue] {
        try run([
            "api", "--paginate",
            "repos/\(repository)/issues?assignee=*&state=open&per_page=100",
            "--jq",
            ".[] | select(.pull_request == null) | [(.number | tostring), ([.assignees[].login] | join(\", \"))] | @tsv",
        ]).split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 2, let number = Int(fields[0]) else { return nil }
            return ClaimedIssue(
                number: number,
                holders: fields[1].components(separatedBy: ", ").filter { !$0.isEmpty })
        }
    }

    // MARK: An issue's content

    func labels(of issue: Int) throws -> [String] {
        try run(["api", "repos/\(repository)/issues/\(issue)", "--jq", ".labels[].name"])
            .split(separator: "\n").map(String.init)
    }

    func isLocked(_ issue: Int) throws -> Bool {
        try run(["api", "repos/\(repository)/issues/\(issue)", "--jq", ".locked"])
            .trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    func comment(on issue: Int, body: String) throws {
        _ = try run(["issue", "comment", String(issue), "--repo", repository, "--body", body])
    }

    func comments(on issue: Int) throws -> [ConversationComment] {
        try GitHub.comments(on: issue, in: repository, run: run)
    }

    func events(on issue: Int, since: Date) throws -> [TimelineEvent] {
        try timelineEvents(timelineJSON: timeline(issue)).filter { $0.createdAt >= since }
    }

    /// Read over GraphQL, the only timeline that says which columns a move was
    /// between, so it spends the board's budget: one point a page.
    func statusChanges(on issue: Int, since: Date) throws -> [StatusChange] {
        let parts = repository.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw BoardError("not owner/name: \(repository)") }
        let json = try run([
            "api", "graphql", "--paginate", "--slurp",
            "-F", "number=\(issue)", "-f", "owner=\(parts[0])", "-f", "name=\(parts[1])",
            "-f", "query=\(statusChangeQuery)",
        ])
        return try BoardCore.statusChanges(
            timelineJSON: json, projectOwner: projectOwner, projectNumber: projectNumber
        ).filter { $0.createdAt >= since }
    }

    /// Matched by body, so a pull request of any age is found, unlike a search of
    /// recent ones, and in any repository. A locked issue gets no cross-reference,
    /// so the pull requests its `PR:` lines record are read too, one request each
    /// beyond the timeline.
    func linkedPullRequests(of issue: Int) throws -> [LinkedPullRequest] {
        let json = try timeline(issue)
        let referenced = try BoardCore.linkedPullRequests(issue: issue, timelineJSON: json)
        let known = Set(referenced.map(\.id))
        return try referenced
            + recordedPullRequests(timelineJSON: json).filter { !known.contains($0) }
            .compactMap { try linkedPullRequest($0, of: issue) }
    }

    /// Nil for a pull request that isn't there, as for one that doesn't link.
    func linkedPullRequest(_ id: PullRequestID, of issue: Int) throws -> LinkedPullRequest? {
        let json: String
        do {
            json = try run(["api", "repos/\(id.repository)/pulls/\(id.number)"])
        } catch let error as BoardError where error.isNotFound {
            return nil
        }
        return try pullRequestLink(issue: issue, pullJSON: json)?.link
    }

    /// Every page of an issue's timeline, `--slurp`ed for `jsonArray`.
    private func timeline(_ issue: Int) throws -> String {
        try run([
            "api", "--paginate", "--slurp",
            "repos/\(repository)/issues/\(issue)/timeline?per_page=100",
        ])
    }

    // MARK: Issues

    func createIssue(_ draft: IssueDraft) throws -> Int {
        // `--label ""` is refused, so an issue with no labels passes none.
        let labels = draft.labels.isEmpty ? [] : ["--label", draft.labels.joined(separator: ",")]
        let url = try run(
            ["issue", "create", "--repo", repository, "--title", draft.title, "--body", draft.body]
                + labels
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number = url.split(separator: "/").last.flatMap({ Int($0) }) else {
            throw BoardError("gh issue create answered \(url), which names no issue")
        }
        return number
    }

    func addToBoard(_ issue: Int) throws -> String? {
        let item = try boardItem(issue)
        let column = try run([
            "api", "graphql", "-f", "id=\(item)", "-f", "query=\(itemStatusQuery)",
            "--jq", ".data.node.fieldValueByName.name // \"\"",
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        return column.isEmpty ? nil : column
    }

    func place(_ issue: Int, in column: String) throws {
        let board = try lastSnapshot ?? snapshot(refresh: false)
        guard let optionID = board.optionIDs[column] else {
            throw BoardError("no such column: \(column)")
        }
        _ = try run([
            "project", "item-edit", "--id", try boardItem(issue), "--project-id", try projectID(),
            "--field-id", board.statusFieldID, "--single-select-option-id", optionID,
        ])
    }

    /// The issue's card, added if it has none: adding one already there answers it.
    ///
    /// Except while the project's add workflow is adding the same issue: then
    /// GitHub refuses with `alreadyOnBoard`, and asking again, once that add has
    /// landed, answers the card it made.
    private func boardItem(_ issue: Int) throws -> String {
        do {
            return try addItem(issue)
        } catch let error as BoardError where error.message.contains(Self.alreadyOnBoard) {
            return try addItem(issue)
        }
    }

    /// What GitHub says when an add races another add of the same issue.
    private static let alreadyOnBoard = "Content already exists in this project"

    private func addItem(_ issue: Int) throws -> String {
        let item = try run([
            "project", "item-add", String(projectNumber), "--owner", projectOwner,
            "--url", "https://github.com/\(repository)/issues/\(issue)",
            "--format", "json", "--jq", ".id",
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !item.isEmpty else { throw BoardError("adding #\(issue) to the board named no card") }
        return item
    }

    func closeIssue(_ issue: Int) throws {
        _ = try run(["issue", "close", String(issue), "--repo", repository])
    }

    func hasOpenIssue(titled title: String) throws -> Bool {
        try run([
            "api", "-X", "GET", "search/issues",
            "-f", "q=repo:\(repository) is:issue is:open in:title \"\(title)\"",
            "--jq", ".items[].title",
        ]).split(separator: "\n").contains { $0 == title }
    }

    func issues(createdBy login: String, since: Date) throws -> [IssueSummary] {
        // `since` on this endpoint is the update time, which is never earlier than
        // the creation time, so it narrows the listing without losing anything.
        let sinceText = ISO8601DateFormatter().string(from: since)
        let rows = try GitHub.rows(
            "repos/\(repository)/issues", query: "creator=\(login)&state=all&since=\(sinceText)",
            select: "select(.pull_request == null)",
            fields: "(.number | tostring), .created_at, (.body // \"\")", run: run)
        return try rows.compactMap { row in
            guard let number = Int(row[0]), try date(row[1]) >= since else { return nil }
            return IssueSummary(number: number, body: row[2])
        }
    }

    func openIssues(limit: Int) throws -> [IssueSummary] {
        try issueSummaries(
            listingJSON: run([
                "issue", "list", "--repo", repository, "--state", "open", "--limit",
                String(limit), "--json", "number,body",
            ]))
    }

    func issueNumbers(limit: Int) throws -> Set<Int> {
        let all = try run([
            "issue", "list", "--repo", repository, "--state", "all", "--limit", String(limit),
            "--json", "number", "--jq", ".[].number",
        ])
        return Set(all.split(separator: "\n").compactMap { Int($0) })
    }

    /// The issues endpoint answers for a pull request too, which is the answer
    /// wanted: a dependency naming a pull request names something real.
    func existence(of number: Int) -> IssueExistence {
        do {
            _ = try run(["api", "repos/\(repository)/issues/\(number)", "--jq", ".number"])
            return .exists
        } catch let error as BoardError where error.isNotFound {
            return .missing
        } catch {
            return .unconfirmed
        }
    }

    // MARK: Blocking

    /// What is still holding an issue: everything it declares a dependency on, by
    /// either record, that has not closed.
    ///
    /// **Two records, read together, because keeping them in step by hand is what
    /// failed.** GitHub's `blockedBy` relation is what the board can act on;
    /// `AGENTS.md` also prescribes a `## Dependencies` section, and nothing made the
    /// two agree. Every issue in the performance-controls chain declared its
    /// dependencies in prose and none of them as a relation, so this printed nothing
    /// for all six and the skip that exists for exactly that case could not fire,
    /// and it cost one item a pull request written against a `main` two of its
    /// predecessors change.
    ///
    /// The union rather than either alone: the relation is the stronger record and
    /// stays authoritative, and the section is what an author actually writes. An
    /// issue held by something either of them names is held.
    func blockers(of issue: Int) throws -> [Int] {
        let output = try run([
            "issue", "view", "--repo", repository, String(issue), "--json",
            "blockedBy,body",
            "--jq",
            "([.blockedBy.nodes[] | select(.state == \"OPEN\") | .number] | map(tostring) | join(\" \"))"
                + " + \"\\u0000\" + .body",
        ])
        let parts = output.components(separatedBy: "\0")
        let related = (parts.first ?? "").split(separator: " ").compactMap { Int($0) }
        let declared = dependenciesNamedInBody(parts.count > 1 ? parts[1] : "")

        // Only the declared ones need their state looked up; the relation was already
        // filtered to open by the query above. An issue declaring nothing costs
        // nothing extra, which is most of them.
        let openDeclared = try declared.isEmpty ? [] : openIssues(among: declared)

        reportDependencyDrift(on: issue, openDeclared: openDeclared, related: related)

        var seen: Set<Int> = []
        return (related + openDeclared).filter { seen.insert($0).inserted }
    }

    /// Which of these issues are still open.
    ///
    /// **One listing rather than a lookup each, because this is on the skip's path.**
    /// `blockers` is called on every candidate a tick walks past, and the board runs
    /// on the same GraphQL budget a card move needs.
    private func openIssues(among numbers: [Int]) throws -> [Int] {
        let limit = 200
        let output = try run([
            "issue", "list", "--repo", repository, "--state", "open", "--limit", String(limit),
            "--json", "number", "--jq", ".[].number",
        ])
        let open = Set(output.split(separator: "\n").compactMap { Int($0) })

        // A listing that came back exactly full may have been cut off, and silently
        // treating the issues past the cut as closed would unblock cards that are
        // held.
        if open.count >= limit {
            FileHandle.standardError.write(
                Data(
                    ("board: the open-issue listing came back at its limit of \(limit); "
                        + "a declared dependency beyond it would read as closed\n").utf8))
        }

        return numbers.filter { open.contains($0) }
    }

    func landing(of number: Int) throws -> BlockerState {
        let issue = try jsonObject(run(["api", "repos/\(repository)/issues/\(number)"]))
        guard issue["state"] as? String == "closed" else { return .open }
        guard issue["pull_request"] != nil else { return .landed }
        let merged = try run(["api", "repos/\(repository)/pulls/\(number)", "--jq", ".merged"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return merged == "true" ? .landed : .abandoned
    }

    /// REST rather than the `blockedBy` field `blockers` reads over GraphQL, because
    /// this is the listing whose `id` the write endpoints take.
    private func blockingRelations(of issue: Int) throws -> [BlockingRelation] {
        BoardCore.blockingRelations(
            inJSON: try run(["api", "repos/\(repository)/issues/\(issue)/dependencies/blocked_by"]))
    }

    func addBlocker(_ blocker: Int, to issue: Int) throws -> Bool {
        guard !(try blockingRelations(of: issue)).contains(where: { $0.number == blocker }) else {
            return false
        }

        let id: String
        do {
            id = try run(["api", "repos/\(repository)/issues/\(blocker)", "--jq", ".id"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let error as BoardError where error.isNotFound {
            throw BoardError("#\(blocker) names no issue here")
        }
        guard Int(id) != nil else {
            // The lookup succeeded and gave something that is not an id, which is a
            // shape change rather than a missing issue. Refused here rather than
            // sent, because `issue_id=` with nothing after it is a 422 that reads
            // like the caller's mistake.
            throw BoardError("could not read the database id of #\(blocker)")
        }

        // `-F` rather than `-f`: the endpoint types `issue_id` as an integer and
        // rejects the string `-f` would send.
        _ = try run([
            "api", "repos/\(repository)/issues/\(issue)/dependencies/blocked_by",
            "-F", "issue_id=\(id)",
        ])
        return true
    }

    /// **Deletes by the id the listing gave rather than looking the number up
    /// again.** The read that decides whether there is anything to do is the read
    /// that says what to delete, so the number a person wrote never reaches the
    /// path, where it would name a different issue.
    func removeBlocker(_ blocker: Int, from issue: Int) throws -> Bool {
        guard let relation = try blockingRelations(of: issue).first(where: { $0.number == blocker })
        else { return false }

        _ = try run([
            "api", "--method", "DELETE",
            "repos/\(repository)/issues/\(issue)/dependencies/blocked_by/\(relation.id)",
        ])
        return true
    }
}
