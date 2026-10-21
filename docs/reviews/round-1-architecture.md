# Implementation review round 1 — Architecture & Plan

**Reviewer role:** architecture & plan conformance (does the code implement the documented boundary; do loop/registry/teardown match §7/§9/§10; does the Phase 1 DoD actually pass; are docs and code in sync; is the layout per §12; are remaining gaps Phase 2/3 items rather than Phase 1 misses).
**Revision reviewed:** `64acfd2` ("Report detached ArrayBuffers on write") on top of `04803ff`, `1d89548`.
**Documents:** `BRIEF.md`, `docs/ARCHITECTURE.md` (v0.1), `docs/PLAN.md` (Phase 1), `docs/D-GUIDE.md`, `docs/REVIEWS.md`, `docs/PINS.md`, plus `scripts/*.sh`, `dub.json`, `vendor/quickjs-ng/quickjs.h` @ `6d46d07d`.
**Date:** 2026-10-21. **No code or documents were modified; this file is the only artifact.**

## Method

Read all of `src/djs/` (≈2.9k lines D + 262 lines prelude) against ARCH §6–§12 and PLAN Phase 1; checked every D ↔ C declaration used at the boundary against the pinned `quickjs.h`; ran the gates myself and probed behaviour the suites do not cover.

Gates run (this machine, current tree):

| Gate | Result |
|---|---|
| `./scripts/bootstrap.sh` | **pass** — LDC 1.36.0, DUB 1.36.0, libuv 1.48.0, ninja 1.11.1; commit match; ABI probe ok; `qjs` smoke ok |
| `./scripts/check-no-phase-refs.sh` | **pass** |
| `dub test` | **pass**, but only `3 modules passed unittests` (registry, value, runtime — the only modules with `unittest` blocks) |
| `./scripts/integration.sh` | **pass** — 26/26 (19 golden cases + 7 CLI checks) |
| PLAN Phase 1 DoD command list | **pass** (all listed commands reproduce) |
| PLAN Phase 1 "additional machine checks" (ASan/`JS_DUMP_LEAKS`/Valgrind, zero-GC-allocation counter) | **fail — nothing implements them** (RP-02) |
| ARCH §13 "machine-readable results to `gates/`" | **fail** — `gates/` empty and `.gitignore`d/untracked (RP-02) |

Extra probes (evidence quoted in the findings): `process.exit` while an fs read is blocked; `process.exit` followed by a same-turn `console.log`; rejection-then-timer; recursion overflow; `Uint8Array.subarray` write; `readFile` of a directory; `dub test` followed by `./djs`.

## Boundary conformance — summary

| Contract | Status |
|---|---|
| `JSValue`/`JSValueConst` layout + `static assert` (§6.1) | **pass** (`quickjs.d:15-32`); matches `quickjs.h`; probe independent |
| Declared signatures vs `quickjs.h` (§6.1/§6.3) | **pass** — spot-checked `JS_SetCanBlock(rt, bool)`, `JS_IsFunction`, `JS_IsArrayBuffer`, `JS_ToCStringLen2(...,bool)`, `JS_EnqueueJob`, `JS_ExecutePendingJob`, `JS_SetHostPromiseRejectionTracker`; all use `bool` in C too |
| No D exception unwinds into C (§6.3/§10) | **fail** — no `catch (Throwable)` in any `extern(C)` callback; only `main()` has one (RP-06) |
| Status-return trampoline (§6.3, D-GUIDE §5) | **not implemented** — callbacks throw JS exceptions directly; `Status`/`ErrorInfo`/`throwStatus` are dead code (RP-07) |
| `ScopedValue`, non-copyable, used on the D side (§6.2) | **type exists and is non-copyable; never used anywhere** (RP-07) |
| Allocator pairing (`js_malloc`/`js_free` vs `malloc`/`free`) (§6.3) | **pass** — no `js_malloc` yet (no normalizer); every `JS_ToCString*` freed with `JS_FreeCString` |
| No `JSValue` in GC memory (§6.2) | **pass** — `Runtime`, `CallbackSlot[]`, `TimerState`, `FsWork`, `RejectionEntry[]` are all `calloc`/`malloc` |
| `JS_GetOpaque2` / class IDs (§6.4) | **not applicable** — no native class objects; `fs`/`process`/`console` are plain objects of `JS_NewCFunction2` closures |
| Format-string rule (§6.3) | **pass** — every throw goes through `value.d:101-114` with a literal `"%s"` |
| `JS_SetPropertyStr` consumes its value (§6.2) | **pass** and documented at `value.d:145-167` |
| `-1` job path, 10k fairness budget (§7) | **pass** (`runtime.d:365-388`); `-1` prints from the returned `jctx`, sets exit 1, stops (`microtask_throw` proves it) |
| `uv_prepare` + `uv_idle` keep-alive (§7) | **pass** (`runtime.d:176-211, 539-556`) — prepare unref'd, idle ref'd only while jobs pending |
| `uv_close` lifetime, free in close cb (§9.3) | **pass** for timers/prepare/idle (`timers.d:55-85`, `runtime.d:213-216`) |
| `process.exit` is a request (§10) | **pass for the turn**, fails for teardown (RP-01): `process.exit(0); console.log("still here")` prints, exit 0; a timer at 20 ms does not run after `process.exit(7)` |
| Teardown sequence (§9.1, §10.1-§10.7) | **fail** — order inverted, `UV_EBUSY` path frees the loop, registry table leaked (RP-03/RP-05) |
| Layout per §12 | **partial** — `apis/timers.d` instead of `loop/timers.d`; no `loop/fs.d`, no `errors.d`; `registry.d` missing from §12; `loop/libuv.d` is declarations only (RP-09) |

