# Node compatibility roadmap — priority order

> (Kept as the historical ranking record — see the status note below.)

> **STATUS at v0.16.1 (2026-10-22):** the Tier 1 and Tier 2 items ranked below
> are implemented and released. This file is retained as the historical
> ranking record; do not schedule from it. The current order is:
>
> 1. **N-API addon bridge** — XL, needs a scope decision; ceiling for
>    Prisma/sharp/bcrypt-class apps.
> 2. **True threads / shared memory** — XL, research spike first; the current
>    `worker_threads` is a child-process shim.
> 3. **fd-3 IPC + permission inheritance** — M; removes loopback transport and
>    broad `--allow-net`/`--allow-listen`/`--allow-env` grants.
> 4. **WebCrypto depth** — M; asymmetric JWK export, `wrapKey`, RSA-OAEP
>    encrypt, usage enforcement.
> 5. **DNS/HTTP-2 depth** — M; DNSSEC/EDNS0/TCP fallback, h2 trailers and
>    flow-control parity.
>
> See `docs/COMPATIBILITY-SCORE.md` for the v0.16.1 measurements (weighted
> depth ~72.6%, module breadth 90.7%).

Basis: djs v0.13.5, empirical API probe plus the library evidence below.
Companion to `docs/COMPATIBILITY-SCORE.md` (weighted depth: **59%**) and
`docs/ROADMAP.md` (raw gap inventory).

## Ranking rule

Each gap is scored on four things:

- **Impact** — how many popular npm packages/apps hit it.
- **Severity** — hard failure vs degraded behaviour.
- **Effort** — S (≤2 days), M (3–5), L (1–2 weeks), XL (multi-week).
- **Dependency** — what must land first.

The order below is impact per unit of effort, not raw API surface.

## Correction to the scorecard

The probe found the docs overstated several modules, so depth scores were
lowered: `Buffer` 0.85→0.55 (no numeric/copy/indexOf methods), `child_process`
0.6→0.4 (no `exec`/`execFile`/`fork`), `dns` 0.6→0.5, `stream` 0.65→0.6,
`crypto` 0.5→0.45. Weighted compatibility is **58.7%**, not 61%.

The single biggest surprise: `Buffer` is missing `readUInt16BE`, `writeUInt16BE`,
`readInt32LE`, `copy`, `indexOf`, `includes`, `toJSON` and every BigInt accessor.
That blocks database drivers and binary protocols far more than missing
`worker_threads` does.

## Tier 1 — unblocks the majority of pure-JS libraries

1. **Buffer completeness** — numeric read/write (8/16/32/64, signed/unsigned,
   LE/BE, BigInt), `copy`, `indexOf`/`lastIndexOf`/`includes`, `fill`
   encodings, `write*` variants, `toJSON`, `swap16/32/64`, base64url,
   `isEncoding`. Blocks: `pg`, `mysql2`, `mongodb`, `ws`, `undici`, `tar`,
   every binary protocol parser. Effort **M**.
2. **Module resolution correctness** — relative JSON require, `require.resolve`
   returning a real path, `createRequire(...).resolve`, `import.meta.resolve`,
   package `exports` edge cases. Blocks: `tsc`/`ts-node`, bundlers, ESM/CJS
   interop tooling. Effort **S–M**.
3. **Stream interop + object mode** — `Readable.toWeb`/`fromWeb`,
   `Writable.toWeb`/`fromWeb`, `Duplex.toWeb`, `addAbortSignal`, correct
   backpressure and pipeline cleanup. Blocks: `undici`, `@hono/node-server`,
   fetch request bodies, modern SDKs. Effort **M**.
4. **Crypto core completion** — async `hkdf`, `generateKeyPair`/`Sync`,
   `X509Certificate`, streaming `createSign`/`createVerify`, cipher/key
   defaults. Blocks: `jws`/`jsonwebtoken` edge cases, mTLS, OIDC libraries.
   Effort **M**.
5. **HTTP `upgrade` event** — 101 handoff with a raw socket (keep-alive and
   chunked request bodies are already verified working). Blocks: `socket.io`,
   `engine.io`, `ws`, HMR (Vite), reverse-proxy WebSocket deployments.
   Effort **M**.
6. **WebCrypto `crypto.subtle`** — digest, import/export JWK, HMAC, RSA/ECDSA
   sign/verify, AES-GCM, PBKDF2/HKDF deriveBits. Blocks: `jose`, `next-auth`,
   `web-push`, AWS SDK v3 crypto helpers. Effort **L**.
