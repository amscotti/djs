# Review log

A review round is closed only when every finding has an explicit disposition: **fixed**, **deferred** (with reason), or **rejected** (with reason). Reviewers write full findings under `docs/reviews/`; this file is the index and the disposition record.

## Cross-cutting reviews

- **macOS parity** (research, port T1–T4, follow-up parity pass):
  `docs/reviews/macos-parity.md`.
- **v0.16.4 hardening**: security and compatibility fixes, coverage-driven
  follow-ups: `docs/reviews/v0.16.4-hardening.md`.

## Document versions

| Document | Reviewed hash (draft) | Current hash | Status |
|---|---|---|---|
| ARCHITECTURE.md | `e79da1e479171170` | `7b848e6697edb984` | revised; see dispositions |
| D-GUIDE.md | `de3849405b2d71e9` | `f26b38250ac6b937` | revised; see dispositions |
| PLAN.md | `ee480ffd632c5d01` | `e41b47f742894ba2` | revised; see dispositions |
| BRIEF.md | `cfd5c2ecd3f7dafc` | `02f858b97b01b684` | module classification clarified |
| PINS.md | `ba37a2e1534f8b84` | `ba37a2e1534f8b84` | unchanged |

## Round 1 — document review (pre-build, 2026-10-20)

| Reviewer | Critical | Important | Minor | Verdict |
|---|---|---|---|---|
| General (`doc-round-1-general.md`) | 2 | 10 | 3 | APPROVE WITH CHANGES |
| Adversarial (`doc-round-1-adversarial.md`) | 8 | 9 | 1 | APPROVE WITH CHANGES |
| Architecture & plan (`doc-round-1-architecture.md`) | 3 | 9 | 3 | APPROVE WITH CHANGES |
| **Total** | **13** | **28** | **7** | |

### Critical findings — all fixed

| ID | Issue | Fix |
|---|---|---|
| A-01 / P-11 | `process.exit` freed the runtime inside a callback (UAF) | §10: exit is a request (`uv_stop`), JS continues to end of turn, numbered teardown runs only in `main` |
| A-02 / G-06 / P-04 | Job drain treated `-1` as truthy and dropped microtask exceptions | §7: exact `>0` / `0` / `-1` contract, per-turn 10k budget, driver loop |
| A-03 / G-08 | Rejection tracker produced false unhandled-rejection exits | §10: dup'd pending set, remove on `is_handled=true`, report at end of each job drain |
| A-04 / A-12 | JS buffer could be GC'd/detached during `writeFile`; short writes/truncation | §9.4: dup'd buffer + view offset/length, re-fetch pointer, short-read/write loops, `uv_fs_req_cleanup` |
| A-05 | User strings passed as `JS_Throw*` format arguments | §6.3 and D-GUIDE §5: format-string rule (`"%s"`/`"%.*s"`) |
| A-06 | `JS_GetOpaque` returns NULL on wrong `this` | §6.4: `JS_GetOpaque2` only, check `JS_SetOpaque` |
| A-07 | Truncated libuv struct mirrors caused heap overflow | D-GUIDE §4: opaque types + `uv_*_size` + accessors; never truncated mirrors |
| A-08 | JSValue ABI is conditional; D asserts could not see C flags | §12: C ABI probe in `bootstrap.sh` (`JS_NAN_BOXING`, `JS_CHECK_JSVALUE`, size, 64-bit) |
| P-01 / G-02 | Module type/entry rule contradicted across docs | §8.0 classifier table, shared by entry/import/require; BRIEF and Phase 2 updated |
| P-02 | `ScopedValue` was blit-copyable and double-freed | §6.2: `@disable this(this)` + negative compile test + `ref`/move note |
| P-03 / G-01 | `@nogc` boundary example could not compile | D-GUIDE §5: two-tier status/`ErrorInfo` trampoline; `catch (Throwable)` only exits 70 |
| G-03 / P-10 | Module-loader API described wrongly | §8.1: five-arg `JS_SetModuleLoaderFunc2`, `check_attrs`, `JS_SetModuleNormalizeFunc2`, `JS_GetImportMeta` |

### Important findings — fixed

- A-09 / P-12: `--timeout` is interrupt + loop deadline; native calls remain uninterruptible; OOM policy added.
- A-10: sync fs uses blocking POSIX calls, never `uv_run`/JS re-entry.
- A-11 / P-05: timer ids are generation-checked slots, freed in `uv_close` callback; no pointer ids.
- A-13 / P-01: canonical realpath, root containment, symlink resolution, builtin table.
- A-14: uncaught reporter arms the deadline, never reads `.stack` in the tracker.
- A-15: driver loop, `uv_stop` close-callback drain, `UV_EBUSY` policy.
- A-16: memory limit scope and OOM handling documented.
- A-17: `RuntimeOptions` capability seam (globals can be omitted).
- G-04: allocator pairing (`js_malloc`/`js_free` vs `malloc`/`free`), normalizer uses `js_malloc`.
- G-05 / P-05: finalizer is `(JSRuntime*, JSValueConst)`, `gc_mark` with `JS_MarkValue`, `js_malloc_rt`.
- G-07: callback registry lifecycle, cancellation, teardown order.
- G-09: dropped `-flto=full`; `extraDependencyFiles` added.
- G-10: console output contract (inspect subset, format specifiers).
- G-11: timer contract (`Timeout` object, clamping, FIFO, throw policy).
- G-12: bootstrap compares LDC/DUB/libuv/Ninja pins and the QuickJS commit; stamp file.
- P-06: `queueMicrotask` is an explicit Phase 1 TODO and test.
- P-07: Phase 1 DoD now tests promises, microtasks, rejection, `process.exit`, REPL.
- P-08: leak gate reworded to ASan + `JS_DUMP_LEAKS` + Valgrind "definitely lost" attributable to DJS.
- P-09: one round budget (round 1 = Phase 1, 2 = Phase 2, 3 = Phase 3 + 4), max two re-reviews per phase.

