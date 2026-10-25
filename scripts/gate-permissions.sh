#!/usr/bin/env bash
# Permission gate: exercises the default-deny model, scoped grants, deny
# precedence, env/sys filtering, async denial delivery and the direct-__djs
# bypass. Runs the binary without -A, which is the point.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${DJS_BIN:-$ROOT/djs}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
run() { "$BIN" "$@" 2>&1; }

expect_contains() {
    local label="$1" needle="$2"; shift 2
    local out
    out="$(run "$@")"
    if [[ "$out" != *"$needle"* ]]; then
        echo "permissions: FAIL $label (wanted '$needle', got: $out)" >&2
        fail=$((fail+1))
    else
        echo "permissions: ok $label"
    fi
}

mkdir -p "$TMP/allowed" "$TMP/allowed2" "$TMP/other"
printf 'ok\n' > "$TMP/allowed/file.txt"
printf 'no\n' > "$TMP/other/file.txt"
printf 'no\n' > "$TMP/allowed2/file.txt"
ln -s "$TMP/other/file.txt" "$TMP/allowed/link.txt"

# 1. Default deny.
expect_contains "default-read-denied" "PermissionDenied ERR_ACCESS_DENIED" \
    -e "try{require('fs').readFileSync('$TMP/allowed/file.txt')}catch(e){console.log(e.name,e.code)}"
expect_contains "default-write-denied" "PermissionDenied ERR_ACCESS_DENIED" \
    -e "try{require('fs').writeFileSync('$TMP/allowed/new.txt','x')}catch(e){console.log(e.name,e.code)}"
expect_contains "default-env-empty" "undefined" \
    -e "console.log(typeof process.env.HOME)"
expect_contains "default-sys-denied" "PermissionDenied ERR_ACCESS_DENIED" \
    -e "try{console.log(os.hostname())}catch(e){console.log(e.name,e.code)}"

# 2. Scoped grants, and outside the grant still denied.
expect_contains "scoped-read" "ok" \
    --allow-read="$TMP/allowed" -e "console.log(require('fs').readFileSync('$TMP/allowed/file.txt','utf8').trim())"
expect_contains "scoped-read-outside-denied" "PermissionDenied ERR_ACCESS_DENIED" \
    --allow-read="$TMP/allowed" -e "try{require('fs').readFileSync('$TMP/other/file.txt')}catch(e){console.log(e.name,e.code)}"
expect_contains "prefix-boundary" "PermissionDenied ERR_ACCESS_DENIED" \
    --allow-read="$TMP/allowed" -e "try{require('fs').readFileSync('${TMP}/allowed2/file.txt')}catch(e){console.log(e.name,e.code)}"

# 3. Symlink escape is judged on the canonical target.
expect_contains "symlink-escape-denied" "PermissionDenied ERR_ACCESS_DENIED" \
    --allow-read="$TMP/allowed" -e "try{require('fs').readFileSync('$TMP/allowed/link.txt')}catch(e){console.log(e.name,e.code)}"

# 4. Write grant.
expect_contains "scoped-write" "written" \
    --allow-write="$TMP/allowed" -e "require('fs').writeFileSync('$TMP/allowed/new.txt','x'); console.log('written')"

# 4b. fd/link/mode gates.
expect_contains "open-read-denied" "PermissionDenied ERR_ACCESS_DENIED" \
    -e "try{require('fs').openSync('$TMP/allowed/file.txt','r')}catch(e){console.log(e.name,e.code)}"
expect_contains "open-read-scoped" "true" \
    --allow-read="$TMP/allowed" -e "const fs=require('fs'); const fd=fs.openSync('$TMP/allowed/file.txt','r'); console.log(fd>=0); fs.closeSync(fd)"
expect_contains "open-write-needs-write" "PermissionDenied ERR_ACCESS_DENIED" \
    --allow-read="$TMP/allowed" -e "try{require('fs').openSync('$TMP/allowed/new.txt','w')}catch(e){console.log(e.name,e.code)}"
