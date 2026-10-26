#!/usr/bin/env bash
# ASan/LSan pass over the fixture set. Any sanitizer report fails the gate.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
. "$ROOT/scripts/lib-portable.sh"
mkdir -p .dub
BIN="$ROOT/.dub/asan/djs-asan"
log="$ROOT/.dub/sanitize-build.log"
# Sanitizer flags live here rather than in dub.json: DUB warns about compiler
# flags in a package description (`-g` is DUB's `--build=debug`), and DFLAGS
# applies to this build only.
SAN_CONFIG=sanitize
# libuv's FSEvents thread and OpenSSL's provider/DRBG globals keep
# process-lifetime allocations that LSan reports on exit, so macOS runs the
# AddressSanitizer checks without leak detection. Linux runs both.
DETECT_LEAKS=1
DETECT_LABEL="asan+lsan"
if [ "$DJS_PLAT" = "darwin" ]; then
    SAN_CONFIG=sanitize-macos
    DETECT_LEAKS=0
    DETECT_LABEL="asan"
fi
if ! DFLAGS="-fsanitize=address" dub build --config="$SAN_CONFIG" --build=debug --force >"$log" 2>&1; then
    tail -20 "$log" >&2
    echo "gate-sanitize: build failed" >&2
    exit 1
fi
[ -x "$BIN" ] || { echo "gate-sanitize: $BIN missing" >&2; exit 1; }
"$BIN" --version >/dev/null 2>&1 || {
    echo "gate-sanitize: $BIN does not run" >&2
    exit 1
}

cases=(hello fs_read fs_binary fs_buffers timers_clear microtasks microtask_throw
       rejection rejection_handled fatal_stops_callbacks throw timer_churn
       fs_meta fs_limits fs_write_gc rejection_late nul_path require_fs
       cjs_cycle cjs_interop cjs_throw_twice require_bound esm_chain json_import
       json_proto dynamic_import root_escape buffer_basic path_module os_module
       immediate fs_cp_io builtin_new_modules meta_space fs_deep_rm memory_usage
       fs_promises_extra node_modules_test node_modules_import
       node_modules_exports node_modules_exports_esm
       events_module stream_module url_util_module timers_clone_abort fs_streams fs_depth fs_depth_regress net_basic child_process child_async diagnostics_sse fork_ipc child_env tls_client_ca tls_mtls tls_alpn http2_tls cluster_basic process_stdio crypto zlib tls_fail node_compat node_partials http_keepalive https_server crypto_extra crypto_sign fs_watch fs_watch_many fs_watch_recursive fs_watch_recursive_renames fs_watch_recursive_replace fs_watch_unref fs_watch_persistent fs_watch_events memory_rss dns_lookup process_chdir os_cpus os_tmpdir dns_resolve fs_dir vm_basic web_streams websocket http2 fetch_headers fetch_stream buffer_full module_resolve stream_web_interop crypto_core http_upgrade blob_formdata fetch_decode webcrypto entry_scope upgrade_close dns_records assert_module stream_promises net_ipv6 child_limits fs_stream_chunks net_server http_server dgram worker_threads api_long_tail stream_consumers_readline
       esm_modules v8_shim async_promises fs_unwatch fs_promises_surface dns_lookup_service dns_resolve_any)
errors=0
ran=0
for name in "${cases[@]}"; do
    js="tests/js/$name.js"
    [ -f "$js" ] || js="tests/js/$name.mjs"
    [ -f "$js" ] || js="tests/js/$name.cjs"
    [ -f "$js" ] || js="tests/js/$name/main.js"
    [ -f "$js" ] || js="tests/js/$name/main.mjs"
    [ -f "$js" ] || js="tests/js/$name/main.cjs"
    if [ ! -f "$js" ]; then
        # A named case that does not resolve must fail the gate: silently
        # skipping is how coverage claims drift away from reality.
        echo "gate-sanitize: missing case $name" >&2
        errors=$((errors+1))
        continue
    fi
    ran=$((ran+1))
    expected=0
    [ -f "tests/golden/$name.exit" ] && expected="$(tr -d '[:space:]' < "tests/golden/$name.exit")"
    ASAN_OPTIONS=detect_leaks=$DETECT_LEAKS:exitcode=1 tmo 60 "$BIN" -A "$js" \
        >/dev/null 2>".dub/asan-$name.err"
    rc=$?
    if [ "$rc" -ne "$expected" ]; then
        # The sanitizer's own exitcode=1 is only valid where the test expects
        # a failure exit; a crash/hang/timeout is never masked by this check.
        echo "gate-sanitize: FAIL $name (rc=$rc expected=$expected)" >&2
        sed -n '1,25p' ".dub/asan-$name.err" >&2
        errors=$((errors+1))
        continue
    fi
    if grep -Eq 'ERROR: (Address|Leak)Sanitizer|SUMMARY: AddressSanitizer' ".dub/asan-$name.err"; then
        echo "gate-sanitize: FAIL $name (sanitizer report)" >&2
        sed -n '1,25p' ".dub/asan-$name.err" >&2
        errors=$((errors+1))
    fi
done
if [ "$errors" -ne 0 ]; then
    echo "gate-sanitize: $errors fixture(s) failed" >&2
    exit 1
fi
echo "gate-sanitize: ok ($ran cases)"
