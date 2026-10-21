#!/usr/bin/env bash
# The binary version, VERSION and djsVersion must agree before a tag.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
want="$(tr -d '[:space:]' < VERSION)"
got="$(./djs --version)"
if [ "$got" != "v$want" ]; then
    echo "version mismatch: binary reports '$got', VERSION says 'v$want'" >&2
    exit 1
fi
if ! grep -q "djsVersion = \"v$want\"" src/djs/runtime.d; then
    echo "src/djs/runtime.d djsVersion does not match VERSION v$want" >&2
    exit 1
fi
echo "version ok: $got"
