# Pinned versions

One place for every pin. `scripts/bootstrap.sh` verifies the toolchain and QuickJS-NG commit; update this table whenever a pin changes, and record why in `docs/REVIEWS.md` or an ADR.

| Component | Pin | Verified by |
|---|---|---|
| OS | Ubuntu 24.04 x86_64 | `uname -a` |
| D compiler | LDC 1.36.0 (LLVM) | `ldc2 --version` |
| D compiler (macOS) | LDC 1.43.0 (Homebrew) | `ldc2 --version` |
| DUB (macOS) | 1.42.0 | `dub --version` |
| libuv (macOS) | 1.53.0 (Homebrew) | `pkg-config --modversion libuv` |
| OpenSSL (macOS) | 3.5.9 (Homebrew) | `openssl version` |
| Brotli (macOS) | 1.2.1 (Homebrew) | `brew list --versions brotli` |
| CA roots (macOS artifact) | `ca-certificates` 2026-10-20 | `brew list --versions ca-certificates` |
| Package manager | DUB 1.36.0 | `dub --version` |
| QuickJS-NG | `v0.17.0` — commit `6d46d07d04041b40f4f49eaa7fdebe44c314c699` | `scripts/bootstrap.sh` |
| libuv | 1.48.0 (system) | `pkg-config --modversion libuv` |
| OpenSSL | 3.0.13 runtime (`libcrypto.so.3`), linked directly; headers not required | `openssl version` |
| zlib | 1.3 (system, `libz`) | `grep ZLIB_VERSION /usr/include/zlib.h` |
| CMake | system | `cmake --version` |
| Ninja | 1.11.1 | `ninja --version` |
| JSValue ABI | 16 bytes, 8-byte aligned, non-NaN-boxed, 64-bit | `scripts/check-abi.sh` |
| `JSMemoryUsage` mirror | 208 bytes (26 × int64) | `scripts/check-abi.sh` |

The macOS rows are the validated Homebrew versions, not hard pins: the pinned
LDC 1.36 cannot run on current macOS releases, Homebrew does not retain old
versions, and `bootstrap.sh` is Linux-pinned. CI therefore uses
`DJS_ALLOW_VERSION_DRIFT=1` on macOS, while the release gate records the actual
runtime (`djs --version`, artifact smoke test) and the integration suite runs
against the installed Homebrew libs. Treat the macOS rows as the versions this
branch was validated with; an update should re-run the macOS gate. macOS
support is arm64 (Apple Silicon) only; Intel Macs are not a target.

QuickJS-NG is built by `bootstrap.sh` with `QJS_BUILD_EXAMPLES=OFF` and
`QJS_ENABLE_INSTALL=OFF`. `qjs` (the oracle used for the smoke test) needs
`quickjs-libc`, so that library is built in the same tree but is **never
linked** into DJS; `dub.json` links only `libqjs.a`. Building the library with
`QJS_BUILD_LIBC=OFF` in a second directory is the preferred future shape and is
tracked as an accepted deviation, not a release blocker.
