#!/bin/bash
# Sourced by the test/gate scripts: one place for the Linux/macOS differences.
#
# - platform name and the DUB configuration to build/test with
# - `timeout` is not installed on stock macOS; CI installs Homebrew coreutils.
#   tmo() falls back to running without a limit when neither exists (the
#   infinite-loop fixtures require it, so CI must provide one).
# - a deterministic umask for the mode-printing tests.

DJS_PLAT=linux
DJS_DUB_CONFIG=""
DJS_UT_CONFIG=""
case "$(uname -s)" in
    Darwin)
        DJS_PLAT=darwin
        DJS_DUB_CONFIG="--config=macos"
        DJS_UT_CONFIG="--config=unittest-macos"
        ;;
esac
export DJS_PLAT DJS_DUB_CONFIG DJS_UT_CONFIG

DJS_TIMEOUT="$(command -v timeout || command -v gtimeout || true)"
export DJS_TIMEOUT

# tmo <seconds> <command...>
# A missing timeout utility is an error, never an unbounded run: the gate and
# the overnight harness cannot distinguish a hang from progress otherwise.
if [ -n "$DJS_TIMEOUT" ]; then
    tmo() {
        local n="$1"; shift
        "$DJS_TIMEOUT" -k 5 "$n" "$@"
    }
else
    tmo() {
        echo "tmo: no timeout utility found (brew install coreutils)" >&2
        return 125
    }
fi

umask 022
