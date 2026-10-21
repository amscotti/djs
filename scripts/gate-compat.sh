#!/usr/bin/env bash
# Real-library compatibility: ws (upgrade + frames) and jose (subtle JWT).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
DJS="$ROOT/djs"
COMPAT="$ROOT/tests/compat"
fail=0

if ! npm ls --prefix "$COMPAT" ws jose >/dev/null 2>&1; then
    echo "installing ws/jose into tests/compat"
    npm install --prefix "$COMPAT" --no-audit --no-fund >/dev/null 2>&1 || {
        echo "FAIL compat install"; exit 1;
    }
fi

check() {
    local label="$1" golden="$2" actual="$3"
    if diff -u "$golden" <(printf '%s\n' "$actual") >/tmp/compat-diff.txt 2>&1; then
        echo "ok   $label"
    else
        echo "FAIL $label"
        sed -n '1,20p' /tmp/compat-diff.txt
        fail=$((fail+1))
    fi
}

out="$("$DJS" -A "$COMPAT/ws_smoke.js" 2>&1)"
check ws tests/golden/compat_ws.txt "$out"

out="$("$DJS" -A "$COMPAT/jose_smoke.js" 2>&1)"
check jose tests/golden/compat_jose.txt "$out"

exit $((fail > 0))
