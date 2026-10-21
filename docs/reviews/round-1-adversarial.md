# Round 1 — Adversarial Review (implementation)

**Scope:** commit `64acfd2`, `src/djs/**`, `js/prelude.js`, `tests/`.
**Method:** line-by-line ownership/teardown audit against `docs/ARCHITECTURE.md` §6, §7, §9, §10, plus live probes. Release build with ASan/LSan:

```
DFLAGS="-fsanitize=address -g" dub build --build=release --compiler=ldc2
```

and a plain release build for timing/repetition probes. Every "Evidence" block below is real output from this checkout, not a hypothetical.

**Verdict: APPROVE WITH CHANGES** — the boundary discipline is better than average (see "What held up"), but there are three production-grade failure modes (native OOM from timer churn, exit-code clobbering, unbounded `readFile`) and one teardown invariant that is only safe by accident.

| ID | Severity | One line |
|----|----------|----------|
| RA-01 | Important | Timer create/clear churn grows native memory without bound inside one turn → OOM |
| RA-02 | Important | `process.exit(code)` code is overwritten; JS keeps running after exit is requested |
| RA-03 | Important | `readFile`/`readFileSync` have no size cap or `fstat`; reads until malloc fails |
| RA-04 | Important | Teardown frees registry `JSValue`s before in-flight requests drain (docs say the opposite) |
| RA-05 | Minor | Callback registry slot array is never freed (`registryDestroy` missing) — LSan |
| RA-06 | Important | `uv_stop` doesn't stop the current timer batch: JS runs after an uncaught exception |
| RA-07 | Minor | Timer ids are Numbers derived from a 64-bit `(gen<<32)|index`; >2^53 loses the slot |
| RA-08 | Important | REPL never advances the loop between lines; async only works at EOF; Ctrl-D can hang |
| RA-09 | Minor | All fs errors report `syscall: "open"` (read/write/close failures included) |
| RA-10 | Minor | `DataView` (and non-typed-array views) rejected as write data; Node accepts them |
| RA-11 | Minor | `process.env` is a lossy snapshot: keys >255 bytes silently truncated |
| RA-12 | Minor | Inconsistent `JS_SetPropertyStr` result handling treats `-1` (exception) as success |
| RA-13 | Minor | `slotCancelled`/`registryCancel` are dead code; ARCH §9.1 cancel path unimplemented |
| RA-14 | Minor | `runtimeCreate` fail path frees handles without `uv_close`, then `uv_loop_close` |

---

## RA-01 — Timer create/clear churn grows native memory without bound (Important)

**File:** `src/djs/apis/timers.d:70-85` (`closeTimer`), `:155-192` (`jsTimerStart`).

`clearTimeout` does `uv_close(handle, onTimerClosed)` and nothing else. `onTimerClosed` (`:55-68`) is the only place the `uv_timer_t` and `TimerState` are freed, and close callbacks only run when the loop turns. A synchronous loop that creates and clears timers therefore retains **every** handle and state until the turn ends. `TimerState` + `uv_handle_size(UV_TIMER)` ≈ 350 B per iteration, with no cap and no relation to `JS_SetMemoryLimit`.

**Evidence** (`t_timer_rss.js`, plain release):

```
rss before KB 13088
rss after 200k create+clear KB 84588
```

200k iterations → +71 MB. Extrapolating, ~3M iterations in one turn exhausts a 1 GB container. `for (;;) clearTimeout(setTimeout(() => {}, 1000));` is a one-line OOM kill. Node survives this because its timers are GC objects; DJS has no equivalent reclamation and the 256 MB JS limit does not cover `malloc`/`uv_handle_size`.

**Failure scenario:** untrusted or buggy script OOM-kills the host process (or the embedder) while `process.memoryUsage`-style limits appear to hold. This is also a slow "leak" in normal use: any turn that clears many timers keeps them all.

**Fix direction:** keep closed timer states on a free list and reuse the `uv_timer_t` (re-`uv_timer_init` is not required after close? it is — allocate a pool), or cap live handles per turn and fail the turn. At minimum, document and test the bound.

