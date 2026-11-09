# The repairs, and the markers they read

`tickwork next` runs the repairs when its tick holds `orchestrator`, as
`repairs --apply`, and puts their lines in its answer. `finish` writes every
marker the repairs read and makes every column move. This page keeps the
reasoning for both, which used to be read on every tick in
`instructions/next-task.md` and now changes only when the Swift does: a rule
changes here first, then in `Sources/BoardCore`.

Where it says `sh <tool> <verb>`, that is the verb the repairs and `finish` run
on the agent's behalf.

## The repairs

**They run only when the tick holds `orchestrator`**, and otherwise it goes straight
to selection. The repairs are the read-heavy half of a tick — a pull request, its
checks, its reviews and its comments for every item in review — and running them
in four agents buys one board's worth of answers at four times the price. They
are also the only part of a tick that writes something other than a card move,
so one orchestrator removes that race outright rather than defending it with a
claim.

The cost is that an engineer no longer sees the red check on its own work at the
top of its next tick: the orchestrator sees it and routes the card back, a tick
later. That is the latency the loop already accepts everywhere else, which is
why no role waits for CI.

A tick holding both `orchestrator` and `engineer` repairs and then works, which
is exactly what `/next-task` alone does.

Mechanical, no judgement. Do all that apply — they are board hygiene, not the
tick's work, so selection runs afterwards.

**Run them with one verb and report what it prints:**

    sh <tool> repairs --apply

It computes every repair below from one board read and REST, and prints one
line per card, each naming the card: `MOVE`, `REPORT`, `MERGE`, `UNARM`, `HELD`,
`RELEASE`, `NOTICE`, `FILE`, `REFUSED` or `ok`. With `--apply` it makes the moves
with `--from`, posts the notices and comments the rules call for, removes agent
claims in `Needs Human` and files a check red on `main`. Without it, it changes
nothing, which is how to see what a tick would do. It finds each card's pull
request from the issue's own timeline: its cross-references, and the pull
requests its `PR: <ref>` lines record, read one request each, which is the only
link a locked issue keeps. No list is typed by hand and an old pull request is
not missed.

**A card's pull request may live in another repository.** The verb
reads every one of its facts in that repository. Such a pull request names the
issue in full, `Closes <repository>#N`, because a bare `#N` there is that
repository's own issue, and a bare one is not counted. The `gh api` calls below
are written for `<repository>`; for another, substitute its name.

**The verb never merges.** A `MERGE` line is the merge repair below, printed
rather than done, and a tick lands it with `sh <tool> merge <ref>`.

The prose below is each rule's reason, and what the verb implements. A rule
changes here first, then in Tickwork's `Sources/BoardCore`.

**Read the claim before moving anything, and skip what somebody holds.**
`sh <tool> status <issue>` gives the column; the claim is the issue's
assignee:

    gh issue view <issue> --json assignees --jq '.assignees[].login'

Anybody there and the repair does not fire on that card this tick — name the
login in the report and carry on to the next repair. Repairs move cards out of
`Agent Review` and `Human Review`, which are the columns a Reviewer or an
Engineer is mid-tick in, so this is the collision the arrangement is most likely
to have. The repair fires on the next tick instead, by which time the claim is
released and the card is wherever that tick left it — which may well be a column
where the repair no longer applies, and that is the right answer rather than a
missed one.

**The orchestrator takes no claim of its own.** A repair is a single write with
nothing in front of it to protect, and a claim would only be one more thing to
remember to release — on the agent that runs most often, where one left behind
is a card no role will take.

**A refused move is reported and the rest of the repairs still run.** Repairs are
independent — a different card and a different rule each — so a board that moved
under one says nothing about the others, and stopping would leave real work
undone over a card somebody has already handled. It is not retried within the
tick: the card is where something else deliberately put it, and the next tick
reads a fresh board and decides again.

