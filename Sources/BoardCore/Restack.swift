import Foundation

// The restack repair: what a stacked pull request's parent asks of it. See
// "Keeping a stack current" in docs/stacked-pull-requests.md.
//
// GitHub judges `mergeable` against the base, so for a pull request based on
// another's branch the conflict and behind reasons fire whenever the parent
// force-pushes, and their fix would pull the parent's commits into the child.
// This replaces them. It only sends the child back: working out which commits
// are the child's and rebasing them is the Engineer's.

/// What a stacked pull request's Engineer must do about its parent.
enum StackFinding: Equatable {
    /// Rebuild the child's own commits on `onto`, a commit or `main`, and with
    /// `retarget` change its base to `main`.
    case restack(onto: String, retarget: Bool, reason: String)
    /// The parent isn't one the design's table knows; `reason` names what was seen.
    case broken(String)

    /// The repair's reason for moving the card.
    var reason: String {
        switch self {
        case .restack(let onto, let retarget, let reason):
            "must restack onto \(onto)\(retarget ? " and retarget to main" : ""): \(reason)"
        case .broken(let reason): "has a broken stack: \(reason)"
        }
    }

    var answer: FindingAnswer {
        switch self {
        case .restack(let onto, let retarget, let reason):
            FindingAnswer(kind: "restack", detail: reason, onto: onto, retarget: retarget)
        case .broken(let reason): FindingAnswer(kind: "stack-broken", detail: reason)
        }
    }
}

/// What the parent of `id` asks of it, or `nil` when the child is current or
/// waits for its parent to settle. `nil` too for a pull request into `main`.
///
/// Two REST reads, the parent and one compare, plus the parent's checks when it
/// may be settled. `ownerReview` is the board's cards in the owner's column,
/// where a settled parent's issue sits unclaimed. Never a write.
func stackFinding(
    _ id: PullRequestID, merge: MergeFacts, ownerReview: [Item], source: SourceControl
) throws -> StackFinding? {
    guard merge.base != "main" else { return nil }
    let fromBase = try source.pullRequests(in: id.repository, from: merge.base)
    func name(_ pullRequest: BranchPullRequest) -> String {
        "PR \(PullRequestID(repository: id.repository, number: pullRequest.number).reference)"
    }

    let open = fromBase.filter(\.open)
    if open.count == 1, let parent = open.first {
        guard try settled(parent, in: id.repository, ownerReview: ownerReview, source: source),
            try source.behindBy(in: id.repository, base: parent.head, head: merge.headSHA) > 0
        else { return nil }
        return .restack(
            onto: parent.head, retarget: false,
            reason:
                "parent \(name(parent)) settled at \(parent.head), which the head doesn't contain"
        )
    }
    // With nothing open, only a branch whose one pull request merged into main
    // names the parent; any other history beside it leaves which is current unknown.
    if fromBase.count == 1, let parent = fromBase.first, parent.base == "main",
        let commit = parent.mergeCommit
    {
        return .restack(
            onto: "main", retarget: true,
            reason: "parent \(name(parent)) merged into main as \(commit)")
    }

    guard !fromBase.isEmpty else { return .broken("no pull request is from \(merge.base)") }
    let seen = fromBase.map { pullRequest in
        if pullRequest.open { return "\(name(pullRequest)) is open" }
        if pullRequest.mergeCommit != nil {
            return "\(name(pullRequest)) merged into \(pullRequest.base)"
        }
        return "\(name(pullRequest)) closed without merging"
    }
    return .broken("from \(merge.base), " + seen.joined(separator: ", "))
}

/// A settled parent: its issue's card is unclaimed in the owner's column, it
/// isn't a draft, and its checks are green.
private func settled(
    _ parent: BranchPullRequest, in repository: String, ownerReview: [Item],
    source: SourceControl
) throws -> Bool {
    guard !parent.draft,
        ownerReview.contains(where: {
            $0.assignees.isEmpty && linksIssue($0.number, body: parent.body, from: repository)
        })
    else { return false }
    return try source.checks(in: repository, at: parent.head).green
}
