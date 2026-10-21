# Roadmap — what DJS does not have

**Status: v0.16.2.** This file is the inventory of capabilities that are absent
outright: they fail loudly, or are not exposed at all. Differences *inside* an
implemented API are in [`COMPAT.md`](COMPAT.md); per-module breadth is in
[`COMPATIBILITY-SCORE.md`](COMPATIBILITY-SCORE.md). See
[`README.md`](README.md) for which documents are current and which are
historical.

Legend: **no** = scope decision, not a bug report · **1.0** = planned for the
1.0 programme · **candidate** = worth doing, not committed.

## Scope decisions

| Capability | Why it is out of scope |
|---|---|
| `Intl` / ECMA-402 | QuickJS-NG builds without ICU. Adding it is a large dependency; formatters can be a guest polyfill. This is the single largest load-time blocker in the package corpus (5 of 64 packages in the current sample). |
| WebAssembly | QuickJS has no WASM engine; embedding one is a different product. |
| N-API / native `.node` addons | The C boundary is private by design. Ceiling for Prisma/sharp/bcrypt-class apps. |
| Inspector / CDP / debugger | Needs engine hooks. Source maps in stack traces are the useful 90%. |
| Profiler / coverage | Out of scope for a glue runtime. |
| JIT | QuickJS is an interpreter; accepted trade (ADR-001). |
| Shared-memory threads | `worker_threads` is a child-process shim; no `SharedArrayBuffer` transfer, no cross-worker `Atomics` coordination. |
| `require()` of ESM | Node 22 allows it for synchronous graphs; DJS throws `ERR_REQUIRE_ESM`. |
| Imports outside the entry package root | Deliberate containment (monorepo hoisting, `npm link`, global installs do not resolve). |
| Package manager / registry client | Not a runtime feature. |
| seccomp / container sandboxing | The permission model is a seat belt; real isolation is the caller's responsibility. |
| Cross-compilation | Build on the target. |

## Planned for 1.0

- **Embedding C header** — `RuntimeOptions` exists internally; publish a stable
  header and document the embedder contract.
- **macOS / Windows ports** — Linux first; the platform seams land with the 1.0
  programme.
- **Packaging and install story** — a tarball with a README and checksum exists
  (`scripts/package.sh`); a release channel does not.

## Candidates

- Source maps in stack traces.
- Import attributes beyond JSON (`text`, `bytes`).
- `async_hooks` / `AsyncLocalStorage` (the SSE and diagnostics work is the
  prerequisite).
- `http.Agent` socket pooling and keep-alive reuse.
- REPL history, multi-line input and editing.
- FFI API — the `ffi` permission is parsed and stored, but no API consumes it.
- Remote/HTTPS imports — the `import` permission exists for the same reason.
- Terminal raw mode (`tty` `setRawMode`); interactive input is line-buffered.
- `process.env` writes reaching `environ` (currently a read-only snapshot).

## Deliberate limitations inside implemented modules

These are partial, not absent; the details live in `COMPAT.md`:

- `worker_threads`: process-backed shim, no shared memory.
- HTTP/2: h2c only; no flow control, server push, trailers or CONTINUATION.
- TLS server: no client-certificate verification or ALPN selection, so mTLS and
  HTTP/2-over-TLS are incomplete.
- `crypto.subtle`: no `wrapKey`, asymmetric JWK export, or usage enforcement.
- Streams: backpressure is advisory (the prelude does not enforce the high-water
  mark), so a fast producer can buffer without bound.
- `fs` streams are chunked reads, but `fs.watch` does not prune watchers for
  deleted directories.
- `process.stdout`/`stderr` are synchronous; there is no TTY handle, so `isTTY`
  is always false.

## Working rule

A capability moves from `candidate` to a release only when a test exists in the
same change. A capability marked `no` is not a bug report; it is a scope
decision recorded here so it cannot be rediscovered as a surprise.
