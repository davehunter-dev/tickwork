# Changelog

Every account runs Tickwork's `main`, so a change reaches every consumer at its
next tick. A major entry is one a consumer or an account has to act on.

## Unreleased

- An issue's pull request is found when the issue is locked. GitHub writes no
  cross-reference onto a locked issue, so with `lockConversations` on,
  `finish --pr` rejected every pull request opened after the lock, and the
  repairs, `feedback`, stacking and the supervisor's watch never saw it. They
  now also read the `PR: <ref>` lines an agent or the owner comments on the
  issue, checking each pull request directly on a cross-reference's terms, and
  `finish --pr` checks the pull request itself. A pull request the owner links
  by hand on a locked issue needs a `PR:` line too.

- The tree is ready to publish: the release design document,
  which cited this repository's item numbers, is gone; Tickwork's own
  `loop.json` turns `lockConversations` on; and a fixture that held another
  repository's issue numbers and ids now holds invented ones.

- Running `gh`, `git` or any command with its output piped no longer depends
  on a dispatch queue thread to read its stderr, so a caller on a Swift
  concurrency thread can no longer wait forever for one. Every such caller
  blocked at once was why the parallel unit tests stalled on the three-core
  hosted macOS runner, which now runs them in parallel again.

- Tickwork's CI runs only on GitHub-hosted runners: the macOS job moves from a
  self-hosted machine to `macos-26` and prints `swift --version`, and
  `actions/checkout` is pinned by commit SHA in both jobs. The package's macOS
  floor rises from 10.15 to 12, which `Date.formatted(date:time:)` already
  needed; the hosted runner's SDK enforces it.

- Tickwork is published under the MIT license, in `LICENSE`, and the Swift
  files no longer carry a per-file copyright header.

- Tickwork has public documentation: `README.md` says what it is and isn't,
  what it needs and its limits; `CONTRIBUTING.md` and `SECURITY.md` say how to
  contribute and how to report a vulnerability. `docs/loop.md` installs over
  HTTPS, with SSH optional, and gains "Trying it first", which runs one tick
  against a scratch repository and board. An existing SSH install keeps working:
  `update` fetches whatever `origin` the clone recorded.

- `.agents/practices.sh` fetches Practices' `main` with `+main:main`, so it
  follows a `main` replaced by unrelated history, such as a fresh snapshot,
  instead of warning and keeping the old one. Its fallback to the last fetched
  `main` when the fetch fails is unchanged.

- `loop.json` takes an optional `lockConversations`. With it `true`, `next`
  claims only issues whose conversation is locked and skips the rest as
  `unlocked`, and `finish --pr` locks the pull request before it writes
  anything else. The owner locks an issue before moving it to `Ready`.
  Tickwork never locks an issue and never unlocks anything. Absent means
  `false`, which changes nothing.

- A pull request counts as an item's only if one of `loop.json`'s agents opened
  it. One a human opens, the owner included, or a stranger's fork, no longer
  sends the card to review or makes agents skip it as `opened-by-another-agent`;
  it stays open for the owner to handle by hand. The supervisor watches only
  agents' pull requests in the owner's review for the same reason.

- Repositories can share one project board. Each consumer reads only its own
  `loop.json` repository's cards, keeps its own board cache, and moves only its
  own card of a number, where it could move another repository's card with the
  same number. The supervisor's board poll reads each repository's cards the
  same way. A numbered card naming no repository is now an error rather than
  taken as the consumer's. `loop.json` is unchanged.

- `tickwork loop` stops interval reconciliations of a dormant repository: one
  whose last `next` passed nothing over that can end without the board
  changing, carried no `MERGE` line and, on an orchestrator login, has no card
  in the design, work, review or parked columns. Board changes and the other
  triggers still wake it, and its status shows `next on a change`. Each interval
  reconciliation read the board uncached, about a hundred GraphQL points, so an
  idle repository spent about 600 an hour; a dormant one spends none, and takes
  no orchestrator turn from active ones. On an orchestrator login a dormant
  repository watches `main`'s checks with conditional REST requests instead, and
  reconciles once when they finish, so a check that goes red after the last
  merge is still filed. See "A dormant repository takes no interval at all" in
  `docs/supervisor.md`.

