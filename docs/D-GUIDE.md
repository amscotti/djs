# Working with D — a guide for the DJS codebase

**Audience:** systems programmers who know C/C++/Zig/Rust and are new to D. This is the house style for DJS, not a general D tutorial. It is deliberately conservative: we use the C-like, `@nogc`-friendly subset of D at the engine boundary, and ordinary D elsewhere.

## 1. Toolchain and project shape

- **Compiler:** LDC 1.36.0 (LLVM). Use `ldc2`, not `dmd`, for release builds.
- **Build:** DUB. `dub build --build=release`, `dub test`, `dub run -- <args>`.
- **Layout:** `src/djs/…` with one module per concern; `module djs.runtime;` mirrors the path. `source/app.d` is a convention, not a requirement; DJS uses `src/djs/main.d`.
- **Pins:** `dub.selections.json` is committed. Do not let a build silently resolve a different dependency; DJS has no third-party D dependencies in v0.1, and that is intentional.
- **Build types:** `debug` (asserts, contracts, bounds checks), `release` (optimized; asserts and contracts off, but `@safe` bounds checks still fire unless you pass `--boundscheck=off`), `release-debug` (optimized with symbols; use this for profiling). `unittest` is its own build type via `dub test`. DJS does not ship with `--boundscheck=off`; a safety check is cheaper than a memory bug. **Read §2 "Current posture" before relying on that sentence** — LDC only keeps bounds checks in `@safe` functions, and the engine layer is `@system`.

Minimal `dub.json` shape:

```json
{
  "name": "djs",
  "targetType": "executable",
  "targetName": "djs",
  "mainSourceFile": "src/djs/main.d",
  "sourcePaths": ["src"],
  "importPaths": ["src"],
  "libs": ["qjs", "uv", "m", "dl", "pthread"],
  "lflags": ["-L$PACKAGE_DIR/vendor/quickjs-ng/build"],
  "extraDependencyFiles": ["vendor/quickjs-ng/build/libqjs.a"],
  "dflags": ["-O3"],
  "buildTypes": {
    "release": { "buildOptions": ["releaseMode", "optimize", "inline"] }
  }
}
```

`extraDependencyFiles` is not optional: DUB does not notice a rebuilt `libqjs.a` and will happily link a stale archive. It also does not track C versions — pin QuickJS by tag and commit and verify it in `bootstrap.sh`. `systemDependencies` in `dub.json` is documentation only.

`dub test` prefers a configuration named `unittest` when one exists. DJS uses `src/djs/main.d` for the executable and `tests/ut_main.d` (an empty `main`) for the test runner, so druntime executes every `unittest` block in every linked module.

## 2. The attribute ladder

D's function attributes are the contract. Order them consistently:

```d
@safe @nogc nothrow pure
```

Read them as a ladder of guarantees:

| Attribute | Guarantees | Cost / restriction |
|---|---|---|
| `@safe` | No pointer arithmetic, no unchecked casts, no uninitialized reads; memory safety checked by the compiler | Cannot do raw pointer work; use `@trusted` at audited boundaries |
| `@trusted` | You assert the function is safe; the compiler stops checking | Must be small, documented, and reviewed like C |
| `@system` | Default; anything goes | Keep it out of public APIs |
| `@nogc` | No GC allocation, transitively | No `new`, no array append, no allocating closures, many Phobos functions excluded |
| `nothrow` | Does not throw `Exception` (an `Error` can still be thrown) | Must handle failures explicitly or return codes |
| `pure` | No mutable global state; result depends only on arguments/immutable data; transitive | No I/O, no logging, no mutable statics, no calling impure functions |

**Rules**

- Put `@safe:` at module scope for pure-D modules; opt individual functions out with `@trusted`/`@system` only at the C boundary.
- Every `extern(C)` callback is `nothrow @nogc`. It may be `@system` because it receives raw pointers; keep the body a thin wrapper around a `@trusted` helper with a documented invariant.
- Mark a function `pure` only when it genuinely has no mutable global dependencies. `pure` is transitive: one impure call infects the caller.
- Prefer `pure @nogc nothrow` for leaf utilities (parsing, formatting into a caller buffer, path joins). This is the sweet spot for testable code.
- Do not chase `@nogc` into code that runs once at startup. `@nogc` is for the loop, the bindings, and per-request paths.

