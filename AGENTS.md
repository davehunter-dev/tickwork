Before other work in a session, run `sh .agents/practices.sh` and follow what
it prints. Where they differ, this file wins over it, and an approved issue
wins over both, except that no layer weakens a check to merge. If it fails,
report why and stop.

# Tickwork

How agents work a GitHub Projects board: the `next-task` instructions, the
three role files, and the `board` and `check-loop` Swift tools. Each account
installs it once, under `~/.cache/tickwork/`, and projects run it through the
one-line skill in `skills/next-task/`. See `docs/loop.md`.

## It names no project

Nothing in Tickwork's code, instructions or documentation names a project,
repository, board number, login, credential or machine path, and CI fails if a
project name appears. Everything project-specific comes from the consumer's
`loop.json` and from the `## Agent loop` section of the consumer's `AGENTS.md`.

The one exception is the root `loop.json`. Tickwork is a consumer of itself:
that file holds the coordinates of Tickwork's own board, as `CODEOWNERS` holds
its owner, and it makes a clone given to a supervisor a configured repository.
Nothing in the tool reads it except as a consumer's `loop.json`.

`Tests/loop.json` is a sample. The unit tests read their coordinates from it,
and CI runs `check-loop` against it. It acts on no board.

## Orchestration boundary

**Orchestrate agents; do not duplicate their capabilities.** Tickwork selects
work, assigns roles, coordinates transitions and enforces essential safety
boundaries. Before adding logic that reasons through an engineering problem,
ask whether an existing agent can handle it with its tools and judgment.
Prefer a clear agent task, constraints and verification over deterministic
machinery that anticipates every case. Keep code where safety, reliable state,
coordination or demonstrated efficiency requires it. This applies to Tickwork's
orchestration design, not to ordinary engineering in consumer projects; never
weaken merge checks or authorization to simplify the orchestrator.

## Changing it

- **Swift** for anything substantial, POSIX `sh` for `install.sh` and the
  wrapper, and no Python or JavaScript.
- **Warnings are errors.** Fix a warning; do not suppress it.
- **`loop.json`'s shape changes additively.** Every consumer runs `main`, so
  each must keep working at the next tick.
- **`CHANGELOG.md` gets its entry in the same pull request**, under
  `Unreleased`.

## Agent loop

- **The local bar:** `swift test`, `sh Tests/wrapper.sh`, `sh Tests/check-loop.sh`
  and `sh Tests/names.sh`, all green.
- **The formatter:** `swift format --in-place --recursive Package.swift Sources Tests`
  before committing.
- **The project's gates:** none beyond the shared instructions.