### Minor findings — dispositions

| ID | Disposition |
|---|---|
| A-18 (gates cannot hold) | **Deferred**: gate scripts are implementation deliverables; Phase 1/4 TODO and DoD now name the exact checks. |
| P-13 (verification claims not backed by scripts) | **Fixed** for bootstrap/ABI/no-phase-refs; **deferred** for `BENCH.md`/`COMPAT.md` to Phase 4. |
| P-14 (`dub.json` sample did not build) | **Fixed**: LTO removed, `extraDependencyFiles` added. The implementation must prove the recipe still builds. |
| P-15 (factual corrections) | **Fixed**: `pure` may throw/allocate and FFI can lie; `-release` still bounds-checks `@safe`; ASan flag `--fsanitize=address`; `js_malloc` is public; loader API corrected. |
| G-13 (`JSValueConst` note) | **Fixed**: §6.1 explains the by-value alias and `JS_CHECK_JSVALUE`. |
| G-14 (layout/Phase 1 mismatch) | **Deferred**: `src/djs/…` is fixed in ARCH §12 and PLAN Phase 1; implementation will confirm. |
| G-15 (review artifact contract) | **Fixed**: this file plus `docs/reviews/` naming convention. |

## Implementation rounds

| Round | Scope | Reviewers | Critical | Important | Minor | Verdict |
|---|---|---|---|---|---|---|
| 1 | Phase 1 vertical slice | general, adversarial, architecture/plan | 3 | 20 | 21 | APPROVE WITH CHANGES → fixed |
| 2 | Full release candidate (rounds 2+3 scope: modules, fs, limits, gates, docs) | general, adversarial, architecture/plan | 3 | 18 | 15 | NOT READY → blockers fixed, re-checked |

A round is done when its three reviewers return no open critical findings and every important finding has a disposition. A critical that survives its round's fix stops the project.

## Round 1 — implementation review dispositions

Source reports: `docs/reviews/round-1-general.md` (RG-xx), `docs/reviews/round-1-adversarial.md` (RA-xx), `docs/reviews/round-1-architecture.md` (RP-xx). The three reports overlap; findings are merged below under one fix ID, which is what `docs/PLAN.md` §3.1 tracks.

| Fix ID | Reports | Issue | Disposition |
|---|---|---|---|
| R1-01 | RG-01, RP-08 | `dub test` overwrites `./djs` with the unittest binary | **fixed** — unittest configuration has its own `targetName`/`targetPath` |
| R1-02 | RP-01, RA-04 | Teardown blocks on in-flight fs work; `UV_EBUSY` frees the loop | **fixed** — bounded `UV_RUN_NOWAIT` drain; leak-and-honor-code on EBUSY |
| R1-03 | RG-08, RP-02 | Phase 1's ASan/leak/GC gates do not exist; `gates/` empty | **fixed** — `gate.sh`, `gate-sanitize.sh`, `gate-alloc.sh`, committed evidence |
| R1-04 | RG-02, RA-05, RP-03 | Registry slot table leaked every run | **fixed** — `registryDestroy` in teardown |
| R1-05 | RG-06, RA-02 | `process.exit(code)` clobbered by later jobs/rejections | **fixed** — drain stops on exit request; explicit code preserved |
| R1-06 | RA-06 | Same-batch callbacks run after a fatal error | **fixed** — completion entry points check `failed \|\| exitRequested` |
| R1-07 | RA-01 | Timer create/clear churn grows native memory without bound | **fixed** — stopped timer handles are recycled from a free list |
| R1-08 | RG-04 | `readFile` silently corrupts binary data | **fixed** — default `Uint8Array`, `{encoding}` opt-in return string |
| R1-09 | RA-03 | `readFile` has no size cap or `fstat` | **fixed** — `fstat` + 512 MiB cap + `EFBIG` |
| R1-10 | RG-03, RA-09, RP-04 | fs uses `uv_queue_work`, not `uv_fs_*` | **accepted deviation** — rationale and cancellation consequences documented in ARCH §9.4/§12; errors carry real syscall names |
| R1-11 | RG-07 | SIGPIPE kills the runtime | **fixed** — `SIGPIPE` ignored at startup |
| R1-12 | RP-06 | No `catch (Throwable)` net on JS-callable entries | **fixed** — every JS-callable entry point wrapped; libuv-internal callbacks are plain `nothrow @nogc` (claim narrowed in PLAN/README/DEVELOPING) |
| R1-13 | RG-09, RP-07 | `ScopedValue`/`Status`/`ErrorInfo` dead code contradicts docs | **fixed with correction** — `Status`/`ErrorInfo` deleted; `ScopedValue` kept as an optional, unit-tested helper but **not used by the bindings**, and ARCH §6.2/§6.3 say so (an earlier disposition wrongly claimed it was adopted) |
| R1-14 | RA-04, RP-05 | Teardown order inverted vs §10 | **fixed** with R1-02 |
| R1-15 | RG-12, RA-08 | REPL does not run the loop between lines; Ctrl-D hangs | **fixed** — bounded pump per line; teardown at EOF |
| R1-16 | RG-05, RA-07, RP-11 | Timer ids lose precision above 2^53 | **fixed** — ids published as `BigInt` |
| R1-17 | RA-13, RP-10 | `slotCancelled`/`registryCancel` unreachable | **fixed** — removed; cancellation deferred until a cancellable API exists (ARCH §9.1) |
| R1-18 | RA-09, RP-04 | fs errors always report `syscall: "open"` | **fixed** — per-operation syscall names |
| R1-19 | RA-10 | `DataView` rejected as write data | **fixed** — `ArrayBufferView` fallback |
| R1-20 | RG-14, RA-11 | `process.env` truncates keys at 255 bytes | **fixed** — keys allocated at full length; platform from `version(linux)` |
| R1-21 | RA-12 | `JS_SetPropertyStr` result handling inconsistent (`-1` treated as success) | **fixed** — single `> 0` helper, exception cleared on failure |
| R1-22 | RG-11 | Non-Error throws print `<exception>` | **fixed** — symbols print their description |
| R1-23 | RG-13 | `err.stack` lacks the message line | **deferred** — the reporter prints the head separately; parity recorded in `docs/COMPAT.md` |
| R1-24 | RG-10, RP-09 | Layout/doc drift from ARCH §12 | **fixed** — §12 updated to the real tree |
| R1-25 | RG-10 | README claims modules before Phase 2 | **fixed** — status line added |
| R1-26 | RA-14 | `runtimeCreate` fail path closes loop with live handles | **fixed** — close handles, drain, then `uv_loop_close` |
| R1-27 | RG-15 | Misleading `JS_Eval` comment; unused imports | **fixed** |
| R1-28 | RG-10, RP-15 | Missing `dub.selections.json`; libc build flag | **accepted deviation** — `dub.selections.json` added; `qjs` oracle needs libc, so it is built but never linked (PINS documents this) |

