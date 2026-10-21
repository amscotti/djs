# Doc review — round 1, adversarial

**Reviewer:** adversarial (failure modes, memory safety, concurrency, security)
**Scope:** `BRIEF.md`, `docs/ARCHITECTURE.md` (ARCH), `docs/D-GUIDE.md` (GUIDE), `docs/PLAN.md` (PLAN), `docs/PINS.md`
**Basis:** claims checked against `vendor/quickjs-ng` at `6d46d07` (v0.17.0) — `quickjs.h`, `quickjs.c`; libuv 1.48 system headers (`sizeof(uv_timer_t)=152`, `sizeof(uv_fs_t)=440`, `sizeof(uv_loop_t)=848`, `offsetof(data)=0` in all three).
Assumption throughout: the design will be implemented by someone following these documents literally. Findings are about what the documents *tell them to build*, not about intentions.

**Severity:** Critical = crash/UAF/hang/security in a normal script or a plausible host. Important = wrong behavior, leak, or gate that cannot hold. Minor = build/CI/portability debt.

---

## Critical

### A-01 — `process.exit` as specified is a use-after-free in QuickJS's own job loop
**Where:** ARCH §10 (l.216), §5 (l.87); PLAN Phase 1 (`process.exit`).
**Claim:** "`process.exit(code)` stops the loop and exits immediately after freeing the runtime; destructors that need the loop must run before."

**Failure:** `process.exit` is a native function. Its C stack is `Runtime.run → uv_run → JS_ExecutePendingJob → job_func → js_process_exit → JS_FreeRuntime`. `JS_FreeRuntime` (`quickjs.c:2639`) runs `JS_RunGC`, frees the job list, then frees every remaining object and the malloc arena. Control then returns into `JS_ExecutePendingJob`, which at `quickjs.c:2543-2550` does `JS_FreeValue(ctx, e->argv[i])`, `JS_FreeValue(ctx, res)`, `js_free(ctx, e)` on the now-freed runtime. Immediate UAF inside QuickJS. Same for every `ScopedValue` destructor still on the stack, and `js_free_rt` has an explicit `abort()` on malloc-state underflow (`quickjs.c:2036-2040`).

Second problem: even without the free, `process.exit()` **returns to JS**. `process.exit(0); console.log("still here")` prints. There is no safe way to abandon the C stack short of `longjmp` (which would skip D destructors) or `_exit`. The doc promises Node semantics it cannot deliver.

Third: "destructors that need the loop must run before" is inverted — destructors run *after* the call, during unwind, and by then the loop is stopped.

**Fix:** specify a shutdown state machine. `process.exit(code)`: flush `console` (already synchronous), set `exitRequested/exitCode`, `uv_stop(loop)`, return `JS_UNDEFINED` — JS continues to the end of the current turn, which must be documented as a divergence. Hard exit, if wanted, is a separate `process.reallyExit` → `_exit(code)` after `fsync`/flush. Runtime free happens only in `main`, after the loop returns, after `uv_loop_close` succeeds, and after every host-held `JSValue` is released. Add "no `JSValue` may outlive `JS_FreeRuntime`" to §6.2 as an explicit rule (it is currently implied by "one owner" but never stated as an ordering constraint).
**Test:** `tests/js/exit_in_timer.js`: `setTimeout(() => { process.exit(0); console.log("after"); }, 0)` → exit 0, no "after", ASan clean. `exit_during_fs.js`: `fs.readFile(big, () => process.exit(0))` → ASan/Valgrind clean, no `abort()`.

---

### A-02 — the prescribed job-drain loop drops microtask exceptions
**Where:** ARCH §7 (l.169) — "call `JS_ExecutePendingJob(rt, &ctx)` in a loop until it returns 0".
**Reality:** `JS_ExecutePendingJob` returns **1** (ran a job), **0** (queue empty), **-1** (job threw) — `quickjs.c:2526-2553`. The natural reading, `while (JS_ExecutePendingJob(rt, &ctx)) {}`, treats **-1 as truthy**: it keeps looping, drains whatever else is queued, then exits on 0 — and the return value is never inspected. The exception stays pending in `*pctx`. The doc's wording gives the implementer no reason to distinguish -1 from 1.