- A `checks-running` skip's `detail` names each unfinished pull request at its
  head, `owner/name#N@sha`, and `tickwork loop` watches those heads' check runs
  and statuses with conditional requests until they finish. Then the
  repository reconciles once, so a review waiting on its checks no longer waits
  for the login's interval, up to 25 minutes on a login orchestrating five
  repositories. See "Checks a review was passed over for" in
  `docs/supervisor.md`.

- `file-issue` and `decompose` add the issue they file to the board and set it
  to `Backlog` themselves, instead of relying on the project's add workflow, so
  a board whose workflow sends new issues to an intake column still gets the
  loop's issues in `Backlog`. A retry leaves an issue already in a column the
  loop names where it is.

- `file-issue` and `decompose` no longer answer `rejected` when the project's
  add workflow adds the new issue to the board at the moment they do. GitHub
  refuses the second add, and the helper now asks again for the card the
  workflow made, places it as usual and answers `filed`.

- Tickwork works its own board: the root `loop.json` names it, so a supervisor
  given a Tickwork clone treats it as a configured repository rather than a
  workspace, and `.agents/skills/` and `.claude/skills/` carry the `next-task`
  skill. `Tests/names.sh` exempts that one file.

- Selection's second pass: with `stack` set, a tick whose roles found nothing
  takes the first labelled `Ready` card whose one open blocker has a settled pull
  request with a stack that reaches `main`, skipping others as `not-stackable`
  with the condition. The assignment carries `stack: {parent, pullRequest,
  branch, head}`, the claim token an optional last field naming `branch`, and
  `finish submitted` rejects a stacked start's pull request based anywhere else.
  `engineer.md` says how to start stacked work. See "Choosing stacked work" in
  `docs/stacked-pull-requests.md`.

- The restack repair: a stacked pull request, one whose base isn't `main`, no
  longer gets the conflict or behind reason. In `Agent Review` and
  `Human Review` the repairs, and for `In Progress` `next`'s findings, read its
  parent instead and send it back with a `restack` finding, now carrying `onto`
  and `retarget`, once the parent settles at a head it lacks or merges into
  `main`, or with a `stack-broken` finding naming what was seen otherwise.
  `engineer.md` carries the restack procedure. See "Keeping a stack current" in
  `docs/stacked-pull-requests.md`.

- The merge guard: the `MERGE` repair, auto-merge in `finish approved` and the
  agent-approved path act only on a pull request into `main` with no open
  former parent and every merged one contained. An open former parent, or a
  base other than `main`, prints `REPORT #N PR <ref> is held: <reason>`; an
  uncontained merged one sends the card back with a `restack` finding onto
  `main`. Auto-merge set on a pull request the guard later stops is disabled
  (`UNARM`), whoever holds the card, and an agent-approved card in `Agent Review`
  with auto-merge off goes to the owner, on whichever pass first finds it
  unclaimed. A `MERGE` line is landed with the new `tickwork merge <ref>`, which
  reads the guard again and merges only that head. Former bases cost one GraphQL query, refused below `readReserve`, on
  a pull request a merge path would act on and on one in `In Progress`.
  `reviewer.md` checks a stacked or once-stacked diff for a parent's work. See
  `docs/stacked-pull-requests.md`.

- `loop.json` takes an optional `"stack": {"label": "<name>"}`. `check-loop`
  then reads the repository through `gh` and refuses a label that doesn't exist
  or `delete_branch_on_merge` on; without `stack` it stays offline. `decompose`
  copies the label onto each task it files from an issue that carries it.

- Clarify Tickwork's orchestration boundary: delegate engineering reasoning to
  agents where practical, retain essential safeguards, and check this boundary
  in design and review.

- **Major:** the bootstrap is gone. `skills/next-task/bootstrap.sh` is deleted,
  and the skill's body is now
  `git fetch -q origin && sh ~/.cache/tickwork/tool/bin/tickwork next-task`.
  A consumer replaces both committed copies of the skill with it and deletes
  its `bootstrap.sh` copies, and each account installs Tickwork with the lines
  in `docs/loop.md` first. `loop.json`'s `tickwork` and `tickworkRepository`
  are no longer read or checked, so nothing pins a revision: every account runs
  `main`. `instructions/next-task.md` drops its `bootstrap:` front matter, and
  `bin/tickwork` with no build beside it says to run the install lines. Each
  account's old `repo/` clone and 40-hex cache entries are inert, and can be
  removed by hand.