**Test that would catch it:** `tests/js/timer_churn.js` — 200k create/clear in one turn, assert RSS growth < 20 MB (read `/proc/self/status` through `fs.readFileSync`, as the probe does) and that the process exits promptly.

---

## RA-02 — `process.exit(code)` exit code is clobbered; JS runs after exit (Important)

**File:** `src/djs/runtime.d:338-347` (`runtimeReportUncaught` sets `exitCode = 1`), `:349-361` (`reportUnhandledRejections` does the same), `:365-388` (`runtimeDrainJobs` never checks `exitRequested`), `:390-405` (`runtimeRunLoop` only checks at the top of the iteration).

`process.exit` is a request (`:483-489`), which is fine and documented. But the drain that follows continues to execute queued jobs, and any throw or unhandled rejection in them overwrites the caller's explicit code with 1. The stated contract is "JS continues to the end of the current turn"; silently discarding `process.exit(7)` is not part of it.

**Evidence:**

```
$ ./djs -e 'Promise.resolve().then(() => process.exit(7)).then(() => { throw new Error("late"); });'
Uncaught (in promise) Error: late
    at <anonymous> (<eval>:1:70)
exit=1                      # asked for 7

$ ./djs -e 'Promise.reject(new Error("nobody handles me")); process.exit(0); console.log("unreachable");'
unreachable
Uncaught (in promise) Error: nobody handles me
exit=1                      # asked for 0
```

Node exits 7 / 0 respectively (and prints neither line). The second case is the dangerous one: a script that deliberately exits 0 after a transient rejection gets a failure status, breaking CI wrappers.

**Fix direction:** once `exitRequested`, stop executing jobs (`runtimeDrainJobs` should return immediately), and make `runtimeReportUncaught` not lower a code that was explicitly requested (`if (!self.exitRequested) self.exitCode = 1;`).

**Test:** `tests/js/exit_microtask.js` — the two snippets above, golden `.exit` files `7` and `0`.

---

## RA-03 — `readFile` reads until malloc fails (Important)

**File:** `src/djs/apis/fs.d:61-118` (`doRead`), also `:338-361` (`jsReadFileSync`).

`doRead` never `fstat`s and has no maximum. It doubles an 8 KiB buffer until EOF. `/dev/zero`, a FIFO held open, or a multi-GB file will consume all available memory before the `malloc` failure path at `:71-76`/`:90-97` returns `ENOMEM`. This contradicts ARCH §9.4 ("`readFile` uses `fstat` + a bounded read loop") and Node's 2 GB `MAX_STRING_LENGTH`-style guard.

**Evidence** (600 MB address-space cap to make the failure observable without killing the box):

```
$ bash -c 'ulimit -v 600000; ./djs -e "try { fs.readFileSync(\"/dev/zero\") } catch (e) { console.log(e.code, e.message) }"'
ENOMEM not enough memory
```

It consumed the entire 600 MB budget before failing; without the cap it takes the host down. `readFile` (async) has the same shape and also copies the buffer into a JS string, so peak is ~2×.

