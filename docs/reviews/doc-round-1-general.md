# Document review — Round 1, General

**Reviewer role:** general — correctness, clarity, completeness, internal consistency, and whether the plan can be executed as written.
**Date:** 2026-10-20
**Scope:** `BRIEF.md`, `docs/ARCHITECTURE.md`, `docs/D-GUIDE.md`, `docs/PLAN.md`, `docs/PINS.md`, checked against the repo and the pinned toolchain.
**Versions reviewed (sha256, first 16):** BRIEF `cfd5c2ecd3f7dafc`, ARCHITECTURE `e79da1e479171170`, D-GUIDE `de3849405b2d71e9`, PLAN `ee480ffd632c5d01`, PINS `ba37a2e1534f8b84`.

**Method.** Read all five documents; checked every cheap-to-verify claim against `vendor/quickjs-ng/quickjs.h` at commit `6d46d07d…` (v0.17.0), the installed libuv 1.48, and LDC 1.36.0 / DUB 1.36.0; compiled probes for the D claims and built the documented `dub.json` verbatim. Probe sources were kept in a scratch directory during the review.

**What checks out** (so the fixer does not re-litigate it): the `JSValue` 16-byte layout and the ownership paraphrase match `quickjs.h` exactly on x86_64 (§6.1/§6.2); `JS_EnqueueJob` **is** exported (header line 1247), so PLAN §5's open question is already answered; `JS_NewCClosure` exists with the advertised shape; the CVE cited in §11 is real (CVE-2026-37630, QuickJS-NG 0.12.1, `js_mapped_arguments_mark`); LDC 1.36.0 / DUB 1.36.0 / libuv 1.48.0 / Ninja 1.11.1 match `PINS.md`; `dub test` correctly excludes `mainSourceFile`, so the executable+test split works.

---

## G-01 — Critical — D-GUIDE §2, §3 (rules 1–2), §5; ARCHITECTURE §6.3

**What is wrong.** The mandated boundary pattern cannot compile. The guide requires every JS-callable function to be `nothrow @nogc`, and then gives a §5 template marked `@nogc nothrow` whose body catches a `Throwable` thrown by ordinary D code that does `throw new OutOfMemoryError(...)` (§3 rule 2 tells you to throw exactly that). `@nogc` is transitive and `throw new` is a GC allocation, so the guide's own example is rejected by the compiler. §3 rule 2 ("return `null`/error, don't throw") and §5 ("throw new OutOfMemoryError") also contradict each other as written.

**Evidence.**

```d
// D-GUIDE §5 shape
extern(C) int js_foo(int argc) @nogc nothrow {
    try { return fooImpl(argc); } catch (Throwable t) { return -1; }
}
int fooImpl(int argc) { if (argc < 0) throw new Exception("bad"); return argc; }
```

```
$ ldc2 -c gctest.d
gctest.d(3): Error: `@nogc` function `gctest.js_foo` cannot call non-@nogc function `gctest.fooImpl`

$ echo 'void f() @nogc nothrow { throw new Exception("x"); }' | ldc2 -c -
Error: cannot use `new` in `@nogc` function `dip.f`
```

The catch site itself is fine: `nothrow` + `try/catch (Throwable)` around a throwing callee compiles (verified). The throw site inside an `@nogc` callee is the problem.

**Fix.** Decide the tiering and write it as one rule in both documents:

- Tier A (loop, timers, fs completion, every `extern(C)` callback): `nothrow @nogc`, **no D exceptions at all** — failures are `int`/enum status plus a fixed-size `struct ErrorInfo` filled in place, converted at the boundary to a JS exception. This is what §3 rule 2 already says; delete the contradictory §5 example.
- Tier B (setup, CLI parsing, module resolution, one-shot code): ordinary D exceptions allowed, **not** `@nogc`, and never reachable from Tier A except through a `catch (Throwable)` wrapper that is itself allowed to allocate.
- Alternative: enable `-preview=dip1008` ("@nogc Throwable") and keep the current single-tier story. Verified: the full §5 pattern compiles unchanged with `ldc2 -preview=dip1008`, and LDC 1.36 supports the flag. Cost: a preview flag in the pins, and `@nogc` `throw` allocates outside the D GC, so a failed allocation inside a `@nogc` function has nowhere to go — document that as accepted.

