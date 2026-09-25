#!/usr/bin/env bash
# Reject a bundle that was not built as a release for arm64: the stamp
# build-app.sh writes (ReedBuildConfiguration / ReedBuildArch) must be present
# and must say release / arm64. Missing, unknown or debug fails (review
# 2026-09-08). Usage: check-build-config.sh <Info.plist>
set -euo pipefail
PLIST="${1:?usage: check-build-config.sh <Info.plist>}"
[[ -f "$PLIST" ]] || { echo "ERROR: $PLIST not found" >&2; exit 1; }
CONF="$(/usr/libexec/PlistBuddy -c "Print :ReedBuildConfiguration" "$PLIST" 2>/dev/null || echo "missing")"
ARCH="$(/usr/libexec/PlistBuddy -c "Print :ReedBuildArch" "$PLIST" 2>/dev/null || echo "missing")"
if [[ "$CONF" != "release" ]]; then
    echo "ERROR: ReedBuildConfiguration is '$CONF' (must be 'release') — not a release build" >&2
    exit 1
fi
if [[ "$ARCH" != "arm64" ]]; then
    echo "ERROR: ReedBuildArch is '$ARCH' (must be 'arm64') — not the shipped architecture" >&2
    exit 1
fi
echo "build configuration: release arm64"
