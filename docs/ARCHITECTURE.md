# DJS Architecture

**Status:** v0.16.4 · **Scope:** the runtime defined in `BRIEF.md` plus the
v0.2–v0.16 surface · **Pins:** `docs/PINS.md` · Section headings that name an
older release mark when that mechanism landed; the descriptions are current.

## 1. What this is

DJS is a small JavaScript runtime written in D. It embeds **QuickJS-NG** for JavaScript execution and **libuv** for the event loop and platform I/O, and exposes a deliberately small Node-shaped API: `console`, timers, `fs`, `process`, ESM/CommonJS modules, and Node-style `node_modules` package loading.

It is not a Node clone. The design goal is a **single binary, ~14 ms cold start, no Node dependency tree**, with a clean C boundary that a small team can maintain.

## 2. Goals and non-goals

**Goals**

- Run a real JavaScript file with `djs file.js` and a one-liner with `djs -e`.
- Node-shaped APIs for the implemented surface, built in JavaScript over a narrow native binding layer.
- Predictable memory: no D GC allocations on the event-loop or binding hot paths.
- One pinned, reproducible build: LDC + DUB + QuickJS-NG + libuv.
- Honest tests: D unit tests, JS integration tests, golden outputs, a normalized Node differential harness and soak test, plus differential timing checks in the bench.

**Non-goals**

a package manager or registry client; full Node API compatibility; N-API/native addons; `Intl`; WebAssembly; inspector/DevTools; JIT. Networking, subprocesses and workers are planned in the parity phases (`docs/PLAN.md` §4), behind the same seams.

## 3. Key decisions

### ADR-001 — Engine: QuickJS-NG, not V8 or JSC

QuickJS-NG is a small MIT-licensed ES2025 interpreter with a plain C API. It builds in seconds, starts in microseconds, and needs no C++ shim — the decisive advantage for a D host. The cost is no JIT: CPU-bound JavaScript is materially slower than V8/JSC. That is an accepted trade for a runtime whose target is glue, tooling, and I/O-bound automation, not a browser engine.

Pinned: **v0.17.0**, commit `6d46d07d04041b40f4f49eaa7fdebe44c314c699` (see `docs/PINS.md`).

### ADR-002 — Event loop: libuv

libuv is the loop Node uses: epoll/kqueue/IOCP, timers, thread pool, fs, TCP, DNS, signals. It is a C ABI, so D binds it directly. It also gives us a credible path to Windows and macOS without writing three loops.

### ADR-003 — Host language: D with LDC

D gives native code, slices, CTFE, and `@nogc`/`extern(C)` control without a C++ shim. LDC's LLVM backend produces competitive code; DUB is a sufficient build driver. The runtime is written in a deliberately C-like D subset at the boundary (see `docs/D-GUIDE.md`).

### ADR-004 — Thin native, fat JavaScript

The native layer exposes mechanisms (`read_file_start`, `write_file_start`, `now`, `random`, …), not policy. Promise/callback shapes, argument validation, and Node-flavored ergonomics live in a JavaScript prelude compiled into the binary. This mirrors Node's own architecture and keeps the C surface small enough to audit.

### ADR-005 — Modules: ESM first, CommonJS as compatibility

ESM is the primary module system (`JS_EVAL_TYPE_MODULE`). CommonJS is implemented as a host-provided `require` with a module cache and a wrapper function. JSON imports use QuickJS-NG's import-attributes path (`with { type: "json" }` or `.json` suffix). Bare specifiers use Node's `node_modules` walk; package `exports`/`imports` maps, conditions and `*` patterns are interpreted by `modules/pkgexports.d` over a small JSON reader (`modules/json.d`).

## 4. System overview

```
┌──────────────────────────────────────────────────────────────┐
│ CLI / REPL  (src/djs/main.d)                                 │
│  argv parsing · file/-e/REPL · exit codes                   │
└───────────────┬──────────────────────────────────────────────┘
                │
┌───────────────▼──────────────────────────────────────────────┐
│ Runtime  (src/djs/runtime.d)                                 │
│  lifecycle · global object · prelude install · run script   │
│  uncaught exception + unhandled rejection policy            │
└───┬───────────────┬───────────────────┬──────────────────────┘
    │               │                   │
┌───▼─────────┐ ┌───▼─────────────┐ ┌───▼──────────────────────┐
│ Engine      │ │ Event loop      │ │ Module loader            │
│ bindings/   │ │ loop/           │ │ modules/                 │
│ quickjs.d   │ │ libuv.d         │ │ esm.d · cjs.d · resolve  │
│ JSValue     │ │ timers · fs ·   │ │                          │
│ ownership   │ │ tcp · signals   │ │                          │
└───┬─────────┘ └───┬─────────────┘ └───┬──────────────────────┘
    │               │                   │
┌───▼───────────────▼───────────────────▼──────────────────────┐
│ Native APIs  (src/djs/apis/)                                 │
│  console.d · timers.d · fs.d · process.d                     │
└───────────────┬──────────────────────────────────────────────┘
                │
┌───────────────▼──────────────────────────────────────────────┐
│ JS prelude  (js/prelude.js, compiled into the binary)        │
│  promise wrappers · callback adapters · require shim         │
└──────────────────────────────────────────────────────────────┘
```

## 5. Process and threading model

- One **runtime thread**: the libuv loop and the QuickJS context live on the same OS thread. QuickJS contexts are not thread-safe and are never touched from libuv's thread pool.
- libuv's thread pool handles blocking fs/DNS work; the completion callback runs on the loop thread, which then calls into QuickJS.
- No D `Thread` is created today. `worker_threads` is deferred; if exposed later, each worker gets its own `JSRuntime`/`JSContext` and its own loop thread, with message passing over a queue.
- The process exits when the loop has no referenced handles and no pending jobs; `process.exit(code)` tears down explicitly.