- `Agent Review` or `Human Review` with a failing check → `In Progress`, or
  `In Design` if the issue is `type:design`. A red check is a change waiting to
  happen, and it waits with whoever owns the change: a design pull request is
  prose, so what fails on it is a check reading prose, and handing that to the
  Engineer gives them a document to fix that they did not write and do not own.
  Every repair that sends a card back for work picks its column this way. The one
  that does not — a merged design going to `In Progress` — sends a `type:design`
  item to the Engineer deliberately, because what an approved design owes next is
  decomposition, and that is engineering. This one routed like that without the
  reason, for no better cause than that a red check reads like code.

  **Every repair that sends a pull request back for work disarms it first.** A
  failing check, owner feedback, a conflict, being behind `main`, and a restack or
  broken stack each print `UNARM #N auto-merge on PR <ref> (<reason>)` before the
  `MOVE` when GitHub's auto-merge is set on it, and `--apply` runs
  `gh pr merge <PR> --disable-auto` before the move, so an approval can't land it
  while it is reworked. With auto-merge off there is no `UNARM` and no extra write.

  Read the checks over REST rather than with `gh pr view --json`: one call to
  `gh api repos/<repository>/pulls/<PR>` gives both the head SHA and
  whether it merges, and
  `gh api "repos/<repository>/commits/<sha>/check-runs?filter=latest"`
  gives the checks. **`filter=latest` is newest per check suite, not per check
  name.** A workflow run cancelled by a newer one on the same commit keeps its
  own suite, so its failure comes back beside the replacement's pass and would
  file a green `main` as red. The verb keeps only the newest run of each name,
  which is what the `cancelled` rule below rests on. REST and GraphQL have
  separate hourly budgets, and the board runs
  entirely on the GraphQL one — Projects has no REST API — so anything read over
  GraphQL that could have been read over REST is taken directly out of the
  loop's ability to move a card.

  **A check run is not the only thing that can go red.** The older commit-status
  API is what a service integrating without a GitHub App writes, and a repository
  may use none today — which is the reason to read it rather than the
  reason not to. The day something does, a rule that only knows about check runs
  hands the owner a pull request it has called green.

      gh api repos/<repository>/commits/<sha>/status \
        --jq '"\(.state) \(.total_count)"'

  **`total_count` is the half that matters, and believing `state` alone is a
  trap.** A commit with no statuses answers `pending`, not `success` — so a rule
  reading the state would find every pull request permanently unfinished and
  never judge one again. Zero means there is nothing here to say; only above zero
  does the state mean what it looks like, and `failure` there is red exactly as a
  check run is.

  **`pending` above zero is the same trap the other way up.** It means a status
  is still running, which is unfinished rather than nothing there — and unfinished
  is what selection needs, so that a pull request is not judged against something
  still going. It is a status, so it has no `cancelled` of its own to confuse it
  with; a check run that was cancelled is settled one section down and is not
  unfinished at all. GitHub answers `pending` in both cases and only
  `total_count` tells them apart, so a rule that reads the state without it is
  wrong twice rather than once.

  **Every conclusion a check run can carry has an answer**, so that none of them
  falls through whichever branch happens to catch it first. These eight are the
  whole set — a check run carries no others, and `startup_failure`, which looks
  like it belongs here, is a *workflow run's* conclusion rather than a check
  run's:

  | Conclusion | What this does |
  |---|---|
  | `success`, `neutral`, `skipped` | Nothing. None of them is a complaint. |
  | `failure`, `timed_out` | Route the card. Something has to change before these pass. |
  | `cancelled`, `stale` | Leave the card and say so in the report. Nothing replaced it. |
  | `action_required` | Leave the card and say so in the report. |

  The case `startup_failure` names is real and is not this rule's: a workflow that
  dies before it starts creates no check runs at all, so there is no conclusion to
  read and a pull request with nothing attached to it reads as green. Nothing
  here catches that yet.

  `cancelled` is not a verdict on the code, so the card is not routed: a
  workflow may cancel in-progress runs when a newer commit arrives, and sending an
  Engineer to fix a run that was stopped on purpose is the wrong answer twice
  over.

  **What matters is whether anything is replacing it, and the condition is:
  no other run of the same check name on this head is queued, running or
  concluded.** State it that way rather than as a property of the listing, so it
  stays right whatever the endpoint returns — the verb's newest run per name
  is what makes the condition free, rather than anything the endpoint promises.

  A newer commit puts its run on a different head SHA, which this call does not
  ask about at all. A re-run on the same head is a second run of that name, which
  the condition sees. What is left is the case with no answer before: cancelled by
  hand, or a replacement that never started. Nothing further is coming, so treating it
  as unfinished means treating it as unfinished forever — selection skips the item
  every tick and no role ever judges the pull request. It does not bounce between
  columns the way a red check does, which is why it is quieter than the failure
  it resembles.

  So it is reported, exactly as `action_required` is, and for the same reason: a
  person has to re-run it, and re-running is a POST the policy guard blocks.

  **The one false positive is a replacement that has not been created yet**, in
  the second or two between a cancellation and the run that follows it: no second
  run exists to find, so the condition holds and the report fires. That costs
  one line in one tick's report and corrects itself on the next, which is the
  cheapest wrong answer available here — the alternative was a card nobody looked
  at again.

  `action_required` is a check asking a person to do something — approve a
  workflow, authorise an integration — and neither role can. Moving it to
  `Needs Human` would look right and would strand it: the repair that brings work
  back from that column recognises a bail-out comment, and a card a repair put
  there has none. Reporting it puts it where the owner is already reading.

  **A check that is red on `main` too is not this pull request's doing.** Leave
  the card and name the check in the report. Routing it sends whoever owns the
  card to fix something that is not in their diff, and they will find it green
  locally and be right. **`main` is the pull request's own repository's**, since
  one check name can mean different things in two repositories. One read per
  repository answers it for the whole tick rather than once per pull request:

      gh api repos/<repository>/commits/main/check-runs \
        --jq '[.check_runs[] | select(.conclusion == "failure") | .name]
              | join(" ")'

  **A commit status red on `main` is the same thing and wants the same read**,
  since the rule above made one a source of red beside the other. Where nothing
  writes a status, this is one more call for an answer that is
  always empty — which is the argument for it rather than against, the
  same argument the status read itself is made on.

  **It answers with names, because the rule below needs one.** A status's name is
  its `context`, and the paragraph after this one has to put it in an issue title
  — so a read that answered only red or not red would leave that title with
  nothing to say and the search that guards against duplicates with nothing to
  search for. Reading the contexts gives the same shape the check-runs read above
  gives, and makes `total_count` moot: an empty list prints nothing.

      gh api repos/<repository>/commits/main/status \
        --jq '[.statuses[] | select(.state == "failure") | .context] | join(" ")'

  **Then open an issue for it, once, when that `main` is `<repository>`'s**,
  titled `<check> is failing on main`, where `<check>` is the name the check
  reports itself under, verbatim. Another repository's red `main` is only
  reported, because it has no card on this board to own it. A check
  red on `main` is red on every open pull request at once, so this leaves the
  whole review queue standing, and a tick report is the wrong place to say so —
  for the reason the abandoned-claim repair gives below, a line printed into one
  of four unattended sessions has no reader. It also gives the breakage a card
  to own it, which nothing else does: the branch that caused it has merged.
  `type:bug` and the labels `loop.json`'s `mainRedLabels` lists, no milestone,
  and it lands in `Backlog` like any other gap.

  **The title is the guard.** Search open issues for that name first and file
  nothing when one comes back. The condition holds every tick until `main` is
  green, so the search is all that stands between it and a hundred identical
  issues — and it only meets what an earlier tick wrote if both ends spell the
  string the same way, which is why the title is prescribed here rather than
  left to whoever happens to be writing it.

  That is as far as the loop can tell the runner from the change, and the limit
  is worth saying rather than leaving to be discovered. A failure that is
  transient — a runner that lost the network, a cache that came back corrupt —
  looks exactly like one the diff caused, and what settles it is a re-run, which
  is a POST the policy guard blocks. So a red check that `main` does not share
  still routes by issue type, and whoever picks it up starts at the log rather
  than the diff. That costs a tick; guessing costs a card that bounces on
  nothing.