No round-1 finding is open critical. R1-10, R1-23 and R1-28 are the accepted deviations and all three are recorded in ARCH/COMPAT/PINS with reasons.

## Round 2 / 3 — release-candidate panel (2026-10-21)

Sources: `docs/reviews/round-2-general.md`, `round-2-adversarial.md`, `round-2-architecture.md`. The panel reviewed the full v0.1.0 candidate at commit `596d430`; the three reports total 36 findings (3 critical, 18 important, 15 minor) and 13 blockers after overlap. All blockers were reproduced by the fixer before changing code, then fixed and re-checked.

| Fix ID | Reports | Issue | Disposition |
|---|---|---|---|
| R2-01 | G-1, A-1, Ar-10 | `require("fs"/"fs/promises"/"process")` returned `__djs` primitives, not the public API | **fixed** — `builtinValue` reads `globalThis.fs`/`fs.promises`/`globalThis.process`; `require_fs` golden |
| R2-02 | A-2, Ar-10 | `require` resolved from a runtime-wide directory stack; exported/deferred calls loaded the wrong module | **fixed** — `JS_NewCFunctionData` binds each module's directory; stack removed; `require_bound` golden |
| R2-03 | G-1, A-3 | NUL bytes in paths/specifiers silently truncated (`fs.unlinkSync("a.txt\0x")` deleted `a.txt`) | **fixed** — `memchr` checks in fs and both require paths, TypeError; `nul_path` golden |
| R2-04 | G-1, A-3 | Throwing CJS module stayed cached; second `require` returned partial exports | **fixed** — cache eviction on compile/call failure; `cjs_throw_twice` golden |
| R2-05 | A-4, G-5, A-7 | JSON modules were spliced into JS source and executed; `__proto__` changed the prototype | **fixed** — `export default JSON.parse("<escaped>")`; `json_proto` golden asserts own key + clean prototype |
| R2-06 | A-5 | `--timeout` never fired while the loop was parked in `poll()` (2 s timer under `--timeout 200` ran 2.01 s) | **fixed** — real unref'd `uv_timer` deadline; exits 1 at ~213 ms even with a blocked fs request |
| R2-07 | G-2, Ar-1 | Entry root from lexical path: symlinked entries rejected; `.js` in a `type:module` subdirectory misclassified | **fixed** — canonical entry, `projectRootFor` widens to the owning package; both layouts tested |
| R2-08 | Ar-2 | Module normalizer passed a 5-arg function to a 4-arg ABI slot; attributes normalizer never installed | **fixed** — correct alias + both registrations |
| R2-09 | G-3, A-5, Ar-3, Ar-7 | Gate evidence overstated coverage: `.mjs/.cjs` skipped, `cjs_cycle` had no entry, `cjs_interop` empty, `root_escape` golden wrong, sanitizer counted skipped cases | **fixed** — integration runs all extensions and directory entries; fixtures added; sanitizer fails on a missing case and reports executed count (27) |
| R2-10 | Ar-4 | Phase 4 "final three-reviewer pass" checked and tagged with no panel | **fixed** — panel run; this section + three review files record it |
| R2-11 | Ar-5, Ar-6, Ar-9 | ARCH/COMPAT described `Status`/`ErrorInfo`, adopted `ScopedValue`, `DJS_MEMORY_LIMIT`/`oomSeen`, `uv_fs_t`, per-timer close, cancelled slots, exit 70 on busy loop, D unittests that do not exist | **fixed docs** — all sections amended to implemented behaviour |
| R2-12 | Ar-8 | PLAN claimed soak, `JS_DUMP_LEAKS`, Valgrind and a differential harness that do not exist | **fixed docs** — unchecked and marked deferred; ASan/LSan substitution and 27-fixture coverage recorded |
| R2-13 | A-6 | Caught OOM exits 0; ARCH promised a forced exit | **fixed docs** — catchable OOM documented in COMPAT/ARCH; `oomSeen` removed |
| R2-14 | A-8 | `--stack-size` ≥ 8 MiB segfaulted instead of `RangeError` | **fixed** — clamp to 4 MiB |
| R2-15 | G-6, A-9 | `DJS_MAX_FILE_SIZE` above `INT_MAX` inverted and failed every read | **fixed** — `size_t`, clamped to the default |
| R2-16 | A-10 | `mkdirSync` ignored a failed mode conversion and left a pending exception | **fixed** — returns the exception |
| R2-17 | A-11 | `require("./x.json")` returned a fresh object each call | **fixed** — JSON values cached like modules |
| R2-18 | A-12 | Clean `process.exit()` with a blocked fs request printed an internal warning and burned 200 ms | **fixed** — quiet on exit/failure, 20-turn budget (73 ms measured) |
| R2-19 | G-7, A-? | Write encodings ignored; `import.meta.url` not percent-encoded; `process.memoryUsage()` omits `arrayBuffers`; `mkdir` mode ignored | **documented** as v0.1 divergences in COMPAT (not release blockers) |
| R2-20 | G-10, G-11, Ar-12 | `DJS_SKIP_BUILD` did not skip `dub test`; unknown-option error wrote a NUL; `package.sh` sha not reproducible; `check-abi.c`/`buffer.d` fictional in §12 | **fixed** — guarded skip, length 20, deterministic tar, §12 amended |

