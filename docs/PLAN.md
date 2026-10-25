# DJS — Build Plan

> **Historical.** The build plan that drove v0.1–v0.7. Current state is in
> [`../README.md`](../README.md), [`COMPAT.md`](COMPAT.md) and
> [`ROADMAP.md`](ROADMAP.md).

**Status:** v0.7.0 released (plain networking; TLS deferred) · **Owner:** Hermes (orchestrator) · **Last updated:** 2026-10-21
**Working name:** DJS (placeholder). **Repo:** `https://github.com/amscotti/djs`

---

## 1. Executive summary

DJS is a small JavaScript runtime written in D, embedding QuickJS-NG and libuv. The goal is a single binary that starts in milliseconds, runs real JavaScript files, and exposes a deliberately small Node-shaped API (`console`, timers, `fs`, `process`, local ESM/CommonJS modules) without Node's dependency tree or a C++ engine shim.

The project is deliberately scoped as a **useful runtime, not a Node clone**. QuickJS-NG is an interpreter: CPU-bound JavaScript will be slower than V8/JSC. That is an accepted trade for a runtime aimed at glue code, tooling, automation, and embedded scripting. If the project later needs Node fidelity or JIT performance, the engine seam is designed to allow a JSC/V8 backend without rewriting the host.

The build is organized as a **vertical slice first**: prove the C boundary, the loop, and the API shape with `console`, timers, `process`, and `fs.readFile`; then widen to modules, the full fs surface, and hardening. Every phase has machine-checkable exit criteria and a review gate. Work is tracked in the Work Log; reviewers write findings to `docs/reviews/`, and every finding gets an explicit disposition in `docs/REVIEWS.md`.

**Budget:** three implementation rounds, mapped to phases: **round 1 = Phase 1**, **round 2 = Phase 2**, **round 3 = Phase 3 plus Phase 4 hardening**. Each round is code → three independent reviews (general, adversarial, architecture/plan) → one fixer → re-run gates. A phase may have at most two re-review cycles inside its round. If a critical finding survives its round's fix, stop and report; do not start a fourth round.

**Where we are (2026-10-22, v0.13.5):** v0.1.0 shipped and was reviewed (36 findings / 13 blockers in the release-candidate panel, all fixed). v0.2.0 added the committed surface — `Buffer`, `path`, `os`, extended `fs` (rename/copyFile/rm/realpath/recursive mkdir, write encodings), `setImmediate`/`nextTick`, percent-encoded `import.meta.url`, `memoryUsage().arrayBuffers` — plus Node differential and soak gates. v0.3.0 added Node-style `node_modules` package loading (`exports`/`imports` maps, conditions, patterns, CJS named exports). v0.4.0 added default-deny permissions. v0.5.0 added `events`, core `stream`, `url`, `util`, `timers/promises`, `structuredClone`, `AbortController` and fs streams. v0.6.0 added fd APIs, chmod/chown/links, richer stat, `buffer` and text codecs. v0.7.0 added `net` TCP clients, `dns.lookup`, a plain-HTTP client and `fetch(http://)`; TLS/HTTPS are deferred to the crypto phase and fail loudly. **v0.8.0 is complete** (`child_process`, process stdio, signal handlers) and **v0.9.0 is complete** (`crypto` hashes/HMAC/CSPRNG/`randomUUID`/`timingSafeEqual`, `zlib` sync helpers and compression streams). The v0.9.0 plan review inserted **v0.9.1 — TLS client and HTTPS transport** because v0.7 deferred TLS to the crypto phase but the v0.9.0 row never scheduled it; **v0.9.1 is now complete** (`tls.connect`, `https`, `fetch(https://)`, verified against a loopback server). **v0.10.0 is complete**: `net.Server`, HTTP/1.1 server, `dgram`, `readline`, the listen permission, and a measured `worker_threads` deferral. The v0.10.0 review originally pushed HTTPS server, HTTP hardening, crypto breadth, HTTP/2, WebSocket and `worker_threads` past 1.0. **They have been replanned into v0.11.0–v0.13.1** (rows 15–21); only the platform ports remain exclusive to v1.0.0. Batch 1 of the Node partials (process/os/fs/dgram) is already in v0.11.0. Remaining gaps and their intent are in `docs/ROADMAP.md`.

---

## 2. Technical overview

### Stack

| Layer | Choice | Why |
|---|---|---|
| Host language | D 2.106 / LDC 1.36 | C interop, `@nogc` control, native code, fast builds |
| JS engine | QuickJS-NG v0.17.0 (pinned) | Small MIT C library, ES2025, microsecond startup, no C++ shim |
| Event loop | libuv 1.48 | Cross-platform, proven, C ABI |
| Build | DUB + CMake (for QuickJS-NG) | One command bootstrap; pinned |
| Tests | D `unittest` + JS integration + golden files | Fast unit loop plus real runtime behavior |

### Architecture in one paragraph

One runtime thread owns one libuv loop and one QuickJS `JSRuntime`/`JSContext`. Native functions exposed to JS are `extern(C) nothrow @nogc`; they report failures by arming a JS exception and returning `JS_EXCEPTION`, and every entry point has a `catch (Throwable)` net that prints and exits 70 so no D exception unwinds through C. A thin native layer exposes mechanisms (`readFileStart`, `timerStart`, `consoleWrite`), and an embedded JavaScript prelude turns them into Node-shaped APIs (`fs.promises.readFile`, callback overloads, `require`). ESM is loaded through QuickJS's module loader; CommonJS is a host `require` with a cache. Promises settle through QuickJS's job queue, which the host drains after every loop callback. Memory, stack, and execution time are capped through QuickJS runtime limits. QuickJS is not treated as a security boundary; hostile code requires process isolation.

### Non-negotiable conventions (inline, self-contained)

1. **C boundary contract:** every JS-callable entry point is `nothrow @nogc` and wraps its body in `catch (Throwable) { print; exit(70); }`. Internal libuv callbacks are plain `nothrow @nogc` and must stay allocation-free/assert-free. No D exception unwinds into C; no GC allocation in the loop, bindings, or per-request paths.
2. **Value ownership:** every `JSValue` has exactly one owner. Functions taking `JSValue` take ownership; `JSValueConst` is borrowed; functions returning `JSValue` transfer ownership. Dup on store, free on release. Never store a `JSValue` in GC memory.
3. **C layout:** mirror C structs exactly and `static assert` sizes/offsets you rely on. Opaque C types are used through pointers and `*_size`/accessor functions.
4. **No phase references in code:** source, tests, comments, and identifiers never mention plan phases or task IDs. `scripts/check-no-phase-refs.sh` enforces this and runs in the gate.
5. **Tests are the oracle:** every behavior has a test; where behavior overlaps Node, a differential test compares observable output and intentional differences are documented in `docs/COMPAT.md`.
6. **Pins are law:** LDC, DUB, QuickJS-NG commit, libuv version, and flags live in `docs/PINS.md`; `scripts/bootstrap.sh` verifies them.
7. **Gates produce evidence:** every gate script appends a machine-readable line to `gates/`, which is committed. A gate that leaves no artifact did not run.

### Deliverables

- `docs/ARCHITECTURE.md` — system design, boundaries, ADRs, risks.
- `docs/D-GUIDE.md` — how to write D in this codebase, including `pure`, `@safe`, `@nogc`, C interop, testing.
- `docs/PLAN.md` — this document.
- `docs/COMPAT.md` — intentional divergences from Node, with reasons.
- `docs/BENCH.md` — measured cold start, RSS, throughput.
- `docs/REVIEWS.md` + `docs/reviews/` — review rounds and dispositions.
- Working code: `dub build --build=release`, `dub test`, `scripts/integration.sh`, `scripts/gate.sh`.

