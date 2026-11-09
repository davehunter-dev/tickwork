# A supervisor that wakes a model only for work

**TLDR.** `tickwork loop <path>…` is a new verb in the existing tool that
replaces Claude Code's `/loop` as the outer loop. Every 15 seconds it checks each
repository's board, and on an orchestrator login the open pull requests of cards
in `Human Review`, with conditional requests, which cost nothing while nothing
has changed. When a check sees a change, or a fixed interval passes, it fetches,
updates the account's Tickwork, and calls `next`. The model is woken only
when `next` answers with work: an `assignment`, or an idle answer carrying a
`MERGE` repair line. Then the supervisor launches one fresh
`claude -p "/next-task"` in that repository and waits for it. That tick's own
`next` hands it back the claim the supervisor just took, because `next` resumes a
login's own claim first. So the model runs the unchanged instructions, on the
unchanged selection, under the unchanged claim and recovery rules.

There is no daemon, no state file, no second selection rule and no new
configuration. The decisions worth checking:
- the supervisor claims before launching;
- one model process runs at a time, across all repositories;
- the account's one installed Tickwork runs the supervisor, which replaces itself
  when an update installs another revision;
- a child runs only once `claude auth status` says it will bill the subscription.

`/loop /next-task` stays as it is.

## The command

    tickwork loop <path> [<path>…]

Each path is an absolute path to a clone with an `origin`. A clone whose
`origin/main` has a `loop.json` at its root is a *repository*: the
supervisor checks and reconciles it. Any other clone is a *workspace*, where
agents work on another repository's issues, such as a Tickwork clone for a board
whose tasks change Tickwork. The supervisor only reads a workspace's Git state,
for "No progress" below. Adding a repository or a workspace means adding its path.
The supervisor checks each path at start and refuses to start if any isn't a
clone, or if the boards' pages exceed the check budget below, since either is an
operator error, not a repository to retry. Its start event lists both kinds. It
runs in the foreground until a signal or an authentication failure stops it.

### What it prints

