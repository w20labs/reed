#!/usr/bin/env bash
# Generate Reed.icns from Tools/render-icon.swift.
#
# Output: ./Reed.icns at the project root.
#
# This is a one-shot tool. The .icns it produces is checked into the
# repo (so contributors don't need to rerun it for every build). Re-run
# when the icon design changes.

set -euo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d)"
ICONSET="$TMP/Reed.iconset"
mkdir -p "$ICONSET"

echo "==> rendering 1024×1024 master"
swift Tools/render-icon.swift "$ICONSET/icon_512x512@2x.png"

# Apple's iconutil expects this exact name set:
#   icon_16x16.png       icon_16x16@2x.png
#   icon_32x32.png       icon_32x32@2x.png
#   icon_128x128.png     icon_128x128@2x.png
#   icon_256x256.png     icon_256x256@2x.png
#   icon_512x512.png     icon_512x512@2x.png
echo "==> downsampling other sizes"
sips -z 16   16  "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_16x16.png"     >/dev/null
sips -z 32   32  "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_16x16@2x.png"  >/dev/null
sips -z 32   32  "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_32x32.png"     >/dev/null
sips -z 64   64  "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_32x32@2x.png"  >/dev/null
sips -z 128  128 "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_128x128.png"   >/dev/null
sips -z 256  256 "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_128x128@2x.png">/dev/null
sips -z 256  256 "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_256x256.png"   >/dev/null
sips -z 512  512 "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_256x256@2x.png">/dev/null
sips -z 512  512 "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_512x512.png"   >/dev/null

echo "==> iconutil → Reed.icns"
iconutil --convert icns "$ICONSET" --output Reed.icns

ls -la Reed.icns
echo "==> done"
