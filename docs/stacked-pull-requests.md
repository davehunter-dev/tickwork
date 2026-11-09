# Stacked pull requests

**TLDR.** An issue labelled as stackable may start while its one open blocker
waits for the owner. It branches from the blocker's pull request and targets
that branch, so each diff holds only its own work, and a sequential epic can be
finished overnight while its first pull request waits for review. Stacks can be
any length.

Tickwork's part is coordination and the merge guard. It chooses stacked work,
notices when a child's parent has moved or merged, and sends the child back to
its Engineer with a `restack` finding naming the new base. The Engineer works
out which commits are its own, rebases them, resolves conflicts and says what
it did. `Agent Review` checks that the diff holds only the issue's work. That is
Git reasoning an agent with a checkout does better than the orchestrator, and
the previous draft spent most of its length on it: the force-push history,
event queries, state table and ancestry proofs are gone.

The merge guard stays in code and holds only structural invariants. A pull
request merges only **into `main`**, only if it **contains the merge of every
former parent that merged**, and is held while a former parent is still open.
Beyond that it merges as any pull request does: green required checks and
whatever approval the repository's own ruleset asks for. **A restack adds no
approval of its own.** Its correctness rests on the Engineer's evidence and on
`Agent Review`, which every restacked child passes again before any merge path
can act on it. Either of them escalates to `Needs Human` when it can't establish
that the restack is right, or finds that it changed the child's scope.

| Area | Share | What makes it cost more than it looks |
|---|---|---|
| The restack repair and its finding | 30% | GitHub computes `mergeable` against the base, so for a stacked pull request the conflict and behind reasons give way to two parent reads, and `engineer.md` gains the restack procedure. |
| The merge guard | 25% | `main`'s ruleset doesn't cover a pull request into a feature branch, and former bases are only in GraphQL's timeline, in `BaseRefChangedEvent` and `AutomaticBaseChangeSucceededEvent`, the `SourceControl` contract's one exception here. |
| Choosing and starting stacked work | 25% | A second selection pass, the walk from the parent to `main` with cycle and break detection, and `finish`'s base check. |
| Opting in | 10% | `check-loop` reads `delete_branch_on_merge` beside the label check, and `decompose` copies the label. |
| `Agent Review` and the docs | 10% | `reviewer.md` gains the check that a stacked or once-stacked diff holds none of a parent's work, and the escalation rule below. |

**Challenging the table:**

- **The guard's containment read** could go. A child retargeted to `main`
  before it is restacked would then rest on a reviewer noticing the parent's
  work in its diff. One compare per former parent, paid only at merge, makes
  that structural, so it stays.
- **The cycle walk** could go, trusting the repairs to break a bad stack. You
  asked for cycle and break detection. It costs one REST read per level, paid
  only when the second pass runs, so it stays.
- **`delete_branch_on_merge` off** could be dropped if the repairs looked for
  former parents on every pull request into `main` each pass. That is a GraphQL
  read per pull request per pass, set against one repository setting. The
  setting stays.

## Departures from what you asked for

These change earlier review requests. They come first because they're yours to
accept.

- **The guard no longer proves that a child carries no earlier version of its
  parent's commits** (the 13:50 review, point 3). The previous draft's proof
  covered only commits replayed under their original shas. A commit rebased onto
  `main` gets a new sha and passed that guard too, so it was also relying on the
  Engineer and the reviewer. An earlier parent commit, rewritten or not, shows in
  the child's diff against `main`, and `Agent Review` is asked explicitly to look
  for it, with `git range-diff` against the former parent. The structural part
  that remains is that a child contains its merged parent, so it was rebuilt on
  top of what landed.
- **No approval test for a once-stacked pull request** (the two 19:06 reviews).
  The previous revision held one until its approval was on its current head and
  newer than its last retarget. That made every routine restack cost a human
  reapproval. It is gone: the restacked diff is checked by `Agent Review`, and
  any approval the owner gave earlier counts exactly as the repository's ruleset
  says, so a ruleset that dismisses stale approvals still asks for a new one.
  With `review.agentApproval` set, a restacked child can land on an agent's
  review alone where the ruleset allows it. That is the trade you asked for, and
  it is the same trust `agentApproval` already gives any pull request.
- **The unresolved-history recovery (points 1 and 2) is no longer the
  orchestrator's.** Tickwork derives no boundary, so it has no history to fail
  on. The Engineer has its reflog, the parent's force-push events through
  `gh api`, `range-diff` and `cherry`. It finishes `needs-human` only when it
  can't tell its own commits from the parent's, can't resolve a conflict with
  confidence, or finds the restack changes the child's scope.