- `Agent Review` or `Human Review` with anything the owner has said that nothing
  has answered → `In Progress`, or `In Design` if the issue is `type:design`. The
  owner has asked for something and nobody is holding it.

  **What counts as answered is defined below and only below.** This bullet used
  to carry its own summary of the rule — "neither a commit nor a reply" — and
  when the rule changed underneath it, the checklist a tick reads went on
  describing the behaviour the change existed to stop. A rule with two statements
  has two places to drift, and this one is the one a tick actually runs down.

  **Answered means a comment from the loop names it**, with the one exception
  below. A reply carrying `Answering <url>.` answers the review or comment at that
  url and no other. An answer is always there to find, because every role file
  requires one: `reviewer.md` on either outcome, `engineer.md` and `designer.md`
  on a pass that came back with findings — `designer.md` most of all, since a
  design finding answered with "the original call stands" has no commit in it by
  definition.

  Every role file requires that line on a line of its own, where the url is the
  comment or review being answered — which the reviews read and the conversation
  read below both carry, and which renders as a link the owner can follow back.
  One reply may carry several, one per line, and answer all of them.

  **Being newer is not naming, which is what broke the reply half.** A reply that
  merely came afterwards counts anything the loop said as an answer, and the loop
  says something on every pass — so the owner commenting while the Reviewer is
  mid-review had their comment buried by the Reviewer's own findings a moment
  later, and this repair, which exists to catch exactly that, read it as handled.
  The comment was then never seen by anyone.

  **A newer head commit is not an answer either, and used to be.** That is the
  same burial one door over. The loop pushes on every fix pass, so an owner
  comment landing while the Engineer is fixing the Reviewer's findings was marked
  answered by that fix commit — one written before anybody had read it. A commit
  is evidence that work happened, never evidence that it was the work the owner
  asked for, and the two are only reliably the same when something says so.

  **A line comment is answered the same way.** It was the last thing a newer head
  commit answered, because its read once carried no url for a reply to name. The
  read carries `html_url` now, so the exception is gone: a push leaves a line
  comment outstanding until an `Answering` line names it.

  The cost of the strong rule is worth stating rather than discovering. A pass
  that forgets its `Answering` line answers nothing, so the card comes back next
  tick and keeps coming back. That is the failure the old rule avoided and this
  one accepts, deliberately: a card that will not settle is visible on the board
  and in every report, where a comment nobody ever saw is visible nowhere at all.

  It covers `Agent Review` as well because a comment landing while the loop is
  reviewing would otherwise be buried by the Reviewer's own comment a moment
  later, and never seen. What the owner says outranks a review in progress.

  **An approval is not a request.** A bare approval is a review like any other —
  `state` `APPROVED`, an empty `body`, and a `submitted_at` newer than every
  comment the loop has left — so a rule that counts reviews would take a pull
  request the owner has just approved, which is one waiting on nothing but the
  merge, and move it off their queue into `In Progress` for an Engineer with
  nothing to do. That is the column's whole purpose defeated by the repair that
  serves it.

  **The repair is one verb, and a tick runs it rather than assembling reads:**

      sh <tool> feedback <issue>

  It prints the url of every owner review, conversation comment and line comment
  on the issue's open pull request that nothing has answered, and nothing when
  nothing is waiting. **Anything printed routes the card.** It exits 0 whether or
  not it prints, so a non-zero exit is a read that failed, never a quiet board.

  **`mergeable_state` cannot answer this, and reading it instead is the trap.**
  It says `blocked` both when a pull request merely lacks an approval and when the
  owner has requested changes, so a tick that reads it sees the column's ordinary
  state in both cases. That is how one pull request sat for 1h44m on two unanswered
  reviews while every tick reported the board idle. It belongs to the merge
  repair, which runs after this one.

  The verb exists because three reads left as prose get partly run, which is the
  same reason `claim` is a verb. Naming the comparison without naming the reads is
  how the repair once went five and a half hours without firing. What it reads,
  all REST, with `<PR>` the pull request's number in every call and never the
  issue's:

      gh api repos/<repository>/pulls/<PR>/reviews \
        --jq '.[] | select(.user.login == "<owner>" and (.state == "CHANGES_REQUESTED" or (.body | length) > 0))
              | "\(.state) \(.submitted_at) \(.html_url)"'
      gh api "repos/<repository>/pulls/<PR>/comments?per_page=100" \
        --jq '.[] | select(.user.login == "<owner>") | "\(.created_at) \(.html_url)"'
      gh api "repos/<repository>/issues/<PR>/comments?per_page=100" \
        --jq '.[] | (.body | split("\n") | map(select(startswith("Answering ")))
                     | join(" ")) as $named
              | "\(.user.login) \(.created_at) \(.html_url) \($named)"'

  Each call answers one question, which is what keeps the approval out without
  losing anything the owner said. The reviews call asks whether they requested
  changes or wrote a summary, and is filtered to exactly those: a review that
  is neither is an approval, and an approval carries no request. The line-comment
  call asks what they said against the diff, read directly rather than inferred
  from the review GitHub wraps it in — which is what an earlier version of this
  did, and why it could not tell a wrapper from an approval, both arriving with
  an empty `body`. The issue-comments call covers the conversation.

  **The reviews call carries a url as well, because a review is a thing that has
  to be nameable.** It is the ordinary shape of the owner's feedback here, and
  the one case with no commit in it by definition — a design answered with "the
  original call stands" — is a review. Without a url on that side there would be
  nothing for a reply to carry and nothing for this to match, so such a card
  would come back every tick on feedback that had in fact been answered.

  The issue-comments call also pulls out the `Answering` lines and nothing else,
  which is what lets one reply name more than one comment. Filtering rather than
  taking the opening line is what makes that free: the output is a url or two
  instead of whatever prose the reply happened to begin with, so a long reply
  costs less to read than a short one used to.

  Approving *and* leaving line comments is one action producing one review, so it
  is the case where a rule reading only reviews goes wrong in the other
  direction. Reading the line comments themselves is what makes it a non-case:
  the approval is discarded and the comments are still there.

  **The conversation call says `issues/` and still means the pull request.**
  GitHub keeps a pull request's conversation on the issues endpoint under the
  pull request's own number, so `issues/<PR>/comments` is that thread and
  `issues/<issue>/comments` is a different one — the same call, one digit apart,
  and the difference between seeing "please resolve the conflicts here" and
  reporting the board idle for as long as it takes somebody to notice. Correcting
  it to `pulls/<PR>/comments` is the other way to get it wrong: that is the
  line-comment call above, and it returns comments against the diff rather than
  the conversation.

  It is also the one call that is not filtered, because it has to answer two
  questions at once: what the owner said, and whether the loop has replied since.
  The loop answers findings with `gh pr comment`, which lands in this same
  thread, so filtering here would drop the answers along with the questions.
  Everywhere else, filter to the owner — the loop comments on its own pull
  requests every pass, and counting those as requests would bounce the whole
  board back every tick.
