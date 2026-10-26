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
case "$VERSION" in
    v[0-9]*.[0-9]*.[0-9]*) ;;
    *) echo "package: invalid VERSION '$VERSION'" >&2; exit 1 ;;
esac

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
    # Map staged basename -> source path. Two different Homebrew dylibs
    # sharing a basename would silently substitute the wrong binary; make
    # that loud instead. Lives outside the stage so it is never packaged.
    SRCMAP="$ROOT/dist/.bundle-map"
    rm -rf "$SRCMAP"
    mkdir -p "$SRCMAP"

    resolve_dep() {
        local dep="$1" base
        case "$dep" in
            @rpath/*)
                base="${dep#@rpath/}"
                # Resolve the real source first so a second library with the
                # same basename is compared against the recorded one. Only if
                # Homebrew has no copy do we reuse a staged source.
                if [ -f "$BREW_PREFIX/lib/$base" ]; then printf '%s' "$BREW_PREFIX/lib/$base"; return 0; fi
                found="$(find -L "$BREW_PREFIX/opt" -path "*/lib/$base" -type f -print 2>/dev/null | sed -n '1p')"
                if [ -n "$found" ]; then printf '%s' "$found"; return 0; fi
                if [ -f "$SRCMAP/$base" ]; then cat "$SRCMAP/$base"; return 0; fi
                ;;
            "$BREW_PREFIX"/*) printf '%s' "$dep" ;;
            *) return 1 ;;
        esac
    }

    bundle_file() {
        local file="$1" dep base real realPath
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
            # Compare resolved paths: Homebrew records both the /opt symlink
            # and the Cellar target for the same dylib, which is fine. A real
            # that IS the staged copy (@rpath resolution) is the same file by
            # construction and skips the check.
            realPath="$(realpath "$real" 2>/dev/null || printf '%s' "$real")"
            case "$realPath" in
                "$STAGE"/*) ;; # @rpath resolved to the staged copy
                *)
                    if [ -f "$SRCMAP/$base" ] && [ "$(cat "$SRCMAP/$base")" != "$realPath" ]; then
                        echo "package: dylib basename collision: $base from both" \
                            "$(cat "$SRCMAP/$base")" and "$realPath" >&2
                        exit 1
                    fi
                    printf '%s\n' "$realPath" > "$SRCMAP/$base"
                    ;;
            esac
            if [ ! -f "$STAGE/lib/$base" ]; then
                printf '%s\n' "$realPath" > "$SRCMAP/$base"
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

    if otool -L "$STAGE/djs" "$STAGE"/lib/*.dylib 2>/dev/null | grep -qF "$BREW_PREFIX"; then
        echo "package: bundled binary still references Homebrew" >&2
        exit 1
    fi
    # Every absolute dependency must be a system library.
    badDeps="$(otool -L "$STAGE/djs" "$STAGE"/lib/*.dylib 2>/dev/null |
        awk 'NR > 1 && $1 ~ /^\// && $1 !~ /:$/ &&
             $1 !~ /^\/usr\/lib\// && $1 !~ /^\/System\// { print $1 }' |
        sort -u)"
    if [ -n "$badDeps" ]; then
        echo "package: non-system absolute dependencies:" $badDeps >&2
        exit 1
    fi
    if otool -l "$STAGE/djs" "$STAGE"/lib/*.dylib 2>/dev/null |
        grep -A2 'LC_RPATH' | grep -qF "$BREW_PREFIX"; then
        echo "package: bundled binary still has a Homebrew rpath" >&2
        exit 1
    fi

    license_copy() {
        local name="$1" dest="$2" file
        file="$(find -L "$BREW_PREFIX/opt/$name" -maxdepth 1 \
            \( -iname 'LICENSE*' -o -iname 'COPYING*' \) -type f -print 2>/dev/null | sed -n '1p')"
        if [ -z "$file" ]; then
            echo "package: no license file for $name" >&2
            exit 1
        fi
        cp -p "$file" "$STAGE/licenses/$dest"
    }
    license_copy "openssl@3" "openssl-LICENSE.txt"
    license_copy "brotli" "brotli-LICENSE"
    license_copy "libuv" "libuv-LICENSE"
    # The bundled libcrypto's OPENSSLDIR points at Homebrew. loadCaFallbacks()
    # in tls.d reads <exe>/etc/cert.pem (and /etc/ssl/cert.pem), so ship a
    # Mozilla roots bundle so HTTPS works on a Mac without Homebrew.
    ca_src=""
    for cand in "$BREW_PREFIX/etc/ca-certificates/cert.pem" \
                "$BREW_PREFIX/etc/openssl@3/cert.pem" \
                "/etc/ssl/cert.pem"; do
        if [ -f "$cand" ]; then ca_src="$cand"; break; fi
    done
    if [ -z "$ca_src" ]; then
        echo "package: no CA bundle found to ship" >&2
        exit 1
    fi
    mkdir -p "$STAGE/etc"
    cp -L "$ca_src" "$STAGE/etc/cert.pem"
    chmod 644 "$STAGE/etc/cert.pem"
    if [ -f "$BREW_PREFIX/opt/ca-certificates/LICENSE" ]; then
        cp -p "$BREW_PREFIX/opt/ca-certificates/LICENSE" "$STAGE/licenses/ca-certificates-LICENSE"
    else
        printf 'Mozilla CA certificate bundle (MPL-2.0)\n' > "$STAGE/licenses/ca-certificates-LICENSE"
    fi
    rm -rf "$SRCMAP"
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
    gotVersion="$("$VERIFY/$NAME/djs" --version)"
    if [ "$gotVersion" != "$VERSION" ]; then
        echo "package: artifact version '$gotVersion' != '$VERSION'" >&2
        exit 1
    fi
    "$VERIFY/$NAME/djs" -A -e 'const c=require("crypto"),z=require("zlib"); const h=c.createHash("sha256").update("x").digest("hex"); const g=z.gunzipSync(z.gzipSync(Buffer.from("ok"))).toString(); if(h!=="2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881"||g!=="ok")process.exit(1)' >/dev/null
    # Prove the executable-relative CA fallback: append a test CA to the
    # shipped bundle, disable every default path, and connect to a local
    # server signed by that CA.
    tlsDir="$VERIFY/tls"
    mkdir -p "$tlsDir"
    cat > "$tlsDir/ca.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = DJS Artifact Test CA
[v3]
basicConstraints = CA:TRUE
EOF
    cat > "$tlsDir/srv.cnf" <<'EOF'
[req]
distinguished_name = dn
req_extensions = v3
prompt = no
[dn]
CN = localhost
[v3]
subjectAltName = IP:127.0.0.1
basicConstraints = CA:FALSE
EOF
    openssl req -x509 -newkey rsa:2048 -keyout "$tlsDir/ca.key" -out "$tlsDir/ca.pem" \
        -days 1 -nodes -config "$tlsDir/ca.cnf" >/dev/null 2>&1
    openssl req -new -newkey rsa:2048 -keyout "$tlsDir/srv.key" -out "$tlsDir/srv.csr" \
        -nodes -config "$tlsDir/srv.cnf" >/dev/null 2>&1
    openssl x509 -req -in "$tlsDir/srv.csr" -CA "$tlsDir/ca.pem" -CAkey "$tlsDir/ca.key" \
        -CAcreateserial -out "$tlsDir/srv.pem" -days 1 \
        -extfile "$tlsDir/srv.cnf" -extensions v3 >/dev/null 2>&1
    cat "$tlsDir/ca.pem" >> "$VERIFY/$NAME/etc/cert.pem"
    tlsPort=$((19443 + RANDOM % 400))
    openssl s_server -accept "$tlsPort" -cert "$tlsDir/srv.pem" -key "$tlsDir/srv.key" \
        -www -quiet >/dev/null 2>&1 &
    tlsPid=$!
    trap 'kill $tlsPid 2>/dev/null' EXIT
    sleep 0.5
    httpsOut="$(SSL_CERT_FILE=/nonexistent SSL_CERT_DIR=/nonexistent \
        "$VERIFY/$NAME/djs" -A -e "require('https').get('https://127.0.0.1:$tlsPort/', r => { console.log('https', r.statusCode); process.exit(0); }).on('error', e => { console.log('https-err', e.code); process.exit(1); })")"
    kill "$tlsPid" 2>/dev/null
    wait "$tlsPid" 2>/dev/null
    trap - EXIT
    if [ "$httpsOut" != "https 200" ]; then
        echo "package: artifact HTTPS fallback failed: $httpsOut" >&2
        exit 1
    fi
    rm -rf "$VERIFY"
fi

if [ "$OS" = linux ]; then
    gotVersion="$("$STAGE/djs" --version)"
    if [ "$gotVersion" != "$VERSION" ]; then
        echo "package: artifact version '$gotVersion' != '$VERSION'" >&2
        exit 1
    fi
    "$STAGE/djs" -A -e 'const c=require("crypto"),z=require("zlib"); if(!c.createHash("sha256").update("x").digest("hex")||z.gunzipSync(z.gzipSync(Buffer.from("ok"))).toString()!=="ok")process.exit(1)' >/dev/null
fi

echo "package: dist/$NAME.tar.gz"
cat "$ROOT/dist/$NAME.tar.gz.sha256"
