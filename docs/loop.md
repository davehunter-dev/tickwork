# Running a backlog as an agent loop

Tickwork runs a project's backlog as an unattended agent loop over a GitHub
Projects board. Each tick reads the board, takes one role, does one thing, and
reports it. The policy is `instructions/next-task.md` and the three role files
beside it, which say how to judge; `next`, `finish` and the other verbs of the
`board` tool do the mechanics; and a project runs both through
the one-line skill in `skills/next-task/`, over a Tickwork each account
installs once.

**Tickwork says how agents work. The consuming project says what they do**, in
two places it owns: `loop.json` at its root, and the `## Agent loop` section of
its `AGENTS.md`, which holds the local bar a change must pass, the formatter,
and any gate of the project's own. Nothing in Tickwork names a project.

A tick does and resumes its item in the checkout it runs in, not a Git worktree,
unless the project allows worktrees in its `## Agent loop` section: a branch
held by a worktree can't be checked out by the tick that resumes it.
Subagents' worktree isolation is left to Claude Code.

In the instructions and below, `sh <tool>` is the path `tickwork next-task`
printed at the top of the tick, and `<repository>` and `<owner>` are `loop.json`'s
`repository` and `owner`.

## The board is the state

Work lives on a GitHub Projects board, and an issue's column says which
role owns it and what happens to it next. Position within a column is priority,
set by hand, so the topmost item is the next one — there is no milestone or
issue-number tiebreak to go stale.

    sh <tool> working

The tick's tool is the loop's whole vocabulary for the board: `working`,
`show`, `list`, `head`, `count`, `status`, `blockers`, and `move`. Columns resolve by
name on every call rather than being baked in as GraphQL node IDs, so renaming
one in the UI fails loudly instead of quietly filing work in the wrong place.

This replaced a label-based model, and the reason is worth remembering. The
`blocked` and `needs-human` labels were maintained by hand and went stale the
moment a pull request merged: by the time they were retired, `blocked` was
sitting on seven of the nine issues that were actually ready to work. Readiness
has one record, and it is the column.

### Being ready and being unblocked are different questions

`Ready` is the owner's judgement that the work is understood and wanted. It is
not a claim that the work can start today, because the owner sets it once and
the world moves afterwards: an issue is ready the moment it is triaged and stays
blocked until whatever it builds on has merged.

So the loop asks a second question before it takes anything, and
`blockers <N>` answers it — the issues GitHub records as blocking it
that have not closed. An item with any is skipped and the next one down is taken.

This is not the `blocked` label coming back. That label was a hand-kept copy of
a fact that lived elsewhere, which is why it rotted: nothing updated it when the
pull request it was waiting for merged. A dependency link is the fact itself.
GitHub maintains it, it carries the blocker's state, and it stops holding the
issue the moment the blocker closes, with nobody remembering to do anything.

Without it the failure is quiet rather than loud. The loop would take an issue
whose groundwork is not on `main`, branch from `main`, and find the thing it was
told to build on missing — leaving it to either build on an unmerged branch or
bail, having spent a tick to learn something the board already knew.

### The columns

| Column | Meaning |
|---|---|
| `Backlog` | Untriaged. Not reviewed, not available. The loop never takes from here. |
| `Ready` | The owner has reviewed it and it is good to go. |
| `In Design` | The Designer is resolving it into a decision. |
| `In Progress` | The Engineer is working it. |
| `Agent Review` | An open PR with nothing yet known to be wrong. The Reviewer's inbox. |
| `Human Review` | Reviewed and clean. Waiting on the owner and nobody else. |
| `Needs Human` | Blocked on something the loop cannot resolve. Two things live here: what the loop parked, and work the owner dragged out of its reach. Only the first comes back on its own — see below. |
| `Done` | The issue closed. The loop never reads it, so it can grow; the owner may still clear it by hand to keep the board readable. |

`Backlog → Ready` is the owner's gate and the loop's only hard constraint on
what it may work. Everything the loop generates — the tasks written from a
merged design, the gaps found mid-implementation — lands in `Backlog`, so the
loop can create work but cannot authorise it. `file-issue` and `decompose` put
the issue there themselves, adding it to the board and setting its column,
rather than trusting the project's add workflow. A board may send every new
issue to a column the loop doesn't read, such as an intake column where the
owner admits what others file, and the loop's own issues still land in
`Backlog`. Run again, either verb leaves alone an issue already in a column the
loop names, so a retry never undoes a move made since.

`Human Review` means the ball is in the owner's court, and it holds as much as
it holds. The loop used to stop pulling from `Ready` while three items sat
there; it does not now, because a loop run overnight that stops at three spends
the rest of the night idle, and a pile of pull requests in the morning is the
point of running it.

## The three roles

Split by kind of work, not by column. The column is where that work usually
shows up, which is not the same thing.

| Role | Produces | Never |
|---|---|---|
| Designer | Decisions, as documents under `docs/` | Writes code |
| Engineer | Code changes, and work items from merged designs | Redesigns; merges |
| Reviewer | Findings | Edits anything |

Findings look alike whatever their source — a failing check, a Reviewer's
verdict, the owner's review comment — and they are routed by what they are
about rather than by who raised them. A finding about code goes to the
Engineer; a finding about a design document goes to the Designer, because a
flawed decision is not fixed by editing the file it was written in.

That is also why fixing red CI is Engineer work and not Reviewer work: it is a
code change, and the Reviewer does not make code changes. A pull request that
has stopped merging cleanly is the same kind of thing again — durable state
that no amount of review will improve — so it goes back the same way.

**Roles are an argument to the tick rather than a property of an agent.**
`/next-task [role...]` takes any of `orchestrator`, `reviewer`, `engineer` and
`designer`, and `/next-task` alone means all four — one agent taking whichever
role the board calls for, which is what a single agent does. A role the tick was
not given is a column it passes over as though empty; `Ready` is shared by two
of them, so it is skipped down instead — a designer-only tick takes the first
`type:design` item, an engineer-only tick the first that is not.

