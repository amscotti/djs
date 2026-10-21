# Tier 2 architecture review — after v0.15.3

Scope: v0.15.0 child_process breadth, v0.15.1 fs breadth, v0.15.2
diagnostics/perf/EventSource, v0.15.3 fork IPC. V8 items are excluded by
decision and need their own research phase.

## What Tier 2 changed

- Async process control moved from sync-only helpers to `exec`/`execFile` with
  timeout/maxBuffer, then `fork` IPC.
- fs gained tree copy, vector I/O, `openAsBlob` and recursive watch.
- The diagnostics surface APM tools import now exists, plus a real SSE client.
- `spawn`/`fork` still run through the same `ChildProcess` and registry slots;
  no second process model was introduced.

## Findings

| # | Severity | Finding | Impact | Recommendation |
|---|---|---|---|---|
| 1 | high | native async `spawn` ignores `options.env` and has no fd-3 pipe | fork needs a loopback socket + argv flag; child environments cannot be controlled | next release: extend the native child ABI (env array, optional IPC fd) before adding cluster |
| 2 | high | fork auto-adds `--allow-net` to the child | a restricted parent can spawn a child with network access | define permission inheritance explicitly; at minimum document it and add a test |
| 3 | high | `cluster` and `worker_threads` remain absent/stub | PM2-style serving, Jest/Vitest workers still blocked | keep them as planned rows, cluster after native child ABI |
| 4 | medium | docs drift: duplicate plan rows, `COMPARISON.md` stale on WebSocket/TLS | planning from docs gives wrong priorities | re-run the API probe and refresh both docs before the next feature row |
| 5 | medium | prelude modules share one IIFE scope and load order | hidden coupling; moving a function between files can change initialization | document ownership per module; defer dependency-based split |
| 6 | medium | fork test covers the happy path only | token rejection, disconnect and queued sends are untested | add failure-path tests before cluster |
| 7 | medium | TLS is still client-only, no ALPN/client certs/HTTP-2 TLS | gRPC/mTLS APIs remain blocked | v0.15.5 row unchanged; needs an OpenSSL context-option pass |
| 8 | low | `PerformanceObserver` accepts but never dispatches; EventSource ignores `Last-Event-ID` | APM correlation and resumable SSE are approximate | document as limitations; fix when an app needs them |

## Alignment with the project's principles

- Still a runtime, not a Node clone: the fork transport is an explicit
  implementation compromise, documented rather than hidden.
- No QuickJS patch was introduced; `async_hooks` stays out of scope.
- Every release above is gate-backed (14/14) with a golden and a review.
- The C boundary convention held: all new work is prelude JavaScript or small
  `@nogc nothrow` natives (`uv_exepath`).

## Maintainability assessment

The prelude split materially improved reviewability, but the codebase now has
four growth fronts at once: JS prelude, D API bindings, module-loader wiring,
and the test/golden matrix. Three concrete risks:

1. **Workaround debt.** Fork IPC is the first feature built around a missing
   native capability. If `options.env`/fd 3 are not added next, cluster and
   worker work will stack more workarounds on it.
2. **Permission semantics.** Auto-granting `--allow-net` to fork children is a
   policy decision made in passing. It needs an explicit rule and a test.
3. **Documentation as planning input.** The duplicated plan rows and stale
   comparison table show docs are not gated. A cheap doc check (unique row
   numbers, no version that does not exist) would prevent this.

None of these are release blockers for v0.15.3, but 1 and 2 should be resolved
before `cluster`.

## Recommended order

1. v0.15.4 — native `spawn` `options.env` + optional fd-3 IPC (removes the
   fork workaround; defines permission inheritance).
2. v0.15.5 — TLS ALPN, client certs/custom CA, HTTP/2 over TLS.
3. v0.15.6 — `cluster` over the corrected fork IPC.
4. v0.16.0 — `worker_threads` with an isolated runtime per worker.
5. v0.17.0 — N-API scope gate (XL; decide minimal subset vs full ABI).
6. V8/`inspector` — separate research phase, no implementation yet.

## Update after v0.15.7

### Resolved since the first pass

- `spawn` now honours `options.env` (v0.15.4), and fork discovers its IPC
  channel through the environment instead of a visible argv flag.
- TLS client custom CA, client certificates and ALPN advertisement landed in
  v0.15.5; server-side client-certificate verification in v0.15.6; server ALPN
  selection and HTTP/2 over TLS in v0.15.7.
- The TLS row no longer blocks mTLS APIs or secure gRPC-style transports.

### Still open

| # | Severity | Finding | Notes |
|---|---|---|---|
| 1 | high | fd-3 IPC is still not implemented | fork keeps the loopback socket; cluster handle passing needs native fd wrapping |
| 2 | high | `cluster` and `worker_threads` remain absent/stub | highest remaining ecosystem gap after TLS |
| 3 | medium | fork grants `--allow-net`/`--allow-env` unconditionally | permission inheritance policy still unresolved |
| 4 | medium | ALPN server preference uses a static window | safe because `SSL_accept` is synchronous; per-context ex-data needed for concurrent native handshakes |
| 5 | medium | N-API is an XL epic with no scope decision | keeps Prisma/sharp/better-sqlite3 out |
| 6 | low | test TLS private keys are committed | acceptable for self-signed fixtures, but should be labelled test-only |

### Maintainability verdict