By default, a line per state change and, between them, Claude's reply and a dim,
indented line for what it is doing:

    12:00:41 🚀 example-org/a: launching Claude for an assignment
    Reading the board…
      Bash: Read the issue and its comments
      Agent: Find every caller of parse(_:)
        Grep: parse\(
        Read: Sources/Loader.swift
      task completed (2 tools, 6s)
      Bash: Run the tests
        failed: Exit code 1 · Parser.swift:41: error: expected ';'
    12:06:02 ✅ example-org/a: Claude finished (31 turns, 5m 21s)

Claude's text is streamed as it arrives, without a prefix and never as JSON. An
activity line is printed for each tool call, the top-level session's at two
spaces and a subagent's at four, as `<name>: <detail>`: the input's first
`description`, `file_path`, `pattern`, `url`, `query`, `skill` or `command`, on
one line and relative to the clone, or the name alone. A failed result follows
one level deeper as `failed: <text>`, and a subagent's or background task's end
as `task <status> (<n> tools, <duration>)`. Successful results and subagent text
aren't shown. An activity line ends any partial line of the reply first, and is
cut with `…` at 160 columns, or at the terminal's width while the status block
is drawn. The top-level session's thinking streams like the reply, dim, after a
`thinking (summary):` lead, since it is the API's summary and not the reasoning
itself. `docs/claude-activity.md` records what the stream carries. A
supervisor line is printed for start, launch, a child's end, a pause, a
backoff, a failure and its recovery, parking, a refused thinking flag, a
failed update, replacement and stop. An unchanged
round, an idle reconciliation and an allowed rate-limit event print nothing. A
failure prints once, however many checks repeat it, until a different failure or
its recovery is printed.

On a terminal each line carries a marker and a colour: ▶️ 🚀 🔄 cyan for
starting, launching and replacing; ✅ green for success and recovery; ⚠️ ⏸️ ⏳ 🅿️
yellow for failures, pauses, backoffs and parked work; ❌ ⏹️ red for errors and
stopping. The words say the same without them. With `NO_COLOR` set, or stdout
not a terminal, the text is plain: no escapes and no markers.

**On a terminal, a status block stays pinned below the log:** the login's state,
its GitHub and Claude budgets, and a line per repository, laid out as
`docs/supervisor-status.md` describes. It is redrawn only when one of its lines
or the terminal's width changes, erased and drawn again in one write, so the log
above it is never torn. Claude's text reaches the log a whole row at a time, at
a newline, a content block's end or the terminal's width, so it is wrapped at
the width it had when written. The child's stderr is printed in the log too,
dimmed. A stderr or event line that arrives while Claude's row is partial waits
until that row is whole, or the child exits. On a stop the block is erased, the
stop line printed, and the last block printed as ordinary lines, so the state at
the stop stays in the scrollback; a replacement erases it and draws its own.
`NO_COLOR` keeps the block without colour. Stdout not a terminal, `TERM` empty
or `dumb`, or a terminal that doesn't report its size at the start gets the
plain log alone, with Claude's text streamed as it comes and each line of the
child's stderr passed to the supervisor's stderr unchanged. A size query that
fails later keeps the last size it reported.

    tickwork loop --json <path> [<path>…]

prints instead one JSON line per event, with no human text and no Claude
reply, and the child's stderr passed through to its own. It adds four events so a
reader follows recovery from the supervisor's state: `check-recovered` when a
repository's checks pass after failing, `watch-recovered` when a card's pull
requests are read after a `watch-failed`, `reconcile-recovered` when a
reconciliation succeeds after one reported an error, and `backoff-cleared` when
that success ends a backoff. `thinking-unavailable`, with the child's stderr line
as `detail`, says `claude` refused `--thinking-display`; see "The child".

**How an operator starts it** is one line, once Tickwork is installed for the
account as "What a consumer's accounts need" in `docs/loop.md` describes:

    sh ~/.cache/tickwork/tool/bin/tickwork loop "/abs/first path" "/abs/other path"

A launcher that clones its repositories and installs Tickwork on a first run
ends in that line, passing every path as a quoted argument.

## Detecting work

**Cheap detection and authoritative selection are two steps.** A *check* asks
GitHub whether anything that could make work available has changed. It is a
conditional request that costs nothing when the answer is no. A
*reconciliation* is the full pass below: fetch, update and `next`. Only a
reconciliation selects, claims, repairs or resumes, and it runs only when a check
says something changed or a fixed interval has passed. So an unchanged board is
never read in full twice.

### What each signal costs and sees

Measured against a live board of more than a hundred cards, read-only, on 31
October 2026:

| Signal | Cost | Moves on | Misses |
|---|---|---|---|
| REST `GET /{orgs\|users}/<owner>/projectsV2/<n>/items`, conditional, every page (2 pages of 100) | **0** on `304 Not Modified`: three repeats left the core counter unchanged. One core request per page on `200`. | status moves, assignment (a claim), closing, adding or removing a card, **and comments on a card's issue**. All are in the body. Each item's `updated_at` matched GraphQL's item `updatedAt` on every card, and no Status value was newer than its item, so every move so far moved it. A claim on a card showed in it within two seconds. Each item also embeds its issue's `assignees`, `comments` and `updated_at`. What remains inferred is that the ETag changes whenever the body does; the push test below and stage 1 cover it. | pull request activity, check runs, time passing |
| GraphQL `projectV2 { updatedAt }` | 1 point | status moves, assignment, closing. It equals the newest item's `updatedAt`. | **comments**: every card whose issue changed after its item did changed by a comment and nothing else |
| GraphQL items with `updatedAt` and status, 100 a page | 1 point a page | as the project timestamp | as the project timestamp |
| REST pull requests of one repository, `state=all`, sorted by `updated`, conditional | 0 on `304`; one core request on `200`, for the page of the 100 most recently updated. | reviews, comments, commits, closing and merging (a close or merge moves `updated_at`). On all 7 open or recent PRs checked, `updated_at` was at or after the newest review, comment and head commit. | check runs |
| REST one pull request, conditional | 0 on `304`; one core request on `200` | as the list, for that PR | check runs |
| `next`, a login without `orchestrator` | about 5 GraphQL points and 11 REST requests | everything, authoritatively | nothing |
| `repairs`, the extra part of an orchestrator's `next` | about 2 GraphQL points and 125 REST requests | everything, authoritatively | nothing |

Two corrections to what this design said before:
- **A full read is cheaper than the 100–200 points assumed** (`loop.md`'s figure
  predates reading only the named columns).
- **An orchestrator's `next` is bounded by REST, not GraphQL.** At about 136 REST
  requests, it can't run much more often than every few minutes without eating
  the hourly 5,000 that the ticks themselves need.

**Latency is the cadence.** Every check response says `Cache-Control: private,
max-age=60`, but that doesn't hold a changed answer back. Pushing to an open pull
request at 12:42:30 made the open-PR list answer `200` on the next 3-second
check, at 12:42:31. No card moved during a 22-minute watch of the board, so the
board's own latency is left to stage 1 to confirm. That watch made 158 conditional
requests, every one a `304`, and none was counted.

**Secondary limits are documented, not observable.** GitHub allows 900 REST points
a minute, a `GET` costing one, and 100 concurrent requests. No header reports
how much of that is left, so the only way to measure the limit is to exceed it,
which GitHub warns can ban an integration. What was measured: 120 conditional
board checks in 154 seconds, about 47 a minute, all `304`, with no `403` or `429`
and `X-RateLimit-Used` unchanged in every response's headers. The docs don't say
whether a `304` counts toward the secondary limit, so the budget below assumes it
does.

### The decision

- **One check budget for the login: 30 requests a minute,** a thirtieth of the
  secondary limit and below the rate measured clean. A *round* checks every board
  page of every repository, each with its stored ETag, plus the pull-request
  lists below. Rounds run every 15 seconds, or every 2 seconds per request in
  the round if that's longer, so a round never exceeds the budget. Today's board
  (2 pages) and two pull-request lists make a round of 4: 16 requests a minute.
  Each check asks for the Status field by id (`fields=<id>`), so the column itself
  is in the body rather than only the `updated_at` a move bumps.
- **A supported bound, enforced at start:** board pages across all paths may not
  exceed 15, a 30-second round. Beyond that the supervisor refuses to start and
  says why. The pull-request lists can stretch the round past that, but there is
  at most one per repository that holds a watched PR.
- **A secondary-limit answer** (a `403` or `429` saying so, or carrying
  `retry-after`) stops every check and reconciliation on the login for
  `retry-after`, or a minute without one, doubling while it repeats, as GitHub
  asks. Going faster than 15 seconds buys little anyway: a tick takes minutes and
  children run one at a time.
- **An exhausted core limit** (a `403` or `429` with `x-ratelimit-remaining: 0`)
  stops the same things until `x-ratelimit-reset`, rather than counting as a
  failed check that backs off. A refusal naming both limits waits for the later.
- **A reconciliation whenever:**
  - a page answers `200`, or the page count changes;
  - on an orchestrator login, a watched pull request changes (below);
  - checks a review was passed over for finish (below);
  - a check fails, since a failure is never read as "unchanged";
  - a child exits;
  - `next` answered `nextDelay: now`;
  - the supervisor starts, with no ETags yet;
  - its turn on the login's interval comes round (below).
- **Re-baseline after every reconciliation and every child.** The supervisor
  checks once more and keeps those ETags, so the loop's own claims, moves and
  comments don't trigger a reconciliation each.
- **A retryable `next` error, or a check failing repeatedly,** backs the
  repository's reconciliations off from one minute up to ten. Checks continue.

**The interval is what catches what no check sees.** Those are a red check run
(outside the review below),
activity on a pull request whose card isn't in `Human Review`, a claim gone stale,
and anything the board doesn't show. The orchestrator's repairs exist to turn
exactly those into card moves, and a card move is something every other
login's check sees within 15 seconds. So the orchestrator's interval is the one
that matters.

**The interval is a budget for the login, not a constant per repository.** Every
repository a supervisor runs spends the same login's hourly 5,000 REST requests.
So the interval reconciliations of all the repositories where the login holds
`orchestrator` share one clock: **one every 5 minutes, taken in turn**, the one
reconciled longest ago first. At about 136 requests each, that is about 1,650 an
hour, a third of the limit, however many repositories there are. The other two
thirds are left for the ticks and for reconciliations a check triggers.

| Orchestrator repositories | Interval for each | Interval reconciliations' REST requests an hour |
|---|---|---|
| 1 | 5 minutes | about 1,650 |
| 2 | 10 minutes | about 1,650 |
| 3 | 15 minutes | about 1,650 |

A repository where the login doesn't hold `orchestrator` reconciles every 10
minutes on its own clock, at 11 requests, about 66 an hour. Three of those cost
less than one orchestrator turn.

**A dormant repository takes no interval at all.** The interval is there for
what can move while the board stays as it is, so a repository with nothing of
that kind is left to its checks. It keeps its interval, or its place in the
orchestrators' turn, while:
- its last `next` passed a card over for a reason the board won't announce the
  end of: `claimed` (the claim can go stale), `blocked` (the blocker may be on
  another board), `checks-running`, `not-stackable`, or any reason the
  supervisor doesn't know. `epic`, `opened-by-this-agent`,
  `opened-by-another-agent`, `moved` and `merging` all end in a card move;
- its last `next` carried a `MERGE` line, which waits on the pull request;
- on an orchestrator login, a card sits in the design, work or either review
  column, where the repairs follow claims, checks, conflicts and pull-request
  activity, or in the parked column, where they move a card back when the
  blocker it bailed out on lands, which may be a pull request with no card.

Anything else wakes it as before: a board change, a watched pull request,
finished checks, a child's exit or `nextDelay: now`. The saving is GraphQL more
than REST: the board's item list costs about a hundred points when it isn't
cached, measured at 101 on 8 November 2026, and its cache lasts 180 seconds, so
every interval reconciliation pays it in full. An idle repository without
`orchestrator` was about 600 points an hour, and the orchestrators' turns about
1,200 between them, whether or not anything was open; a dormant one costs none.

**A dormant orchestrator repository watches `main`'s checks instead.** The
interval was what ran the repair that files a check red on `main`, and a merge's
move to `Done` reconciles while `main`'s checks are still running, so a check
going red after the last merge changes nothing the board shows. So each round
reads `main`'s check runs and statuses with conditional requests, as for
[checks a review was passed over for](#checks-a-review-was-passed-over-for).
When an answer changes and nothing in the two is unfinished, the repository is
due once, for `main checks finished`, and the repairs file whatever is red. The
first answers count as a change when nothing in them is unfinished, because the
reconciliation before them may have read `main` while it ran: a merge's
reconciliation can see `main` running and `main` finish red before the first
read. That costs one `next` when a repository first goes dormant after a start.
The answers are kept while the repository has its interval, so the first read
after it goes dormant again compares with the last. It costs two REST requests
a round, `304`s that don't count against the rate limit while `main` is
unchanged, and no GraphQL.

**A floor guards the rest.** Every check's headers carry `X-RateLimit-Remaining`,
for free on a `304`. Below 1,000, a fifth of the limit, interval reconciliations
wait for the reset that `X-RateLimit-Reset` gives. Triggered ones go on, because
they come from real work. The share, the turn length and the floor are named
constants.

### Pull requests in `Human Review`

**The owner acts on a pull request, and only the orchestrator's repairs turn that
into a card move.** An owner review, comment or approval in `Human Review` waits
for the orchestrator's next interval reconciliation, and nothing else on the
login can act on it, because no other login's `next` reads that card. Measured on
one card under `/loop`: the 11:56:29 review moved the card at 12:04:10, and
the 13:52:23 and 13:53:38 comments at 14:12:09, 8 and 20 minutes. Under the
supervisor the wait is the orchestrator's turn: up to 5, 10 or 15 minutes for
one, two or three repositories, half that on average.

**So an orchestrator login also watches those pull requests, and only those.**
- **The watch set** is the open pull requests linked to cards in `Human Review`,
  in repositories where the login holds `orchestrator`. Other logins don't watch:
  a PR change makes no work for them until repairs move the card, which their
  board check then sees within a round.
- **Discovery** needs no configuration. The board check's body carries each card's
  column and `updated_at`. When a card enters `Human Review`, or its item changes
  while there, the supervisor resolves its pull requests with the resolver repairs
  use (`linkedPullRequests`, one timeline request), so a PR in any repository is
  found. It keeps the open ones, each with the `updated_at` the same timeline
  response carries, as its baseline. One only a `PR:` line records is read
  directly, one request, for its state and `updated_at`. Each interval
  reconciliation re-resolves every
  `Human Review` card, 7 requests today, which catches a PR opened later. A card
  leaving `Human Review` drops its PRs, and a repository with none left drops
  its list. The resolver comes from the supervisor's revision, not the
  repository's; a disagreement can only miss or add a trigger, never a decision.
- **The check** is a conditional request for one page of each watched
  repository's pull requests in every state (`state=all`), sorted by `updated`
  newest first, 100 a page, in the same round as the board. A `304` means nothing
  changed. On a `200` the supervisor looks only for watched PRs on the page: one
  whose `updated_at` is newer than its baseline makes that card's repository due
  for a reconciliation, and becomes the new baseline. **Absence means nothing.** A
  PR off the page simply hasn't changed since the hundredth newest. Closing and
  merging need no rule of their own: they move `updated_at`, as everything else
  does (measured on the last five merges, `updated_at` was at or after
  `closed_at`), so a closed or merged PR comes to the top of the page like any
  other change. Changes to other PRs only refresh the ETag.
- **No pagination, and no request per PR.** A watched PR misses the page only if
  a hundred other PRs in that repository change within one round, after it does.
  Then the interval reconciliation catches it, as it catches anything else no
  check sees. So the cost stays one request per watched repository per round.
- **It decides nothing.** The reconciliation is the ordinary `next`, whose repairs
  judge approval, feedback and merge exactly as today.

**Lists, not one request per PR.** Today's 6 watched PRs sit in 2 repositories, so
lists make 2 requests a round where per-PR checks make 6, and a list's count is
bounded by repositories while per-PR grows with the `Human Review` queue. A
list's `200` also fires on unwatched PRs. In the board's repository, with agents pushing, that
is most rounds of a busy hour, but each costs one core request and triggers
nothing. At one `200` a round that is at most 240 an hour per busy repository, a
twentieth of the hourly limit. Per-PR checks would avoid those `200`s and cost a
request per PR in every round's budget instead, which is worse once more than
two or three cards wait in a repository.

**What it buys:** an owner review, comment, commit, close or merge in `Human
Review` reaches repairs within a round, 15 seconds today, instead of up to the
orchestrator's turn. The one wait it can't remove is a child already running on
the orchestrator login, which holds every reconciliation until it exits, as it
does today. Stage 1 logs both waits. Check runs still don't move a PR's
`updated_at`, so the interval stays for them, apart from the review below.

**Restarting loses nothing.** ETags, the watch set, due times and counts live in
memory. A fresh start has none, so its first check answers `200`, every
repository reconciles at once, and the first board body rebuilds the watch set.

### Checks a review was passed over for

**`next` passes an `Agent Review` card over as `checks-running` while its pull
request's checks run, and nothing then turns their finish into a trigger.** A
passing check changes no card and no `updated_at`, so the review waited for the
login's interval: on 7 November 2026 a fix's checks went green at 4:37:44 p.m.
on a login orchestrating five repositories, whose turn comes round every 25
minutes.

**So the supervisor watches those checks until they finish.**
- **The watch set** is what the last `next` of each repository named. A
  `checks-running` skip's `detail` lists each unfinished pull request at its
  head, `owner/name#N@sha`, separated by `, `. Every answer replaces the set,
  keeping the ETags of heads still in it, so a card taken, moved or pushed to
  drops its old head. Only a login whose `next` can review a card ever has one.
  A skip from an older revision, with no detail, is left to the interval.
- **The check** is a conditional request for each head's check runs and its
  statuses, the two reads `next` judges checks from, in the same round as the
  board. Both count toward the round's budget.
- **The trigger** is `checkFacts` finding nothing unfinished in the two answers,
  passing or failing, since a red check is the repairs' to send back. The head
  leaves the set, and its repository is due once, for `checks finished
  owner/name#N`. The reconciliation decides the rest with the same reads, so a
  head can't look finished to the watch and running to `next`, short of a new run
  starting, which `next` names again.

**What it costs, measured on 7 November 2026** against a consumer pull request
whose three check runs were in progress, polled every 15 seconds: of 28 rounds
(56 requests), 4 answered `200`: the first read of each endpoint, a job
completing and the last two completing. The other 52 were `304`, and the core
counter rose only for the `200`s. The finish was seen in the first round after
it. So a head costs its two first reads, then one request each time a run
starts or ends. While running it adds two requests to each round's budget, which
stretches rounds beyond 15 seconds only past 7 requests a round.

**What it buys:** a review whose checks finish reaches `next` within a round,
instead of the login's interval, however many repositories share it. A child
already running in that repository holds it, as it holds every trigger, and the
child's exit makes the repository due anyway.

### Rejected

- **`next` alone, on a short interval.** It is the authority, but an
  orchestrator's pass costs about 136 REST requests, so a short interval spends
  the budget the ticks need. Without `orchestrator` it is cheap enough, but it
  still re-reads an unchanged board on every pass.
- **The GraphQL project or item `updatedAt`.** It costs a point a check and
  misses comments, and an owner answering a `Needs Human` card with a comment is
  one of the ways work comes back.
- **Watching every pull request of every repository.** Nothing names those
  repositories, and most of their PRs make no work for the owner's review.
  Limiting the watch to `Human Review` makes discovery a timeline read per card
  and the request count one list per repository.
- **Webhooks.** They need an endpoint GitHub can reach, or a relay, and a
  delivery that never arrives still needs the interval. The checks are free and
  arrive within one check of a change, so the evidence doesn't justify the
  infrastructure.
- **The notifications API.** What it delivers depends on each account's
  subscriptions, so it can't be the signal for an account that didn't subscribe.
  It wasn't measured.

## One reconciliation

A repository is due for one when a trigger above fires. Of the repositories that
are due, the one due longest goes first, with ties going to argument order. A
reconciliation is:

1. `git fetch -q origin` in the clone.
2. `sh <its own bin/tickwork> update`, which fetches Tickwork's `main` and
   installs it at `~/.cache/tickwork/tool/` when it is new. A failed update is
   an `update-failed` event, and the reconciliation goes on with the tool it
   has. When `tool/` then holds another revision, or the supervisor runs from
   another path, that tool replaces it; see "Revisions".
3. `<its own bin/tickwork> next`. The supervisor reads only `schema`, `kind`,
   `nextDelay`, `repairs`, `error.retry` and the `checks-running` entries of
   `skipped`. A `schema` it doesn't know is a non-retryable error for that
   repository.

What happens next depends on the answer:

| `next` answered | The supervisor |
|---|---|
| `assignment` (fresh or `resumed`) | launches a child, below. The repository is due again as soon as the child exits. |
| `idle` with a `MERGE` line in `repairs` | launches a child too, since `next-task.md` gives the merge to the agent. |
| `idle`, `nextDelay: now` | due again at once: repairs changed the board. |
| `idle`, `nextDelay: backoff` | waits for the next trigger. |
| `error`, `retry: true` (provider, budget) | backs reconciliations off, from one minute up to ten. |
| `error`, `retry: false` (loop.json, config, claim-permission, unsafe-ruleset), an unknown `schema` | reports it, then waits for the next trigger, until a change on `main` fixes it. |

**Claiming before launching is the point.** A tick's `next` resumes its login's
own claim before it selects anything, so the child's `/next-task` gets back
exactly the item the supervisor claimed. The only difference is that it arrives
with `"resumed": true`, and the instructions already handle that: judge what a
previous tick left, which here is nothing. Three properties follow from
existing behaviour:
- **Repairs need nothing new.** `next` runs them when the login holds
  `orchestrator`.
- **No race.** The claim is taken before any model starts.
- **Crash recovery is the existing recovery.** A child that dies leaves its claim,
  and the supervisor's next reconciliation of that repository resumes it into a new child.

**Rejected: `next --preview`, then `/next-task`.** A preview neither claims nor
runs repairs, and it skips the resume step. It would miss interrupted work and
`MERGE` lines, and let another agent take the item between the preview and the
child's own `next`. Fixing those would make preview a second selection path.

**Rejected: handing the child the assignment JSON instead of `/next-task`.** The
child would need instructions that start at step 2. That is a second entry into
the workflow, kept in step with the first by hand.

### Fairness

**One child at a time, across all repositories.** It is the smallest rule that
keeps a login to one session (`loop.md`, "One login, one session at a time"). It
also never runs two models against one subscription limit, and two clones can't
edit the same working tree at once.

"Due longest first" is the whole of fairness. A busy repository is due again the
moment its child exits. But any repository that came due while the child ran has
been due longer, so it goes first, and a busy repository alternates with the
others rather than starving them. An idle repository costs only its free checks
and its interval's reconciliation. An erroring one backs off and reports each
failure. Check rounds run on their own cadence, even while a child runs, so a
change elsewhere is waiting when the child exits. Nothing else is needed.

## The child

    claude -p "/next-task" --output-format stream-json --verbose --include-partial-messages \
      --permission-mode auto --permission-prompts none --thinking-display summarized \
      --name "tickwork <repository>"

It runs in the repository's clone, with stdin from `/dev/null`. It is a fresh
context every time, and the project's own settings, skills, `AGENTS.md` and
memory apply, as they do for `/loop`. With `--permission-prompts none`, anything
that would have asked a person is denied rather than hanging the child. The
instructions already turn a denied permission into `unable`.

**`--thinking-display summarized` is unlisted, so its refusal is handled.** It is
the only way found to get thinking text headlessly. A child that exits non-zero
before writing a stream line, with a first stderr line that starts `error: ` and
names `'--thinking-display`, was refused it. That exit isn't classified: the
supervisor emits `thinking-unavailable`, warns, and launches the same work again
without the flag, as it launches every child until it restarts. The relaunch
can't match, so it retries once, and its exit is classified as any other. See
"If the flag is rejected" in `docs/claude-activity.md`.

**Billing is checked, not assumed.** In the child's environment the supervisor
removes `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN` and the third-party provider
switches (`CLAUDE_CODE_USE_BEDROCK`, `_VERTEX`, `_FOUNDRY`), and never passes
`--bare`, which reads only an API key. Before each launch it runs
`claude auth status --json` in that same environment and launches only when it
reports `loggedIn: true`, `authMethod: "claude.ai"` and
`apiProvider: "firstParty"`. Anything else stops the supervisor with what was
reported. An `apiKeyHelper` in settings would show up here too, as a method
other than `claude.ai`. The check costs no tokens.

### How a child ends

The child streams one JSON object a line. The supervisor classifies by two types,
never reading prose, and shows the text deltas of the top-level session's
`stream_event` lines, which `--include-partial-messages` asks for:
- **`rate_limit_event`:** `rate_limit_info.status` (`allowed`, `allowed_warning`
  or `rejected`), `rateLimitType` (such as `five_hour` or `seven_day`) and
  `resetsAt`, epoch seconds. Measured here on `claude` 2.1.316: an ordinary
  headless run emits one, with `status: "allowed"`, `resetsAt` and each window's
  utilization. The CLI's schema builds the same shape for a refused request, with
  `status: "rejected"` and the reset of the limit that refused it.
- **`result`:** `is_error`, `subtype`, `api_error_status` and `terminal_reason`.

| Ending | Classified as | The supervisor |
|---|---|---|
| any `rate_limit_event` with `status: "rejected"` | subscription limit | pauses all launching and all `next` calls on the login until the latest `resetsAt` among the rejected events. Calling `next` while paused would claim work no child can do. |
| exit 0, a `result` with `is_error: false` | done | logs the result, and the repository is due again. |
| 401 or 403, or `claude auth status` now failing | authentication | stops the supervisor and says why. The claim stays, and is resumed after the operator logs in and restarts it. |
| `api_error_status` 5xx or 529 | transient | the repository backs off, and its next reconciliation resumes the claim. |
| killed by the supervisor at the two-hour limit (SIGTERM, then SIGKILL after 30 seconds) | crash | as transient. |
| anything else: `is_error` with any other status, a 429 without a rejected event, no `result` line, or a death the supervisor didn't cause | ambiguous | pauses the whole login as for a limit, for 30 minutes. The next child after a pause is the probe: ambiguous again doubles the pause, up to 4 hours, and `done` resets it. While the model's availability is unknown, nothing is claimed. |
| the second child in a row that left the same work | stuck | see "No progress", below. |

**Ambiguity pauses rather than retries.** The fields above are the CLI's, and a
plan limit reported some other way must not let the supervisor claim on in every
repository. A false pause costs half an hour; a missed limit claims work that
can't start. `api_error` (`usage_limit_reached`) also appears on the assistant
message, but its schema marks it internal, so the supervisor doesn't read it.

The supervisor never retries inside a tick and never writes to the board. Every
recovery is a later `next` resuming a claim, which is how a dead `/loop` tick
recovers today. On SIGINT or SIGTERM, it forwards the signal to the child, waits
up to 30 seconds, and exits. Whatever the child held is resumed on the next start.

### No progress

**A child is judged by what the next reconciliation finds, not by how it exited.** A child
that exits cleanly can still leave its work where it was. It may report a refused
merge as `next-task.md` asks, or stop before `finish`, or have `finish` answer
`rejected`. Relaunching on that is the one no-progress cycle that costs tokens, so
the supervisor watches for it.

After each child, the supervisor remembers the work it was launched for, with its
evidence:
- for an assignment, the issue, role, task and column, the pull request's `head`,
  and its `findings` (each one's kind and url or detail), which `next` already
  reports;
- also for an assignment, **the issue's Git state in every path,** repositories
  and workspaces alike:
  - every local branch and every `origin` branch named `f/<issue>-…`, with its
    commit. The shared rules name a fresh item's branch that way so an
    interrupted branch can be found. A repository's reconciliation has just
    fetched; a workspace is fetched before it is read;
  - in each path whose `HEAD` is on such a branch, a SHA-256 of
    `git diff HEAD --binary` and of every untracked, unignored path's name and,
    for a regular file, blob hash. A nested repository or a symbolic link counts
    by name alone: `git hash-object` refuses a repository and a link to a
    directory or to nothing;
- for an idle answer, its `MERGE` lines.

If the next reconciliation of that repository returns the same work with the same
evidence, the child made no progress, whatever its exit. Each of these is
progress, even if the child then died before `finish`, so the existing recovery
resumes it as it would today:
- a commit pushed to the pull request moves `head`;
- an answered finding leaves `findings`, because `next` lists only unanswered ones;
- a branch created, a commit made or pushed, or a change written to the working
  tree, with or without a pull request, changes the Git state.

A failed child that changed nothing counts as no progress. A reconciliation
returning anything else clears the count. On the second child in a row with no
progress:
- **The same assignment parks the repository.** `next` would keep handing it
  back first, so nothing else there can run. The supervisor reports the issue and
  both results, stops calling `next` there, and re-checks only after a restart.
  A person decides, as for a card in `Needs Human`, for example by releasing the
  claim.
- **The same `MERGE` lines are set aside.** Later idle answers with only those
  lines count as idle, so the repository goes on polling and claiming other work.
  A changed set of lines is new work.

The other repositories continue either way. An item that comes back in a new
column or with a new task, such as `address-findings` after `submitted`, has
progressed, so the count is per piece of work, not per issue.

This is deliberately not an attempt limit. A tick that keeps pushing and dying is
relaunched each time, as `/loop` relaunches it today; its cost shows in the event
log. Only a tick that leaves no trace is stopped, because relaunching it can
only repeat it. Reading the Git state costs no API request: it is local, apart
from a workspace's fetch.

The supervisor can only read clones it was given. Work in a clone that isn't a
path is invisible, so the start event lists every path, and `loop.md` tells the
operator to pass each clone the agents work in.

**Rejected: no threshold until a pull request exists.** A fresh item whose tick
exits cleanly without touching Git, for example because `finish` answered
`rejected`, would then be relaunched forever. That is the token cycle the rule
exists to stop, and the Git state tells the two cases apart.

The two-hour limit and the 30-second grace are named constants. A limit of two is
the smallest that tolerates one crash, or one interrupted tick, without
relaunching a tick that can't progress forever.

### Usage limits, measured before rollout

Whether a headless tick costs the subscription's five-hour and weekly limits the
same as an interactive one is a question for stage 1, not something this
document asserts. Every child's result carries `usage`, `modelUsage`,
`num_turns`, `duration_ms` and `total_cost_usd`, which is notional on a
subscription. The supervisor logs them on its `--json` event line. Stage 1 compares those
numbers, and the account's usage page before and after, with the same kinds of
tick run under `/loop`.

## Revisions

**One installed Tickwork runs everything on the account.** Each OS user has one
clone, `~/.cache/tickwork/tickwork.git`, and one tool, `~/.cache/tickwork/tool/`,
which `install.sh` builds from that clone's `main`. Every reconciliation runs
`update` before `next`, as every tick runs it through `tickwork next-task`, so
`next` and the child's `/next-task` use the same revision. A reconciliation runs
only when no child is running, so nothing else is using the tool when an update
switches it.

**The supervisor replaces itself from `tool/`.** After each update, if
`tool/bin/tickwork` exists and either its path isn't the one the supervisor runs
from or `tool/revision` isn't its revision, the supervisor `exec`s it with the
same arguments, but only between children, never with one running. The path
comparison is what moves a supervisor started from any other copy of the tool
onto `tool/`. A build no installer made has no revision beside it: it runs the
installed tool's verbs and never replaces itself.

**What the two sides share is small and already versioned.** It is `next`'s JSON
(`schema: 1`) and `claude -p "/next-task"`. A revision that changes either is
caught as an unknown `schema`, which disables that repository with a message
rather than misreading it.

## What it adds, and what it does not

The verb is one new file in `BoardCore` plus its tests. Polling and the table
above work over a protocol for "run this command in this directory", so the
tests use fakes, as the board verbs do. The verb holds no state on disk: due
times, backoffs and no-progress counts live in memory, and losing them on a restart
is harmless, because the board and the claims carry everything that matters.

It does not add a daemon or launchd job, a database or state file, a
configuration file or flags for cadence, a scheduler, a registry of agents or
repositories, a root repository, submodules, concurrency between children, or any
change to `next`, `finish` or the role files.

## Risks

- **A `/loop` session and the supervisor on the same login break the
  one-session rule.** Nothing enforces it, as today; only a second supervisor
  under the same user is refused. The supervisor's start
  message says so.
- **`--permission-prompts none` can deny something a person would have
  allowed.** The tick finishes `unable` and says what was denied, which is the
  signal to widen the project's permission rules.
- **A child left behind by a killed supervisor keeps working,** and a restarted
  supervisor that resumes the claim would race it. The child runs in its own
  process group, which the supervisor kills on every exit it can catch. After a
  `SIGKILL` it can't, and the operator stops the stray `claude` first, as they
  would a stray `/loop` session today.
- **Rate limits on the subscription are shared with the operator's interactive
  use.** That is the reason the pause stops claiming as well as launching.

## Stages

1. **One repository, one day,** beside nothing else on that login. Check that a
   claimed item comes back as the child's assignment in every column, including
   review. Measure tokens and limits per tick against `/loop`, and verify the
   auth refusal by setting `ANTHROPIC_API_KEY` in the supervisor's environment.
   Log, for each card move, comment, claim and close, the time until a check first
   answers `200`. That settles the board's latency, which the read-only study
   above could only measure on a pull request. Log, for each owner action in
   `Human Review`, the time to its trigger and to the card move, and how long a
   running child held it.
   **Verify the limit path on purpose.** Every event reports the five-hour
   window's utilization. When it passes 0.9, keep launching minimal headless
   requests until one is refused, keep that stream as the test fixture for the
   classifier, and check that the login paused until its `resetsAt` and resumed.
   It spends only the end of a window that is nearly gone.
2. **Two repositories,** to show fairness and a self-`exec` after a merge to
   `main`.

## Tasks

1. **`tickwork loop`: detection and reconciliation.** The verb, path checks
   (repositories and workspaces), the login's
   check budget and its start bound, the conditional board checks and their
   ETags, the `Human Review` watch set with its baselines and `state=all` pages,
   the secondary-limit pause, the triggers and intervals, the per-repository
   update and `next`, the answer table, due-longest-first and the backoff,
   over fakes. The child launch is a stub that records what it was asked to run.
2. **The child.** Environment scrubbing, the `claude auth status` gate, the
   launch, stream classification, the limit and ambiguity pauses, the
   no-progress rule with its evidence, including the issue's Git state in every
   path, the time limit and signal forwarding.
3. **Self-update.** `exec` of the newly installed tool between children.
4. **`loop.md`, "Starting it":** the launch snippet, passing every clone agents
   work in, the one-session rule restated for the supervisor, and stage 1's
   measurements recorded once known.

Task 2 depends on task 1, and task 3 on task 1. Task 4 can follow task 2.
