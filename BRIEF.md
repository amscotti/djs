# DJS — Project Brief (working name)

> **Historical.** The original project brief. Scope and API surface have
> moved on; see [`README.md`](README.md) and [`docs/ROADMAP.md`](docs/ROADMAP.md).

**One line:** A small, embeddable JavaScript runtime written in D, embedding QuickJS-NG and libuv.

> "DJS" is a placeholder codename. Renaming is a find-and-replace plus a binary rename; no architectural impact.

## Why this project

D has excellent C interop, fast native code, slices, compile-time evaluation, and an optional no-GC mode. QuickJS-NG is a small, MIT-licensed, ES2025 interpreter with a clean C API. libuv is the battle-tested cross-platform event loop Node itself uses. Together they make a runtime that is:

- small (single binary, no Node-sized dependency tree),
- fast to start (QuickJS runtime creation is sub-millisecond),
- easy to embed (C ABI host, no C++ shim),
- honest about scope (a useful runtime, not a Node clone).

## v0.1 scope (the build contract)

**In scope**

- `djs <file.js>` executes a JavaScript file; `djs -e "<code>"` evaluates a string; `djs` with no args starts a minimal REPL.
- Globals: `console` (`log`, `error`, `warn`), `setTimeout` / `setInterval` / `clearTimeout` / `clearInterval`, `queueMicrotask`.
- `process`: `argv`, `env`, `cwd()`, `exit(code)`, `platform`, `version`.
- `fs` (promise + callback + sync where practical): `readFile`, `writeFile`, `appendFile`, `stat`, `readdir`, `mkdir`, `unlink`.
- Module system: ESM `import`/`export` for `.mjs` and `.js` under a `"type":"module"` package; CommonJS `require` for `.cjs` and `.js` without that type; JSON imports. Classification follows the nearest `package.json` `"type"`; the entry file uses the same rule. No npm resolution in v0.1.
- Uncaught exceptions and rejected promises print a stack trace and set a non-zero exit code.
- A D test suite (`dub test`) and a JS integration suite with golden outputs.
- Reproducible build: pinned QuickJS-NG tag, vendored, built by `dub`/CMake on Linux x86_64.

**Out of scope for v0.1** (explicitly deferred)

- npm / node_modules resolution, package manager.
- Full Node API compatibility, N-API, native addons.
- `Intl` (QuickJS has no ECMA-402), WebAssembly, inspector/Chrome DevTools.
- `worker_threads` (QuickJS `os.Worker` may be exposed later behind a seam).
- HTTP server/client (phase 2), TLS (phase 3).
- Windows and macOS gates (keep the seams; Linux is the only gate initially).

## Non-negotiable engineering rules

1. **The C boundary is a contract.** No D exception, GC allocation, or delegate may cross into QuickJS/libuv callbacks. All callbacks are `extern(C)`, `nothrow`, `@nogc`, and convert failures to JS exceptions or return codes.
2. **Every `JSValue` has one owner.** Dup on store, free on release, no borrowed value held past a call. Document the rule at each binding.
3. **Hot paths are `@nogc`.** The event loop, bindings, and per-request paths must not allocate through the D GC. Use explicit allocators/arenas; tests assert allocation counts.
4. **No phase references in code.** Tests, comments, and identifiers never mention plan phases or task IDs; a CI grep enforces this.
5. **The reference is the oracle.** Where behavior overlaps Node, differential tests compare observable output against real Node.
6. **Pin everything.** Compiler version, QuickJS-NG tag/commit, libuv version, and build flags are recorded in one place and checked by a script.

## Layout

```
djs/
  docs/            architecture, D guide, plan, reviews, research
  src/djs/         D sources (runtime, loop, bindings, apis, modules)
  tests/           D unit tests + JS integration tests + golden files
  vendor/          pinned QuickJS-NG source (and future vendored C deps)
  scripts/         build/gate/verification scripts
  dub.json         build definition
```

## Definition of done for v0.1

A clean checkout on Linux x86_64, with the documented toolchain, runs:

```bash
./scripts/bootstrap.sh     # fetch/build pinned QuickJS-NG, verify toolchain
dub build --build=release
dub test
./scripts/integration.sh   # JS suite, golden outputs, exit-code checks
```

and every integration test passes with the expected output committed under `tests/golden/`.