Pick one, put the flag (if any) in `PINS.md` and the `dub.json` sample, and add a `unittest` that reproduces the chosen pattern so it cannot rot.

---

## G-02 — Critical — BRIEF "v0.1 scope" vs ARCHITECTURE §8.2 vs PLAN Phase 1/2

**What is wrong.** No document defines whether a `.js` file is a script, an ES module, or a CommonJS module, and the three documents assert incompatible rules. The result is that Phase 2's own definition of done cannot be satisfied without an unstated rule.

- BRIEF: "ESM `import`/`export` for local files, plus CommonJS `require` for `.cjs` and local packages" → `.js` is ESM.
- ARCHITECTURE §8.2 step 1: "Resolve the specifier: relative/absolute; `.js`, `.cjs`, `.json`" → `.js` is require-able CJS.
- PLAN Phase 2 DoD: `./djs tests/js/esm_chain/main.js` must run as ESM **and** `require` must work for `.js`.
- PLAN Phase 2 goal/DoD: `./djs tests/js/cjs_cycle/main.cjs` → `.cjs` is CJS.
- PLAN Phase 1 DoD: `./djs tests/js/fs_read.js` runs as a plain script (no module wrapper).

No mention anywhere of `.mjs`, `package.json` `"type"`, `--input-type`, or how the entry file is classified.

**Evidence.** `grep -rn "\.mjs\|package.json" docs/*.md BRIEF.md` → only the CJS `main` lookup in ARCH §8.2 and PLAN Phase 2. The words "script" and "module" are never defined against each other.

**Fix.** Add a "module type resolution" table to ARCH §8 (and reference it from BRIEF and PLAN):

| Input | Rule |
|---|---|
| entry (`djs file.js`) | `.mjs` → ESM; `.cjs` → CJS; `.js` → ESM if nearest `package.json` has `"type":"module"`, else **script** (global eval) |
| `import` specifier | `.js`/`.mjs` → ESM; `.cjs` → CJS namespace with `default`; `.json` → JSON module |
| `require` specifier | `.cjs`/`.js` → CJS wrapper; `.mjs` → throw `ERR_REQUIRE_ESM`; `.json` → parsed value |
| no extension | probe `.js`, `.json`, then directory `package.json` `main` |

Then change BRIEF's "CommonJS for `.cjs`" to match, and make Phase 2's tests use `.mjs` for the ESM chain if `.js` is to stay CJS.

---

## G-03 — Important — ARCHITECTURE §8.1

**What is wrong.** The `JS_SetModuleLoaderFunc2` description is wrong in three ways, and the promised import-attribute behavior has no API.

`quickjs.h` (v0.17.0, lines 1196–1236):

```c
typedef char *JSModuleNormalizeFunc2(JSContext *ctx, const char *module_base_name,
                                     const char *module_name, JSValueConst attributes, void *opaque);
typedef JSModuleDef *JSModuleLoaderFunc2(JSContext *ctx, const char *module_name,
                                         void *opaque, JSValueConst attributes);
JS_EXTERN void JS_SetModuleLoaderFunc2(JSRuntime *rt, JSModuleNormalizeFunc *module_normalize,
                                       JSModuleLoaderFunc2 *module_loader,
                                       JSModuleCheckSupportedImportAttributes *module_check_attrs,
                                       void *opaque);
JS_EXTERN void JS_SetModuleNormalizeFunc2(JSRuntime *rt, JSModuleNormalizeFunc2 *module_normalize);
JS_EXTERN JSValue JS_GetImportMeta(JSContext *ctx, JSModuleDef *m);
```

1. It takes **five** arguments, not the three the doc implies; the loader typedef receives `JSValueConst attributes`.
2. The 3-arg `JS_SetModuleLoaderFunc` is a separate registration API, not "a compatibility wrapper" — calling it does not give you attributes.
3. "Import attributes are honored; unknown types raise a `TypeError`" requires the `module_check_attrs` callback (plus `JS_SetModuleNormalizeFunc2` after registration); the doc never mentions either.
4. "set `import.meta` (`url`, `filename`, `dirname`)" has no named API; it is `JS_GetImportMeta(ctx, m)` on the freshly compiled `JSModuleDef`.

