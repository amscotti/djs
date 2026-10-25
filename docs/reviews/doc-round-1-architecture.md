# Document review round 1 — Architecture & Plan

**Reviewer role:** architecture & plan (does the design support the phases; is each phase executable; format/scope/risk adequacy).
**Documents reviewed:** `BRIEF.md`, `docs/ARCHITECTURE.md` (v0.1), `docs/PLAN.md` (v0.1), `docs/D-GUIDE.md` (v0.1), `docs/PINS.md`, `docs/REVIEWS.md`, `docs/research/d-idioms.md`, `docs/research/quickjs-embedding.md`, plus `scripts/bootstrap.sh`, `scripts/check-no-phase-refs.sh`, `vendor/quickjs-ng/quickjs.h` @ `6d46d07d`.
**Date:** 2026-10-20.

**Method.** Read all documents; checked every concrete API claim against the pinned `quickjs.h`; compiled D probes with the pinned LDC 1.36 (struct layout, copy semantics, `nothrow @nogc` + `catch (Throwable)`, `pure`, `@disable this(this)`); built a minimal DUB project with the guide's `dub.json` recipe; ran `scripts/bootstrap.sh` and `scripts/check-no-phase-refs.sh`. Probe evidence is quoted inline. No documents were edited.

**Overall.** The architecture is coherent and the plan has the right shape: exec summary → technical overview → four phases with Goal/TODO/DoD/Review gate → work log → risks/stop/open questions → references. Conventions are stated inline (PLAN §2) and the vertical slice is genuinely end-to-end. The defects are concentrated in three places: the D boundary contract as written cannot be implemented (and its guide example does not compile), module-type resolution is undefined where BRIEF and PLAN contradict each other, and several DoD items are not machine-checkable or not achievable as stated.

---

## Findings

### P-01 · Critical · PLAN §3 Phase 2, BRIEF L24 / L20 · Module type, entry rule, and how ESM reaches `fs` are undefined and mutually contradictory

BRIEF says `require` is for `.cjs` and local packages; Phase 2 says "`require` works for `.js`/`.cjs`/`.json`". Nothing states how a `.js` file is classified (ESM vs CJS), what `djs file.js` parses the entry as, or whether `package.json` `"type"` is honoured. Phase 2's DoD (`cjs_cycle/main.cjs`) only exercises `.cjs`, so the ambiguity survives every gate and lands in implementation. Related gap: ESM user code has no stated way to obtain `fs` or `process` — Phase 1 exposes them (presumably as globals via the prelude), but neither document says so, and Phase 2 rejects bare specifiers, so `import fs from 'node:fs'` (what every Node script does) fails with no documented alternative.

**Fix.** Add a short "module classification" table to ARCHITECTURE §8 and mirror it in Phase 2:
`.mjs` → ESM; `.cjs` → CJS; `.js` → `package.json` `"type"` in the nearest ancestor directory, default CJS; entry file uses the same rule (not "always ESM"). Add a builtin-specifier table: `fs`, `node:fs`, `process`, `node:process` resolve to the prelude-provided objects; everything else bare → `ERR_MODULE_NOT_FOUND`-style error. State explicitly that `fs`/`process` are also globals (matching BRIEF L21-22) and add tests: `require('./x.js')` where `x.js` is ESM (error, not silent parse failure), `import fs from 'node:fs'`, and `"type":"module"` in a fixture `package.json`.

### P-02 · Critical · ARCHITECTURE §6.2, D-GUIDE §3 · `ScopedValue` is not move-only; it is blit-copyable and will double-free every `JSValue`

The comment "non-copyable; move-only" is not enforced. D allows implicit blit copies of a struct that has a destructor (verified: a file containing `ScopedValue b = a; take(a);` compiles clean with LDC 1.36). Both copies then run `JS_FreeValue` on the same value — a double free in the single primitive the whole ownership story rests on.

**Fix.** In the snippet and the guide: `@disable this(this);` (verified: blocks the copy, still allows `return ScopedValue(...)` and `auto a = mk(...)` via RVO). Note that D has no move constructor, so a non-copyable guard must be passed by `ref` and relocated with `core.lifetime.move`; add a negative test `static assert(!__traits(compiles, { ScopedValue b = a; }));` next to the type. Add one sentence to §6.2: a `ScopedValue` must never be a struct field of a GC-allocated object or a function parameter taken by value.

### P-03 · Critical · D-GUIDE §5 (example), PLAN §2 conv. 1, ARCHITECTURE §6.3 · The prescribed boundary signature is self-contradictory; the canonical example does not compile