**Failure:** `Promise.resolve().then(() => { throw new Error("boom") })` → no stderr, exit 0. That directly violates BRIEF l.25 ("uncaught exceptions and rejected promises ... set a non-zero exit code") and the Phase 1 DoD. Worse, because the exception is still pending, the next API call that checks it (`JS_Call`, `JS_Eval`, `JS_GetPropertyStr` in the error reporter) fails at an unrelated site with an unrelated message — or, if the script ends first, the failure is invisible and the exit code is 0.
**Fix:** state the exact contract in §7:
```d
int r; JSContext* jctx;
while ((r = JS_ExecutePendingJob(rt, &jctx)) > 0) { /* budget check */ }
if (r < 0) uncaught(jctx);   // take jctx's exception, print, exit non-zero
```
plus a per-turn job budget (e.g. 10k) so a self-feeding promise chain cannot starve libuv; on budget exhaustion, yield to the loop and continue next iteration rather than dropping jobs.
**Test:** `tests/js/microtask_throw.js` → stderr contains `boom`, exit 1. `microtask_chain.js` (`function f(){Promise.resolve().then(f)}; f()`) with a 1 s `--timeout` must terminate, and a timer scheduled before the chain must still fire.

---

### A-03 — unhandled-rejection policy as written produces false "unhandled rejection" exits
**Where:** ARCH §10 (l.215) — "install `JS_SetHostPromiseRejectionTracker`; print the reason and stack at loop drain, exit 1."
**Reality:** the tracker is called **twice** for the same promise: once with `is_handled=false` at rejection, and again with `is_handled=true` when a handler is attached (`quickjs.c:55533-55543`, `js_promise_set_handled`). It receives **borrowed** `JSValueConst promise, reason` — `quickjs.h:1181`.

**Failure 1 (false positive):**
```js
const p = Promise.reject(new Error("boom"));
p.catch(e => console.log("caught"));
console.log("ok");
```
Standard code. The tracker fires `is_handled=false` before `.catch` is attached. If DJS records "unhandled" then prints at drain, this prints `ok`/`caught`, then reports an unhandled rejection and exits 1.

**Failure 2 (UAF):** storing `promise`/`reason` in a malloc'd pending list without `JS_DupValue` leaves dangling pointers as soon as the GC runs; storing *with* dup and forgetting to `JS_FreeValue` before `JS_FreeRuntime` is the A-01 crash again.

