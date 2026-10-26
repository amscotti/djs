# macOS parity — research (no code changed)

**Status:** implemented (T1–T4) on branch `macos-support`. The findings below
are the original research; §12 records what landed, the validation evidence,
and the remaining differences. All original experiments ran on throwaway
copies under `/tmp`.

**Environment:** macOS 26.6 (darwin25.6.0), Apple silicon (arm64).
Toolchains tried: LDC 1.36.0 (mise, the Linux pin) and LDC 1.43.0 (Homebrew,
DMD 2.113 frontend, LLVM 23). DUB 1.42 (Homebrew). libuv 1.53, OpenSSL 4,
Brotli 1.2.1 (Homebrew).

## 1. Verdict

- **The runtime works on macOS today.** With modern LDC and ~9 localized
  compatibility shims (throwaway probe, ~200 lines including mechanical
  casts), the whole codebase compiles, links, and runs: eval, sync and async
  fs, timers/microtasks, OpenSSL crypto, zlib/brotli, URL, `os` (darwin/
  arm64), hrtime, `execSync`/`spawnSync`, TCP, HTTP server and client, TLS
  (including correct self-signed rejection), `fetch`, dgram (after one fix),
  permissions (scoped reads + symlink-escape denial), the threadpool fs path
  through FIFOs, signals, vm, and UTF-8 buffers.
- **"Compiles" is a small, mechanical change.** Every blocker found is a
  localized binding gap or `version` split — no architectural work. The
  inventory is in §4.
- **"Feature parity" is one real feature (fs.watch) plus three small
  behavioral fixes and a test/CI program.** §5–§7.
- **The current macOS path is worse than "broken": it is untested and
  unreachable.** The pinned LDC 1.36 cannot even run hello-world on macOS 26
  (§3), the `release.yml` macOS job (which runs only on tag pushes) fails at
  compile before its three smoke commands ever execute, and no always-on CI
  job exercises macOS at all.

## 2. Method

1. Read the platform-sensitive surface (three research passes: native API
   inventory, fs.watch contract/libuv options, test-suite/gates portability;
   details merged below).
2. Built the **unmodified** source on this Mac with LDC 1.36 and 1.43 and
   recorded every compile/link error (`/tmp/djs-mac-probe*`).
3. Patched a **throwaway copy only** with the minimal shims, built, and ran a
   22-point runtime smoke battery plus targeted TLS/dgram/permissions/FIFO
   probes.
4. Verified constants against the real macOS SDK headers
   (`MacOSX.sdk/_time.h`, `unistd.h`, `sys/socket.h`) and the installed
   libuv header (`/opt/homebrew/include/uv.h`).

Reproduce: the probe scripts are `mac-probe*.sh` / `mac-smoke.sh` /
`mac-deep-smoke.sh` in the session scratch directory; they rsync to `/tmp`
and never touch the repository.

## 3. Toolchain findings (blocking, and easy to miss)

| Finding | Evidence |
|---|---|
| **LDC 1.36.0 cannot run any D program on macOS 26.** `writeln("hi")` segfaults in `pthread_getspecific` before `main`; its static druntime ships Mach-O objects with no platform load command (`ld: warning: no platform load command … assuming macOS`). | hello-world probe, both direct and via dub |
| **LDC 1.43.0 works** (same machine): hello-world, then the full runtime. | probe 3 |
| `version (Darwin)` is **not defined** by LDC 1.36; code must use `version (OSX)` (this silently skipped the clock shims until corrected). LDC 1.43 accepts both, but `OSX` is the portable spelling for the supported range. | probe iteration |
| The `release.yml` macOS job installs Homebrew `ldc` (currently 1.43) and sets `DJS_ALLOW_VERSION_DRIFT=1`, so CI already *would* use a modern compiler — but the job still fails because of §4. | `release.yml:66-80` |
| `dub test` (unittest config) links Linux sonames (`-l:libcrypto.so.3`, …); there is no macOS unittest configuration. | `dub.json:55-75` |

**Pin implication:** `docs/PINS.md` must state a macOS-only LDC floor (≥1.43
on macOS 26; the Linux pin can stay 1.36) or the README's macOS section
should not claim support. The ABI probe and bootstrap are otherwise fine.
The other pins are not actually pinned for macOS: Homebrew's libuv/OpenSSL/
Brotli float, and today the build silently links `openssl@4` (see §6.4).