**Result:** no open critical or important finding. Remaining work is the documented v0.2 list in `docs/reviews/release-plan-review.md` (differential harness, soak + `JS_DUMP_LEAKS`, write encodings, percent-encoded URLs, `Buffer`). Gates after the fix round: `gate.sh` 6/6, integration 60/60, sanitizer 27/27, fuzz 28/28.


## Round 3 — v0.2.0 surface (2026-10-21)

Sources: `docs/reviews/round-3-general.md`, `round-3-adversarial.md`,
`round-3-architecture.md` (panel transcripts retained under
`docs/reviews/`). The panel reviewed commit `337614d` (tag `v0.2.0`) and
reported 36 findings (3 critical, 12 important, 21 minor) with 7 blockers after
overlap. All code blockers were reproduced against the shipped binary before
being fixed.

| Fix ID | Issue | Disposition |
|---|---|---|
| R3-01 | `copyFile(src, src)` (also hardlink/symlink-to-source) truncated the source to 0 bytes while returning success | **fixed** — destination opened without `O_TRUNC`, `fstat` dev/ino identity check returns success untouched; mode preserved with `fchmod`; same-path and overwrite cases in `fs_extra` and the Node diff |
| R3-02 | `readFile`/`readFileSync`/`fs.promises.readFile` accepted `hex`/`base64`/`latin1`/`ascii` but always UTF-8-decoded | **fixed** — native read returns bytes, prelude decodes with `Buffer.toString`; hex/base64/latin1 goldens and diff cases |
| R3-03 | `memoryUsage().arrayBuffers`/`external` were constant 0 (QuickJS `binary_object_size` does not count ArrayBuffers) | **fixed** — pinned QuickJS carries a small accounting patch (`scripts/patches/quickjs-array-buffer-accounting.patch`, applied by `bootstrap.sh`); `JS_GetArrayBufferBytes`; `memory_usage` proves a 4 MiB delta |
| R3-04 | Recursive `mkdir` reported success when the leaf was a file | **fixed** — `EEXIST` accepted only when `stat` confirms a directory; golden + diff |
| R3-05 | `rm -r` failed with `EINVAL` above 64 levels and deleted part of the tree first | **fixed** — read-only pre-scan, 1024-level cap, `fs_deep_rm` removes a 70-level tree; diff case |
| R3-06 | `writeFile`/`appendFile` ignored `{mode}`; `copyFile` dropped the source mode (0600 became 0664) | **fixed** — mode plumbed to `open`, source mode applied with `fchmod`; write/copy mode goldens |
| R3-07 | `Buffer.alloc(n, "a")`/`fill("a")` zero-filled; `write(str, off, "utf8")` returned NaN; `byteLength` stringified views | **fixed** — string fills, overload handling and type-aware `byteLength`; goldens |
| R3-08 | Base64url `-`/`_` decoded to empty; lone surrogates emitted CESU-8 | **fixed** — base64url alphabet and in-place U+FFFD replacement; goldens |
| R3-09 | ESM named exports missed `fs.promises`, `fs.constants`, `path.posix`, `path.delimiter`, `os.devNull`, `os.endianness` | **fixed** — export lists extended; `builtin_new_modules` |
| R3-10 | `path.normalize`/`join` dropped trailing separators; `extname("a.")` was `""`; `os.endianness` was a string | **fixed** — trailing-preserving normalize/join, Node extname rule, `os.endianness()` function; diff + goldens |
| R3-11 | Golden/diff suites avoided every v0.2 divergence, so the defects above passed the gates | **fixed** — integration 70 cases, sanitizer 37, diff 7 cases, new fs/Buffer/path/os goldens; README/COMPAT/ROADMAP/ARCH/PLAN/BENCH corrected |
| R3-12 | Permission-model review: prelude-level checks are bypassable through `__djs`; os/env facts are eager; symlink policy unresolved | **carried into Phase 6** — design rewritten to native-only enforcement, per-access os functions, env filtering in `processEnv`, canonicalised rules, `O_NOFOLLOW`/`openat2`, explicit precedence and async denial contract; `docs/PERMISSIONS.md` is normative |

**Result:** every v0.2.0 code blocker is fixed and covered by a golden or diff
case. Verification after the fix round: `gate.sh` 8/8, integration 70/70,
ASan/LSan 37/37, Node diff 7/7, soak green. The permission-model findings are
design inputs for Phase 6, not v0.2.0 regressions.


## v0.3.0 — node package loading (implementation verification)

