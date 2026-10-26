# DJS permissions — design and implementation

**Status:** implemented in v0.4.0 and extended through v0.16.2. The normative
rules below describe shipped behaviour; `COMPAT.md` records the known gaps
(config `ignore`, module-graph exemption, no OS-level sandbox yet). Sections
that explain *why* the model was cheap to add keep their original v0.2 context
(the line numbers and module inventory are historical); the CLI surface and the
enforcement list are current.

## Recommendation

A Deno-style permission model is **feasible and a good fit for DJS**, because
DJS already funnels filesystem operations, environment access and OS
information through a small number of native entry points. It is not a large
architectural change; it is a gate at those choke points plus a flag/config
parser.

Adopt Deno's semantics (deny by default, scoped `--allow-*` / `--deny-*`,
permission sets in a config file, TTY prompts, audit log) but keep DJS's
Node-shaped API and error conventions.

**Implemented in v0.4.0; enforced by default.**
DJS has no active users, so there is no compatibility population to stage the
rollout for. The release includes the CLI, `djs.json` permission sets,
prompts, audit logging, `process.permission.*`, and the fs/env/os gates
together. `-A`/`--allow-all` is the explicit escape hatch for old behaviour;
the README, COMPAT and changelog call out the default change and the migration
path ("add `-A` to keep the old behaviour, then replace it with the narrowest
grants that work").

This mirrors Deno's model without copying its Rust architecture. The risk of a
one-release delivery is a larger review surface; it is mitigated by the matrix
and bypass tests in the test plan, a dedicated adversarial security review, and
`-A` keeping the old behaviour one flag away.

## How Deno does it

Deno is sandboxed by default: no filesystem, network, environment, subprocess or
FFI access without an explicit grant. The categories and flags are:

- `--allow-read` / `-R`, `--allow-write` / `-W` — paths (comma-separated,
  comma doubled to escape). A directory grant includes its subdirectories.
- `--allow-net` / `-N` — `host`, `host:port`, IP, IPv6; `*.example.com` allows
  subdomains but a bare hostname does not.
- `--allow-env` / `-E` — variable names; since Deno 2.1 suffix wildcards such
  as `AWS_*` are supported.
- `--allow-run` — executable names; spawning is not sandboxed, so this
  effectively disables the sandbox. `LD_*`/`DYLD_*` in a child environment
  requires an *unscoped* `--allow-run`.
- `--allow-sys` / `-S` — host-information interfaces: `hostname`, `osRelease`,
  `osUptime`, `loadavg`, `networkInterfaces`, `systemMemoryInfo`, `uid`, `gid`,
  `username`, `cpus`, `homedir`. The same flag gates the equivalent `node:os`
  functions (`os.cpus()` needs `--allow-sys=cpus`).
- `--allow-ffi` — shared libraries; like `run`, loading native code escapes the
  sandbox.
- `--allow-import` — hosts allowed as module sources; HTTPS only, with a small
  default allowlist of public registries.

`--deny-<category>` overrides `--allow-<category>`; deny-all also disables
prompts for that category. `-A`/`--allow-all` disables the sandbox entirely.
When a permission is missing and the process has a TTY, Deno prompts
interactively; prompts are suppressed when stdout/stderr is not a TTY or when
`--no-prompt` is passed, and the operation then fails.

Filesystem details worth copying:

- Symlinks are checked by the **symlink's location**, not the target, so a link
  inside an allowed directory is readable even if it points outside. Deno
  separately blocks privilege escalation through links that resolve to
  `/proc`, `/dev` or `/sys` (those need `--allow-all`; `/proc/*/environ` needs
  `--allow-env`), while `/dev/null`, `/dev/zero`, `/dev/random` and
  `/dev/urandom` are always allowed.
- Static imports reachable from the entrypoint are readable without
  `--allow-read`; imports that cannot be statically analysed, and workers
  loaded from local files, need read permission.
- Creating symlinks requires unscoped read **and** write, because a link can
  point anywhere.

Deno 2.5 added permission sets to `deno.json`/`deno.jsonc`:

```json
{
  "permissions": {
    "default": {
      "read": { "allow": ["./data"], "deny": ["./data/secrets"], "ignore": ["./data/cache"] },
      "write": ["./output"],
      "env": { "allow": true, "ignore": ["TEMP_*"] },
      "sys": ["cpus", "hostname"],
      "run": { "allow": true, "deny": ["rm", "sudo"] }
    },
    "ci": { "read": true }
  }
}
```

Each set is a map of permission name to `true`/`false`, an array of resources,
or an object with `allow`/`deny`/`ignore`. `read` and `env` support `ignore`;
the other categories do not. `-P` (or `--permission-set=NAME`) opts in; the
`default` set is used when `-P` has no argument. The opt-in is deliberate: a
script can edit `deno.json`, so auto-loading permissions from a file the code
can write would let it escalate itself. The same risk applies to `deno task`.

Deno also supports an audit log: `DENO_AUDIT_PERMISSIONS=<path>` writes JSONL
records `{v, datetime, permission, value}` for allowed *and* denied accesses;
`DENO_TRACE_PERMISSIONS=1` adds stack frames.

## How Node does it (for contrast)

Node's model is behind `--permission` and is explicitly a "seat belt", not a
sandbox against malicious code: Node trusts the code it is asked to run, and
the model mainly prevents trusted code from accidentally touching resources.
Scopes are `fs.read`, `fs.write`, `child`, `worker`, `net`, `addon`, `wasi`,
`ffi`, `inspector` and `openssl-store`; entrypoint files are readable by
default. `--permission-audit` reports violations without denying them, and
`process.permission.has(scope, reference)` / `.drop()` expose the model at
runtime. Node can read the same settings from a `--config-file` with a
`permission` object, which auto-enables enforcement.

Node documents the same caveats DJS must document: symlinks can escape the
allowed set; already-open file descriptors bypass checks; the inspector and
cross-process signalling are not fully covered.

## Why this is cheap in DJS

Current DJS (`v0.2.0`) has narrow, well-defined choke points:

- **Filesystem:** every operation goes through `getPath()` and
  `startFsWork()` in `src/djs/apis/fs.d` (`getPath` at ~line 674,
  `startFsWork` at ~line 1007), covering `readFile`, `writeFile`, `appendFile`,
  `stat`, `readdir`, `mkdir`, `unlink`, `rename`, `copyFile`, `rm`, `realpath`
  in sync, callback and promise forms. One check in `startFsWork` plus the
  synchronous entry points covers the whole surface.
- **Environment:** `process.env` is built once at startup in `processEnv()`
  (`src/djs/apis/process.d`, ~line 35) from `environ`. There is exactly one
  place to filter or wrap it.
- **OS information:** `src/djs/apis/os.d` installs every accessor in
  `installOs()` (~line 124); the syscall wrappers (`gethostname`, `sysconf`,
  `uname`) are local to that file.
- **Modules:** the loader is already confined to the package root by
  `projectRootFor()` (`src/djs/modules/path.d`), so the static import graph is
  both known and bounded.
- **CLI:** option parsing lives in one loop in `src/djs/main.d` (~lines
  114–146), and the runtime state is a single `Runtime` struct
  (`src/djs/runtime.d`, ~line 52).

Enforcement today, per category: `read` and `write` at the fs choke points,
`env` at `process.env` construction, `sys` at the os accessors (and
`process.kill`), `net` at connect/send/DNS, `run` at the spawn path, and
`listen` at the listener path. `ffi` and `import` are parsed, stored and
reported by `process.permission`, but no API consumes them yet: there is no FFI
surface and no remote module loader, so there is nothing to gate. When either
lands it must call the gate — the risk is a future API skipping it, not an
existing bypass. `scripts/check-permissions.sh` does not exist yet; a grep for
raw `uv_tcp_*`/`socket`/`fork`/`dlopen` use outside the permission module is
still a good idea.

## CLI surface

```sh
# Deny everything except what is listed .
djs --allow-read=./data,./config \
    --allow-write=./tmp \
    --allow-env=HOME,API_* \
    --allow-sys=cpus,hostname \
    app.js

# No flags at all means no read/write/env/sys access: enforcement is default.
djs app.js

# Deny wins over allow; deny-all also disables prompts for that category.
djs --allow-read --deny-read=./data/secrets app.js

# Sandbox off (same as today's behaviour).
djs -A app.js

# Permission set from djs.json.
djs -P=ci app.js
```

Flags: `-R/--allow-read`, `-W/--allow-write`, `-E/--allow-env`,
`-N/--allow-net`, `-S/--allow-sys`, `--allow-run`, `--allow-ffi`,
`--allow-import`, the matching `--deny-*`, `-A/--allow-all`, `--no-prompt`,
`--config <path>` and `-P[=set]`. Repeating a flag appends to its list. Relative paths are resolved against the current working
directory for CLI flags and against the config file's directory for config
rules.

Semantics (chosen to match Deno where it matters):

- Unscoped flag = allow everything in that category. Scoped flag = allow only
  the listed resources.
- `--deny-*` always wins, regardless of order or origin (CLI or config).
- Absent category = deny (when enforcement is on).
- `-A`/`--allow-all` is the explicit "no sandbox" switch — it disables
  category checks and prompts, but explicit `--deny-*` rules still win
  over it.
- `--no-prompt` plus a TTY fails closed; a non-TTY always fails closed.
- Invalid values (unknown permission name, malformed config) are startup
  errors, never silently widened.

## Proposed config file

`djs.json` / `djs.jsonc`, discovered from the entry file's package root (the
same root the module loader uses), or passed explicitly with
`--config <path>`. Only the `permissions` key is read at first; other keys can
come later (`tasks`, `imports`).

