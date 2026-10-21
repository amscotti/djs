#!/usr/bin/env bash
# Probe the C boundary with hostile argument counts/types and malformed input.
# Success = the process exits with a code, never a signal (>=128) and never 70.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
BIN="$ROOT/djs"
[ -x "$BIN" ] || { echo "fuzz: build first" >&2; exit 1; }
mkdir -p .dub/fuzz
bad=0
n=0

run() {
    local label="$1" code="$2"
    n=$((n + 1))
    echo "$code" > ".dub/fuzz/$n.js"
    timeout 10 "$BIN" ".dub/fuzz/$n.js" >/dev/null 2>".dub/fuzz/$n.err"
    local rc=$?
    if [ "$rc" -ge 128 ] || [ "$rc" -eq 70 ]; then
        echo "fuzz: FAIL $label (rc=$rc)" >&2
        sed -n '1,6p' ".dub/fuzz/$n.err" >&2
        bad=$((bad + 1))
    fi
}

run "empty" ""
run "fs-read-noargs" 'fs.readFileSync();'
run "fs-read-object" 'fs.readFileSync({});'
run "fs-read-null" 'fs.readFileSync(null);'
run "fs-read-fd" 'fs.readFileSync(1);'
run "fs-write-noargs" 'fs.writeFileSync();'
run "fs-write-object" 'fs.writeFileSync("tests/tmp/fuzz.bin", {});'
run "fs-write-symbol" 'fs.writeFileSync("tests/tmp/fuzz.bin", Symbol("x"));'
run "fs-stat-missing" 'fs.statSync("tests/tmp/nope-xyz");'
run "timer-nan" 'setTimeout(() => {}, NaN);'
run "timer-inf" 'setTimeout(() => {}, Infinity);'
run "timer-negative" 'setTimeout(() => {}, -5);'
run "timer-huge" 'setTimeout(() => {}, 1e300);'
run "timer-nocb" 'try { setTimeout(1, 1) } catch (e) { }'
run "timer-clear-symbol" 'clearTimeout(Symbol("x"));'
run "timer-clear-object" 'clearTimeout({});'
run "microtask-type" 'try { queueMicrotask(1) } catch (e) { }'
run "require-type" 'try { require(1) } catch (e) { }'
run "require-missing" 'try { require("./nope") } catch (e) { }'
run "console-fd" 'try { __djs.console.write(3, "x") } catch (e) { }'
run "console-noargs" 'try { __djs.console.write() } catch (e) { }'
run "exit-string" 'process.exit("0");'
run "throw-symbol" 'throw Symbol("s");'
run "throw-null" 'throw null;'
run "deep-object" 'const o = {}; let p = o; for (let i = 0; i < 5000; i++) { p.n = {}; p = p.n; } console.log("deep");'
run "big-string" 'const s = "x".repeat(1 << 20); console.log(s.length);'
run "json-bad" 'try { JSON.parse("{") } catch (e) { }'
run "module-missing" 'import("./nope.mjs").catch(() => console.log("caught"));'

printf 'fuzz: %d cases, %d failures\n' "$n" "$bad"
[ "$bad" -eq 0 ]
