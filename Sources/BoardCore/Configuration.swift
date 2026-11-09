import Foundation

/// How the loop is arranged for one project, as `loop.json` writes it down.
///
/// Every project coordinate the tool uses comes from here, so the tool names no
/// project of its own. `check-loop` is what validates the file; this
/// only reads the parts the tool needs.
struct LoopConfiguration: Decodable, Equatable {
    struct Project: Decodable, Equatable {
        /// The account that owns the board, as `gh project --owner` takes it.
        let owner: String
        let number: Int
    }

    struct Agent: Decodable, Equatable {
        let login: String
        let roles: [String]
    }

    /// `owner/name`: where the board's issues live.
    let repository: String
    let project: Project
    /// Whose reviews and comments are requests the loop must answer.
    let owner: String
    /// Labels added to `type:bug` on an issue filed for a check red on `main`.
    let mainRedLabels: [String]
    let agents: [Agent]
    let workflow: Workflow
    /// `review.agentApproval`: when an independent agent's review may approve a
    /// pull request itself. Off when absent.
    let agentApproval: AgentApproval?
    /// `merge.auto`: whether approved pull requests land through GitHub's native
    /// squash auto-merge.
    let autoMerge: Bool
    /// `stack.label`: the label that lets an issue start stacked work. Off when
    /// absent.
    let stackLabel: String?
    /// `lockConversations`: `next` claims only locked issues, and `finish --pr`
    /// locks the pull request. Off when absent.
    let lockConversations: Bool

    private enum CodingKeys: String, CodingKey {
        case repository, project, owner, mainRedLabels, agents, workflow, review, merge, stack
        case lockConversations
    }

    private struct Stack: Decodable {
        let label: String
    }

    private struct Review: Decodable {
        let agentApproval: AgentApproval?
    }

    private struct Merge: Decodable {
        let auto: Bool
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        repository = try container.decode(String.self, forKey: .repository)
        project = try container.decode(Project.self, forKey: .project)
        owner = try container.decode(String.self, forKey: .owner)
        mainRedLabels = try container.decodeIfPresent([String].self, forKey: .mainRedLabels) ?? []
        agents = try container.decode([Agent].self, forKey: .agents)
        workflow = try container.decodeIfPresent(Workflow.self, forKey: .workflow) ?? .standard
        agentApproval = try container.decodeIfPresent(Review.self, forKey: .review)?.agentApproval
        autoMerge = try container.decodeIfPresent(Merge.self, forKey: .merge)?.auto ?? false
        stackLabel = try container.decodeIfPresent(Stack.self, forKey: .stack)?.label
        lockConversations =
            try container.decodeIfPresent(Bool.self, forKey: .lockConversations) ?? false
    }

    /// `origin/main`'s `loop.json`, read through `show`, which runs
    /// `git show origin/main:loop.json`.
    ///
    /// **The only arrangement the tool acts by.** A working tree, an agent's
    /// branch or a pull request's head can carry a different file, and nothing
    /// in one of them may widen who approves or what merges.
    static func fromMain(show: () -> String) throws -> LoopConfiguration {
        let text = show()
        guard !text.isEmpty else {
            throw BoardError(
                "origin/main has no loop.json to read; fetch origin, from a checkout of the "
                    + "repository whose board this is")
        }
        do {
            return try JSONDecoder().decode(LoopConfiguration.self, from: Data(text.utf8))
        } catch {
            throw BoardError(
                "origin/main's loop.json could not be read as the loop's arrangement: \(error)")
        }
    }

    /// The arrangement in `file`: the sample the unit tests read.
    static func read(file: URL) throws -> LoopConfiguration {
        guard let data = FileManager.default.contents(atPath: file.path) else {
            throw BoardError(
                "\(file.path) can't be read: it says which repository and board to act on")
        }
        do {
            return try JSONDecoder().decode(LoopConfiguration.self, from: data)
        } catch {
            throw BoardError("\(file.path) could not be read as the loop's arrangement: \(error)")
        }
    }
}

/// `review.agentApproval`: the label that opens the agent-approved path, and who
/// may apply it.
struct AgentApproval: Decodable, Equatable {
    let label: String
    /// Logins whose labelling counts, besides the owner, who always does.
    let appliedBy: [String]

    private enum CodingKeys: String, CodingKey { case label, appliedBy }

    init(label: String, appliedBy: [String] = []) {
        self.label = label
        self.appliedBy = appliedBy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decode(String.self, forKey: .label)
        appliedBy = try container.decodeIfPresent([String].self, forKey: .appliedBy) ?? []
    }

    /// Whether `actor`'s labelling counts.
    func counts(_ actor: String?, owner: String) -> Bool {
        guard let actor else { return false }
        return actor == owner || appliedBy.contains(actor)
    }
}

