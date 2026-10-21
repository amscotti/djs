# D performance and readability: what idiomatic D costs, and what DJS pays

Companion to [`d-idioms.md`](d-idioms.md), which covers the language mechanics (attributes, C
interop, GC policy). This note is about **cost and structure**: which idioms are fast, which are
merely familiar, and what the DJS tree actually does. It exists to feed the project review, so every
claim is either measured here (`[V]`) or attributed.

Repeat runs of the microbenchmarks vary by roughly 10% on this host; the tables quote one
representative run and the ratios are what matter.

Environment: **LDC 1.36.0** (LLVM 17.0.6, DMD frontend 2.106.1), Ubuntu 24.04 x86_64, libuv 1.48,
QuickJS-NG pinned in `vendor/`. Microbenchmarks: `-O3 -release`, best of five runs. Numbers are
single-host and should be read as ratios, not absolutes.

---

## 1. How this was measured

Three instruments, in increasing order of relevance:

1. **Idiom microbenchmarks** (`/tmp/dbench.d`, reproduced in §7) — 50M-access loops, 2M-call loops,
   string building, dispatch. These isolate a single language decision.
2. **The scanner probe** (`/tmp/scanprobe.d`) — links `djs.modules.cjsnames` directly and times
   `collectCjsExportNames` on generated modules of 25k–200k exports.
3. **The real binary** — `djs` built five ways (`base`, `-flto`, `-mcpu=native`, `-boundscheck=off`,
   combined) and run under `hyperfine` on three workloads plus startup.

The third matters most: it tells you whether a language-level win survives contact with a program
whose time is mostly QuickJS and I/O.

---

## 2. The cost model, measured

### 2.1 Bounds checks: `-release` does the opposite of what people assume

LDC's `--release` help says "disabled asserts/contracts/invariants, and bounds checks in `@safe`
functions only". Read literally that means checks are *kept* in `@safe` code and *dropped*
everywhere else. Measured, on a loop indexing a runtime-bounded array (`gArr[(i + 7) & mask]`, mask
loaded at runtime so LLVM cannot prove the range):

| Build | `@system` loop | `@safe` loop |
|---|---|---|
| `-boundscheck=on` | 25.9 ms | 25.9 ms |
| `-boundscheck=off` | 18.7 ms | 18.8 ms |
| `-O3 -release` (default) | **18.9 ms** | **26.0 ms** |

So: checks cost ~38% in this loop (18.7 → 25.9 ms), and **`@safe` is the only thing that keeps them in a release
build**. The D spec says the same thing directly: "Array bounds checks are necessary to enforce
memory safety, so these are enabled (by default) for `@safe` code even in `-release` mode."

This has a consequence for DJS that is worth stating plainly:

- `src/` contains **0** `@safe` and **0** `@trusted` annotations across 30 modules and 16.8k lines.
- Therefore every release build of DJS currently runs with **no bounds checks at all**.
- `docs/D-GUIDE.md` §1 says "DJS does not ship with `--boundscheck=off`; a safety check is cheaper
  than a memory bug." The build fulfils the letter (no flag) and defeats the intent (no `@safe`
  code to check). This is the single biggest guide-vs-code contradiction found in this pass.

It is not automatically a bug: the code is pointer-heavy FFI, where `@safe` cannot live. But the
project is currently telling itself it has a safety net it does not have.

### 2.2 Exceptions vs status codes

2M calls that fail 1 time in 1024:

| Style | Time |
|---|---|
| `bool`/status return | 0.58 ms |
| `throw` + `catch` | 12.8 ms |

~22×, and the throwing version allocates. DJS already uses status returns at the boundary
(`nothrow @nogc` + `throwError`), so this is confirmation rather than a finding. It does explain why
`nothrow` is worth keeping transitive: one `Exception` in a callback path is a per-event cost.

### 2.3 String building

200k appends of 8 bytes:

| Method | Time | Note |
|---|---|---|
| `s ~= "abcdefgh"` | 5.15 ms | amortised, allocates, GC |
| `appender!string` | 4.27 ms | idiomatic non-`@nogc` choice |
| `malloc` + `memcpy` + growth | **0.07 ms** | 73× faster, no GC |

The gap is mostly GC bookkeeping and the copy-on-append path. In `@nogc` code there is no choice —
DJS uses the manual buffer (`Buf` in `esm.d`, `cjsnames.d`) and that is correct. The finding is the
inverse: do **not** introduce `~=` or `format` into the module loader "for readability"; both are
on the forbidden list in the house memo, and this is why.

### 2.4 Dispatch: `strcmp` chains vs `switch`

2M lookups over a 40-entry table of short strings:

| Method | Time |
|---|---|
| chain of `if (!strcmp(...))` | 188.7 ms |
| `switch` on `string` | 35.7 ms |

5.3×, and the `switch` is shorter to read and impossible to half-update (the compiler rejects a
missing `break` differently, and a case list is a single list). `switch` on strings is a normal D
feature; it compiles to length-then-content comparison, not a linear walk.

Where DJS does this: `src/djs/modules/esm.d` has 41 distinct `"djs:…"` specifiers appearing in
**two** parallel chains (`builtinExportNames`, `defaultBindingFor`), plus 43 export arrays. Adding a
builtin means editing three places. At the binary level this costs nothing measurable (§2.6), so the
case for changing it is readability and correctness, not speed.

### 2.5 Structs vs classes, and AA vs `switch`

| Idiom | 2M operations |
|---|---|
| `new Small(i)` | 3.7 ms (+GC pressure) |
| struct value | ~0 ms (elided) |
| `int[string]` lookup | 74.1 ms |
| `switch` lookup | 35.7 ms |

DJS uses **0 classes and 0 associative arrays**; 73 structs. That matches the systems-D advice and
is worth preserving as a rule, not an accident.

### 2.6 Compiler flags on the real binary

Five builds, three workloads (`hyperfine`, warmup 3, 15 runs, mean):

| Workload | base (`-O3 -release`) | `-mcpu=native` | `--boundscheck=off` |
|---|---|---|---|
| `--version` | 8.3 ms | 7.7 ms | 8.7 ms |
| import 15 builtins | 48.8 ms | 53.0 ms | 44.1 ms |
| require 100k-export CJS | 218.1 ms | 223.1 ms | 213.4 ms |
| read 20 MB file | 83.6 ms | 84.3 ms | 81.9 ms |

All differences are inside run-to-run noise (σ on startup alone is ~3 ms; minima are 35.6/34.2/34.9
on the import workload). `-flto=full` could not be tested: this host has no `LLVMgold.so`, so LTO is
unavailable here.

**Conclusion:** DJS's time is dominated by QuickJS parsing/execution and syscalls, not by D codegen.
Flag tuning is not a lever until the JS side is; algorithmic work in loader/scanner code is.

---

## 3. Readability idioms that matter in a runtime

These are the structural patterns that separate "D written like C" from "D written like D":

1. **Table over chain.** A list of (name → data) belongs in one `static immutable` array of structs,
   iterated once, not in two parallel `if` chains that must be kept in sync.
2. **`scope(exit)` over branch cleanup.** One allocation freed on nine paths is nine chances to
   miss one; `scope(exit) free(p);` is `@nogc`, deterministic, and shorter.
3. **Functions that fit on a screen.** D has cheap abstraction (`static if`, templates, nested
   functions); a 283-line function usually has three functions inside it.
4. **`auto` for noise, explicit types for contracts.** `auto n = strlen(p);` is clearer than
   `size_t n = ...`; `JSValue` in a signature is documentation. DJS is at the explicit extreme
   (8 `auto` in 16.8k lines), which is defensible for a runtime but makes helpers noisier than D
   needs.
5. **`pure` as a cheap proof.** A `pure @nogc nothrow` leaf helper is compiler-checked against
   hidden global state; it costs nothing at runtime. DJS has 0.
