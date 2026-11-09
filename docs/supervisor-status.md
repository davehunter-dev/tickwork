# What the supervisor is doing, at a glance

**TLDR.** On a terminal, `tickwork loop` keeps a small status block pinned below
its log: a line for the login, a line for its budgets, and a line per
repository. Each line leads with its state, and each state says whether it
recovers by itself or needs a person. The block is drawn from a snapshot of the
supervisor's own state, so it costs no API request. It changes only when that
state changes, using absolute times rather than countdowns, so nothing redraws
on a timer. The log above it stays exactly as it is, and `--json` and a
redirected stdout are unchanged. The decisions worth checking:
- **One layout for one repository or many.** A shared login header, then one
  line per repository. Per-repository sections repeat login-wide facts and
  crowd the log.
- **A pinned block, erased and redrawn in one write.** No scroll region,
  alternate screen or TUI framework. Claude's text is committed to the log a
  whole row at a time, so a partial line never sits under the block.
- **GitHub's budget is shown from what the supervisor already reads.** Core
  REST is fresh every round, from the headers even a `304` carries. GraphQL
  comes from `next`'s answer and is as old as the last reconciliation. The
  secondary limit can't be seen before it refuses.
- **"Limited" and "paused" are different words.** Limited means a floor holds
  some work back but the supervisor still runs. Paused means GitHub or Claude
  refused, and nothing on the login moves until a stated time.
- **An exhausted core limit becomes a GitHub pause until its reset.** Today it
  reads as a failing check that backs off. This is the one behaviour change.

## What the supervisor knows today

From `Supervisor.swift`, `SupervisorChild.swift` and `SupervisorProcesses.swift`.
Each condition is marked as **recovers** (the supervisor gets out of it
unaided) or **needs you** (only a person ends it).

| Condition | Scope | Held in | Ends |
|---|---|---|---|
| Idle: due for nothing | repository | `dueSince == nil` | recovers |
| Checking: a round of conditional `GET`s, every 15 s | login | `nextRound` | recovers |
| Due, held by a running child, a login pause or the rate floor | repository | `dueSince`, `dueReasons` | recovers |
| Reconciling: fetch, `update`, `next`, which can take a minute on an orchestrator, longer when the update builds | repository | nothing: `reconcile` runs synchronously | recovers |
| Claude running for an assignment or a `MERGE` | login, one child | `child` | recovers |
| Claude past the two-hour limit, SIGTERM sent | login | `child.terminated` | recovers |
| Board or pull-request check failing | repository | `checkFailures`, message only in the event | recovers |
| A watched card's pull requests unreadable | repository, per card | `watchFailed` | recovers |
| Backing off: two failed checks, a retryable `next` error, a transient or crashed child | repository | `backoff.until` | recovers |
| A failed update: the reconciliation goes on with the installed tool | repository | the `update-failed` event | recovers when a fetch or build of Tickwork's `main` succeeds |
| `next` error, `retry: false`, an unknown `schema` | repository | `reconcileFailed` | **needs you**: a change on `main` |
| GraphQL below the read reserve (`next` stage `budget`) | login, reported per repository | the error event | recovers at the reset |
| Core REST below the floor: interval reconciliations wait | login | `rateRemaining`, `rateReset` | recovers at the reset |
| Secondary limit: every check and reconciliation waits | login | `pausedUntil` | recovers |
| Claude's subscription limit: no `next`, no launch | login | `loginPausedUntil` | recovers at `resetsAt` |
| Ambiguous child ending: the same pause, 30 min doubling to 4 h | login | `loginPausedUntil`, `ambiguityPauses` | recovers, probed by the next child |
| Parked: the same assignment twice with no progress | repository | `parked` | **needs you**: release, restart |
| `MERGE` lines set aside | repository | `setAsideMerges` | **needs you**, or a changed set |
| Replacement waiting for the child to exit | login | `replacement` | recovers |
| Stopped: start-time operator error, authentication, a signal, a Git state that can't be digested, replaced | login | the `stop` event, then exit | **needs you**, except replaced |

