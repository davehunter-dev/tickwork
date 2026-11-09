# Tickwork

**Self-hosted, autonomous multi-agent software development, coordinated through
GitHub.**

Tickwork runs a repository's backlog as an unattended loop of Claude Code
agents. Designer, engineer and reviewer roles collaborate through GitHub issues,
pull requests and a Projects board, while orchestration routes work and feedback
between them. Each tick takes one role, performs one bounded piece of work,
records the outcome in GitHub and ends.

Roles can be divided between agent accounts or combined on one. Multi-agent
describes the coordinated responsibilities and handoffs across independent
sessions; it does not require every role to run at the same time.

## Why self-hosted?

Tickwork grew out of a desire to make autonomous development practical for
native iOS, macOS and other mobile applications. Native Apple development still
requires a suitably configured Mac with Xcode and the relevant SDKs, and other
platforms have their own build environments. Running agents on hardware you
control puts them beside the tools their projects actually require.

Tickwork also runs on Linux and is used for web development. Its orchestration
is independent of the application platform: each repository supplies its own
configuration, engineering instructions and validation requirements. A
dedicated Mac or Linux machine can supervise one or more repositories without
occupying a developer's primary computer.

## How it works

The GitHub Projects board is the persistent state shared between sessions:

- **Designers** resolve design issues into decisions documented for approval.
- **Engineers** implement approved work and turn merged designs into concrete
  tasks.
- **Reviewers** judge pull requests against their issues and repository rules,
  returning findings to the role responsible for fixing them.
- **Orchestration** handles workflow repairs such as failed checks, merge
  conflicts and owner feedback, then routes the work back to the right role.

Together, these roles can carry owner-approved work through design,
implementation, agent review and human review. Tickwork respects issue
dependencies, can continue with unrelated work while pull requests await
approval, and optionally supports eligible dependent work through stacked pull
requests. Its supervisor watches configured repositories and launches Claude
Code only when there is work to do.

Tickwork itself is the instructions the agents follow and two small Swift tools,
`board` and `check-loop`, which handle mechanics such as choosing and claiming
items, moving cards and recording outcomes. A consuming project describes
itself in `loop.json` and in the `## Agent loop` section of its `AGENTS.md`;
Tickwork names no project.

## Used in practice

Tickwork works its own public backlog: its root `loop.json` points at its board,
and its agents work the issues the owner moves into `Ready`. Beyond its own
development, Tickwork has been used on projects built with Swift, C++,
TypeScript and Next.js, including native applications and web projects. Its
public [issues](../../issues) and
[pull requests](../../pulls) show the
workflow operating on its own development.

That experience is evidence of how the system is used, not a promise that every
task can be completed autonomously. Tickwork is best suited to projects with
clear engineering standards, a maintained backlog and work that can be divided
into reviewable changes.

## Humans remain in control

Tickwork automates the development workflow, not product ownership. It never
takes work from `Backlog`; the owner authorizes work by moving it to `Ready`.
New work discovered or created by agents returns to `Backlog` for triage, and an
ambiguity that requires an owner's decision moves to `Needs Human`.

Nothing merges unless GitHub's rules on `main` allow it. A typical setup
requires the owner's approving review. A repository may instead configure an
agent-approval path, but only explicitly and only where its GitHub rules permit
it.

**You decide what to build. Tickwork keeps the development moving.**

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
and, for Claude Code, `.claude/skills/next-task/`. Then start the supervisor
from the installed tool, with an absolute path to each clone the agents work in:

    sh ~/.cache/tickwork/tool/bin/tickwork loop "/abs/first path" "/abs/other path"

It watches each repository's board and launches Claude Code, one
`claude -p "/next-task"` at a time, only when there is work, so an idle board
costs no model time. It runs in the foreground until stopped.
[`docs/loop.md`, "Or under a supervisor"](docs/loop.md#or-under-a-supervisor)
says what to pass it and what it requires, and
[`docs/supervisor.md`](docs/supervisor.md) is the design.

To run the loop yourself instead, from an interactive Claude Code session in the
repository:

    /loop /next-task

Use one or the other on a login, never both: a login runs one session at a
time. [`docs/loop.md`](docs/loop.md) explains each piece, and the ruleset on
`main` that keeps merging behind your approval.

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