**Fix:** track a set of rejected promises (dup'd); on `is_handled=true` remove and free; report only promises still in the set **after the job queue is empty and before the next macrotask**, which matches Node closely enough to test against it. Never read `.stack` inside the tracker (A-14).
**Test:** the three lines above → exit 0. Plus `const p = Promise.reject(new Error("x")); setTimeout(()=>{}, 10);` → exit 1 with `x`.

---

### A-04 — `writeFile`/`readFile` do not pin the JS buffer: GC frees it mid-request
**Where:** ARCH §9 (l.202) `writeFileStart(...)`, §6.4; PLAN Phase 1 `fs.readFile`/`writeFile`.
**Claim:** primitives take `(path, callbackId)`; no statement about buffer lifetime.

**Failure:** `fs.writeFile(p, buf)` hands `JS_GetArrayBuffer`'s pointer to `uv_fs_write` and returns. `buf = null;` then any allocation triggers QuickJS GC → the ArrayBuffer's backing store is freed → the threadpool writes from freed memory. Silent file corruption or SIGSEGV. Same for `JS_DetachArrayBuffer` called by script, and for a `Uint8Array` *view*: `JS_GetArrayBuffer` returns NULL for typed arrays (must use `JS_GetTypedArrayBuffer` + `byteOffset`/`byteLength`, `quickjs.h:1121`), so a subarray write either crashes on NULL or writes the wrong region.
**Fix:** the native request struct holds a dup'd `JSValue` of the buffer and the *view's* offset/length; free the dup in the completion callback after `uv_fs_req_cleanup`. Re-fetch the raw pointer immediately before `uv_fs_write`; never cache it across calls. State this in §6.4 as the canonical example of native-state ownership.
**Test:** `fs_write_gc.js`: allocate a 4 MiB buffer, `fs.writeFile`, drop the reference, force `gc()` (expose it in debug builds), verify file contents; run under ASan. `fs_write_subarray.js`: write `buf.subarray(2,6)` and compare bytes.

---

### A-05 — user-controlled strings are passed as printf formats at the boundary
**Where:** ARCH §6.3 (l.152-154): "Convert failure to a JS exception with `JS_ThrowTypeError` / `JS_ThrowInternalError`". GUIDE §5 (l.143) shows the safe form but no rule is stated.
**Reality:** `JS_ThrowTypeError(ctx, fmt, ...)` is `printf`-style. Passing a path, a module specifier, or an env value as `fmt` is format-string injection.

**Failure:** `fs.readFile("%s%s%s%s")` → the error path does `JS_ThrowTypeError(ctx, path)` → `vsnprintf` reads nonexistent varargs → SIGSEGV, or leaks stack words into a JS exception the script can print (`fs.readFile("%p.%p")`). Same for `require("%n")` and for any error message built by concatenation.
**Fix:** hard rule in §6.3 and in the review checklist: *no user-controlled string may be a format argument*; always `JS_ThrowTypeError(ctx, "%s", msg)`, and for non-NUL-terminated data `"%.*s"` with an explicit `int` length (as GUIDE already does). Add a grep-able lint for `JS_Throw*Error(ctx, <non-literal>` in the boundary modules.
**Test:** `djs -e 'try{require("%s%n")}catch(e){console.log("ok")}'` → prints `ok`, no crash; run under ASan.

---

### A-06 — `JS_GetOpaque` on a non-object returns NULL; every native method must use `JS_GetOpaque2`
**Where:** ARCH §6.4 (l.159-160) — "uses a QuickJS class ID and `JS_SetOpaque`/`JS_GetOpaque`".
**Reality:** `JS_GetOpaque` returns NULL for a non-object **and** for the wrong class (`quickjs.c:12114-12123`). `JS_GetOpaque2` throws a TypeError instead (`quickjs.c:12125`), and `JS_SetOpaque` returns `int` (ignored in the doc).

**Failure:** any method whose `this` is attacker-controlled — `fs.readFile.call(42, "/etc/passwd", cb)` or `Reflect.apply(handle.read, {}, [])` — yields `NULL` into D, and the first field access is a SIGSEGV. A hostile six-line script kills the process; a REPL user's typo kills the session. This is the cheapest crash in the whole design.
**Fix:** §6.4 must say: all opaque reads go through `JS_GetOpaque2`, check for NULL, return `JS_EXCEPTION`; check `JS_SetOpaque`'s return. Also state that the class ID is per-runtime (see A-19).
**Test:** `djs -e 'try{fs.readFile.call(1,"x",()=>{})}catch(e){console.log(e.name)}'` → `TypeError`, exit 0.

---

### A-07 — the GUIDE's truncated C-struct pattern is heap corruption, not a style choice
**Where:** GUIDE §4 (l.102-105):
```d
extern(C) struct uv_timer_t { void* data; /* ... fields you actually access */ }
```
**Reality:** `uv_timer_t` is 152 bytes on x86_64; `data` happens to be at offset 0 (measured). The *field offsets* are right; the *size* is 8. Any `malloc(uv_timer_t.sizeof)`, `new uv_timer_t`, static array, or `emplace` allocates 8 bytes and `uv_timer_init` writes well past the end of it → heap overflow into the next chunk. `uv_fs_t` is 440 bytes, `uv_loop_t` 848. The comment "keep the full prefix if you access any" does not protect the allocation site, and the example is the copy-paste source for `loop/libuv.d`.

**Failure:** every timer creation writes 144 bytes past the allocation; with `-release`/`noBoundsCheck` nothing complains until an unrelated object is corrupted.
**Fix:** two acceptable patterns, one of which must be prescribed: (a) declare the **full** struct as a C mirror generated from `uv.h` (a checked-in generated `libuv_types.d` with `static assert` on every size, verified by `scripts/bootstrap.sh`), or (b) opaque `struct uv_timer_t;` plus `uv_handle_size(UV_TIMER)` / `uv_req_size(UV_FS)` for allocation and `void*` for the API. (b) is the cheap one and matches libuv's own ABI contract; it also survives libuv upgrades. Never allocate a truncated mirror.
**Test:** a D unittest that allocates via the chosen path and `static assert`s `uv_handle_size(UV_TIMER) >= 152`; run the timer soak under ASan. Add `_Static_assert(sizeof(uv_timer_t) == uv_handle_size(UV_TIMER))` to the C shim.

---

### A-08 — the JSValue ABI is conditional and nothing in the build fails closed
**Where:** ARCH §6.1 (l.95-110), `static assert(JSValue.sizeof == 16)`.
**Reality:** the 16-byte layout only exists under `!JS_NAN_BOXING` (`quickjs.h:315-327`). `JS_NAN_BOXING` is auto-defined when `INTPTR_MAX < INT64_MAX` (`quickjs.h:173-176`) — i.e. every 32-bit target, including x86 Windows and wasm32, which the "keep the Windows/macOS seams" claim implies. Under `JS_CHECK_JSVALUE` (a supported debug mode) `JSValue` becomes a pointer and `JSValueConst` a `const JSValue*` (`quickjs.h:223-226`), changing every boundary signature. D's `static assert` checks the **D** struct, which is unconditionally 16 bytes — it cannot see the C build. So the assert passes while the ABI mismatches: arguments are read from the wrong registers, `JS_FreeValue` gets garbage pointers, and the failure is silent corruption.

Also: `JSValueConst` is `#define JSValueConst JSValue` (`quickjs.h:202-204`), so D's `alias JSValueConst = JSValue` is layout-correct but discards the only compile-time defense against freeing a borrowed value — the exact bug class ENGINE's own debug mode exists to catch.

**Fix:** fail closed at build time with a generated C probe compiled by the same flags/toolchain as `libqjs.a`:
```c
_Static_assert(sizeof(JSValue) == 16, "DJS requires the non-NaN-boxed 64-bit JSValue");
#ifdef JS_NAN_BOXING
#error "JS_NAN_BOXING must be off"
#endif
#ifdef JS_CHECK_JSVALUE
#error "JS_CHECK_JSVALUE must be off"
#endif
```
and assert the exported `JS_GetVersion()`/pointer size at startup. In D, make borrowed values a distinct type at the helper layer (`struct Borrowed { JSValue v; }`, ABI-identical, accepted only by `JSValueConst` parameters) so `JS_FreeValue(borrowed)` is a compile error. `scripts/bootstrap.sh` must verify the flags it built QuickJS with.
**Test:** build with `-DJS_NAN_BOXING=1` → build fails with a readable error; a D unittest that `static assert(Borrowed.sizeof == JSValue.sizeof)`.

---

## Important

### A-09 — `--timeout` does not cover the paths that actually hang
**Where:** ARCH §11 (l.223); PLAN Phase 3 DoD (l.178).
**What the engine gives you:** the interrupt handler runs only in the interpreter and in libregexp polling (`quickjs.c:8657`, `49646`), and `JS_ThrowInterrupted` marks the error **uncatchable** (`quickjs.c:8647-8652`, `JS_SetUncatchableError`) — good, `try/catch` cannot defeat it. What it does **not** cover: a native call that blocks.

**Failure:** `djs --timeout 100 -e 'fs.readFileSync("/dev/stdin")'` with stdin a pipe that never closes → blocks in `read(2)` forever; the deadline is never polled. Same for the module loader reading a FIFO (`import "./fifo.js"`), for `uv_run` waiting on a timer 10 hours out, and for a threadpool job stuck on a wedged NFS mount. The DoD line "`--timeout 100 tests/js/infinite.js` exits non-zero, no hang" only tests the one case that works.
**Fix:** define `--timeout` as "CPU deadline, checked by the interrupt handler" (honest) and add a wall-clock watchdog: a `uv_timer` armed at the deadline that, when the loop is reached, prints `timeout` and `_exit(124)`. That covers loop-level hangs but not a blocked native call; for those, the only fix is non-blocking I/O or a watchdog **thread** that `_exit`s. State which guarantee is being sold. Also document that `JS_SetCanBlock` is left false so `Atomics.wait` cannot block the thread.
**Test:** the stdin case with a 1 s timeout must exit non-zero within 2 s (or be documented as unsupported); `while(1){try{}catch{}}` interrupted at the deadline; a regexp bomb `/(a+)+$/.test("a".repeat(40)+"!")`.

---

### A-10 — sync fs has no implementation story; via `uv_run` it re-enters JS from inside a JS call
**Where:** ARCH §7 (l.171) "Never call `uv_run()` from inside a JS callback"; PLAN Phase 1 "`readFile` (callback + promise + **sync** where cheap)"; BRIEF §v0.1 (l.23) "sync where practical".
**Problem:** the documents forbid the only implementation they leave open. If `readFileSync` is "start async + spin `uv_run(UV_RUN_ONCE)` until done", then a timer/fs callback can run *inside* `readFileSync`: observable reordering, recursion into JS while the native frame is live, and `readFileSync` nested inside its own completion → unbounded C-stack growth. If instead it is blocking `open/read/close` (what Node does), the loop is blocked — correct, but must be stated, and then A-09 applies.

**Failure:** `setTimeout(()=>log("t"),0); fs.readFileSync(big); log("after")` may print `t` before `after` (nested loop) or after (blocking). `readFileSync` inside a fs completion callback re-enters the loop recursively.
**Fix:** prescribe blocking libc calls for the sync variants (a separate `fs_sync.d`), never `uv_run`; add "sync variants block timers and I/O by design" to COMPAT/ARCH. Keep them out of the `@nogc` requirement (they may use a caller buffer, but a `malloc`'d read buffer is fine).
**Test:** ordering test above with a 5 s timer and a 50 ms read → `after` then `t`, exactly once; and a test asserting no timer fires during a 200 ms sync read.

---

### A-11 — timer ids as handles: stale id → UAF; `uv_close` twice → abort
**Where:** ARCH §9 (l.203) `__djs.timer.start(...)` / `cancel(id)`; §7 keep-alive.
**Failure modes:**
1. `const t = setTimeout(f, 0); setTimeout(() => clearTimeout(t), 50)` — the one-shot handle was stopped, `uv_close`d and freed in its close callback; `clearTimeout` now calls `uv_timer_stop`/`uv_close` on freed memory.
2. Heap address reuse: create and clear 1,000 timers, then `clearTimeout(oldId)` whose address was reused by a *new* timer → silently cancels the wrong timer. Non-deterministic and nearly impossible to debug.
3. `clearInterval(i)` twice, or `clearTimeout` on an already-closing handle → `uv_close` asserts ("uv_close called on closing handle"); in release libuv it is UB.
4. Freeing the handle in `uv_timer_stop` instead of the close callback → UAF when the loop next touches it.

**Fix:** ids are opaque `uint64` slots in a runtime-owned table: `{uv_timer_t*, generation, state: active|closing|dead}`. `cancel` looks up the slot, ignores `dead`, and `closing` is idempotent; the slot is freed only in the `uv_close` callback, and the generation increments on reuse. Keep one ref on the loop per active timer, drop it on stop (not on close).
**Test:** the three scripts above under ASan; a 10k create/clear soak asserting the table size returns to baseline.

---

### A-12 — `readFile`/`writeFile` as specified silently truncate, and leak fds on error
**Where:** ARCH §9, PLAN Phase 1/3 `fs`.
**Failure:** (a) `stat` then one `uv_fs_read` of `st_size` returns short data when the file grows, and returns **0 bytes for `/proc/*` and `/sys/*`** (stat size is 0) — `fs.readFileSync("/proc/self/status")` returns `""`, a bug users hit immediately. (b) `uv_fs_write` can complete short (ENOSPC, EINTR, pipe) and the doc has no loop. (c) `uv_fs_open` succeeds, `uv_fs_read` fails, and the fd is never closed — one leak per error, invisible until `EMFILE`. (d) `uv_fs_req_cleanup` missing on the error/throw path; the `uv_fs_t` and its `path` string leak. (e) `path` must stay alive until the request completes; a D slice of a temporary is dangling.

**Fix:** read in a loop (`uv_fs_read` 64 KiB chunks, append into a growing `malloc` buffer, stop on 0/EOF, cap at a configurable max — A-16); write in a loop with an offset; every completion path closes the fd and calls `uv_fs_req_cleanup` via `scope(exit)`; the request struct owns a `js_malloc`'d path copy. State the chunk size and max file size as contract.
**Test:** `/proc/self/status` non-empty; read a file while another writer appends (no truncation, or a documented snapshot); write to a full loopback fs → error surfaced, fd count unchanged; `fs.readFile("nope")` 10k times → `/proc/self/fd` count stable.

---

### A-13 — module resolution has no root, no canonical key, and no symlink containment
**Where:** ARCH §8.1 (l.182) "Bare specifiers are a v0.1 error unless they resolve inside the project"; §8.2 (l.191-193); PLAN Phase 2.
**Problems:**
- "inside the project" is undefined — there is no project root concept anywhere in the docs. Two modules can disagree about what "the project" is; a script run by absolute path has no anchor.
- No canonicalization rule: `./a.js`, `a.js`, `././a.js`, `./A.JS` (case-insensitive fs), and a symlinked `./link.js` all produce different cache keys → the same module is instantiated twice, with duplicate side effects and two copies of its state (silent, and it breaks singleton patterns).
- Containment checks on the *textual* path are bypassed by symlinks: `./data` → `/etc/shadow` passes a prefix check unless `realpath` is applied first; and a specifier containing `\0` passes the D check but truncates when passed to `uv_fs_open`, so the validated path and the opened path differ (classic check/open mismatch).
- The loader does synchronous `read()` inside a JS call (dynamic `import()`): `import "./fifo.js"` hangs the process (A-09).
- CJS: "cache the module object before executing to tolerate cycles" is right, but there is no rule to **delete the cache entry when execution throws**. `try { require("./bad") } catch {}` then `require("./bad")` in Node re-throws; with the doc's rule it returns `{}` and the failure is masked forever.

**Fix:** define a root (the entry script's directory; `--root` to override), canonicalize with `realpath(3)` on the final path (after extension resolution, before the containment check and before use as a cache key), reject `\0` and invalid UTF-8 specifiers, and open with `O_NOFOLLOW` on the final component where possible. For CJS, delete the cache entry on throw. Document that module loading is synchronous and may block.
**Test:** symlink escape (`ln -s /etc/shadow ./x.js; import "./x.js"` → refused); `a.js` + `link.js` both importing `./b.js` → one side effect; `require("./bad")` twice → throws twice; FIFO import with `--timeout` (expected: documented hang or explicit refusal).

---

### A-14 — the uncaught-exception reporter runs arbitrary JS and can hang or overwrite the real error
**Where:** ARCH §10 (l.214) — "read `.stack` if present (else `String(err)`)".
**Failure:** `.stack` is a property read. `Object.defineProperty(Error.prototype, "stack", { get() { while (1) {} } })` turns every uncaught error into a hang; a getter that throws leaves a *second* pending exception while the handler is formatting, so the original error is lost and the handler's own `JS_GetPropertyStr` returns `JS_EXCEPTION` — DJS then prints a half-built string or nothing, and the exit path reads a pending exception. `String(err)` on an object with a throwing `toString` does the same. A `Proxy` as the rejection reason does it without any prototype mutation.
**Fix:** the reporter is native and defensive: read `.stack`/`String(err)` with `JS_GetPropertyStr`/`JS_ToString`, check `JS_IsException` after **each** step and fall back to a static `<unprintable>`; never call a user getter twice; run the whole report under the interrupt deadline (A-09) so a hang is bounded. Do not implement the reporter in the prelude — user code can replace it.
**Test:** the `Error.prototype.stack` getter above → process exits 1 with a bounded message, no hang; a Proxy reason → no crash.

---

### A-15 — loop termination: `UV_RUN_ONCE` blocks on jobs-only, `uv_stop` skips close callbacks
**Where:** ARCH §7 (l.172), §5 (l.87); PLAN open question (l.248).
**Answer to the open question:** `JS_IsJobPending(rt)` and `JS_GetPendingJobContext(rt)` are exported (`quickjs.h:1249-1250`), so no idle handle is needed — but `UV_RUN_ONCE` must not be called when jobs are pending and no handle is referenced: libuv will block until the next timer with a job sitting in the queue. That state is reachable (a finalizer or close callback that enqueues a microtask after the last handle drops).
**Second bug:** `uv_stop` makes `uv_run` return *without* running pending close callbacks. If `process.exit` / the `--timeout` watchdog calls `uv_stop`, `uv_loop_close` returns `UV_EBUSY` and handle memory leaks (or is freed wrongly). The final drain needs one `uv_run(UV_RUN_NOWAIT)` after the stop flag clears.
**Fix:** write the loop skeleton into ARCH:
```
while (true) {
  while (JS_IsJobPending(rt)) { if (drain_one() < 0) break; }
  if (!uv_loop_alive(loop)) break;
  uv_run(loop, JS_IsJobPending(rt) ? UV_RUN_NOWAIT : UV_RUN_ONCE);
  drain_jobs();
}
uv_run(loop, UV_RUN_NOWAIT);      // close callbacks
if (uv_loop_close(loop) == UV_EBUSY) { /* log + leak, never free handle memory */ }
```
and state that handle memory is freed only in close callbacks.
**Test:** a script whose last action is `queueMicrotask` from a close callback must exit, not hang; `uv_loop_close` must not return EBUSY in any integration test.

---

### A-16 — the memory limit caps the wrong heap; OOM is catchable and does not stop a script
**Where:** ARCH §11 (l.221) "default 256 MiB, overridable with `DJS_MEMORY_LIMIT`".
**Reality:** `JS_SetMemoryLimit` only gates `js_malloc` from the runtime (`quickjs.c:1992-2016, 2438`). It does not cover the D-side `malloc` for fs read buffers, module source, path strings, or the prelude's buffers. And OOM is an ordinary `InternalError`: JS can catch it.
**Failure:** `fs.readFile("/huge")` allocates 2 GiB via libc before QuickJS ever sees it → OOM killer, not a JS exception; the 256 MiB limit gave false confidence. And `try { bigAlloc() } catch (e) { bigAlloc() }` thrashes at the limit instead of terminating — the process stays alive at 100% CPU with no progress until the wall-clock watchdog (A-09) fires.
**Fix:** (a) a hard `maxReadSize` (e.g. 64 MiB) enforced in the fs primitive, independent of the JS limit; (b) `JS_NewRuntime2` with a counting allocator so `JS_ComputeMemoryUsage` and the limit cover everything QuickJS allocates, plus a separate DJS-side counter for native buffers exposed via `process.memoryUsage()`; (c) treat OOM as fatal: set a flag the interrupt handler checks so a caught OOM cannot continue. If a custom allocator is used, **all** memory QuickJS will free must come from it (see A-19) — `js_free_rt` aborts on accounting underflow (`quickjs.c:2036-2040`).
**Test:** `--memory-limit 32M` + a 100 MB `String.repeat` → non-zero exit within 2 s; `fs.readFile` of a >maxRead file → `ERR_FS_FILE_TOO_LARGE`, no OOM-killer; a catch-OOM loop terminates.

---

### A-17 — no capability seam for the embedder, which is the actual security boundary
**Where:** BRIEF l.13 ("easy to embed (C ABI host)"), ARCH §11 (l.224) "QuickJS is not a security boundary".
**Problem:** the doc correctly says the interpreter is not a sandbox, but then gives the embedder no way to build one: §9 installs `fs` (full filesystem), `process.env` (all secrets), `process.exit` (kills the host), and timers, unconditionally. An embedder running a plugin gets host DoS at minimum: `process.exit(0)`, `while(1){}` (the interrupt handler is only installed for `--timeout`), `setInterval(()=>{},0)` (100% CPU forever), `fs.readFile("/etc/shadow")`, `process.env.OPENAI_API_KEY`. "Use a container" is not available to an embedder whose host process is the container.
**Fix:** make global installation a policy input: `installGlobals(ctx, Caps{fs, env, exit, timers, moduleRoot, memoryLimit, deadline})`; the CLI passes everything, an embedder passes what it grants. Default `process.exit` for embedders = `throw`; default `--timeout` for embedded contexts = on. This is a small API change now and an ABI/behavior break later. Add a `docs/EMBEDDING.md` with the threat model (what a script can reach, what isolation the host must add).
**Test:** a D unittest that installs a context with `caps.fs=false` and asserts `typeof fs === "undefined"` and that `require("fs")` fails; a script calling `process.exit` in that context gets an exception, not process death.

---

## Minor

### A-18 — build/test gates that cannot hold (Minor)
**Where:** GUIDE §1 `dub.json`, PLAN Phase 1 DoD / Phase 4, ARCH §13.
Concrete problems:
1. `dub test` on a `targetType: executable` that has a `main`: druntime runs the unittests at startup, then **runs `main`** — which, with no args, starts the REPL and blocks on stdin forever. CI hangs. Fix: `version (unittest) { int main() { return 0; } }` in a test-only module, or a separate `dub test` configuration/target.
2. `dflags-ldc: ["-O3","-flto=full"]` applies to **every** build type, including `debug` and `unittest`: slow tests, no debug info, and LTO + unittest occasionally fails to link. Scope `-O3`/LTO to the `release` build type only.
3. `buildOptions: [... "noBoundsCheck"]` in release removes bounds checks in the module resolver and path code — the code that parses untrusted specifiers. Keep bounds checks there (separate build option or `@safe` module with checks re-enabled), or accept and document the risk.
4. ARCH §13's leak gate is RSS-based ("soak test ... asserts a bounded delta"). glibc does not return freed memory and the D GC never shrinks; the gate will fail intermittently for reasons unrelated to leaks. Assert on `JS_ComputeMemoryUsage().malloc_count` (deterministic) and treat RSS as advisory with a generous bound.
5. Golden tests that depend on `fs` completion vs a 10 ms timer are timing-flaky on loaded CI. Ordering tests must use only `queueMicrotask`/`setTimeout(0)`/`setImmediate`-equivalents within one turn; no cross-source timing assumptions in goldens.
6. `qjsc`-compiled prelude bytecode is engine-version and build-flag locked: it must be generated by the **same** pinned `qjs` at bootstrap, or startup fails with a bytecode error. Say so, or embed the prelude as source.
**Test:** `dub test` finishes in <60 s in CI with stdin < /dev/null; a deliberately leaked object makes the leak test fail deterministically.

*Note for the fixer:* `docs/D-GUIDE.md` §1 is being edited concurrently (the `libs`/`lflags` shape changed and `noBoundsCheck` was dropped). Re-check items 2–3 against the current file before dispositioning; item 2 (`-O3 -flto=full` in the global `dflags-ldc`) still applies as of this review.

---

## Header cross-check (doc claim vs. pinned source)

| Doc claim | Pinned reality | Effect |
|---|---|---|
| ARCH §6.3: "`js_malloc` is internal; prefer `malloc`" | `js_malloc`/`js_mallocz`/`js_free`/`js_malloc_rt` are `JS_EXTERN` (`quickjs.h:575-586`) | **Wrong and dangerous.** The module normalizer must return `js_malloc`'d memory (`quickjs.h:1196-1200`); returning `strdup` memory works only with the default allocator and corrupts the heap with `JS_NewRuntime2`. Any memory QuickJS frees must come from `js_malloc`/the runtime allocator. |
| PLAN open question: "does the pinned engine export `JS_EnqueueJob`?" | Yes (`quickjs.h:1247`), and it **dups** its argv (`quickjs.c:2504-2506`) | Closed: use `JS_EnqueueJob` for `queueMicrotask`; the promise trampoline is unnecessary. |
| ARCH §8.1: `JS_SetModuleLoaderFunc2` registers the loader; "unknown types raise a TypeError" | It takes **four** callbacks including `JSModuleCheckSupportedImportAttributes`; attribute rejection is *your* callback (`quickjs.h:1215-1229`). `JS_SetModuleNormalizeFunc2` must be called **after** it (`quickjs.h:1231`) | Passing NULL silently ignores `with { type: "banana" }`. Doc omits the mechanism it promises. |
| ARCH §8.1: "set `import.meta` (url, filename, dirname)" | There is no setter; only `JS_GetImportMeta(ctx, m)` (`quickjs.h:1236`) | Implement as `JS_GetImportMeta` + `JS_DefinePropertyValueStr`. |
| ARCH §6.4: "`JS_NewClassID` + `JS_NewClass`" | `JSClassID JS_NewClassID(JSRuntime *rt, JSClassID *pclass_id)` (`quickjs.h:707`) | Class IDs are **per-runtime**. A module-level `__gshared JSClassID` breaks the second runtime (workers, REPL-per-line, host re-init): wrong class id → `JS_GetOpaque` NULL → crash. Store ids in the runtime struct. |
| ARCH §6.4: `JS_SetOpaque` | returns `int` (`quickjs.h:1065`) | Return value must be checked. |
| ARCH §6.1: JSValue is 16 bytes | True only for 64-bit `!JS_NAN_BOXING`; NaN boxing is auto-on for 32-bit (`quickjs.h:173-176, 315`) | See A-08. |
| ARCH §6.1: `JSValueConst` is by-value in normal builds | Confirmed (`quickjs.h:202-204`), and it is **not const** | Correct; but D should add its own phantom type (A-08). |
| ARCH §7: drain "until it returns 0" | returns **-1** on exception (`quickjs.c:2545-2548`) | See A-02. |
| ARCH §11: interrupt handler for `--timeout` | Correct and **uncatchable** (`JS_SetUncatchableError`, `quickjs.c:8647-8652`) — stronger than the doc claims — but polled only in interpreter/regexp | See A-09. |
| ARCH §11: `JS_SetMaxStackSize` | Exists; `JS_UpdateStackTop` must be called if the runtime's stack base changes (thread/stack switch) (`quickjs.h:515-521`) | Doc omits `JS_UpdateStackTop`; matters for the future worker seam and for any host calling from a different stack. |

---

## Verdict

**APPROVE WITH CHANGES.**

The architecture is sound: the engine choice, the single-threaded loop ownership, the thin-native/fat-prelude split, and the ownership *rules* are right, and no ADR needs to be reopened. But three sections — §6 (boundary), §7 (loop/microtasks), §10 (exit and error policy) — currently specify behavior that will crash, hang, or silently corrupt if implemented literally, and the D-GUIDE's libuv example teaches heap overflow. None of this requires a redesign; all of it requires the documents to be made precise before Phase 1 code is written.

Critical: 8 · Important: 9 · Minor: 1.

### Top 5 must-fix (block Phase 1)

1. **A-01** — `process.exit`/`JS_FreeRuntime` ordering and stack-owned `JSValue`s. Define the shutdown state machine; no runtime free while any C frame holds a value.
2. **A-07** — truncated libuv struct mirrors. Prescribe full mirrors with size asserts or `uv_handle_size`/`uv_req_size` allocation; fix the GUIDE example.
3. **A-04** — pin JS buffers across async fs requests (dup the value, use `JS_GetTypedArrayBuffer` for views, free in the completion callback).
4. **A-02** — the drain loop contract (`>0` continue, `<0` route to uncaught), plus a per-turn job budget.
5. **A-05** — no user-controlled string as a printf format at the boundary.

Close runners-up that must be fixed before their code lands: **A-03** (rejection tracker false positives — will fail the most basic scripts), **A-06** (`JS_GetOpaque2`), **A-08** (build-time ABI gate), **A-11** (timer id lifetime).

Recommendation to the fixer: fold the boundary rules into a single normative section with code, not prose — A-01/A-04/A-06/A-11 are all instances of one missing rule: *native state that outlives the call must be an owned, generation-checked handle, and every `JSValue` it holds must be dup'd and freed before the runtime.*