## 6. The C boundary and value ownership

This is the most important section in the document.

### 6.1 Types

QuickJS's `JSValue` is a 16-byte C struct: an 8-byte union (`int32`, `double`, `void*`, `int32 short_big_int`) and an `int64 tag`. `JSValueConst` is a by-value alias in normal builds (it becomes a pointer only under `JS_CHECK_JSVALUE`). The D binding must mirror this exactly:

```d
extern(C) union JSValueUnion {
    int   int32;
    double float64;
    void* ptr;
    int   short_big_int;
}
extern(C) struct JSValue {
    JSValueUnion u;
    long tag;
}
alias JSValueConst = JSValue;
static assert(JSValue.sizeof == 16);
static assert(JSValue.alignof == 8);
```

`JSValueConst` is a by-value alias of `JSValue` in normal builds. Under the `JS_CHECK_JSVALUE` debug define it becomes a distinct pointer type so the compiler catches ownership mix-ups; that build is a checker, not a production build. DJS keeps the normal layout and relies on the rules below plus review.

### 6.2 Ownership rules

From `quickjs.h` (paraphrased):

- A function taking `JSValue` **takes ownership**; the caller must not free it.
- A function taking `JSValueConst` **does not take ownership**; the caller must free its own reference.
- A function returning `JSValue` **transfers ownership** to the caller; free it.
- A function returning `JSValueConst` **does not transfer ownership**; do not free it.

DJS adds two project rules:

1. **One owner per value.** Every stored `JSValue` is a dup; every release is a free. No borrowed value survives the C call that produced it.
2. **Never put a `JSValue` in D GC memory.** Store it in C-allocated memory, a stack frame with `scope(exit)`, or a runtime-owned table. The D GC cannot see QuickJS's heap and must not be asked to finalize it.

Property setters are a special case that bites people: `JS_SetPropertyStr` and `JS_SetPropertyUint32` **consume** the value, on success and on failure. Do not free it afterward. `JS_GetPropertyStr` returns an owned value. `JS_GetException` takes and clears the pending exception; `JS_HasException` only peeks. `JS_SetPropertyFunctionList` installs a whole method table in one call and is the preferred way to define an API object.

A small helper (`src/djs/bindings/value.d`) provides:

```d
struct ScopedValue {
    JSContext* ctx;
    JSValue v;
    @disable this(this);                       // D has no move ctor; this blocks blit copies
    ~this() @nogc nothrow { JS_FreeValue(ctx, v); }
}
// static assert(!__traits(compiles, { ScopedValue b = a; }));
```

It is used only on the D side of the boundary; it never crosses into C. Because it is non-copyable, pass it by `ref` and relocate with `core.lifetime.move`; never make it a field of a GC-allocated object or take it by value.

**Status:** `ScopedValue` exists and is unit-tested, but the shipped bindings do not use it. Every current path owns at most one or two values and frees them explicitly, which keeps the `@nogc` control flow visible. It is an optional helper for future multi-value paths, not the enforced ownership mechanism; the one-owner-per-value rule below is what actually holds.

**No `JSValue` may outlive `JS_FreeRuntime`.** This is an ordering rule, not just a refcount rule: every host-held value (callback registry, module cache, timer state, unhandled-rejection set) must be released before the context/runtime are freed. The teardown sequence in §10 is the only place that frees the runtime.

### 6.3 Callbacks

Every function exposed to JavaScript is:

```d
extern(C) nothrow @nogc
JSValue js_fs_read_file(JSContext* ctx, JSValueConst this_val,
                        int argc, JSValueConst* argv) { ... }
```

Inside the callback:

- Failures are reported by **throwing a JS exception directly** from the `@nogc nothrow` body: `throwTypeError`, `throwRangeError`, `throwInternalError` and `throwError` in `bindings/value.d` create the error object, attach `code`/`path`/`syscall` when relevant, and return `JS_EXCEPTION`. There is no intermediate `Status`/`ErrorInfo` trampoline in the shipped code (an earlier design sketch had one; it was deleted because the direct form is shorter and auditable).
- Validate and convert arguments with `JS_ToCStringLen` / `JS_ToInt32`; free C strings with `JS_FreeCString`.
- `catch (Throwable)` at the outermost frame is a last-resort net for `Error` (assert, bounds, null). Print and `exit(70)`; do not convert it into a JS exception and continue. D exceptions must never unwind through QuickJS.
- **Format-string rule:** never pass a user-controlled string as the `JS_Throw*` format argument. Use `"%s"` with a NUL-terminated message, or `"%.*s"` with an explicit `int` length.
- **Allocator pairing:** engine-owned memory is allocated with `js_malloc`/`js_malloc_rt` and freed with `js_free`/`js_free_rt`; D-side scratch uses `malloc`/`free`. Never cross the two. `js_malloc` is public ABI in v0.17.0, and the module normalizer *must* use it because QuickJS frees the returned specifier with `js_free`.
- Never allocate via the D GC. Use `malloc`/`free`, a per-runtime arena, or the QuickJS allocator above, according to ownership.

### 6.4 Opaque data and finalizers

Per-object native state uses a QuickJS class ID and `JS_SetOpaque`/`JS_GetOpaque`:

- Register one class per native object type, per runtime, with `JS_NewClassID` + `JS_NewClass`. Class IDs are runtime-local; do not use a process-global ID.
- The class finalizer receives a `JSRuntime*`, not a `JSContext*`. Free the native allocation there and do not call context-taking JS functions. If the native struct stores `JSValue`s, implement `gc_mark` and call `JS_MarkValue` for each, or cycles through native memory are invisible to QuickJS's collector.
- Allocate native structs that hold `JSValue`s with `js_malloc_rt` (counts against the memory limit) or an arena, and free them in the finalizer with `JS_FreeValueRT`.
- Retrieve opaque pointers with `JS_GetOpaque2`, which validates the class and throws a `TypeError`; never cast blindly.
- Never store a D GC pointer in opaque data. If a native object needs a D object, allocate it with `malloc` and store a pointer, or use a runtime-owned handle table.

## 7. Event loop and microtasks

The loop is a normal libuv loop with one added obligation: **drain QuickJS's job queue**.

- `JS_ExecutePendingJob(rt, &ctx)` returns `1` per job, `0` when the queue is empty (`ctx` set to `NULL`), and `-1` when a job threw. On `-1`, the pending exception is in the returned context, which may differ from the starting context; treat it as fatal to the current turn, report it, and stop the runtime.
- After every callback that can settle a promise (fs completion, timer, TCP read, signal), drain until `0`. After top-level evaluation, drain before deciding whether the process is finished.
- Pending QuickJS jobs **do not keep libuv alive**. `uv_loop_alive()` can be false while `JS_IsJobPending(rt)` is true, so a plain `uv_run(UV_RUN_DEFAULT)` exits with promises queued. Use either of these patterns:
  ```c
  for (;;) {
      if (drain_jobs(rt) < 0) break;
      if (!uv_loop_alive(loop) && !JS_IsJobPending(rt)) break;
      uv_run(loop, UV_RUN_ONCE);
  }
  ```
  or a `uv_prepare` handle that drains each iteration plus a `uv_idle` handle started only while jobs are pending. txiki.js uses the prepare/idle variant; both are valid, and DJS picks one in `loop/libuv.d` and tests it.
- Never call `uv_run()` from inside a JS callback. The loop is entered once, from `Runtime.run()`.
- `UV_RUN_NOWAIT` is useful for tests and for a bounded "drain then check" step; do not busy-loop with it in production.
- Keep-alive: a pending timer, fs request, or TCP handle refs the loop. `unref()` is exposed only where the API semantics require it.
- `queueMicrotask` enqueues with `JS_EnqueueJob` (exported in the pinned v0.17.0 header). Do not route it through a resolved promise unless you need promise semantics.
- **Driver contract:** drain with `while ((r = JS_ExecutePendingJob(rt, &jctx)) > 0)`; `r == 0` means empty; `r < 0` means a job threw and the exception is pending in `jctx` (which may differ from the starting context). Route `r < 0` through the uncaught-exception policy and stop the turn.
- **Fairness budget:** cap jobs per turn at 10,000. If the budget is exhausted, leave the rest queued, return to the loop, and drain again next iteration. A self-feeding promise chain must not starve timers or I/O.
- **`uv_stop` does not run close callbacks.** After a stop request (exit or timeout), call `uv_run(loop, UV_RUN_NOWAIT)` once to let pending `uv_close` callbacks run before `uv_loop_close`; otherwise `uv_loop_close` returns `UV_EBUSY` and handle memory leaks.
- **Unhandled rejections are evaluated at the end of each job drain**, not at loop exit. A promise rejected in this tick and handled by the end of the same microtask checkpoint is not unhandled; one handled in a later macrotask is.

## 8. Module system

### 8.0 Module classification (the rule all three documents share)

There is exactly one classifier; `require`, `import`, and the entry point all call it. The **project root** is the nearest directory containing a `package.json` above the entry file (or the current directory for `djs -e`). The entry is canonicalized with `realpath` before the search, so a symlinked entry classifies like its target. Paths are canonicalized before classification and caching; a path that escapes the root is rejected (no `--allow-outside-root`).

| Input | Classification |
|---|---|
| `.mjs` | ESM |
| `.cjs` | CommonJS |
| `.js` | ESM if the nearest ancestor `package.json` has `"type": "module"`; otherwise CommonJS-capable script |
| entry `djs file.js` | Same rule. A `.js` without `"type": "module"` runs as a **script** (global eval, `require` available); `.cjs` runs as a CJS module; `.mjs` runs as ESM. |
| `import` target | Classifier result. ESM → ESM; CJS → namespace with `default` (plus named where statically detectable); `.json` → JSON module. |
| `require` target | Classifier result. CJS → wrapper; ESM (`.mjs` or `.js` under `"type":"module"`) → `ERR_REQUIRE_ESM`; `.json` → parsed value. |
| no extension | Probe `.js`, `.json`, `.mjs`, `.cjs` in that order; directory → nearest `package.json` `exports`/`main`, else `index.js`/`index.cjs`/`index.mjs`. |
| bare specifier | Builtins first: `fs`, `node:fs`, `fs/promises`, `node:fs/promises`, `process`, `node:process`, `path`, `node:path`, `os`, `node:os`; otherwise walk `<dir>/node_modules/<name>` upward to the project root (scoped names, subpaths, `exports`/`imports` maps, conditions and patterns supported). Missing → `ERR_MODULE_NOT_FOUND` (import) / `MODULE_NOT_FOUND` (require). No package manager. |

`fs`, `process`, `path`, `os` and `Buffer` are installed as globals. Bare package entries go through `exports` when present (string, conditions, subpaths, patterns); otherwise `main` and the index fallbacks are used.

### 8.1 ESM

Register with the five-argument API; it is not a wrapper around the older three-argument call:

```c
typedef char *JSModuleNormalizeFunc(JSContext*, const char *base, const char *name, void *opaque);
typedef JSModuleDef *JSModuleLoaderFunc2(JSContext*, const char *name,
                                         void *opaque, JSValueConst attributes);
typedef int JSModuleCheckSupportedImportAttributes(JSContext*, JSValueConst attributes);
void JS_SetModuleLoaderFunc2(JSRuntime *rt, JSModuleNormalizeFunc *normalize,
                             JSModuleLoaderFunc2 *load,
                             JSModuleCheckSupportedImportAttributes *check_attrs,
                             void *opaque);
void JS_SetModuleNormalizeFunc2(JSRuntime *rt, JSModuleNormalizeFunc2 *normalize);
JSValue JS_GetImportMeta(JSContext *ctx, JSModuleDef *m);
```

- **Normalize** returns a `js_malloc`-allocated specifier (the engine frees it with `js_free`), or `NULL` with an exception set. `NULL` for the normalize parameter uses QuickJS's default relative resolution. Attribute-aware normalization is registered separately with `JS_SetModuleNormalizeFunc2`.
- **Load** receives the normalized name and `attributes`; it returns a `JSModuleDef*`. Read the file, call `JS_Eval(ctx, src, len, filename, JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY)`, and free the temporary `JSValue` wrapper after extracting the pointer (the runtime keeps its own reference).
- **Import attributes** are decided by `check_attrs`: accept `with { type: "json" }` (and text/bytes only if implemented); reject unknown types with a `TypeError`. This callback is the only place the `with { type: ... }` decision is made.
- **`import.meta`** comes from `JS_GetImportMeta(ctx, m)`; populate `url`, `filename`, `dirname` on that object and store per-module data with `JS_SetModulePrivateValue`.
- **JSON** modules: `JS_ParseJSON` + a synthetic C module exporting `default`, or QuickJS-NG's import-attribute path.
- Dynamic `import()` is asynchronous by construction: it creates a promise and enqueues a job that runs the loader. Without the job pump, `await import("./x.js")` never settles. Static imports resolve during linking; top-level await can make evaluation async, so keep pumping.
- Do not link `quickjs-libc`: it brings its own poll loop, loader, `std`/`os`, and workers, none of which match DJS's APIs. Build `libqjs.a` with `QJS_BUILD_LIBC=OFF` (or simply never link `libqjs-libc.a`).

### 8.2 CommonJS

`require` is a native function with a module cache keyed by the **canonical realpath** of the resolved file:

1. Resolve with the §8.0 classifier: relative/absolute; extension probing; directory → `package.json` `exports`/`main`; canonicalize with `realpath`; reject paths outside the project root.
2. If the target classifies as ESM, throw `ERR_REQUIRE_ESM`. Do not parse an ES module as CommonJS.
3. Read the source, wrap it as `(function (exports, require, module, __filename, __dirname) { ... })`, compile, and call it with a fresh `module.exports`.
4. Cache the module object (keyed by the canonical path) before executing to tolerate cycles.
5. JSON files return the parsed value.

ESM importing CJS gets the `module.exports` value as `default`; named properties are detected heuristically from the common `exports.x` / `module.exports = {x}` / `Object.defineProperty` patterns (`modules/cjsnames.d`).

## 9. API layer

**Native (D)** exposes primitives only:

- `__djs.fs.readFileStart(path, asText, callback)` / `writeFileStart(path, data, append, mode, callback)` / `statStart(path, callback)`; the rest follow the same `*Start` shape.
- `__djs.timer.start(delayMs, repeat, callback)` / `clear(id)`.
- `__djs.process.argv()`, `env()`, `cwd()`, `exit(code)`.
- `__djs.console.write(fd, string)`.

**Prelude (JS)** turns primitives into the public API: promise wrappers, callback-style overloads, argument validation, `fs.promises`, `util.promisify`-style adapters (only if needed), and the `require` shim. The prelude is a single `js/prelude.js` embedded as a string (or compiled with `qjsc` and linked as bytecode); it is installed into a fresh context before user code runs.

Why: the C surface stays small and testable, and Node-shaped behavior is easier to express in JS. The cost is one extra JS frame per call, which is irrelevant for I/O-bound APIs.

### 9.1 Callback registry (the async core)

The registry is the only bridge between a libuv completion and a JavaScript function. Treat it as a first-class component, not a map hidden in `fs.d`.

- A slot is `{ JSValue fn; uint32 generation; enum { free, active, cancelled } state; }`, allocated with `malloc` and stored in a runtime-owned table. The public id is `(generation << 32) | index`; a stale id fails the generation check and is ignored, never dereferenced.
- Registering a callback does `JS_DupValue`; the registry owns exactly one reference. It is freed on fire, on cancel-with-no-in-flight-request, or by `freeAll` during teardown — exactly once.
- A completion calls `JS_Call(ctx, fn, JS_UNDEFINED, argc, argv)`. There is no JS caller to return `JS_EXCEPTION` to, so a thrown exception goes through the uncaught policy: print, set exit code 1, stop the loop.
- `cancel` is not exposed: no public API returns a cancellable request, so the registry has no `cancelled` state and `uv_cancel` is not used. A future `fs.cancel`/abort seam must add the state back together with a completion that can reclaim a cancelled slot; until then teardown ownership is the only cancellation path (`freeAll` after handles close).
- Shutdown order is fixed: stop/close all JS-visible handles → run the loop until `uv_close` callbacks fire → `freeAll` (freeing every `JSValue`) → `JS_FreeContext` → `JS_FreeRuntime` → `uv_loop_close`. No `JSValue` may outlive the runtime.

### 9.2 Console contract (v0.1)

Golden files and differential tests need a written spec, not "Node-like".

