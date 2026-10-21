# Idiomatic D in 2026: layout, attributes, C interop, GC policy

Companion: [`d-performance.md`](d-performance.md) — measured cost model (bounds checks,
exceptions, string building, dispatch) and the DJS audit against it.

Written 2026-10-20 against **LDC 1.36.0** (DMD frontend **2.106.1**), **DUB 1.36.0**, Ubuntu 24.04
x86_64, libuv 1.48. **[V]** marks claims compiled and run here; unverified points are flagged.

**Version caveat.** The frontend is late-2024; dlang.org documents a newer D than this compiler
accepts. Trust `ldc2 --preview=?` (`dip1000`, `dip1008`, `dip1021`, `in`, `nosharedaccess`,
`systemVariables`, `bitfields`, `fieldwise`, …) and compile before believing a doc page.

## 1. Project layout and DUB

A package is a directory with `dub.json` **or** `dub.sdl` — equivalent front-ends to one model. SDL
allows comments; JSON is easier to generate from scripts. Both are production-grade:
[vibe.d](https://github.com/vibe-d/vibe.d/blob/master/dub.sdl) and
[vibe-core](https://github.com/vibe-d/vibe-core/blob/master/dub.sdl) ship `dub.sdl`.

Layout: `src/app.d` (the only `main`), `src/djs/…` library modules, `src/djs/c/` bindings with one
module per C header, `src/djs/package.d` as a façade, `tests/ut_main.d` and `tests/js/`, `vendor/`
for pinned C. Module names must mirror the path. `source/` or `src/` is auto-detected only while
`sourcePaths` is unset, and `importPaths` is a separate setting
([build settings](https://dub.pm/dub-reference/build_settings)).

Configurations are the feature that earns DUB its keep: one recipe, three products.

```json
{
  "name": "djs", "targetType": "executable",
  "sourcePaths": ["src"], "importPaths": ["src"], "mainSourceFile": "src/app.d",
  "lflags": ["-L$PACKAGE_DIR/vendor/quickjs-ng/build"], "libs": ["quickjs", "uv"],
  "extraDependencyFiles": ["vendor/quickjs-ng/build/libquickjs.a"],
  "configurations": [
    { "name": "application", "targetType": "executable",    "mainSourceFile": "src/app.d" },
    { "name": "library",     "targetType": "staticLibrary", "excludedSourceFiles": ["src/app.d"] },
    { "name": "unittest",    "targetType": "executable",    "mainSourceFile": "tests/ut_main.d" }
  ]
}
```

`dub test` prefers a configuration named `unittest` when present **[V]**; otherwise the first library
configuration, then the first executable one ([dub(1)](https://dub.pm/cli-reference/dub)).

**Pinning.** Ranges (`~>1.0.4` = `>=1.0.4 <1.1.0`) live in the recipe; resolved versions live in
`dub.selections.json`, written by DUB and rewritten by `dub upgrade`. Verified content **[V]**:
`{"fileVersion": 1, "versions": {"msgpack-d": "1.0.5"}}`. Commit it. The official selections guide
page is a WIP stub (checked 2026-10-20), and path dependencies produce no selections entry at all
**[V]**. DUB knows nothing about C dependency versions — pin vendored C by tag and checksum.

Build modes: `--build=debug` (default) is `-debug -g`; `release` is `-release -O3 -enable-inlining`
(asserts and contracts off); `release-debug` adds `-g`; `release-nobounds` adds `--boundscheck=off`;
`unittest`/`unittest-cov` drive `dub test`. Exact release command **[V]**:
`ldc2 -c -release -enable-inlining -Hkeep-all-bodies -O3 -w --oq -Isrc src/app.d src/djs/….d`.
DUB compiles the package in one invocation, enabling cross-module inlining. But `-release` still
checks bounds in `@safe` code: an out-of-bounds `@safe` index threw `ArrayIndexError` here **[V]**.

## 2. Attributes and idioms

**`@safe` / `@trusted` / `@system`.** `@safe` is compiler-enforced: no out-of-bounds pointer
arithmetic, no `const`-discarding casts, no `@system` calls — it cannot call `printf` **[V]**. Policy:
a large `@safe` core plus a thin `@trusted` binding layer where each function states the invariant it
assumes. `@safe` constrains D code, not the C code you hand a pointer to
([memory-safe D](https://dlang.org/spec/memory-safe-d.html)).

**`@nogc`.** Transitive and compile-checked: `new int[4]` fails with ``cannot use `new` in `@nogc`
function`` **[V]**. It turns "this path does not allocate" into a build error. The `… :` block form
applies attributes to the rest of the scope, but they do not propagate into aggregates, so mark
methods individually ([attributes](https://dlang.org/spec/attribute.html)).

**`nothrow`.** Forbids `Exception`, permits `Error`
([functions](https://dlang.org/spec/function.html#nothrow-functions)): ``Error: `object.Exception`
is thrown but not caught`` and ``function `g` may throw but is marked as `nothrow` `` **[V]**.
`Error` means the process is broken (assert, bounds, null); never catch it to recover.

**`pure`.** A `pure` function cannot touch mutable globals and may only call pure functions; it may
still throw and allocate. What it does *not* buy, verified **[V]**: `pure void bump(int* p) { *p +=
1; }` mutates caller state (weak purity); a `__gshared` read is rejected but a pointer to that global
passed in is fine; and `extern(C) pure int puts(const char*);` compiles and is callable from `pure`
code — purity is unauditable across FFI. Use it for arithmetic, parsing and hashing helpers, never as
a thread-safety claim.

**`scope(exit)`.** Runs on every exit path including exceptions, verified by throwing through one
**[V]**; `scope(success)`/`scope(failure)` are the conditional forms. This is the `goto cleanup`
replacement and it works in `-betterC`.

**Ranges.** `empty`/`front`/`popFront` (+ optional `save`, `length`, `opIndex`) is the protocol
behind `foreach` and `std.algorithm`. In hot paths prefer `foreach` over a slice: lazy chains close
over lambdas and allocate. Custom `@nogc` struct ranges suit walking QuickJS property lists.

**Templates and CTFE.** `enum` makes a manifest constant, `static assert` makes an invariant a build
error, `static foreach` unrolls, `__traits` reflects. CTFE runs ordinary D at compile time with no
I/O and no C calls — `enum n = printf("boom");` is rejected as "cannot be interpreted at compile
time" **[V]**. Use it for opcode tables and layout proofs.

**Structs vs classes.** Default to `struct`: value semantics, stack/embed-friendly, `@nogc`, POD
compatible; a destructor or postblit makes it non-POD, so never pass it to C by value. A `class` is a
GC-allocated (or `scope`) reference type with a vtable; use it only for runtime polymorphism, and
mark leaves `final`.

**Errors.** `Exception` is recoverable, `Error` is not. Exceptions belong in cold paths, status codes
in hot ones. `@nogc` code cannot `throw new Exception` unless `-preview=dip1008` is on — the same code
fails without the flag and runs with it **[V]**; depending on a preview flag for your error strategy
is a smell.

**Contracts.** `in`/`out`/`do` and `invariant` document programmer errors
([contracts](https://dlang.org/spec/contracts.html)), and they vanish in `-release`: a function with
`in (x > 0)` returned `-1` in release and asserted in debug **[V]**. Contracts are never input
validation.

**Naming and modules.** [The D Style](https://dlang.org/dstyle.html): modules lowercase (`djs.c.uv`),
functions and variables `camelCase`, types `PascalCase`. One module per concern, C bindings isolated,
no import cycles — cycles involving module constructors abort at startup
([modules](https://dlang.org/spec/module.html#order_of_static_ctor)).

## 3. C interop for a runtime host

```d
module djs.c.uv;
struct uv_loop_s;                  // opaque: declared, never defined
alias uv_loop_t = uv_loop_s;

extern(C) nothrow @nogc:
uint         uv_loop_init(uv_loop_t* loop);
int          uv_run(uv_loop_t* loop, int mode);
const(char)* uv_strerror(int err);
```

Copy names verbatim: `snake_case` is correct because bindings must be greppable against `uv.h`. The
declarations above compile and link against libuv **[V]**.

**Layout guards.** Every mirrored C struct needs compile-time asserts:

```d
struct uv_buf_t { char* base; size_t len; }          // uv/unix.h
static assert(uv_buf_t.base.offsetof == 0);
static assert(uv_buf_t.len.offsetof  == size_t.sizeof);
static assert(uv_buf_t.sizeof        == 2 * size_t.sizeof);
```

Those compiled here **[V]**. The example is deliberate: libuv's `uv_buf_t` is
`{ char* base; size_t len; }` in `uv/unix.h` but `{ ULONG len; char* base; }` in `uv/win.h`
(installed 1.48 headers **[V]**) — one portable declaration is wrong on one platform, and only a
`static assert` says so. D has no bitfields; use shifts/masks ([interfacing to
C](https://dlang.org/spec/interfaceToC.html)).

**Function pointers vs delegates.** Two distinct types: `void function(int)` versus
`void delegate(int)` (pointer plus context). Neither converts to the other, and linkage is part of
the type. A capturing lambda fails with ``cannot pass argument '__lambda2' of type 'void
delegate(int)' to parameter 'extern (C) void function(int) nothrow @nogc cb'`` **[V]**, and passing
`&onCb` — a default `extern(D)` function — fails against the same parameter **[V]**. Declare **both**
the alias and the function `extern(C)`:

```d
extern(C) alias uv_timer_cb = void function(uv_timer_t* h) nothrow @nogc;

private extern(C) void onTimer(uv_timer_t* h) nothrow @nogc {
    auto ctx = cast(Ctx*) h.data;      // libuv's per-handle void* slot
    if (ctx is null) return;
    ctx.onTick();
}
```

**Userdata.** libuv gives every handle and the loop a `void* data` field (`uv_handle_s`,
`uv_loop_s` in 1.48 **[V]**); QuickJS gives `JS_SetOpaque`. That slot holds the D context, but the
target must outlive the C object and be reachable by its owner: allocate it with `malloc`/an arena
and free it in the close callback, or keep a global root. A pointer held only in C-allocated memory
is not a GC root ([GC](https://dlang.org/spec/garbage.html#gc_foreign_obj)).

**Static C libraries.** `libs` becomes `-l<name>`, `lflags` passes through; verified link line **[V]**:
`ldc2 -of… dubprobe.o -L--no-as-needed -L-L…/vendor/clib -L-lclib`. Two traps:
`systemDependencies` is documentation only ([build
settings](https://dub.pm/dub-reference/build_settings)); and DUB does not notice a rebuilt `.a` —
after `touch libclib.a`, `dub build --build=release` said "is up to date" and linked the stale
archive; adding it to `extraDependencyFiles` forced a relink **[V]**. Build C from
`preBuildCommands`, list archives in `extraDependencyFiles`, and declare C globals as
`extern(C) extern __gshared int foo;`.

## 4. GC strategy for a latency-sensitive host

The default collector is conservative and stop-the-world: it halts threads, scans static data, each
thread's stack and registers, TLS and registered roots, then marks transitively; pause time is
unbounded in principle ([GC](https://dlang.org/spec/garbage.html)). Knobs are at
`--DRT-gcopt=help`: `disable`, `profile:0|1|2`, `gc:conservative|precise|manual`, `parallel:N`
(default 99), pool sizing and `cleanup` **[V]**. `--DRT-gcopt=profile:1` prints an allocation summary
at exit — run it first when someone claims a GC problem.

Policy: keep the GC for startup, configuration and cold errors; keep the loop, bindings and every
per-event path `@nogc`. The JavaScript heap is QuickJS's; the D side holds handles, buffers and
callback contexts.

```d
struct Arena {                        // bump allocator over the C heap
    ubyte* base; size_t cap, used;
    static Arena create(size_t cap) @nogc nothrow { return Arena(cast(ubyte*) malloc(cap), cap, 0); }
    void* alloc(size_t n, size_t alignment = 16) @nogc nothrow {
        size_t off = (used + alignment - 1) & ~(alignment - 1);
        if (off + n > cap) return null;
        used = off + n; return base + off;
    }
    void reset() @nogc nothrow { used = 0; }
    void destroy() @nogc nothrow { free(base); base = null; cap = used = 0; }
}
```

That compiles and runs `@nogc nothrow` **[V]**. Per-turn arenas that are `reset()` rather than freed
give Node-like "allocate freely, release at end of tick" behaviour.
`std.experimental.allocator` remains experimental in 2.106: `Mallocator.instance.allocate` works
under `@nogc`, but do not build architecture on it **[V]**.

**`betterC` trade-offs.** `-betterC` removes the runtime: no GC, and also no classes, associative
arrays, dynamic arrays, exceptions, built-in threading, `synchronized` or static module constructors;
templates, CTFE, `scope(exit)`, RAII and slices of static arrays remain
([better C](https://dlang.org/spec/betterc.html)). A struct-and-`printf` program builds and runs
**[V]**. For a libuv host it is the wrong global choice — you want `core.thread` and cold-path
exceptions. Reserve it for small leaf libraries shipped as runtime-free `.a` files.

**Avoid in or near the loop:** `new`, `~=` append, associative-array lookups, capturing closures,
`format`/`writefln`/`to!string`, `std.json`, exceptions as control flow, `lazy` parameters.

## 5. Testing and tooling

`unittest { … }` blocks are module members: they see private symbols and run before `main` in lexical
order ([unit tests](https://dlang.org/spec/unittest.html)). Assertions are the API. Annotate each
block with the attributes under test (`@safe @nogc nothrow unittest`) so the compiler proves them.
`dub test` builds with `-unittest`, prefers the `unittest` configuration and runs the result **[V]**;
the runner is druntime, so an empty `main` in `tests/ut_main.d` executes every block in every linked
module.

Integration tests stay outside DUB: build `--build=release`, run the binary on `.js` fixtures, diff
stdout/stderr/exit code against golden files; `dub run -- args` forwards arguments.

`dfmt` ([repo](https://github.com/dlang-community/dfmt)) and D-Scanner
([repo](https://github.com/dlang-community/D-Scanner)) are separate DUB packages, not compiler
features; `dub lint` runs D-Scanner. Neither is packaged for Ubuntu 24.04 here (`apt-cache policy`
empty **[V]**), so CI must `dub fetch` them; I did not run them, so their flags are unverified.

LDC flags: `--fsanitize=address` works with druntime and caught a deliberate one-past-the-end write
with a symbolized stack **[V]**; pair it with `-g`. Also `-O3`, `--enable-inlining`,
`--boundscheck=on|safeonly|off`, `--checkaction=halt|context`, `-flto`, `-mcpu=native`.
The GC heap is not instrumented and conservative scanning can keep a dead object alive, so ASan finds
C-side and stack bugs far more reliably than D-side use-after-free.

## 6. Pitfalls that bite C/C++/Zig developers

1. **GC allocation in a C callback.** Compiles, usually works, latently wrong: the object survives
   only while a pointer is reachable from a scanned root, and C memory is not scanned. I could not
   make a small test collect such an object — the finalizer ran only at exit **[V]** — so the bug
   hides until production.
2. **Exceptions across the C boundary.** Not diagnosed. An `extern(C)` function that throws, called
   from a C `main`, linked fine and aborted at runtime with `uncaught exception reached top of stack`
   after unwinding through the C frame **[V]**. Wrap every callback body in `try/catch (Throwable)`;
   `nothrow` is documentation, not enforcement, across FFI.
3. **`pure` misuse.** Weak purity and the FFI lie (§2). Never cite `pure` as thread safety.
4. **Module-level variables are thread-local.** `int counter;` is TLS: a second thread read `0`, wrote
   `99`, and main still read `5`; `__gshared` was shared **[V]**.
5. **`shared` is a qualifier, not a lock.** It makes unqualified access a compile error, not access
   atomic; `synchronized` is a mutex and `std.concurrency` is usually the better default. And
   `new Thread(&fn)` only constructs — without `t.start()` the body never runs **[V]**.
6. **Module constructors.** `shared static this()` runs once before `main`, `static this()` per
   thread; order follows the import graph and a constructor cycle aborts at startup. Verified order:
   shared ctor, thread ctor, `main` **[V]**. Absent in `-betterC`; do no work in them.
7. **Contracts and asserts vanish in `-release`** (§2). Every check protecting untrusted input must
   survive release.

## 7. Rules we will adopt

1. Pin compiler, DUB, libuv, QuickJS-NG tag and build flags in one file; CI verifies them.
2. `src/app.d` holds the only `main`; a `library` configuration must build without one.
3. All C declarations live under `src/djs/c/`, one module per header, in an
   `extern(C) nothrow @nogc` block, names copied verbatim.
4. Every callback is `extern(C) nothrow @nogc`, takes `void*` userdata, and is a plain function —
   no delegates, no closures, no captures.
5. Every callback body wraps its work in `try/catch (Throwable)` and converts failure to a JS
   exception or a return code; nothing unwinds into C.
6. Every mirrored C struct carries `static assert`s on `offsetof` and `sizeof`, per platform where
   the header differs.
7. The loop, bindings and per-event paths are `@nogc`; the build fails if an allocation creeps in.
8. Per-turn state comes from an arena that is reset, not freed; long-lived state is `malloc`-owned
   or rooted where the GC can see it.
9. D code is `@safe` by default; `@trusted` appears only in the binding layer, one function at a
   time, each with a comment stating its invariant.
10. No `pure` on anything touching FFI or mutable indirections; never cite `pure` as thread safety.
11. Validate every byte from JavaScript, the network or the filesystem at runtime; contracts and
    `assert` are for programmer errors only.
12. Module-scope mutable state is thread-local unless declared `__gshared`, and each `__gshared`
    names its owner and its lock; module constructors do no work.
13. `dub.selections.json` is committed, no floating `*` versions, vendored C pinned by tag and
    checksum.
14. CI runs `dub build --build=release`, `dub test`, the JS golden suite, and one ASan build.

## Sources

Spec: [functions](https://dlang.org/spec/function.html) ·
[attributes](https://dlang.org/spec/attribute.html) ·
[GC](https://dlang.org/spec/garbage.html) ·
[interfacing to C](https://dlang.org/spec/interfaceToC.html) ·
[better C](https://dlang.org/spec/betterc.html) ·
[modules](https://dlang.org/spec/module.html) ·
[contracts](https://dlang.org/spec/contracts.html) ·
[unit tests](https://dlang.org/spec/unittest.html) ·
[memory-safe D](https://dlang.org/spec/memory-safe-d.html) ·
[errors](https://dlang.org/spec/errors.html) ·
[D Style](https://dlang.org/dstyle.html).
DUB: [recipe](https://dub.pm/dub-guide/recipe) ·
[build settings](https://dub.pm/dub-reference/build_settings) ·
[build types](https://dub.pm/dub-reference/buildtypes) ·
[configurations](https://dub.pm/dub-reference/configurations) ·
[dub(1)](https://dub.pm/cli-reference/dub).

**Uncertainty log.** (a) The `dub.selections.json` guide page is a WIP stub; its semantics here come
from the CLI reference plus observed behaviour. (b) `dfmt` and D-Scanner were not run. (c) ASan
leak-checking against the conservative GC was not measured. (d) Docs newer than frontend 2.106.1 may
not compile — confirm with `ldc2 --preview=?` and a build.
