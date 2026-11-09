#!/bin/sh
#
# Check that install.sh, `tickwork update` and `tickwork next-task` install and
# print Tickwork's main.
#
#   sh Tests/wrapper.sh
#
# Against a local bare repository standing in for GitHub, and a stand-in `swift`
# whose "build" writes a `board` that says which revision it was built from. So
# nothing here touches the network, a real board, or a real toolchain, and the
# whole run takes seconds.

set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/tickwork-wrapper.XXXXXX")
trap 'rm -rf -- "$work"' EXIT

failures=0
pass() { printf 'ok: %s\n' "$1"; }
fail() {
    printf 'FAIL: %s\n' "$1" >&2
    failures=$((failures + 1))
}

# check <name> <expected> <actual>
check() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 — expected [$2], got [$3]"; fi
}

# contains <name> <needle> <haystack>
contains() {
    case $3 in
        *"$2"*) pass "$1" ;;
        *) fail "$1 — [$2] not in: $3" ;;
    esac
}

# A home and git configuration of the test's own.
export HOME="$work/home"
unset XDG_CACHE_HOME || true
export GIT_CONFIG_NOSYSTEM=1
mkdir -p -- "$HOME" "$work/remotes" "$work/bin"
cat >"$HOME/.gitconfig" <<EOF2
[user]
    name = Wrapper Test
    email = wrapper@example.invalid
[init]
    defaultBranch = main
EOF2

# The stand-in toolchain. Every build appends the revision it built to
# builds.log, so a test can count them.
cat >"$work/bin/swift" <<'EOF2'
#!/bin/sh
set -eu
package= scratch= show=
while [ $# -gt 0 ]; do
    case $1 in
        --package-path) package=$2; shift ;;
        --scratch-path) scratch=$2; shift ;;
        --show-bin-path) show=1 ;;
    esac
    shift
done
[ -z "$show" ] || { echo "$scratch/release"; exit 0; }
marker=$(cat "$package/marker")
case $marker in broken*) echo "$marker does not compile" >&2; exit 1 ;; esac
mkdir -p "$scratch/release"
printf '#!/bin/sh\necho "board %s: $*"\n' "$marker" >"$scratch/release/board"
printf '#!/bin/sh\necho "$1: fine"\n' >"$scratch/release/check-loop"
chmod +x "$scratch/release/board" "$scratch/release/check-loop"
echo "$marker" >>"$BUILD_LOG"
EOF2
chmod +x "$work/bin/swift"
export PATH="$work/bin:$PATH"
export BUILD_LOG="$work/builds.log"
: >"$BUILD_LOG"
builds() { wc -l <"$BUILD_LOG" | tr -d ' '; }

# Tickwork, with one commit per revision. Each carries the real bin/tickwork and
# install.sh, and a marker the stand-in build bakes into its board.
git init -q --bare "$work/remotes/example-org/tickwork.git"
git clone -q "$work/remotes/example-org/tickwork.git" "$work/tickwork" 2>/dev/null
mkdir -p -- "$work/tickwork/bin" "$work/tickwork/instructions"
cp -- "$repo_root/bin/tickwork" "$work/tickwork/bin/tickwork"
cp -- "$repo_root/install.sh" "$work/tickwork/install.sh"

# tickwork_commit <marker>
tickwork_commit() {
    (
        cd "$work/tickwork"
        echo "$1" >marker
        echo "next-task $1" >instructions/next-task.md
        for role in reviewer engineer designer; do echo "$role $1" >"instructions/$role.md"; done
        git add marker instructions bin install.sh
        git commit -qm "$1"
        git push -q origin HEAD:main
        git rev-parse HEAD
    )
}

last_line() { printf '%s\n' "$1" | sed -n '$p'; }

# --- install.sh and update -----------------------------------------------------

root="$HOME/.cache/tickwork"
installed="$root/tool"
tool_layout() { (cd "$installed" && find . | LC_ALL=C sort | tr '\n' ' '); }
leftovers() { ls -A "$root" | grep -c 'staging\|\.old\|\.reap\|install.lock' || true; }

