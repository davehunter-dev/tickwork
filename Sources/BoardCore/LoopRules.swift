import Foundation

// The rules loop.json must meet. `check-loop` reports them, and `next` refuses a
// file that breaks them, so the two cannot disagree. See check-loop for why each
// rule exists.

/// The four a tick accepts. A role outside this set is a typo that would
/// otherwise sit in the file doing nothing until somebody wondered why a column
/// was never served.
let acceptedRoles = Role.allCases.map(\.rawValue)

/// The roles that may be held once at most, listed so that adding one is an edit
/// to one line.
let exclusiveRoles = ["orchestrator"]

/// How many agents must hold `reviewer` before a review can be independent of
/// the change it judges. A pull request has one owner, so a second holder is
/// necessarily somebody else — which is the whole of what the rule needs.
let reviewersRequired = 2

/// A JSON value, decoded by type so that `true` is never mistaken for a number.
/// This is what keeps the check off Core Foundation, which nothing off Apple
/// platforms have.
public indirect enum JSON: Decodable {
    case boolean(Bool)
    case integer(Int)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Bool first: an integer never decodes as one, and `true` never decodes
        // as an integer.
        if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSON].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSON].self) {
            self = .object(value)
        } else if container.decodeNil() {
            self = .null
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "not a JSON value")
        }
    }

    public var string: String? { if case .string(let value) = self { value } else { nil } }
    public var array: [JSON]? { if case .array(let value) = self { value } else { nil } }
    public var object: [String: JSON]? { if case .object(let value) = self { value } else { nil } }
    public var integer: Int? { if case .integer(let value) = self { value } else { nil } }
    public var boolean: Bool? { if case .boolean(let value) = self { value } else { nil } }
}

/// A string that is present and says something. Absent and empty are the same
/// mistake to whoever has to fix the file.
func text(_ value: JSON?) -> String? {
    guard let string = value?.string, !string.isEmpty else { return nil }
    return string
}

/// Everything wrong with the arrangement, in the order a reader meets it.
///
/// Collected rather than reported one at a time, so a file with three things
/// wrong takes one pass to fix rather than three.
public func loopProblems(in document: [String: JSON]) -> [String] {
    var problems: [String] = []

    @discardableResult
    func require(_ condition: Bool, _ message: @autoclosure () -> String) -> Bool {
        if !condition {
            problems.append(message())
        }
        return condition
    }

    require(text(document["repository"]) != nil, "repository: missing, or not a string")
    require(
        text(document["owner"]) != nil,
        "owner: missing, or not a string — the login whose merge is the review gate")

    let project = document["project"]?.object
    if require(project != nil, "project: missing, or not an object"), let project {
        require(text(project["owner"]) != nil, "project.owner: missing, or not a string")
        require(project["number"]?.integer != nil, "project.number: missing, or not an integer")
    }

    if let labels = document["mainRedLabels"] {
        require(
            labels.array?.allSatisfy({ text($0) != nil }) == true,
            "mainRedLabels: not an array of label names")
    }

    if let workflow = document["workflow"] {
        problems += workflowShapeProblems(workflow)
    }
    if let review = document["review"] {
        problems += reviewProblems(review)
    }
    if let merge = document["merge"] {
        problems += mergeProblems(merge)
    }
    if let stack = document["stack"] {
        problems += stackProblems(stack)
    }
    if let lock = document["lockConversations"] {
        require(lock.boolean != nil, "lockConversations: not true or false")
    }
    // An agent-approved card stays in review for auto-merge to land, and nothing
    // else would merge it.
    if document["review"]?.object?["agentApproval"] != nil,
        document["merge"]?.object?["auto"]?.boolean != true
    {
        problems.append("review.agentApproval: needs merge.auto true, which lands what it approves")
    }

    let agents = document["agents"]?.array
    if require(agents?.isEmpty == false, "agents: missing, empty, or not an array"), let agents {
        var logins: [String] = []
        var holders: [String: [String]] = [:]

        for (index, entry) in agents.enumerated() {
            let position = "agents[\(index)]"
            guard let agent = entry.object else {
                problems.append("\(position): not an object")
                continue
            }

            let login = text(agent["login"])
            if require(login != nil, "\(position).login: missing, or not a string"), let login {
                require(
                    !logins.contains(login), "\(position).login: \(login) is listed more than once")
                logins.append(login)
            }

            let roles = agent["roles"]?.array
            guard
                require(
                    roles?.isEmpty == false, "\(position).roles: missing, empty, or not an array"),
                let roles
            else { continue }

            // Counted once per entry, however many times the entry says it. An agent
            // that names `reviewer` twice is one agent holding it, and tallying the
            // mentions would report two entries and name the same login twice —
            // sending the reader to look for a second agent that is not there, from a
            // check whose whole job is to say where the trouble is. The repetition is
            // its own problem and has its own line.
            var counted: Set<String> = []
            var spelled: [String] = []

            for entry in roles {
                guard require(entry.string != nil, "\(position).roles: a role is not a string"),
                    let role = entry.string
                else { continue }
                spelled.append(role)
                guard
                    require(
                        acceptedRoles.contains(role),
                        "\(position).roles: \(role) is not a role a tick accepts "
                            + "(\(acceptedRoles.joined(separator: ", ")))")
                else { continue }
                if counted.insert(role).inserted {
                    holders[role, default: []].append(login ?? position)
                }
            }

            require(Set(spelled).count == spelled.count, "\(position).roles: names a role twice")
        }

        for role in exclusiveRoles {
            let held = holders[role] ?? []
            require(
                held.count <= 1,
                "agents: \(held.count) entries hold \(role) and at most one may — "
                    + held.joined(separator: ", "))
        }

        // Only once there is somebody to hand a review to. A single agent is the
        // state the repository is in until the other accounts exist, and its pull
        // requests wait in review until there is.
        if agents.count > 1 {
            let reviewers = holders["reviewer"] ?? []
            require(
                reviewers.count >= reviewersRequired,
                "agents: \(reviewers.count) entries hold reviewer and at least "
                    + "\(reviewersRequired) must, so that no pull request is reviewed by the "
                    + "agent that opened it"
                    + (reviewers.isEmpty ? "" : " — " + reviewers.joined(separator: ", ")))
        }
    }

    return problems
}

