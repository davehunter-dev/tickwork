import Foundation

/// One card: the issue it points at and the column it is in.
struct Item {
    let id: String
    let number: Int
    let title: String
    let status: String
    /// Who holds the claim, which is the issue's assignees.
    let assignees: [String]
}

/// The board, read once per invocation and cached between them.
///
/// **What this costs is the whole reason for the caching below.** A fetch of
/// both halves is a little over two hundred GraphQL points against an hourly
/// budget of five thousand, and a tick reads the board several times, so an
/// uncached loop prices itself out of moving a card after five or six ticks —
/// which is exactly how it once failed.
struct Board {
    let items: [Item]
    /// The Status field's own id, and its options by column name.
    let statusFieldID: String
    let optionIDs: [String: String]
    /// Column names in the order the project declares them.
    let columns: [String]
}

/// A silently truncated read is the worst failure this tool has: `move` would
/// report a real issue as absent and the loop would carry on as though the board
/// had answered. So the fetch asks for more cards than the columns it reads hold
/// (`Workflow.Columns.read`) and stops if it ever comes back full, rather than
/// assuming it saw everything.
///
/// Not much more, though. GitHub bills a GraphQL query for the rows it asks for
/// rather than the rows it returns, at roughly a point each, and above a hundred
/// the price stops moving — so a hundred is the last raise that costs nothing.
let itemFetchLimit = 100

/// How long a cached copy of each half is believed.
///
/// The two are not alike, so they are not cached alike. The field list is column
/// names and their option ids: it changes when somebody renames a column and at
/// no other time, so it is kept for a day, and the risk of holding a stale one is
/// bounded by resolving a column name and failing loudly on one that is not
/// there. The item list is the board, and it moves.
let itemsTTL: TimeInterval = 180
let fieldsTTL: TimeInterval = 86_400

/// How recently the board must have been fetched for a read that asks for a
/// fresh one — `--refresh`, `show`, `working` or `move --from` — to believe it
/// without asking again.
///
/// The size matters less than what it is measured from. `move` is a read and
/// then a write with no compare-and-swap between them, so `--from` can never win
/// a race decided inside that gap; what it does catch is a snapshot minutes old.
/// A sweep's second and third moves are seconds behind its first and are as
/// protected by that one fetch as the first was.
///
/// **It is also what makes a repeated refresh cost one fetch.** A tick that read
/// every column with its own `--refresh list` spent six fetches in a few seconds
/// and drained the hourly budget the moves needed. Reads that close
/// together are answered by the first, and a re-validation after a claim is tens
/// of seconds behind the tick's opening read, so it still asks GitHub.
let fetchRideWindow: TimeInterval = 10

/// Whether a read must go to GitHub rather than the cache.
///
/// `sinceFetched` is the age of the last actual fetch and `sinceWritten` the age
/// of the cached copy, which `move` also writes; `nil` is a file that is not
/// there.
func needsFetch(refresh: Bool, sinceFetched: TimeInterval?, sinceWritten: TimeInterval?) -> Bool {
    guard let sinceWritten, sinceWritten < itemsTTL else { return true }
    guard refresh else { return false }
    guard let sinceFetched else { return true }
    return sinceFetched >= fetchRideWindow
}

/// The GraphQL points a board read leaves for the writes.
///
/// Board reads and the `move --from` refetches spend from the same hourly
/// 5,000, at a little over 200 points a fetch. Below this a read refuses, which
/// leaves about five fetches: enough for the moves and claims of the ticks still
/// running before the reset, which is the work a read must never starve. `move`,
/// `claim` and `release` do not check it.
let readReserve = 1_000

/// What `gh api rate_limit` says is left of the GraphQL budget. Reading it costs
/// nothing against either limit.
struct GraphQLBudget: Equatable {
    let remaining: Int
    let limit: Int
    let reset: Date

    static func parse(_ json: String) throws -> GraphQLBudget {
        guard let data = json.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let resources = root["resources"] as? [String: Any],
            let graphql = resources["graphql"] as? [String: Any],
            let remaining = graphql["remaining"] as? Int,
            let limit = graphql["limit"] as? Int,
            let reset = graphql["reset"] as? Int
        else {
            throw BoardError("the rate limit came back as something this could not read")
        }
        return GraphQLBudget(
            remaining: remaining, limit: limit,
            reset: Date(timeIntervalSince1970: TimeInterval(reset)))
    }

    var text: String {
        "\(remaining) of \(limit), resets \(reset.formatted(date: .omitted, time: .shortened))"
    }

    /// Refuses a read that would leave the writes too little.
    func requireReadReserve() throws {
        guard remaining >= readReserve else {
            throw BoardError(
                """
                GraphQL budget \(text), below the \(readReserve) kept for moves and \
                claims: this read is refused, and move, claim and release still run
                """)
        }
    }
}

/// GitHub's repository names are case-insensitive, and `loop.json` may spell its
/// repository otherwise than the name a read answers with.
func sameRepository(_ one: String, _ other: String) -> Bool {
    one.lowercased() == other.lowercased()
}

