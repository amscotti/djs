# Compatibility notes

DJS targets a *small, Node-shaped* surface, not Node compatibility. This file
records every place where the observable behaviour deliberately differs, so a
differential test can assert the difference instead of discovering it.

> **How to read this file.** The first sections (Processes and CLI,
> Permissions, fs, net/dns/http/fetch, child_process) describe the current
> surface. The version-tagged sections below them are release notes: each one
> records what a release added or changed, so a later section can amend an
> earlier bullet. For the per-module picture use
> [`COMPATIBILITY-SCORE.md`](COMPATIBILITY-SCORE.md); the README summarises the
> supported surface.

## Compatibility quick wins (v0.16.2)

A batch of small surface gaps that stopped common packages at load time. Each is
implemented and covered by `tests/js/compat_quick_wins.js`.

**Resolver.** `packageJsonValue` now reads only *top-level* keys. It used to scan
for the first `"type"` anywhere in the file, so a package whose `repository` object
(`{"type": "git"}`) preceded `"type": "module"` was classified as CommonJS and
failed to parse (`unsupported keyword: export`). The same helper feeds `main`, so a
nested `"main"` could hijack entry resolution. Both are fixed.

**Process.** `global` is an alias for the global object; `process.versions`
(`node`, `modules`, `v8`, `uv`, `openssl`, `djs`), `process.release`,
`process.features`, `process.argv0` and `process.exitCode` exist.
`process.versions.node` names the *emulated Node level* (22.11.0) rather than the
engine; `process.version` stays DJS's own version. `process.emitWarning` emits
synchronously, where Node defers the `warning` event to the next tick.

**util.** `inspect.custom` (and `inspect.defaultOptions`), `types.isProxy` (real
engine predicate), `types.isMap/isSet/isNativeError/isBoxedPrimitive`,
`isDeepStrictEqual`, `getSystemErrorName` (negative libuv errnos only, as Node),
`stripVTControlCharacters`, `debuglog` (honours `NODE_DEBUG`).

**v8.** `node:v8` is a shim, not a V8 backend: QuickJS has no V8 serializer and
no heap-snapshot format. Implemented: `serialize`/`deserialize` (a djs-local
tagged format that preserves cycles, Map/Set, Date, RegExp, BigInt, Error,
Buffer/typed arrays/DataView, `NaN`/`±Infinity`/`-0` and array holes — the bytes
do **not** interoperate with Node's), `getHeapStatistics` with Node 22's 14 keys
sourced from `JS_ComputeMemoryUsage` and `Runtime.memoryLimit`,
`getHeapSpaceStatistics` (one `quickjs` space), `getHeapCodeStatistics`,
`cachedDataVersionTag` (a constant), `setFlagsFromString` (a no-op) and
`startupSnapshot` (`isBuildingSnapshot()` returns `false`; the three callbacks
throw `ERR_NOT_BUILDING_SNAPSHOT` exactly as Node does outside a snapshot
build). `getHeapSnapshot`/`writeHeapSnapshot` throw `ERR_NOT_IMPLEMENTED`
rather than emit a file no V8 tool can read; `Serializer`, `Deserializer`,
`GCProfiler`, `queryObjects` and `promiseHooks` are absent. Heap numbers are
QuickJS's, so they are shape-compatible but not comparable with V8's.

**Loader gaps found with `execa@10`.** `node:path/win32` and `node:path/posix`
now resolve to the existing namespaces; `util.aborted`,
`events.setMaxListeners`, `timers/promises.scheduler` and `process.execArgv`
were added. execa 10 now runs: `await execa('echo', ['hi'])` returns
`{stdout: 'hi\n'}`.

**Async and streams (v0.16.2).** The promise/stream paths that packages rely on
were audited against Node and fixed:

- `Readable[Symbol.asyncIterator]` buffers and pauses between reads. It used to
  attach a fresh `data` listener per `next()`, so chunks produced while the
  consumer was awaiting were lost, and data+EOF in one turn left the next
  `next()` waiting for an `'end'` that had already fired. Stream errors now
  reject the loop instead of throwing from the event handler (which aborted the
  process).
- `stream.finished()`/`stream/promises.finished()` resolve on an already-ended
  stream, and child stdio is closed at exit, so `await finished(child.stdout)`
  no longer hangs without a second consumer. (An unconsumed *fs* read stream
  still waits, exactly as in Node.)
- `events.on()` returns an async iterator yielding one argument array per
  event, as documented; it previously returned a one-shot promise, so
  `for await (const [chunk] of on(stream, 'data'))` threw `not a function`.
- `child_process`: `ChildProcess.stdio` exists, `stdin` is a real `Writable`
  (with the historical "write after exit returns false" behaviour kept), the
  `'spawn'` event is emitted, and the stdio pipes emit `'close'` at exit.
- Process events: `process.on('exit'|'beforeExit'|'unhandledRejection'|
  'uncaughtException'|...)` no longer throws at registration. `exit` is emitted
  at teardown with the exit code, `beforeExit` once when the loop drains (and
  work scheduled by the listener keeps the process alive), `unhandledRejection`
  listeners are invoked with `(reason, promise)` and their presence prevents
  the abort, and `warning`/IPC events share the same table. Signal listeners no
  longer keep the loop alive (`process.on('SIGTERM', ...)` exits like Node).
  `uncaughtException` can be registered but is not emitted yet.

**events.** `events.on`, `getEventListeners`, `errorMonitor`, `captureRejections`
(the flag and the option; rejected listener promises are forwarded to `'error'`),
`addAbortListener`.

**http/https.** `http.Agent`, `https.Agent`, `globalAgent`, `STATUS_CODES`,
`METHODS`, `maxHeaderSize`, `validateHeaderName`, `validateHeaderValue`.
`ClientRequest.setTimeout`/`setNoDelay`, `ServerResponse.getHeaders`,
`getHeaderNames`, `getRawHeaderNames`, `hasHeader`, `appendHeader`,
`flushHeaders`, `writeContinue`, `writeEarlyHints`, `headersSent`, and
array-valued headers are serialised as repeated lines. Client responses keep
repeated `Set-Cookie` as an array.

Deliberate limits: the agent does not pool sockets — every request still dials a
new connection and sends `Connection: close`. `agent.createConnection` *is*
honoured, which is the hook proxy agents subclass. `setTimeout` emits `'timeout'`
but does not destroy the socket; the timeout is cleared when the response
completes or the request is destroyed.

**http2.** `http2.constants` with the `HTTP2_HEADER_*`, `HTTP2_METHOD_*`,
`HTTP2_ERROR_*`, `HTTP2_SETTINGS_*` and debug symbols.

**fs.** `fs.Dirent` and `fs.Stats` are exported, and `readdir`/`readdirSync`/
`fs.promises.readdir` honour `withFileTypes` using the dirent type from the
directory read (no per-entry `stat`). `fs.access`/`accessSync` check existence and
the permission bits of `stat`; `fs.mkdtemp`/`mkdtempSync` exist (random suffix,
`EEXIST` retry). `fs.constants` keeps `F_OK`/`R_OK`/`W_OK`/`X_OK`.

**os / path / url / zlib.** `os.EOL`; `path.parse`, `path.format`,
`path.toNamespacedPath`, and a `path.win32` namespace (join, resolve, normalize,
dirname, basename, extname, isAbsolute, parse, format, sep, delimiter) that is
*formatting only* — filesystem access stays POSIX. `url.urlToHttpOptions`;
`zlib.crc32` (returns the unsigned 32-bit value, matching Node).

**Modules.** `dns/promises` and `node:dns/promises` resolve to the same object as
`dns.promises` (callback and promise APIs, `lookup` plus the record types DJS
supports). Every `require` function exposes `cache`, `main` and `extensions`;
module objects carry `children`, `path` and `paths`. Limits: `module.parent` is
always `null`, `module.children` is not populated, and entries registered in
`require.extensions` are not consulted by the loader.

**Streams.** `Readable.prototype.setEncoding` now exists and decodes with a
`StringDecoder`, so multi-byte characters split across chunks survive; `data`
events carry strings after it is called. `getDefaultHighWaterMark` and
`setDefaultHighWaterMark` return and store Node's defaults (16384 / 16 for
object mode); no stream enforces them yet, so they are informational.