This release did not go through an external three-reviewer panel; it was
verified by the gate suite plus targeted probes. Recorded here so the evidence
trail stays honest.

| Area | Evidence |
|---|---|
| Bare, scoped and subpath resolution | `node_modules_test`, `node_modules_import`, `node_modules_exports*`; fixture packages `demo-cjs`, `demo-dep`, `demo-esm`, `@demo/scoped`, `demo-exports` |
| `exports` maps and conditions | `demo-exports` import vs require conditions, exact subpath, `*` pattern, exports-authoritative deep-import rejection (`MODULE_NOT_FOUND`) |
| `imports` (`#specifier`) | `demo-exports/esm/uses-imports.js` resolves `#internal` and a bare `#dep` target |
| CJS named exports in ESM | `import { value, name } from "demo-cjs"` on a `module.exports = {…}` fixture |
| pnpm-style layout | `linkpkg -> .store/linkpkg` symlink resolves; an external symlink target is refused with `ERR_ACCESS_DENIED` |
| Real npm packages | `is-number` (CJS), `escape-string-regexp@5` (ESM exports-only), `uuid` picks its `import` condition but still needs the absent `crypto` builtin |
| Target safety | exports/imports targets must stay `./`-relative and may not contain `..`; malformed exports fall back to no match |
| Gates | `gate.sh` 8/8, integration 74/74, ASan/LSan 41/41, Node diff 7/7, soak green |

Accepted limitations are listed in `docs/COMPAT.md` and `docs/PLAN.md`
(conditions other than node/import/require/default, workspace links outside the
root, Yarn PnP, native addons, missing builtins for some packages).


## v0.4.0 — permissions (implementation verification)

No external reviewer panel ran on this delta. Evidence is the dedicated
permission gate plus the full release gates, recorded here so the claim is
auditable.

| Area | Evidence |
|---|---|
| Default deny | 20-check `scripts/gate-permissions.sh`: read/write/env/sys denied with no flags |
| Scoped grants | read/write path grants; outside-path and prefix-collision denials; symlink target judged canonical |
| Precedence | `--deny-*` beats `-A`; `process.permission.drop` revokes |
| Bypass resistance | direct `__djs.fs.readFileSync` and `__djs.os.hostname` denied |
| Async contract | `fs.readFile` denial arrives as `PermissionDenied`/`ERR_ACCESS_DENIED` in the callback |
| Config/audit | `djs.json` set resolution; JSONL contains both allow and deny records |
| Harness | integration/sanitize/diff/soak run with `-A`; permission gate runs without it |
| Gates | `gate.sh` 9/9, integration 74/74, ASan/LSan 41/41, Node diff 7/7, soak green |

Known partials are listed in `COMPAT.md`: `ignore` is treated as deny, the
module graph is exempt without being recorded, net/run/ffi/import rules have
no APIs yet, prompts are TTY-only, and async denial is delivered before
queueing. The model is a seat belt, not a kernel sandbox.


## v0.5.0 — core modules (implementation verification)

No external reviewer panel ran on this delta; the evidence is the expanded
integration/differential/sanitizer suites plus a startup-cost measurement.

| Area | Evidence |
|---|---|
| Events | `events_module`, `esm_modules`: on/once/off/emit, listener counts, `events.once()` |
| Streams | `stream_module`: `Readable.from`, `Transform`, `pipeline`, data/end ordering |
| URL | `url_util_module`: URL parsing, `URLSearchParams` mutation reflected in `href`, `parse`/`format` |
| util | `format`, `inspect`, `promisify`, `inherits` in `url_util_module` |
| timers/structuredClone/Abort | `timers_clone_abort` |
| fs streams | `fs_streams` read/write round-trip |
| ESM builtins | named exports from `events`, `stream`, `url`, `util` (`esm_modules`) |
| Differential | Node comparison extended with `modules.js` (8 cases) |
| Gates | `gate.sh` 9/9, integration 80/80, ASan/LSan 47/47, diff 8/8, soak green |

Known limits are in `COMPAT.md`: simplified backpressure/object mode, fs streams
buffer whole files, URL is not a full WHATWG implementation, and
`structuredClone` does not handle typed arrays or transfer lists. The 28 KB
prelude addition raised cold start from ~10.2 ms to ~13.7 ms; that regression is
recorded in `BENCH.md` and is the main follow-up candidate (lazy/split prelude).


## v0.6.0 — fs depth review round

Two independent reviews ran on the uncommitted delta: adversarial code review
and plan/architecture alignment. Both returned NOT READY. Dispositions:

| Finding | Severity | Disposition |
|---|---|---|
| Numeric open flags ignored `O_CREAT`/`O_TRUNC`/`O_APPEND`; read grant could truncate/create | critical | fixed: flags classified for access plus create/truncate/append; access mode 3 rejected |
| Dangling symlink planted with `symlinkSync` allowed writes outside a grant | critical | fixed: leaf symlinks resolved before permission matching; regression case asserts the outside file is not created |
| `closeSync`/`readSync` accepted libuv fds and could SIGABRT the process | critical | fixed: runtime fd table; foreign descriptors return `EBADF` |
| `writeSync`/`fs.write`/`FileHandle.write` argument shapes dropped offset/length or crashed | important | fixed: Node buffer/string forms, callbacks receive `(err, n, buffer)` |
| String modes parsed as decimal (`"600"` → `0o130`) | important | fixed: octal parser for `open`/`chmod`/`fchmod` |
| No `O_CLOEXEC` anywhere | important | fixed on every fs open |
| `fs.open` blocked the loop on FIFOs | important | fixed: `openStart` runs through `uv_queue_work`; timer probe passes |
| `fs.read`/`write`/`fsync`/link/mode callbacks still run on the loop thread | important | carried: documented in COMPAT/ARCH and PLAN v0.7 prerequisites |
| `fs.constants` only had `COPYFILE_EXCL` | important | fixed: access/open constants |
| Stat was missing Dates/birthtime/blksize/blocks/rdev, second granularity | important | partially fixed: fields and Dates added; second granularity documented |
| `FileHandle` lacked truncate/chmod/chown/sync/readFile/writeFile | important | fixed for the listed methods; no async disposal |
| `flags` string leak per `openSync` | important | fixed: `JS_FreeCString` |
| Buffer builtin and TextEncoder/TextDecoder absent | important | fixed: `require("buffer")`, globals |
| Error objects lost `path` on new path ops | medium | fixed |
| Module graph/computed imports exempt from read grants | high | carried to v0.7 (PLAN prerequisite) |
| `readlinkSync` unbounded growth, fd coercion, no EINTR retry | minor | fixed: 1 MiB cap, integer fd validation, retry loops |
| Stale fs docs | medium | fixed: COMPAT/ARCH/PLAN/ROADMAP/PERMISSIONS updated |