## 4. Compile/link blocker inventory (empirical, exact)

All verified by compiler errors, then fixed in the throwaway probe.

| # | File:line | Problem | Fix shape |
|---|---|---|---|
| 1 | `fs.d:16` | Unguarded `core.sys.linux.sys.inotify` import (fs.watch, v0.12.3) | `version (linux)` around the import + the whole watch section; Darwin stub that throws `ERR_FEATURE_UNAVAILABLE_ON_PLATFORM` (or a real backend, §5) |
| 2 | `fs.d:8`, `permissions.d:557` | `O_CLOEXEC`, `O_NOFOLLOW` missing from druntime's Darwin `fcntl` (SDK has them: `0x1000000`, `0x100`) | local constants in a compat shim, imported where needed |
| 3 | `fs.d:14` | `fdatasync` missing from druntime's Darwin `unistd` (macOS has it) | `extern(C) int fdatasync(int) nothrow @nogc` shim |
| 4 | `child.d:19`, `os.d:7`, `process.d:8` | `clock_gettime`/`CLOCK_MONOTONIC` missing from druntime's Darwin `time` (**"No CLOCK_MONOTONIC defined"** — the module's own comment). SDK value is **`CLOCK_MONOTONIC = 6`** | extern declaration + `enum CLOCK_MONOTONIC = 6` for Darwin; `timespec` still comes from `core.sys.posix.time` |
| 5 | `os.d:213` | local `CLOCK_BOOTTIME = 7` (Linux constant) used for `os.uptime()` | Darwin path: `sysctl kern.boottime` or `clock_gettime(CLOCK_MONOTONIC)` seconds; currently returns 0 (probe) |
| 6 | `process.d:169` | `ru_maxrss` missing from druntime's Darwin `rusage` | local `rusage` layout or `mach_task_basic_info`; also decides peak-vs-current RSS (§6.2) |
| 7 | `fs.d:485/2195/2406`, `process.d:511/515` | Darwin druntime declares `mkdir/chmod/fchmod/umask` with `ushort` mode (not `uint`) → type errors | explicit casts (or a small `djs.platform` wrapper); 6 call sites |
| 8 | `child.d:16` (link) | **`execvpe` is glibc-only** — the only unresolved symbol at link time (`ld: symbol(s) not found`) | Darwin replacement: PATH search (split `PATH`, `access(X_OK)`, `execve`) or `posix_spawnp`; ~60–80 lines. A `execvp` shortcut compiles but **silently drops the child environment** (probe: `spawn(..., {env})` lost every variable) |
| 9 | `dgram.d:122` | `socket(AF_INET, SOCK_DGRAM \| SOCK_NONBLOCK \| SOCK_CLOEXEC)` with Linux numeric values; on Darwin the type field is bogus → `socket failed` (errno masked as EIO). Measured: `EPROTONOSUPPORT`. | reuse `net.d`'s `openSocket` pattern (`version (linux)` fast path, else `fcntl` F_SETFL/F_SETFD + `SO_NOSIGPIPE`); this is a **runtime bug**, not just compile |
| 10 | `dgram.d:27-30` | IP option constants are Linux numbers; on Darwin `IP_TTL=2` is **`IP_HDRINCL`**, and `IP_MULTICAST_TTL=33`, `IP_ADD/DROP_MEMBERSHIP=35/36` don't exist. Measured: `ENOPROTOOPT`. | `version (OSX)` values: `IP_TTL=4`, `IP_MULTICAST_TTL=10`, `IP_ADD_MEMBERSHIP=12`, `IP_DROP_MEMBERSHIP=13` |
| 11 | `os.d:13-16,35,68-69,92-93` | glibc `sysconf` numbers hardcoded: `SC_PAGESIZE=30`, `SC_PHYS_PAGES=85`, `SC_AVPHYS_PAGES=86`, `SC_NPROCESSORS_ONLN=84`. On Darwin these mean different things or `-1`: `os.cpus()` returns **1 CPU**, `totalmem()` and `freemem()` return **0**. | Darwin values: `_SC_PAGESIZE=29`, `_SC_NPROCESSORS_ONLN=58`, `_SC_PHYS_PAGES=200`; `_SC_AVPHYS_PAGES` does not exist → free memory via `mach_host_statistics64` or `sysctl vm.page_free_count`; total via `sysctl HW_MEMSIZE` |
| 12 | `child.d:769`, `process.d:77` | Darwin druntime exposes `environ` as a `@property` function returning `const(char**)`, not a global variable | call `environ()` explicitly (portable under both via a small shim) |

