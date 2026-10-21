# djs vs Node.js — capability comparison

Legend: **yes** = implemented and tested · **partial** = useful subset, details
below · **no** = absent (fails loudly or module missing) · **planned** = pulled
into a pre-1.0 phase by the replan.

Measured against Node 22/26 behaviour; `djs --version` v0.16.2. This is
the one-line-per-area view; `docs/COMPAT.md` is the detailed normative
reference and `docs/COMPATIBILITY-SCORE.md` the per-module scorecard.

## Module loading and language

| Area | Node | djs | Notes |
|---|---|---|---|
| CommonJS `require` | yes | yes | wrapper, cycles, `module.exports`, `__dirname`/`__filename` |
| ESM `import`/`export` | yes | yes | static imports, live bindings, JSON modules via import |
| `node_modules` resolution | yes | yes | `exports`/`imports`, conditions, patterns; `require.resolve` + `createRequire().resolve` |
| Builtin prefixes | `node:fs` | yes | `node:` and bare forms |
| TypeScript / loaders | via tooling | no | no `--experimental-loader` |
| Native `.node` addons | yes | no | no N-API; the `ffi` permission exists but no FFI API is exposed |

## Globals and process

| Area | Node | djs | Notes |
|---|---|---|---|
| `Buffer`, `URL`, `URLSearchParams` | yes | yes | Uint8Array subclass with Node statics, numeric/BigInt accessors, copy/indexOf, base64url |
| `fetch`, `Headers`, `Response`, `AbortController` | yes | yes | http/https; no streaming request bodies |
| `WebSocket`, `EventSource` | yes (22+) | partial | built-in WebSocket client/server; EventSource over SSE; the `ws` package works |
| `TextEncoder`/`TextDecoder` | yes | yes | no streaming option in QuickJS; StringDecoder handles boundaries |
| `structuredClone`, `queueMicrotask` | yes | yes | |
| `process.argv/env/exit/stdio/signals` | yes | yes | signal handlers; `process.kill` gated by the `sys` permission |
| `process.hrtime/uptime/memoryUsage/kill` | yes | yes | hrtime (+bigint), uptime, memoryUsage, cpuUsage, umask, kill |
| `performance` | yes | partial | object exists, limited API |
| `console` | yes | yes | |

## Filesystem and OS

| Area | Node | djs | Notes |
|---|---|---|---|
| `fs` sync/callback/promises | yes | yes | broad: read/write, dirs, links, chmod/chown, stat, fd APIs, cp/readv/writev/openAsBlob, recursive watch |
| `fs` streams | yes | partial | whole-file backed ReadStream/WriteStream, not chunked reads |
| `fs.watch`/`watchFile` | yes | yes | inotify-backed `watch` (+`recursive`, v0.15.1) and `watchFile` polling |
| `fs.statfs` | yes | yes | `statfsSync`/`statfs`, `opendir`/`Dir` (stream methods partial) |
| `path`, `url`, `querystring` | yes | yes | legacy `url.parse` subset |
| `os` | yes | partial | networkInterfaces/uptime/loadavg/userInfo/constants/machine exist |
| `child_process` | yes | partial | spawn/exec/execFile/fork IPC/spawnSync/execSync, pipes, signals, timeout/maxBuffer; no detached |
| `cluster` | yes | partial | fork/workers/messages/kill; workers share a port via SO_REUSEPORT, no round-robin handle passing |
| `worker_threads` | yes | partial | child-process-backed shim: Worker/workerData/parentPort/messages/terminate/eval; no shared memory or transferables |

## Network and servers