### Gaps the status needs closed

These are facts the supervisor doesn't keep, or keeps without a way to show
them:
1. **When a repository's checks last succeeded.** A clean round emits nothing,
   so freshness is unknowable today. Without it, a hung `gh` call looks healthy,
   since no subprocess has a timeout.
2. **When its board last changed.** `dueSince` is cleared by the reconciliation.
3. **What happens next, and when.** `wake(at:)` computes only the login's
   soonest time, not each repository's next reconciliation.
4. **That a reconciliation is in progress.** It blocks the supervisor's thread
   with no event before it.
5. **What the child is working on.** The launch event names the repository and
   reason, but not the issue, role and task `next` answered.
6. **Claude's usage during a run.** `rate_limit_event` lines are kept for the
   classifier and read only at exit.
7. **The GraphQL budget.** `next` answers `budget`, and the supervisor never
   reads it.
8. **An exhausted core limit.** A `403` with `x-ratelimit-remaining: 0` and no
   `retry-after` is reported as `HTTP 403`, a check failure, and backs off one
   to ten minutes against a reset GitHub has already named.
9. **The child's stderr reaches the terminal directly.** `SpawnedChild` maps
   only stdout, and anything `claude` writes to stderr would land inside the
   block.
10. **Start is silent.** Fetching every path and reading every board come before
    the `start` event.

The status closes 1–7 and 9. Gap 8 is a behaviour change, below. Gap 10 is left
alone: start takes seconds and ends in a printed line or a `stop`.

## GitHub's budget, without spending any of it

| Budget | Source the supervisor already has | Fresh | Shown as |
|---|---|---|---|
| Core REST, hourly 5,000 | `x-ratelimit-remaining`, `-limit` and `-reset` on every check, `304`s included. Measured: a `304` carries all three with `x-ratelimit-resource: core`. | every round | `core 4,976/5,000` |
| GraphQL, hourly 5,000 | `budget` in `next`'s answer, read at `next`'s start, before the tick's own spending | the last reconciliation | `GraphQL 4,888 at 12:01` |
| Secondary limits | no header reports what is left | — | only when it refuses: a pause |
| Claude's windows | `rate_limit_event`'s `unifiedWindows`, per window `utilization`, `status`, `resetsAt`. Measured on `claude` 2.1.316: one event after each response, with `five_hour` and `seven_day`. | each event while a child runs, and then as of its last event | `Claude 5h 12% 7d 11% at 12:41` |

`gh api rate_limit` would give GraphQL every round, but it is a request made
only for display, so it is rejected. A child's own `next` and verbs spend
GraphQL between reconciliations, and the next one shows it.

**Limited and paused never share a word.**
- **Limited** is a Tickwork floor that holds back some work while everything
  else runs. Core below `rateFloor` holds interval reconciliations until the
  reset. GraphQL below `readReserve` makes `next` refuse reads until the reset.
  Each is printed with its numbers in the warning colour, and says what waits.
  Claude's own `allowed_warning` holds nothing back in Tickwork, so it is shown
  only as a warning on its window, `Claude 5h 91% near limit`, in the same
  colour.
- **Paused** is a refusal, held until a stated time: GitHub's secondary limit,
  an exhausted core limit, Claude's `rejected` window, or an ambiguous ending.
  The login line says `PAUSED until <time>` and why.

"Approaching" uses only those existing floors and Claude's own status. A second
threshold for colour would be a number nothing else uses.

**An exhausted core limit pauses until its reset (gap 8).** A `403` or `429`
carrying `x-ratelimit-remaining: 0` stops every check and reconciliation on the
login until `x-ratelimit-reset`, as the secondary limit does, and the login line
says so. Backing off one minute at a time against a known reset only adds
failing requests and error lines, and a person can't tell the two apart. A
response carrying both signals waits for the later of the two times.

## The block

### Hierarchy

1. **The login line:** whether anything on the login can move. It reads
   `STOPPED`, `PAUSED until <time>: <why>`, `updating to <rev> after Claude
   exits`, or `running`, then the login and the running revision.