```json
{
  "permissions": {
    "default": {
      "read": { "allow": ["./src", "./data"], "deny": ["./data/secrets"] },
      "write": ["./tmp", "./dist"],
      "env": { "allow": true, "ignore": ["AWS_*", "*_TOKEN"] },
      "sys": ["cpus", "hostname"],
      "net": ["api.example.com:443", "*.internal.example.com"]
    },
    "ci": { "read": true, "env": ["CI", "HOME"] }
  }
}
```

Rules:

- Permissions are **never** loaded implicitly. `-P` (with an optional set name)
  is required, because the running script can edit its own config — the same
  threat model Deno documents. Without `-P`, `djs.json` is ignored and the
  sandbox state comes only from CLI flags.
- A CLI flag for a category **replaces** that category from the selected set;
  categories not mentioned on the CLI inherit from the set. Denies are merged,
  never replaced, so a config deny cannot be undone by a CLI allow.
- `ignore` is accepted only for `read` and `env`. Ignored reads behave as
  `ENOENT`; ignored env reads return `undefined`.
- Relative paths resolve against the config file's directory; `~` is not
  expanded (documented).
- A missing `default` set with bare `-P` is an error. A named `-P=foo` that
  does not exist lists the available sets.

## Enforcement architecture

New module `src/djs/permissions.d`:

```d
enum Perm : ubyte { read, write, net, env, run, sys, ffi, importKind }

struct Rule
{
    Perm kind;
    bool deny;
    bool all;          // unscoped grant/deny
    string[] values;   // paths, hosts, names, programs
}

struct PermissionSet
{
    Rule[] rules;
    bool enforce;
    bool noPrompt;
    // audit sink, decision cache, etc.
}

// Returns true when allowed. On denial, `jsPermissionError` throws a
// PermissionDenied error carrying permission/resource/code.
bool permits(JSContext* ctx, Runtime* self, Perm kind, const(char)* resource);
```

Wiring (revised after the security and implementation reviews):

1. **Native enforcement, not prelude policy.** `__djs` stays reachable from
   user code (generated module wrappers call `__djs.requireFrom`), so every
   check must live in the D primitive itself: sync `js*SyncImpl`, async
   `js*StartImpl`, `startFsWork`, env construction, every `os` accessor, and the
   loader. The prelude only shapes errors and implements `ignore`/`undefined`
   semantics. A test must assert that calling `__djs.fs.readFileSync`,
   `__djs.process.env()` and `__djs.os.hostname()` directly is denied too.
2. **Every fs entry point is gated.** All sync natives call the helper directly;
   `startFsWork` gates path-based async ops after `getPath`, and `fs.open`
   classifies access plus `O_CREAT`/`O_TRUNC`/`O_APPEND`. v0.6 fd operations
   (`read`/`write`/`fstat`/`fsync`/`close`) are authorized by the tracked fd
   table at open time. Denial must free `path`, `path2`
   and `data` exactly like the existing error paths or ASan/LSan fails.
   Classify: read/stat/readdir/realpath = read; write/append/unlink/mkdir/
   rename/copy/rm = write; `rename`/`copyFile` check both sides; recursive
   `mkdir` checks every prefix it creates (or documents the over-grant); `rm`
   checks the root and never follows symlinks.
