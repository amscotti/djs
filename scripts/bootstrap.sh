#!/usr/bin/env bash
# Bootstrap DJS: verify pinned toolchain, fetch/build pinned QuickJS-NG,
# compile the C ABI probe, and smoke-test the engine.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QJS_TAG="v0.17.0"
QJS_COMMIT="6d46d07d04041b40f4f49eaa7fdebe44c314c699"
QJS_DIR="$ROOT/vendor/quickjs-ng"
STAMP="$QJS_DIR/build/.djs-stamp"
QJS_CMAKE_ARGS=(
  -DCMAKE_BUILD_TYPE=Release
  -DBUILD_SHARED_LIBS=OFF
  -DQJS_BUILD_EXAMPLES=OFF
  -DQJS_ENABLE_INSTALL=OFF
)

fail() { printf 'bootstrap: %s\n' "$*" >&2; exit 1; }
warn() { printf 'bootstrap: warning: %s\n' "$*" >&2; }

# macOS has no nproc/sha256sum; keep one image working on both hosts.
JOBS="$( (command -v nproc >/dev/null 2>&1 && nproc) || sysctl -n hw.ncpu 2>/dev/null || echo 2)"
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

echo "== toolchain =="
command -v ldc2 >/dev/null || fail "ldc2 not found (apt install ldc)"
command -v dub  >/dev/null || fail "dub not found (apt install dub)"
command -v cmake >/dev/null || fail "cmake not found"
command -v ninja >/dev/null || fail "ninja not found (apt install ninja-build)"
command -v cc    >/dev/null || fail "cc not found"
pkg-config --exists libuv || fail "libuv development files not found (apt install libuv1-dev)"

LDC_VERSION="$(ldc2 --version 2>&1 | head -1)"
DUB_VERSION="$(dub --version 2>&1 | head -1)"
UV_VERSION="$(pkg-config --modversion libuv)"
NINJA_VERSION="$(ninja --version)"

check_pin() {
  local name="$1" actual="$2" want="$3"
  if [[ "$actual" != *"$want"* ]]; then
    if [ "${DJS_ALLOW_VERSION_DRIFT:-0}" = "1" ]; then
      warn "$name drift: expected $want, got '$actual' (DJS_ALLOW_VERSION_DRIFT=1)"
    else
      fail "$name pin mismatch: expected $want, got '$actual' (set DJS_ALLOW_VERSION_DRIFT=1 to override)"
    fi
  fi
}
check_pin LDC "$LDC_VERSION" "1.36"
check_pin DUB "$DUB_VERSION" "1.36"
check_pin libuv "$UV_VERSION" "1.48"
check_pin Ninja "$NINJA_VERSION" "1.11.1"
printf '  %s\n  %s\n  libuv %s\n  ninja %s\n' "$LDC_VERSION" "$DUB_VERSION" "$UV_VERSION" "$NINJA_VERSION"

echo "== QuickJS-NG $QJS_TAG =="
if [ ! -d "$QJS_DIR/.git" ]; then
  echo "  cloning..."
  git clone --depth 1 --branch "$QJS_TAG" https://github.com/quickjs-ng/quickjs.git "$QJS_DIR"
fi
ACTUAL_COMMIT="$(git -C "$QJS_DIR" rev-parse HEAD)"
[ "$ACTUAL_COMMIT" = "$QJS_COMMIT" ] || fail "QuickJS-NG commit mismatch: $ACTUAL_COMMIT != $QJS_COMMIT"

# DJS adds ArrayBuffer byte accounting to the pinned engine (memoryUsage).
# The patch is applied to the clean clone; a revision bump must refresh it.
QJS_PATCH="$ROOT/scripts/patches/quickjs-array-buffer-accounting.patch"
if ! git -C "$QJS_DIR" apply --reverse --check "$QJS_PATCH" >/dev/null 2>&1; then
  git -C "$QJS_DIR" apply "$QJS_PATCH" || fail "failed to apply $QJS_PATCH"
fi
PATCH_HASH="$(sha256_of "$QJS_PATCH")"

WANT_STAMP="commit=$QJS_COMMIT
patch=$PATCH_HASH
cmake=${QJS_CMAKE_ARGS[*]}"
if [ ! -f "$QJS_DIR/build/libqjs.a" ] || [ "$(cat "$STAMP" 2>/dev/null || true)" != "$WANT_STAMP" ]; then
  echo "  configuring and building static library..."
  cmake -S "$QJS_DIR" -B "$QJS_DIR/build" -G Ninja "${QJS_CMAKE_ARGS[@]}"
  cmake --build "$QJS_DIR/build" -j"$JOBS"
  printf '%s\n' "$WANT_STAMP" > "$STAMP"
fi
[ -f "$QJS_DIR/build/libqjs.a" ] || fail "libqjs.a not found after build"
file "$QJS_DIR/build/libqjs.a" | grep -q 'ar archive' || fail "libqjs.a is not a static archive"

echo "== ABI probe =="
cat > "$QJS_DIR/build/abi_check.c" <<'EOF'
#include "quickjs.h"
#ifdef JS_NAN_BOXING
#error "DJS requires the non-NaN-boxed 64-bit JSValue"
#endif
#ifdef JS_CHECK_JSVALUE
#error "JS_CHECK_JSVALUE is a debug checker; do not build the runtime with it"
#endif
_Static_assert(sizeof(JSValue) == 16, "JSValue layout mismatch");
_Static_assert(sizeof(void*) == 8, "DJS v0.1 targets 64-bit");
EOF
cc -std=c11 -I"$QJS_DIR" -c "$QJS_DIR/build/abi_check.c" -o "$QJS_DIR/build/abi_check.o"
echo "  ABI ok: sizeof(JSValue)=16, 64-bit, no NaN boxing"

echo "== smoke test =="
"$QJS_DIR/build/qjs" -e 'if (1 + 1 !== 2) throw new Error("bad js"); console.log("quickjs-ng ok")'

echo "bootstrap: ok"