---

## 3. Phases

### Phase 0 — Bootstrap and guardrails (done)

**Goal:** a clean checkout can verify its toolchain, fetch/build the pinned engine, and run the documentation and guardrail checks.

**TODO**

- [x] Create repo skeleton and `BRIEF.md` with scope, non-goals, and engineering rules.
- [x] Install and verify LDC 1.36, DUB 1.36, libuv 1.48, CMake, Ninja.
- [x] Pin QuickJS-NG v0.17.0 (commit `6d46d07d…`) and build `libqjs.a`.
- [x] Write `scripts/bootstrap.sh`; smoke-test the `qjs` binary.
- [x] Write `docs/PINS.md` and `docs/REVIEWS.md`.
- [x] Add `scripts/check-no-phase-refs.sh` and wire it into the gate.
- [x] Write `docs/ARCHITECTURE.md` and `docs/D-GUIDE.md`; revise both against the research memos.
- [x] Write research memos `docs/research/d-idioms.md` and `docs/research/quickjs-embedding.md`.
- [x] Review the three documents; dispose every finding (13 critical, 28 important, 7 minor; see `docs/REVIEWS.md`).
- [x] Commit the skeleton with a README quick start.

**Definition of done**

```bash
./scripts/bootstrap.sh           # exits 0, prints toolchain + qjs smoke ok
./scripts/check-no-phase-refs.sh # exits 0 on the tree
```

---

### Phase 1 — Vertical slice: engine, loop, console, timers, process, `fs.readFile`

**Status:** done; extended by the v0.2 surface (Buffer, path, os, fs operations) and kept green by the gates.

**Goal:** `djs -e 'console.log(1 + 1)'` prints `2`; `djs file.js` runs a script that uses `console`, `setTimeout`, `process`, and `fs.readFile`; errors produce a non-zero exit.

**TODO**

- [x] `src/djs/bindings/quickjs.d`: `JSValue`/`JSValueConst`, lifecycle, eval/call, exception helpers, limits, `JS_SetCanBlock(false)`.
- [x] `src/djs/bindings/value.d`: `ScopedValue`, conversions, throw and property helpers.
- [x] `src/djs/loop/libuv.d`: opaque libuv declarations, `*_size` allocation, accessors.
- [x] `src/djs/runtime.d`: create runtime/context, globals, prelude, script entry, job drain, exception policy, loop driver, teardown.
- [x] `src/djs/apis/console.d`: `__djs.console.write(fd, string)`.
- [x] `src/djs/apis/timers.d`: `setTimeout`/`setInterval`/clear, ref/unref/refresh/hasRef.
- [x] `src/djs/apis/process.d`: `argv`, `env`, `cwd`, `exit`, `platform`, `version`.
- [x] `src/djs/apis/fs.d`: `readFile`/`writeFile` sync + callback + promise; buffer/view handling.
- [x] `src/djs/registry.d`: generation-checked callback slots, dup on register, free on fire/teardown.
- [x] `js/prelude.js`: console formatting, timers, process, fs wrappers, `queueMicrotask`.
- [x] `src/djs/main.d`: `djs file.js`, `djs -e`, REPL, `--help`, `--version`, exit codes.
- [x] `dub.json`, `scripts/integration.sh`, `tests/js/`, `tests/golden/`, `tests/ut_main.d`.
- [x] `scripts/check-no-phase-refs.sh`.

**Definition of done**

```bash
./scripts/bootstrap.sh
dub build --build=release
dub test
./scripts/integration.sh
./scripts/gate.sh                                    # ABI, no-phase-refs, ASan/LSan, alloc counter
./djs -e 'console.log(1 + 1)'                        # stdout: 2, exit 0
./djs -e 'Promise.resolve().then(() => console.log("p"))'
./djs -e 'queueMicrotask(() => console.log("m")); setTimeout(() => console.log("t"), 0)'
./djs tests/js/timers_order.js
./djs tests/js/fs_read.js
./djs tests/js/exit_in_timer.js; test $? -eq 7
./djs tests/js/microtask_throw.js; test $? -ne 0
./djs tests/js/rejection.js; test $? -ne 0
printf '1+1\n' | ./djs
./djs tests/js/throw.js; test $? -ne 0
```

### 3.1 Round-1 fix list (executable)

IDs are the merged findings from `docs/reviews/round-1-*.md`; the finding-to-ID mapping is in `docs/REVIEWS.md`.

| ID | Fix | Acceptance |
|---|---|---|
| R1-01 | Unittest config gets its own `targetName`/`targetPath` | `dub test && ./djs -e 'console.log(1)'` prints `1` |
| R1-02 | Teardown: close handles, bounded `UV_RUN_NOWAIT` drain, never block; `UV_EBUSY` leaks rather than frees; honor requested exit code | FIFO read + `process.exit(3)` exits 3 within 1 s |
| R1-03 | Add `scripts/gate-sanitize.sh`, `scripts/gate-alloc.sh`, `scripts/gate.sh`; commit `gates/` evidence | `./scripts/gate.sh` exit 0, `gates/*.txt` present |
| R1-04 | `registryDestroy` in teardown | LSan clean; 100 create/teardown cycles flat |
| R1-05 | Stop draining jobs once exit is requested; never overwrite an explicit code | `Promise.reject(...); process.exit(3)` → exit 3 |
| R1-06 | Gate `onTimer`/`onIdle`/`onPrepare`/fs completion on `failed \|\| exitRequested` | first throw stops all same-batch timers |
| R1-07 | Recycle stopped timer handles through a free list; close only at teardown | 200k create/clear in one turn: RSS delta < 20 MB |
| R1-08 | `readFile` returns a `Uint8Array` by default; `{encoding}` returns a string | binary round-trip byte-identical |
| R1-09 | `fstat` + `DJS_MAX_FILE_SIZE` (default 512 MiB) before reading; `EFBIG` beyond | `/dev/zero` fails fast, bounded memory |
| R1-10 | Keep `uv_queue_work` (blocking POSIX) and document the deviation in ARCH §9.4/§12, including cancellation consequences | docs match code; review sign-off |
| R1-11 | `SIGPIPE` ignored at startup; `EPIPE` is a no-op | `djs -e '…' \| head -1` exits 0 |
| R1-12 | `catch (Throwable)` net in every `extern(C)` entry | forced-`Error` unittest exits 70 |
| R1-13 | Delete unused `Status`/`ErrorInfo`/`throwStatus`; use `ScopedValue` in multi-value paths; amend ARCH §6.3 | no dead tier code; docs match |
| R1-14 | Teardown order per ARCH §10 (implemented with R1-02) | code walk + ASan |
| R1-15 | REPL pumps the loop (bounded `NOWAIT`) after each line; teardown at EOF | `setTimeout(...,0)` output precedes the next prompt |
| R1-16 | Timer ids are exact 64-bit (`BigInt`) | 2.2M churn test still clears correctly |
| R1-17 | Remove `slotCancelled`/`registryCancel`; document cancellation as deferred | no dead state |
| R1-18 | Real `syscall` names (`open`/`read`/`write`/`close`) in fs errors | `EISDIR read`, `ENOSPC write` |
| R1-19 | Accept `DataView` and other `ArrayBufferView`s as write data | byte-exact DataView write |
| R1-20 | `process.env` keys are not truncated; platform from `version(linux)` | 300-byte key survives (documented) |
| R1-21 | `JS_SetPropertyStr` checked `> 0` on every path | D unittest with a throwing setter |
| R1-22 | Symbols and non-Error throws print their description | `throw Symbol("s")` prints `Symbol(s)` |
| R1-23 | `err.stack` message-line parity | deferred to Phase 4 COMPAT (reporter prints the head separately) |
| R1-24 | ARCH §12 layout updated to the real tree | docs match |
| R1-25 | README marked "Phase 1 implemented, modules Phase 2" until Phase 2 lands | docs match |
| R1-26 | `runtimeCreate` failure path closes handles before `uv_loop_close` | ASan fault-injection unittest |
| R1-27 | Trim unused imports; correct the `JS_Eval` NUL comment | build clean |
| R1-28 | Commit `dub.selections.json`; add `-DQJS_BUILD_LIBC=OFF` for the library build | bootstrap passes |

