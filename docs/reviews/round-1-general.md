# Round 1 — General review (Phase 1 vertical slice)

**Reviewer:** general (correctness, clarity, D idioms, test quality, build reproducibility, plan conformance)
**Commit:** `64acfd2` ("Report detached ArrayBuffers on write"), clean tree at start
**Date:** 2026-10-21
**Verdict:** **APPROVE WITH CHANGES** — design and boundary are sound, the documented gates pass, but one gate-integrity defect, one always-on leak, and several error/ID bugs need fixing before Phase 2 builds on this.

## What I ran (not trusting the prior report)

| Command | Result |
|---|---|
| `./scripts/bootstrap.sh` | exit 0; LDC 1.36.0, DUB 1.36.0, libuv 1.48.0, Ninja 1.11.1, ABI probe ok, qjs smoke ok |
| `dub build --build=release` | exit 0 (after `--force`, clean relink) |
| `dub test` | exit 0, "3 modules passed unittests" |
| `./scripts/integration.sh` | 26 passed, 0 failed |
| `./scripts/check-no-phase-refs.sh` | exit 0 |
| All Phase 1 DoD commands | pass, incl. `exit_in_timer` rc 7, `microtask_throw` rc 1, `rejection` rc 1, REPL prints `2`, `throw.js` stack with `at inner`/`at outer` |

Additional probes found the defects below. Two were visible because the workspace's cached release build is ASan/LSan-instrumented: `./djs` is a hardlink into `~/.dub/cache/djs/~master/build/...` and `ldd` shows `libasan.so.8`, while `dub build --build=release --force` produces a clean binary (`ldd | grep asan` empty). Every invocation reports the RG-02 leak under LSan on some runs and exits 0 on others, depending on stack reachability of the leaked pointer — see RG-08. Source was not modified.

## Findings

### RG-01 — Critical — `dub test` replaces `./djs` with the unittest binary; later CLI checks pass vacuously
`dub.json:6` (`targetName`) + `dub.json:26` (unittest config). The unittest configuration inherits `targetName: "djs"`, so `dub test` writes its test executable over the CLI binary.

Evidence:
```
$ dub test            # "Running djs \n 3 modules passed unittests"
$ md5sum djs          # changed after dub test
$ ./djs -e 'console.log(1)'
                      # stdout EMPTY
3 modules passed unittests   # on stderr
$ echo $?             # 0
```
So immediately after `dub test`, `./djs <script>` runs no script and exits 0. Any DoD check issued between `dub test` and the next `dub build` (the PLAN §3 DoD block puts `dub test` before the manual `./djs ...` commands; BRIEF §DoD ends at integration) silently verifies nothing. `integration.sh` happens to rebuild first, which hides it.

**Fix:** give the unittest configuration `"targetName": "djs-unittest"` (or `"targetPath"`), and add `./djs -e 'console.log(1)'` as an explicit post-`dub test` gate assertion.

### RG-02 — Important — `runtimeTeardown` never frees the callback-registry table (2560 B leaked every run)
`runtime.d:590-646`: teardown calls `timersCloseAll`, `registryFreeAll` (frees the `JSValue`s, not the table), then frees context/runtime/loop/argv/self. `registryDestroy` is only called on the `fail:` path (`runtime.d:579`).

Evidence (LeakSanitizer on the release build described above; line numbers match current source):
```
Direct leak of 2560 byte(s) in 1 object(s) allocated from:
  #1 registryInit  src/djs/registry.d:36
  #2 runtimeCreate src/djs/runtime.d:523
  #3 runMain       src/djs/main.d:86
```
2560 = 64 slots × 40 B. Intermittent visibility (LSan only reports unreachable memory) explains why it does not fire on every run.

**Fix:** call `registryDestroy(&self.registry)` after the teardown `uv_run` drain (all in-flight completions done) and before `free(self)`. This is exactly ARCH §10 step 4; the table is runtime-owned memory, not a `JSValue`.

### RG-03 — Important — async fs ignores `uv_fs_*` and reports the wrong `syscall`
`fs.d:152-223` implements async I/O with `uv_queue_work` + blocking `open`/`read`/`write` (`doRead:63`, `doWrite:122`, queued at `:424`). ARCH §9.4 and PLAN Phase 1 require `uv_fs_*`, `uv_fs_req_cleanup` on every path, and short-read/short-write handling through libuv. Consequences today:
- no `uv_fs_req_cleanup` anywhere (there is no `uv_fs_t`);
- `fsAfterCb:189` and both sync error paths (`:352`, `:382`) hardcode `syscall = "open"` even when the failure was `read`/`write`;
- a read from a FIFO/device occupies a libuv threadpool thread with no cancellation seam (`uv_cancel` is declared but unused; `uv_queue_work` requests are not cancellable).

