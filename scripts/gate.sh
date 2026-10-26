#!/usr/bin/env bash
# One command that runs every machine gate and records evidence under gates/.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
mkdir -p gates .dub
. "$ROOT/scripts/lib-portable.sh"
failures=0
step() {
    local name="$1"; shift
    if "$@" >".dub/gate-$name.log" 2>&1; then
        printf '%s ok %s\n' "$name" "$(date -u +%FT%TZ)" >> "gates/$name.txt"
        echo "ok   $name"
    else
        tail -25 ".dub/gate-$name.log" >&2
        echo "FAIL $name" >&2
        failures=$((failures+1))
    fi
}

step abi ./scripts/check-abi.sh
step no-phase-refs ./scripts/check-no-phase-refs.sh
step build dub build --build=release --force $DJS_DUB_CONFIG
step version ./scripts/check-version.sh
step unittest ./scripts/gate-alloc.sh
step permissions ./scripts/gate-permissions.sh
step integration ./scripts/integration.sh
step express ./scripts/gate-express.sh
step examples ./scripts/gate-examples.sh
step compat ./scripts/gate-compat.sh
step sanitize ./scripts/gate-sanitize.sh
step net ./scripts/gate-net.sh
if ./scripts/diff-node.sh >".dub/gate-diff.log" 2>&1; then
    if grep -q "skipped" ".dub/gate-diff.log"; then
        printf 'diff skipped %s (node missing)\n' "$(date -u +%FT%TZ)" >> "gates/diff.txt"
        echo "skip diff (node not installed)"
    else
        printf 'diff ok %s %s\n' "$(date -u +%FT%TZ)" "$(tail -1 ".dub/gate-diff.log")" >> "gates/diff.txt"
        echo "ok   diff"
    fi
else
    tail -25 ".dub/gate-diff.log" >&2
    echo "FAIL diff" >&2
    failures=$((failures+1))
fi
step soak ./scripts/soak.sh

printf '\n%s gate step(s) failed\n' "$failures"
[ "$failures" -eq 0 ]