`orchestrator` is the fourth name and not a fourth role: it owns the repair step
rather than a column, has no role file, and appears in no table here. `docs/repairs.md`
says why the repairs are one agent's rather than
everyone's, and the consumer's `loop.json` says which account holds what.

**A reviewer tick passes over a pull request its own agent has written part
of**, so `Agent Review` is not always this tick's column even when it holds the
role and the column has something in it. The exception is that there may be
nobody else: when every listed reviewer has touched the branch, the tick reviews
it and says so rather than leaving the card where nobody can take it.
"How `next` chooses a tick's item", below, has the reasoning and what it costs.

### How work moves

| From → To | Trigger | Who |
|---|---|---|
| `Backlog → Ready` | Triage | The owner, only |
| `Ready → In Design` | Topmost `Ready` item, `type:design` | Designer |
| `Ready → In Progress` | Topmost `Ready` item, anything else | Engineer |
| `→ Agent Review` | PR opened, and on that pass `PR: #N` commented on the issue | Designer / Engineer |
| `Agent Review → In Design`/`In Progress` | Reviewer has findings | Reviewer |
| `Ready`/`In Progress → Needs Human` | Work that fails one of the project's gates; it waits behind what the gate asks for, and the bail-out carries `Blocked-on:` | Engineer |
| `Agent Review → Human Review` | Reviewer passes it, and assigns the PR to the owner and requests their review | Reviewer |
| `Human Review → In Progress` | CI goes red | Orchestrator |
| `Agent Review`/`Human Review → In Progress`/`In Design` | The PR conflicts with `main`, or is behind it where that blocks merging, by issue type | Orchestrator |
| `Human Review → In Progress`/`In Design` | Owner's comments, by issue type | Orchestrator |
| `Human Review → In Progress` | Design PR merged, decomposition owed | Orchestrator |
| the PR merges | GitHub reports it `clean`, which needs the owner's approval | Orchestrator |
| `Needs Human → In Progress`/`In Design` | The loop's newest comment is a bail-out and the owner has answered it, by issue type; the repair moves the card and then comments `Answer received:` | Orchestrator |
| `Needs Human → In Progress`/`In Design` | The loop's newest comment is a bail-out carrying `Blocked-on: #N` and every reference has landed, by issue type; the repair moves the card and then comments `Blocker cleared:` | Orchestrator |
| claim removed in `Needs Human` | An agent's claim on a card in that column | Orchestrator |
| a notice on the issue | A claim taken more than an hour ago | Orchestrator |
| `→ Done` | Issue closes | Built-in project workflow |
| off the board | Owner clears `Done` by hand, when they like | Owner |
| `→ Needs Human` | Ambiguity only the owner can resolve | Any role |

### Claiming, and why a claim is not enough

Work in flight is claimed by assigning the issue on GitHub, which is why the
claim is arbitrated where every agent can already see it rather than in
something the loop invented. `claim <issue>` holds the whole
protocol — read the assignee, refuse if anybody is there, add `@me`, read back —
because `--add-assignee` adds rather than refuses, so two agents reading the same
empty list can each land a name and neither call fails. The read back settles it,
first come.

A tick claims **last**, after the column, the role, the blockers and the design
check have all agreed, and releases the moment the item stops being its own — on
the move, on a refused move, on a bail-out, and on the spot when an item is
claimed and then abandoned. Every column belongs to a role, so a claim left on a
card handed to another role is a card that role will never take.

Any assignee is a claim, the owner's included: **assigning yourself takes an
issue off the loop without moving its card.** A tick that passes over an item
always names the login holding it, so this is visible rather than silent.

A claim is not a fresh board, and the two guards that follow from that are the
reason `--refresh` and `--from` exist. Having claimed, a tick refetches with
`--refresh status <issue>` and checks the item is still what it
was; and every `move` passes `--from <expected>`, which refuses rather than
overwriting when the card is not where the caller thought. A role whose move is
refused releases its claim, reports the refusal and the column it found, and
stops — keeping what it already made, since the pull request is on the issue and
the findings are on the pull request. A refused repair is reported and the rest
of the repairs still run.

A claim outlives an agent killed mid-tick, and clearing that one is a person
removing the assignee — which is why the orchestrator reports a claim older than
an hour as a comment on the issue, and strips an agent's claim outright in
`Needs Human`, where a notice on top of a bail-out would silence the owner's
answer permanently.

### The API budget, and why the board is what runs out first

REST and GraphQL have separate hourly budgets of 5,000 each. Projects v2 has no
REST API, so the board verbs are entirely GraphQL — which means the board is the first
thing to stop working when that budget goes, and it stops in the worst way: the
loop can read an item and then fail to move it, leaving finished work in the
column it started in.

That has happened. A tick opened a pull request for an item, could not move the card,
and the item sat in `Ready` with the work already done — where the next tick would
have taken it and done it again.

The cost is not where it looks. GraphQL bills in points rather than requests, and
the numbers are lopsided: reading a pull request's checks is one point, and
reading the board is two hundred and four. A tick reads the board several times,
so it spent six to ten hundred points before doing anything — five to eight ticks
an hour, against a sixty-second interval.

**Only the columns the loop names are read, Done excepted.** The item list asks
GitHub for those columns alone (`--query status:...`), and GitHub filters before
it applies the hundred-card limit, so finished work and columns somebody keeps for
themselves never count against it. A card in one of those is, to the tool, in no
column it reads: `status` says so, `move` refuses it, and `list`, `head` and
`count` refuse such a column rather than answer none. Moving a card *into* Done
still works, since the column comes from the field list.

