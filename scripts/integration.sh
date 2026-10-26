#!/usr/bin/env bash
# Run the JavaScript integration suite and the observable CLI checks.
# Cases are tests/js/*.js plus tests/js/<dir>/main.{js,mjs,cjs}; goldens live in
# tests/golden/<name>.txt with optional .stderr.txt (required substrings) and
# .exit (expected status, default 0).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
. "$ROOT/scripts/lib-portable.sh"
BIN="$ROOT/djs"
VERSION="v$(tr -d '[:space:]' < "$ROOT/VERSION")"
TMP="$ROOT/tests/tmp"
mkdir -p "$TMP"
rm -f "$TMP"/*.out "$TMP"/*.err "$TMP"/*.diff

if [ "${DJS_SKIP_BUILD:-0}" != "1" ]; then
    echo "== build =="
    if ! dub build --build=release $DJS_DUB_CONFIG >"$TMP/build.log" 2>&1; then
        cat "$TMP/build.log" >&2
        echo "integration: build failed" >&2
        exit 1
    fi
fi
[ -x "$BIN" ] || { echo "integration: $BIN missing" >&2; exit 1; }

pass=0
fail=0
ok() { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=$((fail + 1)); }

run_case() {
    local js="$1" base="$2"
    local out="$TMP/$base.out" err="$TMP/$base.err"
    tmo 30 "$BIN" ${DJS_TEST_FLAGS:--A} "$js" >"$out" 2>"$err"
    local code=$?

    local expectedExit=0
    if [ -f "tests/golden/$base.exit" ]; then
        expectedExit="$(tr -d '[:space:]' < "tests/golden/$base.exit")"
    fi
    if [ "$code" -ne "$expectedExit" ]; then
        bad "$base exit ($code != $expectedExit)"
        sed -n '1,20p' "$err" >&2
        return
    fi
    if [ ! -f "tests/golden/$base.txt" ] && [ ! -f "tests/golden/$base.$DJS_PLAT.txt" ]; then
        bad "$base missing golden"
        return
    fi
    # Goldens must not embed this checkout's absolute path: the same suite runs
    # from /home/runner/work/djs/djs in CI. Normalize the root before diffing.
    # /private/* prefixes exist only on macOS (mkdtemp/realpath canonicalize
    # through them); mapping them keeps one golden per platform where possible.
    sed -e "s|$ROOT|__ROOT__|g" -e "s|/private/tmp|/tmp|g" -e "s|/private/var|/var|g" \
        "$out" >"$TMP/$base.norm"
    # A per-platform golden wins when it exists (for output that genuinely
    # differs: platform strings, per-OS values).
    local golden="tests/golden/$base.txt"
    if [ -f "tests/golden/$base.$DJS_PLAT.txt" ]; then
        golden="tests/golden/$base.$DJS_PLAT.txt"
    fi
    if ! diff -u "$golden" "$TMP/$base.norm" >"$TMP/$base.diff"; then
        bad "$base stdout"
        cat "$TMP/$base.diff" >&2
        return
    fi

    local caseOk=1
    if [ -f "tests/golden/$base.stderr.txt" ]; then
        while IFS= read -r needle; do
            [ -z "$needle" ] && continue
            if ! grep -Fq -- "$needle" "$err"; then
                bad "$base stderr missing: $needle"
                sed -n '1,20p' "$err" >&2
                caseOk=0
                break
            fi
        done < "tests/golden/$base.stderr.txt"
    elif [ -s "$err" ]; then
        bad "$base unexpected stderr"
        sed -n '1,20p' "$err" >&2
        caseOk=0
    fi
    [ "$caseOk" -eq 1 ] && ok "$base"
}

for js in tests/js/*.js tests/js/*.mjs tests/js/*.cjs; do
    [ -f "$js" ] || continue
    base="$(basename "$js")"
    base="${base%.*}"
    run_case "$js" "$base"
done

# Directory cases: a package or module tree with one entry point.
for dir in tests/js/*/; do
    [ -d "$dir" ] || continue
    base="$(basename "$dir")"
    entry=""
    for cand in main.js main.mjs main.cjs; do
        if [ -f "$dir$cand" ]; then entry="$dir$cand"; break; fi
    done
    [ -n "$entry" ] || continue
    run_case "$entry" "$base"
done