Already portable (verified, no action): `net.d`'s `SO_NOSIGPIPE` vs
`MSG_NOSIGNAL` split; `poll`/`getaddrinfo`/`recvmsg`; `uv_poll`,
`uv_queue_work`, `uv_getaddrinfo`; OpenSSL/Brotli/zlib calls; `realpath`
based permission matching (scoped read + symlink escape behaved identically
to Linux); FIFO async reads; signals; `vm`; HTTP/TLS stack.

## 5. fs.watch — the one real feature decision

**Current contract** (verified in source): `fs.watch(path, listener)` emits
`'change'` with `(eventType, filename)` where `eventType` is `"change"`
(modify/attrib) or `"rename"` (create/delete/move, self-delete/move). The
native table is `WatchSlot[32]` (`fs.d:2496`), each slot holding one inotify
fd + `uv_poll` handle; `filename` is the affected basename (null for
self-events). **Recursive support is prelude-only** (`02-fs.js:457-483`): it
walks directories with `readdirSync`/`statSync` and creates one native
watcher per directory, re-statting on rename to add new subdirectories. There
is no `fs.unwatch` (the similarly named `fs_unwatch.js` tests `watchFile`
polling). Tests are thin: `fs_watch.js` asserts a single create event,
`fs_cp_io.js` checks one recursive filename; nothing tests delete/rename of
watched entries, unwatch silence, multiple watchers, slot exhaustion, or
watching a single file.

**libuv evidence** (real libuv 1.53 on this Mac, probes run outside the
repo): `uv_fs_event_t` is an ordinary loop handle — `uv_handle_size(UV_FS_EVENT)`
= 304 bytes, no `uv_poll` or djs-managed fd required. On macOS libuv uses
**FSEvents for directories** (recursive supported via
`UV_FS_EVENT_RECURSIVE`, absolute filenames relative to the watched root) and
**kqueue for files** (no recursion). On Linux it uses a lazily-created shared
inotify fd. `uv_fs_event_cb` receives an ORed `UV_RENAME|UV_CHANGE` mask;
Node gives **rename priority** (`fs_event_wrap.cc`).

**FSEvents quirks that are inherent, not djs bugs** (verified with probes and
Node 26): writes frequently arrive as `UV_RENAME` (Created|Modified flags
coalesce); event types can flip from rename to change between runs; FSEvents
replays recent history, so watching a directory can deliver the directory's
own creation event first. Node exhibits the same behavior — a test that
unconditionally expects `"change"` for a write is flaky on macOS, and the
current `fs_watch.js` (closes on the first event) would close before the
tested file exists. This forces test rewrites, not just a backend swap.

Options:

| Option | What it means | Effort | Parity |
|---|---|---|---|
| **A. `uv_fs_event` for all platforms (recommended)** | Delete the inotify implementation (`fs.d:2482-2641`, ~160 lines); add ~90–120 lines in `fs.d` + ~10 in `libuv.d` (opaque `uv_fs_event_t`, cb alias, `UV_RENAME`/`UV_CHANGE`, `UV_FS_EVENT_RECURSIVE`, init/start/stop); map `(events & UV_RENAME) ? "rename" : "change"` with Node's rename priority; use `UV_FS_EVENT_RECURSIVE` on Darwin (one handle) while Linux keeps the prelude walk. Net **−30 to −55 lines**. | 1–2 days code; 3–5 with goldens/CI | Highest: one code path, native recursive watch on macOS, behavior Node users already know. Linux regression risk is small — libuv's inotify mapping is the same `IN_ATTRIB\|IN_MODIFY → UV_CHANGE`, other → `UV_RENAME` split. |
| **B. Keep inotify on Linux; add a Darwin `uv_fs_event` backend** | Two implementations behind `version` | 2–3 days code; 3–5 with tests | Same macOS result; Linux frozen byte-for-byte, but two lifecycles/mappings to maintain and duplicate teardown bugs |
| **C. Gate `fs.watch` to `ENOSYS`/feature-unavailable on macOS** | ~10–15 lines + test/docs skips | 0.5 day | None (documented gap). Legitimate **stopgap** while A lands — and the suggested staging |