expect_contains "chmod-denied" "PermissionDenied ERR_ACCESS_DENIED" \
    -e "try{require('fs').chmodSync('$TMP/allowed/file.txt',384)}catch(e){console.log(e.name,e.code)}"
expect_contains "chmod-allowed" "600" \
    --allow-write="$TMP/allowed" --allow-read="$TMP/allowed" -e "const fs=require('fs'); fs.chmodSync('$TMP/allowed/file.txt',384); console.log((fs.statSync('$TMP/allowed/file.txt').mode&511).toString(8))"
expect_contains "symlink-needs-write" "PermissionDenied ERR_ACCESS_DENIED" \
    -e "try{require('fs').symlinkSync('file.txt','$TMP/allowed/s2')}catch(e){console.log(e.name,e.code)}"
expect_contains "symlink-readlink" "file.txt" \
    --allow-write="$TMP/allowed" --allow-read="$TMP/allowed" -e "const fs=require('fs'); fs.symlinkSync('file.txt','$TMP/allowed/s2'); console.log(fs.readlinkSync('$TMP/allowed/s2'))"

# 4c. Numeric flags and fd ownership cannot widen a grant.
expect_contains "flags-trunc-denied" "PermissionDenied ERR_ACCESS_DENIED" \
    --allow-read="$TMP/allowed" -e "try{require('fs').openSync('$TMP/allowed/file.txt',512)}catch(e){console.log(e.name,e.code)}"
expect_contains "flags-create-denied" "PermissionDenied ERR_ACCESS_DENIED" \
    --allow-read="$TMP/allowed" -e "try{require('fs').openSync('$TMP/allowed/new2',64)}catch(e){console.log(e.name,e.code)}"
expect_contains "fd-ownership" "EBADF" \
    -e "try{require('fs').closeSync(3)}catch(e){console.log(e.code)}"
expect_contains "dangling-symlink-denied" "PermissionDenied ERR_ACCESS_DENIED" \
    --allow-write="$TMP/allowed" -e "const fs=require('fs'); try{fs.symlinkSync('$TMP/other/pwn','$TMP/allowed/dangle')}catch(e){}; try{fs.writeFileSync('$TMP/allowed/dangle','OWNED')}catch(e){console.log(e.name,e.code)}"
if [ -e "$TMP/other/pwn" ]; then echo "permissions: FAIL dangling-symlink-created" >&2; fail=$((fail+1)); else echo "permissions: ok dangling-symlink-not-created"; fi

# 5. Network gate: DNS and connect share --allow-net host:port.
expect_contains "net-dns-denied" "PermissionDenied ERR_ACCESS_DENIED" \
    -e "require('dns').lookup('127.0.0.1',e=>console.log(e.name,e.code))"
expect_contains "net-dns-allowed" "127.0.0.1" \
    --allow-net=127.0.0.1:1 -e "require('dns').lookup('127.0.0.1',(e,a)=>console.log(a))"
expect_contains "net-connect-denied" "PermissionDenied ERR_ACCESS_DENIED" \
    -e "try{require('net').connect(1,'127.0.0.1')}catch(e){console.log(e.name,e.code)}"
expect_contains "child-run-denied" "PermissionDenied ERR_ACCESS_DENIED" \
    -e "try{require('child_process').execSync('echo no')}catch(e){console.log(e.name,e.code)}"
expect_contains "child-run-allowed" "ok" \
    --allow-run=sh -e "console.log(require('child_process').execSync('echo ok').toString().trim())"
mkdir -p "$TMP/evil"
printf '#!/bin/sh\necho pwned\n' > "$TMP/evil/echo"
chmod +x "$TMP/evil/echo"
expect_contains "child-path-grant-scoped" "PermissionDenied ERR_ACCESS_DENIED" \
    --allow-run=echo -e "try{require('child_process').spawnSync('$TMP/evil/echo')}catch(e){console.log(e.name,e.code)}"
