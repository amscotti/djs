# Node.js compatibility scorecard

Measured against djs v0.16.2 (2026-10-22). This supersedes the earlier
v0.16.1 score; `docs/COMPAT.md` and `docs/COMPARISON.md` remain the detailed
per-API references.

## Method

43 Node builtin modules, each with a usage weight (3 = everyday core,
2 = common, 1 = niche/legacy) and a depth score (how much of the module's real
surface works, 0..1). Depth is a judgement call backed by `docs/COMPAT.md`, the
gate suite, and the integration tests noted below — not an automated API diff.

- Weighted API depth = Σ(weight × depth) / Σ(weight)
- Module breadth = modules with any working surface / 43
- Weights: 3 for fs/path/http/https/net/crypto/stream/events/buffer/process/
  child_process; 2 for url/util/os/zlib/dns/tls/string_decoder/perf_hooks/
  assert/module/stream-promises/http2/stream-web/fs-promises/timers/
  worker_threads/async_hooks/cluster; 1 for the remainder.

## Result

- **Weighted API depth: ~73.0%**
- **Module breadth: 93.0%** (40 of 43 modules have a working surface)
- 23 full (≥0.8), 9 substantial (0.6–0.8), 8 partial (0.3–0.6), 3 absent
  (`async_hooks`, `wasi`, `repl`)

## Per-module

- fs 0.90 · path 1.0 · url 0.95 · http 0.80 · https 0.85 · net 0.75
- crypto 0.85 · stream 0.90 · events 0.80 · buffer 0.95 · util 0.80 · os 0.60
- child_process 0.80 · zlib 0.95
- dns 0.55 · tls 0.85 · readline 0.60 · tty 0.40 · vm 0.70 · dgram 0.60
- querystring 0.80 · string_decoder 0.90 · perf_hooks 0.60 · process 0.85
- assert 0.80 · module 0.80 · stream/promises 0.90
- http2 0.70 · stream/web 0.65 · fs/promises 0.85 · timers 0.90 ·
  timers/promises 0.80
- worker_threads 0.40 (child-process shim; no shared memory) · async_hooks 0
- cluster 0.70 · diagnostics_channel 0.80 · trace_events 0.30 · inspector 0.10
- v8 0.3 (shim: heap stats, local serialize; no snapshot/byte parity)
- wasi · repl: 0
- constants 0.50 · punycode 0.50

## What the number means in practice

- **Typical HTTP/CRUD/CLI npm app: ~85%.** Verified with Express (full gate),
  Hono (adapter), the official OpenAI SDK against DeepSeek (buffered +
  stream), `ws`, `jose`, HTTP/2 interop both directions, TLS/mTLS/ALPN, and
  cluster serving.
- **Worker/native-heavy app: ~55%.** `worker_threads` is an API-compatible
  process shim without shared memory; `cluster` uses `SO_REUSEPORT`; N-API
  addons are absent.
- **Full Node API parity: ~73%.** Remaining gaps are depth and semantics:
  N-API, true threads, fd-3 IPC, inspector/V8, async_hooks, parts of
  WebCrypto, and DNS/HTTP/2 edge behaviour.

## Biggest levers, in order

1. N-API addon bridge — ceiling for Prisma/sharp/bcrypt-class apps
2. True threads/shared memory — `SharedArrayBuffer`, `Atomics`, worker pools
3. fd-3 IPC + explicit permission inheritance — removes loopback transport and
   broad child grants
4. WebCrypto completion — asymmetric JWK export, wrapKey, RSA-OAEP encrypt
5. DNS/HTTP-2 depth — DNSSEC/EDNS0/TCP fallback; h2 trailers/flow control

## Caveats

Depth scores are subjective. The module list omits internals (`_http_*`) and
subpath-only modules. Framework results used small apps; they prove loading,
routing, templating and streaming, not every framework feature. The
`worker_threads` and `cluster` scores reflect API shape, not true parallel
semantics.

## Delta since the v0.16.1 score

The v0.16.2 quick wins close the load-time gaps that the per-module tables above
score as missing. The table is not re-scored line by line; the honest summary is:

| Area | Change |
|---|---|
| `process` | `versions`/`release`/`features`/`emitWarning`/`exitCode`/`argv0`/`global` |
| `util` | `inspect.custom`, `types.isProxy`, `isDeepStrictEqual`, `getSystemErrorName`, `stripVTControlCharacters`, `debuglog` |
| `events` | `on`, `getEventListeners`, `errorMonitor`, `captureRejections`, `addAbortListener` |
| `http`/`https` | `Agent`/`globalAgent`, `STATUS_CODES`, `METHODS`, header helpers, `setTimeout`, repeated `Set-Cookie` |
| `http2` | `constants` |
| `fs` | `Dirent`/`Stats` exports, `withFileTypes`, `access`, `mkdtemp` |
| `path` | `parse`, `format`, `toNamespacedPath`, `win32` (formatting) |
| `url`/`zlib`/`os` | `urlToHttpOptions`, `crc32`, `EOL` |
| `dns` | `dns/promises` subpath module |
| `module` | `require.main`/`cache`/`extensions`, module `children`/`path`/`paths` |
| `stream` | `Readable.setEncoding` |
| resolver | top-level-only `package.json` keys (`type`, `main`) |

Still absent and unchanged: `async_hooks`/`AsyncLocalStorage`, N-API, `Intl`,
WASM, inspector, `require(esm)`, hoisted monorepo resolution, socket pooling.