2. **The budget line:** core, GraphQL and Claude, each with its age where it can
   go stale. Limited budgets take the warning colour and say what waits.
3. **A line per repository, in argument order:** its name, its state, then
   freshness. The state is the first one that applies:

| State | Marked | Text |
|---|---|---|
| parked | needs you | `parked #N role/task: no progress twice; release the claim, restart` |
| `next` refused, not retryable | needs you | `needs a fix on main: <message>` |
| Claude running here | — | `Claude since T · #N role/task · <tool>` for an assignment; `Claude since T · merging #N, #M · <tool>` for `MERGE` lines, naming each line's issue; `stopping (time limit) since T` |
| reconciling | — | `reconciling since T: <reasons>` |
| backing off | recovers | `retry at T: <last error>` |
| checks or a watch failing | recovers | `checks failing since T: <message>` |
| due and held | — | `due since T: waiting for <Claude in x \| the pause \| the core floor>` |
| idle | — | `idle` |

Then, for every state, `checked T`, which is the last round in which each of
its checks answered. It becomes `last checked T` in the warning colour when a
later round failed. After that come `changed T`, the last page that answered
`200`, the loop's own writes included, and `next T`. Set-aside `MERGE` lines
add `needs you: set aside merge #N` after the state.

**While a repository is backing off, `next T` is the backoff's end and nothing
else,** because `nextDue` holds it until then whatever its interval says. A
failed reconciliation still sets `lastReconciled`, so its interval time can be
earlier, or already past. **Otherwise `next T` is the one of these that applies:**
- for a repository without `orchestrator`, its last reconciliation plus
  `reconciliationInterval`;
- for an orchestrator repository, `nextOrchestratorTurn`, but only on the one
  repository that turn would pick now: the least recently reconciled
  orchestrator repository, not running the child.

A dormant repository, one no interval comes round for (`docs/supervisor.md`),
shows `next on a change`.

The other orchestrator repositories show `next in turn`, with no time. Their
place in the order moves whenever a triggered reconciliation runs, so a
computed time would be wrong as often as right. While the core floor holds, an
interval time earlier than `rateReset` shows as `next after <rateReset>`, since
`intervals(at:)` waits for the reset.

Needs-you states say so in words, with `needs you` in red, so colour is never
the only signal. Recovering states use the warning colour.

**Width.** Each line is cut to one column less than the terminal's width, so it
never wraps, ending in `…`. Any non-ASCII character counts as two columns, which
can cut a line early but never makes it wrap. Lines lead with what matters, so a
40-column terminal still shows each state and its time. Repository names drop
the owner unless two would match, and are padded to the longest, up to 12
columns.

**While Claude runs, the block is about that run.** The repository lines shrink
to two kinds:
- **The active repository's line:** `Claude since T · #N role/task · <tool>`.
- **A line for any other repository only when it needs attention:** a
  needs-you state, or a recovering state, which means backing off, or checks or
  a watch failing.

Idle, due, reconciling and freshness details of the other repositories are left
out, and `+N quiet` stands in for them on one line. The login and budget lines
stay, so a pause or limit across the whole supervisor is always shown. When no
child runs, every repository has its line, as in the table above.

**Height.** The block takes at most half the terminal's rows. Past that, idle
repositories with nothing failing fold into one line, `+3 idle, checked T`.

### Examples

One repository, idle, at 80 columns:

    running · agent · tickwork a02db1fb
    GitHub core 4,976/5,000 · GraphQL 4,888 at 12:01 · Claude 5h 12% 7d 11% at 11:40
    app  idle · checked 12:03:15 · changed 11:58:02 · next 12:05:00

Reconciling:

    app  reconciling since 12:03:16: board changed · checked 12:03:15

Claude running in one repository while another is due, which is routine and so folded away:

    running · agent · tickwork a02db1fb
    GitHub core 4,861/5,000 · GraphQL 4,850 at 12:03 · Claude 5h 14% 7d 11%
    app    Claude since 12:03:20 · #41 engineer/start · Bash · checked 12:04:47
    +1 quiet