# update <wrapper>: the verb, with stdout and stderr together and the exit status last.
update() {
    status=0
    sh "$1" update 2>&1 || status=$?
    echo "exit $status"
}

out=$(update "$repo_root/bin/tickwork")
check "update with no clone fails" "exit 1" "$(last_line "$out")"
contains "saying Tickwork isn't installed" "Tickwork isn't installed for this account" "$out"
contains "and where the install lines are" "What a consumer's accounts need" "$out"

out=$(sh "$repo_root/bin/tickwork" working 2>&1 || echo "exit $?")
check "a verb with no build beside the wrapper fails" "exit 1" "$(last_line "$out")"
contains "saying to run the install lines" "run the install lines" "$out"

first_main=$(tickwork_commit installed-1)
before=$(builds)
git clone -q --bare --single-branch --branch main \
    "$work/remotes/example-org/tickwork.git" "$root/tickwork.git"
git -C "$root/tickwork.git" show main:install.sh | sh 2>/dev/null
check "a first install installs main" "$first_main" "$(cat "$installed/revision")"
check "and its board" "board installed-1: working" "$(sh "$installed/bin/tickwork" working)"
check "building once" "$((before + 1))" "$(builds)"
layout=". ./bin ./bin/board ./bin/check-loop ./bin/tickwork ./instructions ./instructions/designer.md ./instructions/engineer.md ./instructions/next-task.md ./instructions/reviewer.md ./revision "
check "tool/ holds only the entry's layout" "$layout" "$(tool_layout)"
check "and nothing is left beside it" "0" "$(leftovers)"

second_main=$(tickwork_commit installed-2)
out=$(update "$installed/bin/tickwork")
check "an update to a new main succeeds" "exit 0" "$(last_line "$out")"
check "and installs it" "$second_main" "$(cat "$installed/revision")"
check "with its board" "board installed-2: working" "$(sh "$installed/bin/tickwork" working)"
check "and tool/ still holds only the entry's layout" "$layout" "$(tool_layout)"
check "with nothing left beside it" "0" "$(leftovers)"

before=$(builds)
out=$(update "$installed/bin/tickwork")
check "an update with nothing new succeeds" "exit 0" "$(last_line "$out")"
check "without building" "$before" "$(builds)"

tickwork_commit installed-unfetched >/dev/null
mv -- "$work/remotes/example-org/tickwork.git" "$work/remotes/away.git"
out=$(update "$installed/bin/tickwork")
check "an update whose fetch fails fails" "exit 1" "$(last_line "$out")"
contains "saying so" "fetching Tickwork failed" "$out"
check "and leaves tool/ as it was" "$second_main" "$(cat "$installed/revision")"
check "running" "board installed-2: working" "$(sh "$installed/bin/tickwork" working)"

out=$(sh "$installed/bin/tickwork" next-task 2>&1 && echo "exit 0" || echo "exit $?")
check "next-task after a failed fetch still succeeds" "exit 0" "$(last_line "$out")"
contains "with the tool installed before it" "This tick's revision: $second_main of Tickwork's main" "$out"
contains "saying the update failed" \
    "The update failed, so this is the tool installed before it; its error is above." "$out"
contains "and its instructions" "next-task installed-2" "$out"
mv -- "$work/remotes/away.git" "$work/remotes/example-org/tickwork.git"

tickwork_commit broken >/dev/null
out=$(update "$installed/bin/tickwork")
check "an update whose build fails fails" "exit 1" "$(last_line "$out")"
contains "printing the build's log" "broken does not compile" "$out"
check "and leaves tool/ as it was" "$second_main" "$(cat "$installed/revision")"
check "running" "board installed-2: working" "$(sh "$installed/bin/tickwork" working)"
check "with the entry's layout" "$layout" "$(tool_layout)"
check "and nothing left beside it" "0" "$(leftovers)"

