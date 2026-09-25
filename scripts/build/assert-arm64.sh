#!/usr/bin/env bash
# The one rule for a packaged Reed executable (DECIDED 2026-09-06): exactly
# the arm64 slice. A universal binary would update Intel installs into an app
# that cannot run; a Rosetta host's "native" build is x86_64 and must never
# be packaged. Used by build-app.sh (every ARCH, native included) and
# cut-release.sh; tested by scripts/qa/test_release_arch.py.
set -euo pipefail
bin="${1:?usage: assert-arm64.sh <executable>}"
archs="$(lipo -archs "$bin")"
if [[ "$archs" != "arm64" ]]; then
    echo "ERROR: $bin must be arm64 only, got: $archs" >&2
    exit 1
fi