**ESM builtins.** A builtin's named exports now mirror every enumerable key of
its CommonJS object, so `import { createServer } from 'node:http'` and
`import { createHash } from 'node:crypto'` work wherever `require` does; the
default binding for `node:crypto`, `node:zlib`, `node:dgram` and `node:readline`
used to resolve to the process object. `tests/js/esm_builtin_parity` fails when
the two surfaces drift. `node:constants` and `node:punycode` remain absent, so
importing them fails rather than returning a stub.

**CLI terminal surface.** `process.stdout`/`stderr` expose `isTTY`,
`columns`, `rows` and `hasColors(count, env)` (honours `FORCE_COLOR`, `NO_COLOR`
and `TERM=dumb`); `process.stdin` exposes `isTTY` and `setRawMode`.
`readline.cursorTo`, `moveCursor`, `clearLine` and `clearScreenDown` write the
corresponding ANSI sequences. `stdin.setRawMode` is currently a no-op: termios is
not wired up, so interactive prompts fall back to line-buffered input. `columns`
and `rows` come from the `COLUMNS`/`LINES` environment variables, defaulting to
80x24, rather than from `TIOCGWINSZ`.

## Processes and CLI

- `process.argv` for `djs -e '<code>'` is `["djs"]`; the code string is not an
  argument. For a file it is `["djs", "<file>", ...args]`.
- `process.env` is a mutable snapshot taken at startup (already filtered by the
  `env` permission at construction). Assigning to it changes the JS object but
  does not call `setenv`, and changes made to the real environment after
  startup are not visible.
- `process.exit(code)` is a request. Synchronous code after the call still runs
  (`process.exit(0); console.log("still here")` prints), queued microtasks are
  not run, and timers scheduled for later do not fire.
- `process.memoryUsage()` returns `rss`, `heapTotal`, `heapUsed`, `external`
  and `arrayBuffers`. `heapUsed` counts the QuickJS heap; `arrayBuffers` is the
  exact live ArrayBuffer byte count (QuickJS carries a small accounting patch)
  and `external` reports the same total.
- `process.cpuUsage()`, `process.umask()`, `process.hrtime()` (and
  `hrtime.bigint()`), `process.uptime()` and `process.kill(pid, signal)` are
  implemented (v0.11.0). `kill` takes names or numbers, needs the `sys:kill`
  grant, and throws `ESRCH` for an unknown pid.
- `process.nextTick(cb)` enqueues on the same job queue as promises, so it runs
  in scheduling order with `.then` callbacks rather than before all of them as
  in Node.
- `process.on`/`once`/`off` accept any event name (v0.16.2). `exit` is emitted
  with the code at teardown, `beforeExit` when the loop drains (work scheduled
  by its listener keeps the process alive), and `unhandledRejection` listeners
  receive `(reason, promise)` and suppress the abort. `rejectionHandled` is
  emitted with the promise when a rejection that was already reported gets a
  handler in a later turn, including a handler attached from inside the
  `unhandledRejection` listener (v0.16.2; the same-turn case emits neither
  event, as in Node). At most 1024 reported rejections are retained for this;
  beyond that a late handler emits nothing. `uncaughtException` can be
  registered but is never emitted. Signal
  listeners receive the numeric signal and do not keep the loop alive.
- `process.reallyExit` is not provided.
- The platform string comes from the build (`version(linux)`), not a runtime
  probe.
- The REPL is line-at-a-time and prints the raw `String(value)` of an
  expression result (objects print as `[object Object]`), not `util.inspect`.
  Timers with a ready deadline run before the next prompt; pending timers are
  closed at EOF instead of keeping the process alive.

## Permissions

This is the deliberate default divergence: unlike Node, DJS denies read,
write, env and host-information access unless granted. `-A` restores legacy
behaviour; `--deny-*` wins over grants and `-A`.

- Scopes are `read`, `write`, `env`, `sys`, `net`, `run`, `listen`, `ffi`,
  `import`. `read`, `write`, `env`, `sys`, `net`, `run` and `listen` are
  enforced at the native choke points; `ffi` and `import` are parsed, stored
  and reported by `process.permission`, but no API consumes them (there is no
  FFI surface and no remote loader).
- `process.env` is filtered at construction: denied names are absent, so
  enumeration does not leak them. It remains a read-only snapshot (no
  `setenv`), and writes to the JS object are not gated.