- `Agent Review` or `Human Review` whose PR no longer merges cleanly →
  `In Progress`, or `In Design` if the issue is `type:design`. An unmergeable
  pull request cannot be approved however good it is, so it is not waiting on
  the owner. Read `.mergeable` from the same REST call as the checks, and treat
  only `false` as conflicting — `null` means GitHub has not finished working it
  out yet, not that it is fine.

  **A `mergeable_state` of `behind` routes here too, and `.mergeable` cannot see
  it.** A branch that is only out of date has no conflict, so `.mergeable`
  answers `true` and this rule would pass it over — while the merge repair below
  declines it for not being `clean`. Routed by neither, an approved pull request
  would sit in `Human Review` with nothing that would ever pick it up, which is
  the stall that repair exists to remove. What it needs is the rebase this
  column's roles already do, so it comes here, read from the REST call already
  being made for `.mergeable`.

  GitHub reports `behind` only where a pull request must be up to date before it
  merges, so it cannot arise while `strict_required_status_checks_policy` is
  off. The rule is written for both settings rather than for
  either, because that setting is one API call from changing and this file is
  not what anybody would think to change alongside it.

  **A stacked pull request, one whose base isn't `main`, gets the restack
  repair instead.** Selection's second pass starts one, under "Which item a tick
  takes" in `docs/loop.md`, and the repair keeps it current. GitHub compares it
  with its parent's branch, so its conflict and `behind` fire whenever the
  parent is reworked, and `git rebase origin/main` would pull the parent's
  commits into it. The repair reads the parent, the pull request from its base,
  with `pulls?head=<owner>:<base>&state=all`, and acts per "Keeping a stack current"
  in `docs/stacked-pull-requests.md`:

  | Parent | Action |
  |---|---|
  | open, not settled | nothing; the child waits |
  | open, settled, its head in the child | nothing |
  | open, settled, its head not in the child | back with `restack` onto the parent's head |
  | none open, and the branch's only pull request merged into `main` | back with `restack` onto `main`, retargeting |
  | anything else | back with `stack-broken`, naming what was seen |

  Settled is the parent's issue unclaimed in `Human Review`, named by a
  `Closes`, `Refs` or `Part of` line in the parent's body, the parent not a
  draft, and its checks green with at least one having run; those checks are
  read only then. "Its head in the child" is `behind_by` 0 in
  `compare/<parentHead>...<childHead>`. The line is `MOVE #N <column> → <work
  column> (PR <ref> must restack onto <onto>[ and retarget to main]: <reason>)`
  or `(PR <ref> has a broken stack: <what was seen>)`. It never pushes and
  writes no bail-out: the rebase is the Engineer's. `next` gives an
  `In Progress` card the same reading as a `restack` finding, with `onto` and
  `retarget`, or a `stack-broken` one. A claimed card's parent isn't read.
