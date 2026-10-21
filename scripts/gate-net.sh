#!/usr/bin/env bash
# Loopback networking gate: deterministic HTTP fixture, net/http/fetch/dns.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
TMP=".dub/net-gate"
mkdir -p "$TMP"
PORTFILE="$TMP/port"
rm -f "$PORTFILE"
python3 tests/fixtures/http_fixture.py "$PORTFILE" >"$TMP/server.log" 2>&1 &
SERVER=$!
trap 'kill "$SERVER" 2>/dev/null; wait "$SERVER" 2>/dev/null' EXIT
for _ in $(seq 1 50); do
    [ -s "$PORTFILE" ] && break
    sleep 0.1
done
if [ ! -s "$PORTFILE" ]; then
    echo "net-gate: fixture failed to start" >&2
    cat "$TMP/server.log" >&2
    exit 1
fi
PORT="$(cat "$PORTFILE")"
DJS_NET_PORT="$PORT" timeout 20 ./djs -A --allow-net="127.0.0.1:$PORT" tests/net/net_http.js >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "net-gate: exit $rc" >&2
    sed -n '1,20p' "$TMP/err" >&2
    exit 1
fi
sort "$TMP/out" > "$TMP/out.sorted"
sort tests/golden/net_http.txt > "$TMP/golden.sorted"
if ! diff -u "$TMP/golden.sorted" "$TMP/out.sorted"; then
    echo "net-gate: output differs" >&2
    exit 1
fi
./djs -A --allow-net="127.0.0.1:$PORT" -e 'require("dns").lookup("localhost",(e,a,f)=>{ if(e||!a) process.exit(1); console.log("dns",a,f); })' >"$TMP/dns" 2>&1 || exit 1
grep -q "^dns 127.0.0.1 4$" "$TMP/dns" || { cat "$TMP/dns" >&2; exit 1; }
printf 'net-gate ok %s\n' "$(date -u +%FT%TZ)" >> gates/net.txt
echo "net-gate: ok"
