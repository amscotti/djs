# djs vs Node.js benchmarks

Environment: Linux x86_64, 4 cores, 9.8 GB RAM; Node.js v26.7.0; djs v0.16.3;
Express 4.22.3. djs was run with `-A` (permissions disabled), so these are
best-case numbers for the runtime.

## Method

- Startup: `hyperfine --warmup 3 --runs 30`, empty program.
- CPU: in-process microbenchmarks (`bench/cpu-bench.js`), same file under both
  runtimes, median of 3 runs; the Buffer case is the median of 5 interleaved
  runs on both binaries.
- HTTP: `bench/http-bench.js`, a keep-alive Node client that spawns the server
  binary, 5 s at 50 connections, two runs, median reported. (autocannon is not
  installed on this host; the previous table used it, so compare within this
  table rather than across tables.)
- Benchmark files: `bench/cpu-bench.js`, `bench/http-bench.js`,
  `bench/http-lite.js`, `examples/express-app/bench-lite.js`.
- Regression check: the same startup and CPU cases were run against the
  v0.16.2 binary from `dist/` and against `./djs` (v0.16.3); the two are within
  noise of each other (startup order-dependent, ~40–46 ms both).

## Startup

| Runtime | Mean |
|---|---|
| Node | 38.7 ms ± 9.3 |
| djs | 45.5 ms ± 11.2 |

Node is about 1.17× faster to start on this host. Both figures include process
creation; the earlier "parity" claim no longer holds with Node 26, which starts
faster than the Node 20 used when this document was first written.

## CPU microbenchmarks (lower is better)

| Benchmark | Node | djs | djs / Node |
|---|---:|---:|---:|
| JSON stringify+parse ×100k | 125.3 ms | 569.6 ms | 4.5× slower |
| SHA-256 ×5k (4 KB) | 24.3 ms | 45.5 ms | 1.9× slower |
| Buffer write/read ×500k | 25.0 ms | 616.0 ms | 24.6× slower |
| String split/replace ×2k | 329.0 ms | 1614.3 ms | 4.9× slower |

The Buffer numeric-accessor path remains the standout gap and is the first
optimisation candidate; it also affects HTTP parsing and database drivers.

## HTTP throughput (http-bench.js, 50 connections, 5 s)

| Server | Node | djs | djs / Node |
|---|---:|---:|---:|
| Raw `http` `/` | 8,855 req/s | 1,196 req/s | 13.5% |
| Express `/` | 7,981 req/s | 1,066 req/s | 13.4% |
| Express `/json` | 8,160 req/s | 1,094 req/s | 13.4% |

Latency at this load: raw djs p50 ~42 ms / p99 ~49–52 ms; Express djs p50
~44–48 ms / p99 ~77–86 ms. Node raw p50 ~5.5–6.0 ms / p99 ~11–14 ms; Express
p50 ~6.3–6.6 ms / p99 ~13–18 ms. Zero errors and zero non-2xx responses for
both runtimes.

Express and raw now show the same relative gap on this client (both ~13.4%),
because the client is the bottleneck for Node at this concurrency: the Node
server is not saturated, so the ratio reflects the djs server's absolute rate
rather than framework overhead. Absolute djs throughput (~1.1k req/s on this
4-core box) is suitable for local tools and dev servers, not as a Node
production replacement.

## Compatibility recheck (v0.16.3)

- Integration: `scripts/integration.sh` → **161/161**.
- Differential: `scripts/diff-node.sh` → **12/12 cases** identical to Node
  (arith, path, buffer, errors, timers, fs_ops, os, modules, net, child,
  crypto, v8).
- Express: `scripts/gate-express.sh` → **5/5 checks**.
- Examples: `scripts/gate-examples.sh` → **12/12 checks** (Express and Hono).
- Real libraries: `scripts/gate-compat.sh` → **ws** and **jose** smoke tests.
- Hardening: `scripts/fuzz.sh` → **28 cases, 0 failures**; `scripts/gate-sanitize.sh`
  (ASan/UBSan) and `scripts/soak.sh` are part of the gate and pass.

## Takeaways

1. Startup and crypto are close to Node; JSON/string manipulation is ~4–5×
   slower; Buffer numeric access is ~25× slower.
2. HTTP is ~13% of Node on this host with this client, for both raw and
   Express.
3. Before optimising HTTP, profile and move Buffer numeric read/write to a
   native path; that is the largest measured single lever.
4. Re-run this suite after any Buffer or HTTP parser change. These are
   single-machine loopback numbers, not a claim about production workloads.
