# Embedding QuickJS-NG in a native host, with libuv as the event loop

Research memo for a C-ABI host embedding QuickJS-NG with a libuv event loop. For a systems developer who knows event loops and FFI but not QuickJS. Claims are against QuickJS-NG **v0.17.0** unless marked; version-specific behavior is flagged.

**Bottom line:** pin QuickJS-NG, not Bellard's. One `JSRuntime` + `JSContext` per thread, one `uv_loop_t` on that thread, our own loader and stdlib, one microtask-drain point at the loop boundary. Not a sandbox; not a context per request.

## 1. Lineage, versions, license, build

| Engine | Bellard's QuickJS | QuickJS-NG |
|---|---|---|
| Home | <https://bellard.org/quickjs/> | <https://github.com/quickjs-ng/quickjs> |
| Origin | Fabrice Bellard and Charlie Gordon, 2017 | Fork after dormancy; Ben Noordhuis, Saúl Ibarra Corretgé, contributors |
| Version | date releases; current **2026-06-04** | 0.x tags; current **v0.17.0**, commit `6d46d07d04041b40f4f49eaa7fdebe44c314c699`, tagged 2026-09-18 |
| License | MIT | MIT |
| Build | Makefile: `libquickjs.a`, `qjs`, `qjsc` | CMake + helper Makefile, amalgamated zip, sanitizers |

NG is the right base: active, CMake-native, MIT, maintained next to libuv. Cost: 0.x churn, public structs (`JSValue`, `JSClassDef`), no ABI promise. **Pin the commit and compile against that header.** Record tag and SHA in `vendor/quickjs/VERSION`; fail if `git rev-parse HEAD` differs.

Static build (v0.17.0 defaults `BUILD_SHARED_LIBS=OFF`, yielding `libqjs.a`):

```bash
cmake -S vendor/quickjs -B build/qjs -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
  -DQJS_ENABLE_INSTALL=OFF -DQJS_BUILD_EXAMPLES=OFF -DQJS_BUILD_LIBC=OFF
cmake --build build/qjs --target qjs
```

`QJS_BUILD_LIBC=OFF` keeps `quickjs-libc.c` in a separate `qjs-libc` target. Do not link it: it brings its own poll loop, loader, `std`/`os`, and workers — none match our APIs. Link `build/qjs/libqjs.a` plus `-lm -lpthread -ldl`. C11; same compiler and flags each rebuild. Build `qjs` as an oracle.

## 2. Core C API and ownership

```c
JSRuntime *rt = JS_NewRuntime();       /* allocator, GC, atoms, job queue */
JS_SetMemoryLimit(rt, 256u << 20);
JS_SetMaxStackSize(rt, 1u << 20);
JSContext *ctx = JS_NewContext(rt);    /* globals + intrinsics */
/* ... */
JS_FreeContext(ctx);
JS_FreeRuntime(rt);
```