- Module loading (`import`/`require` of the script's graph) is exempt from the
  `read` grant because it happens before user code and is confined to the
  project root. Computed imports are confined the same way.
- `os.hostname`/`os.release` need `sys:hostname`/`sys:osRelease`;
  `os.homedir` needs `env:HOME`; `os.tmpdir` reads `env:TMPDIR` and falls
  back to `/tmp` when the grant is missing; `os.cpus` and the
  memory functions need `sys:cpus`/`sys:systemMemoryInfo`.
- `fs.link` needs the write grant on **both** paths (the new link shares
  the source inode, so a read-only source must not become writable through
  the link). `dgram.bind` is gated by `listen`, not `net`.
- `package.json` set `ignore` rules are currently treated as `deny`; dedicated
  ignore semantics (hide rather than throw) are future work.
- Prompts are TTY-only; non-TTY or `--no-prompt` fails closed. Async fs denial
  is delivered to the callback (before the request is queued), not thrown.
- Audit JSONL uses an integer epoch `time` field, not Deno's datetime string,
  and records env variable names (never values) on enumeration.
- The permission check is a seat belt, not a kernel sandbox: native memory
  corruption can bypass it. Landlock is planned separately.

## Hardening (v0.16.4)

A security-driven pass over the permission model, the HTTP/TLS layers and
the fs workers. Each item has a regression test (`tests/js/*` or
`scripts/gate-permissions.sh`).

**Permission model.** A TTY prompt can no longer override an explicit
`--deny-*` rule or a dropped scope, `process.permission.has()` no longer
prompts/grants/audits as a side effect, and building `process.env` no longer
prompts per variable before user code runs. `--allow-read=` (an explicit
empty value) is a startup error instead of a silent whole-category grant;
the same holds for `-R=`/`-E=`/… and for every `--deny-*=` form. `djs.json`
boolean values no longer widen: `"deny": false` means "no denies", not
allow-all, and a `false` allow key means "nothing". A CLI flag for a
category now **replaces** that category's allow rules from a `-P` set
(deny rules always merge), instead of silently unioning both.
`--allow-listen` uses host:port matching like `--allow-net` (`*:8080`,
`localhost`, `*.example.com` now work). The audit log cannot be corrupted
by a long resource string (a stack overflow), escapes control characters,
and fails closed at startup. Outbound `tls.connect`/`https` respect
`--allow-net` (they previously bypassed it), `fs.link` requires write on
both ends, `dgram.bind` requires `listen`, and a scoped `--allow-run`
rejects `LD_*`/`DYLD_*` in a script-supplied child environment.

**TLS.** Certificate verification mode is no longer reset by the ALPN code
path (`SSL_VERIFY_PEER` used to be silently replaced with
`SSL_VERIFY_NONE` for every connection without an ALPN list).
`TlsSocket.setTimeout` is a real idle timer, so `headersTimeout`/
`requestTimeout` bound slowloris clients on HTTPS servers. The server-side
accept handshake runs with a total 10 s deadline (it used to be unbounded),
validates that its fd is a socket, and reports failures as thrown errors.
TLS read/write callback slots are released after firing instead of leaking
per operation.

**HTTP.** Server response headers, status messages and status codes are
validated exactly like the client path (`ERR_INVALID_CHAR`,
`ERR_HTTP_INVALID_STATUS_CODE`) — response splitting through a reflected
header value is no longer possible. A request carrying both
`Transfer-Encoding` and `Content-Length` is destroyed (the request-smuggling
shape), and `chunked` must be the final transfer coding. The client treats
a chunked body cut mid-chunk as `ERR_HTTP_BODY_TRUNCATED` instead of a
complete body, caps announced chunk sizes, verifies inter-chunk CRLF, and
bounds the wait for a partially delivered chunk. Server responses cannot
desync keep-alive pipelines by over-running a declared `content-length`.
A malformed HTTP/2 frame destroys that session instead of killing the
process. Pipelined input is capped while a handler runs.

**fs/workers.** Async fs operations re-verify the identity (device, inode)
of what the worker actually opened against what the permission check saw;
a leaf swapped for a symlink between check and open fails closed with
`EACCES`. Module sources read through a FIFO (or any file whose `fstat`
size lies) are no longer silently truncated at 8 KiB. `package.json`
string escapes are decoded for `main`/`type` (a `"main"` written as
`".\/lib\/x.js"` used to fail resolution).

**crypto.** Cipher key/IV lengths are validated against the cipher before
OpenSSL reads them (a short key used to read past the buffer inside
OpenSSL). `pbkdf2` iteration/keylen and RSA modulus parameters are bounded
(they run uninterruptibly on the loop thread).

**Surface additions.** `process.arch` exists (it was missing entirely);
`Buffer` implements `utf16le`/`ucs2` in both directions; encoding names are
case-insensitive like Node's; `fetch` honours `AbortSignal`;
`structuredClone` defines own properties instead of writing through
`__proto__`; the legacy `stream.Stream` constructor keeps `pipe`;
`fs.cpSync` copies symlinks as symlinks (`dereference: true` copies
contents). The CJS named-export scanner recognizes `exports['quoted-key']`
and `module.exports['quoted-key']` assignments (matching cjs-module-lexer),
no longer treats `==` comparisons as exports, and non-identifier names are
exposed through string export names in the ESM facade instead of
generating invalid syntax.

## macOS

The runtime builds and runs natively on macOS arm64 (`--config=macos`). The
following are the current platform differences:

- **`fs.watch` uses libuv fs events** (`uv_fs_event`): inotify on Linux,
  FSEvents for directories and kqueue for files on macOS. On macOS, FSEvents
  coalesces and may report a write as `rename` before later reporting
  `change` (Node inherits the same behaviour); FSEvents also replays recent
  history, so a listener can see an event for the watched directory's own
  creation. Recursive watching currently uses the prelude's per-directory
  walk on both platforms.
- **`process.memoryUsage().rss` reports peak RSS** (via `getrusage`) rather
  than current RSS; Linux reads `/proc/self/statm` for the current value.
- **The resolver does not read `/etc/hosts`** on either platform; it queries
  DNS directly. Node honors the hosts file.
- **TLS trust store** is whatever the linked OpenSSL was built with (Homebrew's
  OpenSSL 3 CA file for `--config=macos`), not the macOS Keychain.
- **Toolchain:** macOS requires LDC 1.43 or newer (Homebrew); the Linux pins do
  not apply. `integration.sh`/`gate.sh` remain Linux-only.

## fs

- `readFile`/`readFileSync` return a `Buffer` (a `Uint8Array` subclass).
- Write functions accept `utf8`, `latin1`/`binary`, `ascii`, `hex` and `base64`
  for string data. `utf16le`/`ucs2` are not implemented. `ArrayBuffer`, typed
  array and `DataView` inputs are copied byte-for-byte.
- `readFile` caps a single read at 512 MiB (`DJS_MAX_FILE_SIZE` can lower it)
  and non-regular files at 16 MiB. Exceeding the cap fails with `EFBIG`;
  Node reads up to its own 2 GiB string limit.
- Path-based async fs and `fs.open` run blocking POSIX calls on the libuv
  threadpool via `uv_queue_work`, not `uv_fs_*` (see ARCH §9.4). An in-flight
  blocking request cannot be cancelled; `process.exit()` still terminates, but
  its callback never runs.
- File descriptors are tracked per runtime. `read`/`write`/`fstat`/`fsync`/
  `close` refuse descriptors DJS did not open (`EBADF`), so a script cannot
  close libuv's epoll/eventfd descriptors and abort the process.
- `mkdir` supports `{ recursive: true }`; `mode` is applied to the leaf and
  every created component (subject to the process umask). `rm` covers removal
  (file, or directory with `{ recursive: true }`).
- Surface: `readFile`, `writeFile`, `appendFile`, `stat`/`lstat`/`fstat`,
  `readdir`, `mkdir`, `rm`, `unlink`, `rename`, `copyFile`, `realpath`,
  `open`/`read`/`write`/`close`/`fsync`/`fdatasync`, `chmod`/`chown`,
  `link`/`symlink`/`readlink`, `truncate`, plus `cp`/`cpSync` (v0.15.1),
  `readv`/`writev` (v0.15.1), `openAsBlob` (v0.15.1), `statfs`/`statfsSync`
  (v0.11.0), `opendir` (v0.12.1; since v0.16.2 the `Dir` has `read`/`readSync`,
  `close` (promise or callback) and async iteration),
  `watch` (v0.12.3, inotify, `recursive` supported since v0.15.1),
  `watchFile`/`unwatchFile` (polling; `unwatchFile(file, listener)` removes one
  poller, `unwatchFile(file)` all of them) and `glob`/`globSync`. `rmdir` and
  `utimes` are not exposed.
- `stat`/`lstat`/`fstat` return `size`, `mode`, `mtimeMs`, `atimeMs`,
  `ctimeMs`, `ino`, `dev`, `nlink`, `uid`, `gid`, `blksize`, `blocks`, `rdev`,
  `Date` forms (`atime`/`mtime`/`ctime`/`birthtime`), `birthtimeMs` (aliased to
  ctime), and `isFile`/`isDirectory`/`isSymbolicLink`/`isFIFO`/`isSocket`/
  `isCharacterDevice`/`isBlockDevice`. The D `stat_t` binding has whole-second
  timestamps, so the `*Ms` values are second-granular; birthtime is not a real
  birth time. The `bigint` and `throwIfNoEntry` options are not provided.
- `fs.promises` covers `readFile`, `writeFile`, `appendFile`, `stat`,
  `readdir`, `mkdir`, `unlink`, `rename`, `copyFile`, `rm`, `realpath`,
  `open` (a `FileHandle`), `lstat`, `chmod`, `chown`, `link`, `symlink`,
  `readlink`, `truncate`, `cp`, `readv`/`writev`, `statfs`, `opendir` and
  `glob`. `FileHandle` provides `read`, `write`, `stat`, `truncate`, `chmod`, `chown`,
  `sync`, `datasync`, `readFile`, `writeFile` and `close`; it is not yet
  async-disposable and has no stream helpers.
- Error objects carry `code`, `errno`, `path` and `syscall`. `err.stack` does
  not repeat the `message` line (the uncaught reporter prints the head
  separately); Node's `err.stack` starts with `Name: message`.

## net, dns, http, fetch

- `net` has both a TCP client and a server (`Socket`, `connect`,
  `createConnection`, `createServer`). Sockets are nonblocking POSIX
  descriptors watched by `uv_poll`; IPv4 and IPv6 literals work;
  `setNoDelay`/`setKeepAlive` are no-ops and there is no connect timeout or
  half-close state machine. The table holds 128 sockets and 8 listeners. TLS is
  a separate module (`tls`), not a `Socket` upgrade.
- `dns.lookup` uses a blocking `getaddrinfo` and returns IPv4 or IPv6 (family
  6 for `::1`). The `resolve*` family is a DNS packet client over UDP and
  honours `setServers`/`getServers` (A/AAAA included, v0.16.2; they used to go
  through `getaddrinfo` and ignore the configured servers): `resolve`,
  `resolve4`, `resolve6`, `resolveMx`, `resolveTxt`, `resolveSrv`,
  `resolveCname`, `resolveNs`, `resolvePtr`, `resolveSoa` are implemented; `dns.promises` mirrors the
  record types (including `resolve4`/`resolve6`, v0.16.2) and `reverse`
  (IPv4 and IPv6 PTR names). `lookupService` (v0.16.2) is a `getnameinfo`
  request in the same style, returning `(hostname, service)`; it validates the
  address and port synchronously the way Node does. `resolveAny` (v0.16.2) is an
  ANY (qtype 255) query that reports every answer record with its `type`
  attached — A/AAAA (with `ttl`), CNAME, NS, PTR, MX, SRV, SOA, TXT, CAA and
  NAPTR — and `ENODATA` when the answer is empty. One deliberate divergence: if
  an ANY answer carries a CNAME, c-ares (and therefore Node) returns only that
  CNAME, while DJS reports every record in the answer.
- `http` has a client and a server: keep-alive, pipelining, chunked request
  bodies, HEAD, `Expect: 100-continue`, header and request deadlines, graceful
  `close()` drain (v0.11.1) and an `upgrade` handoff for WebSocket (v0.13.7).
  There are no redirects, proxies, trailers or request streaming
  (`ClientRequest` buffers the body until `end()`), and the agent does not pool
  sockets.
- `fetch` supports `http://` and `https://`, does not follow redirects (a 302
  is returned as the response), accepts `AbortSignal`, follows no proxies and
  buffers the body but also exposes `Response.body` as a web stream (v0.13.2–4).
  `Headers`, `Request`, `Response`, `FormData`, `Blob` and `File` exist; a
  non-2xx status still resolves.
- `https`, `tls.connect` and `fetch("https://…")` use OpenSSL with system or
  custom CA verification (see TLS and HTTPS below).
- `--allow-net=host:port` gates `net.connect`, DNS lookups and `fetch`. Rules
  accept `*`, `host`, `host:*`, `host:port` and `*:port`; a DNS lookup is
  matched on the host part. There is no separate `tls` permission.

## child_process

- `spawn`, `spawnSync`, `exec`, `execFile`, `execSync`, `execFileSync` and
  `fork` are implemented.
- `spawnSync` returns `{ status, signal, stdout, stderr }` with UTF-8 strings,
  matching Node's default (Node returns Buffers only with
  `encoding: "buffer"`). `execSync`/`execFileSync` return a Buffer, or a string
  when `encoding` is set, and throw on a non-zero status.