- `Human Review` or `In Design` whose design PR has merged, with no other
  pull request open → `In Progress`. The design is approved; the
  decomposition is still owed.

  `In Design` is here because of an approval with a comment. The feedback
  repair reads it as a request and sends the card to `In Design`, and if the
  owner then merges, the card would otherwise sit there. A designer working on
  a follow-up pull request holds the claim, and the claim guard leaves the card
  alone.
- `Human Review` whose pull request GitHub reports as `clean` → **merge it.**
  One more field from the call the check repair has already made:

      gh api repos/<repository>/pulls/<PR> --jq .mergeable_state

  `clean` is GitHub's own answer to every question the ruleset asks — a code
  owner's approving review standing on the current head, the required
  checks green, every review thread resolved, and no conflict with `main`.
  **Read it rather than reconstructing it.** The conditions live in repository
  settings where they can be changed without this file being touched, so a rule
  that re-derived them would go on believing an old ruleset, and the one thing
  it must never do is conclude yes where the server would have said no.

      sh <tool> merge <ref>

  The verb reads `clean` and the merge guard again, since the line is a
  snapshot a reopened former parent or a push can outdate, and runs
  `gh pr merge <PR> --squash --match-head-commit <head>` with the head it read
  them on. It refuses otherwise.

  **The merge guard comes first.** `main`'s ruleset doesn't cover a pull
  request into a feature branch, so `clean` alone can't say a pull request may
  land. The `MERGE` line, auto-merge in `finish approved` and the agent-approved
  path act only on a pull request that passes it:

  1. **Its base is `main`.**
  2. **No former parent is open, and every one that merged is contained.** A
     former parent is a pull request from a branch it was based on before a
     retarget, by hand, by Tickwork, or by GitHub when it deleted that branch.
     Contained is `behind_by` 0 in `compare/<mergeCommit>...<head>`. A former
     parent closed without merging is ignored: anything of it the child still
     carries is in its diff, which `Agent Review` checks.

  Former bases come from one GraphQL query over `BaseRefChangedEvent`
  (`previousRefName`) and `AutomaticBaseChangeSucceededEvent` (`oldBase`): the
  one GraphQL read outside the board, refused below `readReserve`. Then one
  `pulls?head=<owner>:<base>&state=all` per former base and one compare per
  merged former parent. A pull request with no base change merges exactly as
  before, after that one query. The guard is read only for a clean pull request
  in `Human Review`, for one with auto-merge set, and for an `In Progress` one,
  whose restack is a finding.

  It refuses in one of two ways. A base other than `main`, an open former
  parent or a refused query prints `REPORT #N PR <ref> is held: <reason>` and
  moves nothing: the parent's merge brings the restack. A merged former parent
  the head doesn't contain, after a hand retarget or a deleted branch, sends the
  card back with a `restack` finding onto `main`. `finish approved` sets no
  auto-merge and submits no agent approval on a pull request the guard stops;
  the owner is asked to review it, and this repair then holds it or sends it
  back. Auto-merge set earlier stays set when a former parent reopens, since
  neither base nor head moves, so a pull request with auto-merge set that the
  guard now stops prints `UNARM #N auto-merge on PR <ref> (<reason>)`, and
  `--apply` runs `gh pr merge <PR> --disable-auto` before holding or sending it
  back. That comes before the claim guard, since a claim doesn't stop GitHub
  merging: a claimed card is disarmed, then `HELD`. In `Agent Review`, where
  auto-merge is an agent-approved card's only way to land and `next` skips it
  as `merging`, an unclaimed one whose auto-merge is off, or is being turned off,
  goes to the owner instead of staying, whenever it was turned off: `MOVE #N
  Agent Review → Human Review (auto-merge on PR <ref> is off[: <reason>])`, and
  the owner is assigned and asked to review, as `finish approved` does when the
  agent path can't land it. There this repair prints `MERGE` once the guard
  passes. The guard asks for no approval of its own. See "Merging" in
  `docs/stacked-pull-requests.md`.

  **The other seven are named here, all of them, because a value nothing claims
  is how a card was once stranded.** GitHub documents eight and this rule acts
  on one, so the other seven have to be accounted for by name rather than by
  falling through a sentence about "any other value" — that sentence is what let
  `behind` be routed by nothing while reading as though it had been considered.

  `blocked` is waiting on the owner, which is what the column means. `dirty` and
  `behind` belong to the repair above, which reads one from `.mergeable` and the
  other from this same field, and says so. `unstable` is a check that is red
  without being required, which is a judgement rather than a mechanism. `unknown`
  means GitHub has not finished working it out, exactly as `null` does on
  `.mergeable`.

  **`draft` is left alone and named in the report.** The loop never creates one —
  nothing here passes `--draft` — so a draft in this column is always a person
  having said the pull request is not ready, either at creation or by converting
  it since. That is the same kind of act as the owner assigning themselves an
  issue, and it gets the same answer: leave it, and say so where they are
  reading. Routing it would send an Engineer to fix code nobody has said is
  wrong, and merging it would overrule the one signal a draft carries.

  It is reported rather than passed over in silence because, unlike `blocked`, it
  does not clear itself. An approved pull request left in draft will sit there
  until somebody notices, and the report is the only place that says why the
  merge repair keeps declining it.

  **`has_hooks` is this rule's own answer on a repository that has pre-receive
  hooks**, which GitHub documents as mergeable with passing status and hooks
  configured — `clean`, one condition further on. Where none are configured it
  cannot arise.

  It is named anyway, and with the instruction rather than only the reason,
  because the day it can arise is the day every mergeable pull request reports it
  **instead of** `clean` and this repair stops merging anything at all. That is
  not one stranded card but the whole queue, arriving from a change nobody would
  think to make this file alongside. Adding pre-receive hooks means adding
  `has_hooks` beside `clean` above; it is not broadened now, because widening the
  one action the board cannot undo, for a value that cannot occur, is a change
  nothing could review.

  **Then stop, and move no card.** A code pull request says `Closes #<issue>`,
  so the merge closes the issue and the project's own workflow sends the card to
  `Done`. A design says `Part of #N` and closes nothing, so the repair above
  catches it on the next tick and sends it to `In Progress` for the
  decomposition it still owes. Both paths already exist, and a second writer on
  either would race the first for no gain.

  **The claim read guards this too**, and it is the one rule where it guards
  something other than a card move. A `Human Review` item carries no agent's
  claim — the Reviewer released it on the way in — so an assignee there is the
  owner, and self-assigning is how they take work off the loop by hand. It has
  to stop a merge for exactly the reason it stops a move, and the merge is the
  one the board cannot undo.

  **This is written after every repair that can empty the column, and the order
  is load-bearing.** A red check, a comment of the owner's, a conflict: each
  moves the item out of `Human Review` before this is reached, so a card still
  sitting there is one nothing above had anything to say about. That is what
  keeps an approval carrying a body out of here — the feedback repair reads it
  as the request it is and routes the card, where `mergeable_state` sees only an
  approval and would happily merge over the top of what the owner wrote. **If a
  repair above has already moved this card this tick, this one does not fire**,
  whatever the snapshot at the top of the tick still says.