"Every `extern(C)` callback is `nothrow @nogc` … catch `Throwable` at the outermost frame" cannot work as a general pattern: a `@nogc` function may not call non-`@nogc` code, so it can never reach the throwing D implementation it is supposed to catch. The guide's own example fails on the pinned compiler:

```
p2.d(7): Error: `@nogc` function `js_foo` cannot call non-@nogc function `fooImpl`
p2.d(8): Error: `@nogc` function `js_foo` cannot call non-@nogc function `JS_ThrowInternalError`
p2.d(8): Error: function `JS_ThrowInternalError` is not `nothrow`
```

Two further inconsistencies: the guide says catch `Throwable` and convert an `Error` into a JS exception, while the research memo says an `Error` means the process is broken and must never be caught to recover; and `throw new Exception` inside `@nogc` needs `-preview=dip1008`, which the memo itself calls a smell.

**Fix.** State the two-tier rule explicitly and make the example compile: (1) the `extern(C) nothrow @nogc` trampoline calls a `@nogc nothrow` implementation that returns a status enum and never throws; (2) the trampoline maps status → `JS_ThrowTypeError`/`JS_ThrowRangeError` (all `JS_*` bindings declared `nothrow @nogc`, so they are callable), returning `JS_EXCEPTION`; (3) `catch (Throwable)` exists only as a last-resort net for `Error`s raised by `@nogc` code (bounds checks, asserts — verified catchable), and its action is "print + `exit(70)`", not "continue as a JS exception". Say which of the two policies wins for `Error`, and drop the `%.*s`-from-`t.msg` formatting from the hot path (formatting allocates; keep it in the cold path).

### P-04 · Important · ARCHITECTURE §7, PLAN §3 Phase 1 DoD · Loop driver drops/starves pending jobs; no promise test in the slice's DoD

§7 prescribes `uv_run(loop, UV_RUN_ONCE)` plus a drain "before the next iteration". Pending QuickJS jobs do not reference a libuv handle, so with no referenced handles `uv_run(ONCE)` returns immediately (jobs enqueued later are dropped), and with a long-period `setInterval` keeping the loop alive a pending promise chain waits for unrelated I/O. The research memo has the correct driver (`drain; if (!uv_loop_alive && !JS_IsJobPending) break; uv_run(ONCE)`) and the txiki.js `uv_idle`-while-jobs-pending pattern, but §7 does not adopt either. Phase 1's DoD then never runs a promise: all five checks use synchronous `console` only, so the prelude's promise wrappers can be entirely broken at the gate.

**Fix.** Replace §7's bullet with the memo's explicit loop and require a `uv_idle` handle that is started while `JS_IsJobPending(rt)` and stopped otherwise. Add Phase 1 DoD checks: `./djs -e 'Promise.resolve().then(()=>console.log("p"))'` prints `p`; top-level `await` in an ESM fixture; `queueMicrotask` vs `setTimeout(0)` ordering; a promise resolved from a timer; and a job run while a 60 s `setInterval` is alive (catches starvation). Document the no-fairness-limit hazard (self-enqueuing chain starves the loop) as a known limitation.

### P-05 · Important · ARCHITECTURE §6.2/§6.4 / PLAN §2 conv. 2 · Native structs that hold `JSValue`s need `gc_mark`, and the consuming-API list is missing

Timers, fs requests, and the CJS module cache must store callbacks/`module.exports` in native memory. §6.4 mentions a finalizer but never `JSClassDef.gc_mark`; per `quickjs.h:673-684` the finalizer is `void (JSRuntime*, JSValueConst)` with no `JSContext*` (so `JS_FreeValueRT`, not `JS_FreeValue`, and no JS calls), and a native struct holding `JSValue`s without `gc_mark` calling `JS_MarkValue` lets the cycle collector free objects the host still points at. Separately, the ownership rules omit the owning/consuming setters — `JS_SetPropertyStr`/`JS_SetPropertyUint32`/`JS_DefinePropertyValue*` free their value argument on success **and** failure (memo §2), the most common double-free in QuickJS hosts.

**Fix.** Add to §6.4: one `JSClassDef` per native object type, with `finalizer` (rt-only, `js_free_rt`/`JS_FreeValueRT`) and `gc_mark` (`JS_MarkValue` for each stored value); never store a `JSValue` in a D-GC object. Add a "consuming calls" list to §6.2 and to the D-GUIDE checklist: `JS_SetProperty*`, `JS_DefinePropertyValue*`, `JS_SetOpaque`'s return check (`int`, `quickjs.h:1065`). Add an ASan fixture where a timer is cleared while its callback is pending, and one where a JS object graph references a native object that references the graph (the cycle case `gc_mark` exists for).