expect_contains "child-deny-run-wins" "PermissionDenied ERR_ACCESS_DENIED" \
    -A --deny-run=sh -e "try{require('child_process').execSync('echo no')}catch(e){console.log(e.name,e.code)}"
expect_contains "child-absolute-sh-grant" "ok" \
    --allow-run=/bin/sh -e "console.log(require('child_process').execSync('echo ok').toString().trim())"
expect_contains "listen-denied" "PermissionDenied ERR_ACCESS_DENIED" \
    -e "try{require('net').createServer().listen(0,'127.0.0.1')}catch(e){console.log(e.name,e.code)}"
expect_contains "listen-allowed" "true" \
    --allow-listen=127.0.0.1:0 -e "const s=require('net').createServer(); s.listen(0,'127.0.0.1'); console.log(s.address().port>0); s.close()"
expect_contains "dgram-bind-denied" "PermissionDenied ERR_ACCESS_DENIED" \
    -e "try{require('dgram').createSocket('udp4').bind(0,'127.0.0.1')}catch(e){console.log(e.name,e.code)}"
expect_contains "child-cwd-missing" "ENOENT" \
    --allow-run=sh -e "try{require('child_process').spawnSync('sh',['-c','true'],{cwd:'/no/such/dir'})}catch(e){console.log(e.code)}"

# 5. Env filtering and sys grants.
expect_contains "env-grant" "string true false" \
    --allow-env=HOME -e "console.log(typeof process.env.HOME, process.permission.has('env','HOME'), process.permission.has('env','PATH'))"
expect_contains "sys-hostname" "true" \
    --allow-sys=hostname -e "console.log(os.hostname().length > 0)"

# 6. Deny wins over -A.
expect_contains "deny-wins" "PermissionDenied ERR_ACCESS_DENIED" \
    -A --deny-read="$TMP/allowed" -e "try{require('fs').readFileSync('$TMP/allowed/file.txt')}catch(e){console.log(e.name,e.code)}"

# 7. Drop revokes a granted category.
expect_contains "drop-revokes" $'true\nPermissionDenied ERR_ACCESS_DENIED' \
    --allow-read="$TMP/allowed" -e "console.log(process.permission.drop('fs.read')); try{require('fs').readFileSync('$TMP/allowed/file.txt')}catch(e){console.log(e.name,e.code)}"

# 8. Direct native access cannot bypass the gate.
expect_contains "direct-djs-bypass" "PermissionDenied ERR_ACCESS_DENIED" \
    -e "try{__djs.fs.readFileSync('$TMP/allowed/file.txt')}catch(e){console.log(e.name,e.code)}"
expect_contains "direct-os-bypass" "PermissionDenied ERR_ACCESS_DENIED" \
    -e "try{__djs.os.hostname()}catch(e){console.log(e.name,e.code)}"

# 9. Async fs denies through the callback, not an uncaught throw.
expect_contains "async-denial" "PermissionDenied ERR_ACCESS_DENIED" \
    -e "require('fs').readFile('$TMP/allowed/file.txt', e => console.log(e.name, e.code))"

# 10. Legacy escape hatch.
expect_contains "allow-all" "ok" \
    -A -e "console.log(require('fs').readFileSync('$TMP/allowed/file.txt','utf8').trim())"

# 11. djs.json permission set.
cat > "$TMP/djs.json" <<'EOF'
{"permissions":{"default":{"read":["./allowed"]}}}
EOF
expect_contains "config-set" "ok"     --config "$TMP/djs.json" -P -e "console.log(require('fs').readFileSync('$TMP/allowed/file.txt','utf8').trim())"

# 12. Audit records both allow and deny.
: > "$TMP/audit.jsonl"
DJS_AUDIT_PERMISSIONS="$TMP/audit.jsonl" "$BIN" --allow-read="$TMP/allowed"     -e "require('fs').readFileSync('$TMP/allowed/file.txt'); try{require('fs').readFileSync('$TMP/other/file.txt')}catch(e){}" >/dev/null 2>&1
if grep -q '"result":"allow"' "$TMP/audit.jsonl" && grep -q '"result":"deny"' "$TMP/audit.jsonl"; then
    echo "permissions: ok audit-jsonl"