### Current posture (measured 2026-10)

The guide above is the target. The tree as it stands is narrower, and the difference is worth stating
so nobody plans around a safety net that is not there:

- `@nogc`/`nothrow`: **967 / 965 annotations**, and zero `new` expressions in `src/`. This part is
  real and is enforced by the compiler on every path that carries the attribute.
- `@safe`/`@trusted`: **37 / 27** (was 0 / 0). The pattern that got there is the one this guide
  asks for: convert the logic to `const(char)[]`, mark the allocator/C-string helpers `@trusted`
  with a one-line invariant, and let the tokenizer, path predicates and export-target checks be
  `@safe`. `cjsnames`, `path`, `pkgexports` and `esm` now follow it end to end.
- `pure`: **24** uses, mostly the leaf helpers (`isStart`, `isPart`, `isDigit`, `endsWithSlice`,
  `withinSlice`, `safeRelativeTargetSlice`, `skipString`, `skipRegex`, `fnv1a`).
- What is still `@system`: the QuickJS/libuv/OpenSSL bindings and the request structs that own raw
  file descriptors. That is the intended boundary, not a backlog item.

The consequence of `@system` is not stylistic: LDC keeps bounds checks only in `@safe` code, so
**`@system` release code runs unchecked**. Measured cost of checks in a runtime-bounded loop: ~38%
(`docs/research/d-performance.md`). Every slice-based helper added here is therefore checked in
release, and the unchecked surface is now a small, documented set of `@trusted` helpers.

The rule for new code: write the logic against slices, put the pointer/allocator step in a named
`@trusted` helper with the invariant in a comment, and give the pure part a `@safe unittest`. Do not
mark a hot function `@safe` without measuring it: in `-release` that *adds* bounds checks, it does
not remove work.

### What `pure` actually means

```d
// Strongly pure: result depends only on arguments, no mutable globals.
pure int add(int a, int b) => a + b;

// Weakly pure: may mutate through its arguments, but no global state.
pure void fill(int[] dst, int v) { foreach (ref x; dst) x = v; }

// NOT pure: reads a mutable global / does I/O / logs.
int counter;
int next() { return ++counter; }        // impure
```

`pure` does **not** mean "no allocation" or "cannot throw". A `pure` function may allocate via the GC and may throw (the GC and exceptions are not treated as observable global state). If you need no allocation, write `pure @nogc`. It also does not mean "no side effects on arguments": D's *weakly pure* functions may mutate their parameters. And FFI can lie: `extern(C) pure int puts(const char*);` compiles and is callable from `pure` code even though it writes to stdout. Never cite `pure` as a thread-safety or no-side-effect claim.

## 3. Memory: GC, `@nogc`, and the boundary

D's GC is a conservative, stop-the-world collector. It is fine for startup, CLI parsing, and tests. It is not fine inside a libuv callback or a QuickJS native function: a collection there can pause the loop and, worse, interact badly with re-entrancy.

**Rules**

1. **Hot paths are `@nogc`.** The loop, timers, fs callbacks, module loader, and every JS-callable function.
2. **Use `core.stdc.stdlib`** (`malloc`, `calloc`, `realloc`, `free`) and `core.stdc.string` (`memcpy`, `memset`, `strlen`) for boundary allocations. Check every allocation; return `null`/error, don't throw.
3. **Use `scope(exit)`** for cleanup in D code. It compiles to deterministic cleanup, works with `@nogc`, and is clearer than nested `if` cleanup.
4. **Never store a `JSValue` in GC memory.** QuickJS values are refcounted C structs; the D GC cannot see or free them. Use stack `ScopedValue`, C-allocated tables, or runtime-owned arrays allocated with `malloc`.
5. **Do not call `GC.disable()` globally.** It breaks libraries and hides leaks. Keep the GC enabled but idle on hot paths; measure allocations in tests.
6. **Prefer structs to classes** for values and handles. Classes allocate, carry a vtable, and are GC-managed. Use `final class` only where polymorphism is genuinely needed, and never in the loop.
7. **Slices do not own memory.** A slice returned from a stack array is dangling. Return a caller-provided buffer, or allocate and document ownership.
8. **`string` is `immutable(char)[]`.** Do not `cast(char[])` and mutate it. For byte buffers use `ubyte[]`; for C strings use `const(char)*` and `JS_ToCStringLen`.

