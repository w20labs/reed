#!/usr/bin/env bash
# Fetch Sparkle's release tarball and extract bin/ (sign_update, generate_keys,
# generate_appcast, BinaryDelta) into ./.sparkle-tools/bin/. These are the
# release-side tools; the runtime framework comes from the SPM dependency
# declared in Package.swift.
#
# The download is verified against a pinned SHA-256 **before** it is extracted,
# and the extracted sign_update is verified against its own pin before it is
# installed. That matters because sign_update is the binary that later receives
# the Sparkle EdDSA private key: an unverified download here is a signing-key
# problem, not just a build-tooling one.
#
# Re-run after bumping the Sparkle SPM version to keep tools in lockstep, and
# re-pin below at the same time.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-2.9.3}"
EXPECTED_ARCHIVE_SHA256="${2:-}"

# Pinned digests. The archive digest is the one GitHub publishes for the release
# asset, which you can re-read yourself:
#
#   gh api repos/sparkle-project/Sparkle/releases/tags/2.9.3 \
#     --jq '.assets[] | select(.name=="Sparkle-2.9.3.tar.xz") | .digest'
#
# The sign_update digest is of the binary inside that verified archive; it is
# checked separately so that a tool replaced after installation, or a different
# binary handed to a signing step later, does not pass unnoticed.
case "$VERSION" in
    2.9.3)
        PINNED_ARCHIVE_SHA256=74a07da821f92b79310009954c0e15f350173374a3abe39095b4fc5096916be6
        PINNED_SIGN_UPDATE_SHA256=bfb52400c3da18bb4c251ac4818c2c2e1e31c2e649a45b31c11109b6e57b34ad
        ;;
    *)
        PINNED_ARCHIVE_SHA256=""
        PINNED_SIGN_UPDATE_SHA256=""
        ;;
esac

ARCHIVE_SHA256="${EXPECTED_ARCHIVE_SHA256:-$PINNED_ARCHIVE_SHA256}"
if [[ -z "$ARCHIVE_SHA256" ]]; then
    echo "ERROR: no pinned digest for Sparkle $VERSION." >&2
    echo "       Read the published digest and pass it as the second argument:" >&2
    echo "         gh api repos/sparkle-project/Sparkle/releases/tags/$VERSION \\" >&2
    echo "           --jq '.assets[] | select(.name==\"Sparkle-$VERSION.tar.xz\") | .digest'" >&2
    echo "       Then add it to the pins in this script." >&2
    exit 1
fi

URL="https://github.com/sparkle-project/Sparkle/releases/download/${VERSION}/Sparkle-${VERSION}.tar.xz"
DEST=".sparkle-tools"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> downloading Sparkle ${VERSION}"
curl -sSLf "$URL" -o "$WORK/sparkle.tar.xz"

echo "==> verifying the download"
GOT="$(shasum -a 256 "$WORK/sparkle.tar.xz" | cut -d' ' -f1)"
if [[ "$GOT" != "$ARCHIVE_SHA256" ]]; then
    echo "ERROR: the Sparkle archive does not match its pinned digest." >&2
    echo "       expected $ARCHIVE_SHA256" >&2
    echo "       got      $GOT" >&2
    echo "       Nothing has been extracted. Do not work around this by editing" >&2
    echo "       the pin to match what arrived." >&2
    exit 1
fi
echo "    archive sha256 ok"

echo "==> extracting bin/"
mkdir -p "$WORK/x"
tar -xf "$WORK/sparkle.tar.xz" -C "$WORK/x" ./bin/

if [[ -n "$PINNED_SIGN_UPDATE_SHA256" ]]; then
    GOT_SIGN="$(shasum -a 256 "$WORK/x/bin/sign_update" | cut -d' ' -f1)"
    if [[ "$GOT_SIGN" != "$PINNED_SIGN_UPDATE_SHA256" ]]; then
        echo "ERROR: sign_update does not match its pinned digest." >&2
        echo "       expected $PINNED_SIGN_UPDATE_SHA256" >&2
        echo "       got      $GOT_SIGN" >&2
        exit 1
    fi
    echo "    sign_update sha256 ok"
fi

mkdir -p "$DEST/bin"
cp "$WORK/x/bin/"* "$DEST/bin/"
chmod 755 "$DEST"/bin/*

echo "==> done — tools at $DEST/bin/"
ls -la "$DEST/bin/"