### P-06 · Important · PLAN §3 Phase 1 TODO/DoD · `queueMicrotask` is a v0.1 requirement with no phase

BRIEF L21 requires `queueMicrotask`; ARCHITECTURE §7 designs it; no phase TODO or DoD mentions it, and Phase 3 claims "the v0.1 API is complete". A BRIEF-level contract item has silently fallen out of the plan.

**Fix.** Add to Phase 1: expose it via `JS_EnqueueJob` (confirmed exported: `quickjs.h:1247`, so the PLAN open question about a resolved-promise trampoline is resolved — use `JS_EnqueueJob`) and test ordering against `setTimeout` and `await`. Add a "BRIEF → phase" traceability row set to §3 (or an appendix) so every BRIEF bullet maps to a phase and a test; that is what would have caught this.

### P-07 · Important · PLAN §3 Phase 1 DoD · The slice's DoD leaves the prelude, REPL, exit codes, and rejection policy unproven

Phase 1 lands a REPL, the JS prelude, `fs` callback+promise+sync, and the uncaught-exception policy; its DoD exercises none of the REPL, no promise path, no `process.exit(code)` propagation, and no unhandled rejection. BRIEF L25 requires rejected promises to print and exit non-zero for v0.1, but the rejection tracker is scheduled in Phase 3 — so the slice can pass its gate while failing the build contract, and if the round budget runs out after Phase 2 the contract is unmet. The "zero D GC allocations over 1,000 timer iterations" check also has no mechanism named (a counter needs `--DRT-gcopt=profile:1` or `GC.profileStats`, neither of which is specified).

**Fix.** Add DoD items: piped-stdin REPL session with golden output; `./djs -e 'process.exit(7)'; test $? -eq 7`; `tests/js/unhandled_rejection.js` (move the tracker to Phase 1, since BRIEF requires it); `tests/js/promise_fs.js` (await + callback + sync in one file, ordering asserted). Replace the GC counter with the stronger, free guarantee — `@nogc` on the loop/binding functions makes allocation a compile error — plus a `malloc`/arena byte counter for boundary allocations; keep `GC.profileStats` only as a documented secondary check.

### P-08 · Important · PLAN §3 Phase 1 DoD · "ASan/Valgrind clean, no leaks attributable to DJS" is not achievable as written

A conservative D GC plus QuickJS's own allocator means LSan/Valgrind report reachable-at-exit blocks that are not DJS leaks; the research memo records that ASan does not instrument the D GC heap and that leak-checking against it was not measured. As written the item will either fail forever or be waived informally, which erodes the gate.

**Fix.** Specify the toolchain: (a) `-DJS_DUMP_LEAKS` + `JS_ComputeMemoryUsage` deltas for QuickJS-side leaks (requires a debug QuickJS build; add it to `bootstrap.sh` as a second, non-default build dir); (b) Valgrind `--leak-check=full` with a committed suppressions file, and the DoD wording "zero invalid reads/writes; every remaining leak classified in the suppressions file"; (c) ASan via `--fsanitize=address` (memo-verified) only on the C-side fixture, not as the primary gate.

### P-09 · Important · PLAN §1 budget vs §3 phase gates vs §4 work log · Round accounting is internally inconsistent

§1: "up to three review/fix rounds for the implementation". Each of four phases: "Maximum three rounds" — up to twelve. §4 lists "Implementation round 1" with no phase mapping. The stop condition ("a critical finding survives three fix rounds") therefore has no defined scope, and a reader cannot tell whether Phase 3 starts in round 2 or round 6.

**Fix.** Define one scheme and use it everywhere, e.g. round 1 = Phase 1, round 2 = Phase 2, round 3 = Phase 3 + Phase 4 hardening; each phase still gets the three-reviewer panel, one fixer, and at most two re-review cycles inside its round. Rename per-phase "max three rounds" to that language, map phases to rounds in §4, and state that an unresolved critical at the end of round 3 stops the project.

### P-10 · Important · ARCHITECTURE §8.1, PLAN §5 open questions · Module-loader API description is factually wrong in three places