## Findings

### RP-01 · Critical · `runtime.d:607-614` (with `apis/fs.d:403-424`, `152-161`) · `process.exit()` can hang forever, so the exit contract is not delivered

Teardown waits for the loop with `for (i < 16) uv_run(loop, UV_RUN_DEFAULT)`. `UV_RUN_DEFAULT` blocks until the loop has no active handles *or requests*, and fs work is `uv_queue_work` + blocking `open`/`read` in the threadpool (`fs.d:61-118`), which libuv cannot cancel. ARCH §10 step 3 says to use `uv_run(loop, UV_RUN_NOWAIT)`; §11 only permits teardown to run *past* the deadline, not to block indefinitely.

Reproduced:

```
$ mkfifo /tmp/djsfifo
$ timeout 6 ./djs -e 'fs.readFile("/tmp/djsfifo", (e,d)=>console.log("read-done"));
                     setTimeout(()=>{console.log("exiting"); process.exit(3);}, 10)'
exiting
exit=124            # never exits; the exit code is never delivered
```

A script that reads a FIFO, a device, or a slow NFS path and then calls `process.exit()` (or hits an uncaught error, which goes through the same teardown) hangs instead of exiting. The DoD's `exit_in_timer` case passes only because the pending work is a timer.

**Fix.** Replace the blocking loop with the documented shape: close handles, then `for (i = 0; i < N && uv_loop_alive(loop); ++i) uv_run(loop, UV_RUN_NOWAIT);` (optionally `uv_cancel()` in-flight requests first, best-effort). If the loop is still alive after the budget, print the count of live handles, do **not** free the loop, and exit 70 — matching §10 step 6's "leak rather than free".

### RP-02 · Critical · PLAN Phase 1 DoD L133-135, ARCH §13 L412-413 · Phase 1's mandatory machine checks do not exist, so the DoD does not pass as written

Phase 1 requires, beyond the shell commands:

- "ASan (`--fsanitize=address -g`) reports no invalid reads/writes; `JS_DUMP_LEAKS` reports no leaked `JSValue`s … Valgrind 'definitely lost' attributable to DJS is zero";
- "No GC allocation in the loop/binding path: a counter test asserts zero D GC allocations over 1,000 timer iterations";
- ARCH §13: "each phase writes machine-readable results to `gates/`".

None of these is implemented: `grep -RIn 'asan|valgrind|JS_DUMP_LEAKS|sanitize' scripts dub.json tests src` returns nothing; there is no `GC.`/`GCStats` counter anywhere (`grep -RIn 'GC\.' src tests` → empty); `gates/` contains only an untracked `.gitkeep` and `gates/` is in `.gitignore`, so gate evidence could not be committed even if produced. `integration.sh` writes to `tests/tmp/` (ignored, disposable) and never records a pass/fail summary anywhere durable.

This is the one DoD item the round cannot honestly check off, and it is exactly the item that would have caught RP-03.

