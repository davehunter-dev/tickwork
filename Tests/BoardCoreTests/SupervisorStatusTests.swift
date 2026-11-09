// `tickwork loop`'s status snapshot: one test per row of the state inventory in
// docs/supervisor-status.md, each `next T` rule, and where it is published.
//

import Foundation
import Testing

@testable import BoardCore

private func at(_ seconds: TimeInterval) -> Date {
    SupervisorWorld.start.addingTimeInterval(seconds)
}

private let merges =
    ##"{"schema":1,"kind":"idle","nextDelay":"backoff","repairs":["MERGE #4 PR #9 is clean","MERGE #5 PR example-org/b#10 is clean"]}"##

extension SupervisorWorld {
    var status: SupervisorStatus { supervisor.status(at: clock.now) }

    func status(of name: String) throws -> SupervisorStatus.Repository {
        try #require(status.repositories.first { $0.name == "example-org/\(name)" })
    }
}

@Suite("tickwork loop: the status snapshot")
struct SupervisorStatusTests {

    // MARK: The inventory

    @Test("Idle: the login, its budgets, and a repository due for nothing")
    func idle() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        try world.start(["a"])
        world.run(for: 1)
        let status = world.status
        #expect(status.login == "agent-one")
        #expect(status.revision == "abc-revision")
        #expect(status.state == .running)
        #expect(
            status.core
                == .init(
                    remaining: 4_000, limit: 5_000, reset: world.github.rateReset, limited: false))
        #expect(status.child == nil)
        #expect(
            try world.status(of: "a")
                == .init(
                    name: "example-org/a", state: .idle, error: nil, checked: at(0),
                    failingSince: nil, changed: at(0), due: nil, next: .at(at(600)),
                    setAsideMerges: []))
    }

    @Test("Checking: a round of unchanged pages moves checked and leaves changed")
    func checking() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        try world.start(["a"])
        world.run(for: 20)
        let repository = try world.status(of: "a")
        #expect(repository.checked == at(15))
        #expect(repository.changed == at(0))
        world.github.change(1) { $0[0][0] = BoardCard(number: 1, status: "Ready", updatedAt: "t1") }
        world.run(for: 15)
        #expect(try world.status(of: "a").changed == at(30))
    }

    @Test("Due and held by a running child")
    func dueHeldByChild() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        world.repository("b", number: 2)
        world.commands.answers["/work/a"] = [assignment(1)]
        world.commands.answers["/work/b"] = [assignment(2)]
        try world.start(["a", "b"])
        world.run(for: 1)
        let b = try world.status(of: "b")
        #expect(b.state == .due(waitingFor: .child(repository: "example-org/a")))
        #expect(b.due == .init(since: at(0), reasons: ["start"]))
        #expect(b.next == .at(at(600)))
        world.run(for: 5)
        #expect(try world.status(of: "b").next == .at(at(600)))
    }

    @Test("Due and held by a login pause, here Claude's subscription limit")
    func subscriptionLimit() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        let reset = at(60 * 60)
        world.launcher.endings = [
            (
                [
                    #"{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","rateLimitType":"five_hour","resetsAt":\#(Int(reset.timeIntervalSince1970))}}"#
                ], 1
            )
        ]
        world.commands.answers["/work/a"] = [assignment(1)]
        try world.start(["a"])
        world.run(for: 5 * 60)
        #expect(world.status.state == .paused(until: reset, cause: .subscriptionLimit))
        #expect(try world.status(of: "a").state == .due(waitingFor: .pause))
    }

    @Test("Due and held by the core floor, whose reset is also the next time")
    func coreFloor() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        world.repository("b", number: 2)
        world.launcher.duration = 30 * 60
        world.github.rateReset = at(45 * 60)
        world.commands.answers["/work/a"] = [assignment(1)]
        try world.start(["b", "a"])
        world.run(for: 15 * 60)
        world.github.rateRemaining = 900
        world.run(for: 25 * 60)
        #expect(world.status.core?.limited == true)
        let b = try world.status(of: "b")
        #expect(b.state == .due(waitingFor: .coreFloor))
        #expect(b.next == .after(at(45 * 60)))
    }

    @Test("Claude running for an assignment names its issue, role and task")
    func childForAssignment() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        world.commands.answers["/work/a"] = [assignment(3)]
        try world.start(["a"])
        world.run(for: 1)
        #expect(
            world.status.child
                == .init(
                    repository: "example-org/a", started: at(0), terminated: nil,
                    purpose: .assignment(.init(issue: 3, role: "engineer", task: "start"))))
        #expect(try world.status(of: "a").state == .claude)
    }

    @Test("An assignment without an issue still launches, its purpose naming none")
    func childForAssignmentWithoutIssue() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        world.commands.answers["/work/a"] = [
            #"{"schema":1,"kind":"assignment","role":"engineer","task":"start","repairs":[]}"#
        ]
        try world.start(["a"])
        world.run(for: 1)
        #expect(
            world.status.child?.purpose
                == .assignment(.init(issue: nil, role: "engineer", task: "start")))
        #expect(world.events("launch").count == 1)
    }

    @Test("Claude running for MERGE lines) names each line's issue")
    func childForMerges() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        world.commands.answers["/work/a"] = [merges]
        try world.start(["a"])
        world.run(for: 1)
        #expect(world.status.child?.purpose == .merge(issues: [4, 5]))
    }

    @Test("Claude past the time limit carries when SIGTERM was sent")
    func timeLimit() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        world.launcher.duration = nil
        world.launcher.ignoresTerm = true
        world.commands.answers["/work/a"] = [assignment(1)]
        try world.start(["a"])
        world.run(for: ChildTiming.timeLimit + 5)
        #expect(world.status.child?.terminated == at(ChildTiming.timeLimit))
        #expect(try world.status(of: "a").state == .claude)
    }

    @Test("A failing board check: since its first failure, with its message")
    func checkFailing() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        try world.start(["a"])
        world.run(for: 20)
        world.github.failing = ["projectsV2/1"]
        world.run(for: 15)
        let repository = try world.status(of: "a")
        #expect(repository.state == .failing)
        #expect(repository.error == "connection reset")
        #expect(repository.failingSince == at(30))
        #expect(repository.checked == at(15))
    }

    @Test("A watched card's unreadable pull requests are failing")
    func watchFailing() throws {
        let world = SupervisorWorld()
        world.repository(
            "a", number: 1, roles: ["orchestrator", "reviewer"],
            pages: [[BoardCard(number: 5, status: "Human Review", updatedAt: "t0")]])
        world.github.timelines[5] = "not a timeline"
        try world.start(["a"])
        world.run(for: 1)
        let repository = try world.status(of: "a")
        #expect(repository.state == .failing)
        #expect(repository.failingSince == at(0))
        #expect(repository.error != nil)
    }

    @Test("Backing off after a failed reconciliation: next is the backoff's end")
    func backingOff() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        world.commands.answers["/work/a"] = [
            #"{"schema":1,"kind":"error","stage":"provider","message":"x","retry":true}"#
        ]
        try world.start(["a"])
        world.run(for: 1)
        let repository = try world.status(of: "a")
        #expect(repository.state == .backingOff(until: at(60)))
        #expect(repository.error == "x")
        #expect(repository.next == .at(at(60)))
        #expect(repository.due?.reasons == ["retry"])
    }

    @Test("A next error that isn't retryable needs a fix on main")
    func needsFix() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        world.commands.answers["/work/a"] = [
            #"{"schema":1,"kind":"error","stage":"loop.json","message":"bad","retry":false}"#
        ]
        try world.start(["a"])
        world.run(for: 1)
        let repository = try world.status(of: "a")
        #expect(repository.state == .needsFix)
        #expect(repository.error == "bad")
        #expect(repository.next == .at(at(600)))
    }

    @Test("GraphQL comes from next's budget, and stays as reported when next refuses for it")
    func graphQLBudget() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        world.commands.answers["/work/a"] = [
            #"{"schema":1,"kind":"idle","nextDelay":"now","repairs":[],"budget":{"remaining":4888,"limit":5000}}"#,
            #"{"schema":1,"kind":"error","stage":"budget","message":"below the read reserve","retry":true}"#,
        ]
        try world.start(["a"])
        world.run(for: 1)
        #expect(
            world.status.graphQL
                == .init(budget: BudgetAnswer(remaining: 4_888, limit: 5_000), reported: at(0)))
        let repository = try world.status(of: "a")
        #expect(repository.state == .backingOff(until: at(60)))
        #expect(repository.error == "below the read reserve")
    }

    @Test("GraphQL's budget is dated when next answers, not when the reconciliation began")
    func graphQLBudgetDatedOnAnswer() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        world.commands.answers["/work/a"] = [
            #"{"schema":1,"kind":"idle","nextDelay":"backoff","repairs":[],"budget":{"remaining":4888,"limit":5000}}"#
        ]
        let clock = world.clock
        world.commands.onNext = { clock.now = clock.now.addingTimeInterval(50) }
        try world.start(["a"])
        world.run(for: 1)
        #expect(world.status.graphQL?.reported == at(50))
    }

    @Test("GitHub's secondary limit pauses the login")
    func secondaryLimit() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        try world.start(["a"])
        world.run(for: 20)
        world.github.override = CheckResponse(
            status: 403, headers: [:], body: "You have exceeded a secondary rate limit")
        world.run(for: 11)
        #expect(world.status.state == .paused(until: at(90), cause: .secondaryLimit))
    }

    @Test("An exhausted core limit pauses the login until its reset")
    func coreLimit() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        try world.start(["a"])
        world.run(for: 20)
        world.github.override = SupervisorTests.coreExhausted(resetIn: 30 * 60)
        world.github.overrideCount = 1
        world.run(for: 11)
        #expect(world.status.state == .paused(until: at(30 * 60), cause: .coreLimit))
    }

    @Test("An ambiguous ending pauses the login")
    func ambiguousEnding() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        world.launcher.endings = [([], 0)]
        world.commands.answers["/work/a"] = [assignment(1)]
        try world.start(["a"])
        world.run(for: 5 * 60)
        #expect(
            world.status.state
                == .paused(
                    until: at(120 + ChildTiming.firstAmbiguityPause), cause: .ambiguousEnding))
    }

    @Test("Parked names the assignment that made no progress")
    func parked() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        world.commands.answers["/work/a"] = Array(repeating: assignment(1), count: 5)
        try world.start(["a"])
        world.run(for: 30 * 60)
        #expect(
            try world.status(of: "a").state
                == .parked(.init(issue: 1, role: "engineer", task: "start")))
    }

    @Test("MERGE lines set aside are listed by issue")
    func setAside() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        let merge =
            ##"{"schema":1,"kind":"idle","nextDelay":"backoff","repairs":["MERGE #4 PR #9 is clean"]}"##
        world.commands.answers["/work/a"] = [merge, merge, merge]
        try world.start(["a"])
        world.run(for: 25 * 60)
        #expect(try world.status(of: "a").setAsideMerges == [4])
    }

    @Test("A replacement waiting for the child is the login's state")
    func replacing() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        world.installed = RunningTool(path: SupervisorWorld.installedPath, revision: "def")
        world.commands.answers["/work/a"] = [assignment(1)]
        try world.start(["a"])
        world.run(for: 30)
        #expect(world.status.state == .replacing(revision: "def"))
    }

    @Test("A stop is published as the login's last state")
    func stopped() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        world.launcher.auth = CommandResult(status: 1, output: "", errors: "not logged in")
        world.commands.answers["/work/a"] = [assignment(1)]
        try world.start(["a"])
        world.run(for: 60)
        let reason = try #require(world.events("stop").first?["reason"] as? String)
        #expect(world.statuses.last?.state == .stopped(at: at(0), reason: reason))
    }

    @Test("A child whose ending stopped the supervisor keeps its line in the last state")
    func endedByChild() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        world.launcher.endings = [
            ([#"{"type":"result","is_error":true,"api_error_status":401}"#], 1)
        ]
        world.commands.answers["/work/a"] = [assignment(1)]
        try world.start(["a"])
        world.run(for: 150)
        #expect(
            world.statuses.last?.repositories.first?.state
                == .ended(
                    outcome: "authentication",
                    purpose: .assignment(.init(issue: 1, role: "engineer", task: "start"))))
    }

    // MARK: next T

    @Test("Only the orchestrator repository the turn would pick has a time; the others are in turn")
    func orchestratorTurn() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1, roles: ["orchestrator", "engineer"])
        world.repository("b", number: 2, roles: ["orchestrator", "engineer"])
        try world.start(["a", "b"])
        world.run(for: 1)
        #expect(try world.status(of: "a").next == .at(at(SupervisorTiming.orchestratorTurn)))
        #expect(try world.status(of: "b").next == .inTurn)
    }

    // MARK: Publishing

    @Test("Reconciling is published before next runs, and every step ends by publishing")
    func publishes() throws {
        let world = SupervisorWorld()
        world.repository("a", number: 1)
        try world.start(["a"])
        world.run(for: 1)
        // A reconciliation, the step that ran it, and the step that found nothing due.
        #expect(
            world.statuses.map { $0.repositories[0].state } == [
                .reconciling(since: at(0), reasons: ["start"]), .idle, .idle,
            ])
    }
}