/// What is wrong with `workflow`'s shape: anything but an object of the keys
/// `Workflow` reads, each naming a column or label. An unknown key is refused
/// rather than ignored, because a misspelt one would otherwise leave today's name
/// in force with nothing to say so.
private func workflowShapeProblems(_ workflow: JSON) -> [String] {
    func names(_ value: JSON?, at path: String, keys: [String]) -> [String] {
        guard let value else { return [] }
        guard let object = value.object else { return ["\(path): not an object"] }
        return object.keys.sorted().flatMap { key -> [String] in
            guard keys.contains(key) else {
                return ["\(path).\(key): not a key it takes (\(keys.joined(separator: ", ")))"]
            }
            return text(object[key]) == nil ? ["\(path).\(key): not a non-empty string"] : []
        }
    }
    guard let object = workflow.object else { return ["workflow: not an object"] }
    let unknown = object.keys.sorted().filter { !Workflow.keys.contains($0) }.map {
        "workflow.\($0): not a key it takes (\(Workflow.keys.joined(separator: ", ")))"
    }
    return unknown
        + names(object["columns"], at: "workflow.columns", keys: Workflow.Columns.keys)
        + names(object["labels"], at: "workflow.labels", keys: Workflow.Labels.keys)
}

/// What is wrong with `review`: an object whose one key, `agentApproval`, names a
/// label and, optionally, the logins besides the owner whose labelling counts.
/// Unknown keys are refused, as `workflow`'s are, so a misspelling can't leave
/// the feature off with nothing to say so.
private func reviewProblems(_ review: JSON) -> [String] {
    guard let object = review.object else { return ["review: not an object"] }
    var problems = object.keys.sorted().filter { $0 != "agentApproval" }.map {
        "review.\($0): not a key it takes (agentApproval)"
    }
    guard let approval = object["agentApproval"] else { return problems }
    guard let fields = approval.object else {
        return problems + ["review.agentApproval: not an object"]
    }
    problems += fields.keys.sorted().filter { !["label", "appliedBy"].contains($0) }.map {
        "review.agentApproval.\($0): not a key it takes (label, appliedBy)"
    }
    if text(fields["label"]) == nil {
        problems.append("review.agentApproval.label: missing, or not a non-empty string")
    }
    if let appliedBy = fields["appliedBy"],
        appliedBy.array?.allSatisfy({ text($0) != nil }) != true
    {
        problems.append("review.agentApproval.appliedBy: not an array of logins")
    }
    return problems
}