3. **Path policy.** Canonicalise **rules and requests** with the same algorithm
   (realpath of the deepest existing ancestor + normalised tail) and compare
   resolved-to-resolved with component boundaries (`/data` must not match
   `/data2`). Do not cache resolutions across operations; if a cache is used,
   revalidate by `st_dev`/`st_ino`. After resolution, `lstat` the leaf: a
   dangling symlink that points outside must be refused, not accepted because
   its parent is allowed. Write with `O_NOFOLLOW|O_CLOEXEC`; prefer
   `openat2(RESOLVE_BENEATH|RESOLVE_NO_SYMLINKS)` on Linux, with
   `O_NOFOLLOW`+`fstat` as the fallback. Define a rule as a subtree only when
   it exists and is a directory; otherwise it is an exact path.
4. **Precedence.** `deny > ignore > allow`. An ignored read behaves as
   `ENOENT` even when an allow also matches; an ignored env read returns
   `undefined`; ignore never overrides deny. A rule path that cannot be
   canonicalised at startup is a startup error, not a silent lexical match.
5. **env.** Enforce inside `processEnv()`, the single native constructor, not in
   a prelude Proxy. `os.homedir()`/`os.tmpdir()` read `HOME`/`TMPDIR` through
   the same gate (tmpdir falls back to `/tmp` when denied); `DJS_MAX_FILE_SIZE`
   is trusted startup configuration, read once. DJS has no `setenv`, so
   `process.env.X = y` only mutates the JS copy: document that `process.env` is
   a read-only startup snapshot, and do not claim to gate writes until a native
   setter exists.
6. **os.** Convert `hostname`, `release`, `homedir` and `tmpdir` from eager
   strings into native functions that call `permits(sys, name)` on every
   access; otherwise `drop('sys')` cannot revoke them and `__djs.os.hostname`
   leaks the value. Map `release` → `osRelease`, `totalmem`/`freemem` →
   `systemMemoryInfo`, `cpus` → `cpus`, `homedir` → `homedir`. Leave
   `platform`, `arch`, `type`, `eol`, `devNull`, `endianness` ungated.
7. **Modules.** Record the statically linked graph; the entry and its static
   imports are readable without `--allow-read` and remain root-confined. Gate
   computed/dynamic specifiers, absolute specifiers not in the graph, and
   `__djs.requireFrom` on read. Stop `projectRootFor` at the package that owns
   the entry, not the filesystem root. `djs.json` is read before enforcement.
8. **Async denial contract.** Sync APIs throw `PermissionDenied`; callback APIs
   deliver it as `cb(err)` through the existing error path (no request is
   queued); `fs.promises` rejects. Pin all three with goldens.
9. **net/run/ffi/import.** Parse and store rules now. `--allow-net` matches
   host[:port] with `*.` subdomains and is checked before DNS resolution when a
   networking API exists. `--allow-run`/`--allow-ffi` are documented as
   sandbox-escaping. Until those APIs exist the flags are accepted but inert.
10. **Audit.** `DJS_AUDIT_PERMISSIONS=<path>` opens
    `O_WRONLY|O_APPEND|O_CREAT|O_CLOEXEC|O_NOFOLLOW` with mode 0600 and aborts
    startup if it cannot. JSON-escape every field; `value` is the resource name
    (path, env name, host) and never an env value or file contents. Emit the
    record **before** the `-A`/unscoped fast path so audits are complete.
    `DJS_TRACE_PERMISSIONS=1` adds a stack array (this path may allocate; the
    rest stays `@nogc`).

### Errors and prompts

Throw a normal JS `Error` with:

```text
PermissionDenied: Requires read access to "/etc/passwd", run again with the --allow-read flag
    at ...
  name: 'PermissionDenied'
  code: 'ERR_ACCESS_DENIED'
  permission: 'fs.read'
  resource: '/etc/passwd'
```

This blends Deno's name/message shape with Node's `code`/fields so existing
Node error handling (`err.code === 'ERR_ACCESS_DENIED'`) works.

Prompting: only when **both** stdin and stderr are TTYs and `--no-prompt` is
not set. Write the question to stderr, read the answer from `/dev/tty`, offer
`[y]es once / [n]o / [a]lways for this session`, default to deny on EOF. Cache
"always" decisions for the session. Non-TTY never prompts.

### Runtime API

Add `process.permission.has(scope, reference)` and
`process.permission.drop(scope, reference)` (Node-shaped), where scopes are
`fs.read`, `fs.write`, `env`, `net`, `sys`. `has` is cheap and useful for
feature detection; `drop` is irreversible and only affects future checks.
Deno's `Deno.permissions.query/request/revoke` promise API is not needed for a
first version.

## Release plan

| Release | Scope | Compatibility |
| --- | --- | --- |
| v0.4.0 | CLI flags, fs/env/os gates, `djs.json` sets, `-P`, prompts, audit, `process.permission.*`, tests, docs | **Default deny**; `-A` restores old behaviour |
| later | `net`/`run`/`ffi` enforcement when those APIs exist (rules already parse) | Unchanged |
| candidate | OS-level sandbox (`--sandbox=...`) as defense in depth | Opt-in |

A single release is the right call only because there are no existing users.
Once v0.4.0 ships, any future change to permission semantics must follow normal
deprecation rules: a flag or config change that widens or narrows access is a
breaking change and needs a major version.

## Test plan

Golden and unit coverage, in the existing style:

- **Matcher:** allow-all, scoped allow, deny-wins, deny-ignore-allow precedence, deny-all, `ignore`, repeated flags, comma escaping, empty list, unknown category.
- **Native bypass:** direct `__djs.fs.readFileSync`, `__djs.process.env()`, `__djs.os.hostname` and `__djs.requireFrom` calls are denied; a grep gate fails if the prelude regains enforcement logic.
- **Paths:** inside/outside cwd, `..` traversal, prefix collision
  (`/data` vs `/data2`), symlink pointing outside (deny), inside (allow) and a
  dangling symlink write (deny),
  non-existent target under an allowed parent, write to a file vs directory,
  `rename`/`copyFile` both sides, recursive `rm` inside/outside, `realpath`.
- **env:** allowed read, denied read throws, ignored read is `undefined`,
  `Object.keys` hides denied names, denied write throws.
- **os:** each gated function with and without `--allow-sys`, plus ungated
  functions remaining available.
- **Config:** `-P` without config is an error; named set; default set; CLI
  override; deny merge; relative paths against config dir; malformed JSON;
  missing set.
- **UX:** non-TTY denial, `--no-prompt`, `-A`, audit JSONL shape and no secret
  values.
- **Regression:** the existing 67 integration cases run with `-A` and produce
  identical output; a second run with no grants fails exactly the cases that
  touch denied resources.
- **Sanitizers:** permission paths under ASan/LSan; no allocations on the
  hot path after startup.

## OS-level sandbox (researched, future)

In-process checks are a seat belt, not a sandbox: a memory-safety bug in
QuickJS, libuv or D defeats them. A kernel backstop is worth adding.

**Landlock is the right first mechanism.** It is unprivileged, needs no
dependency, keeps the single-binary property, and maps almost one-to-one onto
the fs read/write grants. Applied in-process before user code, it enforces
read/write/execute/truncate/remove/make/refer on path hierarchies at `open()`,
which also closes the check-to-open TOCTOU window. A prototype on this host
(kernel 6.8, Landlock ABI 4) applied a ruleset with three raw syscalls and ran
DJS unchanged with reads/writes outside the granted roots returning `EACCES`,
including libuv threadpool operations.

