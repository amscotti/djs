# Tier 1 architecture and planning review

Scope: everything shipped through v0.14.1 (Buffer, module resolution, stream
interop, crypto core, HTTP upgrade, Blob/FormData, Brotli decoding). Written
before the remaining Tier 1 items (WebCrypto `subtle`, `async_hooks`, DNS
breadth) are implemented, because those three carry architectural decisions
that should not be made implicitly.

## Architecture findings

| # | Severity | Finding | Impact | Next phase |
|---|---|---|---|---|
| 1 | high | `js/prelude.js` is now ~5,100 lines and holds streams, fetch, HTTP, WS, HTTP/2, crypto, assert, module, Blob and zlib wrappers | every change risks unrelated regressions; review surface is large | split into ordered source chunks concatenated at build time, or importable prelude modules |
| 2 | high | CJS entry scripts still run as scripts, not wrapped functions, so top-level `var` leaks to the global object | subtle divergence from Node; libraries that assume module scope can collide | wrap entry through `cjsLoad` and keep `-e`/stdin as scripts |
| 3 | medium | `djs:ws`/HTTP2 still use local `wsU16`/`wsFind` helpers that Buffer now provides | duplicated byte logic, divergent bugs | delete helpers, add regression coverage, keep the tests |
| 4 | medium | upgraded HTTP connections stay in `server._connections`; `close()` sees them as busy | shutdown can wait on sockets owned by ws libraries | remove from tracking and mark upgraded |
| 5 | medium | `Readable.toWeb` enqueues without backpressure | unbounded memory with fast producers | honour `desiredSize`/`pull` in the adapter |
| 5a | medium | sockets expose `_readableState`/`_writableState` shims, not a real Duplex; `cork` is a no-op | `ws` works but backpressure/close paths are approximate | make `net.Socket` a true Duplex before Tier 2 |
| 6 | medium | compressed fetch bodies are buffered for decoding | SSE over gzip/br loses token streaming | streaming inflate/br transforms |
| 7 | medium | resolution is bounded by the entry directory; `require.resolve` of paths outside it fails | stricter than Node; some tools break | document as a permission boundary or widen to project root |
| 8 | low | module errors say "Cannot find module" without the specifier in `message` | worse diagnostics than Node | include specifier and parent |
| 9 | low | `X509Certificate` lacks chain/`checkPrivateKey`/`verify` | limited certificate validation | extend with TLS phase |

None of these block the three remaining Tier 1 features, but 1 and 2 should be
addressed in the next phase before adding WebCrypto's ~600 lines to the
prelude.

## Planning review

Delivered against the Tier 1 list:

1. Buffer completeness — **done** (v0.13.6)
2. Module resolution — **done** (v0.13.6)
3. Stream interop — **done** (v0.13.6)
4. Crypto core — **done** (v0.13.7); WebCrypto `subtle` core **done** (v0.13.9)
5. HTTP `upgrade` — **done** (v0.13.7)
6. WebCrypto `subtle` — **done** (v0.13.9), asymmetric JWK export and wrapping absent
7. Blob/File/FormData + uploads — **done** (v0.13.7)
8. `async_hooks`/`AsyncLocalStorage` — **not supported by decision**. The
   engine patch is out of scope for this project; the limitation is documented
   in `docs/COMPAT.md` and the prototype stays removed.
9. DNS breadth — **done** (v0.14.0): MX/TXT/SRV/CNAME/NS/PTR/SOA, promises,
   setServers, fake-DNS test
10. Brotli + fetch decoding — **done** (v0.13.8)

Sequencing corrections:

- Buffer and module resolution were merged into v0.13.6 because both are
  foundation work and shared one gate; the roadmap's v0.13.7 row was absorbed.
- Crypto, upgrade and Blob/FormData shipped together in v0.13.7; they touch
  different subsystems but were validated by one gate and three goldens.
- WebCrypto `subtle` should be its own release: JWK import/export and
  RSA/ECDSA parameter handling are large enough to need dedicated review.
- `async_hooks` is the riskiest remaining item: QuickJS exposes
  `JS_SetPromiseHook`, but propagation through timers and native callbacks
  needs explicit capture. A synchronous-only AsyncLocalStorage would be
  dishonest; either do promise hooks properly or document a narrower contract.
- DNS breadth needs a wire-format client over `dgram` (no libc API for
  MX/SRV/TXT) plus a fake-DNS test server; estimate M, not S.

## async_hooks attempt log (v0.13.9)

`JS_SetPromiseHook` exists in QuickJS-ng, so an AsyncLocalStorage was prototyped
in `src/djs/apis/async_hooks.d`:

- symbol property on promises for context, BEFORE/AFTER stack, `run`/`get`/
  `set`/`exit` natives, JS-side `AsyncLocalStorage` with per-instance ids, and
  timer/`queueMicrotask` context capture.

Two problems stopped it:

1. `JS_PROMISE_HOOK_INIT` passes a parent only for promises created with
   `promise.then`; async-function promises get none, so `await` lost context.
2. Falling back to the current context on every promise creation (to cover
   `await`) **segfaulted** the runtime during the first `als.run(async …)`.

The prototype was reverted; no `async_hooks` module ships. A correct fix needs
engine-level async context propagation (a QuickJS patch or a supported
`AsyncContext` hook), not a JS/native shim. That is a scoped engine task, not a
prelude feature.

## Recommended next phases

- v0.13.9 WebCrypto `subtle` core — **done**
- `async_hooks` is out of scope: it needs engine async-context support, and
  this project does not patch the engine. Documented as a compatibility limit.
- v0.14.1 compat harness — **done** for `ws` + `jose` (gate step 14); extend
  with `pg`, `undici`, `mongodb+srv` as the next slices
- v0.14.2 prelude split and entry-module wrapping (findings 1–2), before Tier 2

## Verification state

- v0.13.6, v0.13.7 and v0.13.8 each passed the 13-step gate.
- Goldens added: `buffer_full`, `module_resolve`, `stream_web_interop`,
  `crypto_core`, `http_upgrade`, `blob_formdata`, `fetch_decode`.
- Compatibility scorecard needs re-scoring after this batch; the previous 59%
  understated Buffer/module/crypto once the new surfaces are counted.
