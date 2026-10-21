# ADR 0002 — `worker_threads` is deferred

**Status:** accepted (v0.10.0) · **Deciders:** runtime owner

## Context

The plan calls for a `worker_threads` evaluation with "one runtime per worker"
and a documented decision or deferral. The runtime is deliberately one thread:
one libuv loop and one QuickJS `JSRuntime`/`JSContext`, with every native entry
point `nothrow @nogc` and no locks in the loop or request paths.

## Measurements

- A bare `djs -e 0` process peaks at **10,496 KiB RSS** (`/usr/bin/time -v`)
  and 10–11 ms wall time on this host. Most of that is the QuickJS runtime,
  the prelude and libuv.
- A worker would need a second QuickJS runtime, a second libuv loop, a thread
  stack (8 MiB reserved by default), a message queue and lifetime management.
  The realistic floor is another ~10 MiB resident per worker, before any JS
  heap.
- QuickJS has no `SharedArrayBuffer`/`Atomics` implementation. `ArrayBuffer`
  transfer would therefore be a copy, and the Node idiom of sharing memory
  between threads cannot be emulated faithfully.
- The single-loop model is the reason the host has no mutexes, no atomics in
  the API layer and no cross-thread `JSValue` ownership rules. Introducing
  workers would add a second ownership model to every module (`crypto`,
  `tls`, `net`, `child`, `dgram`, `zlib` tables are all process-global today).

## Decision

Do not implement `worker_threads` before v1.0.0. Ship a clear stub instead:
`require('worker_threads')` exposes `isMainThread: true`, `threadId: 0`, and a
`Worker` constructor that throws `ERR_WORKER_THREADS_UNSUPPORTED`. A future
version may add process-level parallelism via `child_process` (already
available) or a multi-process supervisor, which preserves the single-thread
invariants.

## Consequences

- CPU-bound JavaScript cannot use more than one core inside one process.
  Callers can spawn child processes for parallelism today.
- The plan's "worker isolation and message tests" exit criterion is replaced by
  this ADR, the stub test and the existing child-process isolation tests.
- Revisiting this decision requires a new ADR covering per-runtime ownership
  for every global table, `ArrayBuffer` transfer semantics and shutdown.