Exceptions are a cold-path tool. `@nogc` code cannot `throw new Exception` unless `-preview=dip1008` is enabled, and depending on a preview flag for your error strategy is a smell. In the loop and bindings, return status codes or a `Result`-style struct; reserve exceptions for startup and programmer errors.

`betterC` (`-betterC`) removes the D runtime and GC entirely. It is tempting for a runtime host, but it also removes classes, exceptions, associative arrays, dynamic arrays, built-in threading, and module constructors, and it makes the ordinary D code in this project much harder to write. **DJS does not use `betterC`.** We get the same effect where it matters with `@nogc` + `nothrow` + explicit allocators, and keep normal D for the rest.

## 4. C interop

D's C interop is the reason this project exists. Keep it boring.

```d
// Opaque C types: declare the name, never a truncated mirror.
struct uv_loop_t;
struct uv_timer_t;
struct uv_handle_t;

// libuv exposes size and accessor APIs precisely so hosts do not mirror its
// structs (uv_timer_t is 152 bytes on x86_64; a {void* data;} mirror is 8).
extern(C) size_t uv_loop_size() nothrow @nogc;
extern(C) size_t uv_handle_size(int type) nothrow @nogc;
extern(C) void*  uv_handle_get_data(const uv_handle_t*) nothrow @nogc;
extern(C) void   uv_handle_set_data(uv_handle_t*, void*) nothrow @nogc;

// C callback type: no D exceptions, no GC.
extern(C) alias uv_timer_cb = void function(uv_timer_t*) nothrow @nogc;

extern(C) int  uv_loop_init(uv_loop_t*) nothrow @nogc;
extern(C) int  uv_timer_init(uv_loop_t*, uv_timer_t*) nothrow @nogc;
extern(C) int  uv_timer_start(uv_timer_t*, uv_timer_cb, ulong timeout, ulong repeat) nothrow @nogc;
```

Allocate with the size API, never `uv_timer_t.sizeof`:

```d
uv_loop_t* loop = cast(uv_loop_t*) malloc(uv_loop_size());
uv_timer_t* timer = cast(uv_timer_t*) malloc(uv_handle_size(UV_TIMER));
uv_handle_set_data(cast(uv_handle_t*) timer, state);
```

**Rules**

- **Never declare a truncated C struct mirror.** The field offsets may be right and the size still catastrophic: `uv_timer_t` is 152 bytes, `uv_fs_t` 440, `uv_loop_t` 848 on x86_64. A mirror with one field is 8 bytes; `uv_timer_init` writes 144 bytes past it. Use opaque types plus libuv's `uv_loop_size`, `uv_handle_size`, `uv_req_size` and the `uv_*_get_data`/`uv_*_set_data`, `uv_fs_get_result/path/ptr/statbuf` accessors — that is what they exist for. If you must mirror a struct, mirror the full layout and assert every size/offset per platform.
- Add `static assert` for every size/offset you do rely on:
  ```d
  static assert(JSValue.sizeof == 16);
  static assert(JSValue.alignof == 8);
  ```
  Platform differences are real: libuv's `uv_buf_t` is `{ char* base; size_t len; }` on Unix but `{ ULONG len; char* base; }` on Windows. One shared declaration is wrong on one platform; per-platform `static assert`s catch it at compile time.
- C functions are `nothrow @nogc` in D declarations. If the C function can fail, check its return code.
- Callbacks are `extern(C) nothrow @nogc`. The normal failure path is a status return; a `catch (Throwable)` at the outermost frame is only a net for `Error` (assert/bounds/null), and its action is print + exit 70, not "convert and continue". **Never let a D exception unwind into C.**
- Do not pass D delegates to C. A D delegate is a two-word `{context, function}` pair; C expects one function pointer. Use a plain function pointer plus an opaque `void*` context, or QuickJS's `JS_NewCClosure` (opaque + finalizer). Linkage is part of the function type: both the alias and the function must be `extern(C)`. A capturing lambda is a `delegate` and will not convert; a default `extern(D)` function will not match an `extern(C)` pointer either.
  ```d
  extern(C) alias uv_timer_cb = void function(uv_timer_t*) nothrow @nogc;
  private extern(C) void onTimer(uv_timer_t* h) nothrow @nogc { /* ... */ }
  ```