- **Your open question about an abandoned parent goes away.** A former parent
  that closed without merging doesn't hold the guard, so a child whose parent
  was abandoned merges like any other: restacked onto `main` and reviewed. If
  that parent is reopened, it holds the child again.
- **Dropped:** the blocker-closer containment test, `finish`'s check for an open
  blocker's commits in a pull request into `main`, the guard's merge-commit test,
  and the races `finish` handled. Each covered an Engineer mistake that
  `Agent Review` sees in the diff. A race is a stale child that the next repair
  pass sends back.

## The model

`main → A → B → C`. A's pull request targets `main`, B's targets A's branch, and
C's targets B's branch.

A pull request is **stacked** when its base isn't `main`. Its **parent** is the
pull request whose head branch is that base: the one open pull request from it,
or, once that has merged, the branch's only pull request, merged into `main`.
Any other history from the branch leaves the parent unknown.

A parent is **settled** when its card is in `Human Review` with no claim, its
pull request is not a draft, and its checks are green as `finish` already
judges them: nothing failing, nothing waiting for a person, nothing unfinished,
and at least one check run. The consumer must run CI on pull requests into any
branch.

## Opting in

`loop.json` gets an optional key:

```json
"stack": { "label": "stackable" }
```

It gates **starting** stacked work and nothing else: selection's second pass,
the assignment's `stack` field, `decompose`'s label copy, and `check-loop`'s
checks that the label exists and `delete_branch_on_merge` is off. The restack
repair and the merge guard key on the pull requests, so turning `stack` off
stops new stacks and lets open ones finish.

- **The label belongs to the downstream issue.** It makes the issue eligible
  to start before its blocker is approved. It doesn't raise its priority.
- **`decompose` propagates it.** When the issue being decomposed has the label,
  every task it files gets it too. Labelling an epic's design issue is how an
  epic asks for stacked work.

## Choosing stacked work

`select` checks `Ready` twice. The first pass is today's. **The second pass runs
only when the first found nothing for this tick's roles.** It goes through
`Ready` again in board order and takes the first labelled item where:

1. **Exactly one blocker is open, as a `blockedBy` relation.** That blocker is
   the parent issue, P. Two open blockers would need a merge of two branches.
2. **P's pull request is settled.**
3. **P's stack reaches `main`.** Following bases from P's pull request, each
   base is the head of one open pull request, until one targets `main`. A branch
   seen twice is a cycle. A missing, closed or duplicated pull request is a
   break.

A skip names the condition that failed, such as `not stackable: #41 is in
Agent Review` or `#41's stack loops at f/39-…`. The assignment has `task:
start` and `stack: {parent, pullRequest, branch, head}`.

## Opening a stacked pull request

The Engineer branches from `head`, does the work, passes the local bar, and runs
`gh pr create --base <branch>`. The body opens `Closes #N.` and says the pull
request merges after its parent.

`finish submitted` for a stacked start checks one thing: **the pull request's
base is the assignment's `branch`.** That stops a stacked start opened against
`main` while the parent is open, which nothing else would catch. Anything else
that moved during the tick, such as the parent settling or merging, is caught
by the next repair pass.

If the work belongs in another repository from its parent's, it can't stack.
The Engineer finishes `blocked --on <P>`.

## Keeping a stack current

For a stacked pull request in `Agent Review` or `Human Review`, and in
`Next.findings` for `In Progress`, the **restack repair replaces the conflict
and behind reasons.** Those compare the child with its base, so they fire
whenever the parent force-pushes, and their fix, `git rebase origin/main`, would
pull the parent's commits into the child's diff. It makes two REST reads, the
parent from `pulls?head=<owner>:<base>&state=all` and `compare/<parentHead>...
<childHead>`, and acts on what it sees:

| Parent | Action |
|---|---|
| open, not settled | nothing; the child waits |
| open, settled, its head in the child | nothing |
| open, settled, its head not in the child | send back with `restack`, `onto` the parent's head |
| none open, and the branch's only pull request merged into `main` | send back with `restack`, `onto` `main`, retarget |
| anything else | send back with `stack-broken`, naming what was seen |

"Send back" is today's move by issue type. The repair never pushes and never
writes a bail-out. While the parent is reworked its head is unreviewed and may
be red, so the child moves once, when the parent settles. **Changes cascade one
level at a time:** restacking B pushes B, and C is sent back once B settles
again.