**Review gate:** three independent reviewers — general, adversarial, architecture & plan. Findings go to `docs/reviews/round-1-*.md`. One fixer addresses all accepted findings, then the gate is re-run. At most two re-review cycles inside this round.

---

### Phase 2 — Modules: ESM and CommonJS

**Goal:** the §8.0 classifier is implemented once and used by the entry point, `import`, and `require`: `.mjs`/`"type":"module"` `.js` are ESM, `.cjs`/other `.js` are CommonJS, `.json` is JSON; cycles behave predictably; builtins (`fs`, `node:fs`, `fs/promises`, `node:fs/promises`, `process`, `node:process`) resolve; paths cannot escape the project root.

**TODO**

- [x] `src/djs/modules/classify.d`: one classifier for `.mjs`/`.cjs`/`.js` + nearest `package.json` `"type"`; canonical `realpath`; root containment; extension probing; JSON.
- [x] `src/djs/modules/resolve.d`: relative/absolute resolution, directory `package.json` `main`, canonical cache keys; builtin table; `ERR_MODULE_NOT_FOUND`/`MODULE_NOT_FOUND`.
- [x] `src/djs/modules/esm.d`: five-argument `JS_SetModuleLoaderFunc2`; normalize with `js_malloc`; `check_attrs`; `import.meta` (`url`, `filename`, `dirname`); `JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY`; JSON modules; dynamic `import()`.
- [x] `src/djs/modules/cjs.d`: `require` function, wrapper compilation, cache-before-execute for cycles, `module.exports`, `__filename`, `__dirname`, `ERR_REQUIRE_ESM`.
- [x] Interop: ESM default-imports CJS; named exports are detected heuristically since v0.3.0 (`modules/cjsnames.d`).
- [x] Entry point uses the classifier: `.mjs` → module eval, `.cjs` → CJS module, `.js` → script or module per `package.json`.
- [x] Tests: ESM chain, CJS chain, cycle, JSON import, `require`-of-ESM error, builtin imports, missing file, syntax error with filename, dynamic `import()`, root escape, `import.meta.url`.

**Definition of done**

```bash
./djs tests/js/esm_chain/main.js
./djs tests/js/cjs_cycle/main.cjs
./djs tests/js/json_import/main.mjs
./djs tests/js/require_esm.cjs | grep -q ERR_REQUIRE_ESM
./djs tests/js/builtin_import.mjs
./djs tests/js/root_escape.mjs; test $? -ne 0
./djs tests/js/missing_module.mjs; test $? -ne 0
./djs tests/js/dynamic_import.mjs
```

**Review gate:** same three-reviewer panel, focused on resolution correctness, cycle behavior, error messages, and path traversal. At most two re-review cycles.

---

### Phase 3 — I/O surface and process semantics

**Goal:** the v0.1 API is complete enough to write a real script: full `fs` promise/callback/sync surface, `process` semantics, unhandled rejections, memory/stack/time limits.

**TODO**

- [x] `fs`: `readFile`, `writeFile`, `appendFile`, `stat`, `readdir`, `mkdir`, `unlink`; promise, callback, and sync variants; `ArrayBuffer`/`Uint8Array`/`DataView`; short-read/short-write loops.
- [x] Node-shaped errors: `code`, `errno`, `path`, `syscall`; `ENOENT`, `EACCES`, `EISDIR`, `ENOTDIR`, `EEXIST`, `ENOTEMPTY`.
- [x] `process`: `argv`, `env`, `cwd`, `exit`, `platform`, `version`, `memoryUsage`.
- [x] Runtime limits: `--memory-limit`, `--stack-size`, `--timeout`; interrupt handler; deadline timer.
- [x] Unhandled rejection timing tests (handled-in-tick vs handled-later).
- [x] Buffer-GC and subarray write tests.
- [x] Long soak test: `scripts/soak.sh` (200k timer cycles + 3000 async reads, heap delta bound); `timer_churn` and the zero-GC unittest remain as narrower checks.

**Definition of done**

```bash
./scripts/integration.sh
dub test
./djs tests/js/fs_errors.js
./djs tests/js/fs_buffers.js
./djs tests/js/rejection_late.js; test $? -ne 0
./djs --timeout 100 tests/js/fixtures/infinite.js; test $? -ne 0
./djs --memory-limit 1048576 tests/js/fixtures/oom.js; test $? -ne 0
./scripts/gate.sh
```

**Review gate:** three reviewers, emphasis on error semantics, resource cleanup, and limit enforcement. At most two re-review cycles.

---

### Phase 4 — Hardening and release

**Goal:** a v0.1 artifact that can be handed to another engineer: reproducible build, documented behavior, measured footprint, no known critical defects.

**TODO**

- [x] ABI gate repeated in `gate.sh` (`JS_NAN_BOXING`/`JS_CHECK_JSVALUE` rejected, `sizeof(JSValue) == 16`).
- [x] Leak gate: ASan/LSan clean across 34 fixtures (`scripts/gate-sanitize.sh`); every named case must resolve.
- [x] Long soak: `scripts/soak.sh` (gate step, heap bound). `JS_DUMP_LEAKS`/Valgrind remain deferred; LSan covers the shipped binary's leak class.
- [x] Differential coverage: `docs/COMPAT.md` records every divergence; `scripts/diff-node.sh` runs 7 normalized Node-vs-DJS cases; `scripts/bench.sh` compares timings.
- [x] Performance baseline in `docs/BENCH.md` (`scripts/bench.sh`): cold start, RSS, `-e` throughput, 1k fs reads.
- [x] Fuzz harness for the C boundary (argument counts/types, malformed modules): 28 cases, clean.
- [x] Docs: README, ARCHITECTURE, D-GUIDE, COMPAT, BENCH; links resolve; no-phase-refs passes.
- [x] Package: release binary, `--version`, third-party notices (QuickJS-NG MIT, libuv MIT), deterministic tarball.
- [x] Archive the release deliverables to the offline storage share and note the path in the work log.
- [x] Final three-reviewer pass (`docs/reviews/round-2-*.md`); no open critical findings after the fix round.

**Definition of done**

```bash
./scripts/bootstrap.sh
dub build --build=release
dub test
./scripts/integration.sh
./scripts/gate.sh
scripts/bench.sh
```

**Review gate:** final three-reviewer pass plus a release checklist; no critical findings; all deferred findings listed with reasons.

