# Developing DJS

## Layout

```
src/djs/
  main.d              CLI, REPL, option parsing, entry dispatch
  runtime.d           lifecycle, globals, job drain, loop driver, teardown, limits
  registry.d          generation-checked callback slots (C memory, one JSValue each)
  bindings/quickjs.d  extern(C) declarations; the only place QuickJS types live
  bindings/value.d    conversions, throw/property helpers, ScopedValue
  loop/libuv.d        opaque libuv declarations via *_size/accessors
  apis/               console, timers, fs, bytes, os, process (native primitives)
  modules/            path helpers, classifier, JSON, exports maps, resolver, CommonJS, ESM loader
js/prelude/*.js       Node-shaped API built on __djs; concatenated at build time
tests/js/             integration cases (flat files or <name>/main.*)
tests/golden/         expected stdout, required stderr substrings, exit codes
scripts/              bootstrap, integration, gates, bench, fuzz, packaging
docs/                 architecture, plan, guide, reviews, compat, bench, roadmap, permissions
```

## Rules that are not negotiable

1. **Boundary shape.** Every JS-callable function is
   `extern(C) nothrow @nogc`, delegates to an `*Impl` body, and is wrapped with
   `guarded!impl` from `runtime.d` (JS-callable entries only; internal libuv
   callbacks stay plain `nothrow @nogc`). The guard prints `djs: internal
   error` and exits 70; a D exception must never unwind through QuickJS or
   libuv.
2. **One owner per `JSValue`.** Taking `JSValue` consumes it; `JSValueConst`
   is borrowed; returning `JSValue` transfers. Dup on store, free on release.
   `JS_SetPropertyStr`/`Uint32` consume on success *and* failure. Check `> 0`.
3. **No GC on hot paths.** The loop, bindings, per-request paths and the
   prelude wrappers' native side are `@nogc`. Use `malloc`/`free` and
   `uv_*_size`/`js_malloc` as appropriate; never cross allocators.
4. **No phase or task identifiers in code, tests or comments.** The plan is a
   planning artifact; `scripts/check-no-phase-refs.sh` enforces this.
5. **Every behaviour has a test.** Golden stdout is exact; stderr is a list of
   required substrings; exit status is its own file. Node-overlapping
   behaviour belongs in `docs/COMPAT.md` when it differs.

## D rules of thumb (see docs/D-GUIDE.md for the long version)

- `bool == 0` is a logic bug (`false == 0` is true). Compare booleans directly.
- `out`, `in`, `alias`, `module`, `body`, `scope`, `version`, `debug` are
  keywords; do not use them as identifiers.
- Null tests are `!is null`; `long long` is `long`; C-style arrays are
  `JSValue[5] args`.
- Opaque C types are used through pointers plus `uv_handle_size`/`uv_req_size`;
  never mirror them.
- `stat_t` exposes `st_mtime` (seconds) on this platform, not `st_mtim`.
- `dub test` builds a *separate* binary because the unittest configuration has
  its own `targetName`/`targetPath`. If you add a module with unittests, make
  sure it is linked into the test build.

## Adding an API

1. Put the mechanism in `src/djs/apis/<area>.d`: `extern(C) JSValue jsX(...)`
   that calls `guarded!jsXImpl`, validates arguments, and returns an owned
   value or `JS_EXCEPTION`.
2. Install it from `install<Area>` with `addNativeFunction`.
3. Add the Node-shaped wrapper to the matching `js/prelude/NN-*.js` file
   (promise/callback/encoding
   handling belongs here, not in C).
4. Add a `tests/js/<name>.js` case, a golden `tests/golden/<name>.txt`, and
   `.stderr.txt`/`.exit` if needed. Run `./scripts/integration.sh`.
5. If it touches the boundary, add it to `scripts/gate-sanitize.sh`'s case
   list and run `./scripts/gate.sh`.

## Gates and review

```bash
./scripts/bootstrap.sh        # pins, engine build, ABI probe, qjs smoke
dub test                      # D unittests + zero-GC allocation counter
./scripts/integration.sh      # golden suite + CLI checks
./scripts/gate.sh             # everything (per-step logs in .dub/)
```

Each review round has three independent reviewers (general, adversarial,
architecture/plan). Findings go to `docs/reviews/round-N-<role>.md`; every
finding gets a disposition in `docs/REVIEWS.md`; one fixer addresses accepted
findings and the gates are re-run. A critical finding that survives its round
stops the project.

## Debugging

- `DJS_DEBUG_TEARDOWN` is not used any more; teardown ordering is asserted by
  the sanitizer gate.
- For a crash: `dub build --config=sanitize --force` then run
  `.dub/asan/djs-asan <script>`. ASan aborts with a stack; do not "fix" it by
  reordering frees.
- For a leak: same build, `ASAN_OPTIONS=detect_leaks=1`.
- For loop behaviour: a test that prints ordering is better than a debugger;
  timers and microtasks are the only ordering primitives.