/// What is wrong with `merge`: an object of `auto`, a boolean, and `method`,
/// which is `squash`, the one method Tickwork sets.
private func mergeProblems(_ merge: JSON) -> [String] {
    guard let object = merge.object else { return ["merge: not an object"] }
    var problems = object.keys.sorted().filter { !["auto", "method"].contains($0) }.map {
        "merge.\($0): not a key it takes (auto, method)"
    }
    if object["auto"]?.boolean == nil {
        problems.append("merge.auto: missing, or not true or false")
    }
    if object["method"]?.string != "squash" {
        problems.append("merge.method: missing, or not squash, the one method Tickwork sets")
    }
    return problems
}

/// What is wrong with `stack`'s shape: an object whose one key, `label`, names a
/// label.
private func stackProblems(_ stack: JSON) -> [String] {
    guard let object = stack.object else { return ["stack: not an object"] }
    var problems = object.keys.sorted().filter { $0 != "label" }.map {
        "stack.\($0): not a key it takes (label)"
    }
    if text(object["label"]) == nil {
        problems.append("stack.label: missing, or not a non-empty string")
    }
    return problems
}

/// What `stack` needs of the repository, read through `gh`: its label exists,
/// spelled exactly as configured, and `delete_branch_on_merge` is off, so a
/// merged parent's children still target its branch and the repairs find them
/// without reading every pull request. Reads nothing when `stack` is absent, so an arrangement without it
/// is checked offline, as every other key is.
///
/// Call it on a document `loopProblems` passed.
public func stackRepositoryProblems(
    in document: [String: JSON], gh run: ([String]) throws -> String
) -> [String] {
    guard let repository = text(document["repository"]),
        let label = text(document["stack"]?.object?["label"])
    else { return [] }
    func reason(_ error: Error) -> String { (error as? BoardError)?.message ?? "\(error)" }
    var problems: [String] = []

    var pathAllowed = CharacterSet.urlPathAllowed
    pathAllowed.remove("/")
    let encoded = label.addingPercentEncoding(withAllowedCharacters: pathAllowed) ?? label
    do {
        // GitHub finds a label whatever its case, but `decompose` matches it exactly.
        let name = try run(["api", "repos/\(repository)/labels/\(encoded)", "--jq", ".name"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name != label {
            problems.append(
                "stack.label: \(label) is spelled \(name) in \(repository), and labels match exactly"
            )
        }
    } catch let error as BoardError where error.isNotFound {
        problems.append("stack.label: \(label) is not a label in \(repository)")
    } catch {
        problems.append(
            "stack.label: can't read whether \(label) is a label in \(repository): \(reason(error))"
        )
    }

    do {
        let setting = try run(["api", "repos/\(repository)", "--jq", ".delete_branch_on_merge"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch setting {
        case "false": break
        case "true":
            problems.append(
                "stack: \(repository) has delete_branch_on_merge on, and stacked work needs it "
                    + "off, so a merged parent's children still target its branch")
        default:
            problems.append(
                "stack: can't read \(repository)'s delete_branch_on_merge, which needs push access")
        }
    } catch {
        problems.append(
            "stack: can't read \(repository)'s delete_branch_on_merge: \(reason(error))")
    }
    return problems
}

/// `gh` with these arguments, for a tool outside this module.
public func runGitHubCLI(_ arguments: [String]) throws -> String {
    try GitHub.run(arguments)
}

/// Each column `workflow` uses that the board doesn't have, named by its key.
func workflowColumnProblems(_ workflow: Workflow, boardColumns: [String]) -> [String] {
    zip(Workflow.Columns.keys, workflow.columns.all).compactMap { key, name in
        boardColumns.contains(name)
            ? nil
            : "workflow.columns.\(key): \(name) is not a column on the board "
                + "(\(boardColumns.joined(separator: ", ")))"
    }
}