- `spawn` returns a `ChildProcess` with `stdout`/`stderr` Readables, a
  `Writable` `stdin`, a `stdio` array (`[stdin, stdout, stderr]`), `pid`,
  `kill`, `killed`, and `spawn`/`exit`/`close` events (v0.16.2). Stdio is
  pipe-based and polled by a 5 ms libuv timer, not `uv_spawn`; the `stdio`
  option is not honoured (children always get pipes), and there is no
  `detached` or `unref`. `stdin.write` copies into a per-child queue (16 MiB
  cap) flushed by the poll timer, so a full pipe never blocks the loop and
  bytes are not silently dropped; writing after the child exits returns `false`.
- `fork` adds newline-JSON IPC over a loopback socket with a token handshake
  (v0.15.3): `child.send`, `child.connected`, `process.send` and
  `process.on("message")`. `spawn`/`fork` honour `options.env` (v0.15.4).
- `shell: true` is supported for `spawnSync`/`execFileSync`/`execSync` only.
  Arguments are concatenated with spaces and **not quoted** (same caveat as
  Node's DEP0190): never pass untrusted arguments with `shell: true`.
- `--allow-run=cmd` matches the exact command string. A bare name is resolved
  through `PATH` by `execvp`; a path grant must match that path. `execSync`
  runs `sh`, so either `--allow-run=sh` or `--allow-run=/bin/sh` works.
  Explicit `--deny-run` rules win over `-A` and over either grant.
  `LD_*`/`DYLD_*` variables in a script-supplied child environment are
  rejected unless the run grant is unscoped (`-A` or bare `--allow-run`);
  they would execute native code outside every permission check.
  `cwd` is validated before fork; a missing directory throws `ENOENT`.
- A signal death reports `status`/`exitCode` `null` and a named
  `signal`/`signalCode` (e.g. `SIGTERM`), for `spawnSync` and for `spawn`'s
  `exit`/`close` events, as Node does (v0.16.2; it used to be `128 + signal`
  and a number). `kill()` accepts numbers and the names `SIGTERM`, `SIGKILL`,
  `SIGINT`, `SIGHUP`, `SIGQUIT`.
- Children are not killed when the runtime exits; `process.exit()` returns
  promptly and leaves them running, as Node does. `spawnSync` supports
  `timeout`/`maxBuffer` (`ETIMEDOUT`, `ERR_CHILD_PROCESS_STDIO_MAXBUFFER`,
  v0.11.1), and `input` accepts a string or Buffer (converted to UTF-8).
  Stdout/stderr are decoded as UTF-8, so binary output is not byte-preserving.
- The child table is 64 entries. Exhaustion throws before forking; the table
  slot is released when the child is reaped.

## crypto and zlib

- `crypto.createHash`/`createHmac` support `sha256`, `sha1`, `sha384`,
  `sha512` and `md5`; `update` accepts strings, Buffers, TypedArrays and
  ArrayBuffers and hashes raw bytes (never a string coercion). `digest()`
  returns a Buffer, `digest(enc)` a string. `randomBytes(n)` is capped at
  64 KiB and uses `RAND_bytes`; `randomUUID()` is a v4 UUID.
- No cipher, key derivation, certificate, `sign`/`verify`, `diffieHellman` or
  `webcrypto` API is provided. `timingSafeEqual` is absent.
- `zlib` provides `deflateSync`/`inflateSync`, `gzipSync`/`gunzipSync`,
  `deflateRawSync`/`inflateRawSync` and `createDeflate`/`createInflate`/
  `createGzip`/`createGunzip`/`createDeflateRaw`/`createInflateRaw`.
  Compression streams emit one zlib/gzip stream, not concatenated members;
  a truncated compressed input raises `Z_BUF_ERROR`. There are no dictionary,
  flush-mode or `maxOutputLength` options, and `crc32` is absent.

## Fetch streaming and forms (v0.13.3–v0.13.4)

- `Response.body` is a `ReadableStream` for fetched responses; `text()`,
  `json()` and `arrayBuffer()` drain it and cache the buffer.
- `FormData` exists with `append`/`get`/`getAll`/`has`/`set`/`delete`/
  `forEach`/`entries`/`keys`/`values`. It is not yet encoded by `fetch` as
  multipart.
- `Headers` is iterable (`[...headers]`).
- HTTP client responses are parsed incrementally: `response` is emitted once
  headers arrive and body chunks are pushed as they are received
  (`content-length`, `chunked`, close-delimited, and bodyless HEAD/204/304).
  SSE consumers therefore see tokens as they are produced.
- `ClientRequest` now copies only own header properties; a `Headers` instance
  is unwrapped by its `forEach` instead of exposing prototype methods.

## Fetch primitives (v0.13.2)

- `Headers`: `get`/`has`/`set`/`append`/`delete`/`forEach`/`entries`/`keys`/
  `values`, and construction from a plain object or another `Headers`.
- `Request` is a global constructor: `url`, `method`, `headers`, `text()`,
  `json()`, `arrayBuffer()`, `clone()`, `bodyUsed`. Bodies are strings or
  Buffers.
- `Response` accepts a `Headers` instance in `init.headers` (previously it
  stringified the internal map).
- `fetch` remains a client-only function; there is no `Blob`, `FormData`,
  stream bodies or `duplex` upload.

## HTTP/2 (v0.13.1)

- `http2.connect("http://host:port")` and `http2.createServer()` speak h2c
  (prior knowledge, no TLS/ALPN), with HEADERS/DATA/SETTINGS/PING/GOAWAY/
  RST_STREAM frames and multiplexed streams.
- HPACK decodes indexed, literal and dynamic-table fields, including Huffman
  strings; encoding uses the static table and literal-without-indexing (no
  Huffman output).
- No flow-control accounting (WINDOW_UPDATE is ignored), no server push,
  trailers, priority, or CONTINUATION reassembly; header blocks above the
  peer's max frame size fail.

## WebSocket (v0.13.0)

- `require("djs:ws")` exports `WebSocket` (client, `ws://` only) and
  `WebSocketServer` (raw `net` listener with its own handshake).
- Frames: text/binary/close/ping/pong, FIN-only messages (no fragmentation),
  client masking and accept-key validation.
- Server upgrade is implemented on the WebSocket server's own listener, not
  through `http.Server`'s `upgrade` event; `wss://`, permessage-deflate and
  subprotocol negotiation are absent.

## Web Streams (v0.12.7)

- `require("stream/web")` provides `ReadableStream`, `WritableStream` and
  `TransformStream` with controllers (`enqueue`/`close`/`error`,
  `desiredSize`), readers/writers, `pipeTo`, async iteration and transform
  flush.
- Backpressure is queue-based inside the readable: `pull` is called only when
  the queue is empty and there are pending reads. Writes are serialized on a
  promise chain.
- Byte streams (`ReadableStream` type `"bytes"` with BYOB readers), queuing
  strategies and `TextEncoderStream`/`TextDecoderStream` are not implemented.

## VM contexts (v0.12.6)

- `vm.runInThisContext` evaluates in the current global scope.
- `vm.runInNewContext(code, sandbox)` creates a **fresh QuickJS context** on the
  same runtime: no `require`, `process`, `fs` or network globals; only JSON
  sandbox values are visible. Results cross the boundary as JSON, so functions,
  symbols and cycles are rejected with `ERR_VM_RESULT`.
- `vm.Script` supports `runInThisContext`/`runInNewContext`.
- Script and sandbox JSON are transferred, not shared, so sandbox object
  mutations do not propagate back to the caller.

## diagnostics, perf and EventSource (v0.15.2)

- `diagnostics_channel` (channel/subscribe/publish hasSubscribers),
  `trace_events` (inert tracing API).
- `perf_hooks.performance.mark/measure` and entry queries; `PerformanceObserver`
  accepts observers but does not dispatch records.
- global `EventSource` with SSE parsing, custom events, reconnect and `close`.
- `ClientRequest.abort()`/`destroy()`.
- `inspector` stays absent pending the V8 research phase; `v8` is a shim (see
the v0.16.2 section).

## fs breadth (v0.15.1)

- `cp`/`cpSync` (recursive trees, symlinks, `force`, `errorOnExist`,
  `dereference`), `readv`/`writev` (+sync/promise), `openAsBlob`, and
  `watch(..., {recursive:true})`.
- Residual: `cp` does not preserve mode/timestamps or run filters; recursive
  watch does not prune deleted-directory watchers.

## stream/consumers and readline/promises (v0.16.1)

- `stream/consumers`: `buffer`, `text`, `json`, `arrayBuffer`, `blob`.
- `readline/promises`: `createInterface` with Promise `question()` and async
  iteration. Mixing `question()` and iteration on one interface can lose a line.

## Core API long tail (v0.16.0)

- `process.ppid`/`title`, `crypto.getRandomValues`, `AbortSignal.any`,
  `util.parseArgs`/`styleText`, `url.fileURLToPath`/`pathToFileURL`,
  `fs.glob`/`globSync`, and the `timers` builtin.
- `process.title` is JS-only; `fs.glob` is a simple `*`/`**`/`?` walker.

## cluster (v0.15.8)

- `cluster.isPrimary`/`isWorker`, `fork(env)`, `workers`, worker
  `send`/`kill`/`disconnect`, `message`/`exit`, primary `fork`/`online`/`exit`,
  and `cluster.worker` in children.
- Workers share a port through `SO_REUSEPORT`; this is kernel balancing, not
  Node's round-robin handle passing. `process.pid` is now available.

## ALPN and HTTP/2 over TLS (v0.15.7)

- TLS server selects ALPN by server preference; `socket.alpnProtocol` is set on
  both sides.
- `http2.createSecureServer({cert,key,alpn})` accepts only `h2`-negotiated
  sockets; `http2.connect("https://...")` performs TLS + ALPN first.
- HTTP/2 trailers/flow-control remain the existing subset.

## fork IPC (v0.15.3)

- `process.execPath`.
- `child_process.fork` with `child.send`, `child.connected`,
  `process.send`/`process.on("message")`, newline-JSON IPC. The transport is a
  loopback socket with a token handshake and environment variables (not
  Node's fd 3).
- `spawn`/`fork` honour `options.env` (v0.15.4); fork children get
  `--allow-net`/`--allow-env`.
- No `cluster` handle passing.

## child_process async APIs (v0.15.0)

- `exec(command, options, cb)` and `execFile(file, args, options, cb)` over
  async `spawn`.
- `timeout`/`killSignal` → `ETIMEDOUT`; `maxBuffer` (1 MiB default) →
  `ERR_CHILD_PROCESS_STDIO_MAXBUFFER`; `encoding: "buffer"` returns Buffers.
- Errors carry `code`, `signal`, `killed`, `cmd`, `stdout`, `stderr`;
  `ChildProcess.exitCode`/`signalCode` are set.
- Still missing: `fork`/IPC, `detached`, `stdio: "inherit"`, Windows shells.

## Stream state and module diagnostics (v0.14.4)

- Every `Readable` exposes `_readableState` (`endEmitted`, `objectMode`,
  computed `length`); `Socket` no longer patches it in.
- Module errors include the specifier in `message` as well as `path`.
- Still not a fully conformant Duplex: `cork` is a no-op and flow control is
  queue-based.

## Prelude layout (v0.14.3)

Internal only: the prelude is now seven ordered files under `js/prelude/`,
concatenated by `src/djs/runtime.d`. Public behaviour is unchanged; edits must
target the owning module and a rebuild is required.

## Module entries and connection lifecycle (v0.14.2)

- CommonJS entries run inside the module wrapper: top-level `var` is
  module-scoped, `module`/`exports`/`require` and absolute
  `__filename`/`__dirname` come from the wrapper, and `#!` is stripped.
- Upgraded HTTP connections leave `server._connections` and clear the header
  timeout, so `server.close()` does not wait on them.
- `Readable.toWeb` honours Web Streams backpressure.

## Async context (not available)

`async_hooks`/`AsyncLocalStorage` are **not implemented**. QuickJS-ng's promise
hook only carries a parent for `.then`; async functions resume without one, so
context cannot survive `await` without engine-level async-context support. A
promise-hook shim lost context and its fallback segfaulted, so it was removed.
`require("async_hooks")` remains unavailable until the engine provides async
context. This is a deliberate compatibility limit, not a pending bug.

## Real-library compatibility (v0.14.1)

- Client `http.request` emits `upgrade(res, socket, head)` on `101`.
- `crypto.randomFillSync`/`randomFill`, `createSecretKey`, `KeyObject.from`,
  `KeyObject.asymmetricKeyType`/`asymmetricKeyDetails`, callback forms of
  `crypto.sign`/`verify`.
- Socket/Writable expose `_readableState`/`_writableState`; `cork`/`uncork` are
  no-ops.
- Gate step 14 runs real `ws` and `jose` against the runtime.

## DNS record types (v0.14.0)

- `resolveMx`, `resolveTxt`, `resolveSrv`, `resolveCname`, `resolveNs`,
  `resolvePtr`, `resolveSoa`, `resolve(host, type)` and the matching
  `dns.promises` methods.
- `setServers`/`getServers`; resolver list from `/etc/resolv.conf`, 2 s
  timeout, retry across servers, `ENOTFOUND` on NXDOMAIN.
- No DNSSEC, EDNS0, TCP fallback, CNAME chasing or `reverse()`.

## WebCrypto `subtle` (v0.13.9)

- `digest` (SHA-1/256/384/512), HMAC sign/verify, AES-GCM encrypt/decrypt with
  AAD and auth tag, PBKDF2/HKDF `deriveBits`, `deriveKey`.
- `generateKey` for HMAC, AES-GCM/CBC, RSA (RSASSA/RSA-OAEP) and ECDSA/ECDH
  (P-256/384/521).
- `importKey`/`exportKey`: raw, SPKI, PKCS#8, and oct JWK; RSA/EC JWK input is
  converted to DER in JS.
- Missing: asymmetric JWK export, wrapKey/unwrapKey, RSA-OAEP encrypt/decrypt,
  AES-CBC/KW, usage enforcement, `CryptoKey` equality.

## Brotli and content decoding (v0.13.8)

- `zlib.brotliCompressSync` / `brotliDecompressSync` (quality via
  `params[BROTLI_PARAM_QUALITY]`) and `BROTLI_PARAM_QUALITY` in constants.
- `fetch` decodes `content-encoding: gzip`, `deflate` and `br` when the body
  is consumed; compressed responses are buffered before decoding, so SSE over
  compression loses incremental delivery.
- DNS breadth (`resolveMx`/`Txt`/`Srv`/`Cname`) is still absent.

## Blob, File and multipart (v0.13.7)

- Global `Blob` (`text`, `arrayBuffer`, `stream`, `slice`, `size`, `type`) and
  `File` (name, lastModified).
- `FormData.append` accepts strings and Blobs with an optional filename;
  `fetch` encodes FormData as multipart with a random boundary and sets
  `content-type`.
- A Blob passed as `fetch` body is sent as bytes with its type as
  `content-type`.
- Not provided: `Blob` from a stream source, `formData()` request parsing,
  `FileReader`.

## HTTP upgrade (v0.13.7)

- `http.Server` emits `upgrade(req, socket, head)` for requests with
  `Connection: upgrade` and an `Upgrade` header; the HTTP parser stops and the
  raw socket is handed over. `head` contains bytes received after the headers.
- With no `upgrade` listener the socket is destroyed.
- Works for `ws`/`socket.io`-style handshakes; the TLS server shares the same
  parser.

## Crypto core (v0.13.7)

- `crypto.hkdf` async exists alongside `hkdfSync`.
- `generateKeyPairSync`/`generateKeyPair` support RSA (2048 default),
  EC P-256/P-384/P-521 and Ed25519; keys export as PEM, `KeyObject.export`
  also decodes the PEM body for `format: "der"`.
- `createSign`/`createVerify` buffer `update()` and sign/verify once.
- `X509Certificate` parses PEM certificates: `subject`, `issuer`,
  `validFrom`/`validTo` (OpenSSL text form plus `*Date` objects),
  `fingerprint256`, `serialNumber`, `checkHost`.
- Missing: X509 chain/CA verification, `checkPrivateKey`, custom RSA public
  exponent, encrypted key export, Diffie-Hellman.

## Stream interop (v0.13.6)

- `Readable.toWeb` / `Readable.fromWeb` (text and `{objectMode:true}`),
  `Writable.toWeb` / `Writable.fromWeb`, `Duplex.toWeb`,
  `stream.addAbortSignal`.
- `ReadableStream`, `WritableStream` and `TransformStream` are also globals,
  matching Node 18+.
- Backpressure is queue-based: `toWeb` enqueues unbounded; `fromWeb` pumps one
  read at a time and respects the reader promise.

## Module resolution (v0.13.6)

- `require.resolve(spec)` exists on the global `require` and on every
  module-scoped `require`; it returns the canonical path, or the specifier for
  builtins, and throws `MODULE_NOT_FOUND` with `code` otherwise.
- `createRequire(filename | file:// URL).resolve` uses the same resolver.
- Entry `.js` scripts receive absolute `__filename`/`__dirname` and global
  `module`/`exports` objects (`module.id` is `"."`), matching the CommonJS
  entry shape. Top-level `var`s still live on the global object because entry
  scripts are not wrapped.
- Resolution is bounded by the project root (entry directory); paths outside
  it fail with `MODULE_NOT_FOUND` by design.
- Not provided: `import.meta.resolve`, `require.cache`, `require.main`,
  `Module._resolveFilename`.

## Buffer (v0.13.6)

- Fixed-width accessors: `readUInt8/16/32/64`, `readInt8/16/32/64`,
  `readFloat/Double`, `readBigUInt64/BigInt64` and the `write*` counterparts,
  LE and BE. Out-of-range offsets throw `RangeError` with `ERR_OUT_OF_RANGE`.
- Variable-width `readUIntLE/BE`, `readIntLE/BE`, `write*` for 1–6 bytes.
- `copy`, `indexOf`/`lastIndexOf`/`includes` (number, string, Buffer,
  byteOffset), `fill` with pattern/encoding, `swap16/32/64`, `toJSON`.
- `Buffer.from(Buffer)` copies; `Buffer.from(ArrayBuffer)` shares.
- `base64url` works for both `Buffer.from(str, "base64url")` and
  `toString("base64url")`; `Buffer.isEncoding` covers the Node encodings.
- Not provided: pooling/`allocUnsafe` zero-fill semantics, `transcode`,
  custom inspect output.

## Assertions and module helpers (v0.13.5)

- `assert`: `ok`, `equal`/`notEqual`, `strictEqual`/`notStrictEqual`,
  `deepEqual`/`deepStrictEqual` (prototypes, Map/Set, Date, RegExp, Buffer,
  typed arrays, cycles), `throws`/`doesNotThrow`, `rejects`/`doesNotReject`,
  `fail`, `ifError`, `match`/`doesNotMatch`, `AssertionError` with
  `ERR_ASSERTION` and `actual`/`expected`/`operator`.
- `assert/strict` and `assert.strict` map the equality methods to strict ones.
- `module`: `createRequire(filename | file:// URL)`, `isBuiltin`,
  `builtinModules`, `Module` data class, `syncBuiltinESMExports` no-op.
  `createRequire(...).resolve` returns its input unchanged.
- `stream/promises`: `pipeline` and `finished` promise wrappers over the
  callback versions; stream objects only, no iterables.
- ESM facades exist for every builtin (previously vm/http2/tty/querystring and
  others fell through to `process`).

## Directories and stat polling (v0.12.5)

- `fs.opendir`/`fs.opendirSync` return a `Dir` whose `readSync()` yields
  `{name, path, parentPath, isFile(), isDirectory()}` and `null` at the end;
  `close`/`closeSync` close it. Entries are listed eagerly with `readdirSync`
  (no OS-level directory handle).
- `fs.watchFile(path, {interval}, listener)` polls `stat` (default 5007 ms) and
  calls the listener when mtime or size changes; `close()` stops the timer.
  `fs.unwatchFile` closes all watchers registered for the path; with a listener
  argument it closes only that listener's watcher (v0.16.2 — before that the
  registry was never populated and `unwatchFile` was a no-op).

## DNS records (v0.12.4)

- `dns.resolve4`, `dns.resolve6` and `dns.resolve(host, "A"|"AAAA")` return
  address arrays. At v0.12.4 they came from `getaddrinfo`; since v0.16.2 they
  use the DNS packet client, so `setServers` applies and every record of the
  type is returned. No TTL or CNAME data.
- `MX`, `TXT`, `SRV` and `CNAME` were not implemented at v0.12.4; they landed
  in v0.14.0, `reverse` in v0.16.2, and `resolveAny` (qtype 255, all types in
  one answer) in v0.16.2. `resolve` rejects an unknown type with `ENOTSUP`.
- `resolveAny` results are shaped exactly like Node's, key order included, and
  `ttl` appears only on A/AAAA records. There are no `resolveNaptr` or
  `resolveCaa` methods, but `resolveAny` parses both types.

## File watching (v0.12.3)

- `fs.watch(path, options, listener)` uses inotify: `change` for
  modify/attrib, `rename` for create/delete/move, with the affected filename.
- `FSWatcher.close()` stops the watch and emits `close`. `options.recursive`
  is supported as of v0.15.1 (watchers for deleted directories are not pruned).
- `fs.watchFile`/`fs.unwatchFile` poll with `interval` (default 5007 ms) and
  report the previous/current `Stats`.

## Signatures (v0.12.2)

- `crypto.sign(algorithm, data, key)` and `crypto.verify(algorithm, data, key,
  signature)` accept `"sha256"`/`"RSA-SHA256"` (prefix stripped), a PEM string,
  a PEM file path, or a `KeyObject` from `createPrivateKey`/`createPublicKey`.
- RSA (PKCS#1 v1.5) and EC keys are handled by OpenSSL's default
  `EVP_DigestSign`/`EVP_DigestVerify` flow; PSS padding, passphrase-protected
  keys and certificate PEMs are not exposed yet.

## Network address families (v0.12.1)

- `dns.lookup` resolves `AF_UNSPEC` and reports family 4 or 6.
- `net.connect`/`http` clients accept IPv6 literals (`[::1]` in URLs,
  `::1` in options); `net.Server` can listen on `::1`, `::` and any colon
  address, and `address()` reports `family: 'IPv6'`.
- IPv6 wildcard binds are v6-only (no `IPV6_V6ONLY` clearing), so `::` does
  not also accept IPv4.
- `perf_hooks.performance`, `os.constants.signals`, `os.availableParallelism`
  and `os.machine` exist.

## Crypto breadth (v0.12.0)

- `createCipheriv`/`createDecipheriv` for `aes-128-cbc`, `aes-256-cbc`,
  `aes-128-gcm`, `aes-256-gcm`, with `setAAD`, `getAuthTag`, `setAuthTag`
  and PKCS#7 padding.
- `pbkdf2Sync`/`pbkdf2`, `hkdfSync` (HMAC-based extract+expand) and
  `scryptSync`/`scrypt`.
- Caveat: ciphers are **one-shot**. `update()` buffers and returns an empty
  buffer; `final()` returns the whole ciphertext/plaintext. `setAutoPadding`
  is a no-op because padding is always PKCS#7 (GCM ignores it).
- `sign`/`verify`, key objects and WebCrypto remain for v0.12.1.

## HTTPS server (v0.11.2)

- `https.createServer({cert, key}, handler)` and `tls.createServer` accept PEM
  file paths, negotiate TLS 1.2+ with OpenSSL, and hand the decrypted stream to
  the same HTTP connection state machine as plain HTTP.
- `caFile` + `requestCert: true` enables mutual TLS; `secureConnection`
  sockets expose `authorized` from `tls.peerAuthorized`.
- There is no ALPN selection on the server and no `getPeerCertificate`.
- The handshake runs synchronously in the accept callback (blocking the loop
  for that connection), unlike the client which uses a worker thread.

## HTTP server hardening (v0.11.1)

- Keep-alive (HTTP/1.1 default, HTTP/1.0 opt-in), pipelining (one request at a
  time, responses ordered), chunked request bodies (8 MiB cap), HEAD (no body),
  `Expect: 100-continue`, and `Connection`/`Keep-Alive` response headers.
- `headersTimeout` (60 s), `requestTimeout` (300 s) and `keepAliveTimeout`
  (5 s) destroy stalled sockets; `server.close(cb)` drains busy connections and
  `closeAllConnections`/`closeIdleConnections` are available.
- Request bodies are buffered before the handler's `data` events (8 MiB), not
  streamed from the socket.

## Process, OS, filesystem metadata and dgram options (v0.11.0)

- `process.cpuUsage()` (µs, optional previous sample) and `process.umask()`.
- `process.hrtime()` (array diff) and `hrtime.bigint()` use CLOCK_MONOTONIC;
  `process.uptime()` is since runtime start; `process.kill(pid, signal)` accepts
  names or numbers and needs the `sys:kill` grant. `SIGWINCH` is not in the
  name table (numeric 28 still works on Linux).
- `os.uptime()`, `os.loadavg()`, `os.networkInterfaces()` (IPv4/IPv6, netmask,
  CIDR, loopback flag, zero MAC) and `os.userInfo()`.
- `fs.statfsSync(path)` / `fs.statfs(path, cb)` from `statvfs`; `type` is 0 and
  fsid/flag are platform values.
- `dgram` sockets support `setBroadcast`, `setTTL`, `setMulticastTTL`,
  `addMembership`, `dropMembership` (IPv4 only; the interface argument is
  currently ignored and the default interface is used).

## Node compatibility kernel (v0.10.1)

- `Error.captureStackTrace(obj, ctor)` honours `Error.prepareStackTrace` and
  produces V8-style CallSite objects (`getFileName`, `getLineNumber`,
  `getColumnNumber`, `getFunctionName`, `isEval`, `getEvalOrigin`). QuickJS's
  own `stack` accessor is a string, so the array is installed as an own
  property.
- `require('stream')` is the callable legacy `Stream` constructor with
  `Readable`/`Writable`/`Duplex`/`Transform`/`PassThrough` attached.
- `EventEmitter` methods work on objects that were mixed in without running
  the constructor (Express does this).
- `__dirname` and `__filename` are defined for the main module as well as
  CommonJS modules.
- `fs.ReadStream`/`fs.WriteStream` are real constructors; `instanceof` checks
  in packages such as `destroy`/`send` work.
- `Buffer.allocUnsafeSlow` and `Buffer.compare` exist.
- `tty.isatty`, `querystring` (parse/stringify/escape/unescape) and
  `string_decoder.StringDecoder` (streaming UTF-8 with boundary buffering)
  are builtins.
- `StringDecoder` does not strip a UTF-8 BOM, and non-UTF-8 encodings decode
  per chunk rather than holding partial code units.

## net.Server, HTTP server, dgram and readline

- `net.createServer`/`net.Server` accept IPv4 TCP connections. `listen(port,
  host)` resolves `localhost` to `127.0.0.1`; `0.0.0.0` and `*` bind all IPv4
  interfaces. `listen` requires `--allow-listen=host:port` (default deny).
  Accepted sockets are ordinary `net.Socket`s. There are 128 socket slots and
  8 listeners; stale socket ids are generation-tagged.
- `http.createServer` parses HTTP/1.1 requests with a 16 KiB header limit and
  an 8 MiB `content-length` body limit. Responses default to `Connection:
  close`; `res.write` streams chunked, `res.end` sends `content-length` when
  the body is small and no length was set. There is no keep-alive, no chunked
  **request** body decoding, no `Expect: 100-continue`, no trailers, no
  upgrade/WebSocket and no request/response timeouts. `https.createServer`
  throws `ERR_TLS_SERVER_UNSUPPORTED`.
- `dgram.createSocket('udp4')` supports `bind`, `send`, `address`, `close` and
  `message` events. Both bind and send are gated by the `net` permission with
  `host:port`. IPv4 only; no multicast, broadcast or `setTTL` options.
- `readline.createInterface({input, output})` splits on LF (tolerating CRLF),
  emits `line`/`close` and supports `question`; `readline/promises` is
  available (v0.16.1). No history, editing or terminal raw mode.
- `worker_threads` is a child-process-backed shim (v0.15.9): `Worker`,
  `workerData`, `parentPort`, messages, `terminate`, `eval`. It is not a real
  thread: no shared memory/`SharedArrayBuffer`/`Atomics`, no transferables.
- The old stub note: `isMainThread` was true and `Worker` threw
  `ERR_WORKER_THREADS_UNSUPPORTED`; see `docs/adr/0002-worker-threads.md`.

## TLS and HTTPS

- `tls.connect({host, port, servername, rejectUnauthorized, caFile, certFile,
  keyFile, alpn})` returns a Duplex socket. The TCP connect and TLS handshake
  run on a libuv worker thread with a 10 second timeout; reads/writes stay on
  the loop. `authorized` is set on connect, and verification failures surface
  as `ERR_TLS_HANDSHAKE`.
- `caFile`/`ca` loads a custom CA bundle; `certFile`/`keyFile` present a client
  certificate; `alpn` is advertised and the selected value is exposed as
  `alpnProtocol`. Values are file paths, not PEM strings.
- `rejectUnauthorized: false` disables both chain and hostname verification.
  Otherwise the system CA store is used and the hostname is checked with
  `SSL_set1_host`. Minimum protocol is TLS 1.2; SNI is sent.
- `https.request`/`https.get` and `fetch(https://...)` use the same transport.
  `fetch` accepts the non-standard `rejectUnauthorized: false` option for
  local/self-signed testing.
- The TLS **server** does not verify client certificates and does not select
  ALPN, so mutual TLS and HTTP/2 over TLS are not complete. There is no session
  resumption or ticket control, and no
  cipher selection. TLS 1.0/1.1 are refused.

## process stdio and signals

- `process.stdout` and `process.stderr` are `Writable` streams backed by
  write(2); writes are synchronous and unbuffered, `fd` is 1/2, and `isTTY` is
  always false (there is no TTY handle).
- `process.stdin` is a `Readable` over fd 0. It starts polling when a
  `data`/`readable` listener or `resume()` is used, stops on `pause()`, and
  pushes null at EOF. It has no `setEncoding`; chunks are Buffers.
- `process.on`/`once`/`off`/`removeListener`/`removeAllListeners`/`listeners`
  accept any event name. Signal listeners (`SIGTERM`, `SIGKILL`, `SIGINT`,
  `SIGHUP`, `SIGQUIT`, `SIGUSR1`, `SIGUSR2`, `SIGWINCH`) receive the numeric
  signal and do not keep the loop alive. `exit` and `beforeExit` are emitted
  (v0.16.2), `unhandledRejection` is dispatched to listeners, and
  `rejectionHandled` is emitted for a late handler; `uncaughtException` can be
  registered but is not emitted.
- `process.kill(pid, signal)` is implemented and requires the `sys:kill`
  grant (see v0.11.0 above); an unknown pid throws `ESRCH`.

## Modules

- Bare specifiers resolve through `node_modules` (walking up to the project
  root), including scoped packages and subpaths, so npm/pnpm/yarn-installed
  packages load without a package manager.
- `package.json` `exports` maps are interpreted: string and conditional
  objects, `node`/`import`/`require`/`default` conditions, exact subpaths and
  one-`*` patterns. An exports map is authoritative (no `main`/index fallback).
  `package.json` `imports` (`#specifier`) are supported for relative and bare
  targets.
- Not supported: `browser`/`development`/custom conditions, chained `#imports`,
  `node_modules` real paths outside the project root (workspace links), Yarn
  PnP, global installs, optional/peer-dependency semantics and native addons.
- ESM named exports from CommonJS are detected heuristically from
  `exports.x`/`module.exports.x`/`module.exports = { x }`/
  `Object.defineProperty`; unusual dynamic patterns expose only `default`.
- ESM importing CommonJS gets the `module.exports` value as `default` plus the
  heuristic named exports above.
- CommonJS `require` of an ES module throws `ERR_REQUIRE_ESM`, never returns a
  namespace.
- `require` is a global in scripts and CommonJS; ES modules can also call it
  (Node's `require` is not defined there).
- `import.meta.url` is `file://` plus the percent-encoded canonical path.
- Import attributes accept `type: "json"`; `text`/`bytes` are rejected.
- All module paths must resolve inside the entry file's directory (symlinks
  are resolved first). There is no `--allow-outside-root`.
- JSON modules are evaluated as `export default <json value>`; there are no
  named exports from JSON.
- Built-in modules available to both `require` and ESM: `events`, `stream`,
  `url`, `util`, `timers/promises` (alongside `fs`, `fs/promises`, `path`, `os`,
  `process`).
- `events` implements the core `EventEmitter` surface; `events.once()` is
  provided, but `captureRejections`/`EventTarget` bridging is not.
- `stream` is a prelude implementation of `Readable`/`Writable`/`Duplex`/
  `Transform`/`PassThrough`, `pipeline` and `finished`. Backpressure, object
  mode edge cases and web-stream interop are simplified; fs streams buffer the
  whole file rather than reading incrementally.
- `url` covers `URL`, `URLSearchParams`, `parse`, `format` and `resolve` for
  http(s)/file-style URLs. It is a parser, not a full WHATWG URL
  implementation: IDNA/punycode and some percent-encoding normalisation differ.
- `util` covers `format`, `inspect`, `promisify`, `callbackify`, `inherits`,
  `deprecate` and a small `types` object; `parseArgs`, `debuglog` and
  `styleText` are absent.
- `structuredClone` handles plain objects, arrays, `Date`, `RegExp`, `Map` and
  `Set`, including cycles; typed arrays, transfer lists and `Blob`/`File` are
  not supported.
- `AbortController`/`AbortSignal` provide `abort()`, `aborted`, `reason`,
  `throwIfAborted()`, `onabort`, `AbortSignal.timeout()` and
  `AbortSignal.abort()`. `fetch` accepts no `AbortSignal` yet;
  the signal is an `EventEmitter` rather than a DOM `EventTarget`.


## Language and runtime

- QuickJS-NG has no `Intl` (no ECMA-402), no WebAssembly, no inspector/CDP, and
  no `worker_threads`. `Atomics.wait` throws because blocking is disabled.
- Timers: delays below 1 ms (or `NaN`) clamp to 1 ms; delays above
  `2^31-1` clamp to 1 ms with a warning; equal deadlines fire FIFO (libuv's
  start-id ordering). `Timeout.refresh()` on an inactive timer is a no-op.
- `queueMicrotask` uses QuickJS's job queue. A self-feeding promise chain is
  capped at 10,000 jobs per loop turn so timers and I/O are not starved.
- Unhandled rejections are reported at the end of each microtask drain and
  exit 1, matching Node's default `throw` mode. `warn`/`none` modes are not
  provided. A rejection observed before `process.exit()` does not overwrite
  the requested exit code.
- `console.log` supports `%s %d %i %f %j %o %O %%`; `console.table`,
  `group`, `time`, `count`, colours and `Symbol.for('nodejs.util.inspect.custom')`
  are not provided.
- Memory limits count the QuickJS heap only; libuv buffers, D allocations and
  the D GC are outside `--memory-limit`. OOM throws a catchable
  `InternalError: out of memory`; an uncaught one exits 1, but a script that
  catches it can continue and exit 0 (there is no forced-exit `oomSeen` policy).
- `process.memoryUsage().arrayBuffers` and `external` both report QuickJS's
  binary-object bytes; `rss` is the process RSS and `heapUsed`/`heapTotal` are
  the QuickJS heap.
  Limits are guardrails, not a sandbox; treat QuickJS as untrusted and isolate
  the process.
- `--stack-size` values above 4 MiB are clamped to 4 MiB; the engine's guard
  must stay below the real thread stack or runaway recursion would SIGSEGV
  instead of throwing `RangeError`.
- `--timeout` stops CPU-bound JS via an interrupt check and wakes a parked loop
  with a real deadline timer. A blocking `fs` read cannot be interrupted, but
  the process still exits 1 at the deadline.
- `setImmediate` is implemented as a 1 ms timer, so it runs after queued
  microtasks and alongside timers rather than in a separate check phase.
- `Buffer` covers `from`, `alloc`, `allocUnsafe`, `concat`, `isBuffer`,
  `byteLength`, `toString`, `write`, `slice`, `equals` and `compare`. The
  numeric helpers (`readUInt32LE`, `writeDoubleBE`, …) and `Buffer.poolSize`
  pooling are not provided. `Buffer.from(typedArray)` shares the underlying
  memory instead of copying (Node copies); `Buffer.from(ArrayBuffer)` also
  shares, as in Node.
- `path` is POSIX-only (`sep` is `/`); `path.win32` and `parse`/`format` are
  not provided.
- `os` provides `platform`, `arch`, `type`, `release`, `hostname`, `tmpdir`,
  `homedir`, `cpus` (model/speed placeholders), `totalmem`, `freemem`, `eol`,
  `devNull`, `endianness`. `loadavg`, `networkInterfaces`, `userInfo` and
  `availableParallelism` are not provided.
- `URL`, `TextEncoder`/`TextDecoder`, `fetch`, `http`, `net`, `dns` and
  `buffer` are provided; `crypto`, `zlib`, `tls` and TLS-backed
  `https` are not.

## Missing capabilities

Features that are absent altogether (rather than divergent) are inventoried in
[`docs/ROADMAP.md`](ROADMAP.md), with an explicit `v0.2` / `candidate` /
`not planned` intent for each. `COMPAT.md` only describes the observable
behaviour of what exists.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | success |
| script value | `process.exit(code)` |
| 1 | uncaught exception, unhandled rejection, timeout, OOM/limit failure |
| 70 | internal error (D `Error` at the boundary, loop could not close) |