/// The cached board, and the one thing that is not the cache.
struct Cache {
    let directory: URL

    /// One per repository as well as per project: consumers sharing a board each
    /// read only their own cards, so one's cached read is not another's.
    init(owner: String, projectNumber: Int, repository: String) {
        let temporary = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp"
        directory = URL(fileURLWithPath: temporary)
            .appendingPathComponent("board-\(owner)-\(projectNumber)")
            .appendingPathComponent(repository.lowercased())
    }

    var items: URL { directory.appendingPathComponent("items.json") }
    var fields: URL { directory.appendingPathComponent("fields.json") }

    /// When the item list was last actually fetched, which is not the same
    /// question as when the cache file was last written. `move` writes its change
    /// through, so a chain of moves keeps moving the cache file's timestamp — and
    /// a guard reading that would let the last move in a long sweep ride a fetch
    /// of any age at all, through the very check that exists to refuse a stale
    /// snapshot. This file's timestamp moves only when GitHub was actually asked.
    var fetched: URL { directory.appendingPathComponent("items.fetched") }

    func age(of file: URL) -> TimeInterval? {
        guard
            let modified = try? FileManager.default
                .attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        else {
            return nil
        }
        return Date().timeIntervalSince(modified)
    }

    func fresh(_ file: URL, within seconds: TimeInterval) -> Bool {
        guard let age = age(of: file) else { return false }
        return age < seconds
    }

    func write(_ contents: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try contents.write(to: file, atomically: true, encoding: .utf8)
    }

    func touch(_ file: URL) throws {
        try write("", to: file)
    }
}

extension Board {
    /// The `--query` that reads only `columns`' cards. GitHub applies it before
    /// `--limit`, so the limit bounds the cards in these columns alone.
    static func statusQuery(_ columns: [String]) throws -> String {
        if let name = columns.first(where: { $0.contains("\"") }) {
            throw BoardError(
                "the column name \(name) has a double quote, which a board filter cannot hold")
        }
        return "status:" + columns.map { "\"\($0)\"" }.joined(separator: ",")
    }

    /// Fails on a fetch that came back full, which may be short.
    ///
    /// Counts the rows before `parseItems` drops any it cannot make an Item of —
    /// a draft card has no number — so a fetch exactly at the limit cannot slip
    /// under it.
    static func requireUnderFetchLimit(_ json: String) throws {
        guard let data = json.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rows = root["items"] as? [Any]
        else {
            throw BoardError("the board came back as something this could not count")
        }
        guard rows.count < itemFetchLimit else {
            throw BoardError(
                """
                the board returned \(rows.count) items, which is the fetch limit; \
                raise itemFetchLimit in Tickwork rather than trusting a read that may be short
                """)
        }
    }

    /// `repository`'s cards only. A board several repositories share holds the
    /// same number more than once, and every number this tool acts on means an
    /// issue in `loop.json`'s repository.
    static func parseItems(_ json: String, repository: String) throws -> [Item] {
        guard let data = json.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rows = root["items"] as? [[String: Any]]
        else {
            throw BoardError("the board came back as something this could not read")
        }

        return try rows.compactMap { row in
            guard let id = row["id"] as? String,
                let content = row["content"] as? [String: Any],
                let number = content["number"] as? Int
            else {
                return nil
            }
            guard let cardRepository = content["repository"] as? String else {
                throw BoardError("the board's card for #\(number) names no repository")
            }
            guard sameRepository(cardRepository, repository) else { return nil }
            return Item(
                id: id,
                number: number,
                title: content["title"] as? String ?? "",
                status: row["status"] as? String ?? "",
                assignees: row["assignees"] as? [String] ?? []
            )
        }
    }

    static func parseStatusField(
        _ json: String
    ) throws -> (id: String, options: [String: String], order: [String]) {
        guard let data = json.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let fields = root["fields"] as? [[String: Any]],
            let status = fields.first(where: { $0["name"] as? String == "Status" }),
            let id = status["id"] as? String,
            let options = status["options"] as? [[String: Any]]
        else {
            throw BoardError("the board has no Status field this could read")
        }

        var ids: [String: String] = [:]
        var order: [String] = []
        for option in options {
            guard let name = option["name"] as? String, let optionID = option["id"] as? String
            else {
                continue
            }
            ids[name] = optionID
            order.append(name)
        }
        return (id, ids, order)
    }

    func item(number: Int) -> Item? {
        items.first { $0.number == number }
    }

    /// The card's column, or a placeholder for a card in no column this read:
    /// one in Done or a column the loop does not name.
    func column(of number: Int) -> String {
        item(number: number)?.status ?? "(not in a column the loop reads)"
    }

    /// Fails loudly on a column the board does not have, rather than filing work
    /// somewhere nobody looks. Renaming one in the project's own UI then breaks
    /// here instead of silently.
    func requireColumn(_ name: String) throws {
        guard optionIDs[name] != nil else {
            throw BoardError(
                """
                no such column: \(name)
                board: columns are: \(columns.joined(separator: ", "))
                """)
        }
    }
}