So the board is read once per tick and kept. The two halves are cached
differently because they are not alike. The **field list** — column names and
their option ids — changes only when someone renames a column, so it is held for
a day; a stale one is caught by `require_column` failing loudly rather than
filing work somewhere wrong. The **item list** is the board and it moves, so it is
held only as long as a tick plausibly runs, and `working` and `show` always
refetch it. Every tick opens with `working`, which is why that needs no rule: a
tick cannot reason about a board an earlier tick saw.

**A refresh within ten seconds of the last fetch reuses it**, so a tick that asks
again costs one fetch rather than one per call. A refresh per column once
drained the budget until moves failed. **Below a reserve of the
hourly GraphQL budget, the reads refuse** and name what is left, so the reads
cannot starve the moves and claims that spend from the same budget.

Within a tick the only thing moving cards is the tick, so `move` writes its own
change through to the cached copy instead of refetching to learn what it just did.

Two smaller things follow, worth doing and worth not mistaking for the fix — they
are about seventeen points a tick between them. Anything REST can answer is read
over REST, which is checks and mergeability. And no role waits for CI: not for
the budget, but because a tick that polls blocks for minutes doing nothing while
hand-rolling a check the orchestrator makes at the top of every one of its ticks
anyway. The
consequence is that items sit in `Agent Review` with checks still running, so the
dispatcher skips them and takes the next case — often starting something new.
Doing other work and coming back is the shape the loop already had; waiting was
the part that never fitted it.

### Getting from an issue to its pull request

The owner works from issues; the loop works from pull requests. GitHub does link
the two, but only in the issue's timeline, which is not what someone scanning a
board reads. So the role that opens a pull request leaves `PR: #N` on the issue
as a comment, on a line of its own, in that fixed shape so it can be found by
eye or by grep.

It goes on the pass that opens the pull request, rather than when the item
reaches `Human Review`. An item can go round the review loop more than once — one
did three times in a day — and a line left on each pass would say the same thing
three times on the same issue, while one left at the start is already there
whenever the owner arrives.

That the rule names the *pass* rather than the *column* is the whole of it. The
role file that carries this instruction is walked on every trip through the
Engineer, not only the first, so "post it once" would have been a thing to
remember rather than a thing that is true. Whether this pass opened the pull
request is something the role knows without looking.

The line is also how the loop finds the pull request when GitHub hasn't linked
it. GitHub writes no cross-reference onto a locked issue, so with
`lockConversations` on the timeline never shows a pull request opened after the
lock. The lookups read each `PR:` line an agent or the owner wrote and check
that pull request directly, on the same terms as a cross-reference: an agent
opened it and its body names the issue. `finish --pr` checks the pull request
itself rather than the timeline. A pull request the owner links by hand on a
locked issue needs its `PR:` line too.

Assignment is the other half and belongs at the later moment, because it is a
claim about whose turn it is rather than about where something lives. When the
Reviewer passes an item, it assigns the pull request to the owner and requests
their review, so it appears in GitHub's own queues and not only on the board.

The repair steps are mechanical and run before any role acts — **on the tick
holding `orchestrator`, not on every agent.** They are the read-heavy half of a
tick, and running them everywhere buys one board's worth of answers at the price
of however many agents there are. The cost is that an engineer no longer sees
the red check on its own work at the top of its next tick: the orchestrator sees
it and routes the card back, a tick later. They deliberately
do not touch an item sitting in `In Progress` or `In Design` with an open PR:
on the board that is indistinguishable from one the Reviewer has just sent back
for fixes, and a rule that moved it on would bounce returned work to
`Agent Review` unfixed on every tick. Recovering a tick that died after opening
a PR is left to the role that owns the item, which can read the PR and tell the
two apart.

## Design, and the tasks that come out of it

A design issue produces a decision, and the owner approves it by merging. So a
design PR is **docs-only**, and its body says `Part of #N` — never `Closes`.

That distinction carries real weight. If the merge closed the issue, the board
would send it to `Done` and nothing would be left holding the obligation to
write the tasks the document describes; the design would evaporate into a
merged file nobody acted on. Instead the issue stays open, the item returns to
`In Progress`, and the Engineer writes the child issues from the approved
document and then closes it.

The Engineer writes them rather than the Designer because the Engineer has to
satisfy the acceptance criteria it writes. It must not redesign while doing so:
a document that does not answer something needed to write a task is a
`Needs Human`, not an invention.

Designs run in parallel. One that needs another's decisions is blocked by it
explicitly, as any issue is, and waits in `Ready` until that design closes.

## The arrangement is written down, not remembered

The facts every agent needs and none can derive live in one committed file,
`loop.json` at the consumer's root:

**Every verb reads `origin/main`'s copy,** never the working tree's, an agent's
branch's or a pull request's head's, so nothing an agent can push widens who
approves or what merges.

| Key | What it says |
|---|---|
| `repository` | `owner/name`, where the board's issues live. The REST reads use it, so the tool does not depend on the directory it runs in. |
| `project` | `owner` and `number` of the Projects board, as `gh project` takes them. The board's cache is named from them. |
| `owner` | The login whose approval merges, and whose reviews and comments are requests the loop must answer. |
| `agents` | Each account's `login` and the `roles` it holds: `orchestrator`, `reviewer`, `engineer`, `designer`. |
| `mainRedLabels` | Optional. Labels added to `type:bug` on an issue filed for a check red on `main`. None by default. |
| `workflow` | Optional. What the board calls the columns and labels the loop acts on, below. Any key left out keeps today's name. |
| `review` | Optional. `agentApproval: {label, appliedBy}` opens the agent-approved path, under "The gate is the ruleset, not a withheld command". Needs `merge.auto` true. Off when absent. |
| `merge` | Optional. `{auto: true, method: "squash"}` lands approved pull requests through GitHub's native auto-merge. Off when absent. |
| `stack` | Optional. `{label}`: the label that lets an issue start stacked work, under "Opting in" in `docs/stacked-pull-requests.md`. It turns on selection's second pass, under "Which item a tick takes". `decompose` copies it from the issue it decomposes onto each task it files. Off when absent. |
| `lockConversations` | Optional. `true` keeps strangers' comments off the items agents work, through GitHub's conversation lock. `next` claims only locked issues, skipping an unlocked one as `unlocked` in every column, so the owner locks an issue before moving it to `Ready`. `finish --pr` locks the pull request before any other write and leaves one already locked alone. Tickwork never locks an issue and never unlocks anything. Off when absent. |

