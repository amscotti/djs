#!/usr/bin/env bash
# ASan/LSan pass over the fixture set. Any sanitizer report fails the gate.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
mkdir -p gates .dub
BIN="$ROOT/.dub/asan/djs-asan"
log="$ROOT/.dub/sanitize-build.log"
# Sanitizer flags live here rather than in dub.json: DUB warns about compiler
# flags in a package description (`-g` is DUB's `--build=debug`), and DFLAGS
# applies to this build only.
if ! DFLAGS="-fsanitize=address" dub build --config=sanitize --build=debug --force >"$log" 2>&1; then
    tail -20 "$log" >&2
    echo "gate-sanitize: build failed" >&2
    exit 1
fi
[ -x "$BIN" ] || { echo "gate-sanitize: $BIN missing" >&2; exit 1; }

cases=(hello fs_read fs_binary fs_buffers timers_clear microtasks microtask_throw
       rejection rejection_handled fatal_stops_callbacks throw timer_churn
       fs_meta fs_limits fs_write_gc rejection_late nul_path require_fs
       cjs_cycle cjs_interop cjs_throw_twice require_bound esm_chain json_import
       json_proto dynamic_import root_escape buffer_basic path_module os_module
       immediate fs_cp_io builtin_new_modules meta_space fs_deep_rm memory_usage
       fs_promises_extra node_modules_test node_modules_import
       node_modules_exports node_modules_exports_esm
       events_module stream_module url_util_module timers_clone_abort fs_streams fs_depth fs_depth_regress net_basic child_process child_async diagnostics_sse fork_ipc child_env tls_client_ca tls_mtls tls_alpn http2_tls cluster_basic process_stdio crypto zlib tls_fail node_compat node_partials http_keepalive https_server crypto_extra crypto_sign fs_watch dns_resolve fs_dir vm_basic web_streams websocket http2 fetch_headers fetch_stream buffer_full module_resolve stream_web_interop crypto_core http_upgrade blob_formdata fetch_decode webcrypto entry_scope upgrade_close dns_records assert_module stream_promises net_ipv6 child_limits fs_stream_chunks net_server http_server dgram worker_threads api_long_tail stream_consumers_readline
       esm_modules v8_shim async_promises rejection_handled fs_unwatch fs_promises_surface dns_lookup_service dns_resolve_any)
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
    ASAN_OPTIONS=detect_leaks=1:exitcode=1 timeout 60 "$BIN" -A "$js" \
        >/dev/null 2>".dub/asan-$name.err"
    if grep -Eq 'ERROR: (Address|Leak)Sanitizer|SUMMARY: AddressSanitizer' ".dub/asan-$name.err"; then
        echo "gate-sanitize: FAIL $name" >&2
        sed -n '1,25p' ".dub/asan-$name.err" >&2
        errors=$((errors+1))
    fi
done
if [ "$errors" -ne 0 ]; then
    echo "gate-sanitize: $errors fixture(s) failed" >&2
    exit 1
fi
printf 'gate-sanitize ok %s cases=%d sanitizer=clean\n' \
    "$(date -u +%FT%TZ)" "$ran" >> gates/sanitize.txt
echo "gate-sanitize: ok ($ran cases)"