Against the pinned header: `JS_SetModuleLoaderFunc2(rt, normalize, loader, check_attrs, opaque)` takes **five** parameters, including a `JSModuleCheckSupportedImportAttributes` callback (`quickjs.h:1225`); the normalize parameter is `JSModuleNormalizeFunc` (no attributes) — attribute-aware normalization is a separate call, `JS_SetModuleNormalizeFunc2` (`:1232`); the older entry point has four parameters (`:1220`), so "3-arg compatibility wrapper" is a misnomer; `import.meta` is not set by hand — it is `JS_GetImportMeta(ctx, m)` (`:1236`) plus `JS_SetModulePrivateValue`. Meanwhile two §5 open questions are answerable now: `JS_EnqueueJob` is exported (`:1247`), and `JS_SetCanBlock` exists (`:1190`) though no document tells the main runtime to leave blocking off (memo rule 17).

**Fix.** Correct §8.1 to the real signatures, name the check-attrs callback (that is where `with { type: "json" }` is accepted/rejected), state that `import.meta` comes from `JS_GetImportMeta`, and close the two open questions in §5 with the header evidence (keep `JS_SetModuleLoaderFunc2`; call `JS_SetCanBlock(rt, false)` on the main runtime). Add a `static assert`-style note that these declarations must be re-verified against the header when the pin moves.

### P-11 · Important · ARCHITECTURE §10 · Teardown and `process.exit` order is one sentence and is the most likely crash source

"`process.exit(code)` stops the loop and exits immediately after freeing the runtime; destructors that need the loop must run before" is not implementable: freeing a runtime while uv handles are open, or closing handles after `JS_FreeContext`, is use-after-free. The memo has the correct order (`uv_stop`, close JS-visible handles, `uv_run` until no closing handles, `JS_FreeContext`, `JS_FreeRuntime`, `uv_loop_close`, treat `UV_EBUSY` as a bug) and notes `uv_close` callbacks never run synchronously.

**Fix.** Put that sequence in §10 as a numbered teardown algorithm, and make `process.exit(code)` mean "record code, `uv_stop(loop)`, unwind to the driver", never `exit(3)` from inside a callback (which would skip finalizers and stdout flush). Add DoD: `process.exit(7)` inside a timer callback exits 7 with no leaks under Valgrind; `uv_loop_close` returning `UV_EBUSY` fails the test.

### P-12 · Important · ARCHITECTURE §11 vs PLAN §3 Phase 3 · Limit configuration is duplicated and timeout semantics are overstated

§11 configures the memory limit via `DJS_MEMORY_LIMIT`; Phase 3 adds `--memory-limit`, `--stack-size`, `--timeout` with no precedence. §11 implies `--timeout` bounds a script, but the interrupt handler is checked every 10,000 interpreter ticks and never runs inside native calls (memo §5), and after an interrupt the runtime must be discarded. A reader will assume `--timeout` bounds a slow `fs.readFile`, which it does not.

**Fix.** State precedence (flag > env > default) in one table, keep §11 as the only place limits are defined, and add: "the interrupt handler cannot preempt native calls; after an interrupt the runtime is discarded" plus a Phase 3 test that documents it (`--timeout 50` with a 2 s `readFile` is not interrupted). Also say whether `JS_SetMaxStackSize` is set below the real thread stack and whether `JS_UpdateStackTop` is called after any thread change (memo rule 14).

### P-13 · Minor · ARCHITECTURE §13, PINS.md, PLAN §3/§4 · Verification claims are not backed by scripts, and one TODO is environment-specific

`ARCHITECTURE` §13 says each phase writes machine-readable results to `gates/` "see PLAN.md"; PLAN never mentions `gates/` and no phase produces a gate artifact — DoDs are ad-hoc shell snippets whose comments ("stdout: 2, exit 0") are not checks. `PINS.md` says `bootstrap.sh` verifies the toolchain, but the script only prints LDC/DUB/libuv versions and compares the QuickJS commit (verified by running it: it prints and does not compare; any libuv would pass). Phase 4's deliverable-archive step is an orphan TODO with no host, mount, or check. Golden-file update procedure is unspecified, which invites silent churn in review.

**Fix.** Add `scripts/gate.sh <phase>` that runs each DoD command, records command/exit/duration to `gates/phase-<n>.json`, and is the only DoD entry; add version equality checks to `bootstrap.sh` (`ldc2 --version | grep -q 1.36.0`, `[ "$UV_VERSION" = 1.48.0 ]`); make golden updates opt-in (`UPDATE_GOLDEN=1`, diff must be reviewed) and have `integration.sh` fail otherwise; make the NAS step optional behind `DJS_PUBLISH_DIR` or drop it from the plan.

### P-14 · Minor · D-GUIDE §1 · The canonical `dub.json` does not build as documented (verified)