`workflow` names columns and labels and nothing else. Which transitions happen
stays in Tickwork:

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

`check-loop` refuses a key it doesn't know at any level, because a misspelt one
would otherwise leave today's name in force with nothing to say so. It never
reads the board, so a consumer's CI needs no Projects access. `next` reads the
board anyway, and refuses a column `workflow` names that the board doesn't
have, at its `loop.json` stage, before it claims anything.

With `stack` set, `check-loop` reads the repository through `gh`, which needs
push access to see `delete_branch_on_merge`: the label must exist, spelled in
the same case, and that setting must be off. Without `stack` it reads nothing.

`check-loop` also holds two invariants: at most one agent holds
`orchestrator`, and once there is more than one agent, at least two hold
`reviewer`, so no pull request is reviewed by the agent that wrote it. It fails
when the `AGENTS.md` beside the file has no `## Agent loop` section, so a
consumer cannot run without a local bar. A tick reads the same file and gives up
any role the file does not agree it holds, which is the backstop; a consumer
runs `check-loop` in its own CI, which is the gate.

**The shape changes additively.** Every consumer runs Tickwork's `main`, which
must accept each consumer's `loop.json` as it stands. `next` refuses a
`loop.json` it can't read at its `loop.json` stage, so a mismatch stops the tick
visibly rather than running on a misread configuration.

## How `next` chooses a tick's item

`tickwork next` does what a tick used to do by hand before it started work: it
works out the roles, selects the item, claims it and checks the board again.
The reasoning for each rule is kept here.

### Which roles a tick holds

`/next-task [role...]`, where a role is `orchestrator`, `reviewer`, `engineer`
or `designer`. **`/next-task` alone means all four**, which is today's single
agent unchanged.

Then read `loop.json` at the repository root, find this agent's own login with
`gh api user --jq .login`, and **give up any role the file does not agree this
agent holds.** An agent started by hand with the wrong argument loses that role
on its first tick rather than on the tick where it races.

**A check gives up a role, never the agent.** One file is read by every agent,
so a condition phrased about the file fails for all of them at once: one typo
would take the loop from four working agents to none. Giving up the role
instead leaves one column unserved until somebody fixes the file, which is the
narrowest thing the ambiguity can cost.

**Two entries holding `orchestrator`: report it and both keep running**, because
a repeated repair is a move the board should already have made and making it
twice changes nothing. Refusing would spend a column's work to prevent a
duplicated read. Any number may hold `designer`: a claim keeps two off one item,
and a design that needs another waits on it as a blocker.

**A login `loop.json` does not list is a single agent and the tick runs.**
Nothing is given up by allowing it: the invariants are about two agents
disagreeing, and one agent has nobody to disagree with. **Say in the report that
it is running unlisted.** The file itself has to exist, because the board tool
reads the repository and the project from it.

**`<repository>` and `<owner>` below are that file's `repository` and
`owner`**: the repository the board's issues live in, and the login whose
reviews and comments are requests the loop must answer.

A tick left holding no roles has nothing to do. Say so and end.


### Which item a tick takes

Work the board right to left — finish things before starting things. Take the
first case that applies and stop:

| Column | Role | Role file |
|---|---|---|
| `Agent Review` not empty | Reviewer | `sh <tool> instructions reviewer` |
| `In Progress` not empty | Engineer | `sh <tool> instructions engineer` |
| `In Design` not empty | Designer | `sh <tool> instructions designer` |
| `Ready` not empty | Engineer; Designer if the item is `type:design` | as above |

`orchestrator` is not a row here and has no role file. The
four names a tick accepts are not four of one kind: three choose a column, and
one chooses whether the repairs run. The three role files describe judgement — how
to decide, how to build, how to judge — and the repairs are a mechanical
checklist already written out in full.

**A row whose role this tick does not hold is a column it passes over as though
empty**, so a reviewer agent never starts work from `Ready` and an engineer
agent never reviews.

**`Ready` is skipped down rather than passed over**, because two roles share it:
a tick holding `designer` but not `engineer` takes the first `type:design` item
in it, and one holding `engineer` but not `designer` takes the first that is
not. Without that, "take the topmost item" hands a designer whatever happens to
be on top.

Take the **topmost** item in that column. That names the item and the role; it
does not start the work, because nothing is this tick's until the claim below has taken
it.

An item in `Agent Review` whose checks have not finished yet is not ready to be
judged — a review against a build still running is a review of nothing.
Unfinished means whatever the repairs treat as unfinished: a check run still going,
or a commit status still pending. Either can turn red after the review is
written, which is what makes judging now a review of nothing.

`cancelled` and `stale` are **not** in that set any more. The repairs report them and
leaves the card, because a cancelled run that reaches it is one nothing is
replacing — so skipping the item would skip it every tick, forever, which is the
stall this once caused. An item whose only complaint is a cancelled run is judged
like any other; what the Reviewer is judging is the diff, and the check that never
ran says nothing about it either way. Skip it and take the next case
that applies, which may well mean starting something new in `Ready`. That is the
right answer rather than a consolation: the checks answer on their own within a
tick or two, and the alternative is a tick spent waiting for them, which the
shared rules forbid. The repairs have already read the checks, so this costs
nothing extra to know.