**Fix.** Replace §8.1's registration bullet with the exact 5-arg call and the typedef shapes above; name `JS_GetImportMeta`; state the normalize contract ("returns a `js_malloc`'d string; the engine frees it with `js_free`; `NULL` sets an exception") — see G-04.

---

## G-04 — Important — ARCHITECTURE §6.3 (and the D-GUIDE checklist)

**What is wrong.** "`js_malloc` is internal; prefer `malloc`" is false for the pinned engine, and the one place where the distinction is mandatory is the module normalizer.

**Evidence.** `quickjs.h` declares `js_malloc`, `js_free`, `js_realloc`, `js_mallocz`, `js_malloc_usable_size`, `js_malloc_rt`, `js_free_rt` as `JS_EXTERN` (public ABI), lines 575–586. And line 1196: "return the module specifier (**allocated with `js_malloc()`**) or NULL if exception". Following the doc's "prefer `malloc`" rule in the normalizer produces memory that QuickJS frees with `js_free`. That happens to work with the default allocator (both bottom out in `malloc`), which is exactly why it will pass review and then break the moment `JS_NewRuntime2` installs a `JSMallocFunctions` table — the natural way to account QuickJS heap in the leak tests that ARCH §13 and PLAN Phase 4 require.

**Fix.** State the allocator pairing as a rule: *engine-owned memory is allocated with `js_malloc(ctx,…)`/`js_malloc_rt(rt,…)` and freed with `js_free`/`js_free_rt`; D-side scratch uses `malloc`/`free`; never cross the two.* Add it to §6.2's ownership list and to the D-GUIDE §10 checklist, and delete the "js_malloc is internal" claim.

---

## G-05 — Important — ARCHITECTURE §6.4

**What is wrong.** The finalizer contract is misstated and the GC-marking obligation is missing.

`quickjs.h` line 673: `typedef void JSClassFinalizer(JSRuntime *rt, JSValueConst val);` — the finalizer receives a **`JSRuntime*`**, not a `JSContext*`. The doc says "It receives the `JSValue`, so retrieve the opaque pointer and free it", which omits the runtime and therefore the constraint that no context-taking API may be called there (`JS_GetOpaque` is fine; `JS_GetOpaque2`, `JS_ThrowTypeError`, `JS_ToCString` are not). It must free with `js_free_rt`/`JS_FreeValueRT`.

Also missing: if an opaque struct holds `JSValue`s (likely for timer/fs state), `JSClassDef.gc_mark` must call `JS_MarkValue` for each (header lines 674–675), or native-held object graphs are invisible to the cycle collector and leak. The research memo already has this (`docs/research/quickjs-embedding.md:101`); the architecture does not.

**Fix.** Correct the signature; add a five-line native-object checklist: allocate with `js_malloc_rt` (or `malloc` if never handed to QuickJS), finalizer `(JSRuntime*, JSValueConst)`, free with `js_free_rt`, `gc_mark` for any held `JSValue`, `JS_GetOpaque2` for the type check on the JS-facing path.

---

## G-06 — Important — ARCHITECTURE §7 (and §5 exit rule)

**What is wrong.** The job pump has no error path and the process-exit predicate is not implementable as stated.

"call `JS_ExecutePendingJob(rt, &ctx)` in a loop until it returns 0" — the function returns `-1` when a job threw, with the exception pending in `*pctx`, which may be a *different* context than the one passed in. As written, a rejected promise reaction either spins the loop or silently drops the exception, which is precisely what §10 promises to report.

Second, §5's "exits when the loop has no referenced handles and no pending jobs" needs a predicate. After `uv_run(loop, UV_RUN_ONCE)` returns 0 there may still be pending jobs (`JS_IsJobPending(rt)`), and a job queued at the tail of the last callback must still run. PLAN §5's open question ("do we need an idle/prepare handle to avoid a busy loop when only jobs are pending?") is answered by this: no. With no active handles `uv_run` returns 0 immediately, so the correct predicate is explicit, not structural.

**Fix.** Specify:

```
for (;;) { r = JS_ExecutePendingJob(rt, &ctx);   // re-read ctx each iteration
           if (r == 0) break;
           if (r < 0) { reportUncaught(ctx); break; } }
...
while (uv_run(loop, UV_RUN_ONCE) != 0 || JS_IsJobPending(rt)) { drainJobs(); }
```