Verification after fixes: integration 82/82, permission gate 31 checks,
sanitizer includes `fs_depth` and `fs_depth_regress`, full gate 9/9 (recorded in
`gates/`). The remaining known gaps are the blocking read/write callbacks and
the module-graph exemption; neither is hidden in the public docs.


## v0.7.0 — networking review round

The plan/architecture review reproduced seven release blockers in the first
plain-networking cut. All were fixed before the v0.7.0 tag; the adversarial
code-review child was interrupted, so its coverage is represented by the
issues below rather than a second independent list.

| Finding | Severity | Disposition |
|---|---|---|
| `socket.end()` shut down before queued writes flushed; data lost and loop hung | critical | fixed: `Socket` is a `Duplex`; `Writable.end` waits for the queue, `_final` shuts down after the last write callback |
| write error left the poll handle alive forever | critical | fixed: write errors close the socket and release callbacks |
| a second `write()` freed the first buffer and orphaned its callback | critical | fixed: Writable serializes writes; native completion captures the callback id before invoking JS |
| every refused connect reported `EIO`/`poll` | critical | fixed: `SO_ERROR` is read on poll failure; `ECONNREFUSED`/errno/syscall are correct |
| throwing callbacks were swallowed (exit 0) | critical | fixed: `runtimeReportUncaught` |
| fd closed before `uv_close` callback | critical | fixed: `CloseCtx` closes the fd in the close callback |
| immediate connect success never fired the callback | critical | fixed: `connecting` stays true until the poll completion path |
| blocking `getaddrinfo` froze timers for 10 s | critical | fixed: `uv_getaddrinfo`; timer runs during lookup |
| `Socket` was not a stream | important | fixed: `Duplex`; `pipe`, backpressure, serialized `_write` |
| HTTP header CRLF injection | important | fixed: `ERR_INVALID_CHAR`/`ERR_INVALID_HTTP_TOKEN` |
| truncated content-length/chunked bodies resolved silently | important | fixed: `ERR_HTTP_BODY_TRUNCATED`/`ERR_HTTP_INVALID_BODY` |
| no header/body limits | important | fixed: 16 KiB headers, 64 MiB buffered body |
| `--allow-net=*.host` promised but denied | important | fixed: wildcard + case-insensitive host matching |
| no networking test in integration/sanitizer/diff | important | fixed: `net_basic`, ASan case 50, diff case 9, expanded loopback gate |

Verification: full gate 10/10, integration 83/83, sanitizer 50/50, Node diff
9/9, permission gate 34 checks, loopback net gate 7 assertions.

Known v0.7 limits: TLS/HTTPS are deferred to v0.9 and fail with
`ERR_TLS_NOT_IMPLEMENTED`; DNS is IPv4 `lookup` only; HTTP buffers whole
responses; the socket table is a fixed 128 entries with index ids (stale-id
generation is tracked for v0.7.1). These are in COMPAT rather than hidden.

## v0.8.0 — child_process adversarial review

The first child_process cut was reviewed before commit. Every finding below was
reproduced against the tree; the fix column is what landed in `child.d`,
`prelude.js` and `permissions.d`.

| Finding | Severity | Disposition |
|---|---|---|
| `shell:true` wrote 2 bytes past a malloc'd command string, then freed the `/bin/sh` and `-c` literals and double-freed the command | critical | fixed: exact size, separate exec argv, single owner per allocation; ASan clean |
| `fcntl(fd, 12, O_NONBLOCK)` is `F_GETLK64`, not `F_SETFL` (4); every pipe stayed blocking | critical | fixed: `F_SETFL`; async timer no longer blocks the loop |
| `spawnSync` wrote all stdin before reading stdout; `cat` with a large `input` deadlocked | critical | fixed: stdin is polled in the same loop and closed at EOF |
| `readFd` drained stdout to EOF before looking at stderr; small stdout plus 200 KiB stderr deadlocked | critical | fixed: `readFd` stops at `EAGAIN`; both pipes are polled |
| Child ids were slot indexes; a stale `ChildProcess` wrote into or killed a later child in the same slot | high | fixed: generation-tagged ids; the handle clears `_id` before `exit`/`close` |
| `runAllowed` accepted a basename match for any path, and `-A` overrode `--deny-run` | high | fixed: exact path grants, `/bin/sh` alias for `sh`, deny probe before the alias |
| Forked children inherited every parent pipe (sibling stdin/stdout/stderr) | high | fixed: `FD_CLOEXEC` on all six pipe ends; sibling `cat` sees EOF immediately |
| `process.exit()` hung in teardown on a live child's blocking read | high | fixed by the non-blocking pipes; children are left running (Node behaviour) |
| Table exhaustion forked first, killed the child and never reaped it (zombie) | high | fixed: capacity is checked before fork; kill paths `waitpid` |
| `kill("SIGKILL")` was a no-op (`JS_ToInt32` produced 0) | medium | fixed: signal-name mapping, range check |
| Missing `cwd` was silently ignored; the command ran in the parent directory | medium | fixed: `stat` before fork, `ENOENT` error with `path`/`syscall` |
| Argument conversion failures (Symbol, throwing `toString`) were swallowed and argv silently truncated | medium | fixed: the pending exception is returned before fork |
| `stdin.write` on a non-blocking pipe could drop bytes | medium | fixed: per-child 16 MiB queue, flushed by the poll timer, EOF after drain |
| New `child-run-allowed` permission case asserted `execSync(...).stdout`; `execSync` returns a Buffer | medium (gate) | fixed: `.toString().trim()`; gate is green |
| `timeout`/`maxBuffer` missing, binary stdout decoded as UTF-8, no `shell`/`input` on `spawn` | low | documented in COMPAT as limits, not fixed |

