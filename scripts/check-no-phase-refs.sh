#!/usr/bin/env bash
# Fail if source, tests, or the JS prelude mention plan phases or task IDs.
# The plan is a planning artifact; code must stand on its own.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGETS=("$ROOT/src" "$ROOT/tests" "$ROOT/js")
EXISTING=()
for t in "${TARGETS[@]}"; do [ -d "$t" ] && EXISTING+=("$t"); done
[ ${#EXISTING[@]} -gt 0 ] || { echo "check-no-phase-refs: no source dirs yet (ok)"; exit 0; }

PATTERN='Phase[[:space:]]+[0-9]|phase-[0-9]|PHASE_[0-9]|Plan[[:space:]]+phase|Task[[:space:]]+[0-9]+'
# Only regular files: -R also opens FIFOs (fs tests create them under
# tests/) and blocks forever on the open.
if find "${EXISTING[@]}" -type f -not -path '*/build/*' -not -path '*/.dub/*' -print0 \
  | xargs -0 grep -nE -- "$PATTERN"; then
  echo "check-no-phase-refs: FAIL — remove phase/task references from code, tests, and comments" >&2
  exit 1
fi

echo "check-no-phase-refs: ok"