# CLI-check helper: exact stdout, expected exit status.
check_stdout() {
    local name="$1" expected="$2"
    shift 2
    local out
    out="$("$@" 2>"$TMP/cli.err")"
    local code=$?
    if [ "$code" -ne 0 ]; then
        bad "$name exit $code"
        sed -n '1,10p' "$TMP/cli.err" >&2
        return
    fi
    if [ "$out" != "$expected" ]; then
        bad "$name stdout"
        printf 'expected: <%s>\nactual:   <%s>\n' "$expected" "$out" >&2
        return
    fi
    ok "$name"
}

check_exit() {
    local name="$1" expected="$2"
    shift 2
    "$@" >"$TMP/cli.out" 2>"$TMP/cli.err"
    local code=$?
    if [ "$code" -ne "$expected" ]; then
        bad "$name exit ($code != $expected)"
        sed -n '1,10p' "$TMP/cli.err" >&2
        return
    fi
    ok "$name"
}

check_stdout "eval-arithmetic" "2" "$BIN" -e 'console.log(1 + 1)'
check_stdout "eval-promise" "p" "$BIN" -e 'Promise.resolve().then(() => console.log("p"))'
check_stdout "eval-microtask-timer" "$(printf 'm\nt')" \
    "$BIN" -e 'queueMicrotask(() => console.log("m")); setTimeout(() => console.log("t"), 0)'
check_stdout "eval-version" "$VERSION" "$BIN" --version
check_exit "process-exit-code" 5 "$BIN" -e 'process.exit(5)'
check_exit "exit-code-wins" 3 "$BIN" -e 'Promise.reject(new Error("x")); process.exit(3)'
if [ -z "$DJS_TIMEOUT" ]; then
    bad "timeout (no timeout utility installed; brew install coreutils)"
else
    check_exit "timeout" 1 "$BIN" --timeout 100 tests/js/fixtures/infinite.js
fi
check_exit "memory-limit" 1 "$BIN" --memory-limit 8388608 tests/js/fixtures/oom.js

# DJS_MAX_FILE_SIZE caps reads (documented env override for the 512 MiB
# default); both the numeric parse and the EFBIG delivery are observable.
printf '0123456789abcdef' > "$TMP/big.bin"
check_stdout "max-file-size-efbig" "EFBIG" env DJS_MAX_FILE_SIZE=8 "$BIN" -A \
    -e "try{require('fs').readFileSync('$TMP/big.bin')}catch(e){console.log(e.code)}"
check_stdout "max-file-size-junk-defaults" "16" env DJS_MAX_FILE_SIZE=notanumber "$BIN" -A \
    -e "console.log(require('fs').readFileSync('$TMP/big.bin').length)"
# Overflow falls back to the default cap instead of wrapping.
check_stdout "max-file-size-overflow-defaults" "16" env DJS_MAX_FILE_SIZE=99999999999999999999 "$BIN" -A \
    -e "console.log(require('fs').readFileSync('$TMP/big.bin').length)"

# --help drifted from the parser once; every documented flag must be listed.
# Capture it once: piping into `grep -q` makes grep exit early and can race
# the writer on macOS.
helpText="$("$BIN" --help 2>&1)"
for flag in --allow-read --allow-write --allow-env --allow-sys --allow-net \
            --allow-run --allow-listen --permission-set --config --no-prompt; do
    if grep -q -- "$flag" <<<"$helpText"; then
        ok "help-lists-$flag"
    else
        bad "help-lists-$flag missing from --help"
    fi
done

# --config names the permission file; a missing one must fail, not be ignored.
check_exit "config-missing-fails" 1 "$BIN" --config "$TMP/no-such-djs.json" -e 'console.log(1)'

# execSync honours `encoding` (a string) and still returns Buffers by default.
check_stdout "exec-sync-encoding" "string true" "$BIN" -A -e \
    'const {execSync}=require("child_process"); console.log(typeof execSync("echo hi",{encoding:"utf8"}), Buffer.isBuffer(execSync("echo hi")))'


"$BIN" "$TMP/definitely-missing.js" >/dev/null 2>&1
if [ $? -ne 0 ]; then ok "missing-file"; else bad "missing-file accepted"; fi

replOut="$(printf '1+1\n' | "$BIN" 2>"$TMP/repl.err")"
if printf '%s' "$replOut" | grep -q '2'; then
    ok "repl-arithmetic"
else
    bad "repl-arithmetic"
    printf '%s\n' "$replOut" >&2
fi

# A zero-delay timer fires before the next prompt, and EOF does not hang.
replAsync="$(printf 'setTimeout(()=>console.log("T"),0)\n' | tmo 5 "$BIN" 2>"$TMP/repl.err")"
if printf '%s' "$replAsync" | grep -q 'T'; then
    ok "repl-async"