---

### Phase 5 — Node package loading (v0.3.0, done)

**Status:** complete for v0.3.0 (exports/imports maps and CJS named-export detection included).

**Goal:** `require("pkg")` and `import "pkg"` work for packages installed by
npm, pnpm or yarn, without DJS implementing a package manager or registry
client. DJS only needs Node's directory-resolution rules.

**Implemented**

- Bare specifiers walk upward from the importing module's directory to the
  project root, probing `<dir>/node_modules/<name>`.
- Scoped packages (`@scope/name`) and package subpaths (`pkg/sub`).
- `package.json` `main`, `type`, and `index.js`/`index.cjs`/`index.mjs`
  fallbacks, reusing the canonical package walk.
- pnpm-style symlinked layouts work as long as the real target stays inside
  the project root (the existing containment rule).
- Real-npm smoke test: `npm install is-number` then
  `require("is-number")(42)` returns `true`; fixture packages cover CJS, ESM,
  scoped, subpath and a transitive dependency.
- ESM imports of bare CJS packages, including named exports detected from
  `exports.x =`, `module.exports.x =`, `module.exports = { x }` and
  `Object.defineProperty(exports, "x", …)`.
- `package.json` `exports`: string and conditional objects, `node`/`import`/
  `require`/`default` conditions, exact subpaths, `*` patterns, and
  exports-authoritative fallback (no `main`/index when an exports map exists).
- `package.json` `imports` for `#specifier` lookups (relative and bare targets).
- Verified with real npm packages: `is-number` (CJS), `escape-string-regexp@5`
  (ESM exports-only) and `uuid`'s exports map (module selection; `uuid` itself
  still needs `crypto`).

**Accepted limitations**

- `browser`/`development`/custom conditions are not active; only `node`,
  `import`, `require` and `default`.
- `node_modules` real paths outside the project root (workspace links), Yarn
  PnP, global installs, optional/peer dependency semantics and native addons
  are out of scope.
- CJS named-export detection is heuristic, like Node's lexer; unusual dynamic
  export patterns may still expose only `default`.
- Packages whose graph needs missing builtins (`util`, `events`, `stream`,
  `crypto`, `http`, …) still fail at that import; a runtime surface gap, not a
  resolver gap.

**Definition of done**

```bash
dub build --build=release
dub test
./scripts/integration.sh        # node_modules_test + node_modules_import
./scripts/gate.sh
# real npm package in a scratch project:
cd /tmp/pkgtest && npm install is-number && djs -e 'console.log(require("is-number")(1))'
```

**Review gate:** resolver edge cases (scoped, subpath, missing entry, root
escape, symlink target, package without main), plus a docs honesty pass on the
unsupported list.

---

### Phase 6 — Permissions (v0.4.0, one release, default deny)

**Status:** implemented for v0.4.0. Core model, CLI, config sets, native fs/env/os
gates, prompts, audit and `process.permission.*` are in place. Known partials:
ignore semantics, module-graph recording, and the post-v0.4 networking gates.

**Decision:** DJS has no active users, so the permission model ships **complete
in one release** instead of the staged opt-in originally sketched in
`docs/PERMISSIONS.md`. The release enables enforcement by default:

- Every script starts with no read, write, env, sys, net, run or ffi access.
- Grants come from `--allow-*` flags and/or `-P[=set]` permission sets in
  `djs.json`.
- `--deny-*` always wins; `-A`/`--allow-all` restores the pre-permission
  behaviour and exists as the explicit escape hatch.
- Prompts, audit logging and `process.permission.*` are part of the same
  release, not a follow-up series.

This is a breaking change to the runtime's defaults. It ships with a README
security section, a COMPAT entry, a ROADMAP status update and a curated
migration note ("add `-A` to keep old behaviour; narrow it grant by grant").

**Goal:** an untrusted script cannot touch a file, environment variable or host
fact outside its grants, and the denial is a catchable, well-shaped JS error.

**Design:** `docs/PERMISSIONS.md` is normative for semantics, CLI shape, config
schema, error shape and the threat model.

**TODO**

