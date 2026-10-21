#!/usr/bin/env bash
# Build the release artifact for this host:
#   dist/djs-<version>-<os>-<arch>.tar.gz + .sha256
# Linux uses the default configuration; macOS uses --config=macos, which links
# the Homebrew OpenSSL/Brotli instead of the Linux sonames.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
VERSION="$(sed -n 's/.*djsVersion = "\([^"]*\)".*/\1/p' src/djs/runtime.d | head -1)"
VERSION="${VERSION:-v0.1.0}"

case "$(uname -s)" in
    Linux)  OS=linux ;;
    Darwin) OS=macos ;;
    *)      echo "package: unsupported OS $(uname -s)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
    x86_64|amd64)  ARCH=x86_64 ;;
    arm64|aarch64) ARCH=arm64 ;;
    *)             ARCH="$(uname -m)" ;;
esac

NAME="djs-$VERSION-$OS-$ARCH"
STAGE="$ROOT/dist/$NAME"
STAMP="$(git log -1 --format=%ct 2>/dev/null || date +%s)"

BUILD_ARGS=(--build=release --force)
if [ "$OS" = macos ]; then
    BUILD_ARGS+=(--config=macos)
fi
dub build "${BUILD_ARGS[@]}" >/dev/null

rm -rf "$STAGE"
mkdir -p "$STAGE/docs"
cp -p djs "$STAGE/djs"
cp -p README.md LICENSE THIRD_PARTY.md "$STAGE/"
cp -p docs/COMPAT.md docs/BENCHMARKS.md docs/PINS.md docs/ROADMAP.md "$STAGE/docs/"

# GNU tar can pin timestamps and ordering, so the same commit produces the same
# sha256 on any Linux host. bsdtar (macOS) has no --sort/--mtime options; the
# archive is still fine, just not bit-reproducible across machines.
if tar --version 2>/dev/null | grep -q GNU; then
    tar --sort=name --mtime="@$STAMP" --owner=0 --group=0 --numeric-owner \
        -C "$ROOT/dist" -czf "$ROOT/dist/$NAME.tar.gz" "$NAME"
else
    ( cd "$ROOT/dist" && COPYFILE_DISABLE=1 tar -czf "$NAME.tar.gz" "$NAME" )
fi

if command -v sha256sum >/dev/null 2>&1; then
    ( cd "$ROOT/dist" && sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256" )
else
    ( cd "$ROOT/dist" && shasum -a 256 "$NAME.tar.gz" > "$NAME.tar.gz.sha256" )
fi

echo "package: dist/$NAME.tar.gz"
cat "$ROOT/dist/$NAME.tar.gz.sha256"
