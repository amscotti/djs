# Pinned versions

One place for every pin. `scripts/bootstrap.sh` verifies the toolchain and QuickJS-NG commit; update this table whenever a pin changes, and record why in `docs/REVIEWS.md` or an ADR.

| Component | Pin | Verified by |
|---|---|---|
| OS | Ubuntu 24.04 x86_64 | `uname -a` |
| D compiler | LDC 1.36.0 (LLVM) | `ldc2 --version` |
| D compiler (macOS) | LDC 1.43.0+ (Homebrew) | `ldc2 --version` |
| Package manager | DUB 1.36.0 | `dub --version` |
| QuickJS-NG | `v0.17.0` — commit `6d46d07d04041b40f4f49eaa7fdebe44c314c699` | `scripts/bootstrap.sh` |
| libuv | 1.48.0 (system) | `pkg-config --modversion libuv` |
| OpenSSL | 3.0.13 runtime (`libcrypto.so.3`), linked directly; headers not required | `openssl version` |
| zlib | 1.3 (system, `libz`) | `grep ZLIB_VERSION /usr/include/zlib.h` |
| CMake | system | `cmake --version` |
| Ninja | 1.11.1 | `ninja --version` |
| JSValue ABI | 16 bytes, 8-byte aligned, non-NaN-boxed, 64-bit | `scripts/check-abi.sh` |
| `JSMemoryUsage` mirror | 208 bytes (26 × int64) | `scripts/check-abi.sh` |

QuickJS-NG is built by `bootstrap.sh` with `QJS_BUILD_EXAMPLES=OFF` and
`QJS_ENABLE_INSTALL=OFF`. `qjs` (the oracle used for the smoke test) needs
`quickjs-libc`, so that library is built in the same tree but is **never
linked** into DJS; `dub.json` links only `libqjs.a`. Building the library with
`QJS_BUILD_LIBC=OFF` in a second directory is the preferred future shape and is
tracked as an accepted deviation, not a release blocker.