6. **String switches and `final switch`.** `switch (s)` over string literals, `final switch` over an
   exhaustive enum; both turn "did we cover every case?" into a compile error.
7. **Comments state the invariant, not the step.** The good comments in this tree do this
   ("A signal listener observes the process, it does not keep it alive"); the review should protect
   that habit.

---

## 4. The DJS audit

Counts from `src/**/*.d` (30 files, 16,839 lines, excluding `vendor/`):

| Metric | Count |
|---|---|
| `@nogc` annotations | 967 |
| `nothrow` annotations | 965 |
| `@safe` / `@trusted` / `pure` | **0 / 0 / 0** |
| `scope(exit)` | 54 |
| `new` expressions | 0 (6 matches were prose) |
| classes / associative arrays | 0 / 0 |
| structs | 73 |
| `malloc`/`calloc`/`realloc` | 97 / 10 / 18 |
| `free` calls | 453 |
| `strcmp` / `strlen` / `memcpy` | 161 / 98 / 77 |
| `extern(C)` declarations | 382 |
| fixed stack buffers (`char[64]`…`char[4096]`) | 13 |
| `dub` release flags | `-O3 -release` |

### 4.1 What is already idiomatic

- **GC-free by construction.** Zero `new` expressions, every buffer malloc-backed, and a unittest in
  `runtime.d` that asserts `GC.stats.allocatedInCurrentThread` does not move across 1,000
  timer create/clear cycles. This is the pattern the rest of the tree should be judged against —
  and it exists, so the review does not need to invent it.
- **`nothrow @nogc` at every boundary**, with `extern(C)` trampolines and status/JS-exception
  returns. That is exactly the two-tier error model the house guide prescribes.
- **Manual buffers (`Buf`) instead of `format`/`~=`**, checked allocation, explicit ownership.
- **Structs only**, no classes, no AAs — the systems-D shape.
- **Naming and layout follow the D Style**: modules lowercase, types PascalCase, functions camelCase,
  one module per concern.

### 4.2 Measured defect: the CJS export scanner is quadratic

`addName` in `src/djs/modules/cjsnames.d` de-duplicates by scanning every existing name
(`for (i; 0 .. set.count) if (eq(...))`), and `eq` recomputes `strlen` per comparison. The result:

| Exports | Scan time |
|---|---|
| 25,000 | 1.21 s |
| 50,000 | 5.14 s |
| 100,000 | 22.1 s |
| 200,000 | 94.4 s |

Each doubling costs ~4.2–4.3×. End to end, importing a generated CJS module from ESM:

| Exports | DJS total | of which scan | `qjs` on an equivalent ESM file | Node on that same ESM file |
|---|---|---|---|---|
| 25,000 | 2.51 s | 1.21 s | 1.35 s | — |
| 50,000 | 10.65 s | 5.14 s | 5.57 s | **0.25 s** |

(Node imports the CJS module at 25k in 1.13 s; the ESM column is a hand-written file with the same
number of `export const` declarations.)

That last column is the important one: the file QuickJS needs 5.57 s to link takes Node 0.25 s, and
the vendored `qjs` shows the same 5.57 s as DJS. **QuickJS's own module linking is superlinear above
~25k exports**, so that part is upstream, not a D-side defect. The scanner fix therefore removes roughly half of the CJS→ESM cost
(10.65 s → ~5.5 s at 50k) and the rest is upstream. That is still worth doing — 5 s is 5 s — but the
review should not promise Node parity on that synthetic shape.

This path only runs when ESM imports a CJS file (`esm.d:cjsModuleSource`), so ordinary `require`
never pays it — which is why it has not shown up in the corpus runs. A generated bundle with tens of
thousands of exports (or a big transpiled file) would.