**Fix.** Add `scripts/check-asan.sh` (build `--build=debug --dflags=-fsanitize=address --lflags=-fsanitize=address`, run the fixture set, fail on any `ERROR: AddressSanitizer`/`LeakSanitizer` report), a `-DJS_DUMP_LEAKS` debug configuration, a `unittest` that loops 1,000 `timer.start/clear` cycles around `GC.stats`/`GC.collect` and asserts zero collection growth, and have each script append a line to `gates/<gate>.txt` (un-ignore `gates/` and commit it).

### RP-03 · Important · `runtime.d:590-646`, `registry.d:51-59` · the registry slot table is leaked on every successful run

`runtimeTeardown` calls `timersCloseAll` and `registryFreeAll` but never `registryDestroy`; `registryDestroy` is only called on `runtimeCreate`'s failure path (`runtime.d:579`) and in the registry's own unittest. The 64-slot table (`64 × 40 B = 2,560 B`) is therefore leaked once per process — small, but it is a `malloc` with no matching `free`, and it fails the DoD's "Valgrind definitely lost attributable to DJS is zero" gate. It was visible in this tree's earlier LSan-instrumented binary:

```
Direct leak of 2560 byte(s) in 1 object(s) allocated from:
    #0 ... calloc
    #1 ... _D3djs8registry12registryInit ... src/djs/registry.d:36
    #3 ... djs.runtime.runtimeCreate ... src/djs/runtime.d:523
```

**Fix.** Call `registryDestroy(&self.registry)` in `runtimeTeardown` after `JS_FreeContext` (or right before `free(self)`), and add the leak gate from RP-02 so this class of bug is caught mechanically.

### RP-04 · Important · `apis/fs.d:61-161`, `392-435` · fs is not implemented on `uv_fs_*` as §9.4/§12 require, and the substitution loses the documented guarantees

ARCH §9.4 is specific: "Allocate `uv_fs_t` with `uv_req_size(UV_FS)`, read results with `uv_fs_get_result`/`uv_fs_get_ptr`, and always call `uv_fs_req_cleanup`"; "`readFile` uses `fstat` + a bounded read loop". ARCH §12 lists `loop/fs.d` as "uv_fs_* wrappers". The implementation instead does raw blocking POSIX calls inside `uv_queue_work` (`fs.d:61-161`, `424`) and has no `uv_fs_*` binding at all (`loop/libuv.d` has none). Consequences, all observable:

- **The memory budget is bypassed.** `doRead` grows its buffer by doubling with no size bound (`fs.d:80-100`); `JS_SetMemoryLimit` counts only the QuickJS heap (ARCH §11), so `fs.readFileSync("/dev/zero")` or a 4 GiB file allocates host memory without limit instead of failing against a documented bound.
- **Error metadata is wrong for non-open failures.** `fsAfterCb` passes `w.isWrite ? "open" : "open"` (`fs.d:189`), and the sync paths hard-code `"open"` (`fs.d:352, 382`), so a failing `read`/`write`/`close` reports `syscall: "open"`. Verified: `fs.readFile("/tmp", cb)` → `cb EISDIR open` (Node reports `EISDIR, read`).
- **No `uv_fs_req_cleanup` path exists to get wrong or right**, and short-write handling is hand-rolled (it is correct here, but it is bespoke code the architecture intended to avoid).
- It is also the direct cause of RP-01's uncancellable request.

**Fix.** Either implement §9.4 as written (`uv_fs_open/read/fstat/write/close` + `uv_fs_req_cleanup` on every path, with the `fstat` bound and per-op `syscall` strings), or amend §9.4/§12 to document `uv_queue_work` + blocking POSIX as the chosen design, including the cancellation consequences and the explicit read-size cap. Do not leave the doc claiming `uv_fs_*`.

### RP-05 · Important · `runtime.d:592-614`, `624-636` · teardown order is inverted relative to §9.1/§10, and the `UV_EBUSY` path frees memory the architecture says to leak

§9.1/§10 fix the order: stop/close JS-visible handles → run the loop until `uv_close` callbacks fire → `freeAll` (every `JSValue`) → `JS_FreeContext` → `JS_FreeRuntime` → `uv_loop_close`; step 1 marks slots *cancelled*, it does not free them. The code does `timersCloseAll` + `registryFreeAll` **before** `uv_close(prepare/idle)` and before any `uv_run` (`runtime.d:596-605`). It is safe today only because every completion re-checks `self.shuttingDown` before detaching (`fs.d:177`) and because `registryFreeAll` zeroes `freeHead`, so a late `registryDetach` fails closed. Any future completion that holds its own dup'd callback, or any code that registers during shutdown, turns this into a use-after-free of a `JSValue`. The "cancelled" state is never reached (RP-10), so the documented cancel-then-drain semantics are not exercised at all.

