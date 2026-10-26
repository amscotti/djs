#!/usr/bin/env bash
# Timer churn + async fs soak with a bounded heap delta. Fails above the cap.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
CAP_KB="${DJS_SOAK_CAP_KB:-8192}"
out="$(./djs -A tests/js/fixtures/soak.js)"
printf '%s\n' "$out"
delta="$(printf '%s\n' "$out" | sed -n 's/^heap_delta //p')"
if [ -z "$delta" ]; then
    echo "soak: no heap_delta reported" >&2
    exit 1
fi
if [ "$delta" -gt "$CAP_KB" ]; then
    echo "soak: heap grew ${delta} KiB (cap ${CAP_KB} KiB)" >&2
    exit 1
fi
echo "soak: ok (heap delta ${delta} KiB <= ${CAP_KB} KiB)"