- [x] `src/djs/permissions.d` (native, `@nogc` hot path; rules in malloc'd
      memory because `Runtime` is calloc'd): `Perm` enum, `Rule`/`PermissionSet`, allow/deny
      matching with component boundaries, path canonicalisation
      (realpath-deepest-existing + normalised tail), env name and suffix
      wildcard matching, net host/port matching with `*.` wildcards, decision
      cache, audit writer, `PermissionDenied` constructor.
- [x] `src/djs/main.d`: parse `-R/--allow-read`, `-W/--allow-write`,
      `-E/--allow-env`, `-N/--allow-net`, `-S/--allow-sys`, `--allow-run`,
      `--allow-ffi`, `--allow-import`, the `--deny-*` counterparts,
      `-A/--allow-all`, `--no-prompt`, `--config <path>`, `-P[=set]`; support
      repeated flags, `=value` and comma escaping; reject unknown permission
      names; keep `--help` accurate.
- [x] `djs.json`/`djs.jsonc` loader: `std.json` at startup (before the JS
      realm), permissions sets with `default`, boolean/array/object forms,
      `allow`/`deny`/`ignore` rules (ignore only read/env), relative paths
      resolved against the config directory, named-set errors that list
      available sets, config only loaded with `-P`.
- [x] `src/djs/apis/fs.d`: gate all **11** sites — ten sync impls plus
      `startFsWork` — after `getPath`, freeing path/path2/data on denial
      (read/stat/readdir/realpath = read; write/append/unlink/mkdir/rename/
      copy/rm = write; rename/copy check both sides; recursive mkdir checks its
      prefixes; rm checks the root and never follows symlinks). No fs op may
      reach a syscall without a check.
- [x] `src/djs/apis/process.d`: filter inside `processEnv()` (the single
      constructor) and gate `os.homedir`/`os.tmpdir` through the same env
      rules. The prelude Proxy is UX only; DJS has no `setenv`, so document
      `process.env` as a read-only snapshot and do not claim write gating.
- [x] `src/djs/apis/os.d`: convert `hostname`, `release`, `homedir`, `tmpdir`
      and the memory/cpu accessors into native functions that check on every
      call (they are eager strings today). Map to Deno names (`hostname`,
      `osRelease`, `systemMemoryInfo`, `cpus`, `homedir`); leave `platform`,
      `arch`, `type`, `eol`, `devNull`, `endianness` open.
- [ ] Module policy: record the statically linked graph; the entry + graph are
      readable without `--allow-read` and confined to the package root. Gate
      computed imports, absolute specifiers not in the graph, and
      `__djs.requireFrom` on read; stop `projectRootFor` at the entry's owning
      package rather than `/`.
- [x] Prompts: TTY-only, stderr question, `/dev/tty` answer,
      yes-once/no/always-session, deny on EOF, `--no-prompt` and non-TTY fail
      closed.
- [x] Audit: `DJS_AUDIT_PERMISSIONS=<path>` JSONL with
      `v/datetime/permission/value/result`; never log env values or file
      contents; optional `DJS_TRACE_PERMISSIONS=1` stack frames.
- [x] `process.permission.has(scope, reference)` / `.drop(scope, reference)`
      with Node-shaped scopes (`fs.read`, `fs.write`, `env`, `net`, `sys`).
- [x] Errors: sync throws; callback APIs deliver `cb(err)`; promises reject.
      Shape: `name: PermissionDenied`, `code: ERR_ACCESS_DENIED`,
      `permission`, `resource`; message suggests the exact flag.
- [ ] Network/subprocess/FFI: parse and store the rules now; when those APIs
      land they must call the gate from day one. Add the checklist item and a
      grep-based guard (`scripts/check-permissions.sh`) that fails on raw
      socket/fork/dlopen use outside the permission module.
- [x] Tests: matcher matrix; path escapes (`..`, prefix collision, symlink in
      and out, non-existent tails); rename/copy both sides; rm recursive;
      env read/write/enumerate/ignore; os allow/deny per function; config sets,
      CLI override, deny merge, malformed config, missing set; prompts with and
      without TTY; audit line shape; `-A` compatibility; the full existing
      integration suite re-run with `-A` and with zero grants.
- [x] Harness: `integration.sh` gains a `DJS_TEST_FLAGS` slot (default `-A`),
      a second zero-grant pass with an expected-denial list, and goldens for the
      three denial forms, audit JSONL and direct `__djs.*` bypass attempts.
- [x] Docs: README security section + quick start grants, COMPAT default-change
      entry and symlink/TOCTOU caveats, ROADMAP status, PERMISSIONS status
      "implemented", CHANGELOG migration note.
- [ ] Bench: `-A` overhead below 2% on `fs_sync`; scoped checks measured
      separately; cold start regression budget +1 ms.

**Definition of done**

```bash
dub build --build=release
dub test
./scripts/integration.sh          # all existing cases pass with -A
./scripts/gate-permissions.sh     # permission matrix + bypass suite
./scripts/check-permissions.sh    # no ungated syscall path
./scripts/gate.sh                 # all release gates
./djs script.js                   # denied by default, exit non-zero
./djs --allow-read=./data script.js
./djs -A script.js                # legacy behaviour
DJS_AUDIT_PERMISSIONS=audit.jsonl ./djs -A script.js && test -s audit.jsonl
```

**Review gate:** a dedicated security review (adversarial bypass hunt) plus the
normal three-reviewer panel; no critical findings open; every accepted
limitation recorded in COMPAT/PERMISSIONS.

---

### Phase 7 — OS-level sandbox (candidate, not committed)

In-process checks are a seat belt, not a sandbox against native memory-safety
bugs. Research (in `docs/PERMISSIONS.md`) recommends **Landlock** as the first
kernel backstop: unprivileged, dependency-free, and a near one-to-one mapping
from the read/write grants. Shape: `--sandbox=landlock` (opt-in, independent of
`--permissions`), applied in `main.d` before user code while the process is
still single-threaded, rights masked to the running ABI, fail closed with exit
2 if unavailable, and `warn` as the explicit best-effort mode. Rules are
irreversible, so prompts and kernel sandboxing are mutually exclusive. Effort
is ~350–500 lines in `src/djs/sandbox.d` plus tests (about a week). Defer
seccomp to the following release (deny-list + io_uring `ENOSYS`); document
`bwrap`/`nsjail` recipes instead of embedding them because Ubuntu 24.04 blocks
unprivileged user namespaces by default. Nothing in Phase 6 should depend on
this, and `-A` must never silently disable a requested sandbox.

---

## 4. Node parity roadmap (planning, after v0.4.0)

**Parity target:** the parts of Node that automation, CLI tools and small
services actually use — not V8 equivalence, not the whole npm ecosystem's
native surface. Success means a script written against the common core
(`fs`, `path`, `os`, `events`, `stream`, `url`, `util`, `net`, `http`,
`child_process`, `crypto`, `zlib`) runs with small or no changes.

**Non-goals for the parity programme:** JIT performance, N-API/native addons,
the V8 inspector protocol, `cluster`, full `Intl`, WebAssembly, and perfect
error-message/stack parity. Those remain explicit scope decisions, not bugs.

Each phase follows the same discipline as v0.1–v0.3: machine-checkable exit
criteria, integration + differential + sanitizer coverage, docs updated in the
same change, a benchmark delta recorded, and a review round before the tag.

| Phase | Version | Scope | Depends on | Primary exit criteria |
|---|---|---|---|---|
| 6 | v0.4.0 | Permissions, default deny | v0.3.0 | `gate-permissions.sh`; no ungated fs/env/os path; `-A` restores legacy behaviour |
| 8 | v0.5.0 **done** | `events`, `stream` core (`Readable`/`Writable`/`Transform`/`pipeline`), `url`, `util`, `timers/promises`, `structuredClone`, `AbortController`, fs streams | 6 | Node differential cases for each module; stream backpressure/error tests; permissions on fs streams |
| 9 | v0.6.0 **done** | fs depth: fd APIs (`open`/`read`/`write`/`close`), `chmod`/`chown`/`link`/`symlink`/`readlink`, richer `stat`, `fs.promises` extension | 8 | fd ownership; dangling-symlink permission tests; 82 integration; fd LSan case |
| 10 | v0.7.0 **done (plain)** | Networking client: `net`, `dns`, `http` client, `fetch(http://)`; `tls`/`https` explicitly deferred | 8 | loopback gate (`gate-net.sh`), `net` permission gates, chunked/content-length parsing; TLS tests deferred |
| 11 | v0.8.0 **done** | `child_process` (`spawn`/`spawnSync`/`execSync`/`execFileSync`), `process.stdin`/`stdout`/`stderr` streams, signal handlers | 8, 10 | run permission matrix; deadlock/EOF/stale-id regressions; stdin/signal tests; diff for exit codes/stdio |
| 12 | v0.9.0 **done** | `crypto` (hash/HMAC/random/`randomUUID`/`timingSafeEqual`), `zlib` (gzip/deflate), compression streams | 8, 10 | known-answer vectors; binary-input and stream round-trip tests; 256 MiB output cap; OpenSSL/zlib pins and licences |
| 12a | v0.9.1 (inserted) **done** | TLS client and HTTPS transport (`tls.connect`, `https.request`, `fetch(https://)`) | 12 | loopback TLS handshake; certificate verification failure is an error; HTTPS GET and fetch through the HTTP client |
| 13 | v0.10.0 **done** | `net.Server`, `http` server, `dgram`, `readline`; `worker_threads` deferral (ADR 0002) | 10, 11 | HTTP server subset (GET/POST/headers/404), loopback `dgram`, `readline` pipe test, listen/dgram permission denial, ADR with measurements |
| 14 | v0.10.1 **done** | Node compatibility kernel: V8-style stack CallSites, callable `stream`, mixin-safe `EventEmitter`, main-module paths, fs stream classes, `tty`/`querystring`/`string_decoder`, Buffer statics; Express 4 target | 13 | Express app with static + JSON + params + POST body passes end to end |
| 15 | v0.11.0 **done** | Node partials batch 1: `process.hrtime/uptime/kill`, `os.uptime/loadavg/networkInterfaces/userInfo`, `fs.statfs`, dgram socket options | 14 | native + facade tests; statfs, interfaces, multicast membership, signal 0 |
| 16 | v0.11.1 **done** | Node partials batch 2 + HTTP hardening: child `timeout`/`maxBuffer`, keep-alive, pipelining, chunked requests, HEAD, 100-continue, deadlines, graceful close, cpuUsage/umask, chunked fs reads | 15 | keep-alive reuse, pipelined order, chunked body, 100-continue, HEAD, header timeout, spawn timeout/maxBuffer |
| 17 | v0.11.2 **done** | HTTPS server + TLS server options (`cert`/`key`); net IPv6 moved again to v0.12.1 (needs the address-family refactor across DNS/connect/bind/getsockname) | 16 | `https.createServer` served to `https.get`; TLS handshake + HTTP request over it |
| 18 | v0.12.0 **done** | Crypto breadth: AES-GCM/CBC ciphers, pbkdf2/hkdf/scrypt; `sign`/`verify`/key objects/WebCrypto moved to v0.12.1 | 17 | NIST/RFC known-answer vectors, GCM tamper rejection |
| 19 | v0.12.1 **done** | net IPv6 (client/listener/lookup), `perf_hooks.performance`, `os.constants`/`machine`/`availableParallelism` | 18 | IPv6 loopback request, lookup family, perf/os assertions |
| 20 | v0.12.2 **done** | `crypto.sign`/`verify` and `KeyObject` (RSA/EC PEM) | 19 | RSA-SHA256 round trip, tamper rejection, KeyObject paths |
| 21 | v0.12.3 **done** | `fs.watch` over inotify (change/rename, close) | 20 | create a file in a watched dir; filename reported |
| 22 | v0.12.4 **done** | `dns.resolve4/6` and `resolve(A/AAAA)` | 21 | localhost A/AAAA arrays, ENOTSUP for other types |
| 23 | v0.12.5 **done** | `fs.opendir`/`Dir`, `fs.watchFile`/`unwatchFile` polling | 22 | directory iteration and stat-poll change event |
| 24 | v0.12.6 **done** | `vm` over a fresh QuickJS context (`runInNewContext`, `Script`) | 23 | isolated context has no process/require; JSON result round trip |
| 25 | v0.12.7 **done** | Web Streams (`ReadableStream`/`WritableStream`/`TransformStream`/`pipeTo`) | 24 | chunk flow, pipe, transform, pull-driven source |
| 26 | v0.13.0 **done** | WebSocket client + server (`djs:ws`), handshake/frames/close/ping | 25 | echo round trip, close code 1000 |
| 27 | v0.13.1 **done** | HTTP/2 h2c client+server: frames, HPACK (Huffman decode), multiplexed streams | 26 | self h2 round trip; Node http2 interop both directions |
| 28 | v0.13.2 **done** | Fetch primitives (`Request`, full `Headers`) + Express/Hono HTMX example apps | 27 | both example apps pass curl + browser smoke |
| 29 | v0.13.3 **done** | `fetch` streaming body, `FormData`, iterable `Headers`; DeepSeek OpenAI-SDK example | 28 | real DeepSeek completion + stream |
| 30 | v0.13.4 **done** | Incremental HTTP response parsing (true token streaming) | 29 | first SSE event arrives before the last |
| 31 | v0.13.5 **done** | `assert`, `module`, `stream/promises` builtins + full ESM facades | 30 | assert/module/stream tests green in CJS and ESM |
| 32 | v0.13.6 **done** | Buffer completeness, module resolution, stream interop | 31 | buffer_full + module_resolve + stream_web_interop goldens |
| 33 | v0.13.7 | Stream interop (`toWeb`/`fromWeb`, object mode, pipeline cleanup) | 32 | `undici` chunked fetch works |
| 34 | v0.13.7 **done** | Crypto core, HTTP `upgrade`, Blob/File/FormData uploads | 32 | crypto_core + http_upgrade + blob_formdata goldens |
| 35 | v0.13.8 **done** | Brotli + fetch content decoding | 34 | fetch_decode golden |
| 36 | v0.13.9 **done** | WebCrypto `subtle` core | 34 | webcrypto golden |
| 37 | — | `async_hooks`/AsyncLocalStorage — **out of scope** (needs engine async context) | 33 | documented limitation |
| 38 | v0.14.0 **done** | DNS breadth (Mx/Txt/Srv/Cname/Ns/Soa/Ptr) | 35 | dns_records golden |
| 39 | v0.14.2 **done** | Cleanup: entry wrapping, upgrade tracking, toWeb backpressure, helper dedupe | 36 | entry_scope + upgrade_close goldens |
| 39b | v0.14.3 **done** | Prelude split into seven concatenated modules | 36 | byte-identical rejoin + full gate |
| 39c | v0.14.4 **done** | Stream state ownership + module diagnostics | 36 | ws/stream goldens |
| 39a | v0.14.1 **done** | Compat harness: real `ws` + `jose` in the gate | 36 | gate-compat green |
| 40 | v0.15.0 **done** | `child_process`: async `exec`/`execFile`, timeout, maxBuffer | 32 | child_async golden |
| 41 | v0.15.1 **done** | `fs` breadth: `cp`/`cpSync`, `readv`/`writev`, `openAsBlob`, recursive watch | 32 | cp tree + vector I/O + watch events |
| 42 | v0.15.2 **done** | diagnostics/perf long tail + global `EventSource` | — | imports succeed; SSE golden |
| 43 | v0.15.3 **done** | `fork` IPC + `process.execPath` | 40 | fork_ipc round-trip |
| 43b | v0.15.4 **done** | Native `spawn` `options.env`; fork IPC moves to env (fd-3 still deferred) | 43 | child_env + fork_ipc goldens |
| 43c | v0.16.1 | fd-3 IPC + explicit permission inheritance | 43 | fork without loopback socket |
| 44 | v0.15.5 **done** | TLS client custom CA/cert/key + ALPN advertisement | 36 | trusted CA vs system-store rejection |
| 44b | v0.15.6 **done** | Server mTLS (`caFile` + `requestCert`) | 44 | tls_mtls golden |
| 44c | v0.15.7 **done** | Server ALPN selection + HTTP/2 over TLS | 44 | tls_alpn + http2_tls goldens |
| 45 | v0.15.8 **done** | `cluster` over fork IPC + `SO_REUSEPORT` | 43 | cluster_basic golden |
| 46 | v0.15.9 **done** | `worker_threads` API shim over child processes | 40 | worker_threads golden |
| 46b | research | True threads / shared memory (`SharedArrayBuffer`, `Atomics`) | — | design spike before implementation |
| 46c | v0.16.0 **done** | Core API long tail (`getRandomValues`, `parseArgs`, `fs.glob`, `timers`, URL helpers) | 40 | api_long_tail golden |
| 46d | v0.16.1 **done** | `stream/consumers` + `readline/promises` | 40 | consumers/readline golden |
| 47 | v0.17.0 | N-API addon epic (scope gate first) | 43 | one native addon loads (`bcrypt` or `better-sqlite3`) |
| 48 | v1.0.0 | Ports (macOS/Windows), source maps, embedding header, packaging/ABI policy | all | cross-platform gates; no tag before they pass |
| 13 | v1.0.0 | macOS/Windows ports, source maps/diagnostics, embedding C header, packaging and ABI policy | all | CI matrix on three platforms; embedding example; stable public header; release checklist |

**Sequencing rationale**

- Permissions land first because every later network/subprocess/FFI API must be
  gated from its first commit; retrofitting gates is how bypasses appear.
- `events` and `stream` are the dependency spine for fs streams, HTTP, child
  stdio and compression; building them before networking avoids a second
  rewrite of the async surface.
- `url`/`util`/`timers/promises` are small and unblock compatibility tests for
  everything above them.
- Networking splits client (v0.7) from server (v0.10) so TLS and permission
  semantics settle before accepting connections.
- `crypto`/`zlib` are backend work, not API design; schedule them after the
  stream model is stable.
- Workers are evaluated last because the single-loop design is deliberate; a
  worker must be a separate runtime with explicit message copying, not a
  thread sharing JS values.

**Parity scorecard (target after v0.10)**

Core modules: `fs`, `path`, `os`, `events`, `stream`, `url`, `util`, `net`,
`tls`, `http`, `https`, `dns`, `child_process`, `crypto`, `zlib`, `timers`,
`buffer`, `module` — implemented at the documented subset. Still out:
`cluster`, N-API, inspector, full `Intl`, WASM, JIT.

---

## 5. Work log

Append-only. Each entry: date, item, status, evidence (command output path or commit), notes.

| Date | Item | Status | Evidence | Notes |
|---|---|---|---|---|
| 2026-10-20 | Repo skeleton, BRIEF, README, pins, bootstrap | done | `scripts/bootstrap.sh` exits 0; `qjs -e` prints ok | LDC 1.36, DUB 1.36, libuv 1.48, QuickJS-NG v0.17.0 |
| 2026-10-20 | Architecture and D guide drafts | done | `docs/ARCHITECTURE.md`, `docs/D-GUIDE.md` | Revised against research memos |
| 2026-10-20 | Research memos (D idioms, QuickJS embedding) | done | `docs/research/*.md` | Toolchain-verified findings |
| 2026-10-20 | Document review round | done | `docs/reviews/doc-round-1-*.md`; `docs/REVIEWS.md` | 13 critical, 28 important, 7 minor; all critical fixed |
| 2026-10-21 | Implementation round 1 code (Phase 1) | done | commit `64acfd2`; `dub build` 0; `dub test` 3 modules; `integration.sh` 26/26 | Vertical slice |
| 2026-10-21 | Implementation round 1 review | done | `docs/reviews/round-1-{general,adversarial,architecture}.md` | 44 findings: 2 critical, 20 important, 22 minor |
| 2026-10-21 | Round-1 fix list merged into §3.1 | done | `docs/REVIEWS.md` | 28 merged fixes; R1-10/R1-28 accepted deviations |
| 2026-10-21 | Round-1 fixes applied | done | `scripts/gate.sh` 6/6; integration 44/44; sanitizer 19/19 | teardown, exit policy, timers, fs, boundary guard, `dub test` target |
| 2026-10-21 | Phase 2 modules | done | `tests/js/{esm_chain,cjs_cycle,json_import,builtin_import,root_escape,dynamic_import,cjs_interop}` | one classifier; ESM loader with import.meta; CJS cache/cycles |
| 2026-10-21 | Phase 3 I/O + limits | done | `tests/js/{fs_meta,fs_buffers,fs_errors2,fs_limits,rejection_late}`; `--timeout/--memory-limit/--stack-size` | full fs surface; `EFBIG` caps; memoryUsage |
| 2026-10-21 | Phase 4 hardening | done | `docs/COMPAT.md`, `docs/BENCH.md`, `scripts/fuzz.sh` 28/28 | package + docs + bench complete; panel then run |
| 2026-10-21 | Release-candidate panel (rounds 2+3 scope) | done | `docs/reviews/round-2-{general,adversarial,architecture}.md`; 36 findings, 13 blockers | all blockers reproduced then fixed |
| 2026-10-21 | Blocker fixes + regressions | done | integration 60/60, sanitizer 27/27, fuzz 28/28 | require/fs API identity, module-bound require, NUL rejection, cache eviction, JSON.parse, deadline timer, entry root, ABI normalizer, gate honesty |
| 2026-10-21 | Release candidate (refreshed) | done | tag `v0.1.0`; `dist/djs-v0.1.0-linux-x86_64.tar.gz`; archived to offline storage | 8.1 ms cold start, 7.2 MiB RSS; gate 6/6 |
| 2026-10-21 | v0.2.0 surface | done | `Buffer`, `path`, `os`, fs rename/copyFile/rm/realpath/recursive mkdir, write encodings, `setImmediate`/`nextTick`, encoded `import.meta.url`, `arrayBuffers` | 67 integration cases, 7 diff cases, soak heap delta 3 KiB |
| 2026-10-21 | v0.2.0 gates | done | `scripts/diff-node.sh`, `scripts/soak.sh`, gate 8/8 | ASan/LSan 34 fixtures |
| 2026-10-21 | v0.2.0 review + fix round | done | `docs/reviews/round-3-*.md`, `docs/REVIEWS.md` R3-01…R3-12 | 36 findings; copyFile/readEncodings/arrayBuffers blockers fixed; 70 integration, 37 sanitizer, 7 diff |
| 2026-10-21 | Permissions design review | done | `docs/PERMISSIONS.md` (revised), Phase 6 | Native-only enforcement, per-access os, env in `processEnv`, symlink/async contracts; single-release default-deny |
| 2026-10-21 | OS sandbox research | done | Phase 7; `docs/PERMISSIONS.md` sandbox section | Landlock recommended (~1 week); seccomp/namespaces deferred |
| 2026-10-21 | Node package loading (v0.3.0) | done | `modules/{resolve,json,pkgexports,cjsnames}.d`; 74 integration cases; real `is-number`, `escape-string-regexp@5` and `uuid` selection smoke | exports/imports, conditions, patterns, CJS named exports, pnpm symlinks |
| 2026-10-21 | Node parity roadmap + plan/architecture audit | done | `docs/PLAN.md` §4; `docs/ROADMAP.md` intent column; `docs/ARCHITECTURE.md` stale-claim fixes | v0.5–v1.0 phased; permissions v0.4 remains next |
| 2026-10-21 | Core modules v0.5.0 | done | `events`, `stream`, `url`, `util`, `timers/promises`, `structuredClone`, `AbortController`, fs streams; 80 integration, 47 sanitizer, 8 diff | prelude polyfills; permissions unchanged |
| 2026-10-21 | Permissions v0.4.0 | done | `permissions.d`, CLI, fs/env/os gates, `gate-permissions.sh` (20 checks); gate 9/9; integration 74, sanitizer 41 | default deny; `-A`; config sets, prompts, audit, `process.permission.*`; ignore/module-graph partials documented |
| 2026-10-21 | fs depth v0.6.0 | done | fd APIs, `FileHandle`, chmod/chown/links, richer stat, `buffer`, text codecs; gate 9/9, integration 82, sanitizer 49 | review fixed permission/flag escapes and fd ownership; tag `v0.6.0` |
| 2026-10-21 | Networking v0.7.0 | done (plain) | `net` Duplex client, async `uv_getaddrinfo` DNS, plain HTTP client, `fetch(http://)`; gate 10/10, integration 83, sanitizer 50, diff 9, net gate 7 | TLS deferred to v0.9; review fixed end/error/write-queue/fd/DNS blockers; tag `v0.7.0` |
| 2026-10-22 | assert/module/stream promises (v0.13.5) | done | scorecard's top three gaps closed |
| 2026-10-22 | Incremental HTTP responses (v0.13.4) | done | first DeepSeek token at 1.0 s, stream total 1.8 s |
| 2026-10-22 | DeepSeek SDK example + fetch streaming (v0.13.3) | done | real API calls, SSE chunks; client still buffers responses |
| 2026-10-22 | Express/Hono examples + fetch primitives (v0.13.2) | done | HTMX polling UI verified in Chromium for both frameworks; Request/Headers gaps fixed |
| 2026-10-22 | HTTP/2 h2c (v0.13.1) | done | frame codec, HPACK static/dynamic + Huffman decode, client/server; Node interop verified both ways; workers moved to v0.13.2 |
| 2026-10-22 | WebSocket (v0.13.0) | done | ws client+server over net with handshake/frames; HTTP/2 moved to v0.13.1, workers to v0.13.2 |
| 2026-10-22 | Web Streams (v0.12.7) | done | readable/writable/transform, pipeTo, pull-driven backpressure |
| 2026-10-22 | vm contexts (v0.12.6) | done | fresh QuickJS context per runInNewContext, JSON boundary; Web Streams moved to v0.12.7 |
| 2026-10-22 | fs.opendir + watchFile (v0.12.5) | done | eager Dir wrapper, polling StatWatcher |
| 2026-10-22 | dns.resolve A/AAAA (v0.12.4) | done | deduplicated arrays from getaddrinfo; other record types deferred |
| 2026-10-22 | fs.watch (v0.12.3) | done | inotify watch with change/rename events and close; batch-3 leftovers to v0.12.4 |
| 2026-10-22 | Signatures (v0.12.2) | done | RSA/EC PEM sign/verify, KeyObject; batch-3 remainder moved to v0.12.3 |
| 2026-10-22 | net IPv6 + perf_hooks + os extras (v0.12.1) | done | AF_UNSPEC lookup, dual-family connect, IPv6 listener, host-derived address family; batch-3 remainder moved to v0.12.2 |
| 2026-10-22 | Crypto breadth (v0.12.0) | done | AES-128/256 CBC+GCM with AAD/tags, pbkdf2, hkdf (HMAC-built), scrypt; sign/verify moved to v0.12.1 |
| 2026-10-22 | HTTPS server (v0.11.2) | done | `tls.createServer`/`https.createServer` with PEM cert/key, blocking accept handshake, same HTTP state machine; IPv6 moved to v0.12.1 |
| 2026-10-22 | HTTP hardening + partials batch 2 (v0.11.1) | done | keep-alive/pipelining/chunked/HEAD/100-continue/timeouts/drain; child timeout+maxBuffer; cpuUsage/umask; chunked fs reads; IPv6 moved to v0.11.2 |
| 2026-10-22 | Node partials batch 1 (v0.11.0) | done | `process.hrtime/uptime/kill`, `os.uptime/loadavg/networkInterfaces/userInfo`, `fs.statfs`, dgram broadcast/TTL/membership; leftover partials scheduled v0.11.1 and v0.12.1 |
| 2026-10-22 | Node compatibility kernel + Express target (v0.10.1) | done | stack CallSites, callable `stream`, EventEmitter mixin safety, main-module paths, fs stream classes, `tty`/`querystring`/`string_decoder`; Express 4 static/JSON/params/POST passes; gate adds `express` step |
| 2026-10-22 | net server, HTTP server, dgram, readline (v0.10.0) | done | listener/accept in `net.d`, HTTP parser/response in the prelude, `dgram.d`, `readline`, worker stub + ADR 0002; integration 95, sanitize 59, permissions 42, gate 10/10 | review fixed listener use-after-free, stale socket ids (generation-tagged), HTTP client half-close truncation, duplicate handler dispatch; worker_threads deferred with measurements |
| 2026-10-22 | TLS client (v0.9.1, inserted) | done | `tls.d` worker-thread handshake + loop I/O, `https`/`fetch(https)` transport; integration 92, sanitize 55, gate 10/10 | review fixed blocking-descriptor loop freeze, uninitialized addrinfo, no connect timeout, stringified binary reads; client-only, no cert options/ALPN |
| 2026-10-22 | crypto + zlib (v0.9.0) | done | `crypto.d` (EVP digests, HMAC, RAND, timingSafeEqual), `zlib.d` (sync + Transform streams); integration 90, sanitize 54, diff 11, gate 10/10 | review fixed Buffer string-coercion, ignored `Transform.final`, unbounded inflate, per-runtime slot ownership; insert v0.9.1 for TLS |
| 2026-10-21 | child_process + process I/O review and recovery (v0.8.0) | done | adversarial review; fixes in `child.d`, `signals.d`, `stdio.d`, `prelude.js`, `permissions.d`, gate scripts; `gate-permissions.sh` 39 checks, integration 88, diff 10, sanitizer child/stdio cases clean, unittest 3 | fixed shell heap overflow/invalid frees, blocking-pipe loop freeze, sync stdin and stdout/stderr deadlocks, stale ids, sibling fd inheritance, zombie and pre-fork exhaustion, silent `cwd` failure; added `process.stdin`/`stdout`/`stderr` and signal handlers; remaining: `timeout`/`maxBuffer`, binary stdout, `process.kill` |

---

## 6. Risks, stop conditions, and open questions

**Risks**

- **Interpreter performance:** QuickJS is not a JIT. If the target workload is CPU-bound, DJS is the wrong tool. Stop and reassess rather than adding a JIT.
- **Boundary bugs:** refcount mistakes and exceptions through C are the most likely crash sources. Mitigate with ownership rules, ASan/Valgrind, and adversarial review.
- **Scope creep:** HTTP, npm, workers, and Intl are attractive and out of scope. Defer behind seams.
- **D toolchain churn:** pin LDC and QuickJS; no floating dependencies.
- **"It compiles" trap:** a green build is not a working runtime. Gates are behavioral and produce evidence.

**Stop conditions**

- A critical finding survives three fix rounds.
- The C boundary cannot be made memory-safe with the chosen binding approach (e.g., struct layout/ABI mismatch that cannot be pinned).
- The pinned QuickJS-NG version lacks an API the architecture depends on and no stable alternative exists.
- The build cannot be made reproducible on a clean checkout.

**Resolved during research**

- **Module loader API:** `JS_SetModuleLoaderFunc2` exists in v0.17.0 and is the right call; it takes five arguments and carries import attributes (`with { type: "json" }`) plus a `check_attrs` callback.
- **`JS_EnqueueJob`:** exported in v0.17.0. `queueMicrotask` uses it directly; no resolved-promise trampoline.
- **Microtask keep-alive:** pending jobs do not ref libuv. DJS uses `uv_prepare` + `uv_idle` so a long promise chain cannot let the loop exit.
- **`JS_GetException` vs `JS_HasException`:** `JS_GetException` takes and clears; `JS_HasException` peeks.

**Still open**

- `Buffer`: resolved in v0.2 — `readFile` returns a `Buffer` (Uint8Array subclass) and the class covers the common API; numeric helpers/pooling remain absent (ROADMAP).
- `process.env` mutation: the object is a mutable snapshot; assignments do not reach `environ` and are visible to subsequent JS reads only. Documented in COMPAT.

---

## 6. References

- `BRIEF.md` — scope, non-goals, engineering rules.
- `docs/ARCHITECTURE.md` — design, ADRs, boundary rules, risks.
- `docs/D-GUIDE.md` — D style, attributes, C interop, testing.
- `docs/PINS.md` — toolchain and engine pins.
- `docs/REVIEWS.md` — review log and dispositions.
- `docs/COMPAT.md`, `docs/BENCH.md` — divergence and performance records.
- `docs/research/d-idioms.md`, `docs/research/quickjs-embedding.md` — research memos.
- QuickJS-NG: <https://github.com/quickjs-ng/quickjs> · QuickJS: <https://bellard.org/quickjs/>
- libuv: <https://docs.libuv.org/>
- D language: <https://dlang.org/> · DUB: <https://dub.pm/>