Evidence:
```
$ ./djs -e 'try{fs.readFileSync("tests/js")}catch(e){console.log(e.code,e.syscall)}'
EISDIR open          # Node: EISDIR, syscall 'read'
$ ./djs -e 'try{fs.writeFileSync("/tmp/x",{})}catch(e){console.log(e.name,e.message)}'
TypeError data must be a string, ArrayBuffer, or typed array   # fine
```
**Fix:** either move to `uv_fs_open/read/write/close` with `uv_fs_req_cleanup`, or (minimum) record which operation failed in `FsWork` and pass the real syscall name; update ARCH/PLAN to match whichever is chosen.

### RG-04 — Important — `readFile` silently corrupts binary data (no Buffer/Uint8Array result)
`fs.d:357` (sync) and `:192` (async) always build a JS **string** from the raw bytes. Invalid UTF-8 becomes U+FFFD, so `writeFileSync(p, readFileSync(p))` does not round-trip.

Evidence:
```
$ printf '\xff\xfe\x00A\x80B' > /tmp/bin1.dat
$ ./djs -e 'const s=fs.readFileSync("/tmp/bin1.dat"); console.log("jslen",s.length); fs.writeFileSync("/tmp/bin2.dat",s)'
jslen 6
$ xxd /tmp/bin2.dat
efbf bdef bfbd 0041 efbf bd42     # 9 bytes, two replacement chars
```
`writeFile` already accepts `ArrayBuffer`/typed arrays, so the asymmetry is surprising. BRIEF leaves Buffer open, but the current behavior is lossy without being documented.
**Fix:** return a `Uint8Array` when no encoding is given (Node's default), or document text-only in ARCH §9.4/COMPAT and add a test that pins the replacement-char behavior.

### RG-05 — Important — timer ids exceed Number precision after ~2^21 generations per slot
`registry.d:103` encodes ids as `(generation << 32) | index`; `timers.d:193` returns that as a JS Number (`jsFloat`). A double holds 53 bits: once `generation ≥ 2^21` and `index != 0`, the id is rounded, and `parseTimerId` (`timers.d:87`) decodes a different generation/index. `clearTimeout`, `ref`, `hasRef`, `refresh` then silently no-op (interval keeps firing; slot leaks until teardown).

Evidence (exact arithmetic for the encoding):
```
gen 2097152 idx 1: id 9007199254740993 -> 9007199254740992 -> gen_back 2097152 idx_back 0  MISMATCH
gen 2097152 idx 63: id 9007199254741055 -> 9007199254741056 -> idx_back 64             MISMATCH
```
Generation increments on both add and release, so ~1M timer creations on one slot reach this (minutes at 1 kHz). Unreachable in the current tests.
**Fix:** keep public ids < 2^53 — e.g. a per-slot monotonic `ulong` counter that never shifts, or return a string/index into a JS-side table — and `static assert`/runtime-check the bound.

### RG-06 — Important — `process.exit(code)` is overridden by a pending unhandled rejection
`runtime.d:349-361` `reportUnhandledRejections` unconditionally sets `failed = true; exitCode = 1`, and `runtimeRunScript:461` drains jobs before the loop notices `exitRequested`.

Evidence:
```
$ ./djs -e 'Promise.reject(new Error("x")); process.exit(3)'
Uncaught (in promise) Error: x
$ echo $?   # 1        (Node: 3)
```
An explicit exit code is part of the CLI contract (DoD checks exit codes) and should not lose to a rejection produced earlier in the same turn.
**Fix:** skip rejection reporting when `self.exitRequested` (Node parity), or set the failure code only if `!exitRequested`.

### RG-07 — Important — SIGPIPE kills the runtime; "a failed write is ignored" is false
ARCH §9.2 says a failed console write is ignored. `writeFd` (`runtime.d:74-86`) ignores the `write` return value but never suppresses `SIGPIPE`; there is no `signal(SIGPIPE, SIG_IGN)` anywhere in `src/`.

Evidence:
```
$ ./djs -e 'for (let i=0;i<20000;i++) console.log("abcdefghijklmnopqrstuvwxyz")' | head -1 >/dev/null
$ echo ${PIPESTATUS[0]}   # 141
```
**Fix:** ignore `SIGPIPE` at startup (`main`/`runtimeCreate`) and treat `EPIPE` as a no-op in `writeFd`; add a pipe-close integration check.

### RG-08 — Important — Phase 1's machine-checkable extras are absent; the D suite is thin
PLAN Phase 1 requires ASan with no invalid accesses, `JS_DUMP_LEAKS` clean, Valgrind "definitely lost" zero, and a counter test asserting **zero D GC allocations over 1,000 timer iterations**. There is no script, no result, and `gates/` is empty (ARCH §13 says each phase writes evidence there). `grep -ri 'fsanitize|DUMP_LEAKS|valgrind|allocat' src scripts dub.json` finds nothing but comments. The only ASan binary in the tree was a stale artifact (see RG-02), which is how the leak went unnoticed.

`dub test` runs three unittest blocks (`value`, `registry`, `runtime`). Timers, fs, process, console and the prelude have no unit tests; the registry test registers `jsUndefined` rather than a real function and never exercises `registryCancel`/`registryDetach`, so the ownership and cancellation paths are unverified. Integration golden files are otherwise honest: exact stdout diffs plus exit codes, and an accidentally-skipped async callback would fail the diff.

**Fix:** add `scripts/gate-sanitize.sh` (separate build dir, `-fsanitize=address`, `ASAN_OPTIONS=detect_leaks=1:exitcode=1`, run the fixture set), a GC-allocation counter test around 1k timer fires (druntime `GC.stats` before/after in a unittest, or `core.memory.GC` counters), record outputs in `gates/`, and add a registry test with a real JS function plus a cancel-then-fire case. Also make the sanitizer build hermetic: in this workspace a plain `dub build --build=release` hardlinks an ASan-instrumented binary from `~/.dub/cache`, so the gate's result depends on hidden cache state; `--force` (or `--cache=local`) produces a clean binary. With the RG-02 leak, the same script exits 1 under LSan on one run and 0 on the next, which would make an unhardened ASan gate flaky.

### RG-09 — Minor — dead code contradicts the documented Tier A pattern
`registryCancel` (`registry.d:164`) has no callers; the whole cancelled-in-flight path is unreachable. `Status`, `ErrorInfo` and `throwStatus` (`value.d:38-88`) are used only by their own unittest — ARCH §6.3/D-GUIDE §5 present this as *the* boundary pattern, but no production callback uses it. `jsIsObject`, `jsIsNumber`, `dupCString`, `freeCString`, `JS_NewArrayBufferCopy`, `JS_GetUint8Array`, `uv_cancel`, `uv_timer_again`, `uv_hrtime`, `uv_now`, `uv_version_string` are declared/defined but unused. `TimerState.delay` is written and never read.

**Fix:** delete the unused surface, or adopt the status/`ErrorInfo` trampoline in at least one real callback and implement cancellation through it; either way make code and ARCH agree.

### RG-10 — Minor — layout and docs drift from ARCH §12 / PLAN Phase 1
Missing: `src/djs/errors.d`, `src/djs/loop/timers.d`, `src/djs/loop/fs.d`, `src/djs/apis/buffer.d`; `src/djs/modules/` is an empty directory; timers and fs live in `apis/`. ARCH §12 lists the first three as the home of that code (G-14 was explicitly deferred to implementation "will confirm"). `dub.selections.json`, which D-GUIDE §1 says is committed, does not exist (harmless with zero dependencies, but the doc should say so).

README `:22` advertises "ESM + CommonJS local modules, JSON imports" under "What v0.1 does", but no module loader or `require` exists yet and `runtimeEval` always uses `JS_EVAL_TYPE_GLOBAL` (`runtime.d:429`), so `import`/`export` is a syntax error today. PLAN Phase 1's TODO checkboxes are all still `[ ]` despite being implemented.

**Fix:** either update ARCH/PLAN/README to the actual layout and current state (label README "target" vs "implemented"), or move the files; tick the Phase 1 TODOs.

### RG-11 — Minor — non-Error throws lose their value in the reporter
`runtime.d:276-295` prints "Uncaught " + `JS_ToCStringLen2(exc)`; for values that cannot be converted (Symbol, objects with a throwing `toString`) it prints `Uncaught <exception>`. `printExceptionValue`'s `self` parameter is unused.

Evidence: `./djs -e 'throw Symbol("s")'` → `Uncaught <exception>` (Node: `Uncaught Symbol(s)`).
**Fix:** special-case `JS_TAG_SYMBOL` (print the description) and drop the unused parameter.

### RG-12 — Minor — REPL: timers only run at EOF; Timeout prints a raw internal id
`main.d:22-64`: each line is evaluated and jobs drained, but the loop is not pumped between lines, so `setTimeout` output appears only after end of input; an interval makes the process run forever after EOF (rc 124 under `timeout`, Node-like but with no prompt to Ctrl-C from a pipe). The REPL echoes the `Timeout` value through `[Symbol.toPrimitive]`, printing `4294967296`.

Evidence:
```
$ printf 'setTimeout(()=>console.log("t"),0)\n' | ./djs
> 4294967296
> 
t
```
**Fix:** run a bounded `uv_run(UV_RUN_NOWAIT)` (plus job drain) after each line, and make `inspect` render `Timeout { delay, repeat, ref }` instead of the numeric id; document the REPL as line-at-a-time.

### RG-13 — Minor — fs error objects are Node-shaped but partly wrong
Beyond RG-03's `syscall`: `makeError` (`value.d:171-185`) constructs via `JS_NewError` and assigns `message` afterwards, so `err.stack` never contains the message (`Error` stacks are captured at construction); `errno` is only set for fs failures (`fs.d:47`), and `path` is absent from cwd/internal errors. `e.name` is `Error` for ENOENT (Node: `Error` too, ok), but the stack/message split will bite `console.log(err)` and any differential test in Phase 4.
**Fix:** create the error with `JS_ThrowTypeError`-style factory or pass the message to `JS_NewError` before setting fields, and set `errno`/`path` consistently.

### RG-14 — Minor — `process` snapshot semantics and hardcoded platform
`process.d:49-52` truncates env keys to 255 bytes in a stack buffer, silently merging/colliding longer names; `jsProcessPlatform` returns the literal `"linux"` (`:114`) regardless of build host; `process.env`/`argv` are snapshots taken at prelude install (`prelude.js:199-206`); `process.argv` includes DJS options (`djs -e code` → `["djs","-e",code]`) where Node's `-e` argv is `[node]`.
**Fix:** skip rather than truncate over-long keys (or allocate), derive platform from a build-time constant/`version(linux)`, and document the snapshot/argv divergence in COMPAT.

### RG-15 — Minor — misleading comment and import hygiene
`runtime.d:415-419` claims "QuickJS's parser wants a NUL-terminated buffer even when input_len is supplied" and copies every script. `JS_Eval` takes `input_len` precisely so the buffer need not be NUL-terminated; the copy is at best defensive. Unused imports: `memset` (`runtime.d:4`), `strlen` (`fs.d:5`), `malloc` (`registry.d:3`). `runtimeEval` also ignores `JS_EVAL_FLAG_STRICT`/module flags, which will need revisiting in Phase 2.
**Fix:** correct or delete the comment (cite the real constraint if one exists), trim imports.

## Top 5 (fix first)

1. **RG-01** — `dub test` clobbers `./djs`; gates after it can pass vacuously. (Critical)
2. **RG-02** — registry table leaked on every run; teardown never calls `registryDestroy`.
3. **RG-04** — binary files are silently corrupted by `readFile` → string → `writeFile`.
4. **RG-06** — `process.exit(code)` loses to a pending unhandled rejection (wrong exit code).
5. **RG-08** — Phase 1's ASan/leak/GC-allocation gates do not exist; `gates/` empty; D suite has no timer/fs/process coverage.

## Notes / non-findings

- The C boundary is genuinely clean: every `extern(C)` callback is `nothrow @nogc`, no D exception or delegate crosses it, blockable `Atomics` is disabled, and `ScopedValue`'s non-copyability is compile-tested.
- `uv_loop_close`/`uv_close` discipline is correct (handles closed, freed in close callbacks, `UV_EBUSY` → 70); teardown ordering otherwise matches ARCH §10.
- Microtask draining (`>0/0/-1`, budget, prepare/idle keep-alive, rejection reporting at end of drain) matches the documented contract in every probe I ran, including `m t` ordering and handled-vs-late rejections.
- Integration goldens are not vacuous: exact stdout `diff`, explicit `.exit` files, and stderr substrings that would fail if a callback never fired.
- `./scripts/bootstrap.sh` verifies the QuickJS commit and pins, and the ABI probe is real; build from a forced relink is reproducible.