Second half: when `uv_loop_close` returns `UV_EBUSY`, §10 step 6 says "log the offending handles, leak rather than free them, exit 70". The code prints the error, leaves the loop memory **freed anyway** (`runtime.d:635`) and returns 70, then `free(self)` — leaving libuv handles and pending requests pointing at freed memory.

**Fix.** Reorder to §10 exactly: mark slots cancelled (not freed), `uv_close` all handles, bounded `UV_RUN_NOWAIT` drain, then `freeAll`, then `JS_FreeContext`/`JS_FreeRuntime`, then `uv_loop_close`; on `UV_EBUSY`, log `uv_loop_foreach` handles, *do not* `free(self.loop)`, exit 70.

### RP-06 · Important · all `extern(C)` callbacks (`apis/*.d`, `runtime.d`) · a D `Error` can unwind through QuickJS; the required last-resort net is missing

ARCH §6.3/§10 and D-GUIDE §5 require `catch (Throwable)` at the outermost frame of every `extern(C)` callback ("D exceptions must never unwind through QuickJS"), with print + `exit(70)`. `grep -Rn catch src` finds only `main.d:111` (a file-read `Exception`) and `main.d:139` (the process-level `Throwable` net). Every JS-callable function (`jsReadFileSync`, `jsTimerStart`, `jsProcessEnv`, `jsConsoleWrite`, `jsQueueMicrotask`, `fsAfterCb`, `onTimer`, `onPrepare`, `onIdle`, …) is a bare body. A bounds/`assert`/null `Error` raised inside one of them unwinds *through* `JS_Call`/`uv_run` frames to `main` — the exact undefined behaviour the rule exists to prevent. Today the code avoids obvious array indexing, but `fs.d:213` (`for i < argc` over `JSValue[2] args` with `argc` set to 2 in one branch) is one edit away from being that bug.

**Fix.** Wrap each `extern(C)` entry point (or use a `boundary!(fn)` template) in `try { … } catch (Throwable) { writeLiteral(2, "djs: internal error\n"); exit(70); }`. `try`/`catch` is legal in `nothrow @nogc` and adds nothing to the success path.

### RP-07 · Important · `bindings/value.d:11-88` · the documented ownership and status-trampoline machinery is dead code; the bindings use neither

ARCH §6.2 presents `ScopedValue` as the mechanism that makes "one owner per value" real, and §6.3/D-GUIDE §5 present the `Status` + `ErrorInfo` → `JS_Throw*` trampoline as *the* callback pattern. In the implementation:

- `ScopedValue` is defined, correctly `@disable this(this)`, has a negative compile test (`value.d:213-219`) — and is **never constructed anywhere** (`grep -RIn ScopedValue src` matches only `value.d`).
- `Status`, `ErrorInfo` and `throwStatus` are **never used** outside `value.d`'s own unittest; every binding calls `throwTypeError`/`throwInternalError` directly and returns `jsException()`, with manual `JS_FreeValue` on each path.

That is not a memory-safety failure (the manual pattern in this tree happens to balance), but it means the central docs describe a discipline the code does not follow, and the reviewer's main tool for auditing ownership does not apply. It also means the "no D exception across C" rule is unenforced (RP-06).

**Fix.** Pick one and make the other disappear: (a) adopt `ScopedValue` in at least the multi-value paths (`fsAfterCb`, `installPrimitives`, `processEnv`) and wrap callbacks in a status-returning helper, or (b) amend §6.2/§6.3 to say bindings throw JS exceptions directly, keep `ScopedValue` as an optional helper, and delete `Status`/`ErrorInfo`/`throwStatus` until a binding uses them. Do not ship three dead abstractions that the docs call mandatory.

### RP-08 · Important · `dub.json:31-37` · `dub test` overwrites `./djs` with the unittest executable, so DoD commands can run the wrong program

The `unittest` configuration keeps the default `targetName` (`djs`) and writes its executable at the package root, the same path the DoD uses for `./djs`. Reproduced:

```
$ dub test --force
$ ./djs -e 'console.log(3)'
3 modules passed unittests        # exit 0 — the runtime never ran
```

`dub build --build=release` afterwards restores the cached release artifact (and prints "up-to-date"), which is why `integration.sh` — which builds first — is green. But the PLAN/README gate order is `dub build; dub test; ./scripts/integration.sh`, and anyone who runs `./djs …` between `dub test` and the next build is testing druntime's unittest runner. This is precisely the "it compiles / it ran something" trap PLAN §5 warns about, and it makes an unattended gate script able to report a false pass.

**Fix.** Give the test configuration its own output: `"targetName": "djs-unittest", "targetPath": ".dub/unittest"` (and keep `tests/ut_main.d`). Then `./djs` always means the runtime.

### RP-09 · Important · ARCH §12 L358-385 vs tree · layout has drifted from the documented one, and the doc's `loop/` layer does not exist as described

Actual: `src/djs/{main,runtime,registry}.d`, `bindings/{quickjs,value}.d`, `loop/libuv.d`, `apis/{console,fs,process,timers}.d`, `js/prelude.js`.
Documented: `loop/libuv.d` ("uv declarations + loop wrapper"), `loop/timers.d`, `loop/fs.d`, `modules/{esm,cjs,resolve}.d`, `apis/{console,process,fs,buffer}.d`, `errors.d`.

Differences that matter, not just names:

- `loop/libuv.d` is a declaration file only (106 lines, no wrapper); the loop driver, job drain and keep-alive live in `runtime.d`. ARCH §4/§12 say the loop wrapper is `loop/libuv.d`, and PLAN Phase 1 lists the "loop wrapper, `uv_run` integration, `uv_prepare`/`uv_idle` job-keepalive" under `src/djs/loop/libuv.d`. A reader looking for the driver there finds nothing.
- Timers are in `apis/timers.d`, not `loop/timers.d` (PLAN Phase 1 says "`src/djs/loop/timers.d` + `apis/timers.d`", which is satisfied; ARCH §12 lists only `loop/timers.d`).
- `errors.d` does not exist; the uncaught/exception policy lives in `runtime.d:273-361`.
- `registry.d` (ARCH §9.1's "first-class component") is not in §12's tree at all.
- No `loop/fs.d` because there is no `uv_fs_*` (RP-04).

**Fix.** Amend §12 to the tree that exists (`registry.d`, `apis/timers.d`, error policy in `runtime.d`) or move the files; state explicitly that the loop driver is `runtime.runLoop` for now. Keep §12 as the single layout authority and make PLAN reference it rather than listing a second variant.

### RP-10 · Minor · `registry.d:106-118, 164-169`; `loop/libuv.d:99` · the registry's `cancelled` state and `uv_cancel` are unreachable, and a cancelled slot could never be reclaimed

PLAN Phase 1's registry TODO requires "cancelled-in-flight handling". `registryCancel` has no caller, `uv_cancel` has no caller, and `registryLookup` refuses any slot whose state is not `slotActive`, so a slot marked `slotCancelled` can never be found by `registryRelease`/`registryDetach` again — its `JSValue` would live until `freeAll` and its index would never return to the free list. No code exercises this today (timers release directly instead of cancelling), so it is currently dead-but-harmless; if a future `fs.cancel` uses `registryCancel` as written, it leaks one slot + one function reference per cancel.

**Fix.** Make `registryCancel` release-if-possible (`if no in-flight request: JS_FreeValue + free slot`) and let `registryDetach` accept `slotCancelled` so an in-flight completion can reclaim it; or delete `registryCancel`/`slotCancelled` until a cancellable API exists, and say so in PLAN.

### RP-11 · Minor · `apis/timers.d:87-97, 193`; `js/prelude.js:166` · timer ids are exposed as doubles; ids above 2^53 silently stop clearing

`jsTimerStart` returns `jsFloat(cast(double) id)` where `id = (generation << 32) | index`, and `parseTimerId` converts back with `toFloat64` + `cast(ulong)`. The id is exact only while `generation < 2^21`; after ~2M reuses of the same slot the double rounds, `clearTimeout`/`ref`/`hasRef`/`refresh` miss, and the timer becomes unclearable (it still fires). The trigger is long-running or soak tests (Phase 4's 10k timer/fs cycles are close enough to matter for smaller capacities).

**Fix.** Return the id as a `BigInt` (JS_NewBigInt64) or a two-number pair, or keep ids ≤ 2^53 by using a 20-bit generation + 32-bit index with explicit wraparound. Add a unittest that forces slot reuse.

### RP-12 · Minor · `apis/timers.d:107-135`, `255-276`; ARCH §9.3 · FIFO tie-breaking is delegated to libuv, and `refresh()` can resurrect a fired one-shot

ARCH §9.3 says equal deadlines fire in insertion order "tracked by a monotonic sequence number". DJS keeps no sequence number; it relies on libuv's `start_id` tie-break (libuv 1.48 does order equal timeouts by start id, so behaviour matches — but the stated mechanism is not what runs, and nothing tests it beyond two 0 ms timers in `timers_order`). Separately, `Timeout.refresh()` when `_id == 0` calls `_start()` (`prelude.js:160-164`), re-arming a timer that already fired or was cleared; Node's `refresh()` on an inactive timer is a no-op. `timeout_api.js` only refreshes a live timer, so neither behaviour is pinned.

**Fix.** Either note in §9.3 that libuv's start-id ordering provides FIFO (and cite the version), or track a sequence number in `TimerState`. Make `refresh()` a no-op when `_id == 0`, and add a test for it.

### RP-13 · Minor · `js/prelude.js:6-58`; `tests/golden/console_format.txt` · inspect depth does not match Node, and the golden encodes the divergence

ARCH §9.2 says "depth 2"; the implementation truncates only when `depth > 2`, so `console.log({a:{b:{c:1}}})` prints `{ a: { b: { c: 1 } } }`, while Node's default `util.inspect` prints `{ a: { b: [Object] } }`. The committed golden locks in the DJS behaviour, so the Phase 4 differential suite will disagree with its own oracle on the first console test unless this is decided now. Also `%d`/`%f` use `String(Number(x))` so `%d` on `"3.9"` prints `3.9` while Node's `%d` prints `3` (the golden currently only exercises `%d` with a number).

**Fix.** Define depth in §9.2 as "3 nested object levels (Node default)" or change the truncation to `depth >= 2`; decide `%d` (`Number` + truncate) vs `%f`, and add both cases to `console_format.js` so the choice is pinned.

### RP-14 · Minor · `README.md:14-20`; `js/prelude.js:199-206` · docs claim module support the code does not have, and `process.env` is a snapshot

README's "What v0.1 does" lists "ESM + CommonJS local modules, JSON imports" with no status caveat; in this revision `import` is a syntax/runtime failure and `typeof require === "undefined"` (verified). That is consistent with PLAN Phase 2 and therefore not a Phase 1 gap, but a reader (or the next round's reviewer) cannot tell shipped from planned. Related, smaller: `process.env` is materialised once at prelude install (`prelude.js:201`), so `process.env.X = "y"` does not reach child processes or `environ`; Node's is live.

**Fix.** Add a one-line status block to README ("Phase 1 vertical slice: console/timers/process/fs; modules are Phase 2") and a §9.2/§9.3-style note that `process.env` is read-only/snapshot in v0.1.

### RP-15 · Minor · `D-GUIDE §1`; `scripts/bootstrap.sh:11-16, 84-85` · two pin/build statements disagree with the tree

(a) D-GUIDE says "`dub.selections.json` is committed"; there is no such file in the repo (`git ls-files` confirms), and ARCH's risk table names it as a mitigation. With zero D dependencies it is an empty file, but the pin rule says it should exist.

(b) ARCH §12 says `QJS_BUILD_LIBC=OFF` is preferred; `bootstrap.sh` does not pass it and requires `build/qjs` for the smoke test, so libc is built in the same directory. It is not linked (`dub.json` links only `qjs`), so the "never link `libqjs-libc.a`" rule holds, but the build does not do what the doc prefers, and the stamp records only the four flags actually passed.

**Fix.** Commit `dub.selections.json`; add `-DQJS_BUILD_LIBC=OFF` for the library build and build `qjs` (if still wanted as an oracle) in a second build dir, as §12 already describes; update the stamp format accordingly.

## What is good and should not change

- The C boundary is real: `JSValue` layout is asserted and independently probed, every callback is `extern(C) nothrow @nogc`, all C memory is `malloc`/`free` or QuickJS-owned, and no `JSValue` sits in GC memory. I found no ABI mismatch in any declaration used.
- The job pump matches §7's difficult parts: exact `>0`/`0`/`-1` contract, `-1` reported from the returned context and treated as fatal, 10k fairness budget, unref'd `uv_prepare` + on-demand ref'd `uv_idle`, and a rejection set that is evaluated at the end of each drain (so `rejection_handled` exits 0 and `rejection` exits 1 — both verified).
- Timer lifetime is right: generation-checked ids, handle freed only in `onTimerClosed`, dup-before-call so a callback may clear itself, `clearTimeout(undefined)`/double-clear are no-ops, `unref()` drops the loop ref (`timer_unref_exit` proves the process exits).
- `process.exit` is a request, not a free: same-turn JS continues, the loop stops, teardown is outside the callback. The one place this breaks is teardown (RP-01), not the callback contract.
- fs copies the input buffer before queueing (§9.4's v0.1 rule). `Uint8Array.subarray(1,3)` writes exactly `[2,3]`; a directory read reports `EISDIR`; sync variants are plain blocking POSIX and never re-enter JS.
- Errors are honest at the edges: uncaught exception → `Uncaught Error: kaboom` + frames + exit 1; microtask throw → exit 1; stack overflow → `Uncaught RangeError: Maximum call stack size exceeded`, exit 1 (no crash); format strings are always literals.
- The integration suite is behavioural, not tautological: golden stdout is exact, exit codes are separate files, stderr is asserted by required substring, and the seven CLI checks cover `-e`, promise, microtask-vs-timer order, `--version`, `process.exit`, missing file and the REPL. The gaps are missing cases (RP-02/RP-12), not fake ones.
- Phase 2/3 gaps are the right ones: no modules, no `stat`/`readdir`/`mkdir`/`unlink`, no `--timeout`/`--memory-limit`, no `memoryUsage`, no ESM/CJS interop, no `Buffer`. Nothing from Phase 2/3 is silently claimed as done. The two Phase 1 items that *are* silently partial are fs-on-`uv_fs_*` (RP-04) and registry cancellation (RP-10).

## Verdict

**APPROVE WITH CHANGES.**

This is a working vertical slice, not a sketch: the documented boundary is largely implemented, the hard loop semantics (`-1`, keep-alive, per-turn budget, rejection timing) are correct and tested, and every gate that exists passes. It should not go to Phase 2 as-is, because Phase 1's DoD is not actually met (RP-02, RP-03) and one documented exit guarantee is false under a realistic condition (RP-01). None of the findings requires an architectural change; RP-01, RP-02/RP-03, RP-04, RP-05/RP-06 and RP-07 should be fixed in this round's fix pass, with RP-09's doc sync in the same edit.

## Top 5

1. **RP-01 — make teardown non-blocking.** Bounded `UV_RUN_NOWAIT` loop (+ best-effort `uv_cancel`), leak-and-exit-70 if the loop will not drain. Today `process.exit()` can hang forever behind a blocked fs read, and the `UV_EBUSY` path frees the loop anyway (RP-05).
2. **RP-02 + RP-03 — make the Phase 1 DoD true and provable.** Add the ASan/`JS_DUMP_LEAKS`/Valgrind script and the 1,000-iteration zero-GC-allocation test, write evidence to a committed `gates/`, and fix the registry-table leak (`registryDestroy` in `runtimeTeardown`) that those gates will immediately find.
3. **RP-04 — put fs back on the documented contract.** Either `uv_fs_*` + `uv_fs_req_cleanup` + `fstat` bound + per-operation `syscall`, or amend §9.4/§12 and cap the read size explicitly; the current `uv_queue_work` version bypasses `JS_SetMemoryLimit`, mislabels every failure as `open`, and is uncancellable.
4. **RP-05 + RP-06 — restore the boundary/teardown invariants.** Teardown in §10 order (cancel, close, drain, freeAll, free context/runtime, loop close; never free on `UV_EBUSY`), and a `catch (Throwable)` → print + `exit(70)` net at every `extern(C)` entry so no D `Error` can unwind through QuickJS.
5. **RP-07 + RP-09 — stop the docs from describing code that does not exist.** Either use `ScopedValue`/the status trampoline in the bindings or delete them and amend §6.2/§6.3; align §12 with the real tree (`registry.d`, `apis/timers.d`, error policy in `runtime.d`, driver in `runtime.runLoop`) so round 2 reviews against truth.