else
    bad "repl-async"
    printf '%s\n' "$replAsync" >&2
fi

# A closed stdout must not kill the process via SIGPIPE.
"$BIN" -e 'for (let i = 0; i < 20000; i++) console.log("abcdefghijklmnopqrstuvwxyz")' \
    | head -1 >/dev/null 2>&1
pipeStatus=${PIPESTATUS[0]}
if [ "$pipeStatus" -eq 0 ]; then ok "sigpipe-ignored"; else bad "sigpipe-ignored ($pipeStatus)"; fi

# A blocked fs read must not stop process.exit from delivering its code.
rm -f "$TMP/fifo"
mkfifo "$TMP/fifo"
tmo 5 "$BIN" -e "fs.readFile('$TMP/fifo', () => {}); setTimeout(() => process.exit(3), 10)" \
    >/dev/null 2>&1
fifoCode=$?
rm -f "$TMP/fifo"
if [ "$fifoCode" -eq 3 ]; then ok "exit-with-blocked-fs"; else bad "exit-with-blocked-fs ($fifoCode)"; fi

# process.stdin is fed by fd 0; process.stdout/stderr are Writable streams.
stdioOut="$(printf 'hello-stdin' | "$BIN" -A tests/js/fixtures/stdin_echo.js 2>"$TMP/stdin.err")"
if [ "$stdioOut" = "hello-stdin" ]; then ok "stdin-stream"; else bad "stdin-stream"; fi

# A registered signal handler runs and can choose the exit code.
sigOut="$TMP/signal.out"
"$BIN" -A tests/js/fixtures/signal_handler.js >"$sigOut" 2>&1 &
sigPid=$!
sleep 0.5
kill -TERM "$sigPid" 2>/dev/null
wait "$sigPid"
sigCode=$?
if [ "$sigCode" -eq 0 ] && grep -q "got SIGTERM" "$sigOut"; then
    ok "signal-handler"
else
    bad "signal-handler ($sigCode)"
    sed -n '1,5p' "$sigOut" >&2
fi

# TLS clients against loopback openssl servers: self-signed (must fail
# verification with Node's code), CA-signed with a DNS-only SAN (altname
# failure and untrusted-CA failure), and CA-signed with DNS+IP SANs (trusted
# success). Config files instead of -addext: macOS ships LibreSSL.
tlsDir="$TMP/tls"
mkdir -p "$tlsDir"
cat > "$tlsDir/self.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = localhost
[v3]
subjectAltName = DNS:localhost,IP:127.0.0.1
EOF
cat > "$tlsDir/dns.cnf" <<'EOF'
[req]
distinguished_name = dn
req_extensions = v3
prompt = no
[dn]
CN = localhost
[v3]
subjectAltName = DNS:localhost
basicConstraints = CA:FALSE
EOF
cat > "$tlsDir/san.cnf" <<'EOF'
[req]
distinguished_name = dn
req_extensions = v3
prompt = no
[dn]
CN = localhost
[v3]
subjectAltName = DNS:localhost,IP:127.0.0.1
basicConstraints = CA:FALSE
EOF
tlsOk=1
openssl req -x509 -newkey rsa:2048 -keyout "$tlsDir/key.pem" -out "$tlsDir/cert.pem" \
    -days 1 -nodes -config "$tlsDir/self.cnf" >/dev/null 2>&1 || tlsOk=0
openssl req -x509 -newkey rsa:2048 -keyout "$tlsDir/ca.key" -out "$tlsDir/ca.pem" \
    -days 1 -nodes -subj "/CN=DJS Test CA" >/dev/null 2>&1 || tlsOk=0
for prof in dns san; do
    openssl req -new -newkey rsa:2048 -keyout "$tlsDir/$prof.key" -out "$tlsDir/$prof.csr" \
        -nodes -config "$tlsDir/$prof.cnf" >/dev/null 2>&1 || tlsOk=0
    openssl x509 -req -in "$tlsDir/$prof.csr" -CA "$tlsDir/ca.pem" -CAkey "$tlsDir/ca.key" \
        -CAcreateserial -out "$tlsDir/$prof.pem" -days 1 \
        -extfile "$tlsDir/$prof.cnf" -extensions v3 >/dev/null 2>&1 || tlsOk=0