Verification after the fix round: `scripts/gate-permissions.sh` (39 checks),
`scripts/integration.sh` 88/88, `scripts/diff-node.sh` 10/10, `dub test` 3
modules, ASan/LSan on `child_process`, `child_async` and `process_stdio`. The
v0.8.0 scope is implemented: `child_process`, `process.stdin`/`stdout`/`stderr`
and signal handlers (`process.on`, receiving only). `process.kill`, binary
stdout and `spawnSync` `timeout`/`maxBuffer` remain documented limits.


## v0.9.0–v0.10.0 review rounds

- **v0.9.0 (crypto/zlib)**: Buffer stringification, `Transform.final` being
  ignored, unbounded decompression and per-runtime slot ownership. See
  `docs/reviews/v0.9.0-plan.md`, `-architecture.md`, `-application.md`.
- **v0.9.1 (TLS, inserted)**: blocking-descriptor loop stall, uninitialized
  `addrinfo`, missing connect timeout, stringified binary reads, and a 79 KB
  LeakSanitizer report from unfreed `tlsCall` arguments/callback slots. See
  `docs/reviews/v0.9.1-tls.md`.
- **v0.10.0 (server/UDP/readline)**: listener invalid free on close, slot-index
  socket ids, HTTP half-close truncation, duplicate request dispatch, dgram
  `localhost`. See `docs/reviews/v0.10.0-{plan,architecture,application}.md`.
- **v0.10.1 (Node compat + Express)**: CallSite stacks, callable `stream`,
  EventEmitter mixin safety, main-module paths, fs stream classes,
  `safe-buffer`, `string_decoder` UTF-8 boundaries. See
  `docs/reviews/v0.10.1-node-compat.md`.
- **v0.11.0 (Node partials batch 1)**: process/os/fs/dgram surfaces; native
  additions only reachable after the JS facade is extended, Linux-only socket
  constants, and a truncated-golden release mistake. See
  `docs/reviews/v0.11.0-partials.md`.
- **v0.11.1 (HTTP hardening)**: per-connection state machine, keep-alive and
  pipelining, chunked request decoding, HEAD/100-continue, deadline handling,
  graceful drain, child timeout/maxBuffer. See
  `docs/reviews/v0.11.1-http.md`.
- **v0.11.2 (HTTPS server)**: TLS server over the client's slot/poll path,
  fd hand-off via `net.detachFd`, `https.createServer`; IPv6 moved to
  v0.12.1. See `docs/reviews/v0.11.2-https.md`.
- **v0.12.0 (crypto breadth)**: one-shot AES-CBC/GCM ciphers, pbkdf2, HMAC-built
  HKDF, scrypt; OpenSSL 3 HKDF ctrl crash worked around. See
  `docs/reviews/v0.12.0-crypto.md`.
- **v0.12.1 (net IPv6, perf_hooks, os extras)**: AF_UNSPEC lookup, dual-family
  connect/listen, host-derived address family; batch-3 remainder moved to
  v0.12.2. See `docs/reviews/v0.12.1-ipv6.md`.
- **v0.12.2 (signatures)**: RSA/EC PEM sign/verify and KeyObject; batch-3
  remainder moved to v0.12.3. See `docs/reviews/v0.12.2-sign.md`.
- **v0.12.3 (fs.watch)**: inotify-backed watch with change/rename and close;
  leftovers moved to v0.12.4. See `docs/reviews/v0.12.3-watch.md`.
- **v0.12.4 (dns.resolve)**: A/AAAA arrays with dedupe; other record types
  deferred. See `docs/reviews/v0.12.4-dns.md`.
- **v0.12.5 (opendir, watchFile)**: eager Dir wrapper and polling StatWatcher;
  vm/Web Streams moved to v0.12.6. See `docs/reviews/v0.12.5-dir.md`.
- **v0.12.6 (vm)**: fresh QuickJS context isolation with a JSON boundary;
  Web Streams moved to v0.12.7. See `docs/reviews/v0.12.6-vm.md`.
- **v0.12.7 (Web Streams)**: readable/writable/transform streams, pipeTo and
  queue-based backpressure. See `docs/reviews/v0.12.7-streams.md`.
- **v0.13.0 (WebSocket)**: client+server handshake, frames, ping/pong and
  close; HTTP/2 moved to v0.13.1. See `docs/reviews/v0.13.0-websocket.md`.
- **v0.13.1 (HTTP/2 h2c)**: frame codec, HPACK with Huffman decoding,
  multiplexed client/server; Node interop verified both directions. See
  `docs/reviews/v0.13.1-http2.md`.
