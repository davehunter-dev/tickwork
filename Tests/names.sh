#!/bin/sh
#
# Fail if a project name appears anywhere in the tree.
#
#   sh Tests/names.sh
#
# Tickwork names no project: everything project-specific comes from the
# consumer's loop.json and AGENTS.md. This keeps one from creeping back in. It
# reads what git tracks or would, so ignored build products do not count. The
# patterns are split so that this file does not match itself.
#
# Three files are exceptions, because each has to name the owner:
# `.github/CODEOWNERS` names the owner whose review `main` requires, and GitHub
# takes an owner only as a login or a team. `.agents/practices.sh` is the
# owner's practices loader, committed verbatim, and fetches their repository by
# its URL. The root `loop.json` is Tickwork's own board, which its loop works.

set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

found=$(git -C "$repo_root" grep --untracked -n -i -I -e 'Basement''54' -e 'dave''hunter' -- . ':!.github/CODEOWNERS' ':!.agents/practices.sh' ':!loop.json' || true)
if [ -n "$found" ]; then
    printf '%s\n' "$found" >&2
    echo "a project name appears in the tree; take it from loop.json instead" >&2
    exit 1
fi
echo "no project names in the tree"
