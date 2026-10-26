#!/usr/bin/env bash
# Runs the D unittest suite. runtime.d's allocation-counter unittest asserts
# zero D GC allocations across 1,000 timer create/clear cycles.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
mkdir -p gates .dub
. ./scripts/lib-portable.sh
if dub test $DJS_UT_CONFIG >.dub/alloc.log 2>&1; then
    printf 'gate-alloc ok %s gc_alloc_delta=0 cycles=1000\n' \
        "$(date -u +%FT%TZ)" >> gates/alloc.txt
    echo "gate-alloc: ok"
else
    tail -30 .dub/alloc.log >&2
    echo "gate-alloc: FAIL" >&2
    exit 1
fi