Proposed shape: `--sandbox=landlock` (opt-in, independent of `--permissions`),
`--sandbox=landlock,warn` for best-effort, `off` by default. Derive rules from
the same `PermissionSet` (read grants, write grants, package root), mask rights
to the running ABI, set `PR_SET_NO_NEW_PRIVS`, and apply in `main.d` after the
entry is resolved but **before** user code, while the process is still
single-threaded (Landlock is per-thread before ABI 8). Fail closed with exit 2
and a clear diagnostic when the kernel lacks Landlock; never silently degrade.
Because rules are irreversible, kernel sandboxing and TTY prompts are mutually
exclusive; `process.permission.drop()` only narrows the in-process policy.
Known gaps to document: no `stat`/`access` filtering, no env, no
`uname`/affinity control, pre-opened fds exempt. `process.chdir` is allowed
(Node parity) but anchors relative read/write rules to their original
directory before changing cwd, so a scoped grant cannot move with the process.
`memoryUsage()` uses libuv's platform RSS call rather than reading
`/proc/self/statm`, so the sandbox does not need to re-expose `/proc/self`.

Effort: ~350–500 lines of D in a new `src/djs/sandbox.d` plus ~40 lines of CLI
parsing and ~200–300 lines of tests, roughly one week; no new dependency, no
measurable startup cost.

**Later:** `--sandbox=seccomp` as a deny-list (mount/ptrace/bpf/io_uring/...)
with `PR_SET_NO_NEW_PRIVS` and TSYNC; force io_uring to `ENOSYS` because libuv
1.48 opens it at startup and it bypasses seccomp. Allowlist seccomp is a
maintenance tax and is not recommended. Namespaces/bubblewrap/nsjail give a
stronger filesystem view but need unprivileged user namespaces, which Ubuntu
24.04 blocks by default (`kernel.apparmor_restrict_unprivileged_userns=1`), so
ship reviewed `bwrap`/`nsjail` recipes in the docs instead of building them in.
Defer macOS Seatbelt until macOS is a target; Capsicum is out of scope.

## Risks and limitations (must be documented)

- **Not a sandbox against malicious code.** DJS is a native interpreter; an
  engine or syscall bug can bypass an in-process check. Node says the same
  thing about `--permission`; Deno's Rust/V8 isolation is stronger. For truly
  untrusted code, use OS isolation (separate user, `bubblewrap`/`nsjail`,
  seccomp) in addition to flags.
- **TOCTOU.** Permission checks and the subsequent `open()` are separate
  syscalls; a concurrent filesystem change can swap a symlink between them.
  V1 accepts this and documents it; later versions can open relative to a
  verified directory fd (`openat`) or use `O_NOFOLLOW` for writes.
- **Symlink policy.** Resolving `realpath` and checking the target is stricter
  than Deno's "check the link location" rule and may break setups where a
  symlinked data directory points into an allowed tree. Choose one policy and
  test it; the proposal above prefers the stricter target check.
- **Config is code-adjacent.** A script that can write `djs.json` can grant
  itself permissions; `-P` opt-in is the mitigation, exactly as in Deno.
- **Prompt fatigue / social engineering.** Interactive grants are a
  convenience, not a security boundary; CI must use `--no-prompt`.
- **Future APIs.** Networking, subprocesses and FFI must call the gate from
  day one; add a checklist item and a grep-based gate when they land.
- **No workers yet.** Permission inheritance for workers/child processes is
  undefined until those features exist; Deno propagates to workers, Node has
  subtle `execArgv` rules. Decide when the feature lands.

## Open questions

1. Config file name and discovery: `djs.json` at the package root, or a `djs`
   key inside `package.json` (fewer files, but mixes concerns)?
2. Should the static module graph be implicitly readable (Deno/Node) or should
   imports obey `--allow-read` too (simpler to reason about, more friction)?
3. Prompt "always" scope: this resource, this category, or the whole session?
4. Audit-only mode (`--permission-audit`) for validating a config before
   enforcing, as Node offers — worth adding to v0.4.0 if it does not delay it.

## References

- Deno permissions reference: https://docs.deno.com/runtime/reference/permissions
- Deno configuration file, permissions: https://docs.deno.com/runtime/reference/deno_json#permissions
- Deno 2.5 release notes (permission sets, audit log): https://deno.com/blog/v2.5
- Deno security fundamentals: https://docs.deno.com/runtime/fundamentals/security
- Node.js permission model: https://nodejs.org/api/permissions.html