- Do not pass GC-allocated memory to C for storage beyond the call. C will outlive the GC's knowledge of it.
- For a static C library, add its directory to `lflags` and its name to `libs`; confirm the final link line with `dub build -v`. Add the archive to `extraDependencyFiles`, or DUB will report "is up to date" after the `.a` changes and link the stale one. Build C from `preBuildCommands` so a clean checkout is truly clean.

### The `@trusted` boundary, concretely

`@safe` code cannot call libc/libuv, so every entry point is a sandwich: `@trusted` conversion
in, `@safe` logic, `@trusted` syscall out. The three shapes used in this tree:

```d
// 1. JS value -> owned C string. Validate, then copy; the copy is what callers own.
private @trusted bool getPath(JSContext* ctx, JSValueConst val, char** dest) @nogc nothrow
{
    // string-ness, embedded-NUL rejection, length-bounded copy
}

// 2. C string -> slice. One strlen, and the returned slice is bounded by it.
private @trusted const(char)[] asSlice(const(char)* s) @nogc nothrow
{
    return s is null ? null : s[0 .. strlen(s)];
}

// 3. Syscall wrapper. Stays @system (the descriptor is the hazard), takes an
//    fd the caller already owns, checks every return value.
private @system int doRead(FsWork* w) @nogc nothrow { ... }
```

A request struct is the way to make an entry point `@safe` when it has more than one buffer:
construct it in the `@trusted` part (allocation + JS conversion), pass it by `ref` to `@safe`
helpers, and let `scope(exit)` release everything in one place — `jsReadFileSyncImpl` is the
worked example. Until a given entry point gets that treatment, its `@system` body is honest about
where the checks stop; do not label it `@safe` because the tests pass.

What is annotated today: `fs.getPath`/`copyBytes`/`copyRange`, `net.openSocket`/`adoptSocket`,
`path`'s four adapters, `pkgexports.safeRelativeTarget`, `cjsnames`' five helpers. Everything
else under `apis/` is `@system` by design.

## 5. Error handling

D has exceptions, but the C boundary does not, and `@nogc` cannot `throw new`. Use two tiers.

**Tier A — the loop, callbacks, and every JS-callable function.** No D exceptions. Work returns a status enum and fills a fixed-size error record; the `extern(C)` trampoline maps the status to a JS exception. There is no allocation in the failure path.

```d
enum Status { ok, invalidArg, notFound, ioError, outOfMemory }

struct ErrorInfo {
    Status status;
    char[256] msg;      // NUL-terminated, filled with memcpy/snprintf-free code
    size_t len;
}

private @nogc nothrow
Status readFileImpl(JSContext* ctx, int argc, JSValueConst* argv,
                    JSValue* result, ErrorInfo* err) {
    if (argc < 1) {
        err.status = Status.invalidArg;
        err.len = copyLiteral(err.msg, "path must be a string");
        return Status.invalidArg;
    }
    // ... uv_fs_* ...

    return Status.ok;
}

private @nogc nothrow
JSValue throwStatus(JSContext* ctx, const ErrorInfo* err) {
    // Never pass a user-controlled string as the format argument.
    return JS_ThrowTypeError(ctx, "%s", err.msg.ptr);
}

extern(C) nothrow @nogc
JSValue js_fs_read_file(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) {
    ErrorInfo err = void;
    JSValue result = JS_UNDEFINED;
    Status s;
    try {
        s = readFileImpl(ctx, argc, argv, &result, &err);
    } catch (Throwable) {
        // Last-resort net for Error (assert, bounds, null): the process is
        // broken. Do not convert it into a JS exception and continue.
        write(2, "djs: internal error\n", 20);
        exit(70);
    }
    if (s != Status.ok) return throwStatus(ctx, &err);
    return result;   // owned, transferred to the caller
}
```

