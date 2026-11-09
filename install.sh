#!/bin/sh
#
# Install `main` of this account's Tickwork clone as its tool.
#
#   git -C ~/.cache/tickwork/tickwork.git show main:install.sh | sh
#
# `tickwork update` runs it after fetching, and so do the install lines in
# docs/loop.md. It reads nothing from a consumer and takes no arguments.
#
#   ~/.cache/tickwork/
#     tickwork.git/   bare clone, main only
#     tool/           bin/{tickwork,board,check-loop}, instructions/, revision
#     install.lock    held while this builds or switches
#
# 1. Take install.lock, since a person's update can run beside the supervisor's.
# 2. Stop if tool/revision is already main.
# 3. Build main into .staging.<pid>/, whose entry/ alone holds tool/'s layout.
#    A failed build leaves tool/ untouched.
# 4. Swap entry/ in for tool/ with two renames, since macOS has none that
#    replaces a non-empty directory.

set -eu

# How long to wait for another install, in seconds. A first build takes about a
# minute.
lock_wait_limit=900

# Always under HOME, not XDG_CACHE_HOME: the skill line and the account's
# permission rule name ~/.cache/tickwork.
root=$HOME/.cache/tickwork
clone=$root/tickwork.git
tool=$root/tool
lock=$root/install.lock

held=
staging=
reaping=

say() { printf '%s\n' "$*"; }
fail() {
    say "install.sh: $*" >&2
    exit 1
}

cleanup() {
    [ -z "$reaping" ] || rmdir -- "$reaping"
    [ -z "$staging" ] || rm -rf -- "$staging"
    [ -z "$held" ] || rm -rf -- "$lock"
}

lock_holder() { cat -- "$lock/pid" 2>/dev/null || true; }

# take_over <pid>: removes the lock if <pid>, which has died, still holds it.
# Waiters that read the same dead holder would otherwise each remove the lock,
# and a later one would remove the lock an earlier one had just taken. So each
# first claims .reap.<pid>, which only one can hold, and reads the holder again
# under it. Fails if another waiter holds the claim.
take_over() {
    mkdir -- "$root/.reap.$1" 2>/dev/null || return 1
    reaping=$root/.reap.$1
    [ "$(lock_holder)" != "$1" ] || rm -rf -- "$lock"
    rmdir -- "$reaping"
    reaping=
}

# Takes the lock, waiting for whoever holds it. A lock whose holder has died is
# taken over, so a killed install cannot wedge every later one.
acquire() {
    waited=0
    while ! mkdir -- "$lock" 2>/dev/null; do
        holder=$(lock_holder)
        if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null && take_over "$holder"; then
            continue
        fi
        [ "$waited" -lt "$lock_wait_limit" ] \
            || fail "waited ${lock_wait_limit}s for $lock, held by process ${holder:-unknown}"
        sleep 1
        waited=$((waited + 1))
    done
    held=1
    say $$ >"$lock/pid"
}

main() {
    command -v git >/dev/null || fail "git is not installed"
    command -v swift >/dev/null || fail "swift is not installed"
    revision=$(git -C "$clone" rev-parse --verify -q 'refs/heads/main^{commit}') \
        || fail "$clone has no main"

    trap cleanup EXIT
    trap 'exit 130' INT TERM
    acquire

    [ "$(cat -- "$tool/revision" 2>/dev/null || true)" != "$revision" ] || exit 0

    staging=$root/.staging.$$
    old=$root/.old.$$
    rm -rf -- "$staging" "$old"
    mkdir -p -- "$staging/source" "$staging/entry/bin"
    git -C "$clone" archive "$revision" | tar -x -C "$staging/source" \
        || fail "could not extract $revision"
    say "Building Tickwork $revision; a first build takes about a minute." >&2
    swift build -c release --package-path "$staging/source" \
        --scratch-path "$staging/scratch" >"$staging/build.log" 2>&1 || {
        tail -n 40 -- "$staging/build.log" >&2
        fail "the build of $revision failed"
    }
    products=$(swift build -c release --package-path "$staging/source" \
        --scratch-path "$staging/scratch" --show-bin-path)
    cp -- "$products/board" "$products/check-loop" "$staging/source/bin/tickwork" \
        "$staging/entry/bin/" || fail "the build of $revision is missing a product"
    cp -R -- "$staging/source/instructions" "$staging/entry/instructions"
    say "$revision" >"$staging/entry/revision"

    { [ ! -e "$tool" ] || mv -- "$tool" "$old"; } && mv -- "$staging/entry" "$tool" \
        || fail "could not switch $tool to $revision"
    rm -rf -- "$old"
}

# Last, and with stdin closed: `sh` reads this script from stdin as it runs, so
# anything that read stdin would eat the rest of it.
main "$@" </dev/null
