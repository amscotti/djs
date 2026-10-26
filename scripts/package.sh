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

# macOS: the linker records Homebrew's absolute dylib paths. Bundle them and
# rewrite every install name so the tarball runs on a Mac without Homebrew.
if [ "$OS" = macos ]; then
    BREW_PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
    mkdir -p "$STAGE/lib" "$STAGE/licenses"

    resolve_dep() {
        local dep="$1" base
        case "$dep" in
            @rpath/*)
                base="${dep#@rpath/}"
                if [ -f "$STAGE/lib/$base" ]; then printf '%s' "$STAGE/lib/$base"; return 0; fi
                if [ -f "$BREW_PREFIX/lib/$base" ]; then printf '%s' "$BREW_PREFIX/lib/$base"; return 0; fi
                find "$BREW_PREFIX/opt" -path "*/lib/$base" -type f 2>/dev/null | head -1
                ;;
            "$BREW_PREFIX"/*) printf '%s' "$dep" ;;
            *) return 1 ;;
        esac
    }

    bundle_file() {
        local file="$1" dep base real
        while IFS= read -r dep; do
            [ -n "$dep" ] || continue
            case "$dep" in
                /usr/lib/*|/System/*|@executable_path/*) continue ;;
            esac
            real="$(resolve_dep "$dep" || true)"
            if [ -z "$real" ]; then
                echo "package: unresolved dylib dependency $dep in $file" >&2
                exit 1
            fi
            base="$(basename "$dep")"
            if [ ! -f "$STAGE/lib/$base" ]; then
                cp -L "$real" "$STAGE/lib/$base"
                chmod u+w "$STAGE/lib/$base"
                install_name_tool -id "@executable_path/lib/$base" "$STAGE/lib/$base"
                bundle_file "$STAGE/lib/$base"
            fi
            install_name_tool -change "$dep" "@executable_path/lib/$base" "$file"
        done < <(otool -L "$file" | tail -n +2 | awk '{print $1}')
    }

    bundle_file "$STAGE/djs"

    # ad-hoc signatures: install_name_tool invalidates the linker's signature,
    # and arm64 macOS refuses to execute an unsigned Mach-O.
    for f in "$STAGE/djs" "$STAGE"/lib/*.dylib; do
        codesign --force --sign - "$f" >/dev/null 2>&1 || {
            echo "package: codesign failed for $f" >&2
            exit 1
        }
    done

    if otool -L "$STAGE/djs" "$STAGE"/lib/*.dylib 2>/dev/null | grep -q "$BREW_PREFIX"; then
        echo "package: bundled binary still references Homebrew" >&2
        exit 1
    fi

    license_copy() {
        local name="$1" dest="$2" file
        file="$(find -L "$BREW_PREFIX/opt/$name" -maxdepth 1 \
            \( -iname 'LICENSE*' -o -iname 'COPYING*' \) -type f 2>/dev/null | head -1)"
        if [ -z "$file" ]; then
            echo "package: no license file for $name" >&2
            exit 1
        fi
        cp -p "$file" "$STAGE/licenses/$dest"
    }
    license_copy "openssl@3" "openssl-LICENSE.txt"
    license_copy "brotli" "brotli-LICENSE"
    license_copy "libuv" "libuv-LICENSE"
fi

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

# Smoke-test the artifact itself, not the build tree: this is where a broken
# @executable_path rewrite shows up.
if [ "$OS" = macos ]; then
    VERIFY="$ROOT/dist/$NAME.verify"
    rm -rf "$VERIFY"
    mkdir -p "$VERIFY"
    tar -xzf "$ROOT/dist/$NAME.tar.gz" -C "$VERIFY"
    "$VERIFY/$NAME/djs" --version >/dev/null
    "$VERIFY/$NAME/djs" -A -e 'const c=require("crypto"),z=require("zlib"); const h=c.createHash("sha256").update("x").digest("hex"); const g=z.gunzipSync(z.gzipSync(Buffer.from("ok"))).toString(); if(h!=="2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881"||g!=="ok")process.exit(1)' >/dev/null
    rm -rf "$VERIFY"
fi

echo "package: dist/$NAME.tar.gz"
cat "$ROOT/dist/$NAME.tar.gz.sha256"