**One pull request, one owner.** The agent that opened a pull request owns it
until it closes, design or implementation. Only it takes the item in `In Design`
or `In Progress` — to address findings or to assess a pull request an
interrupted tick left — and it never takes the review. Another agent may
review it; it never commits to it. `next` reads the opener from the pull request
it already reads for its merge state, skips the item as
`opened-by-another-agent` in `In Design` and `In Progress`, and as
`opened-by-this-agent` in `Agent Review`, and moves on. Nothing transfers
ownership, and the claim is still per tick: ownership is who opened the pull
request, not a claim held between ticks.

The opener alone decides, not every commit's author. A pull request both agents
pushed to before this rule is owned by its opener, and the other agent may
review it.

**A review nobody independent can take waits.** There is no disclosed
self-review. A loop with one agent, or with two listed and one running, leaves
that agent's pull requests in `Agent Review`, unclaimed, so no repair reports
them. `loop.json` says
who holds `reviewer`, not who is awake, so this cost is quiet, which is why it is
written here.

One thing can make you skip the topmost `Ready` item and take the next one
down. Nothing else can.

**Its blockers are still open.** `sh <tool> blockers <issue>` prints the
issues GitHub records as blocking it that have not closed; nothing printed means
nothing is holding it. An issue whose blocker is still open is one whose
groundwork is not on `main` yet, so branching from `main` gets a tree without it
— and the only ways out of that are to build on an unmerged branch or to bail,
both of which waste the tick. Skip it, and say in your report which you skipped
and what for.

**A design is no exception.** Designs run in parallel, and one that needs
another's decisions waits on it the same way: as a blocker, recorded with
`sh <tool> add-blocker`. Overlap between two designs is not a
dependency; only a decision one cannot be written without is.

This governs taking new work only. An item already in a working column is worked
where it stands: a blocker that appeared after it started is a finding for
whoever owns it, not a reason to shuffle the board.

**There is no cap on how much is waiting on the owner.** The loop keeps taking
work while `Ready` has any, and a night of it is a morning of pull requests
rather than a loop that stopped at three and idled until someone woke up. What
keeps it from running away is the `Backlog → Ready` gate, which it cannot open:
it can only work through what the owner has already approved.

**With `stack` set, a second pass runs when the first found nothing** for the
tick's roles, Engineer only. It goes through `Ready` again in board order and
takes the first card carrying `stack.label` whose one open blocker, its parent,
has one open pull request that is settled (unclaimed in `Human Review`, not a
draft, its checks green) and whose bases reach `main`, each the head of exactly
one open pull request. Every other labelled card is skipped as `not-stackable`,
naming the condition: two open blockers, the parent's column, a loop, or a
break. The assignment carries `stack: {parent, pullRequest, branch, head}`, the
token carries `branch`, and `finish submitted` refuses a pull request based
anywhere else. See "Choosing stacked work" in `docs/stacked-pull-requests.md`.
Its reads, the parent's pull request and checks and one `pulls?head=` per level,
are paid only when this pass runs.

If nothing is ready, say so and stop. Do not invent work.

Never take an issue labelled `epic` — those are containers that close when
their children do.

With an item chosen, the claim comes next. **No role file is opened before it** — a tick
that starts reviewing or building here has skipped the claim, which is the whole
of what keeps two agents off one item.


### Claiming, then checking the board again

**Claim last** — after the column, the role and the blockers have all agreed
this is the item. Everything before that is a reason to leave an
item alone, and claiming before them means claiming things you then hand
straight back.

    sh <tool> claim <issue>

That verb holds the whole protocol: it reads the assignee, refuses if anybody is
there, adds `@me`, and reads back — because `--add-assignee` adds rather than
refuses, so two agents that read the same empty list can each land a name and
neither call fails. It prints `#<issue> claimed by <login>` and exits 0 when the
item is this tick's, and otherwise fails with the reason:

- **held by somebody** — the item is theirs, whether they were there before the
  claim or arrived alongside it. First come, and the verb has already removed
  this agent again. Name the login and take the next item down.
- **the claim did not take** — GitHub silently drops an assignee with no push
  access, so this is an account that needs write access on the repository.
  Leave the item and say so.

**A column with nothing this tick can take is an empty column.** Fall through to
the next case rather than stopping — "take the first case that applies" has
always meant a case holding an item this tick can work, and a claim is the same
kind of skip as checks that have not finished. Stopping instead would idle an
agent holding a role with work waiting for it, which is the one thing adding
agents is meant to prevent.

Any assignee is a claim, the owner's included: assigning themselves takes an
issue off the loop without moving its card. That is not a trap, because a tick
that passes over an item always names the login holding it.

**Then check the board has not moved under you.** The board a tick reasons from
is a cached snapshot, and it can be wrong by the time the claim lands — another
agent can have claimed the item, worked it, moved it and released it while this
tick was still deciding, leaving an empty assignee list and a card that is no
longer `Ready` work at all:

    sh <tool> --refresh status <issue>

`--refresh` rather than plain `status`, and by hand, because the item list is
cached for three minutes: a re-validation written as `status <issue>` returns
the very snapshot it was added to distrust. Same column, still open, blockers
still closed, or for a stacked start only its parent open. **Anything moved and the tick releases the claim and takes the
next item down.** One board read and one issue read, on an item this tick is
otherwise about to spend minutes on.

**Release the claim the moment the item stops being this tick's** —
`sh <tool> release <issue>` — on the move, on a move the board refuses,
on a bail-out, and on the spot when an item is claimed and then abandoned. Every
column belongs to a role, so a claim left on a card handed to another role is a
card that role will never take. A claim covers the tick holding it, not the life
of the item.