**Fix direction:** `fstat` regular files to presize and reject `st_size > MAX_FILE_SIZE` (Node's default `fs.readFile` cap is 2 GiB); for non-regular files use a bounded loop and fail with `EFBIG`/`ERR_FS_FILE_TOO_LARGE`.

**Test:** `tests/js/fs_limits.js` — read `/dev/zero` under `ulimit -v` in the harness and require `ENOMEM`/`EFBIG` within 2 s, plus a 300 MB sparse file rejected before allocation.

---

## RA-04 — Teardown frees JS values before in-flight requests drain (Important)

**File:** `src/djs/runtime.d:590-614`; contrast ARCH §10 steps 2–4.

Documented order: close handles → run loop until close callbacks fire → **then** `freeAll` → `JS_FreeContext`. Implemented order: `timersCloseAll` + `registryFreeAll` (`:596-600`) → close prepare/idle → `uv_run` (`:607-614`) → `JS_FreeContext`. So the registry's `JSValue`s (including the callbacks of in-flight `uv_queue_work` requests) are freed *while those requests are still running*. It is safe today only because `fsAfterCb` re-checks `!self.shuttingDown` before `registryDetach` (`src/djs/apis/fs.d:177-178`) and therefore never touches the freed values.

That is a one-line guard standing between the current code and a use-after-free: any new completion path (DNS in phase 2, `uv_cancel`, a signal handler) that calls `registryDetach` without the guard reads freed QuickJS memory and calls a freed function. `registryFreeAll` also marks slots free and zeroes `freeHead` (`registry.d:173-187`), so a late `registryAdd` after teardown would rebuild a bogus free list.

**Evidence:** `fs.readFile(...); process.exit(3)` never invokes the callback (by design), but the freeing happens before the loop drain, not after:

```
$ ./djs t_exit_fs.js
after exit
exit=3          # neither "SHOULD NOT PRINT" nor "WRITE SHOULD NOT PRINT"
```

**Fix direction:** move `registryFreeAll` after the drain loop (step 4), as documented; or make `fsAfterCb` unconditionally call a `registryDetach`-that-tolerates-shutdown and assert `slot.state == free` afterwards. Add an assertion in `registryRelease`/`Detach` that `self.ctx != null` and not `shuttingDown`.

**Test:** D unittest that enqueues 50 fs requests, calls `runtimeRequestExit`, tears down, and asserts (a) no callback fired, (b) `registry.capacity == 0` after teardown, (c) ASan clean.

---

## RA-05 — Registry slot array leaks (Minor)

**File:** `src/djs/runtime.d:590-646`; `registryDestroy` exists (`registry.d:51-59`) and is called only on the `runtimeCreate` failure path (`runtime.d:579`).

**Evidence (LSan):**

```
Direct leak of 2560 byte(s) in 1 object(s) allocated from:
    #0 ... in calloc
    #1 ... _D3djs8registry12registryInitFNbNiPSQBiQBh16CallbackRegistrykZb src/djs/registry.d:36
    #2 ... runtimeCreate ... src/djs/runtime.d:523
SUMMARY: AddressSanitizer: 2560 byte(s) leaked in 1 allocation(s)
```

One allocation per process, so cosmetic for the CLI — but this is an embeddable runtime; an embedder that creates/destroys runtimes in a long-lived host leaks 2.5 KB each time, and LSan noise hides real leaks. Call `registryDestroy(&self.registry)` at the end of `runtimeTeardown`.

**Test:** run the D unittests under ASan with `detect_leaks=1`; add `runtimeCreate`/`runtimeTeardown` in a loop (100×) and assert no growth.

---

## RA-06 — `uv_stop` does not stop the current timer batch; JS runs after a fatal error (Important)

**File:** `src/djs/runtime.d:338-347`, `:390-405`; `src/djs/apis/timers.d:107-135`.

`runtimeReportUncaught` calls `uv_stop`, but libuv only prevents the *next* blocking poll: timers already due in the current timer phase still run. `onTimer` never checks `self.failed`, so callbacks scheduled to the same millisecond execute after the error has been printed and the exit code set. A second due timer can even call `process.exit(0)` and undo the failure (see RA-02).

**Evidence** (`t_batch.js`: three 0 ms timers, the first throws):

```
$ ./djs t_batch.js ; echo exit=$?
t1 throwing
Uncaught Error: first timer
    at <anonymous> (/home/ubuntu/.hermes/cache/scratch/t_batch.js:1:58)
    ...
t2 ran after fatal
t3 ran after fatal
exit=1
```

Confirmed scope: later *iterations* do stop (a 30 ms timer and the remaining `readFile` completions never ran in the fs probe), so this is the same-batch window, not a general "loop keeps going". Node stops at the first throw. For a runtime whose contract is "uncaught → print, exit 1, stop", executing two more user callbacks after the report is a correctness and least-surprise problem.

**Fix direction:** check `self.failed || self.exitRequested` at the top of `onTimer`, `onIdle`, `onPrepare`, and `fsAfterCb`; return without calling into JS once either is set.

**Test:** `tests/js/fatal_stops_callbacks.js` — exactly `t_batch.js`; golden stdout must contain only `t1 throwing` (plus the stderr `Uncaught` match).

---

## RA-07 — Timer ids lose the slot index above 2^53 (Minor)

**File:** `src/djs/apis/timers.d:193` (`return jsFloat(cast(double) id);`), `src/djs/registry.d:103` (`(slot.generation << 32) | index`).

Ids are published to JS as IEEE doubles. `generation` increments twice per add/release cycle, so after ~2^21 cycles on one slot the id exceeds 2^53 and the low index bits round away. `clearTimeout` then targets a different index and fails the generation check (silent no-op) or, worse, matches another live slot with the same generation. The prelude stores the rounded Number in `Timeout._id` (`prelude.js:133`) and never re-derives it.

**Evidence:** after 1.2M create/clear cycles the probe id is already `1300717960691714` (< 2^53), with `id mod 2 == 0`; the threshold is a factor of ~7 away and is reached by any long-lived process that churns timers (servers, retry loops).

**Fix direction:** publish the id as two 32-bit halves, a BigInt, or a string; or shrink the generation to 20 bits and reuse ids after a full cycle only when the slot is provably free.

**Test:** `tests/js/timer_id_precision.js` — 2.2M create/clear on one slot while an anchor holds slot 0, then `clearTimeout` a fresh timer and assert it never fires.

---

## RA-08 — REPL never runs the event loop between lines (Important)

**File:** `src/djs/main.d:22-64`.

The REPL evaluates each line and calls `runtimeDrainJobs`, but `runtimeRunLoop` is only entered after stdin closes (`:62`). Timers, fs completions and promise continuations that need a macrotask never run while the user is at the prompt; they all flush in a burst at EOF. A `setInterval` started in the REPL makes Ctrl-D hang forever, because teardown waits for the loop.

**Evidence:**

```
$ printf 'setTimeout(()=>console.log("T"),0)\n1+1\n' | ./djs
> 4294967296
> 2
>
T                     # only after EOF

$ printf 'setTimeout(()=>{},100000)\n' | timeout 5 ./djs ; echo $?
124                   # Ctrl-D equivalent hangs on the pending timer
```

Also note `4294967296`: the REPL prints a `Timeout` via `String()`, which hits `Symbol.toPrimitive` and shows the raw native id; Node prints `Timeout { ... }`.

**Fix direction:** run the loop to quiescence (bounded `UV_RUN_NOWAIT` + drain, with the current prepare/idle machinery) after each line, or accept non-blocking `UV_RUN_NOWAIT` between prompts. Cancel/close pending timers on REPL EOF (or document that Ctrl-D waits).

**Test:** `tests/js/repl_async.txt` driving the binary with a pipe: `setTimeout(...)` then a line that depends on it; golden output must show ordering before EOF. (This needs the integration harness to support stdin, which it currently does not — see test gaps.)

---

## RA-09 — All fs errors claim `syscall: "open"` (Minor)

**File:** `src/djs/apis/fs.d:189` (`w.isWrite ? "open" : "open"`), `:352`, `:382`.

`doRead`/`doWrite` return a single `errno` with no syscall tag, so a failed `read` or `write` is reported as `open`. Node-shaped error consumers branch on `err.syscall`.

**Evidence:**

```
$ ./djs -e 'try { fs.readFileSync("/tmp") } catch (e) { console.log(e.code, e.syscall) }'
EISDIR open            # Node: EISDIR read

$ ./djs -e 'try { fs.writeFileSync("/dev/full", "abc") } catch (e) { console.log(e.code, e.syscall) }'
ENOSPC open            # Node: ENOSPC write
```

**Test:** extend `tests/js/fs_errors.js` with a directory read and `/dev/full` write, golden the `syscall` values.

---

## RA-10 — `DataView` writes are rejected (Minor)

**File:** `src/djs/apis/fs.d:288-295`.

`copyBytes` accepts strings, `ArrayBuffer`, and typed arrays only. A `DataView` returns `JS_GetTypedArrayType == -1` and throws `TypeError`; Node's `fs.writeFile` accepts any `ArrayBufferView` and writes its bytes.

**Evidence:**

```
$ ./djs -e 'fs.writeFileSync("/tmp/dv.bin", new DataView(new ArrayBuffer(4)))'
dataview TypeError data must be a string, ArrayBuffer, or typed array
```

**Fix direction:** after `JS_GetTypedArrayType` fails, fall back to `JS_GetArrayBuffer`-style access for `DataView` (QuickJS exposes `JS_GetTypedArrayBuffer` only for typed arrays; a `JS_GetPropertyStr(view, "buffer"/"byteOffset"/"byteLength")` path is enough).

**Test:** `tests/js/fs_buffers.js` — string / ArrayBuffer / Uint8Array / subarray / DataView, byte-exact golden.

---

## RA-11 — `process.env` is a lossy snapshot (Minor)

**File:** `src/djs/apis/process.d:34-66`.

Keys are copied into `char[256]` and truncated at 255 bytes (`:49-52`); the environment is read once at prelude install (`prelude.js:201`) and never refreshed. Two variables whose first 255 bytes match collapse into one property (last wins); `delete process.env.X` / assignment cannot affect the real environment.

**Test:** `tests/js/process_env.js` — a 300-byte key and two 255-byte-prefix keys; assert full keys present (or a documented truncation policy) and that `process.env` reflects `setenv` in a parent-spawned probe.

---

## RA-12 — `JS_SetPropertyStr` result handling is inconsistent (Minor)

**File:** `src/djs/bindings/value.d:147-151` (`!= 0`), `:159-168` (`> 0`), `src/djs/apis/fs.d:487`, `console.d:41`, `process.d:140` (`!= 0`), `process.d:59` (`<= 0`).

QuickJS-NG returns `1` on success, `0` on failure, `-1` on exception (`vendor/quickjs-ng/quickjs.c:11001-11013`). `setProp` treats `-1` as success and leaves a pending exception behind; `makeError` then returns a half-built error while `ctx` still has an exception armed, which the next `JS_HasException` consumer will attribute to its own operation. This is only reachable under OOM or a hostile `Object.prototype` setter, but it is exactly the class of latent state corruption the boundary rules exist to prevent.

**Fix:** one helper `bool ok = JS_SetPropertyStr(...) > 0;` everywhere, and clear any pending exception on failure.

**Test:** D unittest that installs a throwing setter on `Object.prototype` and asserts `makeError` either succeeds cleanly or returns `JS_EXCEPTION`, never a valid object with a pending exception.

---

## RA-13 — Cancellation model is dead code (Minor)

**File:** `src/djs/registry.d:164-169` (`registryCancel`), `:15` (`slotCancelled`); `src/djs/runtime.d:594-600`.

`registryCancel` is never called; `slotCancelled` is never assigned; ARCH §9.1 ("cancel marks the slot cancelled; the completion still runs, sees cancelled, frees the slot") and §10 step 1 ("mark all callback-registry slots cancelled") are not implemented. Teardown uses `registryFreeAll` instead, and `fs` has no per-request cancellation at all. The dead state also makes `registryFreeAll`'s `slotCancelled` branch untestable. Either implement it for fs (so `clearTimeout`-style cancellation of a pending read frees the JS function immediately) or delete it and amend the docs.

**Test:** remove the dead code path from coverage expectations, or add a D unittest for cancel-then-complete.

---

## RA-14 — `runtimeCreate` failure path closes the loop with live handles (Minor)

**File:** `src/djs/runtime.d:563-587`.

If `uv_prepare_init`/`uv_idle_init`/`uv_prepare_start` fails after `uv_loop_init`, the path frees `self.prepare`/`self.idle` without `uv_close` and then calls `uv_loop_close`, which returns `UV_EBUSY`; the loop's internal handle queue still references the freed memory until the loop is freed immediately after (no UAF today, but the pattern is wrong and the error is ignored). Also `installPrimitives` failure leaves timer/fs JSValues in the registry and `registryDestroy` is called without freeing them (`:579` before `JS_FreeContext`? no — `JS_FreeContext` runs first at `:566-567`, so the values are freed with the context; harmless but only by ordering).

**Fix:** close initialized handles, run `UV_RUN_NOWAIT`, then `uv_loop_close`; only `free()` handle memory in the close callback.

**Test:** fault-injection unit test (`uv_prepare_init` forced to fail) under ASan/LSan.

---

## What held up

Worth recording so the fixes don't regress it:

- `onTimer` dups `slot.fn` before `JS_Call` (`timers.d:120-124`), so a callback that clears itself — which releases the registry's reference — does not free the function out from under the call. Verified with self-clearing intervals.
- Registry ids are `(generation, index)` checked before any deref (`registry.d:106-118`); stale numeric ids and `clearTimeout(-1)`/`1e300` are safe no-ops (probed).
- No format-string injection: every `JS_Throw*` goes through `value.d:101-114` with a literal `"%s"`; user data never reaches a format argument.
- `copyBytes` copies before queueing, so a detached/collected `ArrayBuffer` cannot outlive the call (ARCH §9.4).
- `JS_GetTypedArrayType`/`JS_IsArrayBuffer` are tag-checked inside QuickJS, so `Symbol`/`null`/object data produce `TypeError`, not a crash (probed all of them).
- `JS_ExecutePendingJob == -1` uses the returned context, not the starting one (`runtime.d:371-377`), and `JS_FreeRuntime` frees any still-queued jobs (`quickjs.c:2648-2654`), so aborting a turn is leak-free.
- The rejection tracker dups both promise and reason, and the swap-remove on `isHandled` is correct (`runtime.d:241-254`).

## Test gaps (concrete)

The suite has 13 JS tests and unittests in only 3 modules (`registry`, `value`, `runtime`). Missing, in priority order:

1. **Exit semantics:** `exit_microtask`, `exit_with_rejection`, `exit_code_over_255`, `exit_in_fs_callback` (RA-02/RA-04).
2. **Timer stress:** `timer_churn` with an RSS assertion, `timer_id_precision`, `interval_self_clear_then_more_ticks`, `clear_timeout_by_number`, `double_clear_after_fire` (RA-01/RA-07).
3. **fs limits and buffers:** `fs_limits` (`/dev/zero`, sparse 300 MB), `fs_buffers` (ArrayBuffer/Uint8Array/subarray/DataView), partial-read loop with a small pipe (RA-03/RA-10).
4. **Fatal-error propagation:** `fatal_stops_callbacks` (RA-06); assert no JS output after the `Uncaught` line.
5. **REPL:** a stdin-driven integration case; the harness has no stdin support today (RA-08).
6. **ASan/LSan CI job:** `DFLAGS="-fsanitize=address -g" dub build …` + `dub test` + one integration pass with `detect_leaks=1`; it would have caught RA-05 on day one.
7. **D unittest coverage** for `timers.d`, `fs.d`, `process.d`, `console.d` error paths (currently zero).

## Verdict

**APPROVE WITH CHANGES.**

The architecture is sound and the ownership rules are mostly followed at the value level. The failures are at the *policy* level: limits, ordering, and what happens after a fatal event.

**Top 5 must-fix, in order:**

1. **RA-01** — bound/reuse timer handles; a one-line script currently OOMs the host.
2. **RA-02** — stop draining jobs once exit is requested; never overwrite an explicit exit code.
3. **RA-03** — `fstat` + a max-size cap in both read paths.
4. **RA-04** — move `registryFreeAll` after the drain (or make the completion path explicitly shutdown-aware), matching ARCH §10.
5. **RA-06** — gate every callback entry point on `failed || exitRequested` (same-batch timers currently run after a fatal error).

RA-05 (registry free) and RA-08 (REPL loop) should land in the same change set; they are small.