The release discipline held: every row above has a golden, a review and a green
14-step gate, and no QuickJS patch was required. The codebase is still
maintainable, but the next phase should not stack more fork workarounds:
either implement fd-3/permission inheritance, or explicitly decide that
loopback IPC is the permanent design and remove the fd-3 row from the plan.
`cluster` and `worker_threads` are the remaining high-impact gaps; N-API and
V8/inspector should stay separate research epics.

## Update after v0.15.8

`cluster` is no longer missing: workers fork the current entry and share the
listening port through `SO_REUSEPORT`, with `process.pid` added for cluster
code. That closes the "PM2-style serving" gap functionally, but not
semantically: there is no round-robin scheduler, no shared-handle handoff and
no graceful reload.

Remaining high-impact work is now `worker_threads` and N-API. Both are larger
than any release in this phase and should not be improvised:

- `worker_threads` needs either an isolated runtime per thread or an explicit
  child-process-backed shim; the shim would not provide `SharedArrayBuffer` or
  true `MessagePort` semantics.
- N-API needs a scope decision (minimal addon ABI vs full surface).
- fd-3 IPC remains an implementation debt behind fork/cluster; either fund it
  or retire the row and document loopback IPC as the design.

The architecture remains maintainable: nine Tier 2 releases, all with goldens
and gate coverage, no QuickJS patches, and the public API kept Node-shaped
even where the transport differs.

## Update after v0.15.9

`worker_threads` now exists as a child-process-backed API shim: file and eval
workers, `workerData`, `parentPort`, messages, `terminate` and same-process
`MessageChannel`. That unblocks libraries that only need the worker API shape,
but it is **not** a thread implementation. Code that depends on shared memory,
`Atomics`, `SharedArrayBuffer`, transferable objects or true parallel CPU
execution will not work; the plan keeps a separate research row for real
threads rather than claiming parity.

### Tier 2 status

Implemented in this phase: child_process breadth (exec/execFile/fork IPC),
fs breadth, diagnostics/perf/EventSource, TLS client CA/certs/ALPN, server
mTLS, HTTP/2 over TLS, cluster, and the worker_threads shim. Every release is
tagged, packaged, golden-tested and gate-green (14/14).

Not implemented, and not hidden:

- N-API addons (XL epic; scope decision still required)
- true threads/shared memory (research row)
- fd-3 IPC and explicit permission inheritance (fork/cluster use loopback IPC
  and auto-grant `--allow-net`/`--allow-listen`/`--allow-env`)
- V8/`inspector` (deferred by user to a separate research phase)
- `async_hooks` (engine-level limitation, not supported by decision)

### Maintainability conclusion

The runtime is in a maintainable position for this phase: the prelude remains
split by concern, native additions are localized (`process.pid`/`execPath`,
`execvpe`, TLS options, `SO_REUSEPORT`), and fork/cluster/worker share one
process model rather than three. The largest residual risk is semantic
overstatement: several APIs are Node-shaped but process-backed. Documentation
and review files state those limits explicitly; future work should fund fd-3
and true threads before advertising full worker/cluster parity.

## Update after v0.16.0

The remaining Tier 2 surface work was a core-API long tail: `process.ppid`,
`process.title`, `crypto.getRandomValues`, `AbortSignal.any`, `util.parseArgs`,
`util.styleText`, URL file conversion, `fs.glob`/`globSync`, and the `timers`
builtin. The gate caught a nondeterministic `worker_threads` golden (two
workers emitting in varying order); the test now sequences file and eval
workers explicitly. Integration is 138/138 and gate 14/14.

This closes the implementable Tier 2 breadth list. What remains is not more of
the same:

| Item | Why it is not next | Needed decision |
|---|---|---|
| N-API addons | XL native ABI epic; cannot be approximated safely in JS | minimal subset (crypto/sqlite-shaped) vs broad ABI |
| true threads/shared memory | requires per-thread runtimes or engine work; current worker_threads is a process shim | fund a design spike, or accept the shim and document no `SharedArrayBuffer` |
| fd-3 IPC | removes loopback/token transport and narrows permission grants | fund native fd wrapping, or retire the row permanently |
| V8/`inspector` | explicitly deferred to a separate research phase | research first, no implementation now |
| `async_hooks` | engine limitation; no QuickJS patch allowed | remains unsupported by decision |

Maintainability remains sound: localized native changes, golden-backed
releases, and explicit residual notes. The project should not start N-API or
true threads without a scope decision; doing so opportunistically would create
the largest unmaintainable surface in the runtime.

## Update after v0.16.1

Two high-frequency subpath imports were added without new native surface:
`stream/consumers` (buffer/text/json/arrayBuffer/blob) and
`readline/promises` (Promise `question`, async line iteration). They are thin
wrappers over the existing stream/readline implementations, so the
maintainability cost is low. The remaining Tier 2 items are unchanged: N-API,
true threads/shared memory, fd-3 IPC, V8/inspector research, and the
engine-limited `async_hooks`. None should start without an explicit scope
decision.

## Performance baseline (v0.16.1)

Measured against Node v26.7 on the same 4-core host (`docs/BENCHMARKS.md`):
startup is at parity (39.7 ms vs 40.1 ms); SHA-256 is 1.9× slower, JSON 4.5×,
string work 5×, and Buffer numeric access 31×. HTTP throughput is 8.0% of Node
for a raw server and 14.6% for the same Express app.

This is a normal cost profile for a JS-implemented runtime, but it sets
priorities: Buffer numeric accessors are the largest measured single lever and
feed HTTP parsing and database drivers. Do not chase raw HTTP parity before
profiling; the benchmark harness is committed so changes can be measured
rather than guessed.
