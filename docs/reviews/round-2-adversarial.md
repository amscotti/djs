**Scope:** full v0.1.0 release candidate (modules, fs, limits, gates, docs), not just the Phase 1 slice.
**Reviewed:** commit `596d430` (tag `v0.1.0`), tree clean. **Method:** read code/docs, drove the shipped `./djs`, ran `DJS_SKIP_BUILD=1 ./scripts/integration.sh`. No files modified by the reviewer.

**Verdict: NOT READY at review time — 5 blockers. All fixed; a re-check of each reproduction now passes.**

## Blockers and their fixes

| # | Blocker | Evidence at review | Fix |
|---|---|---|---|
| 1 | `require("fs")` returned `__djs.fs` primitives, not the public API; `require("fs/promises")` undefined | `typeof fs.readFile === "undefined"`, `require("fs/promises") === undefined` | `builtinValue` resolves `globalThis.fs` / `.promises` / `globalThis.process`; golden `require_fs` |
| 2 | `require` resolved against a runtime-wide directory stack, so exported/deferred calls loaded the wrong file | `B/x` printed for an `a/mod.cjs` call; deferred call threw MODULE_NOT_FOUND | `JS_NewCFunctionData` binds the module directory per function; `cjsDirs`/`cjsDepth` deleted |
| 3 | Throwing CJS module stayed cached, second `require` returned partial exports | `1 boom` then no throw | cache eviction on exception; golden `cjs_throw_twice` |
| 4 | `.json` imported as ESM was concatenated into source and executed | `CODE FROM A .json FILE EXECUTED`, `fs` reachable | emits `JSON.parse("<escaped>")`; no code path from data |
| 5 | `--timeout` only checked in an unref'd prepare callback; a 2 s timer under `--timeout 200` ran 2.01 s, exit 0 | measured | real unref'd `uv_timer` deadline wakes `poll()`; exits 1 at 213 ms |

## Other findings

| # | Sev | Finding | Disposition |
|---|---|---|---|
| 6 | Important | Caught OOM could exit 0; ARCH claimed `oomSeen` | **Docs corrected** — catchable OOM documented, forced-exit policy removed |
| 7 | Important | JSON `__proto__` became the prototype | **Fixed** by `JSON.parse`; golden asserts own key + `Object.prototype` |
| 8 | Minor | `--stack-size` ≥ 8 MiB segfaulted instead of `RangeError` | **Fixed** — clamped to 4 MiB |
| 9 | Minor | `DJS_MAX_FILE_SIZE` > INT_MAX inverted | **Fixed** — `size_t`, clamp |
| 10 | Minor | `mkdirSync` ignored a failed mode conversion | **Fixed** — returns the pending exception |
| 11 | Minor | `require("./x.json")` not cached (no identity) | **Fixed** — JSON values cached; golden `require_bound` covers module binding, JSON identity covered by the same path |
| 12 | Minor | Clean `process.exit()` with a blocked fs request printed a teardown warning and burned 200 ms | **Fixed** — quiet when exit/failed, 20-turn budget (73 ms measured) |

Verified-good areas with no findings: root containment (relative, absolute, symlink, `../`), CJS cycles, ESM/CJS interop, `ERR_REQUIRE_ESM`, import attributes, dynamic import, timer recycling/stale ids, 20k async fs cycles, 100k timer churn, `EFBIG` caps, view copy semantics, error fields, exit codes.
