import Foundation

/// What the supervisor is doing at one moment, built from its own state alone, so
/// it costs no request. See docs/supervisor-status.md.
struct SupervisorStatus: Equatable {
    let login: String
    /// `nil` for a build no installer made.
    let revision: String?
    let state: LoginState
    /// From the last check's headers; `nil` until one has carried all three.
    let core: CoreBudget?
    /// From the last `next` that answered one.
    let graphQL: GraphQLBudget?
    let child: Child?
    /// In argument order.
    let repositories: [Repository]

    /// The first that applies.
    enum LoginState: Equatable {
        case stopped(at: Date, reason: String)
        case paused(until: Date, cause: PauseCause)
        /// A new tool waits for the child to exit.
        case replacing(revision: String)
        case running
    }

    /// A login pause's raw value is its `pause` event's `reason`.
    enum PauseCause: String, Equatable {
        case secondaryLimit = "secondary limit"
        case coreLimit = "core limit"
        case subscriptionLimit = "subscription limit"
        case ambiguousEnding = "ambiguous ending"
    }

    struct CoreBudget: Equatable {
        let remaining: Int
        let limit: Int
        let reset: Date
        /// Below the rate floor before the reset, so interval reconciliations wait.
        let limited: Bool
    }

    struct GraphQLBudget: Equatable {
        let budget: BudgetAnswer
        let reported: Date
    }

    struct Assignment: Equatable {
        /// `nil` when `next` names none.
        let issue: Int?
        let role: String
        let task: String
    }

    struct Child: Equatable {
        let repository: String
        let started: Date
        /// When the time limit's SIGTERM was sent.
        let terminated: Date?
        let purpose: Purpose
    }

    enum Purpose: Equatable {
        case assignment(Assignment)
        /// The issues of the `MERGE` lines it was launched for.
        case merge(issues: [Int])
    }

    struct Repository: Equatable {
        let name: String
        let state: State
        /// The failure not yet recovered from, whichever state shows.
        let error: String?
        /// The last round in which every check answered.
        let checked: Date?
        /// Since when a check or a watch has been failing.
        let failingSince: Date?
        /// The last board page that answered `200`.
        let changed: Date?
        let due: Due?
        let next: Next
        let setAsideMerges: [Int]
    }

    /// The first that applies.
    enum State: Equatable {
        case parked(Assignment)
        /// A `next` error that isn't retryable: `error` says what.
        case needsFix
        /// The child that ended here stopped the supervisor, with this outcome.
        case ended(outcome: String, purpose: Purpose)
        /// The child runs here.
        case claude
        case reconciling(since: Date, reasons: [String])
        case backingOff(until: Date)
        /// A check or a watch is failing.
        case failing
        /// `nil` when nothing holds it and it is simply next in line.
        case due(waitingFor: Hold?)
        case idle
    }

    enum Hold: Equatable {
        case child(repository: String)
        case pause
        case coreFloor
    }

    struct Due: Equatable {
        let since: Date
        let reasons: [String]
    }

    enum Next: Equatable {
        case at(Date)
        /// The core floor holds an earlier interval time until this reset.
        case after(Date)
        /// An orchestrator repository waiting for a turn another may take first.
        case inTurn
        /// Dormant: no interval comes round, so only a check's trigger wakes it.
        case onChange
    }
}

/// When a check or a watch started failing, and what it says now.
struct Failing: Equatable {
    let since: Date
    var message: String
}

/// An assignment answer's issue, role and task.
func assignmentSummary(_ answer: [String: Any]) -> SupervisorStatus.Assignment {
    .init(
        issue: (answer["issue"] as? [String: Any])?["number"] as? Int,
        role: answer["role"] as? String ?? "", task: answer["task"] as? String ?? "")
}

/// `next`'s `budget`, when it answered one.
func budgetAnswer(_ value: Any?) -> BudgetAnswer? {
    guard let budget = value as? [String: Any], let remaining = budget["remaining"] as? Int,
        let limit = budget["limit"] as? Int
    else { return nil }
    return BudgetAnswer(remaining: remaining, limit: limit)
}

/// The issue of a `MERGE #<issue> PR <ref> …` repair line.
func mergeIssue(_ line: String) -> Int? {
    let words = line.split(separator: " ")
    guard words.count > 1, words[0] == "MERGE", words[1].hasPrefix("#") else { return nil }
    return Int(words[1].dropFirst())
}