- **v0.13.2 (examples + fetch gaps)**: Express and Hono HTMX/Alpine apps,
  `Request` global and complete `Headers`. See
  `docs/reviews/v0.13.2-examples.md`.
- **v0.13.3 (DeepSeek SDK)**: fetch streaming body, FormData, Headers
  iteration and a real OpenAI-SDK integration. See
  `docs/reviews/v0.13.3-deepseek.md`.
- **v0.13.4 (incremental HTTP)**: true token streaming; parser emits on
  headers and decodes chunked bodies incrementally. See
  `docs/reviews/v0.13.4-incremental-http.md`.
- **v0.13.5 (assert/module/stream)**: the top three scorecard gaps closed. See
  `docs/reviews/v0.13.5-assert-module.md`.
- **Tier 2 architecture review** (after v0.15.3): fork transport debt,
  permission inheritance, missing cluster/worker, docs drift. See
  `docs/reviews/tier2-architecture-review.md`.
- **v0.16.3 (D-guide conformance)**: slice cores behind `@trusted` edges, tables
  over `strcmp` chains, `scope(exit)` for fs buffers, and a close-out review of
  every change since v0.16.2 (R-01..R-11, each with a disposition). See
  `docs/reviews/v0.16.3-d-guide.md`.
- **v0.16.1 (stream consumers/readline)**: subpath builtins for real libraries.
  See `docs/reviews/v0.16.1-stream-consumers-readline.md`.
- **v0.16.0 (core API long tail)**: getRandomValues, parseArgs, fs.glob,
  timers, URL helpers. See `docs/reviews/v0.16.0-core-long-tail.md`.
- **v0.15.9 (worker_threads shim)**: child-process workers, workerData,
  parentPort, eval. See `docs/reviews/v0.15.9-worker-threads.md`.
- **v0.15.8 (cluster)**: fork workers, SO_REUSEPORT listener sharing,
  process.pid. See `docs/reviews/v0.15.8-cluster.md`.
- **v0.15.7 (ALPN/HTTP-2 TLS)**: server ALPN selection, secure h2.
  See `docs/reviews/v0.15.7-alpn-http2-tls.md`.
- **v0.15.6 (mTLS server)**: `caFile`/`requestCert`, `authorized` on server
  sockets. See `docs/reviews/v0.15.6-mtls.md`.
- **v0.15.5 (TLS client options)**: custom CA, client cert/key, ALPN
  advertisement. See `docs/reviews/v0.15.5-tls-client.md`.
- **v0.15.4 (spawn env)**: options.env via execvpe, fork IPC via env.
  See `docs/reviews/v0.15.4-env.md`.
- **v0.15.3 (fork IPC)**: loopback JSON IPC, process.execPath.
  See `docs/reviews/v0.15.3-fork-ipc.md`.
- **v0.15.2 (diagnostics/SSE)**: diagnostics_channel, trace_events, perf
  marks, EventSource, ClientRequest abort. See
  `docs/reviews/v0.15.2-diagnostics-sse.md`.
- **v0.15.1 (fs breadth)**: cp, readv/writev, openAsBlob, recursive watch.
  See `docs/reviews/v0.15.1-fs.md`.
- **v0.15.0 (child_process)**: async `exec`/`execFile`, timeout/maxBuffer.
  See `docs/reviews/v0.15.0-child-process.md`.
- **v0.14.4 (stream state/diagnostics)**: `_readableState` on Readable,
  specifier in module errors. See `docs/reviews/v0.14.4-streams-diagnostics.md`.
- **v0.14.3 (prelude split)**: monolith split into seven ordered modules,
  concatenated at compile time with byte-identical source. See
  `docs/reviews/v0.14.3-prelude-split.md`.
- **v0.14.2 (cleanup)**: CJS entry wrapping, shebang stripping, upgrade
  connection tracking, toWeb backpressure, ws helper dedupe. See
  `docs/reviews/v0.14.2-cleanup.md`.
- **v0.14.1 (compat harness)**: real `ws` and `jose` in the gate; client
  upgrade, secret KeyObjects, randomFill, socket stream states. See
  `docs/reviews/v0.14.1-compat.md`.
- **v0.14.0 (DNS records)**: MX/TXT/SRV/CNAME/NS/PTR/SOA wire client,
  promises + setServers. See `docs/reviews/v0.14.0-dns.md`.
- **v0.13.9 (WebCrypto)**: subtle core for digest/HMAC/AES-GCM/RSA/ECDSA
  and PBKDF2/HKDF. See `docs/reviews/v0.13.9-webcrypto.md`.
- **v0.13.8 (Brotli/decode)**: brotli sync + fetch gzip/br decoding. See
  `docs/reviews/v0.13.8-brotli.md`.
- **v0.13.7 (crypto, upgrade, Blob/FormData)**: hkdf, keygen, streaming
  sign/verify, X509, `upgrade` handoff. See `docs/reviews/v0.13.7-crypto.md`.: hkdf, RSA/EC/Ed25519 keygen, streaming
  sign/verify, X509 inspection. See `docs/reviews/v0.13.7-crypto.md`.
- **v0.13.6 (Buffer + module + stream interop)**: full numeric/BigInt
  accessors, `require.resolve`, entry `module`, `toWeb`/`fromWeb`. See
  `docs/reviews/v0.13.6-buffer-module.md`.
- **Compatibility roadmap**: priority order by library impact/effort in
  `docs/COMPAT-ROADMAP.md` (v0.13.5 audit).
- **Pre-1.0 readiness**: `docs/reviews/v1.0-readiness.md` lists the inserted
  work; the post-1.0 items were replanned into v0.11.0–v0.13.1.