and close the PLAN open question with that answer.

---

## G-07 — Important — ARCHITECTURE §9 and §10

**What is wrong.** The callback registry — the mechanism the entire async API rests on — is one sentence: "with completion delivered through a native callback registry". Unspecified: how `callbackId` maps to a `JSValue` and when it is dup'd/freed; what happens when a completion arrives after `process.exit` or during teardown; how an exception thrown inside a completion callback is surfaced (there is no JS caller to return `JS_EXCEPTION` to); what happens when `clearTimeout`/abort races an in-flight uv request (`uv_cancel` is best-effort — the callback still runs); and what `this`/argument shape the callback receives.

This is where the refcount and use-after-free bugs will be (ARCH §14 says so itself), and §10 covers only top-level evaluation.

**Fix.** Add a subsection to §9 specifying: registry keyed by `uint64_t` with entries `{JSValue fn; uint32_t state;}` allocated by `malloc`; `JS_DupValue` on register, `JS_FreeValue` exactly once on fire / cancel / free-all; completions call `JS_Call(ctx, fn, JS_UNDEFINED, …)` and route a thrown exception through the uncaught policy (stderr + exit 1) because there is no caller; cancelled-but-in-flight requests mark the entry dead and free it in the completion; shutdown order is explicit — cancel/close handles → run the loop until `uv_close` callbacks fire → free the registry (freeing every `JSValue`) → `JS_FreeContext` → `JS_FreeRuntime` → `uv_loop_close`.

---

## G-08 — Important — ARCHITECTURE §10

**What is wrong.** "Unhandled promise rejection: … print the reason and stack **at loop drain**, exit 1" diverges from Node in a way that will fail the project's own differential tests and hide a real bug class.

Node (`--unhandled-rejections=throw`, default since v15) decides at the end of the microtask checkpoint for the current tick, before the next macrotask. Under "at loop drain":

```js
const p = Promise.reject(new Error('x'));
setTimeout(() => p.catch(() => {}), 10);
```

prints a warning and exits 0 under DJS, crashes with exit 1 under Node. Conversely, a rejection created in a timer callback would be reported by Node on that same tick and by DJS only after the loop empties, changing ordering in golden stderr.

**Fix.** Track rejections with `JS_SetHostPromiseRejectionTracker`, and evaluate "still unhandled?" at the end of every job-queue drain (not at loop exit); report + exit 1 there. State explicitly that `--unhandled-rejections=warn|none` is not in v0.1. Add the two differential cases (handled in the same tick; handled one macrotask later) to Phase 3.

---

## G-09 — Important — D-GUIDE §1 (`dub.json` sample)

**What is wrong.** The sample build definition does not link on the pinned toolchain.

```
$ dub build            # sample copied verbatim, paths adjusted only
Error: The LLVMgold.so plugin (needed for LTO) was not found. You can specify its path with -flto-binary=<file>.
Error /usr/bin/ldc2 failed with exit code 1.
```

`"dflags-ldc": ["-O3", "-flto=full"]` requires the LLVM gold plugin (or `lld`), which is not part of the documented Ubuntu install (`apt install ldc dub libuv1-dev cmake ninja-build`). Removing `-flto=full` links and runs (verified). Everything else in the sample is correct — DUB prefixes `lflags` entries with `-L`, so `-Lvendor/quickjs-ng/build` and `-lqjs` both land correctly on the link line (verified with `dub build -v`); the only other gap is that the sample has no `extraDependencyFiles`, so rebuilding `libqjs.a` will not trigger a relink.

**Fix.** Drop `-flto=full` from the default flags (or move it to an opt-in `release-lto` build type with a note that it needs `LLVMgold.so`/`lld`), add `"extraDependencyFiles": ["vendor/quickjs-ng/build/libqjs.a"]`, and add a sentence: "this snippet was built on the pinned toolchain before being committed" — the same discipline the plan asks of code.

---

## G-10 — Important — ARCHITECTURE §9 + BRIEF (console)

**What is wrong.** `console.log`'s output format is never specified, so the golden files and the Node differential tests have no oracle. The doc stops at `__djs.console.write(fd, string)` and "argument validation in JS". Node's `console.log` is `util.format` + `util.inspect`: `%s %d %i %f %j %o %O %%`, object depth, `[Circular *1]`, `Map(1) { … }`, `Error` (stack, not `{}`), `-0`, `NaN`, `undefined` vs `null`, boxed primitives, `console.log()` → `"\n"`. Every one of these is a differential-test failure unless the subset is written down.

