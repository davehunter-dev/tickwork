import BoardCore
import Foundation

// Check loop.json, the file that says how the agent loop is arranged.
//
//   swift run check-loop [file]
//
// The file carries what every agent needs and none can derive: which repository
// and project they act on, which login is the owner whose merge is the review
// gate, and which accounts hold which roles. See "The arrangement is written
// down, not remembered" in docs/loop.md.
//
// Two of those facts are invariants rather than settings, and this is what
// makes them checkable: at most one agent holds `orchestrator`, and — once there
// is more than one agent — at least two hold `reviewer`. Any number may hold
// `designer`: designs run in parallel, blocked only by explicit dependencies. One orchestrator because the repairs are the read-heavy half
// of a tick, and running them in four agents buys one board's worth of answers
// at four times the price.
//
// Two reviewers for the opposite reason: a reviewer skips a pull request its
// own agent opened, so a second one is what keeps that from being a card nobody
// can take. Two is also exactly enough — a pull request has one owner, so any
// second holder is someone else. It is not asked of a lone agent, whose pull
// requests wait for review because there is nobody to hand them to.
//
// A tick reads the same file and gives up a role the file does not agree it
// holds, which is the backstop. This is the gate: a file this wrong should not
// be able to land, and here the reader is the merge rather than whoever happens
// to be watching a terminal.
//
// On `owner` appearing twice, which is the one confusing thing about the shape:
// the top-level `owner` is a person, the login whose approval merges. The one
// under `project` is a GitHub account that owns a Projects board, and is spelled
// that way because `gh project --owner` is what it is passed to.

/// The heading a consuming repository's `AGENTS.md` must carry: it is where the
/// shared instructions find the project's local bar and formatter.
let agentLoopHeading = "## Agent loop"

func fail(_ message: String) -> Never {
    print(message)
    exit(1)
}

/// The path is taken relative to where this runs, and the default assumes the
/// repository root — which is where CI and every script here start from.
let arrangement = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "loop.json"

guard let contents = FileManager.default.contents(atPath: arrangement) else {
    fail("\(arrangement) does not exist, or could not be read.")
}

let parsed: JSON
do {
    parsed = try JSONDecoder().decode(JSON.self, from: contents)
} catch DecodingError.dataCorrupted(let context) {
    // Named down to the line, because "invalid JSON" about a file somebody is
    // about to merge is a message that costs them the search. The parser puts
    // the line and the column in the underlying error's description.
    let underlying = context.underlyingError as NSError?
    let reason =
        underlying?.userInfo[NSDebugDescriptionErrorKey] as? String ?? context.debugDescription
    fail("\(arrangement): not valid JSON — \(reason)")
} catch {
    fail("\(arrangement): not valid JSON — \(error)")
}

guard let document = parsed.object else {
    fail("\(arrangement): the document is not an object")
}

/// Whether the `AGENTS.md` beside the arrangement has the section the shared
/// instructions hold a change to. Without it a consumer would run with no local
/// bar, silently.
func agentLoopSectionProblem(besides arrangement: String) -> String? {
    let instructions = URL(fileURLWithPath: arrangement).deletingLastPathComponent()
        .appendingPathComponent("AGENTS.md").path
    guard let data = FileManager.default.contents(atPath: instructions) else {
        return "AGENTS.md: missing beside \(arrangement), and it must hold `\(agentLoopHeading)`"
    }
    let hasSection = String(decoding: data, as: UTF8.self).split(separator: "\n").contains {
        $0.trimmingCharacters(in: .whitespaces) == agentLoopHeading
    }
    return hasSection
        ? nil
        : "AGENTS.md: no `\(agentLoopHeading)` section, which holds the local bar and formatter"
}

let shapeProblems = loopProblems(in: document)
// Only a well-formed file is worth a read of the repository, and only `stack`
// asks for one.
let found =
    shapeProblems
    + (shapeProblems.isEmpty ? stackRepositoryProblems(in: document, gh: runGitHubCLI) : [])
    + [agentLoopSectionProblem(besides: arrangement)].compactMap {
        $0
    }
if !found.isEmpty {
    print("\(arrangement) is not a usable arrangement:")
    for problem in found {
        print("  \(problem)")
    }
    exit(1)
}

// Everything here is known to be present and of the right type, because a file
// that reached this line had nothing wrong with it.
let owner = document["owner"]?.string ?? ""
let project = document["project"]?.object
let projectOwner = project?["owner"]?.string ?? ""
let projectNumber = project?["number"]?.integer ?? 0
let agentCount = document["agents"]?.array?.count ?? 0
print(
    "\(arrangement): \(agentCount) agent(s), owner \(owner), "
        + "project \(projectOwner)/\(projectNumber)")
