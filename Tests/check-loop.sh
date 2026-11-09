#!/bin/sh
#
# Check that check-loop accepts the sample arrangement and refuses broken ones.
#
#   sh Tests/check-loop.sh
#
# Builds check-loop with `swift build` first. The sample, Tests/loop.json, checked
# beside the root AGENTS.md as check-loop requires, must pass, and each variant
# below must fail naming its problem.

set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/tickwork-check-loop.XXXXXX")
trap 'rm -rf -- "$work"' EXIT

swift build --package-path "$repo_root" --product check-loop >/dev/null
check_loop="$(swift build --package-path "$repo_root" --show-bin-path)/check-loop"

failures=0

mkdir -p -- "$work/sample"
cp -- "$repo_root/AGENTS.md" "$repo_root/Tests/loop.json" "$work/sample/"
"$check_loop" "$work/sample/loop.json" >/dev/null \
    && echo "ok: the sample arrangement passes" \
    || { echo "FAIL: the sample arrangement is refused" >&2; failures=$((failures + 1)); }

# refuses <name> <expected problem> <sed expression applied to the sample>
refuses() {
    mkdir -p -- "$work/$1"
    cp -- "$repo_root/AGENTS.md" "$work/$1/AGENTS.md"
    sed "$3" "$repo_root/Tests/loop.json" >"$work/$1/loop.json"
    if output=$("$check_loop" "$work/$1/loop.json"); then
        echo "FAIL: $1 — accepted" >&2
        failures=$((failures + 1))
        return
    fi
    case $output in
        *"$2"*) echo "ok: $1" ;;
        *)
            echo "FAIL: $1 — [$2] not in: $output" >&2
            failures=$((failures + 1))
            ;;
    esac
}

refuses "an unknown key in workflow" \
    "workflow.labels.bug: not a key it takes" \
    's/"mainRedLabels": \["area:build"\],/"mainRedLabels": ["area:build"], "workflow": {"labels": {"bug": "type:bug"}},/'

mkdir -p -- "$work/labels-only"
cp -- "$repo_root/AGENTS.md" "$work/labels-only/AGENTS.md"
sed 's/"mainRedLabels": \["area:build"\],/"mainRedLabels": ["area:build"], "workflow": {"labels": {"epic": "kind:epic"}},/' \
    "$repo_root/Tests/loop.json" >"$work/labels-only/loop.json"
"$check_loop" "$work/labels-only/loop.json" >/dev/null \
    && echo "ok: a workflow renaming only labels passes without reading the board" \
    || { echo "FAIL: a workflow renaming only labels is refused" >&2; failures=$((failures + 1)); }

mkdir -p -- "$work/columns"
cp -- "$repo_root/AGENTS.md" "$work/columns/AGENTS.md"
sed 's/"mainRedLabels": \["area:build"\],/"mainRedLabels": ["area:build"], "workflow": {"columns": {"parked": "Waiting", "done": "Shipped"}},/' \
    "$repo_root/Tests/loop.json" >"$work/columns/loop.json"
GH_TOKEN=offline "$check_loop" "$work/columns/loop.json" >/dev/null \
    && echo "ok: a workflow renaming columns passes without reading the board" \
    || { echo "FAIL: a workflow renaming columns is refused" >&2; failures=$((failures + 1)); }

# Nothing reads tickwork or tickworkRepository any more. A consumer that still
# names them keeps working, since loop.json's shape changes additively.
mkdir -p -- "$work/retired-keys"
cp -- "$repo_root/AGENTS.md" "$work/retired-keys/AGENTS.md"
sed 's/"owner": "example-owner",/"owner": "example-owner", "tickwork": "main", "tickworkRepository": "example-org\/tickwork",/' \
    "$repo_root/Tests/loop.json" >"$work/retired-keys/loop.json"
"$check_loop" "$work/retired-keys/loop.json" >/dev/null \
    && echo "ok: an arrangement still naming tickwork and tickworkRepository passes" \
    || { echo "FAIL: an arrangement still naming tickwork and tickworkRepository is refused" >&2; failures=$((failures + 1)); }

for value in true false; do
    mkdir -p -- "$work/lock-$value"
    cp -- "$repo_root/AGENTS.md" "$work/lock-$value/AGENTS.md"
    sed "s/\"mainRedLabels\": \[\"area:build\"\],/\"mainRedLabels\": [\"area:build\"], \"lockConversations\": $value,/" \
        "$repo_root/Tests/loop.json" >"$work/lock-$value/loop.json"
    "$check_loop" "$work/lock-$value/loop.json" >/dev/null \
        && echo "ok: lockConversations $value passes" \
        || { echo "FAIL: lockConversations $value is refused" >&2; failures=$((failures + 1)); }
done

refuses "a lockConversations that is not a Boolean" \
    "lockConversations: not true or false" \
    's/"mainRedLabels": \["area:build"\],/"mainRedLabels": ["area:build"], "lockConversations": "yes",/'

# stack reads the repository through gh, so these put a fake one first on PATH.
# It logs each call, answers the label read with FAKE_LABEL as the repository
# spells it (missing for none), and the repository read with FAKE_DELETE.
mkdir -p -- "$work/bin"
cat >"$work/bin/gh" <<'EOF'
#!/bin/sh
echo "$*" >>"$FAKE_GH_LOG"
case $2 in
    */labels/*)
        [ "$FAKE_LABEL" != missing ] && { echo "$FAKE_LABEL"; exit 0; }
        echo "gh: Not Found (HTTP 404)" >&2
        exit 1
        ;;
    *) echo "$FAKE_DELETE" ;;
esac
EOF
chmod +x "$work/bin/gh"
stacked='s/"mainRedLabels": \["area:build"\],/"mainRedLabels": ["area:build"], "stack": {"label": "stackable"},/'

FAKE_GH_LOG="$work/gh.log" PATH="$work/bin:$PATH"
export FAKE_LABEL FAKE_DELETE FAKE_GH_LOG PATH

FAKE_LABEL=missing FAKE_DELETE=true
: >"$FAKE_GH_LOG"
"$check_loop" "$work/sample/loop.json" >/dev/null \
    && [ ! -s "$FAKE_GH_LOG" ] \
    && echo "ok: without stack, the repository is not read" \
    || { echo "FAIL: an arrangement without stack read the repository" >&2; failures=$((failures + 1)); }

mkdir -p -- "$work/stack"
cp -- "$repo_root/AGENTS.md" "$work/stack/AGENTS.md"
sed "$stacked" "$repo_root/Tests/loop.json" >"$work/stack/loop.json"
FAKE_LABEL=stackable FAKE_DELETE=false
"$check_loop" "$work/stack/loop.json" >/dev/null \
    && echo "ok: stack passes with its label present and delete_branch_on_merge off" \
    || { echo "FAIL: a usable stack is refused" >&2; failures=$((failures + 1)); }

FAKE_LABEL=missing FAKE_DELETE=false
refuses "a stack label the repository lacks" \
    "stack.label: stackable is not a label in example-org/example" "$stacked"
FAKE_LABEL=Stackable FAKE_DELETE=false
refuses "a stack label the repository spells in another case" \
    "stack.label: stackable is spelled Stackable in example-org/example" "$stacked"
FAKE_LABEL=stackable FAKE_DELETE=true
refuses "a stack with delete_branch_on_merge on" \
    "stack: example-org/example has delete_branch_on_merge on" "$stacked"

if [ "$failures" -gt 0 ]; then
    echo "$failures check(s) failed" >&2
    exit 1
fi
echo "all check-loop checks passed"
