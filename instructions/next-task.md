---
description: Run one tick of the agent loop — read the board, take one role, do one thing
---

One tick: `next` gives you one item, you do it, `finish` records what you did.
Never two items.

**The contract: you approve only on the path `loop.json` configures, and nothing
merges without what GitHub's rules require.** A ruleset on `main` requires a code
owner's approval. Without `review.agentApproval` that is the owner alone, and no
agent can reach it. The loop can generate and judge work; only the owner, or the
path they configured, authorises it.

**One revision for the whole tick.** `tickwork next-task` printed this file and,
above it, `This tick's tool:` and `This tick's revision:`. Every `sh <tool> …`
below uses that path, and role files come from it too, so nothing in the
checkout changes the rules this tick follows. If it printed no instructions,
report what it said and end.

## 1. Ask for an item

    sh <tool> next [--roles reviewer,engineer,designer,orchestrator]

`/next-task` alone means all four; `/next-task engineer reviewer` passes those.
`next` checks `loop.json`, runs the repairs if this tick holds `orchestrator`,
takes back this login's own interrupted claim, chooses, claims, and answers in
JSON:

- **`idle`:** report it and end the tick.
- **`error`:** report its `stage` and `message` and end the tick.
- **`assignment`:** the item is claimed and yours. Keep its `token` exactly as
  printed; every later verb takes it.

`"resumed": true` means a tick of yours died holding this item. Judge what it
left, using `task` and `pullRequest`, rather than starting again.

**A `MERGE` line in `repairs` is yours to merge,** whatever the answer: the
repairs print it rather than merge. `MERGE #<issue> PR <ref> is clean` means
the owner approved it and GitHub says it can land, so run `sh <tool> merge <ref>`,
never a bare `gh pr merge`: the verb reads the merge guard and `clean` again and
merges only the head it read them on. If it refuses, report what it said and
move on.

## 2. Read the rules for this item

Read `AGENTS.md` first, every time. Its `## Agent loop` section is the project's
half of these rules: the local bar a change must pass, the formatter, and any
gate of the project's own. Then:

    sh <tool> instructions <role>

with the assignment's `instructions` value. The role file says how to do each
`task`.

## 3. Do the task

The assignment carries what you need to know about the item: `issue`, `task`,
`pullRequest`, `findings` (with the url of each one to answer), and `outcomes`.
Read the issue body and every comment on it before you start; a later comment
overrides earlier text.

The helper verbs make the mid-tick writes against your claim. Each answers in
JSON, and running one again does nothing twice:

| Verb | For |
|---|---|
| `reply --token T --answering URL… --body-file F` | Answering owner feedback on the pull request without finishing |
| `file-issue --token T --key K --title … --body-file F [--label L]…` | A gap found along the way, filed for the owner to triage |
| `decompose --token T --key K --title … --body-file F [--label L]…` | One task written from a merged design |
| `add-blocker` / `remove-blocker --token T --blocker N` | Recording what the item waits on |

`--key` names the issue you mean to file, such as `gap-socket-timeout`, so a
retry returns the issue already filed instead of filing it twice.

## 4. Finish

    sh <tool> finish --token T <outcome> [--pr <ref>] [--new] [--body-file F]
                     [--answering URL]… [--on N]…

Pass one of the assignment's `outcomes`. `finish` writes the comments with
their markers, moves the card and releases the claim. It answers:

- **`finished`:** done.
- **`rejected`:** an input was wrong and nothing was written. Fix it and run it
  again.
- **`incomplete`:** a write failed part-way. Run the same command again; it
  does only what is left.
- **`refused`:** the card or the claim moved under you. Report it and stop; do
  not retry or work around it.

## 5. Report

Say what you did, then the revision, `budget`, `skipped` and `notes` from
`next`'s answer, and `finish`'s answer. `nextDelay` is `now` after a tick that
did something, and `backoff` otherwise: a doubling wait from one minute to half
an hour.

## Shared rules

**Never wait for CI.** Open the pull request, finish, and end the tick. The
repairs read the checks every orchestrator tick and send a red one back. What
you stand behind is the local bar, green, here.

**Branch only for fresh work:** `f/<issue>-<short-slug>` off an up-to-date
`main`, with the number first so an interrupted branch can be found. An item
with an open pull request continues on its branch (`gh pr checkout <N>`). The
Reviewer doesn't branch.

**Do and resume the item in this checkout.** Don't move the tick into a Git
worktree, such as with Claude Code's `EnterWorktree`: a branch a worktree holds
can't be checked out here, so the tick that resumes the item can't reach it.
A project whose `AGENTS.md` allows worktrees in its `## Agent loop` section has
opted out of this rule.

**Stage what you changed, by name.** Never `git add -A` or `git add .`; a tick
leaves scratch files behind, and a blanket stage takes them.

**Attribution in commits, pull requests and issues follows `AGENTS.md`.**

**A closing keyword closes.** GitHub links and closes the issue a `Closes`,
`Fixes` or `Resolves` names, and moves its card, so never use one for an issue
the change doesn't close, even to say a proposal would retire it: write
"retire". Before finishing, check the pull request's `closingIssuesReferences`
names only what it closes.

**When you can't go on, finish with the outcome that says why:**
- **`needs-human`:** a decision only the owner can make. The body says
  precisely what is ambiguous, the options, and which you'd pick. Don't guess
  to keep busy.
- **`blocked --on N…`:** waiting on something landing and nothing else, such as
  groundwork on an unmerged branch. The card comes back when every `N` lands.
  If it needs a decision too, use `needs-human`.
- **`unable`:** a broken environment or a denied permission, not a product
  question. Say what failed. Don't work around a policy.

Discard any branch this tick started; keep one with an open pull request.

**Gaps found along the way.** One that blocks the acceptance criteria is a
`needs-human`. Otherwise search open issues, and if it isn't filed, file it
with `file-issue`, stating the gap rather than the fix, with a `type:` label
and whatever else `AGENTS.md` asks. Filing never changes what this tick does:
finish the item as specified. Wanting to file more than two or three means the
item was mis-scoped, which is a `needs-human`. Say in the PR body what you
knowingly left out.