A runtime is single-threaded, not thread-safe. `JS_NewContext` installs intrinsics; `JS_NewContextRaw` + `JS_AddIntrinsic*` builds leaner. Free contexts before the runtime, values before their context. `JS_FreeRuntime` runs remaining finalizers LIFO and the runtime is unusable during them ([quickjs.h](https://github.com/quickjs-ng/quickjs/blob/v0.17.0/quickjs.h)).

`JSValue` is 16 bytes on 64-bit: a union (`int32`, `double`, `void*`, short bigint) plus `int64_t tag`. The header states the convention:

- `JSValue` parameter takes ownership; caller must not free.
- `JSValueConst` parameter is borrowed; caller keeps its reference.
- returned `JSValue` transfers ownership; returned `JSValueConst` does not.

Store with `JS_DupValue(ctx, v)`; release with `JS_FreeValue(ctx, v)`.

Debug builds can compile with `-DJS_CHECK_JSVALUE`, making the types distinct pointers so the compiler catches mix-ups (a checker; it does not produce working code).

```d
extern (C) {
    union JSValueUnion { int int32; double float64; void* ptr; int short_big_int; }
    struct JSValue { JSValueUnion u; long tag; }
}
alias JSValueConst = JSValue;
static assert(JSValue.sizeof == 16);
```

Use `JS_Is*`/`JS_To*`, never the tag. Guard owned values so early returns free:

```d
struct Owned {
    JSContext* ctx; JSValue v;
    ~this() @nogc nothrow { if (ctx) JS_FreeValue(ctx, v); }
}
```

**Exceptions.** One pending exception per context. A failing C function calls a `JS_Throw*` (returns `JS_EXCEPTION`) and returns it; returning `JS_EXCEPTION` without setting one violates the contract and may assert. Callers test `JS_IsException`, then `JS_GetException(ctx)`, which **takes and clears** it. `JS_HasException` peeks (v0.17.0). Clear before further JS calls.

```c
JSValue r = JS_Call(ctx, fn, JS_UNDEFINED, argc, argv); /* argv borrowed */
if (JS_IsException(r)) {
    JSValue e = JS_GetException(ctx);   /* clears */
    /* format e, then */
    JS_FreeValue(ctx, e);
}
```

`JS_Eval(ctx, src, len, filename, flags)` takes `JS_EVAL_TYPE_GLOBAL` or `JS_EVAL_TYPE_MODULE`; `JS_EVAL_FLAG_COMPILE_ONLY` returns a bytecode/module object for `JS_EvalFunction`. `JS_Call` returns owned or `JS_EXCEPTION`; arguments are borrowed.

**C functions.** `JSCFunction` is `(JSContext*, JSValueConst this_val, int argc, JSValueConst *argv)`; `argv` borrowed, return owned or `JS_EXCEPTION`. `JS_NewCFunction(ctx, fn, name, length)` wraps `JS_NewCFunction2` with `JS_CFUNC_generic`. For state use magic/data variants or `JS_NewCClosure` with an opaque finalizer. `JS_SetPropertyFunctionList` installs a method table in one call.

**Properties.** `JS_GetPropertyStr` returns owned. `JS_SetPropertyStr`/`Uint32` **consume** `val`, on success and failure (verified in `JS_SetPropertyInternal2`); do not free afterward. `JS_DefinePropertyValue*` also consumes. `JS_GetOwnPropertyNames` allocates `JSPropertyEnum[]` → `JS_FreePropertyEnum`. `JS_ToCString` returns a runtime buffer → `JS_FreeCString`; copy before the next JS call.

**Opaque/classes.**

```c
static JSClassID point_id;
JS_NewClassID(rt, &point_id);                    /* once per runtime */
JSClassDef def = { .class_name = "Point",
                   .finalizer = point_finalizer, .gc_mark = point_gc_mark };
JS_NewClass(rt, point_id, &def);
JSValue obj = JS_NewObjectClass(ctx, point_id);
JS_SetOpaque(obj, p);
```

`JS_GetOpaque2(ctx, obj, point_id)` validates and throws TypeError. The finalizer gets `JSRuntime*`, not a context: use `JS_FreeValueRT`/`js_free_rt` and no context-taking JS calls. If the struct stores `JSValue`s, `gc_mark` must call `JS_MarkValue` for each, or cycles through native memory are invisible. Allocate with `js_malloc_rt` to count against the limit.

## 3. Modules

`JS_SetModuleLoaderFunc(rt, normalize, loader, opaque)`. `normalize` may be `NULL` for the default, which resolves `./x`/`../x` against the importing module and leaves bare specifiers unchanged. A custom normalizer returns a `js_malloc`'d string (engine frees with `js_free`) or `NULL` with an exception. The loader gets the normalized name and returns a `JSModuleDef*`, or `NULL` with an exception.

```c
static JSModuleDef *loader(JSContext *ctx, const char *name, void *opaque) {
    size_t len; char *src = djs_read_file(name, &len);
    if (!src) { JS_ThrowReferenceError(ctx, "cannot load %s", name); return NULL; }
    JSValue m = JS_Eval(ctx, src, len, name,
                        JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY);
    free(src);
    if (JS_IsException(m)) return NULL;
    JSModuleDef *mod = JS_VALUE_GET_PTR(m);
    JS_FreeValue(ctx, m);   /* runtime owns the module */
    return mod;
}
```

This mirrors `quickjs-libc`'s loader; the runtime already references the module. Native modules use `JS_NewCModule`/`JS_AddModuleExportList`.

Resolution is ours: QuickJS calls normalize then loader, caching by normalized name. Extension probing, `exports`, `node_modules`, and JSON imports are host code. v0.17.0 adds `JS_SetModuleLoaderFunc2` with import attributes (`with { type: "json" }`) and `JS_SetModulePrivateValue`, which `quickjs-libc` uses for JSON modules.

**Dynamic import is asynchronous by construction.** `import()` creates a promise and enqueues `js_dynamic_import_job`; the loader runs in that job ([quickjs.c](https://github.com/quickjs-ng/quickjs/blob/v0.17.0/quickjs.c)). Without a job pump, `await import("./x.js")` never settles. Static imports resolve during linking; top-level await can make evaluation async — check the tag and keep pumping (verify the exact TLA return shape in tests).

## 4. Promises and microtasks

One job queue per runtime: promise reactions, async continuations, `import()`, finalization jobs.

```c
static int drain_jobs(JSRuntime *rt) {
    JSContext *jctx; int r;
    while ((r = JS_ExecutePendingJob(rt, &jctx)) > 0) { }
    return r;   /* 0 = drained, -1 = a job threw */
}
```

Returns `1` per job, `0` when empty (`*pctx = NULL`), `-1` on exception with it pending in `*pctx` — which may differ from the starting context. `JS_IsJobPending(rt)` keeps the loop alive; `JS_EnqueueJob` queues host jobs.

Pump after every JS entry (eval, module eval, timer/I/O `JS_Call`), before blocking in `uv_run`, and after resolving a host promise. Even `await 1` resumes in a later job, so without a pump nothing after the first `await` runs. Draining to empty after each macrotask approximates Node ordering. Do not drain mid-binding unless re-entrant user code is intended.

`JS_SetHostPromiseRejectionTracker` reports rejected promises with `is_handled`; record and report at exit, never throw or run JS there. No fairness limit exists: a self-enqueuing chain starves libuv; the interrupt handler is the only brake.

## 5. Limits and safety

- `JS_SetMemoryLimit(rt, bytes)`, `0` disables. Enforced in `js_malloc`/`js_realloc` (arena overhead included); surfaces as `InternalError: out of memory`. Counts only QuickJS heap — libuv buffers, D GC memory, binding `malloc`s are invisible: a budget, not an RSS cap.
- `JS_SetMaxStackSize(rt, bytes)`, `0` disables; default 1 MiB (`JS_DEFAULT_STACK_SIZE`, v0.17.0). Compiled into `stack_limit` from the C stack pointer: call `JS_UpdateStackTop(rt)` after moving threads, and set it below the real thread stack to leave room for libuv/D frames. Exceeding throws `RangeError: Maximum call stack size exceeded`. Native recursion is not covered.
- `JS_SetInterruptHandler(rt, cb, opaque)`: non-zero aborts, checked every 10,000 interpreter ticks (`JS_INTERRUPT_COUNTER_INIT`) and in regexp execution. Abort throws an **uncatchable** `InternalError: interrupted`. The handler must be cheap, allocation-free, lock-free, and call no JS; compare `uv_hrtime()` to a deadline in the runtime opaque. It never runs in native C functions or blocking syscalls, so a slow `fs` call or C loop is uninterruptible.

Watchdogs: (a) interrupt deadline for CPU-bound JS; (b) loop-level deadline stopping timers and sockets; (c) for untrusted code, an external killer (process + `setrlimit`/cgroup), the only option that survives a native hang. After an interrupt, discard the runtime; policy, not a guarantee.

**Not a security boundary.** QuickJS runs in-process with host privileges. Memory limits and interrupts are cooperative; `std`/`os` expose files and processes; SAB/Atomics can block; bytecode reading is explicitly unhardened — the header warns `JS_READ_OBJ_BYTECODE` on hostile input can corrupt memory. Engine memory bugs are host RCE. Untrusted code needs a separate process, OS sandbox (seccomp/landlock/namespaces), resource limits, and no host bindings.

## 6. Workers and threads

QuickJS core has no threads. `os.Worker` is `quickjs-libc`: a pthread per worker with its own `JSRuntime`/`JSContext`. Messaging uses pipes and a structured-clone-like serializer; `SharedArrayBuffer`s are shared. Docs cover `postMessage(msg)`, `onmessage`, and `Worker.parent` — no transfer list — and the source has no `terminate()`, so lifetime is tied to message handlers. `Atomics.wait` requires `JS_SetCanBlock(rt, true)`; leave it false on the main runtime so a stray wait throws instead of blocking the loop.

`JSValue` never crosses a runtime or thread; SAB is the only shared memory; each worker needs its own loader, loop, and `JS_UpdateStackTop`. v0.1 should not expose workers. Later, implement our own thread (own runtime, message pipe, `uv_async`), not `os.Worker`, whose bootstrap assumes `quickjs-libc`.

## 7. libuv integration

One `uv_loop_t` per runtime, initialized and run on that thread. The loop and handles are not thread-safe except where documented; multiple loops belong on separate threads ([design](https://docs.libuv.org/en/v1.x/design.html)). Successful `uv_*_init` obliges `uv_close`; memory is freed only in or after `uv_close_cb`. Requests self-close except `uv_fs_t` (`uv_fs_req_cleanup`) and `uv_getaddrinfo_t` (`uv_freeaddrinfo`).

**Timers.** Store `uv_timer_t`, callback, and args in one host struct.

```c
static void on_timer(uv_timer_t *h) {
    Timer *t = h->data;
    JSValue r = JS_Call(t->ctx, t->fn, JS_UNDEFINED, t->argc, t->argv);
    if (JS_IsException(r)) djs_report_exception(t->ctx);  /* clears */
    JS_FreeValue(t->ctx, r);
    drain_jobs(JS_GetRuntime(t->ctx));
    if (!t->repeat) destroy_timer(t);   /* uv_close + free in close_cb */
}
```

`clearTimeout` = `uv_timer_stop` + `uv_close(handle, close_cb)`; free the struct and its JSValues in `close_cb`. Repeat timers re-arm; check `uv_is_closing` before touching a timer another callback may have cleared. `uv_close` callbacks never run synchronously ([handle docs](https://docs.libuv.org/en/v1.x/handle.html)).

**fs.** One `uv_fs_t` per operation, alive until its callback: check `req->result`, copy into JS (`JS_NewStringLen`, `JS_NewArrayBufferCopy`), `uv_fs_req_cleanup`, free, drain. fs runs on the global thread pool (default 4, `UV_THREADPOOL_SIZE`, max 1024); callbacks run on the loop thread, so JS is safe. Version note: libuv 1.45–1.48 can hand some Linux fs ops to io_uring; 1.49 reverted to threadpool by default, io_uring opt-in via `UV_LOOP_USE_IO_URING_SQPOLL` ([fs docs](https://docs.libuv.org/en/v1.x/fs.html)). With 1.48 pinned, assume neither threadpool-only nor ordered completion.

**TCP.** A connection owns `uv_tcp_t`. `uv_read_start` needs an `alloc_cb` allocating from malloc/arena (never D GC) and a `read_cb` that wraps bytes, calls JS, frees, drains. EOF/error → `uv_close`. Each `uv_write_t` owns its buffer until its callback. Map `uv_strerror` to JS exceptions.

**Loop plus microtasks.** Pending QuickJS jobs do not keep libuv alive, so plain `uv_run(UV_RUN_DEFAULT)` exits with promises queued. Either:

```c
for (;;) {
    if (drain_jobs(rt) < 0) break;
    if (!uv_loop_alive(loop) && !JS_IsJobPending(rt)) break;
    uv_run(loop, UV_RUN_ONCE);
}
```

or a `uv_prepare` that drains each iteration plus a `uv_idle` started only while `JS_IsJobPending` — txiki.js's pattern.

Cross-thread wakeup is `uv_async_t` + `uv_async_send`, libuv's thread-safe wakeup; sends coalesce and are sequentially consistent, so post a flag and drain in the callback ([async docs](https://docs.libuv.org/en/v1.x/async.html)).

**Re-entrancy and teardown.** Never `uv_run` from a callback, call JS off the loop thread, `uv_close` twice, free a handle before `close_cb`, or reuse a request. Never let a JS exception unwind through an `extern(C)` callback: catch, print, set exit code, `uv_stop` if needed (legal in callbacks, effective after the iteration). Teardown: stop work, close JS-visible handles, free context then runtime (finalizers may close more), run until no closing handles, `uv_loop_close`; `UV_EBUSY` means something survived.

## 8. Prior art

- **`qjs` + `quickjs-libc`**: `js_std_loop` drains jobs then `os_poll`, repeat. Simplest proof of "drain, then block"; not libuv.
- **txiki.js** (saghul, MIT): QuickJS-NG + libuv, one runtime per worker. [`src/vm.c`](https://github.com/saghul/txiki.js/blob/master/src/vm.c): `uv_prepare` starts `uv_idle` while jobs or rejected promises are pending; `tjs__drain_microtasks` loops `JS_ExecutePendingJob` and reads the exception from the returned context on `-1`; timers call JS and close via `uv_close`. Validates the architecture, including that jobs alone do not keep the loop alive.
- **AWS LLRT** ([repo](https://github.com/awslabs/llrt)): Rust, `rquickjs` 0.14, Tokio — no libuv. Lambda-focused; README claims up to 10× faster startup and 2× lower cost (vendor benchmark), and labels itself experimental, not a Node replacement. Validates QuickJS in a foreign async host; the cost is a partial Node API and bundling constraints.
- **nginx njs**: nginx embeds **Bellard's** QuickJS as `js_engine qjs` (docs link bellard.org; changelog references `bellard/quickjs` commits); the native njs engine is deprecated since 1.0.0 ([engine docs](https://nginx.org/en/docs/njs/engine.html)). It pools contexts (`js_context_reuse`, default 128). Benchmark: njs 93,915 req/s at 42.64 µs; QuickJS reused 94,518 req/s at 43.07 µs (+0.6%); QuickJS with reuse 0, 5,363 req/s at 742.18 µs (−94.3%) ([blog](https://blog.nginx.org/blog/quickjs-engine-support-for-njs)). ~17× latency and 94% throughput loss for per-request contexts (including njs's per-request overhead, not just `JS_NewContext`). Pooled contexts retain globals and are assigned non-deterministically; state bleed is the price. Our long-lived context avoids this; per-request isolation must pool.

## 9. Pitfalls

**Leaks.** Every `JS_GetPropertyStr`, `JS_NewString`, `JS_NewCFunction`, `JS_AtomToValue`, and successful `JS_Call` returns owned. `JS_ToCString` needs `JS_FreeCString`; `JS_GetOwnPropertyNames` needs `JS_FreePropertyEnum`; atoms need `JS_FreeAtom`. `JS_SetPropertyStr` consumes its value and frees it even on failure, so freeing after is a double-free. Use `-DJS_DUMP_LEAKS`, `JS_ComputeMemoryUsage` deltas, ASan/LSan.

**Use-after-free.** `JSValueConst` is borrowed only for the call; dup to store. A `JS_ToCString` pointer dies at `JS_FreeCString` and allocation can invalidate it — copy immediately. Freeing a context with live values, a handle before `close_cb`, or touching JS globals in a runtime finalizer are UAFs.

**JSValue in GC memory.** A `JSValue` in a malloc'd struct behind `JS_SetOpaque` needs `gc_mark` calling `JS_MarkValue` and a finalizer calling `JS_FreeValueRT`; otherwise native-memory cycles are invisible. A `JSValue` field in a D GC object is worse: D knows nothing about QuickJS refcounts and QuickJS does not scan the D heap. Native structs holding JSValues must be malloc'd/arena'd and owned by a JS class.

**Exceptions across the boundary.** Never return `JS_EXCEPTION` without a pending exception; never leave one pending when returning a normal value; never use `JS_GetException` as a probe (it clears). Inside `extern(C)` callbacks, convert to host state and report; never propagate into libuv.

**Context-per-request cost.** The nginx numbers show creation dominates; pooling is the workaround. Measure before adding per-request contexts; for isolation, processes beat pooled contexts.

**CVE history.** NVD shows a steady stream; treat it as evidence about the engine class, not a risk score. Bellard: CVE-2020-22876 (buffer overflow), CVE-2023-48184 (async-function GC UAF), CVE-2025-46687/46688 (`JS_ReadString`/`JS_ReadBigInt` heap overflows, fixed 2025-04-26), CVE-2025-62490–62496 (several in `quickjs-libc`, plus TypedArray/BigInt/regexp issues). QuickJS-NG: CVE-2025-46687/88 through 0.9.0, CVE-2026-0821/0822 and 1144/1145 (typed arrays, Atomics, ≤0.11.0), CVE-2026-3979 (≤0.12.1 UAF). Most pre-date 0.12.1; v0.17.0 is current. CVE-2026-18329 is listed against njs's QuickJS engine for async access-control handling — scope unclear; do not read it as a core-engine bug.

## Rules we will adopt

1. Pin QuickJS-NG v0.17.0 at commit `6d46d07d04041b40f4f49eaa7fdebe44c314c699`; vendor it and fail the build if the commit differs.
2. Build `libqjs.a` with `BUILD_SHARED_LIBS=OFF` and `QJS_BUILD_LIBC=OFF`; do not link `quickjs-libc`.
3. One `JSRuntime` and one `JSContext` per OS thread; never touch either from another thread.
4. Create runtime, set limits, then context; free contexts before the runtime, values before their context.
5. Treat every `JSValue` as owned unless it is `JSValueConst`; dup on store, free on release, use `JS_CHECK_JSVALUE` in debug.
6. Wrap owned values in a scope guard; every `extern(C)` callback is `nothrow @nogc`; no D exception crosses it.
7. Return `JS_EXCEPTION` only after `JS_Throw*`; retrieve and clear with `JS_GetException` at every call site; use `JS_HasException` to peek.
8. Never store a `JSValue` in D GC memory; native JSValues live in `js_malloc_rt`'d structs with `gc_mark` and a finalizer.
9. Register class IDs once per runtime, validate with `JS_GetOpaque2`, free native resources only in finalizers or `uv_close_cb`.
10. Own module resolution: implement normalize/loader, cache by normalized name, return the `JSModuleDef`, free the `JSValue` wrapper.
11. Drain `JS_ExecutePendingJob` after every JS entry and before blocking; treat `-1` as fatal, reading the exception from the returned context.
12. Keep a `uv_idle`/`uv_prepare` handle active while `JS_IsJobPending` so microtasks keep the loop alive.
13. Never `uv_run` from a callback, free a handle before `uv_close_cb`, or reuse a request after its callback.
14. Set memory/stack limits explicitly, call `JS_UpdateStackTop` after any thread change, treat OOM as fatal.
15. Install an interrupt handler with a `uv_hrtime` deadline; keep it allocation-free, accept native calls are uninterruptible, discard the runtime after an interrupt.
16. Never run untrusted JS in-process; isolation means a separate process with OS sandboxing and resource limits.
17. Leave `JS_SetCanBlock` false on the main runtime; allow `Atomics.wait` only in worker runtimes with their own loops.
18. Run ASan/LSan plus `JS_DUMP_LEAKS` in CI, and review the CVE list when updating the pinned engine.