**Tier B — setup, CLI parsing, module resolution, one-shot code.** Ordinary D exceptions are fine. Tier B is never called from inside a Tier A callback; if a callback needs module resolution, that resolver must itself be `@nogc nothrow` or use C allocation and status returns.

**Rules**

- `nothrow` functions return a status/`bool`/pointer; no exceptions.
- At the boundary, catch `Throwable` only as a net for `Error`; print and exit 70. Do not catch `Exception` and continue, and do not turn an `Error` into a JS exception.
- `JS_ThrowTypeError`/`JS_ThrowRangeError`/`JS_ThrowInternalError` return `JS_EXCEPTION`; declare the C functions `nothrow @nogc` and use them directly.
- **Format-string rule:** no user-controlled string may be the format argument. Always `JS_ThrowTypeError(ctx, "%s", msg)`; for non-NUL-terminated data use `"%.*s"` with an explicit `int` length. `JS_Throw*` is `printf`-style; a path or module specifier passed as the format is a crash and an information leak.
- Never `assert` for input validation in release builds. `-release` removes asserts and contracts; use explicit checks for anything security-relevant. `@safe` bounds checks still fire in `-release` (unless `--boundscheck=off`), but that protects memory, not API correctness.
- `scope(failure)` is the cleanup tool for partial construction; `scope(exit)` for unconditional cleanup.
- Do not enable `-preview=dip1008` to make `@nogc` throws work. The two-tier rule is simpler and keeps allocation out of the loop.

## 6. Ranges, templates, CTFE

- Use ranges and `std.algorithm` in ordinary code (path manipulation, parsing config). They are expressive and usually fine outside hot paths.
- In hot paths, prefer `foreach` over a slice; it compiles to a tight loop and allocates nothing.
- Many Phobos algorithms allocate or are not `@nogc`. Check the signature; if it is not `@nogc`, it does not belong in the loop.
- Use `static if` for platform differences and optional fields; keep it shallow.
- Use CTFE for tables that never change (MIME types, keyword sets), but watch compile time. `enum` is compile-time; `static immutable` is initialized once at runtime.
- Avoid `mixin` string code generation unless it removes real duplication; it is hard to debug.
- Templates are instantiated per type; keep them small and `@nogc`-compatible.

## 7. Style and naming

- Modules: lowercase, dot-separated, matching the path: `djs.bindings.quickjs`.
- Types: `PascalCase` (`JSRuntime`, `TimerHandle`).
- Functions and variables: `camelCase` (`readFile`, `loopThread`).
- Enum members: `camelCase`; compile-time constants: `camelCase` or `PascalCase` for acronym-like names, consistently within a module.
- Indent 4 spaces; max line length ~100; braces on the same line; one statement per line.
- Imports at the top, selective (`import core.stdc.stdlib : malloc, free;`), sorted.
- `public import` only when re-exporting is the point; otherwise import privately.
- Use `package(djs)` visibility for internals that must cross modules but are not public API.
- Comments explain *why* and invariants, not *what*. Every `@trusted` function has a comment stating the invariant it relies on.
- No phase/task identifiers in code, tests, or comments. CI greps for them.

## 8. Testing and tooling

- `unittest` blocks live next to the code they test. `dub test` builds with `-unittest` and runs them. Annotate blocks with the attributes under test (`@safe @nogc nothrow unittest`) so the compiler proves the guarantees, not just the behavior.
- Integration tests are JavaScript files under `tests/js/`, run by `scripts/integration.sh`, compared against `tests/golden/`.
- Differential tests run the same script under Node and DJS; normalize paths/timings; document intentional differences.
- Leak tests: expose memory counters, run N cycles, assert a bounded delta. Run Valgrind on a small script. LDC supports AddressSanitizer (`--fsanitize=address`) on Linux; pair it with `-g`. The D GC heap is not instrumented and conservative scanning can keep a dead object alive, so ASan finds C-side and stack bugs far more reliably than D-side use-after-free.
- `dfmt` and D-Scanner are separate DUB packages, not compiler features; neither is packaged for Ubuntu 24.04 here. Install them with `dub fetch` if you want local formatting/linting, but the build does not depend on them.
- **dfmt is deliberately not enforced.** dfmt 0.15.2 (the version `dub fetch` resolves) rewrites `scope(exit)` as `scope (exit)` and joins wrapped parameter lists, so adopting it would churn roughly 140 lines in `path.d` alone with no correctness gain. The house style is the D Style plus the conventions in §7; if dfmt is ever adopted, it needs `--space_after_keywords` kept at its default and a one-off formatting commit of its own.
- `dub build -v` to inspect the link line when a C symbol is missing.
- `dustmite` to reduce a failing input/test case before debugging.

