<p align="center">
  <img src="docs/logo.png" alt="djs" width="220">
</p>

# DJS

A small, embeddable JavaScript runtime written in **D**, embedding
[QuickJS-NG](https://github.com/quickjs-ng/quickjs) and [libuv](https://docs.libuv.org/).

DJS is deliberately *small*: one binary, ~45 ms cold start on this host against
Node 26's ~39 ms (measured, see `docs/BENCHMARKS.md`), no Node
dependency tree, a C ABI a small team can audit. It is Node-shaped where it
matters (`console`, timers, `fs`, `process`, ESM/CommonJS modules, packages from
`node_modules`, `http`/`https`/`http2`/`fetch`/`WebSocket`, `child_process`,
`worker_threads`, TLS, crypto, zlib) and explicit about what it is not (no
package manager, no N-API, no `Intl`/WASM/inspector).

## Status and scope

**This is a hobby project, not production software.** It exists to see how far a
small, auditable runtime can get on Node compatibility, and it is shared in case
that is useful or fun for someone else. There is no support contract, no security
response process, and no promise that a given Node package works. Do not run
untrusted code with it and do not put it in front of users who matter.

**Current state: v0.16.3.** The Node API level it emulates is **22.x**:
`process.versions.node` reports `22.11.0` (the level implemented) while
`process.version` reports DJS's own version, as Deno does. Breadth is tracked
per module in [`docs/COMPATIBILITY-SCORE.md`](docs/COMPATIBILITY-SCORE.md);
intentional divergences are in [`docs/COMPAT.md`](docs/COMPAT.md); measured
numbers are in [`docs/BENCHMARKS.md`](docs/BENCHMARKS.md).

**The priority is command-line tools.** The target is a CLI you would actually
install: argument parsing (`util.parseArgs`), terminal output (TTY detection,
colour, cursor control), file globbing, spawning child processes, reading config
files, and making HTTP requests. Day-to-day CLI workloads are the scenario that
gets tested first; server frameworks and build tooling are best-effort.

Known hard limits today: no native addons (N-API), no `Intl`, no WASM, no
inspector, no true async-context propagation across `await` (`async_hooks`/
`AsyncLocalStorage` are compatibility shims), and interactive raw-mode input
degrades to line buffering.

## Permissions

DJS denies filesystem, environment and host-information access by default. An
untrusted script can read only what it was granted:

```bash
djs app.js                                  # no fs/env/sys access
djs --allow-read=./data app.js              # read ./data only
djs --allow-read=./data --allow-write=./out app.js
djs --allow-env=HOME,API_* app.js           # exact names or * wildcards
djs --allow-sys=hostname,cpus app.js
djs -A app.js                               # legacy: allow everything
djs -P=ci app.js                            # set from ./djs.json
```

`--deny-*` always wins, including over `-A`. Sync calls throw a
`PermissionDenied` error (`code: "ERR_ACCESS_DENIED"`); async fs calls deliver
it to the callback. `process.permission.has(scope, resource)` and
`.drop(scope)` allow a script to query or voluntarily give up a capability.
`DJS_AUDIT_PERMISSIONS=audit.jsonl` records allow/deny decisions as JSONL.

The checks are enforced in native code, so `__djs.fs.*`/`__djs.os.*` cannot
bypass them. Module loading is exempt (a script can import its own graph); the
model is a seat belt, not a kernel sandbox — see
[`docs/PERMISSIONS.md`](docs/PERMISSIONS.md) and the Landlock plan in
[`docs/PLAN.md`](docs/PLAN.md).

## Quick start (Linux x86_64)

```bash
sudo apt install ldc dub libuv1-dev cmake ninja-build
./scripts/bootstrap.sh          # verify pins, build pinned QuickJS-NG, ABI probe
dub build --build=release
dub test
./scripts/integration.sh        # golden-output suite + CLI checks
./scripts/gate.sh               # every gate (logs in .dub/)
```

Pinned toolchain: LDC 1.36, DUB 1.36, libuv 1.48, Ninja 1.11.1,
QuickJS-NG v0.17.0 (`6d46d07d…`). `docs/PINS.md` is authoritative;
`DJS_ALLOW_VERSION_DRIFT=1` is the only escape hatch.

### macOS (Apple Silicon)

The binary builds natively on macOS arm64; the release workflow publishes
`djs-<version>-macos-arm64.tar.gz`.

```bash
brew install ldc dub libuv openssl@3 brotli ninja cmake pkg-config
DJS_ALLOW_VERSION_DRIFT=1 ./scripts/bootstrap.sh
dub build --build=release --compiler=ldc2 --config=macos
./djs --version
```

**Toolchain:** macOS needs LDC **1.43 or newer** (Homebrew's `ldc`); the
pinned 1.36 cannot run on current macOS releases, so
`DJS_ALLOW_VERSION_DRIFT=1` is required and the Linux pins in `docs/PINS.md`
do not apply. `--config=macos` links Homebrew's OpenSSL 3/Brotli/libuv. The
release tarball bundles those dylibs under `lib/` (install names rewritten to
`@executable_path`) plus a Mozilla CA bundle under `etc/`, so running it does
**not** require Homebrew; building from source still does.

**Support boundary:** macOS builds are arm64 (Apple Silicon) only. Intel Macs
are not supported. Release artifacts are ad-hoc signed, not notarized; a
browser-downloaded tarball may need `xattr -d com.apple.quarantine <file>`
before first run (or build from source). Notarization needs an Apple Developer
account and is a distribution decision.

Known differences on macOS: TLS uses the linked OpenSSL store or the bundled
Mozilla roots, not the macOS Keychain (Node uses its own bundled Mozilla roots
by default, also not the Keychain); use `NODE_EXTRA_CA_CERTS`, `SSL_CERT_FILE`
or `SSL_CERT_DIR` for private roots. An unreadable `NODE_EXTRA_CA_CERTS` emits
a warning and the default roots stay active, as in Node. `fs.watch` inherits FSEvents' coalescing and event-order
quirks, as Node does.

The suite runs natively as well: install `coreutils` for `timeout`, then
`./scripts/integration.sh`. `./scripts/gate.sh` runs every gate; AddressSanitizer
runs on both platforms, while LeakSanitizer is Linux-only (libuv's FSEvents
thread and OpenSSL keep process-lifetime allocations). CI runs the integration
suite, the permission/network gates, Express, and the Node differential on
macOS arm64; the release job builds, bundles, and smoke-tests the artifact.

## Usage

```bash
djs script.js            # run a script or module (classification below)
djs -e '1 + 1'           # evaluate a string
djs                      # minimal line-at-a-time REPL
djs --version
```

Options:

- `--timeout <ms>` — interrupt CPU-bound JS and stop the loop at the deadline.
- `--memory-limit <bytes>` — QuickJS heap limit (default 256 MiB).
- `--stack-size <bytes>` — JS stack limit (default 1 MiB).
- `-A`, `--allow-all` — disable permission checks (legacy behaviour).
- `--allow-read[=paths]`, `--allow-write[=paths]`, `--allow-env[=names]`,
  `--allow-sys[=names]`, `--allow-net[=host:port]`, `--allow-run[=cmds]`,
  `--allow-listen[=host:port]` — grant capabilities, scoped and
  comma-separated (`-R`/`-W`/`-E`/`-N`/`-S` are the short forms of
  read/write/env/net/sys).
- `--deny-<perm>[=values]` — deny wins over grants and `-A`.
- `-P[=set]`, `--permission-set[=set]` — load a named permission set from the
  config file; `--config <path>` selects that file (default `djs.json`).
- `--no-prompt` — never ask; denied access fails closed.
- `-v`/`--version`, `-h`/`--help`.

Exit codes: the script/`-e` status, `process.exit(code)`, `1` for an uncaught
exception, unhandled rejection or timeout, `70` for an internal error.

## API surface

The full inventory with per-module parity scores is in
[`docs/COMPATIBILITY-SCORE.md`](docs/COMPATIBILITY-SCORE.md). In short:

**Globals** — `console` (format specifiers and an `inspect` subset), timers
(`setTimeout`/`setInterval`/`setImmediate`/`queueMicrotask`, `Timeout` with
`ref`/`unref`/`hasRef`/`refresh`), `process`, `Buffer`, `URL`/`URLSearchParams`,
`TextEncoder`/`TextDecoder`, `fetch`/`Headers`/`Request`/`Response`/`FormData`/
`Blob`/`File`, `structuredClone`, `AbortController`, `atob`/`btoa`, `global`.

**Core modules** — `fs` (+`fs/promises`), `path` (POSIX and `path.win32`
formatting), `os`, `util`, `events`, `stream` (+`stream/promises`,
`stream/web`), `buffer`, `string_decoder`, `querystring`, `url`, `zlib`,
`crypto` (hashes, HMAC, ciphers, keys, `webcrypto.subtle` subset), `tls`,
`net`, `dns` (+`dns/promises`), `http`, `https`, `http2`, `dgram`,
`child_process` (sync and async, `--allow-run` enforced), `worker_threads`,
`cluster`, `readline` (+`readline/promises`), `tty`, `assert`, `module`,
`perf_hooks`, `diagnostics_channel`, `vm`, `v8` (heap statistics and a
serialization shim), `process`.

**Modules and packages** — one classifier decides script/ESM/CJS for the entry
point, `import` and `require`:

| Input | Classification |
|---|---|
| `.mjs` | ESM |
| `.cjs` | CommonJS module |
| `.js` + nearest `package.json` `"type": "module"` | ESM |
| `.js` otherwise | script entry (global `require`); CommonJS when required |
| `.json` | JSON module |

`import`/`require` resolve relative and absolute paths, extensions, directory
`package.json` `main`, `index.*`, and `node_modules` packages (bare, scoped and
subpath) including `exports`/`imports` maps with conditions and patterns.
`require` caches by canonical `realpath`, supports cycles, exposes
`require.main`/`require.cache`/`require.extensions`, and throws
`ERR_REQUIRE_ESM` for ES modules (Node 22's `require(esm)` is not implemented).

The module graph is confined to the directory of the nearest `package.json`
above the entry file. That is a deliberate permission boundary, and it means
hoisted monorepo layouts (`packages/app` importing a dependency installed at the
repo root), `npm link` and globally installed packages do not resolve.

## Architecture in one paragraph

One runtime thread owns one libuv loop and one QuickJS `JSRuntime`/`JSContext`.
Every JS-callable entry point is `nothrow @nogc` and wrapped in a
`catch (Throwable)` net that prints and exits 70, so no D exception crosses the
C boundary. Internal libuv callbacks are plain `nothrow @nogc` code that only
frees memory and enqueues work. Native code exposes mechanisms; `js/prelude/*.js` (`01-core.js` …
`08-v8.js`, concatenated into the binary) turns them into the Node-shaped
API. QuickJS's job queue is drained on
every loop turn, with a 10k-job fairness budget and `uv_prepare`/`uv_idle`
keep-alive. `process.exit` is a request: JS finishes the current turn, teardown
closes handles and runs non-blocking loop turns, and a blocked fs worker can
never prevent the exit code from being delivered. See
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full design, ADRs and
boundary rules.

## Testing and gates

```bash
dub test                 # D unittests (includes the zero-GC-allocation counter)
./scripts/integration.sh # golden stdout/stderr/exit-code suite + CLI checks
./scripts/gate.sh        # also Node differential, soak, and the ABI/no-phase gates
```

`gate.sh` keeps per-step logs under `.dub/`; CI job logs are the durable
record, and no generated evidence is committed. The sanitizer pass builds
`.dub/asan/djs-asan` with `-fsanitize=address` and fails on any
`AddressSanitizer`/`LeakSanitizer` report across the fixture set.
`integration.sh` also checks SIGPIPE, REPL async ordering, `process.exit` with a
blocked fs read, and that `dub test` does not replace the runtime binary.

## Development

See [`docs/DEVELOPING.md`](docs/DEVELOPING.md) for the layout, D style rules,
the gate/review workflow, and how to add an API or a test. Known gaps and
their intent are in [`docs/ROADMAP.md`](docs/ROADMAP.md); the permission model
is specified in [`docs/PERMISSIONS.md`](docs/PERMISSIONS.md). The short
version:
hot paths are `@nogc nothrow`, every `JSValue` has one owner, no phase/task
identifiers in code (`scripts/check-no-phase-refs.sh`), and every behaviour gets
a golden test.

## License

MIT. QuickJS-NG and libuv are MIT; see `THIRD_PARTY.md`.