- Tickwork installs once per OS user at `~/.cache/tickwork/tool/`, from a bare
  clone at `~/.cache/tickwork/tickwork.git`, through the new root `install.sh`.
  `tickwork update` fetches that clone's `main` and runs its `install.sh`;
  `tickwork next-task` updates, then prints the tick's header and
  `next-task.md`. The install lines are in `docs/loop.md`, under "What a
  consumer's accounts need", which now asks for an SSH key and `github.com` in
  `known_hosts` instead of `gh auth setup-git`. The bootstrap still works.
- `tickwork loop` runs `update` before every reconciliation's `next`, in place
  of the repository's bootstrap, and reports a failure as `update-failed`
  without stopping. It replaces itself with `tool/bin/tickwork` when that is at
  another path or another revision, so a supervisor the bootstrap started moves
  to the installed tool once it exists. Any path may come first, and a clone is
  a repository when `origin/main` has a root `loop.json`, bootstrap or not.
- The sample `loop.json` moves to `Tests/loop.json`.
- `tickwork loop` no longer stops with "the Git state of … can't be digested"
  when an issue branch's checkout holds an untracked nested repository or a
  symbolic link to a directory or to nothing. It counts those by name and hashes
  only untracked regular files.
- `.agents/practices.sh` clones `practices` over SSH, and points an existing
  cache's `origin` at SSH before each fetch, so an HTTPS cache keeps its commits
  and no HTTPS credential is needed.
- `tickwork loop` launches each child with `--thinking-display summarized` and
  streams its thinking summaries into the log, dim, after a
  `thinking (summary):` lead. If `claude` refuses the flag at startup, the loop
  warns once (`thinking-unavailable` with `--json`), relaunches that child
  without it, and leaves it off until the loop restarts. The child's stderr is
  now always piped: in the plain log and with `--json` each line still reaches
  the supervisor's stderr unchanged.
- `tickwork loop` shows what Claude is doing between its reply text: a dim,
  indented line for each tool call, the top-level session's and its subagents',
  for each failed tool result, and for each subagent or background task's end,
  cut to one line. `--json` and the status block are unchanged.
- The role files no longer carry the owner's writing and testing standards:
  "Commits and PR bodies are plain prose" and "Write for the owner's time" leave
  `next-task.md`, "New behaviour needs new tests" leaves `engineer.md` (and its
  echo in `reviewer.md`), and "Length is not thoroughness" leaves `designer.md`.
  "No AI attribution" becomes "attribution follows `AGENTS.md`". A consumer that
  wants these standards opts into `practices` from its own `AGENTS.md`; Tickwork
  neither fetches nor requires it. Two mechanics are added: `next-task.md` says a
  closing keyword is never used for an issue the change doesn't close, and
  `reviewer.md` says a nameable defect is a finding with `changes-requested`,
  never an aside on `approved`.
- Tickwork's own development opts into `practices`: `AGENTS.md` loads it through
  `.agents/practices.sh`, which `Tests/names.sh` accepts as its second exception.
- `tickwork loop` no longer leaks two file descriptors per `gh` or `git` command.
  After enough commands every launch failed with "Bad file descriptor" and the
  loop backed off indefinitely; every command's pipes are now closed once read.
- `tickwork loop` pins the status block below its log on a terminal, redrawn in
  one write only when its lines or the width change. Claude's text is committed
  a row at a time, and a stderr or event line waits behind its partial row. The
  child's stderr is piped and printed dimmed in the log, and the block names the
  child's current tool and Claude's usage windows. A stop
  leaves the last block in the scrollback; a replacement erases it. `--json`, and
  the plain log for a redirected stdout, `TERM` empty or `dumb`, or a terminal
  that doesn't report its size, are unchanged.
- `tickwork loop` can render that snapshot as the status block's lines: the
  login, its budgets and a line per repository, cut to the width, folded to half
  the rows, and focused on the running child. The entry above draws it. The
  snapshot also keeps the child whose ending stopped the supervisor, so the last
  block names it.
- `tickwork loop` keeps a status snapshot of state it already holds, for the
  terminal display `docs/supervisor-status.md` designs: the login's state, core
  and GraphQL budgets, the running child and what it was launched for, and each
  repository's state, error, last check, last change and next reconciliation. It
  makes no request and changes no event, so `--json` is as it was.