Recommendation: **A** for parity; **C first** if macOS must compile and ship
before watch parity is funded. Either way `fs.d`'s other portability shims
(§4) must land simultaneously — gating watch alone is not a full macOS build.

Tests required for A/B: rewrite `fs_watch.js` (ignore the watched
directory's own event; waits above the 50 ms FSEvents latency); add a
per-platform golden mechanism (`tests/golden/<base>.<platform>.txt` fallback,
~5 lines in `integration.sh`); add delete/rename/file/watch-close/multiple-
watcher/slot-exhaustion/non-recursive/recursive-new-subdir coverage.

## 6. Behavioral gaps beyond watch (small, but user-visible)

1. **`child_process` environment on macOS** — `execvpe` replacement must
   preserve `envp` (`spawn(..., {env})`). `LD_*/DYLD_*` filtering (added in
   v0.16.4) must also apply on the Darwin path.
2. **`process.memoryUsage().rss`** — fixed in the follow-up by binding
   `uv_resident_set_memory`, the same call Node uses. It reports current RSS
   on both platforms; the earlier `getrusage` peak-RSS branch was removed.
3. **`os.uptime()`** — fixed using `CLOCK_MONOTONIC` on Darwin (the value
   matches Node exactly); `CLOCK_BOOTTIME` is Linux-only.
4. **dgram** — fix `openSocket` (§4 #9); after the fix the loopback
   send/receive smoke must pass.
5. **TLS trust store** — public HTTPS works: Homebrew's OpenSSL links
   `ssl/cert.pem` to `ca-certificates`, verified with `fetch("https://example.com")`.
   The follow-up added `NODE_EXTRA_CA_CERTS` (additive) and verified
   `SSL_CERT_FILE`; `SSL_CERT_DIR` is OpenSSL's default-path mechanism.
   Keychain integration was not pursued because Node does not use the
   Keychain by default either (it bundles Mozilla roots).
6. **`os.cpus()`/`totalmem()`/`freemem()`** — fixed with Darwin `sysconf`
   numbers plus `sysctl hw.memsize`/`vm.page_free_count`. `os.cpus()` now
   comes from `uv_cpu_info`, so model/speed/times match Node on both
   platforms (it previously had placeholder entries).
7. **`dgram` IP options** — Linux option numbers hit different Darwin
   options (`IP_TTL=2` is `IP_HDRINCL`); TTL/multicast/broadcast
   configuration fails with `ENOPROTOOPT` (§4 #10).
8. **DNS resolver and `/etc/hosts`** — this finding was incorrect for
   `dns.lookup`/`net.connect`: both use `uv_getaddrinfo`, which honors the
   host's resolver (including `/etc/hosts`). Verified with an actual hosts
   entry (`kubernetes.docker.internal` → `127.0.0.1`) on DJS and Node.
   `dns.resolve*` queries DNS directly and bypasses hosts, exactly as Node
   does. No code change was needed.
9. **`os.tmpdir()` returns `TMPDIR` verbatim** including a trailing slash.
   Fixed: trailing separators are stripped (except root), matching Node;
   covered by `tests/js/os_tmpdir.js`.

## 7. Test suite + gates portability

The integration suite and gates are Linux-only by design today, but an
empirical sample says the gap is smaller than the label suggests: **23 of 26
representative golden cases pass unmodified** on macOS with the probe binary
(hello, async/promises, buffers, streams, events, URL, timers, util, assert,
JSON/ESM/CJS imports, dynamic import, crypto (hash/sign), zlib,
string_decoder, querystring, path, http2, tls, vm, blob/formdata, and more).
The three failures separate cleanly:

| Sample failure | Cause | Verdict |
|---|---|---|
| `dgram` | the real `SOCK_NONBLOCK`/IP-constant bug (§4 #9/#10) | code fix |
| `os_module`, `process_info` | golden text contains the platform string (`linux`, `Darwin`/`darwin`, cpus count) | harness normalization (`__PLATFORM__` placeholder or platform-neutral assertions, as done for arch) |
| `fs_write`, `fs_meta` | need `tests/tmp` (the harness creates it; the sample did not) | not a macOS issue |

Static findings that remain:

- **Scripts — the real Linux-isms are few and precise:** `timeout` is the
  big one (`integration.sh:34,181,198`; `gate-sanitize.sh:46`;
  `gate-net.sh:23`; `gate-express.sh:12`; `fuzz.sh:17`), and two uses fail
  *silently* when it is absent: gate-sanitize greps only stderr for
  sanitizer text and fuzz treats rc 127 as success, so a missing `timeout`
  reads as a pass. Everything else is small: `bench.sh` uses
  `date +%s%N` and `/proc/cpuinfo`; `gate-examples.sh`/`gate-express.sh`/
  `gate-compat.sh` assume `npm ci` already ran (they fail on a clean
  checkout — Linux too, as observed in the container); `gate.sh` does not
  `mkdir -p .dub` before logging; `integration.sh`/`gate.sh` invoke
  `dub build`/`dub test` without selecting a platform config. **Not**
  present (contrary to a first-glance assumption): GNU `sed -i`,
  `stat -c`, `readlink -f`, `grep -P`; `head -c` works (BSD supports it);
  no `flock`/`xxd`/`base64 -w`. All 20 scripts are bash-3.2 compatible
  (`bash -n` clean; no associative arrays/mapfile/`&>>`). Cheap CI route:
  Homebrew `coreutils` gnubin on PATH plus explicit config selection.
- **Goldens — 7–8 of 150 need Darwin variants/normalization** of 147 suite
  cases: `process_info`, `builtin_import`, `builtin_new_modules`,
  `require_fs`, `os_module` (platform string, cpus/memory values),
  `child_process` (`/tmp` vs `/private/tmp`), `dns_resolve`,
  `fs_errors2` (`/dev/full` absent), `node_partials` (`lo` vs `lo0`,
  uptime, dgram). Also normalize `$TMPDIR`/`/private/var`→`/var` in
  `integration.sh:52` (today only `__ROOT__`) and set `umask 022` for the
  mode-printing tests. The remaining **128 of 147 cases (87%) pass
  unmodified** once the runtime ports land; 10 need only the runtime fixes
  (watch, dgram, execvpe env).
- **`dub.json`**: there is no `defaultConfiguration`, so plain `dub build`
  picks the Linux `application` config even on macOS, and `dub test` picks
  the Linux-soname `unittest` config. Add `unittest-macos` and
  `sanitize-macos` configurations (same targets as their Linux twins, with
  the macos lflags). The `macos` config's `-L/opt/homebrew/lib` precedes
  the openssl@3 path, so `-lcrypto` resolves through Homebrew's unversioned
  symlink — observed linking **openssl@4** on this machine; reorder or pin
  the versioned library names.
- **`dub test`** needs the macOS-unittest configuration (above).
- **gate.sh**: abi/build/version/unittest/integration/permissions/net/diff/
  soak are mechanically portable once scripts normalize; sanitize needs an
  LDC/Mach-O ASan check (LDC 1.43 supports `-fsanitize=address` on Darwin,
  but the current gate script's Linux link flags need a platform branch);
  express/examples/compat are npm-based and portable.
- **CI:** add an always-on macOS **compile + smoke** job (today macOS runs
  only on tag push). Full suite on macOS can start as a nightly/manual
  subset.

## 8. Distribution risk (independent of source parity)

The macOS build currently links **Homebrew dylibs by absolute path**
(`otool -L` on the probe: `/opt/homebrew/opt/openssl@4/lib/libcrypto.4.dylib`,
`libssl.4.dylib`, `brotli`, `libuv`). A user without the exact Homebrew kegs
cannot run the published binary — and `dub.json`'s `macos` config pins
`openssl@3` paths while the linker resolved `openssl@4` on this machine.
Options: static-link OpenSSL/Brotli/libuv (Homebrew ships `.a` for most),
bundle dylibs with `@loader_path` rpaths, or document Homebrew as a runtime
requirement. This is a packaging decision, not a code port.

## 9. Effort picture

| Tier | Scope | Estimate |
|---|---|---|
| **T1 — compiles + core runtime** | §4 items 1–9 (with watch = stub), LDC floor for macOS, `macos` unittest config, `otool`-clean linking decision deferred | 1 focused day; ~200–300 changed lines, all localized |
| **T2 — behavioral parity** | execvpe env (60–80), rss (30–60), uptime (20), dgram fix (20), TLS trust decision (document or 50–100), watch option C first (15) | 2–3 days; after T1 the probe already proved the rest works |
| **T3 — watch parity** | Option A (`uv_fs_event` everywhere) incl. golden review | 3–5 days, the only feature-sized item |
| **T4 — test/CI parity** | script portability (coreutils shim), golden placeholders, macOS-unittest config, CI jobs, docs/PINS updates | 2–4 days, mostly mechanical; full suite green on macOS is the real gate |

**Total to honest "macOS supported" (T1+T2+T4, watch stubbed): about one
week.** Adding watch parity (T3): one to two more.

## 10. Recommendations

1. **Do T1 + the CI compile guard first** — it converts "silently broken"
   into "compiles and core-tested", and every item is mechanical.
2. **Ship watch as an explicit, documented gap** (`ENOSYS` on macOS) until
   T3; do not couple "macOS support" to FSEvents.
3. **Decide the toolchain story**: macOS requires LDC ≥ 1.43 (pin/README),
   Linux stays on 1.36. `bootstrap.sh` already tolerates drift with a flag.
4. **Decide distribution**: bundle dylibs (recommended for a public
   tarball) or document Homebrew runtime deps; also stop linking `openssl@4`
   by accident.
5. **Add a `macOS` section to `docs/COMPAT.md`** listing the gaps above
   (watch, rss semantics, trust store) rather than implying full parity.

## 11. What was *not* verified

- No real integration-suite run on macOS yet (only isolated smoke probes) —
  T4 is where surprises would surface (timing-sensitive tests, TTY/readline,
  cluster/worker paths, soak).
- FSEvents semantics for `uv_fs_event` were not prototyped (contract analysis
  only; §5 recommendation follows libuv's documented behavior).
- No x86_64 macOS consideration (brew runner is arm64; Intel Macs would need
  their own job).

## 12. Implementation result (T1–T4)

Landed on `macos-support`:

- **T1 — compile.** `src/djs/platform.d` is the single compatibility layer:
  Darwin `O_CLOEXEC`/`O_NOFOLLOW`/`CLOCK_MONOTONIC`, `clock_gettime`,
  `fdatasync`, the `Mode` width alias (uint/ushort), `environPtr()`, and
  `peakRssBytes()` (`ru_maxrss` is `ru_opaque[0]` in Darwin druntime). No
  changes to the runtime architecture.
- **T2 — behaviour.** Portable `execvpe` (fixed-buffer PATH search running
  after `fork`, since glibc's is absent on Darwin); `os.cpus`/`totalmem`/
  `freemem`/`uptime` via the right `sysconf` numbers, `sysctl hw.memsize`,
  and `vm.page_free_count`; `process.rss`/umask/environ; dgram sockets via
  `fcntl` and Darwin's IP option numbers (`IP_TTL` is 4, not 2); permission
  audit flags; **`fs.constants` now reports the host's real `O_*` values**
  (the prelude had Linux values hardcoded; Darwin's differ, e.g. `O_CREAT`
  is 512).
- **T3 — `fs.watch`.** The inotify implementation is replaced by
  `uv_fs_event` (inotify on Linux; FSEvents for directories and kqueue for
  files on macOS). The JS contract is unchanged. Start failures translate the
  negative libuv code back to the host errno. New `fs_watch_events` coverage:
  create/write/rename/delete, single-file watch, missing-path `ENOENT`, and
  post-`close` silence; stable on both platforms.
- **T4 — tests, CI, packaging.** `scripts/lib-portable.sh` centralises the
  platform name, `dub` configs, `timeout`/`gtimeout`, and umask; the harness
  normalises `/private/{tmp,var}` and supports `*.darwin.txt` goldens;
  `dub.json` has `unittest-macos`/`sanitize-macos`; CI has a macOS arm64 job
  (integration, permissions, net, Express, Node differential); the release
  smoke test now passes `-A`; `package.sh` already selected `--config=macos`.

Validation evidence (both platforms, same commit):

- Linux: full `scripts/gate.sh` green — build, 10 unittest modules, 181
  integration cases, permission gate, net gate, Express, examples, compat,
  ASan/LSan, Node differential, soak.
- macOS 26 arm64 (LDC 1.43.0, Homebrew libuv/OpenSSL 3/Brotli): the same gates
  green except the ASan pass, which is skipped on Darwin. `otool -L` confirms
  `openssl@3`, not the unversioned `@4` symlink.
- Behaviour spot-checks against Node: `os.uptime()` identical;
  `os.freemem()` follows libuv's `free_count * pagesize`; `fdatasyncSync`
  works; `os.cpus()` reports all 10 cores.

Follow-up parity pass (post-T4) closed the remaining application-visible
items: `rss` is now current via `uv_resident_set_memory`; watcher slots are
dynamic and macOS uses native recursive FSEvents; `NODE_EXTRA_CA_CERTS`,
`SSL_CERT_FILE` and `SSL_CERT_DIR` are honored; `os.cpus()` carries
model/speed/times from `uv_cpu_info`; and the release artifact bundles the
Homebrew dylibs with `@executable_path` install names. The macOS ASan gate now
runs (AddressSanitizer; LSan leak detection stays Linux-only because libuv's
FSEvents thread and OpenSSL keep process-lifetime allocations).

Remaining differences: TLS uses OpenSSL's CA bundle rather than Node's bundled
Mozilla roots (not the Keychain in either case); FSEvents event coalescing and
ordering are OS-defined; macOS support is arm64-only. `os.tmpdir()` now strips
trailing separators like Node, and `/etc/hosts` was confirmed to work through
`uv_getaddrinfo`.


| Constant | Darwin value | Source |
|---|---|---|
| `CLOCK_MONOTONIC` | **6** | `MacOSX.sdk/usr/include/_time.h:159-160` |
| `clock_gettime` | `int clock_gettime(clockid_t, struct timespec*)` (macOS 10.12+) | `_time.h:181` |
| `O_CLOEXEC` | **0x01000000** | `sys/fcntl.h:153` |
| `O_NOFOLLOW` | **0x00000100** | `sys/fcntl.h:123` |
| `MSG_NOSIGNAL` | 0x80000 (SDK has it; druntime Darwin binding does not) | `sys/socket.h:594` |
| `SO_NOSIGPIPE` | **0x1022** | `sys/socket.h:169` |
| `_SC_PAGESIZE` | **29** | `unistd.h:255` |
| `_SC_NPROCESSORS_ONLN` | **58** | `unistd.h:283` |
| `_SC_PHYS_PAGES` | **200** | `unistd.h:379` |
| `_SC_AVPHYS_PAGES` | **does not exist** | — |
| `IP_TTL` / `IP_MULTICAST_TTL` / `IP_ADD_MEMBERSHIP` / `IP_DROP_MEMBERSHIP` | **4 / 10 / 12 / 13** | `netinet/in.h:408,414,416,417` |
| `IP_HDRINCL` | 2 (what Linux's `IP_TTL=2` hits on Darwin) | `netinet/in.h:406` |
| `SOCK_NONBLOCK` / `SOCK_CLOEXEC` | **not defined** (use `fcntl`) | `sys/socket.h:111-117` |
| `fdatasync` | symbol in libSystem, no SDK prototype | `dlsym` verified |
| `execvpe` | **absent** (no header, no symbol) | SDK + `dlsym` |
| `statvfs`/`fstatvfs` | present; druntime's struct matches Darwin | `sys/statvfs.h:60-62` |

druntime gaps confirmed on **both** LDC 1.36 and 1.43: `O_CLOEXEC`
(1.43 still lacks it; `O_NOFOLLOW` was added in newer druntime),
`fdatasync`, `CLOCK_MONOTONIC`/`clock_gettime`, `ru_maxrss`, and `environ`
(as a global — Darwin exposes `environ()` as a property function).