done
if [ "$tlsOk" = 1 ]; then
    tlsPort=$((18443 + RANDOM % 900))
    tlsPort2=$((tlsPort + 1))
    tlsPort3=$((tlsPort + 2))
    openssl s_server -accept "$tlsPort" -cert "$tlsDir/cert.pem" -key "$tlsDir/key.pem" \
        -www -quiet >/dev/null 2>&1 &
    tlsPid=$!
    openssl s_server -accept "$tlsPort2" -cert "$tlsDir/dns.pem" -key "$tlsDir/dns.key" \
        -www -quiet >/dev/null 2>&1 &
    tlsPid2=$!
    openssl s_server -accept "$tlsPort3" -cert "$tlsDir/san.pem" -key "$tlsDir/san.key" \
        -www -quiet >/dev/null 2>&1 &
    tlsPid3=$!
    sleep 0.5
    tlsOut="$("$BIN" -A tests/js/fixtures/tls_client.js "$tlsPort" 2>&1)"
    tlsExtra="$(NODE_EXTRA_CA_CERTS="$tlsDir/ca.pem" "$BIN" -A \
        tests/js/fixtures/tls_extra_ca.js "$tlsPort3" 2>&1)"
    tlsNoExtra="$("$BIN" -A tests/js/fixtures/tls_extra_ca.js "$tlsPort3" 2>&1)"
    tlsSslFile="$(SSL_CERT_FILE="$tlsDir/ca.pem" "$BIN" -A \
        tests/js/fixtures/tls_extra_ca.js "$tlsPort3" 2>&1)"
    tlsUntrusted="$("$BIN" -A tests/js/fixtures/tls_code.js "$tlsPort2" 2>&1)"
    tlsAltname="$(NODE_EXTRA_CA_CERTS="$tlsDir/ca.pem" "$BIN" -A \
        tests/js/fixtures/tls_code.js "$tlsPort2" 2>&1)"
    kill "$tlsPid" "$tlsPid2" "$tlsPid3" 2>/dev/null
    wait "$tlsPid" "$tlsPid2" "$tlsPid3" 2>/dev/null
    if printf '%s' "$tlsOut" | grep -q "https 200 true" &&
       printf '%s' "$tlsOut" | grep -q "verify DEPTH_ZERO_SELF_SIGNED_CERT" &&
       printf '%s' "$tlsOut" | grep -q "fetch true"; then
        ok "tls-https"
    else
        bad "tls-https"
        printf '%s\n' "$tlsOut" >&2
    fi
    if printf '%s' "$tlsExtra" | grep -q "extra-ca 200 true"; then
        ok "tls-extra-ca"
    else
        bad "tls-extra-ca"
        printf '%s\n' "$tlsExtra" >&2
    fi
    if printf '%s' "$tlsNoExtra" | grep -q "extra-ca-err"; then
        ok "tls-extra-ca-not-default"
    else
        bad "tls-extra-ca-not-default"
        printf '%s\n' "$tlsNoExtra" >&2
    fi
    if printf '%s' "$tlsSslFile" | grep -q "extra-ca 200 true"; then
        ok "tls-ssl-cert-file"
    else
        bad "tls-ssl-cert-file"
        printf '%s\n' "$tlsSslFile" >&2
    fi
    if printf '%s' "$tlsUntrusted" | grep -q "code UNABLE_TO_VERIFY_LEAF_SIGNATURE"; then
        ok "tls-verify-untrusted"
    else
        bad "tls-verify-untrusted"
        printf '%s\n' "$tlsUntrusted" >&2
    fi
    if printf '%s' "$tlsAltname" | grep -q "code ERR_TLS_CERT_ALTNAME_INVALID"; then
        ok "tls-verify-altname"
    else
        bad "tls-verify-altname"
        printf '%s\n' "$tlsAltname" >&2
    fi
else
    bad "tls-fixture"
fi

# readline splits piped input into lines and closes at EOF.
rlOut="$(printf 'one\ntwo\n' | "$BIN" -A tests/js/fixtures/readline.js 2>"$TMP/rl.err")"
if [ "$rlOut" = "one|two" ]; then ok "readline-stream"; else bad "readline-stream"; fi

# dub test must not replace the runtime binary.
if [ "${DJS_SKIP_BUILD:-0}" = "1" ]; then
    ok "dub-test-skipped"
elif dub test $DJS_UT_CONFIG >/dev/null 2>&1; then
    afterTest="$("$BIN" -e 'console.log(42)' 2>/dev/null)"
    if [ "$afterTest" = "42" ]; then ok "dub-test-keeps-runtime"; else bad "dub-test-keeps-runtime"; fi
else
    bad "dub test"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