## One login, one session at a time

**`next` hands an agent its own interrupted claim back**, as `"resumed": true`,
so the work a dead tick started is judged by the next tick rather than left
for an hour and a notice. That is safe only while the login's next tick can't
be racing a session still working the claim. So each login listed in
`loop.json` runs one session at a time.

What that rules out:
- **A second loop on the same account,** on another machine or in another
  terminal.
- **A hand-run `/next-task` beside a running loop on the same account.** Use
  another login for it, or stop the loop first.

`tickwork loop` enforces one part: a second supervisor under the same
operating-system user refuses to start, whatever repositories it names, and says
which pid holds the lock. Nothing enforces the rest, `/loop` or `/next-task`
beside it or the same login on another account or machine. `loop.json` lists one
entry per login, and the invariant is what that entry means.

## Installing and updating

Each account has one installation of Tickwork, under `~/.cache/tickwork/`:

    tickwork.git/   bare clone of Tickwork, main only
    tool/           bin/{tickwork,board,check-loop}, instructions/, revision
    install.lock    held while install.sh builds or switches
    loop.lock       the supervisor's single-instance lock

The root is always `$HOME/.cache/tickwork`, not `XDG_CACHE_HOME`, so that the
skill line and the permission rule name the same path. "What a consumer's
accounts need" below has the lines that install it.

A consumer commits the skill twice, at `.agents/skills/next-task/` and, for
Claude Code, at `.claude/skills/next-task/`. `gh skill install <owner>/<name>
next-task` places a copy, or the folder is copied by hand. The skill's whole
body is one line:

    git fetch -q origin && sh ~/.cache/tickwork/tool/bin/tickwork next-task

The fetch is there because `next` reads `origin/main:loop.json`. `tickwork
next-task` runs `update`, then prints `This tick's tool: sh <path>`,
`This tick's revision: R` and the installed instructions. Every tool call in the
tick uses that path, and the role files come from it too, with
`sh <tool> instructions <role>`.

**R is always a commit on Tickwork's `main`**, which requires the code owner's
approval, so approving a Tickwork pull request is approving the revision that
will govern. Every account picks a merged change up at its next tick, or its
supervisor's next reconciliation.

**`update`** fetches `main` into `tickwork.git` and runs that `main`'s
`install.sh`, so a change to the installer takes effect in the update that
brings it. It runs the installer even when the fetch fails. A failed fetch or
build leaves `tool/` as it was, and `next-task` then says the update failed and
prints the tool installed before it.

**`install.sh`** takes `install.lock`, and does nothing when `tool/revision` is
already `main`. Otherwise it builds `main` with `swift build -c release` into a
staging directory beside `tool/`, and swaps the finished entry in with two
renames, since macOS has none that replaces a non-empty directory. A lock whose
holder has died is taken over. The first build takes about a minute.

**Updates happen between pieces of work.** A tick updates before it starts, and
a supervisor before a reconciliation, when it has no child running. A person who
runs `tickwork update` while a tick is running can switch that tick's tool under
it, and nothing guards against that.

**The one hole is the entry point.** A runtime reads a skill's body from the
working tree, so after `gh pr checkout` of a branch that edits the skill, the
next tick runs that branch's body. The body is one line, and a branch that edits
it is a pull request in front of the owner. Once `tickwork next-task` runs,
nothing in the working tree is in the path.

## What a consumer's accounts need

On each account the loop runs as:

- Tickwork installed once, at `~/.cache/tickwork/tool/`, by hand or by the
  account's launcher. With `example-org/tickwork` standing for Tickwork's
  repository, the one you're reading this in or your fork of it:

      root=$HOME/.cache/tickwork
      [ -d "$root/tickwork.git" ] ||
        git clone -q --bare --single-branch --branch main \
          https://github.com/example-org/tickwork.git "$root/tickwork.git"
      git -C "$root/tickwork.git" fetch -q origin '+refs/heads/main:refs/heads/main' ||
        echo "Fetching Tickwork failed; installing the last fetched main." >&2
      git -C "$root/tickwork.git" show main:install.sh | sh

  `sh ~/.cache/tickwork/tool/bin/tickwork update` repeats the last two lines,
  and the supervisor and `tickwork next-task` run it before their work. It
  fetches whatever `origin` the clone recorded, which is why only these lines
  name the repository.

  HTTPS needs no key for a public repository. SSH works too: clone
  `git@github.com:example-org/tickwork.git` instead, which needs a key that can
  read the repository and `github.com` already in `~/.ssh/known_hosts`, so that
  an unknown host stops the clone rather than being trusted. A private fork over
  HTTPS needs Git to have `gh`'s credentials, through `gh auth setup-git`.

  **To pin a version, clone your own fork** and install from its URL. Every
  account runs its `origin`'s `main`, so it changes only when you update the
  fork.
- The `project` OAuth scope, through `gh auth refresh -s project`. Without it the
  loop cannot move a card.