| Area | Node | djs | Notes |
|---|---|---|---|
| `net` TCP client/server | yes | partial | IPv4 + IPv6 literals; 128 sockets, 8 listeners |
| `dns` | yes | partial | `lookup`, `lookupService`, `reverse`, `resolveAny`, `setServers`/`getServers`, and `resolve` plus the A/AAAA/MX/TXT/SRV/CNAME/NS/PTR/SOA record types; no `resolveNaptr`/`resolveCaa` methods (their types come back from `resolveAny`) and no TCP fallback |
| `http` client | yes | yes | chunked responses, redirects not automatic |
| `http` server | yes | partial | request/response, keep-alive, chunked bodies, 100-continue, `upgrade` handoff |
| `https` client / TLS | yes | yes | OpenSSL, system CA, SNI, TLS 1.2+ |
| `https` server | yes | partial | PEM cert/key, mutual TLS via `caFile`/`requestCert`; no ALPN selection or HTTP-2 TLS |
| `http2` | yes | partial | h2c client+server, multiplexed streams, HPACK; no flow control, push, trailers, CONTINUATION (v0.13.1) |
| `dgram` | yes | partial | udp4 bind/send/message, broadcast, TTL, multicast membership; no IPv6/buffer options |
| `tls` options (`ca`, `cert`, `key`, ALPN) | yes | partial | client custom CA/client cert/ALPN advertisement; server mTLS and HTTP-2 TLS pending |

## Crypto, compression, streams

| Area | Node | djs | Notes |
|---|---|---|---|
| Hashes/HMAC | yes | yes | SHA-1/2, MD5 |
| CSPRNG, UUID, timingSafeEqual | yes | yes | 64 KiB per randomBytes call |
| Ciphers (AES-GCM/CBC) | yes | partial | one-shot only; no streaming cipher state |
| `sign`/`verify`, key objects | yes | partial | RSA/EC PEM sign/verify, streaming sign/verify, keygen, X509 inspection; no PSS/cert chains |
| KDFs (`pbkdf2`, `scrypt`, `hkdf`) | yes | yes | sync + async wrappers, key generation for RSA/EC/Ed25519 |
| WebCrypto `crypto.subtle` | yes | partial | digest, HMAC, AES-GCM, PBKDF2/HKDF, keygen for HMAC/AES/RSA/EC; no wrapKey, asymmetric JWK export, usage enforcement (v0.13.9) |
| `zlib` gzip/deflate/raw | yes | yes | sync + Transform streams, 256 MiB cap; Brotli sync + fetch decode |
| Brotli | yes | yes | sync compress/decompress, fetch `br` decoding | |
| `stream` core + `pipe`/`pipeline`/`finished` | yes | partial | `toWeb`/`fromWeb`, `addAbortSignal`, `stream/consumers`; object-mode edges still thin |
| `events` | yes | partial | `on()` async iterator, `once`, `captureRejections`; no max-listener warnings |
| `readline` | yes | partial | line/close/question; `readline/promises`; no terminal editing/history |
| `vm`, `perf_hooks`, `diagnostics_channel`, `trace_events` | yes | partial | `vm` Script/contexts; perf marks/measures; diagnostics channels; inert tracing; no async_hooks/inspector |
| `assert`, `module`, `stream/promises` | yes | partial | assert methods + deep equality, createRequire/isBuiltin, promise pipeline/finished; no snapshots or Module internals |

## Frameworks

| Target | Status |
|---|---|
| **Express 4** (routing, params, JSON body, static, 404) | **works unmodified** — `examples/express-app`, `scripts/gate-express.sh` |
| Express 5 | not tested; depends on the same http/stream surface |
| Fastify / Koa | not tested; likely blocked by missing APIs (schema compilers, `stream` details) |
| `ws` package | works (WebSocket client/server, v0.13.0); Socket.IO untested |
| Prisma / native addons | blocked by N-API |

## What Express needed (fixed in v0.10.1)

`Error.captureStackTrace` + `Error.prepareStackTrace` returning V8-style
CallSite objects, callable `require('stream')`, `EventEmitter` methods on
objects that never ran the constructor, `__dirname`/`__filename` for the main
module, `fs.ReadStream`/`fs.WriteStream` constructors, `Buffer.allocUnsafeSlow`
and `Buffer.compare`, `querystring`, `string_decoder` (with UTF-8 boundary
buffering) and `tty`.

## Delivery history

The rows above were filled in across v0.2–v0.16; the order that produced them
is recorded in `docs/COMPAT-ROADMAP.md` (historical). Current priorities are in
`docs/ROADMAP.md` and `docs/COMPAT-BACKLOG.md`.