GitHub's secondary limit, then a low core budget:

    PAUSED until 12:06:47: GitHub's secondary limit · agent · tickwork a02db1fb
    GitHub core 4,861/5,000 · GraphQL 4,850 at 12:03 · Claude 5h 14% 7d 11%
    app    Claude since 12:03:20 · #41 engineer/start · Read · checked 12:04:47
    +1 quiet

    GitHub core 812/5,000, intervals wait for 13:00 · GraphQL 4,850 at 12:03 · …

Local errors and parking:

    running · agent · tickwork a02db1fb
    GitHub core 4,700/5,000 · GraphQL 4,800 at 12:40 · Claude 5h 31% 7d 23% at 12:38
    app    needs you · parked #57 engineer/address-findings: no progress twice; …
    tools  retry at 12:49:00: fetch failed: Could not resolve host · last checked …

Claude's limit, at 40 columns:

    PAUSED until 14:00: Claude's five_hou…
    GitHub core 4,700/5,000 · GraphQL 4,8…
    app    due since 12:51:03: waiting fo…
    tools  idle · checked 12:52:18 · next…

A stop. The block is erased, the stop line printed, and the last block printed
again as ordinary lines, so the state at the stop stays in the scrollback:

    12:55:02 ⏹️ Stopped: authentication failed (the API answered 401); the claim stays for the next start
    STOPPED at 12:55:02 · agent · tickwork a02db1fb
    GitHub core 4,700/5,000 · GraphQL 4,800 at 12:40 · Claude 5h 31% 7d 23% at 12:54
    app    Claude ended, authentication · #57 engineer/address-findings
    tools  idle · checked 12:54:48 · next 12:58:00

A process killed outright can't do this. Its last block stays on the screen,
and its times stop moving, which is the only sign.

### Rejected layouts

- **A section per repository**, with its budget, child and freshness on lines of
  its own. The budgets, the pause and the one child are the login's, so each
  section repeats them. Three repositories would take a dozen lines away from
  Claude's text.
- **One summary line.** It can't keep each repository's error and freshness
  identifiable while another one runs Claude.
- **The window title.** It is one line, and some terminals hide it.
- **Animation**, such as a spinner or a ticking elapsed time. It redraws on a
  timer and adds nothing an absolute `since T` doesn't say.

## Rendering

**Output.** The log with the block below it is the default and the experience
the design is for. `NO_COLOR` removes colour and markers, as today, and keeps
the block. Only two other outputs exist:
- **`--json`**, for machines: unchanged, one JSON line per event and nothing else.
- **The plain log,** used automatically when stdout isn't a terminal or `TERM`
  is empty or `dumb`. It is a fallback, not a mode a person chooses: it has no
  flag of its own, and no behaviour of its own beyond leaving the block out.

**Drawing.** The block is drawn with the cursor left at the end of its last
line, with no trailing newline. Every write to the terminal becomes one
`write`: carriage return, cursor up the block's height less one, erase to the
end of the screen, then any committed log text, then the block again. The block
is never torn, and anything echoed in the meantime, such as a typed `^C`, is
erased with it. This needs two escape sequences that every terminal emulator
supports, and no library.

**Claude's text is committed a row at a time.** The text arrives as deltas, mostly
without newlines, and a partial line can't sit under a block that will be
erased. So the renderer holds the partial line and commits it at a newline, at
a content block's end, or once it reaches the terminal's width, breaking at the
last space. The text reaches the scrollback at most one row behind the stream.
On a terminal, it is wrapped at the width it had when written. The plain log
still writes the deltas as they come.

**Child stderr goes through the renderer (gap 9).** In block mode the child's
stderr is a pipe, read on a thread of its own and committed line by line in the
dim style. The other modes keep inheriting it, so `--json`'s stdout stays pure.
Every other subprocess already pipes both streams.

**Redraws.** The supervisor publishes a status snapshot at the end of every
`step` and before every reconciliation. Claude's reader thread publishes the
current tool and each `rate_limit_event`. The renderer turns the snapshot into
lines and redraws only when they differ from the lines on screen, or when the
width it reads with `TIOCGWINSZ` has changed. The snapshot holds absolute times,
so an idle supervisor redraws once a round, when `checked` moves, and otherwise
not at all. A running child is polled every second, but the poll redraws
nothing unless something changed.