else
    echo "permissions: FAIL audit-jsonl" >&2
    fail=$((fail+1))
fi

# 13. A hard link must not turn a read grant into a write grant: the
# source of the link needs the write grant too (inode aliasing).
printf 'secret\n' > "$TMP/allowed2/file.txt"
mkdir -p "$TMP/w"
expect_contains "hardlink-read-only-source-denied" "PermissionDenied ERR_ACCESS_DENIED" \
    --allow-read="$TMP/allowed2" --allow-write="$TMP/w" -e "try{require('fs').linkSync('$TMP/allowed2/file.txt','$TMP/w/hl')}catch(e){console.log(e.name,e.code)}"
if [ -e "$TMP/w/hl" ]; then echo "permissions: FAIL hardlink-created" >&2; fail=$((fail+1)); else echo "permissions: ok hardlink-not-created"; fi
expect_contains "hardlink-write-both-ends" "linked" \
    --allow-read="$TMP/allowed2" --allow-write="$TMP/allowed2" --allow-write="$TMP/w" -e "const fs=require('fs'); fs.writeFileSync('$TMP/w/src.txt','v'); fs.linkSync('$TMP/w/src.txt','$TMP/w/hl'); console.log('linked')"

# 14. Outbound TLS is gated like net.connect.
expect_contains "tls-connect-denied" "PermissionDenied ERR_ACCESS_DENIED" \
    -e "try{require('tls').connect(443,'example.com',{})}catch(e){console.log(e.name,e.code)}"
expect_contains "tls-connect-scoped-denied" "PermissionDenied ERR_ACCESS_DENIED" \
    --allow-net=127.0.0.1:1 -e "try{require('tls').connect(443,'example.com',{})}catch(e){console.log(e.name,e.code)}"

# 15. An explicit empty value (`--allow-read=`) is a startup error, never a
# silent whole-category grant.
"$BIN" --allow-read= -e 'console.log(1)' >/dev/null 2>&1
if [ $? -eq 1 ]; then echo "permissions: ok empty-flag-value-rejected"; else echo "permissions: FAIL empty-flag-value-rejected" >&2; fail=$((fail+1)); fi
"$BIN" -E= -e 'console.log(1)' >/dev/null 2>&1
if [ $? -eq 1 ]; then echo "permissions: ok empty-short-flag-rejected"; else echo "permissions: FAIL empty-short-flag-rejected" >&2; fail=$((fail+1)); fi

# 16. Config booleans must not widen: deny:false is "no denies", not allow-all.
cat > "$TMP/djs-false.json" <<'EOF'
{"permissions":{"default":{"read":{"allow":["./allowed"],"deny": false}}}}
EOF
expect_contains "config-deny-false-still-denied" "PermissionDenied ERR_ACCESS_DENIED" \
    --config "$TMP/djs-false.json" -P -e "try{require('fs').readFileSync('$TMP/other/file.txt')}catch(e){console.log(e.name,e.code)}"

# 17. dgram bind is the listen capability; net grants must not open sockets.
expect_contains "dgram-bind-net-grant-denied" "PermissionDenied ERR_ACCESS_DENIED" \
    --allow-net=127.0.0.1:1 -e "try{require('dgram').createSocket('udp4').bind(0,'127.0.0.1')}catch(e){console.log(e.name,e.code)}"
expect_contains "dgram-bind-listen-granted" "true" \
    --allow-listen=127.0.0.1:0 -e "const d=require('dgram'); const s=d.createSocket('udp4'); s.bind(0,'127.0.0.1'); console.log(s.address().port>0); s.close()"

# 18. listen rules use host:port matching: wildcards work.
expect_contains "listen-wildcard-granted" "true" \
    --allow-listen='*:0' -e "const s=require('net').createServer(); s.listen(0,'127.0.0.1'); console.log(s.address().port>0); s.close()"

