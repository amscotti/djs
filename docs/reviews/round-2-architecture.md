**Scope:** full v0.1.0 release candidate (modules, fs, limits, gates, docs), not just the Phase 1 slice.
**Reviewed:** commit `596d430` (tag `v0.1.0`), tree clean. **Method:** read code/docs, drove the shipped `./djs`, ran `DJS_SKIP_BUILD=1 ./scripts/integration.sh`. No files modified by the reviewer.

**Verdict: NOT READY at review time — documentation/code contract drift and two real blockers. All fixed except where stated.**

## Blockers and fixes

| # | Blocker | Fix |
|---|---|---|
| 1 | Phase 2/3 DoD commands referenced missing/misnamed files and a wrong exit expectation | DoD rewritten to existing paths; `require_esm` now checked via `grep ERR_REQUIRE_ESM` |
| 2 | `JS_SetModuleLoaderFunc2` received a five-argument normalizer where the pinned header takes four; attributes-aware normalizer never installed | Correct `JSModuleNormalizeFunc` alias; loader gets the 4-arg wrapper, `JS_SetModuleNormalizeFunc2` gets the 5-arg one |
| 3 | Gate evidence overstated coverage (module cases not run, empty `cjs_interop`, wrong `root_escape` golden, 21 vs 18 sanitizer cases) | Integration runs `.js/.mjs/.cjs` and directory entries; `cjs_cycle`/`cjs_interop`/`dynamic_import` fixtures added; sanitizer fails on missing cases |
| 4 | Phase 4 "final three-reviewer pass" checked with no panel and a tagged release | This panel ran; findings and dispositions recorded here and in `REVIEWS.md` |
| 5 | ARCH/COMPAT contradicted code on `Status`/`ErrorInfo`, `ScopedValue`, `DJS_MEMORY_LIMIT`/`oomSeen`, `uv_fs_t`, sync-fs toggle, timer close semantics, teardown, D unittest coverage, §12 layout | All amended to the implemented behaviour |

## Other findings

| # | Sev | Finding | Disposition |
|---|---|---|---|
| 6 | Important | `ScopedValue` unused despite REVIEWS R1-13 claiming it was adopted | ARCH §6.2 states it is an optional helper; R1-13 corrected |
| 7 | Important | Libuv callbacks are not wrapped in `catch (Throwable)` as PLAN/README claimed | Claim narrowed to JS-callable entry points in PLAN/README/DEVELOPING/ARCH |
| 8 | Important | Phase 3/4 soak, `JS_DUMP_LEAKS`, Valgrind, differential harness checked but absent | Unchecked in PLAN and marked deferred with the ASan/LSan substitution recorded |
| 9 | Important | Round-1 totals and document hashes wrong; R1-13 overstated | Totals corrected to 3/20/21; hash table refreshed; R1-13 fixed |
| 10 | Important | `require` not module-bound, and `require` exists in ESM contrary to COMPAT | Module binding fixed; COMPAT now says ESM can call `require` |
| 11 | Important | ARCH §13 claimed path/argument/cache/error D unittests that do not exist | Claim narrowed to the three real unittest modules |
| 12 | Minor | §9.3/§10 timer and teardown text stale; §12 listed a fictional `check-abi.c`, `buffer.d`, and omitted scripts | Amended; `check-abi.sh` and bench/fuzz/package added to §12 |

Residual documented divergences (not blockers): `import.meta.url` is not percent-encoded; write encodings ignored; `process.memoryUsage()` omits `arrayBuffers`; `require` in ESM; `mkdir` mode not applied. All are in `docs/COMPAT.md`.