**Fix.** Add a short "console" subsection to §9 with the v0.1 contract: primitives via `String(v)`; objects via a named `inspect` subset (depth 2, no colors, circular marker, `Error` → `stack`); which `%` specifiers are supported; and an explicit not-in-v0.1 list (`console.table/group/time`, `Symbol.for('nodejs.util.inspect.custom')`). Golden files are generated from that spec, not from Node, where the spec says "different".

---

## G-11 — Important — ARCHITECTURE §9 + BRIEF (timers)

**What is wrong.** The timer contract omits everything a Node differential test touches. `__djs.timer.start(delayMs, repeat, callbackId)` / `cancel(id)` says nothing about:

- return value: Node returns a `Timeout` **object** (`typeof setTimeout(f,1) === 'object'`, with `ref`/`unref`/`hasRef`/`refresh`), not an integer;
- delay clamping: `< 1` → 1 ms, `> 2^31-1` → 1 ms with a warning, non-numeric → 1 ms;
- ordering of equal deadlines (Node: insertion order, per-ms list);
- a timer callback that throws → uncaught exception, exit 1;
- `clearTimeout(undefined)` / double clear being no-ops.

**Fix.** Specify the return type and methods in §9 (recommend a prelude-created object `{ref, unref, hasRef, refresh, [Symbol.toPrimitive]}` mapping to the native id), the clamp rule, FIFO ordering, and add the three ordering cases to `tests/js/timers_order.js` in Phase 1.

---

## G-12 — Important — PINS.md, PLAN rule 6, `scripts/bootstrap.sh`

**What is wrong.** "Pins are law" is not enforced. `bootstrap.sh` prints `LDC_VERSION`, `DUB_VERSION`, `UV_VERSION` and never compares them to anything; it only checks `command -v`. PINS.md's "Verified by" column claims `ldc2 --version`, `dub --version`, `pkg-config --modversion libuv`, and PLAN rule 6 says "`scripts/bootstrap.sh` verifies them". It does not. Separately, the script skips the engine build whenever `build/libqjs.a` exists, so a changed commit, changed CMake flags, or a stale cache never triggers a rebuild, and nothing checks that the archive is static or matches the host arch.

**Fix.** Compare each pin (`ldc2 --version` → `1.36`, `dub --version` → `1.36`, `pkg-config --modversion libuv` → `1.48`, `ninja --version` → `1.11.1`) and fail on mismatch, with `DJS_ALLOW_VERSION_DRIFT=1` as the documented escape. Write `commit + cmake args` to `vendor/quickjs-ng/build/.djs-stamp` and rebuild when it differs. Add `-DQJS_BUILD_EXAMPLES=OFF -DQJS_BUILD_LIBC=OFF -DQJS_ENABLE_INSTALL=OFF` (the research memo recommends these and explains why not to link `libqjs-libc.a`), then assert `libqjs.a` exists after the build.

---

## G-13 — Minor — ARCHITECTURE §6.1

**What is wrong.** The 16-byte `JSValue` layout is presented as universal; it is the x86_64/64-bit representation. The pinned header defaults to `JS_NAN_BOXING 1` on 32-bit builds and offers `JS_CHECK_JSVALUE` (pointer typedefs) as a debug mode, so §6.1's `static assert(JSValue.sizeof == 16)` fails to compile there with a confusing message at the first line of the binding.

**Evidence.** Probe against the vendored header: `sizeof(JSValue)=16 align=8 JS_NAN_BOXING=0 JS_CHECK_JSVALUE=0`; header lines 173–175 `#ifndef JS_NAN_BOXING / #define JS_NAN_BOXING 1 /* Use NAN boxing for 32bit builds. */`.

**Fix.** Wrap the asserts in `version (D_LP64)` (or `static if (size_t.sizeof == 8)`) and add: "v0.1 binds the 64-bit representation only; 32-bit builds use NaN boxing and need a second binding." This matters because ADR-002 sells libuv on a Windows/macOS path, and a future 32-bit or `JS_CHECK_JSVALUE` debug build should fail loudly, not silently misread tags.

