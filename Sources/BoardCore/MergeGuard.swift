import Foundation

// The merge guard: the structural test every merge path passes before it acts on
// a pull request. See "Merging" in docs/stacked-pull-requests.md.
//
// `main`'s ruleset doesn't cover a pull request into a feature branch, so a
// pull request merges only into `main`, only once no former parent is open, and
// only if it contains every former parent that merged. Everything else about a
// merge is GitHub's `clean`. The guard asks for no approval of its own.

/// A pull request from a branch another pull request is, or was once, based on.
struct BranchPullRequest: Equatable {
    let number: Int
    let open: Bool
    /// Set once it has merged.
    let mergeCommit: String?
    /// What the restack repair reads of a parent: where its head is, what it
    /// merges into, whether it is a draft, and the body that names its issue.
    var head = ""
    var base = "main"
    var draft = false
    var body = ""
}

/// What the guard says about one pull request.
enum MergeGuardVerdict: Equatable {
    case passes
    /// Not merged now and nothing sent back: `reason` says what it waits for.
    case held(String)
    /// A merged former parent the head doesn't contain: the pull request is
    /// rebuilt onto `main` before it can merge.
    case restack(String)

    /// Why it doesn't pass; empty when it does.
    var reason: String {
        switch self {
        case .passes: ""
        case .held(let reason), .restack(let reason): reason
        }
    }

    var needsRestack: Bool {
        if case .restack = self { true } else { false }
    }
}

/// The guard's verdict on `id`, whose `merge` facts were just read.
///
/// The reads, in order and only as far as a verdict needs: none when the base
/// isn't `main`; then the one GraphQL query for former bases, refused below
/// `readReserve`; then one `pulls?head=` per former base and one compare per
/// merged former parent. A pull request never retargeted stops after the query.
func mergeGuard(
    _ id: PullRequestID, merge: MergeFacts, board: BoardProvider, source: SourceControl
) throws -> MergeGuardVerdict {
    guard merge.base == "main" else { return .held("its base is \(merge.base), not main") }
    do {
        try board.budget().requireReadReserve()
    } catch let error as BoardError {
        return .held("its former bases aren't read: \(error.message)")
    }

    let formerBases = Set(try source.formerBases(id)).subtracting([merge.base])
    var formerParents: [BranchPullRequest] = []
    for base in formerBases.sorted() {
        formerParents += try source.pullRequests(in: id.repository, from: base)
    }
    func name(_ parent: BranchPullRequest) -> String {
        "PR \(PullRequestID(repository: id.repository, number: parent.number).reference)"
    }

    if let open = formerParents.first(where: \.open) {
        return .held("former parent \(name(open)) is open")
    }
    for parent in formerParents {
        guard let commit = parent.mergeCommit else { continue }
        if try source.behindBy(in: id.repository, base: commit, head: merge.headSHA) > 0 {
            return .restack(
                "former parent \(name(parent)) merged as \(commit), which the head doesn't contain")
        }
    }
    return .passes
}

/// The `merge` verb: what a `MERGE` line asks for, judged again as it acts. The
/// line is a snapshot, and a former parent can reopen or the head move before a
/// tick runs it, so the guard and `clean` are read now and the merge is bound to
/// the head they were read on.
func guardedMerge(_ id: PullRequestID, board: BoardProvider, source: SourceControl) throws
    -> String
{
    let name = "PR \(id.reference)"
    let merge = try source.mergeFacts(id)
    guard merge.mergeableState == "clean" else {
        throw BoardError("\(name) is \(merge.mergeableState), not clean")
    }
    let verdict = try mergeGuard(id, merge: merge, board: board, source: source)
    guard verdict == .passes else { throw BoardError("\(name) is held: \(verdict.reason)") }
    try source.merge(id, head: merge.headSHA)
    return "merged \(name) at \(merge.headSHA)"
}

/// The former bases on a `--paginate --slurp`ed `formerBaseQuery` answer, oldest
/// first: a retarget by hand or by Tickwork, and the one GitHub makes when it
/// deletes a merged parent's branch.
func formerBases(timelineJSON json: String) throws -> [String] {
    guard let pages = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
    else { throw BoardError("GitHub answered with something that is not a list of pages") }
    return try pages.flatMap { page -> [String] in
        let data = page["data"] as? [String: Any]
        let repository = data?["repository"] as? [String: Any]
        guard
            let pull = repository?["pullRequest"] as? [String: Any],
            let items = pull["timelineItems"] as? [String: Any],
            let nodes = items["nodes"] as? [[String: Any]]
        else { throw BoardError("GitHub's base changes answer carries no timeline: \(page)") }
        return try nodes.map { node in
            guard let base = (node["previousRefName"] ?? node["oldBase"]) as? String else {
                throw BoardError("a base change names no former base: \(node)")
            }
            return base
        }
    }
}

/// A pull request's base changes, a page at a time, for `gh api graphql --paginate`.
let formerBaseQuery = """
    query($owner: String!, $name: String!, $number: Int!, $endCursor: String) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          timelineItems(first: 100, after: $endCursor,
                        itemTypes: [BASE_REF_CHANGED_EVENT, AUTOMATIC_BASE_CHANGE_SUCCEEDED_EVENT]) {
            pageInfo { hasNextPage endCursor }
            nodes {
              ... on BaseRefChangedEvent { previousRefName }
              ... on AutomaticBaseChangeSucceededEvent { oldBase }
            }
          }
        }
      }
    }
    """

/// The pull requests on a `--paginate --slurp`ed `pulls?head=` answer.
func branchPullRequests(pullsJSON json: String) throws -> [BranchPullRequest] {
    try jsonArray(json).map { pull in
        guard let number = pull["number"] as? Int else {
            throw BoardError("a pull request came back without a number")
        }
        let merged = pull["merged_at"] is String
        guard !merged || pull["merge_commit_sha"] is String else {
            throw BoardError("PR #\(number) merged and names no merge commit")
        }
        return BranchPullRequest(
            number: number, open: pull["state"] as? String == "open",
            mergeCommit: merged ? pull["merge_commit_sha"] as? String : nil,
            head: (pull["head"] as? [String: Any])?["sha"] as? String ?? "",
            base: (pull["base"] as? [String: Any])?["ref"] as? String ?? "",
            draft: pull["draft"] as? Bool ?? false, body: pull["body"] as? String ?? "")
    }
}