**The Engineer's restack**, added to `engineer.md`:

1. Identify the child's own commits, the ones made for its issue. Usually that
   is everything above the parent head the child was built on, which
   `git merge-base` gives while the parent only fast-forwards. After a
   force-push or a squash merge, find that head in the reflog of
   `origin/<parent>`, the parent's `HeadRefForcePushedEvent`s, or with
   `git range-diff` and `git cherry` against `onto`.
2. `git rebase --onto <onto> <boundary>`, resolve conflicts as for any rebase,
   pass the local bar, `git push --force-with-lease`, and
   `gh pr edit <N> --base main` when the finding says to retarget.
3. Verify the result: the diff against `onto` holds only the issue's work, and
   `git range-diff` of the old and new commits shows no change beyond the
   conflict resolutions. Comment the boundary taken, that evidence and any
   conflict resolved, so `Agent Review` can check it.
4. Finish `needs-human` if it can't separate its commits from the parent's, if
   a conflict can't be resolved with confidence, or if the restack changes
   what the child does beyond its approved scope, such as when the parent's
   change invalidates it.

The same rule covers a conflict or behind finding on a pull request into `main`
that was once stacked, which the Engineer sees in its timeline. It rebases only
its own commits. It never fixes a stacked branch with a merge commit.

**`stack-broken`.** If the parent closed without merging and its issue is
closed, the work it held was dropped or replaced, so the Engineer restacks onto
`main` without it and retargets. If its issue is still open, whether to wait for
a replacement, drop the parent's work or close the child is the owner's call:
finish `needs-human` with the facts and those options. Anything else, such as
two open pull requests from the base, is reported the same way.

## Merging

`main`'s ruleset doesn't apply to a pull request into a feature branch. The
`MERGE` repair, auto-merge in `finish approved` and the agent-approval path act
only on a pull request that passes the **merge guard**:

1. **Its base is `main`.**
2. **No former parent is open, and every one that merged is contained.** A
   former parent is the pull request from a branch it was based on before a
   retarget, by hand, by Tickwork, or by GitHub when it deleted that branch.
   "Contained" is `behind_by` 0 in `compare/<mergeCommit>...<head>`. A
   former parent closed without merging is ignored: its work was dropped,
   and anything of it the child still carries is in the child's diff, which
   `Agent Review` checks.

Everything else is today's merge: `clean` from GitHub, which covers required
checks and the ruleset's approvals, on a card that has passed `Agent Review`.
The guard asks for no approval of its own.

The reads: one GraphQL query for the pull request's base changes, which name
each former base. Two timeline events record one: `BaseRefChangedEvent`
(`previousRefName`) for a retarget by hand or by Tickwork, and
`AutomaticBaseChangeSucceededEvent` (`oldBase`) for the retarget GitHub makes
itself when a merged parent's branch is deleted. The query asks for both item
types, so it still costs one query, refused below `readReserve`. Then one
`pulls?head=` per former base and one compare per merged one. A pull request
with neither event has nothing for test 2 to check, so after the query it merges
exactly as today.

**Refusals.** A merged former parent that isn't contained, which happens after a
hand retarget or a deleted branch, sends the card back with `restack` onto
`main`. An open former parent holds the card with
`REPORT #N PR <ref> is held: <reason>` and nothing is sent back; the parent's
merge brings the restack.

**Why this is enough.** Before a child's parent merges, the child's base isn't
`main` (test 1), or it was retargeted early and its open former parent holds it
(test 2), so a child can't land before its parent. After the parent merges, the
child is built on that merge (test 2), so CI saw it on top of what landed. Every
restack sends the card back to its Engineer, so the restacked head passes
`Agent Review` before any merge path can act on it. Whatever the child carries
beyond its own work, including an earlier version of its parent's commits or the
work of an abandoned parent, is in the diff that review checks.

**When `Agent Review` can't confirm a restack.** The reviewer requests changes
for a defect it can name, such as a parent commit in the diff, because the
Engineer can fix that. It finishes `needs-human` when it can't establish that
the restack is right, or finds that the restack changed the child's scope.
Sending an unconfirmable restack back to the Engineer would only repeat it, so
either agent's doubt is enough to reach the owner; both don't have to fail.

## Walkthrough: `main → A → B → C`

B and C are labelled. B is blocked by A, and C by B.

1. A settles in `Human Review`. `Ready` has nothing unblocked, so the second
   pass takes B, with parent A. B branches from A's head `a1`, targets A's
   branch, and settles. C stacks on B the same way.
