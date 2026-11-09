# Workflow orchestration in Swift

**Status:** proposal. Design only; the consumer issue that asked for it links here.

## TLDR

**A tick becomes two calls with judgment in between.** `tickwork next` does
everything a tick now does by reading prose: it loads `loop.json`, runs the
repairs, picks the item and role, claims and re-checks it, and prints one JSON
**assignment**. The agent does the work and then calls `tickwork finish` with an
**outcome**, such as `submitted`, `changes-requested`, `approved`, `blocked` or
`needs-human`. It never names a column. Swift checks the outcome, writes every
marker the repairs depend on (`PR:`, `Bailing out:`, `Blocked-on:`,
`Answering`), moves the card and releases the claim.

**Instructions shrink to judgment.** About 1,550 lines of instructions load each
tick today. That becomes about 350: a one-page `next-task.md` and three role
files that say how to build, design and review. Rationale and history move to
`docs/`. Agents stop knowing about columns, GitHub Projects or transition rules.
Board mechanics sit behind a `BoardProvider` and pull-request facts behind
`SourceControl`, so a move to Jira changes Swift and not the instructions.

**Behaviour stays the same except for three changes you approve or reject
separately**, listed under [Changes for the owner](#changes-for-the-owner):
1. A tick picks its own interrupted claim back up.
2. `unable` is a new outcome.
3. Column and label names move into `loop.json`, with today's values as the
   defaults.

## The boundary

| Swift owns | The agent owns |
|---|---|
| Reading and validating `loop.json`, every invocation | Building, designing, reviewing |
| Repairs (orchestrator only), unchanged | Judging whether an existing pull request is finished |
| Choosing the item and role (step 2's table and its skips) | Deciding to escalate, and the question it asks |
| Claiming, re-validating, releasing | Every sentence a person reads: findings, PR bodies, bail-out reasons |
| Column transitions, with `--from` semantics | Which owner comments a reply answers |
| Every structured marker the repairs read | Choosing which follow-up issues to file and their content |
| Labels, blocker relations, assignment to the owner | Staging, committing, pushing, opening the PR |

The agent still runs `git` and `gh pr create`, because building and opening a
pull request is execution. Swift never edits a working tree.

## Start of tick: `tickwork next`

    sh <tool> next [--roles reviewer,engineer,designer,orchestrator]

`--roles` replaces `/next-task [role...]`. Omitting it means all four, as today.
`--preview` runs steps 1 and 4 only. It loads, validates and selects, prints
what it would choose, and writes nothing: no repairs, no claim.
In order:

1. **Load `loop.json`** from `origin/main`, the file every verb reads,
   and validate it with `check-loop`'s rules. An invalid file is an `error`.
   Roles the file doesn't give this login are dropped and listed in `notes`. An
   unlisted login runs as a single agent and says so, as today.
2. **Repairs**, only when the tick holds `orchestrator`. This runs today's
   `repairs --apply` unchanged, and its lines appear in `repairs`.
3. **Resume an interrupted claim** (change 1). The agent's own claim on a card in
   a working column comes back first, with `"resumed": true`.
4. **Select.** This is step 2 as a pure function over a snapshot of the board
   and per-card facts. It covers the right-to-left order, `Ready` split by
   `type:design`, epics, open blockers, checks still running, and the authorship
   rule for `Agent Review`. Every skip is recorded in `skipped` with its reason.
5. **Claim and re-validate** with today's protocol: read the assignee, add,
   read back, then refresh the board. A lost race moves on to the next
   candidate, and that too is recorded in `skipped`.
6. **Print the assignment.**

Selection reuses the repairs' pattern: an I/O layer gathers `CardFacts`, and a
pure function decides. The fixture-driven tests that pin `repairs(for:)` today
pin `select(from:)` the same way.

### The assignment

```json
{
  "schema": 1,
  "kind": "assignment",
  "token": "tw1~agent-one~example-org/example~7~engineer~address-findings~In%20Progress~2026-10-28T13:49:02Z",
  "tickwork": "1f0c56fb",
  "budget": { "remaining": 4981, "limit": 5000 },
  "repairs": ["MERGE #3 PR #12 is clean"],
  "skipped": [
    { "issue": 5, "reason": "authored-by-this-agent", "detail": "agent-two can review it" },
    { "issue": 9, "reason": "blocked", "detail": "#8 open" }
  ],
  "notes": [],
  "role": "engineer",
  "resumed": false,
  "issue": {
    "number": 7,
    "repository": "example-org/example",
    "title": "Clean up project-specific historical references",
    "type": "feature",
    "labels": ["area:build"],
    "url": "https://github.com/example-org/example/issues/7"
  },
  "task": "address-findings",
  "pullRequest": {
    "ref": "example-org/tickwork#2",
    "branch": "f/7-generic-history",
    "mergeable": false,
    "checks": "green",
    "authors": ["agent-two"]
  },
  "findings": [
    { "kind": "owner-review", "url": "https://github.com/example-org/tickwork/pull/2#pullrequestreview-5683042316" },
    { "kind": "conflict", "detail": "does not merge with main" }
  ],
  "instructions": "engineer",
  "outcomes": ["submitted", "blocked", "needs-human", "unable"]
}
```

- **`task`** tells the role what kind of pass this is, from facts Swift
  already reads:
  - `start` is a fresh item.
  - `address-findings` comes with `findings`.
  - `assess-existing` has an open pull request and no findings: today's
    "fourth case", where the agent judges whether the work is done.
  - `decompose` is a merged design.
  - `review` and `design` are self-explanatory.
- **`findings`** covers red checks, conflicts, `behind`, unanswered owner
  feedback with its URLs, and the Reviewer's outstanding findings. The agent no
  longer reads checks or reviews to learn why the card came back. A Reviewer's
  findings are the pull request's newest comment carrying a `finish` marker
  (see [Markers](#markers)), when that marker says `changes-requested`. An
  engineer's `submitted` posts a marked comment of its own, which settles them.
  Findings written before the cut-over carry no marker and are not listed, so
  for those the agent reads the thread as it does today.
- **`outcomes`** lists what `finish` will accept for this role and task.
- **`token`** is everything `finish` needs to re-check the claim, in `~`-separated
  fields after `tw1`:
  - the login that claimed it;
  - the issue's repository and number;
  - the role and the task, which together say which outcomes `finish` accepts;
  - the column the card was taken from, URL-encoded;
  - the claim time, which is the `assigned` event `next` read back.

  `finish` refuses a token whose login is not `gh api user` at that moment,
  or whose claim time is not the issue's newest `assigned` event for that
  login. The claim time is what tells two sessions of one login apart. A
  second claim by the same login, after a release, has a newer time, so a
  stale token from the first can't finish over it. The token is plain text, so
  nothing is stored locally and an interrupted tick loses nothing.

### The other answers

```json
{ "schema": 1, "kind": "idle", "budget": {"remaining": 4993, "limit": 5000},
  "repairs": [], "skipped": [{"issue": 5, "reason": "authored-by-this-agent"}],
  "notes": [], "nextDelay": "backoff" }
```

```json
{ "schema": 1, "kind": "error", "stage": "loop.json",
  "message": "agents[1].roles: \"orchestator\" is not a role", "retry": false }
```

Each `stage` has one reading:

| `stage` | Meaning | Agent does |
|---|---|---|
| `loop.json` | The file is invalid, so no role can be trusted | Report and end the tick |
| `budget` | GraphQL is below the read reserve | Report and back off |
| `provider` | A read failed (network, 5xx) | Report and back off; `retry: true` |
| `claim-permission` | The claim did not take, so the login lacks write access | Report and end the tick |

A tick left with no roles is `idle`, with a note saying so.
`nextDelay` is `"now"` or `"backoff"`, so the doubling rule stays in Swift.

## During the tick: helper verbs

Each takes the token, so it can act only on the claimed item. Each is
idempotent and prints JSON.

| Verb | Agent gives | Swift does |
|---|---|---|
| `file-issue --token T --key K --title … --body-file F [--label L…]` | A key naming this intended issue, stable for the claim (for example `gap-socket-timeout`), the title, the body and the labels the consumer's `AGENTS.md` asks for | Files in the issue repository, in its Backlog. Prefixes `Found while implementing #N.`, which is Tickwork's own rule. Applies the labels as given and ends the body with an issue marker for the token and key. A retry finds that marker and returns the issue it already filed. Creating an issue never authorises work. |
| `add-blocker --token T --blocker N` / `remove-blocker` | The other issue | Records the provider's blocking relation, as `add-blocker` does today. The issue body is the agent's to edit, in whatever shape the consumer uses. |
| `reply --token T --answering URL… --body-file F` | Prose, and which feedback it answers | Checks each URL is among this pull request's outstanding feedback, then posts the comment with one `Answering <url>.` line per URL. |
| `decompose --token T --key K --title … --body-file F [--label L…]`, once per task | A key per task (for example `task-2`), the task in the consumer's issue shape, and its labels | Files it in the issue repository with `Part of #N.`, in Backlog, with the same issue marker and the same retry rule as `file-issue`. `finish decomposed` closes the design issue. |

**Issues go to the issue repository, and only there.** That is `loop.json`'s
`repository`, whose project is the board. `file-issue`, `decompose`, blocker
relations and every comment on an issue use it, and nothing else decides it:
not the checkout's `origin`, and not the repository a pull request lives in.
For example, Tickwork's own work is tracked in the consumer's issue repository
while its code and pull requests live in Tickwork's. The token carries the
issue repository, and every verb refuses a token whose repository differs from
`loop.json`'s.

**Idempotent by operation, not by title.** The issue marker is a hidden last
line in the body:

    <!-- tickwork:issue tw1~agent-one~example-org/example~7~engineer~start~In%20Progress~2026-10-28T13:49:02Z gap-socket-timeout -->

Before filing, the verb lists the issue repository's issues created by the
token's login since the claim time, in every state, and looks for that line.
Finding it, it returns the issue rather than filing again, even if the issue
has since closed. Two different intended issues with the same title get
different keys, so they don't collide.

Whether a gap is already filed by somebody else is still the agent's judgment,
as it is today ("search open issues first"). The key prevents only the
verb's own duplicates.

## End of tick: `tickwork finish`

    sh <tool> finish --token T <outcome> [arguments]

| Outcome | Roles | Arguments | Swift does, in order |
|---|---|---|---|
| `submitted` | engineer, designer | `--pr <ref>`, `--new` when this pass opened it, and `--body-file` (what this pass did about them) when the assignment listed findings | Comments `PR: <ref>` on the issue if `--new`. With a body, comments it on the pull request. Moves the card to the review column and releases the claim. |
| `decomposed` | engineer | none (uses `decompose`'s issues) | Closes the design issue and releases the claim. |
| `approved` | reviewer | `--body-file` (what was checked), `--answering URL…` | Comments on the PR, assigns the owner and requests their review, moves the card to `Human Review` and releases the claim. |
| `changes-requested` | reviewer | `--body-file` (findings), `--answering URL…` | Comments on the PR, moves the card to the work column for its type and releases the claim. |
| `blocked` | any | `--on N…`, `--body-file` (why) | Comments `Bailing out:` with the reason and one `Blocked-on: #N` line per blocker. Moves the card to `Needs Human` and releases the claim. |
| `needs-human` | any | `--body-file` (the question, the options, where it should return) | Comments `Bailing out:` with the question. Moves the card to `Needs Human` and releases the claim. |
| `unable` | any | `--body-file` (what failed) | Change 2: comments `Bailing out: unable to proceed.` with the body. Moves the card to `Needs Human` and releases the claim. |

The design-as-a-gate step from today's shared rules files a design issue, adds
the blocker and bails. Here it becomes `file-issue`, then `add-blocker`, then
`finish blocked --on <design>`, so no sequence lives in prose.

**What `finish` checks.** A first run checks everything below before writing
anything. A failed check writes nothing and answers `rejected`, with the
reason.
- the token's login is `gh api user`, still holds the claim, and claimed it at
  the token's time;
- the token's issue repository is `loop.json`'s `repository`;
- the outcome is one the token's role and task accept, which is the list the
  assignment printed as `outcomes`;
- `--pr` names a pull request that links the issue;
- each `--answering` URL is outstanding feedback;
- `blocked` names at least one open issue or pull request.

**A re-run checks only the claim.** A run is a re-run only when the issue or
pull request already carries this token's `finish` marker. Its own first run
then posted the comment, so the input checks were met when it mattered.
Repeating them would reject the run, because the `--answering` URLs it answered
are no longer outstanding. A re-run does only the writes still pending.

A card already in the outcome's column is not a sign of a re-run. A repair can
move a card while a tick holds it, and a first run that found it there would
otherwise skip its checks. `submitted` with nothing to post needs no marker: its
input checks still pass when it runs again.

**A write counts as done only when it is proven to be this operation's.** The
card's column, or the claim being gone, can't show who acted. So each write has
a proof, attributed to the token's login and later than the token's claim time:

| Write | Its proof |
|---|---|
| Comment | A comment carrying this token's `finish` marker |
| Move | A status-change event on the issue, by this login, to the outcome's column |
| Release | An `unassigned` event on the issue removing this login, by this login |
| Assign the owner, request review (`approved`) | The pull request's `assigned` and `review_requested` events, by this login |
| Close (`decomposed`) | A `closed` event on the design issue, by this login |

`finish` reads the proofs before writing. It does each write whose proof is
missing, in the outcome's order, and answers by these rules:

- **Every write proven: `finished`.** That includes the release, so `finished`
  always means this operation completed, not merely that the board looks as if
  it did.
- **The claim still held and some writes unproven:** it carries on with those
  writes, then answers `finished`, or `incomplete` if a write fails.
- **The claim gone without a proven release, or held by another login:**
  `refused`, writing nothing. Examples are the owner unassigning to take the
  card back, or a repair having moved it.
- **The card in any column but the one it was taken from, with no proven
  move:** `refused`, as a move refused by `--from` is today. That includes the
  outcome's own column: somebody else moved it, and `finish` doesn't adopt a
  move it can't attribute. As today, the comment stands or is still posted,
  since it is the work, and the claim is released while it is still this
  token's. Nothing else is written.
  The one move by somebody else that is not refused is the project's own
  automation taking a card from `Ready` into its work column when the pull
  request links: that is the engineer's ordinary pass, and the move it makes
  starts from there.
- **A proof the provider can't read**, such as an events endpoint that fails:
  `incomplete`, with `retry: true`. Never `finished`.

The GitHub provider reads these from the issue's and the pull request's
timelines, and a move from GraphQL's `ProjectV2ItemStatusChangedEvent`, which
carries the actor and both columns. The REST timeline's status change names no
column, so it is not read. Recorded timelines pin each kind.

The tests cover every row of that table, for each outcome. In each case the
write is done and proven, done by another actor, or not done, and the test
asserts the answer above.

`reply` works the same way. With its marker already present, it posts nothing
and answers done.

**What it answers:**

```json
{ "schema": 1, "kind": "finished", "issue": 7, "outcome": "submitted",
  "done": ["comment PR: example-org/tickwork#2", "move In Progress → Agent Review", "release"],
  "nextDelay": "now" }
```

```json
{ "schema": 1, "kind": "refused", "issue": 7, "stage": "move",
  "found": "Human Review",
  "done": ["comment PR: example-org/tickwork#2", "release"],
  "message": "the card moved under the tick; nothing was retried" }
```

```json
{ "schema": 1, "kind": "rejected", "issue": 7,
  "message": "--answering https://…#issuecomment-9 is not outstanding feedback on example-org/tickwork#2" }
```

A write that fails part-way, such as a 5xx between the comment and the move,
answers `incomplete`. Running the same `finish` again does what is still
pending and nothing it already did:

```json
{ "schema": 1, "kind": "incomplete", "issue": 7, "outcome": "changes-requested",
  "done": ["comment on example-org/tickwork#2"],
  "pending": ["move Agent Review → In Progress", "release"],
  "message": "HTTP 502 from the project's GraphQL endpoint", "retry": true }
```

### Markers

Every comment `finish` posts ends with one hidden line naming the outcome and
the token:

    <!-- tickwork:finish changes-requested tw1~agent-one~example-org/example~7~reviewer~review~Agent%20Review~2026-10-28T13:49:02Z -->

The marker comes last, so a bail-out still opens with `Bailing out:` and the
repairs read it as today. Two things read the marker:

- **`finish`, re-run:** a comment carrying this token's marker on that issue
  or pull request means the comment was already posted. This is exact,
  because the token names the claim. It doesn't depend on whether the comment
  is newer than the claim.
- **`next`:** the newest marked comment on a pull request says whose turn it
  is. `changes-requested` means the Reviewer's findings are outstanding, and
  `submitted` means they have been answered.

`reply` and the helper verbs mark their comments too, with their own verb in
place of `finish`.

## Concurrency, failure and recovery

- **Claims are unchanged.** The issue's assignee is the claim, taken by
  read–add–read-back, and `finish` refuses a token whose login no longer holds
  it. The only orchestrator still takes none.
- **Every write in `finish` checks first, so a second run finishes the first.**
  Before each write it looks for that write's proof (see the table under
  `finish`), attributed to this login since the claim. Re-running the same
  `finish` after a crash does only what is left, and a write another actor made
  is never taken as its own. The order is today's: comment, then move, then release. That
  order keeps an interrupted bail-out recognisable.
- **A refused move ends the tick as today.** Swift releases the claim, reports
  the column it found, and does not retry.
- **An interrupted tick is resumed, not guessed at.**
  - Its own claim comes back as the next assignment (change 1). If a pull
    request exists, the task is `assess-existing` or `address-findings`, so the
    agent judges the unfinished work.
  - Swift never advances an existing pull request by itself.
  - Another login's claim is passed over and named. After an hour it gets
    today's notice, never a reclaim.
- **Partial provider failures** inside `next` before the claim answer `error`
  with nothing changed. After the claim, `next` releases what it took before
  answering `error`.

## Provider seams

```swift
protocol BoardProvider {
    // Built with loop.json's `repository` and `project`: the issue repository and
    // its board. Every issue it creates, comments on or reads is in that repository.
    func snapshot(refresh: Bool) throws -> BoardSnapshot  // cards, columns, assignees
    func move(_ issue: Int, to column: String, from expected: String) throws -> MoveResult
    func claim(_ issue: Int, as login: String) throws -> ClaimResult
    func release(_ issue: Int, login: String) throws
    func comment(on issue: Int, body: String) throws
    func comments(on issue: Int) throws -> [ConversationComment]
    func createIssue(_ draft: IssueDraft) throws -> Int
    func blockers(of issue: Int) throws -> [Int]
    func addBlocker(_ blocker: Int, to issue: Int) throws
    func removeBlocker(_ blocker: Int, from issue: Int) throws
    func events(on issue: Int, since: Date) throws -> [IssueEvent]  // actor, kind, column
    func issues(createdBy login: String, since: Date) throws -> [IssueSummary]  // every state
    func budget() throws -> Budget
}

protocol SourceControl {
    func pullRequests(linking issue: Int) throws -> [LinkedPullRequest]
    func mergeFacts(_ pr: PullRequestID) throws -> MergeFacts
    func checks(_ pr: PullRequestID, head: String) throws -> CheckFacts
    func unansweredFeedback(_ pr: PullRequestID, head: String) throws -> [OwnerFeedback]
    func authors(_ pr: PullRequestID) throws -> Set<String>
    func comment(on pr: PullRequestID, body: String) throws
    func requestReview(_ pr: PullRequestID, from login: String) throws
    func events(on pr: PullRequestID, since: Date) throws -> [PullRequestEvent]
    func merge(squash pr: PullRequestID) throws
}
```

- **The issue repository and the source repository stay apart.** `BoardProvider`
  never takes a repository argument, so it can't be pointed at a pull
  request's. `SourceControl` always takes one, inside `PullRequestID`. A test
  arranges an issue in one repository and its pull request in another, and
  asserts that `file-issue`, `decompose` and every issue comment land in the
  first.
- **One implementation of each:** GitHub Projects with `gh`, and GitHub.
  There's no plugin loader and no second provider. The seams are there so the
  tests can use fakes, and so a Jira board would be a new `BoardProvider` and
  nothing else.
- **Policy above the seams reads `loop.json`.** That covers the column and
  label names, the orchestrator, the owner and `mainRedLabels`. It is one
  shared engine, not one per repository.
- **Fixture work extends here.** A consumer with different column or label
  names says so in `loop.json`. A capability it needs becomes a Swift verb, and
  a different transition would be a Swift change, made when a real need shows
  up. This design adds no fixture-specific configuration.

## What happens to the instructions

| Today | Lines | Goes to |
|---|---|---|
| `next-task.md`: contract, one-revision rule, the board | 75 | Kept, cut to 15 lines of rule, no history |
| Step 0: roles and `loop.json` | 35 | Swift (`next`) |
| Step 1: repairs and their reasoning | 690 | Swift already implements them. The reasoning moves to `docs/repairs.md`. |
| Step 2: selection, skips, authorship | 155 | Swift (`select`). Its reasoning moves to `docs/loop.md`. |
| Step 3: claim and re-validate | 55 | Swift (`next`) |
| Shared rules: never wait for CI, branch names, stage by name, plain-prose commits, write for the owner, gaps | 75 | Kept as judgment, cut to about 40 lines |
| Shared rules: `--from`, refused moves, bail-out markers and order, `Blocked-on:` | 77 | Swift (`finish`) |
| A consumer gate's park-behind-a-design sequence (in the consumer's `AGENTS.md`) | n/a | `file-issue`, `add-blocker` and `finish blocked`, which the consumer's text can name instead of spelling out steps |
| `engineer.md` | 175 | About 80. Kept: how to build, the local bar, the PR body, decomposition judgment. Gone: column moves, `PR:` and `Answering` mechanics. |
| `designer.md` | 112 | About 60. Kept: decision, not survey; findings as conversation. Gone: column moves and markers. |
| `reviewer.md` | 93 | About 60. Kept: read the issue first, what a finding is, saying what was checked, disclosing own work. Gone: authorship arithmetic and moves. |

The new `next-task.md`, in full outline:

1. Run `sh <tool> next`. On `idle` or `error`, report and stop.
2. Read `AGENTS.md`, then `sh <tool> instructions <role>`.
3. Do the `task`, using the helper verbs for issues, blockers and replies.
4. Run `sh <tool> finish --token … <outcome>`, and report what it answered.
5. The judgment rules every role shares.

The report keeps the revision, the budget, the skips and the `nextDelay`, all
copied from the JSON.

## Migration

Each step is one pull request. Behaviour is the same at every step, apart from
the three changes below, which land only if approved.

1. **Seams.** Move `GitHub.run` callers behind `BoardProvider` and
   `SourceControl`, and add fakes. No change in behaviour. The existing suite
   passes untouched.
2. **`select`, as a pure function.** One test per row of step 2's table and
   per skip: epic, blockers, checks still running, each authorship branch, and
   `Ready` by role. A parity test runs `select` and the current prose's choice
   over recorded board fixtures and requires the same pick.
3. **`next`**: load, repairs, select, claim, re-validate, assignment JSON, and
   `next --preview`. Preview reads the board and the facts selection needs, and
   prints `"kind": "preview"` with the item, role, task and skips it would
   choose. It runs no repairs, takes no claim and writes nothing, so it is safe
   to run beside the live loop. The instructions don't call `next` yet. Parity
   is checked inside a prose tick, after its repairs and before its claim:
   `next --preview` runs at that point, and its choice is compared with the
   one the prose then makes. Running it before the repairs would compare
   against a board the repairs are about to change. Every tick that moved a
   card would show a mismatch that isn't one, and file it. A real mismatch is
   filed. The claiming `next` is first used live at the cut-over.
4. **`finish` and the helper verbs.** Tests assert the exact comment text and
   write order today's prose produces for each outcome, plus re-run after a
   failure at each write.
5. **Cut-over.** Rewrite the instructions and move rationale into `docs/`, in
   one pull request, so no tick runs half of each.
6. **`workflow` in `loop.json`** (change 3). It is additive: today's names are
   the defaults, so existing files keep working. `check-loop` learns the new
   key in the same pull request.

## Changes for the owner

1. **A tick picks its own interrupted claim back up**, and **one login runs one
   session at a time** becomes an invariant you sign off on with it. Today, a
   card claimed by a tick that died sits until an hour passes and a notice asks
   a person. With this change, the same login's next `next` returns it as
   `resumed`, and the agent assesses the work through the task. Other logins'
   claims stay as today.
   - **Why it needs the invariant:** resuming is safe only if the claimant's
     next tick can't be racing a session that is still working the claim.
     `loop.json` already lists one entry per login, so the invariant is
     written into the file's meaning rather than enforced. A person running
     `/next-task` by hand beside a running loop must use another login, or
     stop the loop first. `docs/loop.md` will say so.
   - **Rejecting it** keeps the hour-and-notice path for every claim.
2. **`unable` is a new outcome**, for a tick that can't continue for a reason
   that isn't a product question, such as a denied permission or a broken
   environment. It bails to `Needs Human` with that reason. Today there is no
   such outcome: a tick either bails with a question or releases the claim and
   leaves the card, and the card then comes straight back.
   - **Rejecting it** removes the outcome, and such ticks use `needs-human`.
3. **Column and label names in `loop.json`.** This adds an optional `workflow`
   object, shown here with today's values, which are also its defaults:

   ```json
   "workflow": {
     "columns": {
       "backlog": "Backlog",
       "ready": "Ready",
       "design": "In Design",
       "work": "In Progress",
       "review": "Agent Review",
       "ownerReview": "Human Review",
       "parked": "Needs Human",
       "done": "Done"
     },
     "labels": { "design": "type:design", "epic": "epic" }
   }
   ```

   The transitions themselves stay in Swift, written against these names:

   | Outcome | Goes to |
   |---|---|
   | `submitted` | `review` |
   | `approved` | `ownerReview` |
   | `changes-requested` | `design` for the `design` label, `work` otherwise |
   | `blocked`, `needs-human`, `unable` | `parked` |

   The repairs and the board's display use the same names. `check-loop` refuses
   an unknown key without reaching GitHub, and `next` refuses a column the board
   doesn't have. Any key left out keeps its default.
   - **Why only names:** another consumer's board, or another provider, can
     use its own column and label names without any change to the
     instructions. Configurable transitions would be the generic framework the
     issue warns against, built for a need nobody has yet.
   - **Rejecting it** keeps the names as constants in Swift. That is still
     outside the instructions, but the same for every consumer.

## Not here

- Fixture-specific workflow, which waits for its own design.
- A second board provider.
- Running the agent from Swift. The agent session still drives the tick.
- Any change to how a tick's revision is chosen.
