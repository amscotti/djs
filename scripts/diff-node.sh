#!/usr/bin/env bash
# Differential check: run the same script under Node and DJS, compare stdout and
# exit status after normalising temporary paths. Skips cleanly without node.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
if ! command -v node >/dev/null 2>&1; then
    echo "diff-node: node not installed; skipped"
    exit 0
fi
mkdir -p .dub
cases=(arith path buffer errors timers fs_ops os modules net child crypto v8)
fail=0
for c in "${cases[@]}"; do
    node "tests/diff/$c.js" >".dub/diff-$c.node" 2>&1
    nrc=$?
    ./djs -A "tests/diff/$c.js" >".dub/diff-$c.djs" 2>&1
    drc=$?
    sed -E 's#/tmp/[A-Za-z0-9._/-]*djsdiff[^ "]*#TMP#g' ".dub/diff-$c.node" >".dub/diff-$c.node.n"
    sed -E 's#/tmp/[A-Za-z0-9._/-]*djsdiff[^ "]*#TMP#g' ".dub/diff-$c.djs" >".dub/diff-$c.djs.n"
    if [ "$nrc" -ne "$drc" ]; then
        echo "diff-node: FAIL $c (exit node=$nrc djs=$drc)" >&2
        fail=$((fail + 1))
    elif ! diff -u ".dub/diff-$c.node.n" ".dub/diff-$c.djs.n" >".dub/diff-$c.patch"; then
        echo "diff-node: FAIL $c (stdout differs)" >&2
        sed -n '1,20p' ".dub/diff-$c.patch" >&2
        fail=$((fail + 1))
    fi
done
if [ "$fail" -ne 0 ]; then
    echo "diff-node: $fail case(s) differ" >&2
    exit 1
fi
printf 'diff-node ok %s cases=%d\n' "$(date -u +%FT%TZ)" "${#cases[@]}" >> gates/diff.txt
echo "diff-node: ok (${#cases[@]} cases)"