7. **Blob/File + FormData multipart + fetch upload bodies** — request streams
   (`duplex: "half"`), multipart encoding. Blocks: OpenAI file APIs, `undici`
   uploads, SDKs that post files. Effort **M**.
8. **`async_hooks` / `AsyncLocalStorage` / `AsyncResource`** — request-scoped
   context across promises. A loader-compatibility shim landed: `AsyncResource`
   works and undici runs, while `AsyncLocalStorage` is synchronous-only.
   True context across `await` remains **L** (needs promise-context
   propagation; may need engine hooks) and still blocks Fastify request-context,
   NestJS, OpenTelemetry instrumentation and structured logging.
9. **DNS breadth** — `resolveMx`/`Txt`/`Srv`/`Cname`/`Ns`/`Soa`/`Reverse` plus
   `dns.promises`. Blocks: `mongodb+srv`, `nodemailer`, service discovery.
   Effort **S–M**.
10. **zlib Brotli + fetch content decoding** — `brotliCompress`/`Decompress`,
    automatic gzip/deflate/br decoding and `accept-encoding`. Blocks: fetch
    against CDNs/APIs that force compression. Effort **S**.

## Tier 2 — server, tooling and scale

11. **TLS ALPN + client certs/custom CA; HTTP/2 over TLS with trailers and flow
    control.** Blocks gRPC, mTLS APIs, HTTP/2-only services. Effort **L**.
12. **`child_process` breadth** — async `exec`/`execFile`, `fork` IPC,
    `timeout`/`maxBuffer`, detached/kill semantics. Blocks PM2, test runners,
    CLI wrappers. Effort **M**.
13. **`fs` breadth** — `cp`/`cpSync`, `readv`/`writev`, recursive `watch`
    semantics and change events, `openAsBlob`. Blocks chokidar-based dev tools
    and copy-heavy build steps. Effort **M**.
14. **`worker_threads`** — real isolated runtime per worker, `postMessage`,
    `MessageChannel`, clean shutdown. Blocks Jest/Vitest workers, Next.js
    builds, `piscina`, CPU fan-out. Effort **L**.
15. **diagnostics/perf long tail** — `perf_hooks` fuller API,
    `diagnostics_channel`, `trace_events`, `inspector` stubs. `v8` shipped as a
    shim in v0.16.2. Blocks APM agents that merely import them. Effort **S–M**.
16. **`cluster` + global `WebSocket`/`EventSource`.** Blocks PM2-style
    multi-process serving and browser-style clients. Effort **M** (cluster
    depends on fork IPC).
17. **N-API addon loader.** Blocks `Prisma`, `sharp`, `bcrypt`,
    `better-sqlite3`, `canvas`, `node-sass`. Effort **XL** — its own epic, not
    a version row. Decision point after Tier 2: minimal N-API subset for
    database/image drivers vs full ABI.

## Release sequence

- v0.13.6 Buffer completeness + module resolution (**done**)
- v0.13.7 stream interop
- v0.13.8 crypto core
- v0.13.9 HTTP upgrade event (101 handoff)
- v0.14.0 WebCrypto subtle
- v0.14.1 Blob/File/FormData + uploads
- v0.14.2 async_hooks/AsyncLocalStorage
- v0.14.3 DNS breadth + Brotli/decoding
- v0.14.4 TLS ALPN + HTTP/2 completion
- v0.14.5 child_process + fs breadth
- v0.15.0 worker_threads
- v0.15.1 diagnostics/perf + cluster + global clients
- v0.16.0 N-API epic (scope gate)
- v1.0.0 ports, source maps, embedding header, packaging/ABI policy

## Why not `worker_threads` next

It was the next row in the old plan, but it only unblocks dev-time tooling.
Buffer, module resolution and stream interop unblock runtime libraries that
apps load in production; HTTP upgrade unblocks the realtime server ecosystem.
`worker_threads` moves to Tier 2 and stays ahead of the long tail.

## Acceptance harness (build alongside v0.13.6)

A new `examples/compat-matrix/` with network-free smoke scripts, run by
`scripts/gate-compat.sh`:

- `pg` — parse a startup/auth message with Buffer numeric helpers
- `mysql2` — build a handshake packet
- `ws` — echo over an upgraded HTTP server (after v0.14.0)
- `jose` — sign/verify a JWT with `crypto.subtle` (after v0.14.1)
- `mongodb` — parse `mongodb+srv://` and resolve SRV (after v0.14.4)
- `tsc` — compile a two-file project (after v0.13.7)
- `undici` — fetch a chunked response through `Readable.toWeb` (after v0.13.8)

Each script prints deterministic `ok`/`fail` lines; the gate installs pinned
versions under `examples/compat-matrix/node_modules` (gitignored).
