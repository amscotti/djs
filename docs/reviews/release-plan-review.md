# Plan health review — v0.1.0 release

**Question:** after executing Phases 0–4, does the plan still describe reality,
and did following it help or hurt?

**Short answer:** the plan held. The vertical-slice-first ordering, the
"thin native, fat JavaScript" split, and the "one classifier" rule all paid for
themselves. The plan's weak spots were in *verification*, not architecture: its
Phase 1 "additional machine checks" were prose until this pass turned them into
scripts, and its review budget assumed independent panels that only round 1
actually received.

## What the plan got right

- **Vertical slice first.** Proving the D↔QuickJS↔libuv boundary with console,
  timers, process and `readFile` surfaced every class of bug that later phases
  would otherwise have multiplied: teardown hangs, exit-code clobbering,
  callback lifetime, job-drain ordering.
- **One classifier.** Writing `modules/classify.d` before `require`/`import`/
  entry dispatch meant the three callers could not drift. The round-1 finding
  that created this rule (P-01) was the most valuable document review outcome.
- **Thin native / fat JS.** Encoding, promise and callback shapes stayed in
  `prelude.js`; the C surface stayed small enough to audit (one file per API).
- **Pins and gates as first-class.** `bootstrap.sh` + the ABI probe caught real
  drift risk; the DUB `unittest` target-name trap was found by the round-1
  reviewers and is now regression-tested.
- **Accepted trade recorded.** QuickJS is an interpreter. Benchmarks show the
  expected shape: much faster startup, ~2× slower engine-only CPU. Nothing in
  the plan promised otherwise.

## Where the plan was wrong or thin

1. **"Machine checks" were not deliverables.** Phase 1 listed ASan, leak and
   GC-allocation checks but named no script, no artifact and no owner. They
   did not exist until this pass. Fix: every DoD line now names a command that
   writes `gates/<name>.txt`.
2. **The fs design assumed `uv_fs_*`.** The implementation used
   `uv_queue_work` + blocking POSIX calls, which is simpler for the read/write
   loops the plan itself requires. The plan did not weigh the cost it cares
   about most (cancellation, teardown), so the deviation had to be discovered by
   a FIFO test. Fix: ARCH §9.4 now states the choice, its costs and the cap.
3. **Test harness assumptions.** The original `integration.sh` could not drive
   stdin and had no way to assert "exit while an fs request is blocked". Both
   were added when the corresponding bugs appeared. Fix: the harness now runs
   directory cases, stdin cases, pipe cases and timing-sensitive exit cases.
4. **Review capacity.** The plan budgets three reviews per round. Round 1 got
   them; rounds 2 and 3 have implementation evidence and green gates but no
   independent panel. The plan should either budget the panel time or state
   explicitly that a release candidate may ship with a pending panel — it
   currently does neither, so this document records the gap.
5. **Buffer was left open.** The plan said "decide when the fs tests are
   written". The decision (return `Uint8Array`, encoding opt-in) is now made
   and documented in COMPAT; the plan's open question is closed.

## Deviations from the documented design (all deliberate)

| Deviation | Why | Where recorded |
|---|---|---|
| Async fs uses `uv_queue_work`, not `uv_fs_*` | One blocking-POSIX code path; no `uv_fs_t` lifetime; simpler short-read/write loops. Cost: requests are uncancellable while blocked. | ARCH §9.4, COMPAT, REVIEWS R1-10 |
| `qjs` oracle needs libc, built in the same tree | Bootstrap's smoke test uses the CLI; `libqjs-libc.a` is never linked | PINS, REVIEWS R1-28 |
| ESM→CJS named exports not detected | Heuristic analysis is npm-shaped scope; default import works | COMPAT, ARCH §8.2 |
| `readFile` returns `Uint8Array` | Binary-correct without a `Buffer` polyfill; encoding opt-in matches Node's shape | COMPAT, README |
| REPL prints `String(value)` | `util.inspect` parity is not a v0.1 goal; async ordering is correct | COMPAT |

## Remaining work before "released"

- [x] Independent three-reviewer panel for the release candidate (rounds 2+3
      scope), dispositions in `docs/REVIEWS.md` (`R2-01`…`R2-20`).
- [ ] v0.2 candidates: the full inventory (planned / candidate / not planned) is
      in [`ROADMAP.md`](ROADMAP.md). Committed v0.2 items: `path`/`os` facades,
      `Buffer`, `setImmediate`/`process.nextTick`, the missing fs operations
      (`rename`, `copyFile`, `rm`, `realpath`, recursive `mkdir`), write
      encodings, percent-encoded `import.meta.url`, `memoryUsage().arrayBuffers`,
      and the differential/soak harnesses.
- [ ] Optional: `QJS_BUILD_LIBC=OFF` for the library, qjs built separately.
- [ ] Optional: replace blocking fs threadpool calls with `uv_fs_*` if
      cancellation becomes a requirement.
- [x] All v0.1 features implemented and covered by golden tests.
- [x] Gates produce committed evidence (`gates/`).
- [x] Benchmarks recorded (`docs/BENCH.md`), fuzz harness (`scripts/fuzz.sh`).
- [x] README, COMPAT, DEVELOPING, PINS, ARCH, PLAN updated.

## Verdict on the plan

Still the right plan for v0.1: small scope, explicit non-goals, phases that end
in observable behavior. The correction for the next cycle is procedural — make
every DoD line a script from the start, and schedule the review panel as work,
not as an assumption. No architectural rewrite is warranted.
