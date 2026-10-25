#!/usr/bin/env bash
# Line coverage over src/djs/*.d, driven by the real test suites.
#
# Uses LDC's DMD-style --cov (.lst files). Every test case is a separate
# djs process and each process rewrites <module>.lst in its CWD, so this
# script swaps ./djs for a wrapper that runs the instrumented binary in a
# unique per-run directory (mirroring the checkout through symlinks,
# because tests and the .lst writer use paths relative to the CWD) and
# appends the counts to a TSV log. One awk pass merges everything.
#
# Reports two tables:
#   unittest — what `dub test` (the D unittest blocks) executes alone.
#              Known limitation: with a shared druntime the unittest
#              binary writes .lst files whose counters stay zero, so this
#              table reads 0% today; the D unittests are instead verified
#              by `dub test` pass/fail itself.
#   suite    — what integration.sh + gate-permissions.sh + gate-net.sh drive
#
# Usage: scripts/coverage.sh          (takes ~8–10 minutes; rebuilds twice)
# The plain release binary is restored at the end.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
COV=".dub/coverage"

echo "== build instrumented binaries =="
mkdir -p .dub
export DFLAGS="--cov"
dub build --build=release --config=application --compiler=ldc2 --force >"$COV.build.log" 2>&1 \
    || { tail -25 "$COV.build.log"; exit 1; }
[ -x ./djs ] || { echo "coverage: ./djs missing after build" >&2; exit 1; }
mkdir -p "$COV"
mv ./djs "$COV/djs-real"
REAL="$ROOT/.dub/coverage/djs-real"

dub test --compiler=ldc2 --force >>"$COV.build.log" 2>&1 \
    || { tail -25 "$COV.build.log"; exit 1; }
cp .dub/unittest/djs-unittest "$COV/djs-unittest"
unset DFLAGS

mkdir -p "$COV/runs" "$COV/merged"
: > "$COV/counts.tsv"
: > "$COV/unittest.tsv"

collect() { # $1 = lst dir, $2 = tsv out
    for lst in "$1"/*.lst; do
        [ -f "$lst" ] || continue
        base=$(basename "$lst" .lst)
        awk -v m="$base" '
            match($0, /^ *[0-9]+\|/) {
                v = $0
                sub(/^ */, "", v); sub(/\|.*/, "", v)
                print m "\t" NR "\t" (v + 0)
            }' "$lst" >> "$2"
    done
}

cat > ./djs <<WEOF
#!/bin/bash
REAL="$REAL"
RUN="$ROOT/.dub/coverage/runs/\$\$"
mkdir -p "\$RUN"
for e in "$ROOT"/*; do
    ln -sfn "\$e" "\$RUN/\$(basename "\$e")"
done
args=()
for a in "\$@"; do
    if [[ "\$a" != -* ]] && [ -f "\$a" ]; then
        case "\$a" in /*) args+=("\$a") ;; *) args+=("\$PWD/\$a") ;; esac
    else
        args+=("\$a")
    fi
done
trap 'kill -TERM "\$child" 2>/dev/null' TERM INT
( cd "\$RUN" && exec "\$REAL" "\${args[@]}" ) &
child=\$!
wait "\$child" 2>/dev/null
rc=\$?
if [ "\$rc" -ge 128 ]; then
    wait "\$child" 2>/dev/null
    rc=\$?
fi
for lst in "\$RUN"/*.lst; do
    [ -f "\$lst" ] || continue
    base=\$(basename "\$lst" .lst)
    awk -v m="\$base" '
        match(\$0, /^ *[0-9]+\|/) {
            v = \$0
            sub(/^ */, "", v); sub(/\|.*/, "", v)
            print m "\t" NR "\t" (v + 0)
        }' "\$lst" >> "$ROOT/.dub/coverage/counts.tsv"
done
rm -rf "\$RUN"
exit \$rc
WEOF
chmod +x ./djs

echo "== run D unittest blocks =="
ln -sfn "$ROOT/src" "$COV/merged/src"
( cd "$COV/merged" && "$COV/djs-unittest" >/dev/null 2>&1 )
rm -f "$COV/merged/src"
collect "$COV/merged" "$COV/unittest.tsv"

echo "== run JS suites against the instrumented binary =="
DJS_SKIP_BUILD=1 ./scripts/integration.sh >"$COV/integration.log" 2>&1
DJS_SKIP_BUILD=1 ./scripts/gate-permissions.sh >"$COV/permissions.log" 2>&1
DJS_SKIP_BUILD=1 ./scripts/gate-net.sh >"$COV/net.log" 2>&1
tail -1 "$COV/integration.log"

echo "== restore the plain release binary =="
rm -f ./djs
dub build --build=release --config=application --compiler=ldc2 --force >>"$COV.build.log" 2>&1

echo
echo "======== PER-MODULE LINE COVERAGE ========"
for tsv in unittest suite; do
    f="$COV/unittest.tsv"; [ "$tsv" = suite ] && f="$COV/counts.tsv"
    [ -s "$f" ] || continue
    echo "-- $tsv --"
    awk -F'\t' '
        { k=$1 SUBSEP $2; seen[k]=1; mods[$1]=1; cnt[k]+=$3 }
        END {
            for (m in mods) { tot[m]=0; cov[m]=0 }
            for (k in cnt) { split(k, p, SUBSEP); tot[p[1]]++; if (cnt[k]>0) cov[p[1]]++ }
            for (m in tot) printf "%-22s %6.2f%%  (%d/%d lines)\n", m, 100*cov[m]/tot[m], cov[m], tot[m]
        }' "$f" | sort
    awk -F'\t' '
        { k=$1 SUBSEP $2; seen[k]=1; cnt[k]+=$3 }
        END { t=0; c=0; for (k in cnt) { t++; if (cnt[k]>0) c++ }
              printf "%-22s %6.2f%%  (%d/%d lines)\n", TOTAL, 100*c/t, c, t }' "$f"
done
echo
echo "Raw per-line counts: $COV/counts.tsv (module<TAB>line<TAB>hits)"
echo "coverage: done"