Fix shape: keep the `NameSet` API, replace the linear scan with open addressing (FNV-1a, power-of-two
capacity, `malloc`'d slots). Prototype over the same 50k names:

| De-dupe | Time |
|---|---|
| current linear scan | 7,688 ms |
| open-addressing hash set | **4.8 ms** |

~1,600×, and it removes the `strlen`-per-compare. Expected end-to-end: 50k exports from 10.6 s to
roughly the cost of tokenising plus QuickJS parsing.

### 4.3 Structural findings (readability, not speed)

- **`esm.d` (805 lines)** duplicates the builtin registry: two `strcmp` chains over the same 41
  specifiers, 43 export arrays, 87 `strcmp` calls. One `static immutable` table of
  `{ spec, names, defaultExpr }` would collapse both chains and make "add a builtin" a one-line
  change. No measurable runtime effect (§2.6).
- **Function length**: `collectCjsExportNames` 283 lines, `runMain` 281, `spawn` (child.d) 253,
  `net` connect handler 172, `runtimeCreate` 161. The scanner is the one with a measured defect
  inside it; splitting it would also make the quadratic fix easier to test.
- **Cleanup duplication**: `apis/fs.d` has 1 `scope(exit)` and 148 `free()` calls; many are the same
  buffer freed on several error branches. Converting the obvious single-allocation cases to
  `scope(exit)` reduces leak surface without changing behaviour (and stays `@nogc`).
- **`strcmp`-heavy string handling** (161 calls) is normal at the C boundary; it is the *dispatch*
  uses (esm.d, cjs.d) that would read better as `switch`.
- **No `pure`**: leaf helpers (`isStart`, `isPart`, `skipString`, path/URL utilities) could carry
  `pure @nogc nothrow` and get compiler-checked against hidden state. Zero runtime cost.
- **13 fixed stack buffers** (`char[64]`, `char[128]`, `char[4096]`) — all in address/path/argv
  formatting. Not a defect, but each one is a silent-truncation risk that deserves a length check
  and a comment.

### 4.4 Guide vs code, itemised

| `docs/D-GUIDE.md` says | `src/` does |
|---|---|
| §2 "Put `@safe:` at module scope for pure-D modules" | 0 `@safe` |
| §2 "Prefer `pure @nogc nothrow` for leaf utilities" | 0 `pure` |
| §2 "`@trusted` only at the C boundary, one function at a time" | 0 `@trusted` (everything is `@system`) |
| §1 "release keeps `@safe` bounds checks" | true, but no code is `@safe`, so release has no checks |
| §3 "Use `scope(exit)` for cleanup" | 54 uses, but fs.d has 1 vs 148 `free`s |
| §6 "In hot paths, prefer `foreach` over a slice" | followed |
| §7 naming/indent/imports | followed |

The first three are not stylistic preferences: `@safe`/`@trusted` are how the project's stated
memory-safety story is supposed to be enforced, and they are absent. The review should decide
whether DJS wants that story (then start annotating leaves and accept the measured 28% bounds cost
in those functions, or pass `--boundscheck=off` and say so), or wants the current de-facto posture
(everything `@system`, no checks in release) and updates the guide to say it.

---

## 5. Recommendations, ranked

| # | Change | Expected effect | Risk |
|---|---|---|---|
| 1 | Hash-set de-dupe in `cjsnames.d` | 50k-export ESM import 10.6 s → ~5.5 s (the rest is QuickJS linking) | Low: local to `NameSet`, same API |
| 2 | Resolve the `@safe`/bounds-check contradiction (code + guide) | Safety honesty; possibly ~38% on hot @safe loops | Medium: policy decision, touches many signatures |
| 3 | Collapse `esm.d`'s two builtin chains into one table | 1 place to add a builtin; shorter file | Low; no runtime change |
| 4 | `scope(exit)` for single-allocation cleanup in `fs.d` | Smaller leak surface | Low |
| 5 | Split the 250+ line functions (scanner, `runMain`, `spawn`) | Reviewability; enables #1 | Low–medium |
| 6 | `pure @nogc nothrow` on leaf helpers | Compiler-checked purity, no runtime cost | Low |
| 7 | Do **not** chase `-flto`/`-mcpu` yet | None measurable at the binary level (§2.6) | — |

Ordering is by measured impact, not by tidiness: #1 is the only item with a number that changes a
user-visible outcome.

---

## 6. What this does not cover

- No profiling of QuickJS itself. Its module linker is superlinear above ~25k exports (measured
  identical under `qjs`), which bounds what a D-side fix can achieve on that shape.
- `-flto` untested (no LLVMgold on this host).
- GC pause behaviour under a real workload (`--DRT-gcopt=profile:1`) not measured; the tree allocates
  almost nothing, so this is low priority.
- The JS prelude (~8.5k lines) is out of scope; it is JavaScript, not D.

---

## 7. Reproduction

```bash
# microbenchmarks
ldc2 -O3 -release -boundscheck=on  /tmp/dbench.d -of=/tmp/dbench-on  && /tmp/dbench-on
ldc2 -O3 -release -boundscheck=off /tmp/dbench.d -of=/tmp/dbench-off && /tmp/dbench-off
ldc2 -O3 -release                  /tmp/dbench.d -of=/tmp/dbench-rel && /tmp/dbench-rel

# scanner scaling (links the real module)
python3 - <<'EOF'
for n in (25000, 50000, 100000, 200000):
    open(f"/tmp/mod{n}.js","w").write("\n".join(f"exports.k{i} = {i};" for i in range(n))+"\n")
EOF
ldc2 -O3 -release -I src /tmp/scanprobe.d src/djs/modules/cjsnames.d -of=/tmp/scanprobe
for n in 25000 50000 100000 200000; do /tmp/scanprobe /tmp/mod$n.js; done

# binary-level flags
build() { name=$1; shift; DFLAGS="$*" dub build -b release --compiler=ldc2 --force && cp djs /tmp/djs-$name; }
build base
build native   --mcpu=native
build nobounds --boundscheck=off
hyperfine --warmup 3 -r 15 \
  "/tmp/djs-base -A /tmp/imp.js" "/tmp/djs-native -A /tmp/imp.js" "/tmp/djs-nobounds -A /tmp/imp.js"
```

## 8. Sources

- D Style — <https://dlang.org/dstyle.html> (naming, declaration style, properties, docs, unittests)
- Memory-safe D — <https://dlang.org/spec/memory-safe-d.html> (`@safe`/`@trusted`/`@system`, and the
  sentence that bounds checks stay on in `@safe` code under `-release`)