# 19. The audit sink is fail-closed: a path that cannot be opened aborts
# startup, and a very long resource must not corrupt the record or crash.
DJS_AUDIT_PERMISSIONS="$TMP/no-such-dir/audit.jsonl" "$BIN" --allow-read="$TMP/allowed" \
    -e 'console.log(1)' >/dev/null 2>&1
if [ $? -ne 0 ]; then echo "permissions: ok audit-open-fails-startup"; else echo "permissions: FAIL audit-open-fails-startup" >&2; fail=$((fail+1)); fi
: > "$TMP/audit-long.jsonl"
DJS_AUDIT_PERMISSIONS="$TMP/audit-long.jsonl" "$BIN" --allow-read="$TMP/allowed" \
    -e "try{require('fs').readFileSync('$TMP/allowed/' + 'A'.repeat(4000) + '.txt')}catch(e){}" >/dev/null 2>&1
auditLongRc=$?
auditLongOk=1
[ "$auditLongRc" -eq 0 ] || auditLongOk=0
# Structural check (no python/jq dependency): every record is a complete
# object — opens as a v1 record and closes with a result field — which the
# stack overflow would have mangled.
while IFS= read -r auditLine; do
    case "$auditLine" in
        '{"v":1,'*) ;;
        *) auditLongOk=0; break ;;
    esac
    case "$auditLine" in
        *',"result":"deny"}'|*',"result":"allow"}') ;;
        *) auditLongOk=0; break ;;
    esac
done < "$TMP/audit-long.jsonl"
[ -s "$TMP/audit-long.jsonl" ] || auditLongOk=0
if [ "$auditLongOk" -eq 1 ]; then
    echo "permissions: ok audit-long-resource-valid-jsonl"
else
    echo "permissions: FAIL audit-long-resource-valid-jsonl" >&2
    fail=$((fail+1))
fi

# 20. process.permission.has() is a query: it must not grant anything.
expect_contains "has-is-not-a-grant" $'false\nPermissionDenied ERR_ACCESS_DENIED' \
    --allow-read="$TMP/allowed" -e "console.log(process.permission.has('fs.read','$TMP/other/file.txt')); try{require('fs').readFileSync('$TMP/other/file.txt')}catch(e){console.log(e.name,e.code)}"

# 21. Trailing-slash paths must canonicalize without recursing forever
# (the canonicalizer's parent split used to reproduce its own input).
expect_contains "trailing-slash-read" "EISDIR" \
    --allow-read="$TMP/allowed" -e "try{require('fs').readFileSync('$TMP/allowed/')}catch(e){console.log(e.code)}"
expect_contains "trailing-slash-read-a" "EISDIR" \
    -A -e "try{require('fs').readFileSync('$TMP/allowed/')}catch(e){console.log(e.code)}"

# 22. Config string escapes: a \u escape must decode before path matching
# decides the grant, and a malformed escape must fail startup (never a
# silent partial parse of a permission file).
printf 'esc\n' > "$TMP/allowed/esc.txt"
cat > "$TMP/djs-esc.json" <<'EOF'
{"permissions":{"default":{"read":["./\u0061llowed"]}}}
EOF
expect_contains "config-escape-grants" "esc" \
    --config "$TMP/djs-esc.json" -P -e "console.log(require('fs').readFileSync('$TMP/allowed/esc.txt','utf8').trim())"
cat > "$TMP/djs-badesc.json" <<'EOF'
{"permissions":{"default":{"read":["./\uZZZZ"]}}}
EOF
"$BIN" --config "$TMP/djs-badesc.json" -P -e 'console.log(1)' >/dev/null 2>&1
if [ $? -ne 0 ]; then echo "permissions: ok config-bad-escape-rejected"; else echo "permissions: FAIL config-bad-escape-rejected" >&2; fail=$((fail+1)); fi

if [[ $fail -ne 0 ]]; then
    echo "permissions: $fail check(s) failed" >&2
    exit 1
fi
echo "permissions: ok"