## 9. Pitfalls that bite C/C++/Zig developers

1. **D exceptions through C is undefined behavior.** Catch `Throwable` at every `extern(C)` boundary.
2. **GC allocation in a callback** can pause the loop and re-enter the collector at the worst time. `@nogc`.
3. **`pure` is not "const-correct" and not "no allocation".** It is "no mutable global state". `pure` functions can mutate their arguments (weak purity) and can allocate GC memory.
4. **`@safe` is only as good as its `@trusted` holes.** Audit every `@trusted` function; keep them tiny.
5. **`-release` removes asserts and contracts.** Do not rely on them for validation or security.
6. **Module constructors (`static this`)** run before `main` in an unspecified order across modules. Avoid them; initialize explicitly in `Runtime.init`.
7. **`shared`/`__gshared`**: QuickJS contexts are not thread-safe. Do not touch a context from two threads, even with `shared` casts.
8. **Slices alias.** Passing a slice to a function that stores it is a lifetime bug unless the backing memory is owned and documented.
9. **`null` vs empty**: `arr is null` and `arr.length == 0` differ. Normalize at API boundaries.
10. **Integer widths:** use `size_t` for sizes, `ptrdiff_t` for differences, `int` for JS `int32`; do not mix silently.
11. **`extern(C++)` is not needed here.** QuickJS and libuv are C; using C++ interop adds mangling and template pain for no gain.
12. **D's `string` is immutable.** Build output in a `char[]`/`ubyte[]` buffer, then slice it; do not cast away immutability.
13. **Module-scope variables are thread-local.** `int counter;` at module scope is TLS: another thread sees its own zero-initialized copy. Use `__gshared` only with a documented owner and lock; never assume a plain global is shared.
14. **`nothrow` still permits `Error`.** It forbids `Exception`, not `Error` (assert failure, bounds error, null dereference). At a C boundary, catch `Throwable`; do not treat `nothrow` as "cannot fail".

## 10. Code review checklist

- [ ] Every `extern(C)` function is `nothrow @nogc`; every callback has a status path, and any `catch (Throwable)` is a print-and-exit-70 net, not a converter.
- [ ] Every `JSValue` has exactly one owner; dups/frees pair on every path; `ScopedValue` has `@disable this(this)` and the negative copy test.
- [ ] No `JSValue` stored in GC memory; no D GC pointer stored in QuickJS opaque data.
- [ ] Engine memory uses `js_malloc`/`js_free_rt`; D scratch uses `malloc`/`free`; the two never cross.
- [ ] No GC allocation on the loop/binding path; allocations checked.
- [ ] `pure` only where true; `@trusted` blocks are small and commented.
- [ ] No truncated C struct mirrors; libuv uses `uv_*_size` + accessors; `static assert`s cover what is mirrored.
- [ ] No user-controlled string is a `JS_Throw*` format argument.
- [ ] Callback registry entries are generation-checked, dup'd on register, freed exactly once, and freed before `JS_FreeRuntime`.
- [ ] Async fs writes own their bytes (v0.1 copies into a request buffer) or hold a dup'd value plus view offset/length; `uv_fs_req_cleanup` runs on every path.
- [ ] Errors become JS exceptions via status codes; `process.exit` is a request (`uv_stop`), never a runtime free inside a callback.
- [ ] Tests cover the failure path, not just the happy path; golden output updated deliberately.
- [ ] No phase/task references in code, tests, or comments.
- [ ] `dub build --build=release` and `dub test` are clean; `scripts/integration.sh` passes.