- `tickwork loop` pauses until `x-ratelimit-reset` when a check is refused with
  GitHub's core limit exhausted (`x-ratelimit-remaining: 0`), as it pauses for
  the secondary limit, and says so, instead of reporting `HTTP 403` and backing
  off. `--json` gets a `core-limit` event with `until`.
- `tickwork loop` runs once per operating-system user. A second loop under the
  same user, for any repositories, stops at once with the holder's pid and exits
  1. The lock is `flock` on `~/.cache/tickwork/loop.lock` in the account's home,
  so it is released however the loop ends, and neither Claude's children nor a
  replacement inherit it. Every other verb runs beside a loop as before.
- A tick does and resumes its item in its checkout rather than entering a Git
  worktree, so the branch stays where the next tick can check it out, unless the
  project allows worktrees in its `## Agent loop` section. Subagent worktree
  isolation is unaffected.
- `tickwork loop` prints for a person by default: a line per state change, with
  Claude's reply streamed between them, and nothing for an unchanged round or an
  idle reconciliation. A repeated failure prints once and its recovery once. A
  terminal gets markers and colour; `NO_COLOR` or a redirected stdout gets plain
  text. `tickwork loop --json` keeps the JSON event stream, which adds
  `check-recovered`, `watch-recovered`, `reconcile-recovered` and
  `backoff-cleared` events. A reconciliation whose Git state can't be read no
  longer resets its backoff, so the retries grow as for any other error.
  Children run with `--include-partial-messages`.
- `docs/loop.md` says how to start `tickwork loop`: a snippet that runs the first
  clone's bootstrap and passes every path quoted, and the rules for running it.
  Pass every clone agents work in, put a repository first, never run it beside
  `/loop` on the same login, and bill only the subscription. `Tests/wrapper.sh`
  runs the snippet from the document.
- `tickwork loop` replaces itself when the first path's bootstrap resolves a
  different tool than the one running. It `exec`s the new one with the same
  arguments once no child is running, logging both revisions first, so a
  supervisor following `main` picks up a merge without a restart.
- `tickwork loop <path>…`, the supervisor in `docs/supervisor.md`. It checks each
  repository's board, and on an orchestrator login the pull requests of cards in
  `Human Review`, with conditional requests, and runs a repository's bootstrap
  and `next` only when a check sees a change or an interval comes round. Where
  `next` answers with work it launches one `claude -p "/next-task"` in that
  clone, in its own process group, once `claude auth status` says it bills a
  claude.ai subscription. It classifies how the child ended from the stream's
  fields, pauses the login on a subscription limit or an unclear ending, stops on
  an authentication failure, kills a child at two hours, and parks a repository
  whose assignment comes back twice with no progress. `linkedPullRequests` and
  `linksIssue` take the board's repository as `home`, so the resolver works for a
  board other than the working directory's.
- A line comment is answered only by an `Answering <url>.` line, like every other
  piece of owner feedback. A newer head commit no longer answers it, so a push
  can't bury one before anybody reads it, and `finish --answering` no longer
  rejects the url `next` listed. `unansweredFeedback` drops its `head` argument
  and the commit-date read.
- **One pull request, one owner.** The agent that opened a pull request is the
  only one `next` gives its `In Design` and `In Progress` passes to
  (`opened-by-another-agent` otherwise), and is never given its review
  (`opened-by-this-agent`). The disclosed self-review is gone: a review nobody
  independent can take waits in `Agent Review`. Ownership is read from the
  opener alone, not every commit's author, so the commit listing,
  `authorship-unknown`, the assignment's `disclosesAuthorship` and
  `pullRequest.authors` are removed.
- Every verb reads `loop.json` from `origin/main`, never from the working tree,
  a branch or a pull request's head. `next` no longer compares the two copies,
  since there is only one.
- `loop.json` takes an optional `review.agentApproval: {label, appliedBy}`. Where
  the issue carries the label from the owner or a login in `appliedBy`, the
  review is independent, and the commit it names with `--head` is still the head
  with every check green, `finish approved` submits a real `APPROVE` of that
  commit. It needs `merge.auto` on, and `next`'s assignment shows
  `pullRequest.head`. It hands the pull request to the owner anyway when GitHub's
  `reviewDecision` isn't then `APPROVED`. `next` stops at stage `unsafe-ruleset`
  unless `main` requires one approval, a code owner's review, last-push approval
  and a required check, and skips an approved card as `merging`.