- `console.log`/`info` → stdout; `error`/`warn` → stderr; each call ends with `\n`; `console.log()` prints a blank line.
- Primitives: `String(v)` (`undefined`, `null`, booleans, numbers including `-0` and `NaN`, strings, symbols, bigint).
- Objects: a named `inspect` subset — depth 2, no colors, `[Circular]` for cycles, arrays as `[ 1, 2 ]`, plain objects as `{ a: 1 }`, and `Error` printed as its `stack` when present. Functions print `[Function: name]`.
- Format specifiers supported: `%s`, `%d`, `%i`, `%f`, `%j`, `%o`, `%O`, `%%`. Extra arguments are appended space-separated.
- Not implemented: `console.table/group/time/count`, colors, `Symbol.for('nodejs.util.inspect.custom')`, `Map`/`Set` pretty-printing (print them as objects or add later).
- Writes are synchronous `write(2)` calls; no buffering layer in v0.1. A failed write is ignored (stdout may be closed).

### 9.3 Timer contract (v0.1)

- `setTimeout`/`setInterval` return a prelude `Timeout` object with `ref()`, `unref()`, `hasRef()`, `refresh()`, and `[Symbol.toPrimitive]`; the native id is internal. `clearTimeout(undefined)` and double clears are no-ops.
- Delay clamp: `< 1`, `NaN`, or non-numeric → 1 ms; `> 2^31-1` → 1 ms plus a warning (Node's behavior). Equal deadlines fire in insertion order (FIFO), which libuv provides through its start-id ordering; there is no separate sequence field.
- A timer callback that throws is an uncaught exception: print and exit 1.
- Each active timer refs the loop; `unref` drops the ref. A retired timer handle is stopped and pushed onto a per-runtime free list for reuse; the free list is `uv_close`d and freed at teardown (or when it grows past its cap), so timer create/clear churn does not churn native memory. Never free a started handle in `uv_timer_stop`.
- Timer state is a registry slot (§9.1) plus a `uv_timer_t*` allocated with `uv_handle_size(UV_TIMER)`; `uv_handle_set_data` points at the state. The id is not the pointer.

### 9.4 fs buffer ownership (the other crash source)

`fs.writeFile(path, buf)` hands bytes to a threadpool request that outlives the JS call.

**Implementation note (v0.1):** async fs runs blocking POSIX `open`/`read`/`write`/`stat`/`scandir` on a libuv threadpool thread via `uv_queue_work`, not through `uv_fs_*`. The reasons: one code path for the read/write loops the architecture requires anyway, simpler error mapping, and no `uv_fs_t` lifetime to audit. v0.6 added `fs.open` and the fd table on this
 path; the callback wrappers for `read`/`write`/`fsync`/links/modes still run
 their syscall on the loop thread inside `queueMicrotask`, a known gap listed
 in PLAN's v0.7 prerequisites. The costs are explicit and accepted: a request cannot be cancelled while it is blocked (a FIFO or device read holds a threadpool thread), `uv_fs_req_cleanup` does not apply because there is no `uv_fs_t`, and teardown must not wait for such a request. That is why `runtimeTeardown` drains with bounded `UV_RUN_NOWAIT` turns and leaves a stuck loop unfreed rather than blocking `process.exit()`. `readFile` still applies `fstat` + a cap: 512 MiB for regular files (`DJS_MAX_FILE_SIZE` lowers it), 16 MiB for non-regular files, both failing with `EFBIG`. The JS `ArrayBuffer` can be detached or collected while the write is in flight.

- **v0.1 copies** the view's bytes into a request-owned `malloc` buffer before queueing the write. This is correct by construction: the JS `ArrayBuffer` can be detached or collected immediately after the call. If a later optimization avoids the copy, it must hold a **dup'd `JSValue`** plus the view's `byteOffset`/`byteLength`, and re-fetch the raw pointer immediately before the write.
- For a read result, allocate the output with `malloc`, create the JS string/value in the completion callback, then free the buffer. For an `ArrayBuffer`, use `JS_GetArrayBuffer`; for a typed-array view, `JS_GetTypedArrayBuffer` (never `JS_GetArrayBuffer`, which returns NULL for views).
- Async fs state lives in `FsWork`: path/bytes are copied before the call, the request is `uv_queue_work`'d, and the completion maps `errno` to `{code, errno, path, syscall}`. There is no `uv_fs_t` and no `uv_fs_req_cleanup`; do not add one without removing the other. Ownership transfers to the request and the completion frees it.
- Handle short writes: loop until the byte count is satisfied or the request errors. `readFile` uses `fstat` + a bounded read loop; do not assume one `uv_fs_read` returns the whole file.
- `writeFile` opens with create/truncate and mode `0o666`; a failed open leaves no fd behind.
- **Synchronous fs variants** use blocking POSIX calls (`open`/`read`/`write`/`fstat`/`close`) directly on the loop thread. They must never call `uv_run` or re-enter JS, and they are documented as blocking timers and I/O for the duration. `RuntimeOptions` has no separate sync toggle in v0.1: `fs: false` disables the whole surface.

### 9.5 Capability seam

`RuntimeOptions` decides which globals are installed: `console`, `timers`, `fs`, `process`, and `require`. An embedder can omit `fs` and `process` for a restricted script.

On top of that seam, v0.4.0 adds Deno-style permissions (`src/djs/permissions.d`). Native fs/env/os entry points call `permissionCheck` before touching the OS; the default is deny, `-A` restores the old behaviour, `--deny-*` wins, and `djs.json` sets/audit/prompts are supported. Module loading is exempt and confined to the project root. This remains least authority, not a kernel sandbox: a memory-safety bug in the engine or native code can bypass it, which is why Landlock is a separate phase.

### 9.6 Prelude modules (v0.5.0–v0.6.0)

`events`, `stream`, `url`, `util`, `timers/promises`, `structuredClone` and
`AbortController` are implemented in `js/prelude.js` over the existing native
primitives, then exposed through the global scope and the builtin-module table
in `classify.d`/`cjs.d`/`esm.d`. This keeps the D surface small and makes the
modules auditable in one place. The trade is performance and edge-case fidelity:
streams are a simplified backpressure model, fs streams buffer whole files, and
the URL parser is not a full WHATWG implementation. `COMPAT.md` records those
differences; the integration and Node differential suites pin the supported
subset.

### 9.7 Networking (v0.7.0)

`net.d` keeps a 128-entry socket table. `connect` resolves IPv4 with
`getaddrinfo`, creates a nonblocking `SOCK_STREAM|SOCK_NONBLOCK|SOCK_CLOEXEC`
descriptor, and watches it with a `uv_poll` handle. The poll callback owns the
state machine: connect completion (`SO_ERROR`), reads, and queued writes.
`net.Socket` in the prelude is an `EventEmitter` over those callbacks.

Deliberate limits: DNS blocks only in `getaddrinfo` (`uv_getaddrinfo` on the
threadpool); writes are queued and drained on writable events but a single
`send` can still perform work in the callback; backpressure remains one queued
buffer. TLS (client and server) is OpenSSL 3 in `apis/tls.d`, with the
handshake on a worker thread and reads/writes on `uv_poll`; HTTP/1.1, HTTP/2,
WebSocket, `http` and `fetch` are layered over these transports (see
`docs/COMPAT.md` for the exact surface).

The TLS table holds 256 live sockets. When a client handshake completes and
every slot is busy, the connection waits in a FIFO queue until a socket closes;
client callers never see `ERR_TLS_EXHAUSTED` for a normal burst. Because the
handshake blocks a worker, `main` sets `UV_THREADPOOL_SIZE=32` before libuv
initialises the pool unless the environment already specifies one. Client
keep-alive pooling then keeps the number of handshakes proportional to the
per-origin cap (128 for the global agents), not the request count; idle
connections are unref'd. See §9.4 for the fs side of the same pool.

## 10. Error handling, exit, and teardown

**Boundary errors.** Tier A implementations throw JS exceptions directly with the helpers above. Every **JS-callable** entry point runs inside `guarded` (`runtime.d`), which catches `Throwable`, prints `djs: internal error`, and exits 70, so a D exception never unwinds into QuickJS. Internal libuv callbacks (`onTimer`, `onPrepare`, `onIdle`, `fsAfterCb`, the rejection tracker) are plain `@nogc nothrow` code that only frees memory and enqueues work; they are not wrapped, and adding allocating or asserting code there requires adding a guard first. Nothing may unwind into C either way.

**Uncaught JS exception.** At the point of detection (eval, callback, job drain), call `JS_GetException` once — it clears the pending exception — then format it. Formatting may invoke user code (`toString`, a `stack` getter); arm the interrupt deadline, catch failures, and never let formatting replace the original error. Print `Uncaught <error>` plus `stack` when it is a string, to stderr, and exit 1. In the REPL, print and continue. Do not run arbitrary JS after `uv_stop`.

**Unhandled promise rejections.** `JS_SetHostPromiseRejectionTracker` is called twice for the same promise: `is_handled=false` at rejection and `true` when a handler is attached. The `promise` and `reason` arguments are borrowed. Maintain a set of **dup'd** rejected promises:

1. `is_handled=false` → add the dup'd promise and its dup'd reason.
2. `is_handled=true` → remove and free both.
3. After each job-queue drain (end of the microtask checkpoint, before the next macrotask), report every promise still in the set and exit 1.
4. Free every remaining value during teardown.

This matches Node's default `--unhandled-rejections=throw` closely enough to test. `warn`/`none` modes are not implemented.

**`process.exit(code)` is a request, not an immediate exit.**

- The native function flushes `console` (writes are already synchronous), sets `exitRequested`/`exitCode`, calls `uv_stop(loop)`, and returns `JS_UNDEFINED`.
- JavaScript continues to the end of the current turn. `process.exit(0); console.log("still here")` prints — document this divergence from Node. The driver then breaks and runs teardown.
- Do not call `JS_FreeContext`/`JS_FreeRuntime` inside the callback: the C stack still holds `JSValue`s and QuickJS's job loop will use the runtime after the call returns. That is a use-after-free.
- `process.reallyExit` is not provided. `_exit` is reserved for fatal internal errors after flushing.

**Module teardown ownership.** `runtimeTeardown` closes module state in a fixed
order before the bounded drain: timers, fs watchers, sockets/TLS/dgram,
signals, stdio and crypto. Handling callbacks that complete during the drain
must check `shuttingDown`/`failed`/`exitRequested` before running more JS.
Runtime-owned native state (the TLS CA store, watcher lists) is freed only
when the loop did not get stuck; a stuck loop is abandoned with its workers
rather than risking a use-after-free while `process.exit` returns.

**Teardown runs only in `main`, after the loop returns.**

1. Set `shuttingDown`; reject new requests. Registry slots are not marked cancelled (there is no cancellation state in v0.1); they are freed wholesale in step 4.
2. Close every JS-visible handle with `uv_close` (timers, the control handles, the deadline timer); do not free handle memory yet. In-flight fs requests are not cancellable: the bounded drain may end with the loop still alive, in which case the loop is deliberately left unfreed.
3. Run `uv_run(loop, UV_RUN_NOWAIT)` until no closing handles remain, up to a bounded number of turns (200 normally, 20 when JS asked to exit or the runtime already failed). Close callbacks are the only place handle memory is freed.
4. `freeAll` the callback registry, the module cache, and the rejection set — every `JSValue` is released here.
5. `JS_FreeContext(ctx)`, then `JS_FreeRuntime(rt)`.
6. `uv_loop_close(loop)`. If the loop is still alive and the exit was requested or the runtime failed, keep the recorded code and `_exit(code)` after freeing runtime-owned memory; if it is alive unexpectedly, print a diagnostic and return 70. Never free a live loop.
7. `free(loop)` when it closed cleanly, then exit with the recorded code.

**Stack traces.** QuickJS provides `error.stack`; the loader sets filenames and `import.meta.url` so frames are useful. The reporter must not read `.stack` from inside the rejection tracker; defer formatting until the report point.

## 11. Limits and safety

- `JS_SetMemoryLimit(rt, bytes)` — default 256 MiB, set with `--memory-limit` (there is no environment override in v0.1). It is enforced in QuickJS's allocator and counts only the QuickJS heap (including arena overhead); libuv buffers, the D GC, and binding `malloc`s are invisible. It is a JS budget, not an RSS cap. OOM surfaces as `InternalError: out of memory` and is catchable; an **uncaught** OOM exits 1, and a caught one does not (there is no `oomSeen` forced-exit policy in v0.1). When the engine cannot even allocate the exception object, the reporter recognises the null exception and prints `InternalError: out of memory`.
- `--timeout` is two mechanisms, not one: the interrupt handler bounds CPU-bound JS, and a real `uv_timer` deadline (unref'd, so it never keeps a script alive) wakes the loop out of `poll()` and stops timers/I/O scheduling. Neither can interrupt a blocking native `fs` call; the deadline still fires, the run exits 1, and teardown abandons the stuck loop. For hostile code the external process killer remains the complete answer.
- `JS_SetMaxStackSize(rt, bytes)` — default 1 MiB, clamped to 4 MiB regardless of a larger `--stack-size`, so the engine's guard stays below the real thread stack. Call `JS_UpdateStackTop(rt)` after any thread change. Native recursion is not covered.
- `JS_SetInterruptHandler(rt, cb, opaque)` — checked every 10,000 interpreter ticks (and during regexp execution). A non-zero return aborts with an **uncatchable** `InternalError: interrupted`. The handler must be `@nogc nothrow`, lock-free, and must not call back into JS; compare `uv_hrtime()` to a deadline. It never runs during native C functions or blocking syscalls, so a slow `fs` call is uninterruptible; an external process killer is the only complete answer for hostile code.
- `JS_SetCanBlock(rt, false)` on the main runtime so a stray `Atomics.wait` throws instead of blocking the loop. Only worker runtimes with their own loops may allow blocking.
- QuickJS is **not a security boundary**. Treat untrusted code as requiring process isolation (seccomp/container/unprivileged user), not just an interpreter. CVE history is a reminder to pin current and sandbox; most 2025 issues were in `quickjs-libc`, which DJS does not link.

## 12. Build and layout

```
djs/
  dub.json
  scripts/bootstrap.sh        # toolchain check + pinned QuickJS-NG build
  scripts/integration.sh      # JS suite + golden files
  scripts/gate.sh             # every gate; per-step logs in .dub/
  scripts/gate-sanitize.sh    # ASan/LSan fixture pass
  scripts/gate-alloc.sh       # unittest suite incl. GC counter
  scripts/check-abi.sh        # C probe against the pinned header
  scripts/bench.sh            # measurements -> docs/BENCH.md
  scripts/fuzz.sh             # hostile-argument boundary probes
  scripts/package.sh          # deterministic release tarball
  src/djs/
    main.d                    # CLI, REPL, options, entry dispatch
    runtime.d                 # lifecycle, globals, prelude, job drain, loop, teardown
    platform.d                # shared POSIX/druntime gaps (Darwin + Linux)
    registry.d                # callback slots (C memory, one JSValue each)
    bindings/quickjs.d        # extern(C) declarations + types
    bindings/value.d          # ScopedValue, conversions, helpers
    loop/libuv.d              # uv declarations (opaque types + *_size/accessors)
    apis/console.d
    apis/timers.d             # setTimeout/setInterval + recycling pool
    apis/net.d                # TCP client sockets, uv_poll, DNS lookup gate; HTTP server
    apis/tls.d                # TLS client/server (OpenSSL), shared-CA store, hostname check
    apis/fs.d                 # read/write/append/stat/readdir/mkdir/unlink/rename/copy/rm/realpath;
                              # fd/open/read/write/close, chmod/chown/link/symlink/readlink, truncate, fsync
    apis/bytes.d              # Buffer codecs (utf8/latin1/hex/base64)
    apis/os.d                 # os information (cpus, memory, hostname, tmpdir)
    apis/process.d
    modules/path.d            # path strings, realpath, file reads, package.json
    modules/classify.d        # the single .mjs/.cjs/.js/.json classifier
    modules/json.d            # malloc-backed JSON reader for package metadata
    modules/pkgexports.d      # exports/imports maps, conditions, patterns
    modules/cjsnames.d        # heuristic CJS named-export detection
    modules/resolve.d         # specifier → canonical path + containment
    modules/cjs.d             # require, wrapper compilation, cycle-safe cache
    modules/esm.d             # loader callbacks, import.meta, entry dispatch
  js/prelude.js               # embedded prelude
  tests/                      # D unittests + JS integration + golden
  tests/ut_main.d             # empty main; druntime runs every unittest block
  tests/js/                   # integration scripts (flat or <name>/main.*)
  tests/golden/               # expected stdout/stderr/exit codes
  vendor/quickjs-ng/          # fetched by bootstrap, pinned
```

Build: `dub build --build=release`. Link `vendor/quickjs-ng/build/libqjs.a` through `libs: ["qjs", "uv", "m", "dl", "pthread"]` and `lflags: ["-L$PACKAGE_DIR/vendor/quickjs-ng/build"]`; list the archive in `extraDependencyFiles` so DUB relinks when it is rebuilt. Include path: `vendor/quickjs-ng`. Do not link `libqjs-libc.a`. The implementation's `dub.json` is authoritative once it builds.

**ABI gate (fail closed).** Two probes run against the pinned header: `bootstrap.sh` compiles an inline `_Static_assert` probe while validating the engine build, and `scripts/check-abi.sh` compiles `build/abi_check.c` with `cc -std=c11 -Ivendor/quickjs-ng` on every gate run. Both check the same properties:

```c
#include "quickjs.h"
#ifdef JS_NAN_BOXING
#error "DJS requires the non-NaN-boxed 64-bit JSValue"
#endif
#ifdef JS_CHECK_JSVALUE
#error "JS_CHECK_JSVALUE is a debug checker; do not build the runtime with it"
#endif
_Static_assert(sizeof(JSValue) == 16, "JSValue layout mismatch");
_Static_assert(sizeof(void*) == 8, "DJS v0.1 targets 64-bit");
```

The D side asserts the same size/alignment, but only this C probe sees the engine's actual compile flags. If it fails, stop; do not "fix" it by changing the D struct.

**Bootstrap pins.** `scripts/bootstrap.sh` compares LDC (`1.36`), DUB (`1.36`), libuv (`1.48`), and Ninja (`1.11.1`) against `docs/PINS.md`, verifies the QuickJS commit, writes commit + CMake arguments to `vendor/quickjs-ng/build/.djs-stamp`, and rebuilds when the stamp differs. `DJS_ALLOW_VERSION_DRIFT=1` is the only escape hatch and prints a warning. It builds with `-DQJS_BUILD_EXAMPLES=OFF -DQJS_ENABLE_INSTALL=OFF`; `QJS_BUILD_LIBC=OFF` is preferred, but if the `qjs` oracle needs libc, build it in a separate directory and never link `libqjs-libc.a`.

## 13. Testing strategy

- **D unit tests** (`unittest` blocks, `dub test`): callback-slot generations and free-list reuse, `ScopedValue` negative copy test, and the zero-GC-allocation timer counter. Path resolution, argument conversion, module cache keys and error formatting are covered by the JS integration suite, not D unittests.
- **JS integration tests** (`tests/js/*.js` + `tests/golden/*.txt`): run under `djs`, compare stdout/stderr/exit code. Required cases: async ordering, fs reads/writes (including a subarray and a dropped-buffer GC case), ESM/CJS interop and `ERR_REQUIRE_ESM`, cycles, JSON imports, uncaught errors, microtask throws, unhandled rejection timing, `process.exit` in a timer, stale timer ids, opaque-method misuse (`fs.readFile.call(1, ...)`), format-string injection, and module-root escape.
- **Differential checks**: `scripts/diff-node.sh` runs a case list under both `node` and `djs`, normalizes temporary paths, and compares stdout plus exit status (the case list lives in the script; it is
  skipped cleanly when Node is absent). `docs/COMPAT.md` records every intentional difference; the golden suite remains the behavioural contract.
- **Leak checks**: `process.memoryUsage()` exposes QuickJS heap + RSS; `scripts/gate-sanitize.sh` builds with `-fsanitize=address`, verifies every listed case runs, and fails on an exit-status mismatch or any ASan/LSan report. Linux runs ASan + LSan; macOS runs ASan only, because libuv's FSEvents thread and OpenSSL keep process-lifetime allocations LSan would report. `JS_DUMP_LEAKS` and Valgrind runs are **deferred**. The D unittest suite adds a 1,000-cycle timer churn assertion that the D GC allocation counter does not move.
- **Gate results**: `scripts/gate.sh` runs the ABI probe, the no-phase-refs check, build, the unittest suite (including the zero-GC-allocation counter), the integration suite, the ASan/LSan pass, the loopback networking gate, the Node differential and the soak test, and exits non-zero if any step fails. Per-step output is kept in `.dub/gate-*.log`; CI job logs are the durable record. Generated gate output is not committed — the repository stays source-only.

## 14. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| QuickJS interpreter is slow on CPU-bound JS | Wrong tool for heavy compute | Scope to I/O/glue; document; offer a future JSC/V8 seam |
| GC/manual-memory boundary bugs | Crashes, leaks | Ownership rules, ASan/LSan gate, GC-counter unittest |
| libuv + QuickJS re-entrancy | Use-after-free, loop corruption | Never run the loop inside a callback; no JS calls from thread pool |
| No `Intl`/WASM | Node incompatibility | Document; polyfill/`Intl` later via ICU binding |
| C engine CVE | Host compromise | Pin current, sandbox, fuzz the boundary |
| D toolchain churn | Build breaks | Pin LDC, `dub.selections.json`, CI gate |
| Windows/macOS drift | Platform gaps | Keep libuv/QuickJS behind seams; no Linux-only APIs in core |

## 15. Future seams

- **HTTP/TLS**: a `net` + `http` layer over libuv; OpenSSL/mbedTLS behind a `tls` interface.
- **Workers**: one `JSRuntime` per thread, message queue; decide between `os.Worker` and a D thread + QuickJS context.
- **Alternate engine**: keep `bindings/` engine-specific and the runtime API engine-agnostic; a JSC/V8 backend is a later ADR, not a rewrite.
- **Inspector**: QuickJS has no CDP inspector; a debugger would be a separate protocol over the runtime's debug hooks.
