#!/usr/bin/env bash
# Long-running stress harness for soak and overnight runs.
#
#   overnight-stress.sh <hours> [label]
#
# Cycles a timing-sensitive battery (watch, async fs, memory, net, tls) and,
# periodically, the full integration suite, the net gate and a small
# AddressSanitizer pass. Every cycle rewrites
# .dub/overnight/status-<label>.txt; failures are logged with their output to
# .dub/overnight/fail-<label>-<cycle>-<name>.log. The append-only log is
# .dub/overnight/stress-<label>.log. Exits non-zero if anything failed, so a
# CI-style consumer can alarm on it.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
. "$ROOT/scripts/lib-portable.sh"

HOURS="${1:?usage: overnight-stress.sh <hours> [label]}"
LABEL="${2:-run}"
case "$HOURS" in
    ''|*[!0-9]*|0) echo "overnight-stress: hours must be a positive integer" >&2; exit 2 ;;
esac
case "$LABEL" in
    *[!A-Za-z0-9._-]*|'') echo "overnight-stress: label may contain only [A-Za-z0-9._-]" >&2; exit 2 ;;
esac
[ -x "$ROOT/djs" ] || { echo "overnight-stress: $ROOT/djs is missing" >&2; exit 2; }
END=$(( $(date +%s) + HOURS * 3600 ))
DIR="$ROOT/.dub/overnight"
mkdir -p "$DIR"
LOG="$DIR/stress-$LABEL.log"
STATUS="$DIR/status-$LABEL.txt"
: > "$LOG"

cycle=0
fails=0
FAILED=""
START="$(date -u +%FT%TZ)"

run() { # run <timeout-s> <name> <command...>
    local t="$1" name="$2"; shift 2
    local out rc
    out="$(tmo "$t" "$@" 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ]; then
        fails=$((fails + 1))
        FAILED="$FAILED $name"
        printf '[%s] cycle %d FAIL %s (rc=%d)\n' "$(date -u +%FT%TZ)" "$cycle" "$name" "$rc" >> "$LOG"
        printf '%s\n' "$out" | head -60 > "$DIR/fail-$LABEL-$(printf '%04d' "$cycle")-$name.log"
    fi
    return 0
}

status() {
    {
        printf 'overnight %s: cycle=%d fails=%d\n' "$LABEL" "$cycle" "$fails"
        printf 'started=%s now=%s ends-epoch=%d\n' "$START" "$(date -u +%FT%TZ)" "$END"
        printf 'failed:%s\n' "${FAILED:- none}"
        printf 'log=%s\n' "$LOG"
    } > "$STATUS"
}
trap 'status; printf "[%s] stopped: %d cycle(s), %d failure(s)\n" "$(date -u +%FT%TZ)" "$cycle" "$fails" >> "$LOG"' EXIT

WATCH_CASES="fs_watch fs_watch_many fs_watch_recursive fs_watch_recursive_renames fs_watch_unref fs_watch_events"
QUICK_CASES="fs_async_ops fs_meta memory_rss os_cpus os_tmpdir net_basic http_server child_process"
ASAN_CASES="fs_watch fs_watch_many tls_client_ca net_basic"
ASAN_LEAKS=1
ASAN_BIN="$ROOT/.dub/asan/djs-asan"
if [ "$DJS_PLAT" = "darwin" ]; then ASAN_LEAKS=0; fi

printf '[%s] overnight %s started, %s hour(s)\n' "$(date -u +%FT%TZ)" "$LABEL" "$HOURS" >> "$LOG"

while [ "$(date +%s)" -lt "$END" ]; do
    cycle=$((cycle + 1))

    for c in $WATCH_CASES; do
        run 40 "watch-$c" "$ROOT/djs" -A "tests/js/$c.js"
    done
    for c in $QUICK_CASES; do
        run 40 "quick-$c" "$ROOT/djs" -A "tests/js/$c.js"
    done

    # Soak: bounded heap growth check once per cycle.
    run 120 soak "$ROOT/djs" -A tests/js/fixtures/soak.js

    if [ $((cycle % 6)) -eq 0 ]; then
        run 900 integration env DJS_SKIP_BUILD=1 "$ROOT/scripts/integration.sh"
    fi
    if [ $((cycle % 9)) -eq 0 ]; then
        run 180 gate-net env DJS_SKIP_BUILD=1 "$ROOT/scripts/gate-net.sh"
    fi
    if [ $((cycle % 5)) -eq 0 ] && [ -x "$ASAN_BIN" ]; then
        for c in $ASAN_CASES; do
            run 90 "asan-$c" env ASAN_OPTIONS="detect_leaks=$ASAN_LEAKS:exitcode=1" "$ASAN_BIN" -A "tests/js/$c.js"
        done
    fi

    printf '[%s] cycle %d complete (fails so far: %d)\n' "$(date -u +%FT%TZ)" "$cycle" "$fails" >> "$LOG"
    status
    sleep 5
done

printf '[%s] overnight %s finished: %d cycle(s), %d failure(s)\n' "$(date -u +%FT%TZ)" "$LABEL" "$cycle" "$fails" >> "$LOG"
[ "$fails" -eq 0 ]