- `Needs Human` where the loop asked a question and the owner has since answered
  → `In Progress`, or `In Design` if the issue is `type:design`. The block is
  what the loop was waiting for, and it has been lifted.

  Without this the answer is never read. A bail-out puts the question on the
  issue and the card in `Needs Human`, and nothing afterwards ever looks at that
  column — so the owner replies, the loop keeps reporting the board idle, and the
  only way the work resumes is the owner moving the card by hand as well.

  **`Needs Human` means two different things and this must only fire on one of
  them.** The loop parks its own questions there, and the owner also drags work
  there to keep the loop off it (Tickwork's `docs/loop.md`, "What it will not do").
  Pulling anything commented-on out of that column would take back the work the
  owner deliberately set aside, which is worse than the problem being fixed.

  What tells them apart is **the loop's newest comment on the issue being a
  bail-out, with a comment from the owner after it.** Nothing weaker works. "The
  loop has commented at some point" is true of every issue it has ever worked,
  because opening a pull request leaves a `PR: #<number>` line — so an item the
  loop finished and the owner then dragged aside would be pulled straight back by
  a note explaining why it was set aside. A bail-out opens with `Bailing out:`
  precisely so it can be recognised.

  Being the *newest* loop comment is what makes it a question still standing. An
  older bail-out that was answered and worked has the loop's later comments on
  top of it, and the question is spent.

  **A loop comment is one from any agent, not from the agent reading it.** Which
  logins those are is what `loop.json` records, and this reads it the way the
  abandoned-claim repair below does: a login the file lists.

  This rule never named an account — it said "the loop's" and stopped, which one
  agent makes right by accident. The feedback repair once matched an account
  name too, and the `Answering` line replaced it there. What
  several agents cost is a tick matching its own name alone: it finds no bail-out
  on an issue another agent parked, and the question sits in that column with
  nothing to bring it back.

  **When this fires, move the card first and comment `Answer received:` second**,
  with the one line of the answer that unblocks the work. The comment is what
  spends the question, and it has to happen here rather than being left to
  whichever role picks the item up — a role that gets there and bails again, or
  opens no pull request, leaves the bail-out newest. Until something newer sits
  on top of it, the owner answering and then deciding to park the work anyway is
  a card this repair drags back out every minute, which is the exact failure the
  paragraph above is written to prevent. It is also what the owner sees when
  they wonder why the card moved.

  **The order is the whole of it.** Comment first and a crash before the move
  leaves the bail-out no longer newest, so nothing recognises the card as needing
  the repair and it sits in `Needs Human` until a person moves it. Move first and
  a crash leaves the card in a working column with a stale bail-out on the issue,
  which harms nothing: the bail-out means something only while the card is in
  `Needs Human`, and the role picking the item up writes over it. The failure
  that costs a person's attention becomes the one that costs nothing.

  One REST call, unfiltered for the same reason as the review repair, because it
  has to see both sides:

      gh api "repos/<repository>/issues/<issue>/comments?per_page=100" \
        --jq '.[] | "\(.user.login) \(.created_at) \(.body[0:20])"'

  This is not the `Backlog → Ready` gate and does not touch it. An item in
  `Needs Human` was authorised before it got there — it reached a working column
  and stalled — so returning it is resuming work the owner already approved,
  which is why it goes back to a working column rather than to `Ready`. The
  column is chosen by issue type, as the other repairs choose it, rather than by
  reading the one the bail-out comment named: the bail-out names it in prose, and
  a rule that has to parse prose to know where a card goes is a rule that will
  one day put it somewhere else.

- `Needs Human` where the loop bailed out waiting on something and that thing has
  since landed → `In Progress`, or `In Design` if the issue is `type:design`.

  The repair above returns a card when the owner answers. This one returns a card
  nobody has to answer: a bail-out whose reason was a fact about the board rather
  than a question, and the fact has expired. One item bailed because the registry
  it builds on was only on an unmerged pull request; that merged eight minutes
  later, and nothing about the card needed a decision from then on — but the rule
  above waits for a comment the owner has no reason to write. Two more items named
  it as a dependency, so one parked card held a whole column while every tick
  reported `Ready` idle.

  **It keeps the repair above's first guard and replaces its second.** The loop's
  newest comment on the issue must still be a bail-out — recognised by
  `Bailing out:`, from any login `loop.json` lists — because that is what keeps
  work the owner dragged aside from ever being pulled back, and it is as necessary
  here as there. What changes is the second: in place of a comment from the owner,
  that bail-out must carry at least one `Blocked-on: #N` line, which is what says
  its reason was a wait rather than a question. A bail-out without one is not this
  repair's, whatever it says in prose.

  The two are meant to be alternatives, and the shared rule asks the author of a
  bail-out to keep them apart: leave the line off when the work also needs a
  decision. **That is discipline rather than a guard, and it says nothing about
  what the owner does afterwards.** A comment on a waiting bail-out — "approving
  those two now", on exactly the kind of card this repair exists for — makes both
  conditions true at once, by the most ordinary route there is.

  **If a repair above has already moved this card this tick, this one does not
  fire**, whatever the snapshot at the top of the tick still says. The same
  sentence the merge repair carries, for the same reason. Both choose the column
  the same way, so what the overlap would otherwise cost is not a card landing
  somewhere wrong but a `--from` refused — and a refusal is reported as the board
  having moved under the tick, which is a race that did not happen.

  The owner's comment winning is the right way round. It is the more specific
  signal: the reference landing says the wait is over, and a comment on top of it
  may say something about the work that the landing does not.

  **Every reference it names must have landed, not merely closed.** For an issue,
  closed is landed. For a pull request, merged is landed and closed-without-
  merging is not: the work was abandoned, so the thing the bail-out waited for is
  never coming, and resuming would build on groundwork that does not exist. Leave
  the card, and name the abandoned pull request in the report — that is a person's
  call, and it is the one case here where waiting is right.

      gh api repos/<repository>/issues/<ref> --jq '"\(.state) \(.pull_request != null)"'

  A `true` there means the reference is a pull request, and merged is then the
  question rather than closed:

      gh api repos/<repository>/pulls/<ref> --jq .merged

  One call for an issue and two for a pull request, over the one or two references
  a bail-out names. It runs only for cards in `Needs Human` whose newest loop
  comment is a `Blocked-on:` bail-out, which is a small set and usually empty.

  **Move first, comment `Blocker cleared:` second**, naming what landed — the same
  order and the same reason as the repair above. The comment is what spends the
  bail-out: until something newer sits on top of it, a card the owner moves back
  to `Needs Human` on purpose is one this repair drags out again every minute.

  The column is chosen by issue type, as every other repair chooses it, and not
  from the column the bail-out named in prose.

  **A bail-out written before this line existed carries no `Blocked-on:`, so this
  never fires on one.** That is the ordinary cost of a rule that has to be in the
  copy being read, and it is not worth working around: adding the line to an old
  bail-out by commenting again would make that comment the loop's newest, which is
  exactly what stops both `Needs Human` repairs recognising the card at all. Such
  cards want a person to move them, once.

- A claim taken **more than an hour ago** → report it on the issue. Four
  unattended sessions make an abandoned claim likelier than one did, and the
  failure is quiet: a card sits claimed, its column looks busy, and every tick
  walking past it names the login and moves on exactly as it would for a claim
  being worked. An hour is longer than any tick this loop has taken and short
  enough that a night of running does not hide it.

  **Every claimed issue at once, in one call**, rather than an assignee read per
  card. A claim can be anywhere a tick claims from and anywhere a tick died
  before releasing, which is every column but `Backlog` and `Done` — so
  enumerating columns would be both longer to write and more expensive to run:

      gh api "repos/<repository>/issues?assignee=*&state=open&per_page=100" \
        --jq '.[] | select(.pull_request == null)
              | "#\(.number) \([.assignees[].login] | join(", "))"'

  `select(.pull_request == null)` is what keeps pull requests out: the issues
  endpoint returns them too, and every one the Reviewer passed carries the
  owner as an assignee. Reporting those would be reporting the review queue as
  abandoned work, every tick.

  When it was taken is GitHub's answer rather than the loop's, which is what
  keeps this as stateless as the rest of the claim protocol — a tick that has
  never seen the item before can still tell a claim minutes old from one left
  overnight:

      gh api "repos/<repository>/issues/<issue>/timeline?per_page=100" \
        --jq '[.[] | select(.event == "assigned") | .created_at] | max'

  **The report goes on the issue, not only into this terminal.** Four unattended
  sessions is the arrangement this exists for, so a line printed in one of them
  has no reader, and GitHub is the only place the owner and every agent already
  look.

  **Post it once per claim rather than once per issue**: when there is no such
  notice on the issue at all, or when the newest one is older than the
  `assigned` event it is about. Guarding on the notice merely existing would
  report an issue's first abandonment and none of the ones after it.

  Reporting rather than reclaiming, because the loop cannot tell an abandoned
  claim from a slow one — the assignee reads the same either way — and the
  decision belongs where the ambiguity can be resolved.
- A claim on an item in `Needs Human` → **remove it, without waiting the hour,
  and post no notice.** The hour tells an abandoned claim from a slow one, and
  in that column there is no slow one to confuse it with: a bail-out's own order
  is comment, move, release, so an agent still on a card that has reached
  `Needs Human` is a tick that died between the move and the release. Waiting
  would leave the answered-question repair handing cards back to roles that
  cannot take them for an hour, which is the failure that rule exists to prevent.

  A notice would be worse than doing nothing here, because the answered-question
  repair fires only while the bail-out is the loop's newest comment, and a
  notice on top of one silences the owner's answer permanently.

  **Only an agent's claim is removed** — a login `loop.json` lists. Everything else in this column is the owner's:
  self-assigning is how they park work, and stripping that would take the item
  back.

There is deliberately **no** repair moving an item with an open PR out of
`In Progress` or `In Design`. Such an item is indistinguishable from one the
Reviewer has just sent back for fixes, so a blind rule would bounce it straight
to `Agent Review` unfixed — and then do it again every tick, forever. Picking
up an interrupted tick takes the judgement of whoever owns the item, so it
lives in the role files instead.


## The moves and markers `finish` makes

**Every `move` passes `--from`.** `sh <tool> move <issue> <column> --from
<expected>` refuses when the card is not where the caller thought, rather than
overwriting what another agent has just done. Every caller knows which column it
is moving a card out of, so this costs a word at each call site. `--from`
refetches the item list before it resolves the card, unless that list was
fetched seconds ago — a flag that asks whether the board has moved is the wrong
place to economise on asking GitHub.

**A stacked start's `submitted` checks one input first:** the pull request's
base is the branch its token names, the parent's. It is rejected otherwise, with
nothing written, so a stacked start opened against `main` while its parent is
open never reaches review. Anything else that moved during the tick, such as
the parent settling again or merging, is the restack repair's on its next pass.

**A refused move ends a role's tick, and the tick keeps what it made.** The move
is the last thing such a tick does, so by the time one is refused the Reviewer
has already commented its findings and the Engineer has already pushed a branch
and opened a pull request. None of that is lost and none of it is redone: the
pull request is on the issue with its `PR: #<number>` line, the findings are on
the pull request, and whoever owns the column the card is now in reads both.
Release the claim, report the refusal and the column it found, and stop.

**Do not retry, and do not move the card anywhere else.** Something put that card
where it is deliberately — a repair routing a red check, or another agent
finishing the item — and a second opinion arriving a moment late is exactly the
clobber the guard exists to prevent. The release matters more here than
anywhere: the rule above hangs it on the move, and this is the case where the
move is what failed, so a claim left behind is a card nothing will take.

**Bailing out.** When the work needs a decision only the owner can make, do not
guess to keep busy: comment on the issue with precisely what is ambiguous and
what the options are, name the column it should come back to, move it to
`Needs Human` with `--from`, release the claim, discard any branch this tick
started, stop. A branch with an open pull request is kept. A stalled tick that
asks a sharp question beats a merged PR built on a guess.

Comment, then move, then release — in that order, and unlike the
answered-question repair, which moves first. The bail-out comment is what makes
the card recognisable in `Needs Human` at all, so a crash before it leaves a
card nothing can route; the repair's comment only spends a question the card
already carries.

**The comment must open with `Bailing out:` and nothing before it.** That line is
what lets the `Needs Human` repair tell a question apart from every other thing
the loop says on an issue — `PR: #<number>`, a reply to a review — so that an
answer brings the work back and a comment on work the owner parked does not.
Without it the repair can only ask whether the loop has ever spoken, which is
true of anything it has already worked.

**A bail-out waiting on something rather than asking something carries
`Blocked-on: #N` on a line of its own**, one per line, naming every issue or pull
request whose landing is the whole of what it is waiting for.

Not every bail-out is a question. Some are a fact about the board: the groundwork
is on a branch that has not merged, so there is nothing to build against and
nothing for the owner to decide. Such a reason expires by itself, and the
answered-question repair cannot see it expire — it waits for a comment the owner
has no reason to write, so the card sits in `Needs Human` after the thing it
waited for has landed. One card sat there eight minutes after its blocker merged
and would have sat there indefinitely; two more named it as a dependency, so one
parked card held a column while every tick reported it idle.

The line is structured for the reason `Answering <url>.` is: a rule that had to
read the reason out of prose would one day read it wrong, and this file already
refuses to pick a column that way. `#N` is the whole of what a rule needs.

**Carry it only when the blocker clearing is enough on its own.** A bail-out that
also needs a decision must not have one, because the repair below acts on it
without asking anything else — a card returned while its real question still
stands is a guess with a rule behind it, which is worse than the wait. When the
work needs both, ask the question and leave the line off: the owner's answer is
what should bring it back.