/// The names of the board's columns and labels the loop acts on, from
/// `loop.json`'s optional `workflow` object. Which transitions happen stays in
/// Swift; only what the columns and labels are called is the consumer's. A key
/// left out keeps today's name.
struct Workflow: Decodable, Equatable {
    struct Columns: Decodable, Equatable {
        /// Untriaged: no tick takes work from it.
        var backlog = "Backlog"
        var ready = "Ready"
        var design = "In Design"
        var work = "In Progress"
        var review = "Agent Review"
        var ownerReview = "Human Review"
        var parked = "Needs Human"
        /// Closed issues: no tick acts on it.
        var done = "Done"

        static let keys = [
            "backlog", "ready", "design", "work", "review", "ownerReview", "parked", "done",
        ]

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            func name(_ key: String, _ standard: String) throws -> String {
                try container.decodeIfPresent(String.self, forKey: Key(key)) ?? standard
            }
            let standard = Columns()
            backlog = try name("backlog", standard.backlog)
            ready = try name("ready", standard.ready)
            design = try name("design", standard.design)
            work = try name("work", standard.work)
            review = try name("review", standard.review)
            ownerReview = try name("ownerReview", standard.ownerReview)
            parked = try name("parked", standard.parked)
            done = try name("done", standard.done)
        }

        /// Every column the loop names, in `keys`' order, which is the order work
        /// flows through them and the order the board is shown in.
        var all: [String] { [backlog, ready, design, work, review, ownerReview, parked, done] }

        /// The columns the board is read for: every one the loop names but Done.
        /// Finished work and columns somebody keeps for themselves are never read,
        /// so the board can hold them without reaching `itemFetchLimit`.
        var read: [String] { all.filter { $0 != done } }

        /// Refuses a column the board is not read for, whose cards would
        /// otherwise list as none.
        func requireRead(_ column: String) throws {
            guard read.contains(column) else {
                throw BoardError(
                    "\(column) is not read: the loop reads only \(read.joined(separator: ", "))")
            }
        }
    }

    struct Labels: Decodable, Equatable {
        /// The label that makes an issue a design.
        var design = "type:design"
        /// The label that makes an issue a container no tick takes.
        var epic = "epic"

        static let keys = ["design", "epic"]

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            let standard = Labels()
            design =
                try container.decodeIfPresent(String.self, forKey: Key("design")) ?? standard.design
            epic = try container.decodeIfPresent(String.self, forKey: Key("epic")) ?? standard.epic
        }
    }

    var columns = Columns()
    var labels = Labels()

    static let standard = Workflow()
    static let keys = ["columns", "labels"]

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        columns = try container.decodeIfPresent(Columns.self, forKey: Key("columns")) ?? Columns()
        labels = try container.decodeIfPresent(Labels.self, forKey: Key("labels")) ?? Labels()
    }

    /// The column a card goes back to for work: the Designer's for a design, and
    /// the Engineer's otherwise.
    func workColumn(isDesign: Bool) -> String {
        isDesign ? columns.design : columns.work
    }

    /// The columns whose cards wait on a pull request's review.
    var reviewColumns: Set<String> { [columns.review, columns.ownerReview] }

    /// The columns a tick works, right to left, with the role each needs.
    /// `ready`'s role depends on the card, so it is chosen per card.
    var selectionOrder: [(column: String, role: Role?)] {
        [
            (columns.review, .reviewer), (columns.work, .engineer), (columns.design, .designer),
            (columns.ready, nil),
        ]
    }

    /// A key read by name, so that the keys `check-loop` accepts are the ones
    /// decoded here.
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ name: String) { stringValue = name }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

/// The project this run acts on.
///
/// Read once, the first time anything asks. A run with no usable file stops
/// there, because nothing it could do would know which board it was doing it to.
///
/// **The tool reads `origin/main`'s `loop.json`,** because `run()` sets
/// `readsMain` before any verb asks. Only the unit tests, which never call
/// `run()`, read the sample, `Tests/loop.json` under the working directory.
enum Coordinates {
    nonisolated(unsafe) static var readsMain = false

    static let configuration: LoopConfiguration = {
        do {
            if readsMain {
                return try LoopConfiguration.fromMain(show: mainArrangement)
            }
            return try LoopConfiguration.read(
                file: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent("Tests/loop.json"))
        } catch let error as BoardError {
            FileHandle.standardError.write(Data("board: \(error.message)\n".utf8))
            exit(1)
        } catch {
            FileHandle.standardError.write(Data("board: \(error)\n".utf8))
            exit(1)
        }
    }()

    /// The account that owns the board.
    static var owner: String { configuration.project.owner }
    /// The repository the board's issues live in. A pull request doing a card's
    /// work may live in another.
    static var repository: String { configuration.repository }
    static var projectNumber: Int { configuration.project.number }
    /// Whose reviews and comments are requests the loop must answer.
    static var ownerLogin: String { configuration.owner }
    static var workflow: Workflow { configuration.workflow }
}
