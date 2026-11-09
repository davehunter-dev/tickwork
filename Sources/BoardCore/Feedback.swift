import Foundation

/// Something the owner said on a pull request: a review requesting changes or
/// carrying a summary, a comment on the conversation, or a comment on a line of
/// the diff. Answered only by an `Answering <url>.` line naming it.
struct OwnerFeedback: Equatable {
    let url: String
    let createdAt: Date
}

/// A comment on the pull request's conversation, which is where every
/// `Answering` line lands.
struct ConversationComment: Equatable {
    let author: String
    let url: String
    let createdAt: Date
    let body: String
}

/// The urls a comment's `Answering <url>.` lines name, one per line.
func answeredURLs(in body: String) -> Set<String> {
    let prefix = "Answering "
    var urls: Set<String> = []
    for line in body.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(prefix) else { continue }
        var url = String(trimmed.dropFirst(prefix.count).split(separator: " ").first ?? "")
        if url.hasSuffix(".") { url.removeLast() }
        if !url.isEmpty { urls.insert(url) }
    }
    return urls
}

/// The urls of every piece of owner feedback nothing has answered, oldest first.
///
/// **Naming is the answer, and being newer is not.** A reply or a commit that
/// merely came afterwards would count anything the loop did as an answer, and the
/// loop does something on every pass — see the feedback repair in
/// `docs/repairs.md`.
func unansweredFeedback(_ feedback: [OwnerFeedback], conversation: [ConversationComment])
    -> [String]
{
    let named = conversation.reduce(into: Set<String>()) { $0.formUnion(answeredURLs(in: $1.body)) }
    return
        feedback
        .filter { !named.contains($0.url) }
        .sorted { $0.createdAt < $1.createdAt }
        .map(\.url)
}

/// Whether a pull request body says it is the work for this issue.
///
/// The three link lines `AGENTS.md` prescribes. A body that only mentions the
/// issue in passing — `Found while implementing #N.` — is some other issue's pull
/// request, and the owner's feedback on it is not this card's.
///
/// A pull request in another repository names the issue in full, as
/// `owner/name#N` of the board's repository, because a bare `#N` there is that
/// repository's own issue.
func linksIssue(
    _ issue: Int, body: String, from repository: String = Coordinates.repository,
    home: String = Coordinates.repository
) -> Bool {
    let home = home.lowercased()
    var references = ["\(home)#\(issue)"]
    if repository.lowercased() == home {
        references.append("#\(issue)")
    }
    return body.split(separator: "\n").contains { line in
        let lowered = line.trimmingCharacters(in: .whitespaces).lowercased()
        return ["closes ", "refs ", "part of "].contains { keyword in
            references.contains { reference in
                guard lowered.hasPrefix(keyword + reference) else { return false }
                let rest = lowered.dropFirst(keyword.count + reference.count)
                return rest.first.map { !$0.isNumber } ?? true
            }
        }
    }
}

/// The owner feedback on an issue's open pull requests that no reply has
/// answered, printed as urls. Prints nothing when nothing is waiting.
///
/// **One verb because three reads left as prose get partially run.** A tick that
/// read only `mergeable_state` saw `blocked` — which covers "no approval yet" and
/// "changes requested" alike — and reported a pull request idle while two reviews waited.
func feedback(on issue: Int, board: BoardProvider, source: SourceControl) throws {
    for pullRequest in try board.linkedPullRequests(of: issue) where pullRequest.open {
        try source.unansweredFeedback(pullRequest.id).forEach { print($0) }
    }
}

/// The owner's reviews that ask for something: changes requested, or a summary
/// written. **An approval is not a request**, so a bare approval is dropped, and
/// a pull request the owner has just approved is not sent back for work. Reads a
/// `--slurp`ed page list, or a single page.
func ownerReviewRequests(reviewsJSON json: String, owner: String) throws -> [OwnerFeedback] {
    guard let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Any] else {
        throw BoardError("reviews came back as something this could not read")
    }
    let reviews = parsed.flatMap {
        ($0 as? [[String: Any]]) ?? [$0 as? [String: Any]].compactMap { $0 }
    }
    return try reviews.compactMap { review in
        guard (review["user"] as? [String: Any])?["login"] as? String == owner,
            let url = review["html_url"] as? String,
            let submitted = review["submitted_at"] as? String
        else { return nil }
        let asks =
            review["state"] as? String == "CHANGES_REQUESTED"
            || !(review["body"] as? String ?? "").isEmpty
        return asks ? OwnerFeedback(url: url, createdAt: try date(submitted)) : nil
    }
}

func date(_ text: String) throws -> Date {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let parsed = ISO8601DateFormatter().date(from: trimmed) else {
        throw BoardError("not a timestamp GitHub would write: \(trimmed)")
    }
    return parsed
}
