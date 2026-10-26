# Third-party notices

DJS links the following components. Their licences apply to those components,
not to DJS's own code.

- **QuickJS-NG v0.17.0** — MIT. <https://github.com/quickjs-ng/quickjs>
  Pinned commit `6d46d07d04041b40f4f49eaa7fdebe44c314c699`, built by
  `scripts/bootstrap.sh`; `libqjs.a` is linked, `libqjs-libc.a` is not.
- **libuv** — MIT. <https://libuv.org/> Linux builds use the pinned system
  1.48 library; the macOS artifact bundles Homebrew 1.53.0.
- **LDC / druntime / Phobos** — Boost Software License 1.0 and the D
  runtime's own licences, as shipped with LDC 1.36 (Linux) or 1.43.0 (macOS).
- **OpenSSL** — Apache License 2.0. <https://www.openssl.org/> Linux uses
  3.0; the macOS artifact bundles Homebrew 3.5.9.
  `libcrypto.so.3` for SHA-1/SHA-2/MD5, HMAC, AES, RSA/EC, the KDFs and
  `RAND_bytes`; `libssl.so.3` for TLS (`tls`, `https`, `wss`). The system
  provider configuration is used as-is; DJS loads no custom `openssl.cnf`.
- **Brotli** — MIT. <https://github.com/google/brotli>
  System `libbrotlienc`/`libbrotlidec`, used by `zlib.brotliCompress*` /
  `brotliDecompress*` and for `Accept-Encoding: br` decoding in `fetch`.
- **zlib 1.3** — zlib License. <https://zlib.net/> System `libz`, used for
  deflate/gzip streams.
- **Mozilla CA certificate bundle** — MPL-2.0. The macOS artifact ships
  Homebrew's `ca-certificates` PEM under `etc/cert.pem` so HTTPS works without
  Homebrew; the licence is included in the tarball.
