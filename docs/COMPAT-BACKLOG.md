# Node partials backlog

> **Historical.** The batch list that drove v0.11–v0.16; every batch below
> shipped. Current gaps are in [`ROADMAP.md`](ROADMAP.md) and
> [`COMPAT.md`](COMPAT.md).

Every "partial" in `docs/COMPARISON.md` with the version that finishes it.
Batch 1 shipped in v0.11.0; the rest is scheduled before v1.0.0.

## Batch 1 — v0.11.0 (done)

- `process.hrtime()` / `hrtime.bigint()` (CLOCK_MONOTONIC), `process.uptime()`,
  `process.kill(pid, signal)` (named or numeric; `sys:kill` permission).
- `os.uptime()`, `os.loadavg()`, `os.networkInterfaces()` (IPv4+IPv6, netmask,
  CIDR, internal flag), `os.userInfo()`.
- `fs.statfsSync()` and `fs.statfs()` (`statvfs`).
- `dgram`: `setBroadcast`, `setTTL`, `setMulticastTTL`, `addMembership`,
  `dropMembership` (IPv4).

## Batch 2 — v0.11.1 (done)

- Done: `child_process` `timeout`/`maxBuffer` for spawnSync/execSync with
  `ETIMEDOUT`/`ERR_CHILD_PROCESS_STDIO_MAXBUFFER`; async `AbortSignal` still
  open (tracked with batch 3).
- Done: `http` server keep-alive, pipelining, chunked request bodies, HEAD,
  `Expect: 100-continue`, header/request deadlines, graceful `close()` drain.
- Done: `process.cpuUsage`, `process.umask` (`resourceUsage` still open).
- Done: `fs.createReadStream` chunked Buffer reads.
- Moved to **v0.12.1**: `net` IPv6 (client and listener) — `net.d` hardcodes
  `AF_INET` in DNS hints, connect, bind and `getsockname`, so it is an
  address-family refactor. `socket.setTimeout` idle semantics is already
  present on sockets.
- Moved to **v0.12.1**: `fs.opendir` (with `fs.watch`).

## Batch 3 — v0.12.6

- `fs.watch`/`watchFile` (inotify, recursive opt-in), `fs.statfs` constants.
- `dns.resolve*` (A/AAAA/CNAME/MX/TXT/SRV), `dns.promises` parity.
- `os.constants`, `os.machine`, `os.availableParallelism`.
- `events`: `captureRejections`, max-listener warnings, `getEventListeners`.
- `stream`: Web Streams interop (`Readable.toWeb`/`fromWeb`), `addAbortSignal`.
- `util.inspect` depth/colors/showHidden; `util.parseArgs`.
- `vm` (`Script`, `runInNewContext` subset), `perf_hooks`
  (`performance.now`, `PerformanceObserver` minimal).
- WebSocket client (`ws://`/`wss://` handshake over net/tls).
- `dgram`: `setMulticastLoopback`, buffer-size options, IPv6.

## Later phases

- **v0.11.2 (done)** HTTPS server + TLS `cert`/`key`; IPv6 delivered in v0.12.1.
- **v0.12.0 (done)** ciphers (AES-CBC/GCM) and KDFs (pbkdf2/hkdf/scrypt);
  sign/verify, key objects and WebCrypto moved to v0.12.1.
- **v0.13.0** HTTP/2 client+server, WebSocket upgrade/server.
- **v0.13.1** `worker_threads` (shared-nothing runtime per worker).
- **v1.0.0** macOS/Windows ports, source maps, embedding header, packaging.
