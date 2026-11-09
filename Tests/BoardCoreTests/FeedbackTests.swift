// What `feedback` counts as answered.
//
// The rule under test is that naming answers and being newer does not. A reply
// that merely came afterwards is what once buried owner comments, and a
// tick reading `mergeable_state` instead of this is what left two reviews
// waiting on a pull request.
//

import Foundation
import Testing

@testable import BoardCore

@Suite("Owner feedback, and what answers it")
struct FeedbackTests {

    let pull = "https://github.com/example-org/example/pull/561"

    func at(_ minute: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(minute * 60))
    }

    func review(_ id: Int, at minute: Int) -> OwnerFeedback {
        OwnerFeedback(url: "\(pull)#pullrequestreview-\(id)", createdAt: at(minute))
    }

    func reply(_ body: String, at minute: Int) -> ConversationComment {
        ConversationComment(
            author: "agent-one", url: "\(pull)#issuecomment-\(minute)",
            createdAt: at(minute), body: body)
    }

    @Test("A review a reply names is answered")
    func namedReviewIsAnswered() {
        let feedback = [review(1, at: 10)]
        let conversation = [reply("Answering \(pull)#pullrequestreview-1.\n\nDone.", at: 20)]
        #expect(
            unansweredFeedback(feedback, conversation: conversation).isEmpty
        )
    }

    @Test("A review nothing names is unanswered")
    func unnamedReviewIsUnanswered() {
        let feedback = [review(1, at: 10)]
        #expect(
            unansweredFeedback(feedback, conversation: [])
                == ["\(pull)#pullrequestreview-1"])
    }

    @Test("One reply naming two urls answers both")
    func oneReplyAnswersTwo() {
        let feedback = [review(1, at: 10), review(2, at: 11)]
        let conversation = [
            reply(
                "Answering \(pull)#pullrequestreview-1.\nAnswering \(pull)#pullrequestreview-2.\n\nBoth done.",
                at: 20)
        ]
        #expect(
            unansweredFeedback(feedback, conversation: conversation).isEmpty
        )
    }

    @Test("A reply that is merely newer answers nothing")
    func newerIsNotAnswered() {
        let feedback = [review(1, at: 10)]
        let conversation = [reply("Findings on the latest head.", at: 20)]
        #expect(
            unansweredFeedback(feedback, conversation: conversation)
                == ["\(pull)#pullrequestreview-1"])
    }

    @Test("A reply naming a different url leaves the review unanswered")
    func otherURLIsNotAnswered() {
        let feedback = [review(1, at: 10)]
        let conversation = [reply("Answering \(pull)#pullrequestreview-2.", at: 20)]
        #expect(
            unansweredFeedback(feedback, conversation: conversation)
                == ["\(pull)#pullrequestreview-1"])
    }

    @Test("A line comment is answered by a reply naming it, like any other feedback")
    func lineCommentAnsweredByName() {
        let line = OwnerFeedback(url: "\(pull)#discussion_r1", createdAt: at(10))
        #expect(unansweredFeedback([line], conversation: []) == ["\(pull)#discussion_r1"])
        let conversation = [reply("Answering \(pull)#discussion_r1.", at: 20)]
        #expect(unansweredFeedback([line], conversation: conversation).isEmpty)
    }

    @Test("Unanswered feedback comes out oldest first")
    func oldestFirst() {
        let feedback = [review(2, at: 20), review(1, at: 10)]
        #expect(
            unansweredFeedback(feedback, conversation: [])
                == ["\(pull)#pullrequestreview-1", "\(pull)#pullrequestreview-2"])
    }

    @Test("Answering lines are read one per line, with or without the full stop")
    func answeringLines() {
        let body = "Answering a.\n  Answering b\nNot Answering c.\nAnswering d. trailing"
        #expect(answeredURLs(in: body) == ["a", "b", "d"])
    }

    @Test("A pull request is the issue's when it closes, refs or is part of it")
    func linkLines() {
        #expect(linksIssue(547, body: "Part of #547.\n\nA decision document."))
        #expect(linksIssue(652, body: "Closes #652."))
        #expect(linksIssue(652, body: "refs #652"))
        #expect(!linksIssue(65, body: "Closes #652."))
        #expect(!linksIssue(652, body: "Found while implementing #652."))
    }

    @Test("A pull request in another repository must name the issue in full")
    func linkLinesAcrossRepositories() {
        let fixtures = "example-org/fixtures"
        #expect(linksIssue(1118, body: "Closes example-org/example#1118.", from: fixtures))
        #expect(linksIssue(1118, body: "Closes example-org/example#1118."))
        #expect(!linksIssue(1118, body: "Closes #1118.", from: fixtures))
        #expect(!linksIssue(111, body: "Closes example-org/example#1118.", from: fixtures))
        #expect(!linksIssue(1118, body: "Closes example-org/other#1118.", from: fixtures))
    }
}