- `loop.json` takes an optional `merge: {auto: true, method: "squash"}`, which
  sets GitHub's native auto-merge on approved pull requests in the board's
  repository. `next` stops at stage `config` when that repository doesn't allow
  auto-merge.
- The board is read only for the columns `loop.json` names, Done excepted, so
  Done and personal columns no longer count toward the hundred-card fetch
  limit. `show` and `working` no longer list columns the loop doesn't name;
  `list`, `head` and `count` refuse Done or such a column; `status` reports a
  card outside them as `(not in a column the loop reads)`.
- `loop.json` takes an optional `workflow` object naming the board's columns
  (`backlog`, `ready`, `design`, `work`, `review`, `ownerReview`, `parked`,
  `done`) and labels (`design`, `epic`). The repairs, `select`, `next`, `finish`
  and the board's display read the names from it, and any key left out keeps
  today's name, so an existing file behaves as before. `check-loop` refuses an
  unknown key without reaching GitHub, and `next` refuses a column the board
  doesn't have.
- **The cut-over.** A tick now runs `next`, does the work, and runs `finish`.
  `instructions/next-task.md` and the three role files say how to judge, and
  no longer name a column, a transition or a marker. Together they come to
  about 340 lines, down from about 1,550. The repairs' reasoning moves to
  `docs/repairs.md`, and selection's to `docs/loop.md`, which also states that
  one login runs one session at a time. To roll back, pin a consumer's
  `loop.json` `tickwork` to `a3c7050b7313eff18bfe1014ff1531d4365cf6d2`, the last
  revision with the prose instructions. The bootstrap is unchanged.
- `tickwork finish --token T <outcome>` ends a tick: it checks the token, the
  outcome and its inputs, writes the comment, move, release and every other
  write the outcome makes in today's order and text, with a hidden marker on
  each comment, and answers `finished`, `refused`, `rejected` or `incomplete`.
  A write counts as done only when GitHub shows it by this login since the
  claim, so running it again after a failure does only what is left. The
  helper verbs `reply`, `file-issue`, `decompose` and the token forms of
  `add-blocker` and `remove-blocker` act on the same token. The instructions
  don't call them yet.
- `tickwork next` starts a tick in one call: it checks `origin/main`'s `loop.json`
  with `check-loop`'s rules, runs the repairs for the orchestrator, takes back
  this login's own interrupted claim, selects, claims and re-checks, and prints
  an assignment, `idle` or `error` as JSON. `next --preview` only reads and
  selects. The instructions don't call it yet. A review is never assigned on
  authorship that could not be fully read.
- Every GitHub call goes through a `BoardProvider`, for the board and its issue
  repository, or a `SourceControl`, for pull requests and commits wherever they
  live, with a fake of each for tests. No verb's behaviour changes. This is the
  first step of `docs/orchestration-in-swift.md`.
- A card's moves are read over GraphQL, with who moved it and from and to which
  column, which is what proves a move. The REST timeline's status change names no
  column and is no longer read.
- `select(from:)` makes step 2's choice of item, role and task as a pure
  function over a tick's cards and their facts, recording every skip with its
  reason. Nothing calls it yet; `next` will.
- The repairs judge only the newest run of each check name. `filter=latest` is
  newest per check suite, so a cancelled workflow run's failure was judged
  beside the pass that replaced it, filing a green `main` as red.
- Tickwork is created from the loop tool of the project that first ran it,
  history kept. The `board` and `check-loop` tools read every project
  coordinate from the consumer's `loop.json`.
- `skills/next-task`, bootstrap version 1: resolves one revision per tick from
  the consumer's `origin/main:loop.json`, builds it into a commit-keyed cache,
  and prints its instructions.
- `check-loop` accepts the optional `tickwork` and `tickworkRepository` keys,
  and refuses one without the other.
- Generic instructions: `instructions/next-task.md` and the reviewer, engineer
  and designer role files, deferring to the consumer's `## Agent loop` section
  for the local bar, the formatter and the project's own gates.
- `repairs` moves a design whose pull request has merged to `In Progress` from
  `In Design` as well as `Human Review`, so a design approved with a comment
  and then merged is no longer stranded.
- The instructions, docs and source comments no longer cite issues by bare
  `#N`. Those numbers were the originating project's, and in a consumer they
  name unrelated issues. Each incident is told in words, and the original
  numbers are in the history before this change.