- Garbage collection — <https://dlang.org/spec/garbage.html> (`@nogc`, collector configuration,
  conservative marking)
- LDC 1.36 `--help` (local): `--release`, `--boundscheck=on|safeonly|off`, `-flto`, `-mcpu`
- Idioms for the D Programming Language — <https://p0nce.github.io/d-idioms/>
- Auburn Sounds, "Running D without its runtime" —
  <https://www.auburnsounds.com/blog/2016-11-10_Running-D-without-its-runtime.html> (`@nogc`
  discipline, reasons to avoid GC in a callback-driven program)
- Ali Çehreli, *Programming in D* — <http://ddili.org/ders/d.en/> (const/immutable, ranges,
  `scope`)
- House documents: `docs/D-GUIDE.md`, `docs/research/d-idioms.md`, `docs/BENCHMARKS.md`

**Uncertainty log.** (a) Microbenchmark ratios are stable across five runs but absolute times depend
on the host; the binary-level table is noise-dominated and should not be read as "native is slower".
(b) The 50k/100k/200k scanner figures are single runs with no warmup; scaling, not the absolute
value, is the finding. (e) The `qjs` and Node ESM comparisons use a hand-written ESM file, not the CJS rewrite, so
they isolate module-linking cost rather than reproducing the full path. (c) Node's 50k figure was not measured; its lexer is linear by construction
but that is attribution, not measurement. (d) `-flto` was not measurable on this host.
