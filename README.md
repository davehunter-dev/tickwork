# Tickwork

Tickwork runs a GitHub repository's backlog as an unattended loop of Claude Code
agents over a GitHub Projects board. Each tick reads the board, takes one role
(orchestrator, reviewer, engineer or designer), does one thing, such as opening
a pull request or reviewing one, and records it on the board.

**It is** the instructions the agents follow and two small Swift tools, `board`
and `check-loop`, that do the board's mechanics: choosing and claiming an item,
moving cards, and recording outcomes. A project describes itself in a
`loop.json` and in the `## Agent loop` section of its `AGENTS.md`; Tickwork
names no project.

**It is not** an approver. Nothing merges without what GitHub's rules on `main`
require, normally your own approving review. The loop never moves work out of
`Backlog`, so it works only what you have put in `Ready`.

## Requirements

- macOS or Linux
- Swift 6.2 or later, and Git
- [`gh`](https://cli.github.com), signed in with the `project` scope
  (`gh auth refresh -s project`)
- [Claude Code](https://claude.com/claude-code)
- A GitHub Projects board whose Status field has the columns in
  [`docs/loop.md`](docs/loop.md#the-columns)
- For the agents, a GitHub account other than yours, with write access to the
  repository and the board

## Install

Each account installs Tickwork once, under `~/.cache/tickwork/`, from this
repository's `main` over HTTPS. The lines are in
[`docs/loop.md`, "What a consumer's accounts need"](docs/loop.md#what-a-consumers-accounts-need).
The first build takes about a minute, and every tick updates to the latest
`main` before it starts.

## First use

Try it without touching a real project:
[`docs/loop.md`, "Trying it first"](docs/loop.md#trying-it-first). It checks
the sample configuration, then runs one tick against a scratch repository and
board.

**`next` acts on whatever board `loop.json` names.** It claims items, moves
cards, comments, and may merge whatever GitHub's rules on `main` allow, so
those rules are what keep merging behind your approval. Point it only at a
board you're willing to have it change.

## Using it on a project

A repository adds `loop.json` at its root, a `## Agent loop` section in its
`AGENTS.md` naming the checks a change must pass, and the one-line skill in
[`skills/next-task/`](skills/next-task/SKILL.md), at `.agents/skills/next-task/`
and, for Claude Code, `.claude/skills/next-task/`. Then, in Claude Code:

    /loop /next-task

[`docs/loop.md`](docs/loop.md) explains each piece, and the ruleset on `main`
that keeps merging behind your approval.

## Limitations

- **GitHub and Claude Code only.** The board is a GitHub Projects board and
  the agents run in Claude Code.
- **Every account runs `main`.** There are no releases or version tags; a
  merged change reaches every account at its next tick. To pin a version, clone
  your own fork and install from it.
- **One maintainer.** Support is through issues, best effort.

## Documentation

- [`docs/loop.md`](docs/loop.md): how the loop works, installing, and starting it
- [`docs/supervisor.md`](docs/supervisor.md): `tickwork loop`, which launches
  ticks only when a board has work
- [`docs/stacked-pull-requests.md`](docs/stacked-pull-requests.md): building
  on work still waiting for review
- [`CONTRIBUTING.md`](CONTRIBUTING.md) and [`SECURITY.md`](SECURITY.md)

## License

Tickwork is released under the MIT license; see [`LICENSE`](LICENSE).