---

## G-14 — Minor — ARCHITECTURE §4/§12 vs PLAN Phase 1

**What is wrong.** The file layout disagrees between documents at the exact place implementation starts:

- ARCH §4 diagram: `apis/ console.d · timers.d · fs.d · process.d · buffer.d`.
- ARCH §12 tree: `loop/timers.d` (no `apis/timers.d`).
- PLAN Phase 1: "`src/djs/loop/timers.d` + `apis/timers.d`".
- ARCH §12 lists `src/djs/errors.d # boundary conversion, uncaught policy`; PLAN Phase 1 never mentions it, and §10/§9 split the responsibility between "boundary code" and "the prelude".

**Fix.** Make ARCH §12 the single canonical tree, matching the PLAN Phase 1 file list; either drop `errors.d` or add it to Phase 1 with one line of ownership. Same for `apis/timers.d` vs `loop/timers.d` — pick one and use it everywhere.

---

## G-15 — Minor — PLAN Phase 0 / `docs/REVIEWS.md` (review-artifact contract)

**What is wrong.** Plan state is stale and the review workflow has no artifact contract.

- `[ ] Add scripts/check-no-phase-refs.sh` — the script exists and is tracked (`git ls-files scripts` → `scripts/bootstrap.sh`, `scripts/check-no-phase-refs.sh`).
- `[ ] Commit the skeleton (git) with a README quick start` — commit `5e285b2` exists.
- `[ ] Write docs/ARCHITECTURE.md and docs/D-GUIDE.md` — both exist as drafts (this review is the "review pending" step).
- PLAN says findings go to `docs/reviews/round-1-*.md`, while REVIEWS.md already calls the *document* review "Round 1" and the implementation rounds also start at 1 — the two namespaces collide. This review had to invent `doc-round-1-general.md` (matching the existing `doc-round-1-architecture.md`) and a `G-nn` ID scheme.
- REVIEWS.md's version table has `—` for every SHA-256, so "reviewed version" is untracked even though dispositions are per-finding; no severity definitions or verdict vocabulary are defined anywhere.

**Fix.** Tick the completed Phase 0 boxes and record the gate evidence. Then define the contract in REVIEWS.md: filename patterns `doc-round-<n>-<role>.md` / `impl-round-<n>-<role>.md`; ID prefixes `G-`/`A-`/`P-`; severity rubric (Critical = cannot execute as written or produces wrong results; Important = will cause rework or a known bug class; Minor = clarity/consistency); verdicts `APPROVE` / `APPROVE WITH CHANGES` / `REJECT`; and paste `sha256sum docs/*.md` output into the version table at review time.

---

## Verdict

**APPROVE WITH CHANGES.**

The documents are unusually good for a pre-build draft: they are specific, they name the real hazards (ownership, re-entrancy, thread affinity, sandboxing), and most verifiable claims are correct. But two findings block execution as written (the `@nogc`/exception contradiction and the undefined module-type rule), and the async core — job pump, callback registry, rejection timing — is specified too loosely to implement without guessing. None of these requires an architectural rethink; they are specification gaps and one build-flag error.

### Top 5 changes

1. **G-01** — Resolve `@nogc` vs D exceptions before any binding is written: pick `-preview=dip1008` or the two-tier "no exceptions on the loop path" rule, and make the §5 example match the choice.
2. **G-02 / G-03** — Write the module-type resolution table and fix the loader API section (5-arg `JS_SetModuleLoaderFunc2`, `module_check_attrs`, `JS_SetModuleNormalizeFunc2`, `JS_GetImportMeta`). Phase 2 is not executable without both.
3. **G-06 / G-07 / G-08** — Specify the job-pump error and exit contract, the callback-registry lifecycle with an explicit teardown order, and end-of-tick unhandled-rejection detection. This is where the crashes and the differential-test failures will come from.
4. **G-04 / G-05** — Fix the engine-memory rule (`js_malloc` is public; the normalizer must use it) and the class-finalizer signature (`JSRuntime*`, `js_free_rt`, `gc_mark` when holding `JSValue`s). Cheap now, heap corruption later.
5. **G-09 / G-12** — Make the build real: drop `-flto=full`, add `extraDependencyFiles`, and make `bootstrap.sh` actually compare the pinned versions instead of printing them.
