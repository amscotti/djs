#!/usr/bin/env bash
# Compile-time ABI probe against the pinned quickjs.h. This is the only check
# that sees the engine's real compile flags.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
OUT="$ROOT/.dub/abi"
mkdir -p "$OUT"
cat > "$OUT/abi_check.c" <<'EOF'
#include "quickjs.h"
#ifdef JS_NAN_BOXING
#error "DJS requires the non-NaN-boxed 64-bit JSValue"
#endif
#ifdef JS_CHECK_JSVALUE
#error "JS_CHECK_JSVALUE is a debug checker; do not build the runtime with it"
#endif
_Static_assert(sizeof(JSValue) == 16, "JSValue layout mismatch");
_Static_assert(sizeof(void*) == 8, "DJS v0.1 targets 64-bit");
_Static_assert(sizeof(JSMemoryUsage) == 208, "JSMemoryUsage mirror drift");
EOF
cc -std=c11 -I"$ROOT/vendor/quickjs-ng" -c "$OUT/abi_check.c" -o "$OUT/abi_check.o"
echo "check-abi: ok sizeof(JSValue)=16 sizeof(JSMemoryUsage)=208"
