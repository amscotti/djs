**Scope:** full v0.1.0 release candidate (modules, fs, limits, gates, docs), not just the Phase 1 slice.
**Reviewed:** commit `596d430` (tag `v0.1.0`), tree clean. **Method:** read code/docs, drove the shipped `./djs`, ran `DJS_SKIP_BUILD=1 ./scripts/integration.sh`. No files modified by the reviewer.

**Verdict: APPROVE WITH CHANGES** — no memory-safety defects; blockers were correctness/coverage.

## Blockers (all fixed in the fix round)

1. Embedded NUL bytes truncated fs paths and `require` specifiers instead of throwing.
2. Entry root derived from the lexical path: symlinked entries rejected; `.js` under a `"type":"module"` package misclassified as a script.
3. `gate-sanitize.sh` reported 21 cases while silently skipping 3; `cjs_cycle` had no entry point, so its golden never ran.

## Findings

| # | Sev | Finding | Disposition |
|---|---|---|---|
| 1 | Important | NUL truncation in `getPath`/`require` | **Fixed** — `memchr` checks, TypeError |
| 2 | Important | Entry root/symlink/package classification | **Fixed** — `projectRootFor`, realpath entry, package-root widening |
| 3 | Important | Sanitizer skipped missing cases | **Fixed** — missing case fails; counts executed |
| 4 | Important | Throwing CJS module stayed cached | **Fixed** — evict on every failure path |
| 5 | Important | JSON modules executed as JS; `__proto__` changed the prototype | **Fixed** — `JSON.parse` of an escaped string |
| 6 | Minor | `DJS_MAX_FILE_SIZE` int overflow | **Fixed** — `size_t`, clamped to default |
| 7 | Minor | Write encoding option silently ignored | **Documented** in COMPAT (v0.2 candidate) |
| 8 | Minor | Caught OOM exits 0 despite ARCH `oomSeen` claim | **Fixed docs** — policy removed from ARCH, recorded in COMPAT |
| 9 | Minor | PLAN DoD paths pointed at missing files | **Fixed** — DoD rewritten to real paths |
| 10 | Minor | `DJS_SKIP_BUILD` did not skip `dub test` | **Fixed** — guarded |
| 11 | Minor | Unknown-option error wrote a NUL byte | **Fixed** — length 20 |
| 12 | Minor | `package.sh` produced a different sha per run | **Fixed** — `cp -p` + deterministic tar |

Also noted, not findings: `import.meta.url` has no percent-encoding (documented), `require` of JSON now cached (fixed), `process.memoryUsage()` omits `arrayBuffers` (documented).