With LDC 1.36/LLVM 17 on Ubuntu 24.04, `"dflags-ldc": ["-O3", "-flto=full"]` fails at link: `The LLVMgold.so plugin (needed for LTO) was not found`. Also: `-lqjs` belongs in `libs` (DUB already prefixes `lflags` entries with `-L`; with `lflags: ["-Lvendor/quickjs-ng/build"]` DUB emitted `-L-Lvendor/...` and linked — verified — while the double-`-L` form emitted `-L-L-Lvendor/...` and failed), and the recipe omits `extraDependencyFiles`, so DUB does not relink when `libqjs.a` is rebuilt (memo §3).

**Fix.** Replace the recipe with one that builds on the pinned toolchain: `"libs": ["qjs","uv","m","dl","pthread"]`, `"lflags": ["-Lvendor/quickjs-ng/build"]`, `"extraDependencyFiles": ["vendor/quickjs-ng/build/libqjs.a"]`, and `-O3`/LTO only under `buildTypes.release.dflags-ldc` (so `dub test`/debug stay fast). Document LTO as opt-in requiring `llvm-17-linker-tools` (`-flto-binary`), or drop it. Keep the "verify key names for 1.36" caveat.

### P-15 · Minor · docs/research/*, D-GUIDE §2 · Three factual corrections worth making before developers copy them

(a) `d-idioms.md` §3 declares `uint uv_loop_init(...)`; libuv returns `int`, and this is the value every caller must check. (b) The same memo says `-betterC` removes "dynamic arrays"; slices and dynamic arrays are fine in betterC — `new` and `~=` are what disappear. The D-GUIDE version of the betterC paragraph is the accurate one. (c) Neither document notes that `alias JSValueConst = JSValue` is only valid for the default build: under `-DJS_CHECK_JSVALUE` it is `const JSValue*` (`quickjs.h:226`) and the alias silently changes ABI — say that checker builds are unsupported for linking. Also add one ABI round-trip unittest (`JS_NewInt32`/`JS_ToInt32`, `JS_NewFloat64`) to Phase 1: static asserts prove layout, not the struct-passing convention that a 16-byte `JSValue` depends on.

---

## What is good and should not change

- ADR-001…005 are decided, justified, and consistent with the research memos; the engine seam (§15) is credible because `bindings/` is already isolated.
- "Thin native, fat JavaScript" (ADR-004) is the right call for a small team and is carried consistently into §9 and the prelude plan.
- The one-runtime-thread / no-JS-from-the-thread-pool rule (§5) and the "never `uv_run` inside a callback" rule (§7) are the two invariants that keep this class of runtime alive; both are stated plainly.
- The plan's structure fully satisfies the required format, conventions are inline in §2 (not only in the guide), and the work log/REVIEWS disposition model is better than most plans at this stage.
- Phase 0's DoD genuinely passes on this machine (ran `bootstrap.sh` → exit 0, `qjs` smoke ok; `check-no-phase-refs.sh` → ok).

## Verdict

**APPROVE WITH CHANGES.**

The design is sound and the phase structure is executable once the boundary contract and module rules are pinned down. P-01, P-02, and P-03 must be fixed before Phase 1 starts; P-04 through P-12 should be fixed in the same edit pass because they change Phase 1/2 DoDs.

## Top 5 changes

1. **P-02/P-03 — make the boundary implementable and prove it compiles.** `@disable this(this)` on `ScopedValue` plus the negative `__traits(compiles)` test; rewrite the D-GUIDE §5 example as the `@nogc nothrow` status-return trampoline and state the single `Error` policy (print + exit 70, never converted into a JS exception).
2. **P-01 — decide module classification and builtin specifiers now.** `.mjs`/`.cjs`/`.js` + `package.json` `"type"`, `fs`/`node:fs` resolution, and an explicit statement that `fs`/`process` are globals; add the three tests that pin it.
3. **P-04/P-07 — fix the loop driver and make Phase 1's DoD exercise the prelude.** Adopt the memo's driver (drain jobs → break only if `!uv_loop_alive` and `!JS_IsJobPending` → `uv_run(UV_RUN_ONCE)`), with a `uv_idle` handle running while jobs are pending; add promise/`await`/microtask-order, REPL, `process.exit` and unhandled-rejection checks.
4. **P-05/P-11 — close the two silent-crash holes.** Require `gc_mark` + rt-only finalizer for every native `JSValue` holder (timers, fs requests, CJS cache), and write down the teardown sequence behind `process.exit`.
5. **P-06/P-09 — restore contract traceability and round honesty.** Map every BRIEF bullet to a phase and test (this recovers `queueMicrotask`), and replace the conflicting round budgets with one phase→round mapping.
