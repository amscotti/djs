# Contributing to DJS

DJS is a hobby runtime; contributions are welcome, especially in the areas
the project cares about (CLI-shaped correctness, the permission model, and
small diffs with tests).

## Before you start

Read [`docs/DEVELOPING.md`](docs/DEVELOPING.md) first — it defines the
non-negotiable rules (the C boundary contract, JSValue ownership, no-GC hot
paths, no phase/task identifiers in code) and the layout. The short version:

- Every JS-callable native function is `extern(C) nothrow @nogc`, delegates
  to an `*Impl` body, and is wrapped with `guarded!impl`.
- Every `JSValue` has exactly one owner; `JS_SetPropertyStr` consumes on
  success and failure.
- Never pass a user-controlled string as a `JS_Throw*` format argument.
- Every behaviour change ships with a golden test.

## Building and testing

```bash
./scripts/bootstrap.sh   # pinned toolchain + QuickJS-NG build
dub build --build=release
dub test
./scripts/integration.sh # golden suite; add your case under tests/js/
./scripts/gate.sh        # everything, evidence in gates/
```

The pinned toolchain lives in [`docs/PINS.md`](docs/PINS.md);
`DJS_ALLOW_VERSION_DRIFT=1` is the escape hatch when your distribution's
packages differ. CI (`.github/workflows/ci.yml`) runs the full gate on
Ubuntu 24.04.

## Adding an API or a fix

1. Add the case under `tests/js/` and its golden under `tests/golden/`
   first; watch it fail.
2. Make the change (`src/djs/` for native, `js/prelude/` for the
   Node-shaped layer).
3. `dub test && ./scripts/integration.sh` locally; `./scripts/gate.sh`
   before opening the PR.
4. Behaviour that differs from Node belongs in
   [`docs/COMPAT.md`](docs/COMPAT.md), in the same PR.

## PR checklist

- [ ] Golden tests added or updated (and only for behaviour that actually
      changed).
- [ ] No D GC allocation on the changed hot path.
- [ ] Permission checks live in native code, not the prelude.
- [ ] `docs/COMPAT.md` updated for observable Node differences.
- [ ] Version left alone unless the maintainer asked for a release.