**Stop and replace.** On `stop`, the renderer erases the block, prints the stop
line, and prints the final block as ordinary lines, headed `STOPPED at T`.
Before `exec`ing a replacement, it erases the block, and the new process draws
its own.

**Threading.** Supervisor events and snapshots arrive on the supervisor's
thread. Claude's text, tool and rate-limit events arrive on the stdout reader's
thread, and stderr on its own. `HumanOutput`'s existing lock guards the held
partial line, the latest snapshot, the child's live activity, and the lines on
screen. Every redraw happens under it, in one write. The supervisor reads
nothing from the renderer.

## What to build

**Status snapshot.** A value type, `SupervisorStatus`, built by a pure
`Supervisor.status(at:)` from the supervisor's own state. It holds:
- the login's state: stopped, paused with its cause and time, replacement
  pending, or running;
- the core budget and its reset, from the last check;
- the GraphQL budget and when `next` reported it;
- the running child: repository, start and termination times, and its
  purpose. That is either an assignment's issue, role and task, from `next`'s
  answer, or a merge's issues, from the `MERGE #<issue> PR <ref>` lines it was
  launched for;
- for each repository: its state from the table above, its current error
  message, last successful check, last change, due time and reasons, and next
  scheduled reconciliation.

The new state is a few dates and strings on `SupervisedRepository`, plus the
assignment summary and GraphQL budget from `nextAnswer`. A `status` seam is
called where the snapshot is published. No event changes, so `--json` is
untouched. Tested over the existing fakes, one test per row of the inventory.

**The renderer.** A pure function from the snapshot, Claude's live activity,
width, height and styling to lines. Each example in this document is a test, at
80 and 40 columns.

**The terminal.** Block mode in `HumanOutput`:
- the erase-and-redraw write;
- committing Claude's text by rows;
- piping the child's stderr in block mode;
- stop and replace;
- forwarding the top-level `tool_use` block's name and `rate_limit_event` from
  `SpawnedChild`'s reader.

Tested against a small screen model in the tests: carriage return, line feed,
cursor up and erase to the end of the screen, applied to a grid. After any
sequence of events, deltas, stderr and snapshots, it asserts that the screen is
the committed log followed by exactly one current block. That covers a delta
split mid-line around a status change, a paragraph longer than the width, a
stop, and a replacement. `docs/supervisor.md`'s "What it prints",
`docs/loop.md` and `CHANGELOG.md` say what changed.

**The exhausted core limit.** Its classifier and the pause, over the fake
GitHub, with the login line naming it.

The snapshot task owns `SupervisorStatus` and comes first. The renderer depends
on it. The terminal task depends on both. The core-limit task depends on
nothing, and the snapshot reads its pause once both have landed.

## For the owner

- **The core-limit pause is a behaviour change** riding on a display design. I
  would ship it, because the display can't tell an exhausted limit from a broken
  check without it. Relabelling the failure while keeping the backoff is the
  smaller alternative.
- **Claude's text is hard-wrapped in a terminal's scrollback** at the width it
  had then. The alternatives are delaying text to whole lines, which stalls a
  long paragraph, or redrawing the partial line in the block on every delta.
- **Narrowing the window can leave a stale copy of the block in the
  scrollback** where the terminal reflows the old lines. Nothing is lost, and
  the next redraw is correct. Avoiding it needs a scroll region, which loses
  Claude's text from the scrollback in some terminals, or the alternate screen,
  which loses it everywhere.
- **`checked` to the second redraws the block once a round,** four times a
  minute. To the minute would redraw once a minute, but would hide a hung check
  for longer.
- **Parking is shown, not endorsed.** The `parked` state and its text show the
  no-progress policy as `docs/supervisor.md` has it today. The owner will assess
  that policy separately after watching the supervisor, and the display follows
  whatever that decides.