2. The owner asks for changes on A. B and C wait. A settles at `a2`, which isn't
   in B, so B gets `restack onto a2`. Its Engineer runs
   `git rebase --onto a2 a1`, and B settles at `b2`. C then gets
   `restack onto b2`.
3. The owner approves A, which squash-merges as `m1`. B gets `restack onto main`
   with a retarget. Its Engineer takes A's final head as the boundary, rebases,
   retargets and comments its evidence. `Agent Review` checks that B's diff
   against `main` has none of A's work and returns it to `Human Review`. B
   contains `m1`, so it passes the guard. If the owner approved B before the
   restack and the ruleset keeps that approval, B merges without another.
4. B's restack moved it, so C restacks onto it, and later onto `main` after B
   merges, in the same way.

With n pull requests in a stack, landing all of them costs n(n−1)/2 restacks,
and each rework adds one per level below it. Nothing in GitHub or these rules
needs a depth limit.

## Exceptional states

| State | Handling |
|---|---|
| The restack conflicts, or the parent's change invalidates the child | The Engineer resolves it with confidence, or finishes `needs-human` |
| `Agent Review` finds a parent's work in the restacked diff | Changes requested, naming it |
| `Agent Review` can't establish the restack is right, or its scope moved | `needs-human` with what it checked |
| The Engineer can't tell its commits from the parent's | `needs-human` with what it found |
| The parent settles or merges during the child's tick | The next repair pass sends the child back |
| Two open blockers, or a loop or break further up | Not stackable, and the skip names it |
| The label is removed, or `stack` turned off, mid-stack | Only starting stops |
| The owner merges a parent by hand | The child is restacked onto `main`, as usual |
| Somebody retargets a child to `main` early | The guard holds it until the parent merges, then sends it back |
| Somebody deletes a merged parent's branch | GitHub retargets the child, and the guard sends it back for a restack |
| The parent closes without merging | `stack-broken`; once the child is retargeted, the closed parent doesn't hold it |
| The owner approved the child before its restack | The approval counts as the ruleset says; the restack passes `Agent Review` first |

## What changes

In Tickwork, in this order, so the guard lands before anything can create a
stacked pull request:

1. **The merge guard**, with the base-change query over both event types,
   its `REPORT` and its send-back. It isn't gated by `stack`. `reviewer.md`'s
   check for a once-stacked diff ships with it.
2. **`stack` in `loop.json`**, `check-loop`'s two checks and `decompose`'s label
   copy.
3. **The restack repair** in `Repairs` and `Next.findings`, the `restack` and
   `stack-broken` findings in `workTask`, and `engineer.md`'s restack procedure.
4. **Selection's second pass**, the stack walk, the assignment's `stack` field
   and `finish`'s base check, with `engineer.md`'s section for starting stacked
   work, `docs/loop.md` and `docs/repairs.md`.

In the consumer, after step 4: run CI on pull requests into any branch, add
`"stack": {"label": "stackable"}` to `loop.json`, and create the label.

## Alternatives

- **The orchestrator derives the boundary from the parent's force-push
  history**, as the previous draft did. It is exact when GitHub still has every
  tip, and when it doesn't it needs the Engineer's recovery anyway. It brought a
  second GraphQL exception, per-stretch compares, an unresolved state and a
  state table. That is roughly half the implementation spent on judgment the
  Engineer already has, and the guard still couldn't see rewritten commits.
- **A structural guard against every parent commit** (the left-behind,
  closer and merge-commit tests). It proves absence only for commits under their
  original shas, at the cost of the derivation. `Agent Review` covers both
  kinds, in the diff.
- **Require an approval on the current head, newer than the last retarget**, as
  the previous revision did. It made a routine restack cost a human reapproval
  that the repository's own policy doesn't ask for. A ruleset that wants it can
  dismiss stale approvals.
- **A `Stacked-on:` line in the body.** A second, hand-written record of a sha
  GitHub and the Engineer's reflog already hold. It goes stale on the first
  restack that doesn't edit it.
- **The orchestrator rebases.** A rebase can conflict, and that needs the
  branch's owner.
- **Merge parents with a merge commit.** Children would only need retargeting,
  but review-fix commits would land on `main`. You chose squash.
- **A depth limit.** It would leave valid work undone to bound agent work you
  have chosen to spend.
- **An external stack tool** (`gh-stack`, Graphite, git-town). A second owner
  for branch state beside the board.
- **Interleave stacked work by board priority.** The issue asks for stacked work
  only once unblocked work has run out.