third_main=$(tickwork_commit installed-3)
out=$(sh "$installed/bin/tickwork" next-task 2>/dev/null && echo "exit 0" || echo "exit $?")
check "next-task updates and succeeds" "exit 0" "$(last_line "$out")"
check "headed by the installed tool" "This tick's tool: sh ~/.cache/tickwork/tool/bin/tickwork" \
    "$(printf '%s\n' "$out" | sed -n 1p)"
check "and the new revision" "This tick's revision: $third_main of Tickwork's main" \
    "$(printf '%s\n' "$out" | sed -n 2p)"
contains "printing the new revision's file" "next-task installed-3" "$out"
case $out in
    *"The update failed"*) fail "a successful update says it failed" ;;
    *) pass "with no failed-update line" ;;
esac

# --- install.lock ------------------------------------------------------------

# A stand-in `sleep` that returns at once, counting its calls in sleeps.log. Its
# first call releases the lock, and any takeover claim, as their holders would.
mkdir -p -- "$work/lockbin"
cat >"$work/lockbin/sleep" <<'EOF2'
#!/bin/sh
echo >>"$SLEEP_LOG"
rm -rf -- "$LOCK" "$ROOT"/.reap.*
EOF2
# A stand-in `cat` whose first read of the lock's pid, with STALE_PID set, says
# STALE_PID: a waiter that read a dead holder before another waiter took over.
cat >"$work/lockbin/cat" <<'EOF2'
#!/bin/sh
if [ -n "${STALE_PID:-}" ] && [ "${2:-}" = "$LOCK/pid" ] && [ ! -e "$STALE_READ" ]; then
    : >"$STALE_READ"
    echo "$STALE_PID"
    exit 0
fi
exec /bin/cat "$@"
EOF2
chmod +x "$work/lockbin/sleep" "$work/lockbin/cat"
export SLEEP_LOG="$work/sleeps.log" LOCK="$root/install.lock" ROOT="$root"
export STALE_READ="$work/stale-read"
sleeps() { wc -l <"$SLEEP_LOG" | tr -d ' '; }

# hold_lock <pid>: the lock as an install running as <pid> leaves it.
hold_lock() { mkdir -- "$LOCK" && echo "$1" >"$LOCK/pid"; }
dead_pid() { sh -c 'echo $$'; }

# lock_update: update with the stand-ins, a fresh count and a fresh stale read.
lock_update() {
    : >"$SLEEP_LOG"
    rm -f -- "$STALE_READ"
    PATH="$work/lockbin:$PATH" update "$installed/bin/tickwork"
}

hold_lock "$(dead_pid)"
fourth_main=$(tickwork_commit installed-4)
out=$(lock_update)
check "an update behind a holder that has died succeeds" "exit 0" "$(last_line "$out")"
check "taking the lock over without waiting" "0" "$(sleeps)"
check "and installs main" "$fourth_main" "$(cat "$installed/revision")"
check "with nothing left beside it" "0" "$(leftovers)"

# This test's own shell stands in for the live holder that took the lock over.
hold_lock $$
fifth_main=$(tickwork_commit installed-5)
out=$(STALE_PID=$(dead_pid) lock_update)
check "an update that read a dead holder after another took over succeeds" "exit 0" "$(last_line "$out")"
check "waiting for the new holder rather than taking its lock" "1" "$(sleeps)"
check "and installs main" "$fifth_main" "$(cat "$installed/revision")"
check "with nothing left beside it" "0" "$(leftovers)"

dead=$(dead_pid)
hold_lock "$dead"
mkdir -- "$root/.reap.$dead"
sixth_main=$(tickwork_commit installed-6)
out=$(lock_update)
check "an update while another waiter takes a dead lock over succeeds" "exit 0" "$(last_line "$out")"
check "waiting for that waiter rather than taking over too" "1" "$(sleeps)"
check "and installs main" "$sixth_main" "$(cat "$installed/revision")"
check "with nothing left beside it" "0" "$(leftovers)"

if [ "$failures" -gt 0 ]; then
    printf '%s check(s) failed\n' "$failures" >&2
    exit 1
fi
echo "all wrapper checks passed"
