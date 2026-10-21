#!/usr/bin/env bash
# Express 4 end-to-end smoke: real npm package tree, real HTTP server.
# Skips (exit 0) when express is not installed and cannot be installed.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
BIN="$ROOT/djs"
APP="$ROOT/examples/express-app"
LOG="$ROOT/.dub/express.log"

if [ ! -d "$APP/node_modules/express" ] && command -v npm >/dev/null 2>&1; then
    (cd "$APP" && timeout 180 npm install --no-audit --no-fund >/dev/null 2>&1) || true
fi
if [ ! -d "$APP/node_modules/express" ]; then
    echo "express gate skipped (express not installed and npm unavailable)"
    exit 0
fi

port=$((3210 + RANDOM % 200))
PORT="$port" "$BIN" -A "$APP/app.js" >"$LOG" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null' EXIT

ready=0
for _ in $(seq 1 100); do
    if curl -sf --max-time 1 "http://127.0.0.1:$port/" >/dev/null 2>&1; then ready=1; break; fi
    sleep 0.1
done
if [ "$ready" -ne 1 ]; then
    echo "express gate: server did not start" >&2
    cat "$LOG" >&2
    exit 1
fi

checks=0
fail=0

static_body="$(curl -sS --max-time 5 "http://127.0.0.1:$port/")"
if printf '%s' "$static_body" | grep -q "static works"; then checks=$((checks+1)); else fail=$((fail+1)); echo "FAIL static" >&2; fi

items="$(curl -sS --max-time 5 "http://127.0.0.1:$port/api/items")"
if printf '%s' "$items" | grep -q '"items":\[1,2,3\]'; then checks=$((checks+1)); else fail=$((fail+1)); echo "FAIL items: $items" >&2; fi

user="$(curl -sS --max-time 5 "http://127.0.0.1:$port/api/user/42")"
if printf '%s' "$user" | grep -q '"id":"42"'; then checks=$((checks+1)); else fail=$((fail+1)); echo "FAIL user: $user" >&2; fi

echoed="$(curl -sS --max-time 5 -X POST -H 'content-type: application/json' -d '{"x":1}' "http://127.0.0.1:$port/api/echo")"
if printf '%s' "$echoed" | grep -q '"received":{"x":1}'; then checks=$((checks+1)); else fail=$((fail+1)); echo "FAIL echo: $echoed" >&2; fi

code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$port/does-not-exist")"
if [ "$code" = "404" ]; then checks=$((checks+1)); else fail=$((fail+1)); echo "FAIL 404: $code" >&2; fi

if [ "$fail" -ne 0 ]; then
    echo "express: $fail failure(s)" >&2
    cat "$LOG" >&2
    exit 1
fi
echo "express: ok ($checks checks)"
