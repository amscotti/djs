#!/usr/bin/env bash
# Smoke-test the example apps: Express and Hono serving the same HTMX/Alpine UI.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
DJS="$ROOT/djs"
LOGDIR="$ROOT/.dub"
mkdir -p "$LOGDIR"
fail=0

check() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$actual" == *"$expected"* ]]; then
        echo "ok   $label"
    else
        echo "FAIL $label (wanted '$expected', got '${actual:0:120}')"
        fail=$((fail+1))
    fi
}

wait_up() {
    local url="$1"
    for _ in $(seq 1 50); do
        if curl -fsS --max-time 1 "$url" >/dev/null 2>&1; then return 0; fi
        sleep 0.1
    done
    return 1
}

run_app() {
    local dir="$1" port="$2" name="$3"
    ( cd "$ROOT/examples/$dir" && PORT="$port" exec "$DJS" -A server.js >"$LOGDIR/example-$name.log" 2>&1 ) &
    APP_PID=$!
    if ! wait_up "http://127.0.0.1:$port/"; then
        echo "FAIL $name did not start"
        cat "$LOGDIR/example-$name.log" >&2
        fail=$((fail+1))
        return 1
    fi
    local index vendor start progress status
    index=$(curl -fsS "http://127.0.0.1:$port/")
    check "$name index" "HTMX · Alpine" "$index"
    check "$name htmx" "hx-post=\"/start\"" "$index"
    vendor=$(curl -fsS "http://127.0.0.1:$port/vendor/htmx.min.js" | head -c 200)
    check "$name vendor" "htmx" "$vendor"
    start=$(curl -fsS -X POST "http://127.0.0.1:$port/start")
    check "$name start" "hx-get=\"/progress\"" "$start"
    sleep 1
    progress=$(curl -fsS "http://127.0.0.1:$port/progress")
    check "$name progress" "%" "$progress"
    status=$(curl -fsS "http://127.0.0.1:$port/api/status")
    check "$name status" "\"pct\"" "$status"
    kill "$APP_PID" 2>/dev/null
    wait "$APP_PID" 2>/dev/null
}

run_app progress-app 3101 express
run_app hono-progress-app 3102 hono

echo
if [ "$fail" -ne 0 ]; then
    echo "$fail example check(s) failed"
    exit 1
fi
echo "examples ok (express + hono)"