- One permission rule beside the consumer's own, for the tool's verbs:

      Bash(sh ~/.cache/tickwork/*/bin/tickwork *)

The rest — `gh issue`, `gh pr`, the REST reads on `<repository>` and the denials
that keep `gh api` read-only, git, and the local bar's commands — are the
consumer's to document, because they name its repository and its tools.

## Trying it first

**`next` acts on whatever board `loop.json` names.** It claims an item, moves
cards and comments on issues, and an orchestrator's repairs merge what GitHub's
rules on `main` allow. Try it on a scratch repository and board, never by
pointing a sample at a real one.

1. **Check the sample, which needs no network.** `check-loop` reads a
   `loop.json` and the `AGENTS.md` beside it, so copy the sample beside
   Tickwork's own. From a clone of Tickwork:

       d=$(mktemp -d) && cp Tests/loop.json AGENTS.md "$d/"
       ~/.cache/tickwork/tool/bin/check-loop "$d/loop.json"

   It prints the agents, owner and project it read.
2. **Make a scratch repository and board.** A public repository with a
   `README.md` on `main`, since a private one needs a paid plan for step 5's
   ruleset, and a Projects board linked to it whose Status field has the eight
   columns under "The columns". `gh project create` and `gh project link` make
   the board; the columns are edited in its settings.
3. **Get an agent account.** The owner is you. The agent is a second GitHub
   account with write access to the repository and the board, because the
   loop takes the owner's comments and reviews as requests it must answer.
   Sign `gh` in as the agent, with the `project` scope, and install Tickwork
   for it as above.
4. **Configure the scratch repository.** Commit a `loop.json` at its root:

       {
         "repository": "<you>/<scratch>",
         "project": { "owner": "<you>", "number": <board number> },
         "owner": "<you>",
         "agents": [
           { "login": "<agent>", "roles": ["orchestrator", "engineer"] }
         ]
       }

   An `AGENTS.md` with an `## Agent loop` section naming the local bar, such as
   `- **The local bar:** none for this scratch repository.`, a `CODEOWNERS`
   reading `* @<you>`, and the skill from `skills/next-task/` at
   `.claude/skills/next-task/SKILL.md`. Run `check-loop` on it as in step 1,
   then push it to `main`.
5. **Protect `main`.** In the repository's settings, add a ruleset on `main`
   that requires a pull request with one approval and a code owner's review.
   This is what keeps merging behind your approval: the repairs merge any card
   in `Human Review` that GitHub reports as mergeable, and without the ruleset
   that is every one.
6. **Give it one issue.** Open a small one, such as "Add a line to the README
   saying what this repository is for", add it to the board and move it to
   `Ready`.
7. **Run one tick.** In a clone of the scratch repository, as the agent, start
   Claude Code and run `/next-task`. The Engineer takes the issue, opens a pull
   request and moves the card to `Agent Review`, where it stays: no agent may
   review its own pull request, and the merge repair reads only `Human Review`.
   Taking it further needs a second agent account, with `reviewer` given to
   both agents. A Reviewer's pass moves the card to `Human Review`, your
   approval satisfies the ruleset, and the next orchestrator tick merges it.

A real project's ruleset asks for more, under "The gate is the ruleset, not a
withheld command", and it runs `/loop /next-task`, under "Starting it".

## The gate is the ruleset, not a withheld command

**The loop may merge. It approves only on a path the owner configures.**

The ruleset on `main` requires a code owner's approving review standing
on the current head, the required checks green and every review thread resolved, and
`CODEOWNERS` assigns the repository to the owner alone — so a code owner is the
owner and nobody else, and no agent account has a bypass. Whoever presses merge,
the only thing that can go through is a pull request the owner has approved.
That is what makes the button safe to hand over, and what made withholding it
stop being a gate.

Withholding it was the gate before that, and it was a permission grant rather
than an enforcement. **The same door has a second handle**: GitHub's REST merge
endpoint needs only `Contents: write`, which every agent has because it pushes
branches, so an account holding `gh api` was one call away whatever the `gh pr`
grants said. That is the argument that moved the gate to the server. Once it had
moved, the command in front of it was costing latency and nothing else — an
approved pull request waiting for somebody to open GitHub, while `main` moved
underneath it. The orchestrator now merges one on the tick after it goes `clean`.

What was load-bearing is unchanged and belongs to the ruleset now. The owner's
*approval* is how work is approved, and a loop that could approve its own pull
requests would free itself to build on unreviewed work — it would not just skip
review, it would accelerate away from it. That matters most for `type:design`
issues, where the approval is of a direction every later task is built on.

**Do not withhold `gh pr merge` anyway, as a second line.** It defends nothing
the ruleset does not already defend, and it tells whoever reads these grants
next that the boundary is here — which is how a boundary that has moved gets
weakened by accident, at the place it actually lives.

### An agent-approved path, where a project configures one

**`review.agentApproval: {label, appliedBy}`** lets an independent agent's review
approve, where the owner chooses. GitHub can't condition a ruleset on a label,
so the label decides only whether Tickwork's reviewer submits a real `APPROVE`.
It bypasses no check, `CODEOWNERS` rule, last-push approval or branch
protection. What keeps it safe is the repository's own rules:

- `next` stops at stage `unsafe-ruleset` unless the board repository's rules for
  `main` require one approval, a code owner's review, approval of the last push
  and a required check, or when it can't read them.
- `finish approved` takes the path only when all of these hold:
  - the pull request is in that repository;
  - the issue carries `label`, applied last by the owner or a login in
    `appliedBy` (the owner alone when it is left out);
  - the reviewer didn't open the pull request;
  - the reviewer passed `--head` the commit it judged, that commit is still the
    head, and every check on it is green.
  - the pull request passes the merge guard (see "The merge guard" in
    `docs/repairs.md`).
- The approval is submitted for that commit, so it never covers a later push.
- Then it reads GitHub's `reviewDecision`. `APPROVED` leaves the card in review,
  where `next` skips it as `merging`. Anything else means a path still needs a
  code owner the agents aren't, so the owner is assigned and asked to review, as
  without the feature.
- `CODEOWNERS` is therefore what bounds the path: give the agents' team only the
  paths an agent may approve.

**`merge: {auto: true, method: "squash"}`** sets GitHub's native auto-merge on
every approved pull request in the board's repository, on either path, so it
lands the moment GitHub's rules are met. A pull request elsewhere is left to
the owner, since only that repository's settings are checked. `next` stops at
stage `config` when the repository doesn't allow auto-merge.
`review.agentApproval` needs it on, since nothing else lands what an agent
approves. The orchestrator's `MERGE … is clean` repair stays for loops without
it. Neither path sets auto-merge on a pull request the merge guard stops: the
owner is asked to review it, and the merge repair holds it or sends it back.
Auto-merge set before the guard stopped it is turned off by the repairs, which
hand an agent-approved card left in `Agent Review` with auto-merge off to the
owner in the same way, on that pass or once a claim on it is released.

## Starting it

    /loop /next-task

No interval — self-paced. Each tick does one thing and reports what it did.

What keeps it from running away is the `Backlog → Ready` gate: it cannot
promote anything into `Ready` to feed itself, so it converges on the work the
owner has already approved and then stops. Nothing caps how much of that work
ends up waiting in `Human Review` at once.

The cost of that is branches. Every open pull request is a branch off whatever
`main` was when it started, so a queue of them is a queue of things going stale
against each other. That is caught rather than prevented: the orchestrator reads
`.mergeable` and `mergeable_state` on every one of its ticks and routes a pull
request that conflicts with `main` — or that is merely behind it, where the
ruleset makes that block a merge — back to the role that owns it, which rebases
it.

What shortens the queue is merging on approval rather than on the owner's next
visit. An approved pull request left open is one `main` can still move under —
one was passed clean and another change landed on the same file while it
waited, so the fix for a conflict that no longer existed had to be found twice.
The gate is unchanged either way; only how long the approved thing sits there
is.

### Or under a supervisor

`tickwork loop` runs the same ticks without a model watching an idle board. It
checks the boards itself and launches one `claude -p "/next-task"` only when
there is work. `docs/supervisor.md` is the design. Start it from the installed
tool, with every path quoted:

    sh ~/.cache/tickwork/tool/bin/tickwork loop "/abs/first path" "/abs/other path"

It updates the installation before each reconciliation, and replaces itself
with the new tool between children when an update installs another revision.

- **Pass every clone the agents work in,** workspaces included, such as a
  Tickwork clone for a board whose tasks change Tickwork. The no-progress rule
  reads the Git state only of the paths it is given. A clone it isn't given
  can't show that a stuck item moved, and the repository is parked.
- **One session per login still holds.** A supervisor's children are that
  login's ticks, so never run `/loop /next-task` and a supervisor on the same
  login. A second supervisor under the same operating-system user refuses to
  start; other verbs still run beside one.
- **Only the subscription pays.** The children's environment drops
  `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN` and the Bedrock, Vertex and
  Foundry switches. Before every launch the supervisor runs
  `claude auth status --json` and stops unless it reports `claude.ai` and
  `firstParty`.

It prints a line per state change, with Claude's reply streamed between them,
and on a terminal keeps a status block below them: the login's state, its
budgets and a line per repository. With `--json` it prints one JSON event a
line instead. It runs in the foreground until a signal stops it, or it stops
itself, such as on a refused login or a board it can't read, and says why.
"What it prints" in `docs/supervisor.md` has the detail.

## What it will not do

- Approve anything. It merges what the owner has approved, and the ruleset on
  `main` is what makes those the same set — see the merge gate above.
- Take anything out of `Backlog`, or move anything into `Ready`.
- Take an issue labelled `epic`.
- Take a design decision the owner has parked in `Needs Human`.
- Guess at an ambiguity. It comments on the issue with the specific question —
  opening `Bailing out:`, so the comment is recognisable later — moves it to
  `Needs Human`, discards any branch the tick started and stops the tick. A
  branch with an open pull request is kept.

Not everything parked there is a question. A tick that stops because the
groundwork is on a branch that has not merged is waiting on a fact rather than on
a decision, and that bail-out carries a `Blocked-on: #N` line naming what it
waits for. Such a card comes back when the thing lands, without the owner having
to say anything — a reason that expires by itself needs no answer, and before
that line existed one sat parked eight minutes after its blocker merged, holding
two other issues behind it.

Dragging an issue to `Needs Human` is also how the owner keeps a specific piece
of work away from the loop by hand.

Those two uses of the column are why answering a bail-out brings the card back
but commenting on parked work does not. The repair that returns a `Needs Human`
item to a working column looks for the loop's *newest* comment being a bail-out —
which is why a bail-out has to open with `Bailing out:` — and for the owner
having commented after it.

Both halves of that are load-bearing. Merely having commented is true of every
issue the loop has worked, since opening a pull request leaves a `PR: #<number>`
line behind, so work the loop finished and the owner then dragged aside would be
pulled back by the note explaining why. And *newest* is what makes the question
still standing rather than spent.

Spending it is the repair's own job: when it fires it comments `Answer received:`
on the issue before moving the card. Leaving that to whichever role picks the
item up would not do — a role that bails again, or that opens no pull request,
leaves the bail-out newest — and an answered question with nothing on top of it
is a card the repair takes back out of the column every minute, however plainly
the owner has since parked it.

## Developing Tickwork

Tickwork works its own board: the root `loop.json` names it, and its agents
work the issues the owner puts in `Ready`. Work for Tickwork found on another
consumer's board can also arrive as a pull request here that says
`Closes <repository>#N`. A contributor starts with an issue, as
`CONTRIBUTING.md` says.

- **Work in an ordinary clone**, never in the installation under
  `~/.cache/tickwork/`. Nothing reads a working tree to decide what governs a
  tick.
- **The local bar** is this repository's `AGENTS.md`: `swift test`,
  `sh Tests/wrapper.sh`, `sh Tests/check-loop.sh` and `sh Tests/names.sh`, which
  CI runs on macOS and on Linux.
- **`main` requires the code owner's review**, and `CODEOWNERS` names the owner
  for everything. Agents review each other here too, but their approval alone
  merges nothing.
- **`CHANGELOG.md` gets its entry in the same pull request**, under
  `Unreleased`.
