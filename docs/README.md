# Documentation index

Two kinds of documents live here. **Current references** are kept in step with
the code and the gates; treat them as authoritative. **Historical records**
explain how the runtime got here; they are not maintained and may describe an
older version — do not schedule work from them.

## Current references

- [`../README.md`](../README.md) — front door: what DJS is, install, CLI,
  permission model, API summary.
- [`COMPAT.md`](COMPAT.md) — the normative list of observable differences from
  Node 22, section by section, with the release that introduced each surface.
- [`COMPATIBILITY-SCORE.md`](COMPATIBILITY-SCORE.md) — per-module breadth
  scorecard and its method.
- [`BENCHMARKS.md`](BENCHMARKS.md) — measured startup, CPU and HTTP numbers,
  with the method and the machine they were measured on.
- [`PERMISSIONS.md`](PERMISSIONS.md) — the permission model: scopes, `djs.json`
  sets, prompts, audit log, and the reasoning behind default-deny.
- [`ARCHITECTURE.md`](ARCHITECTURE.md) — runtime structure, ownership rules,
  the C boundary, and the ADR index.
- [`DEVELOPING.md`](DEVELOPING.md) — layout, D style rules, gate/review
  workflow, how to add an API or a test.
- [`PINS.md`](PINS.md) — pinned toolchain and vendored versions.
- [`D-GUIDE.md`](D-GUIDE.md) — D notes for contributors coming from JS.
- [`V8.md`](V8.md) — the `node:v8` shim: what it promises, what it does not,
  and the divergences.
- [`ROADMAP.md`](ROADMAP.md) — capabilities that are absent outright, and the
  intent for each (scope decision, candidate, or 1.0).


## Historical records

- [`../BRIEF.md`](../BRIEF.md) — the original project brief.
- [`PLAN.md`](PLAN.md) — the original build plan and phasing.
- [`COMPAT-ROADMAP.md`](COMPAT-ROADMAP.md) — the historical priority ranking.
- [`BENCH.md`](BENCH.md) — the v0.7.0 benchmark run, superseded by
  `BENCHMARKS.md`.
- [`COMPAT-BACKLOG.md`](COMPAT-BACKLOG.md) — the batch list that drove
  v0.11–v0.16; every batch shipped.
- [`REVIEWS.md`](REVIEWS.md) and [`reviews/`](reviews/) — review rounds and
  their dispositions (one file per release).
- [`adr/`](adr/) — architecture decision records.
- [`research/`](research/) — background notes: D idioms, D performance and readability,
  QuickJS embedding.
