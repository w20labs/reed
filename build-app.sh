#!/usr/bin/env bash
# Build a .app bundle that macOS will accept for microphone + accessibility prompts.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Reed"
BUNDLE="$APP_NAME.app"
ENTITLEMENTS="$APP_NAME.entitlements"

# CONFIG=debug / ARCH=native gives a much faster local iteration loop (no
# optimizer, no dSYM). The shipped build is arm64 only (DECIDED 2026-09-06):
# the free tier is on-device, the model is Apple-Silicon-only, and an x86_64
# slice only ever produced an Intel blocker or a Rosetta launch that could not
# load the model. See dev-build.sh for the fast path.
CONFIG="${CONFIG:-release}"
case "$CONFIG" in
    release|debug) ;;
    *) echo "ERROR: unknown CONFIG=$CONFIG (use 'release' or 'debug')" >&2; exit 1 ;;
esac

ARCH="${ARCH:-arm64}"
case "$ARCH" in
    arm64|native) ;;
    *) echo "ERROR: unknown ARCH=$ARCH (use 'arm64' or 'native')" >&2; exit 1 ;;
esac

# A release cut owns its configuration (review 2026-09-08): BUILD_MODE=release
# forces release/arm64 whatever the shell inherited, says so, and the
# resolved configuration is stamped into the bundle for verify-dmg.sh to
# reject anything else. --resolve-only prints the resolution and exits.
if [[ "${BUILD_MODE:-}" == "release" ]]; then
    if [[ "$CONFIG" != "release" || "$ARCH" != "arm64" ]]; then
        echo "==> BUILD_MODE=release: forcing CONFIG=release ARCH=arm64 (shell had CONFIG=$CONFIG ARCH=$ARCH)"
    fi
    CONFIG=release
    ARCH=arm64
fi
echo "==> configuration: CONFIG=$CONFIG ARCH=$ARCH BUILD_MODE=${BUILD_MODE:-}"
if [[ "${1:-}" == "--resolve-only" ]]; then
    echo "resolved: $CONFIG $ARCH"
    exit 0
fi

# KeyboardShortcuts uses #Preview macros that require Xcode's toolchain
# (the CommandLineTools-only `swift` will fail with a PreviewsMacros error).
if [[ -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    SWIFT="xcrun --toolchain XcodeDefault swift"
else
    SWIFT="swift"
fi

# Resolve SPM dependencies up-front so we can patch the checkout before building.
echo "==> $SWIFT package resolve"
$SWIFT package resolve

# KeyboardShortcuts hits `NSLocalizedString(self, bundle: .module, comment: ...)`
# in Utilities.swift during RecorderCocoa.init. SwiftPM's generated
# `Bundle.module` uses the iOS layout (resources at the .app root) — on macOS
# resources are in Contents/Resources/, so Bundle.module's `Bundle(path:)`
# returns nil and fatalErrors on first use, crashing the Settings window
# (the actual cause of the v0.1.9/v0.1.10/v0.1.11 crashes).
#
# Patching the SPM-generated accessor doesn't work — SwiftPM regenerates it
# unconditionally on every build. Instead, patch upstream Utilities.swift to
# drop the `bundle: .module` argument: NSLocalizedString then falls back to
# the main app bundle. Reed ships English-only so the only side-effect would
# be losing KeyboardShortcuts' 17 localization files, which we don't use.
KS_UTIL=".build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/Utilities.swift"
if [[ -f "$KS_UTIL" ]] && grep -q 'bundle: \.module' "$KS_UTIL"; then
    sed -i '' 's|NSLocalizedString(self, bundle: \.module, comment: self)|NSLocalizedString(self, comment: self)|g' "$KS_UTIL"
    echo "==> patched KeyboardShortcuts Utilities.swift to avoid Bundle.module crash on macOS"
fi

# One architecture. The Sparkle framework ships universal in its
# xcframework artifact, which is harmless; the Reed binary is arm64.
ARM64_TRIPLE="arm64-apple-macosx14.0"

if [[ "$ARCH" == "native" ]]; then
    # No --triple: swift build targets the host arch directly.
    echo "==> $SWIFT build (native, $CONFIG)"
    $SWIFT build -c "$CONFIG"
    BIN_PATH="$($SWIFT build -c "$CONFIG" --show-bin-path)"
else
    echo "==> $SWIFT build arm64 ($CONFIG)"
    $SWIFT build -c "$CONFIG" --triple "$ARM64_TRIPLE"
    BIN_PATH="$($SWIFT build -c "$CONFIG" --triple "$ARM64_TRIPLE" --show-bin-path)"
fi
EXEC_PATH="$BIN_PATH/$APP_NAME"
if [[ ! -x "$EXEC_PATH" ]]; then
    echo "ERROR: the build did not produce $APP_NAME" >&2
    exit 1
fi

DSYM_PATH="$APP_NAME.app.dSYM"

echo "==> packaging $BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
mkdir -p "$BUNDLE/Contents/Resources"

# Third-party notices (compliance finding 2026-08-25; rebuilt after the
# third-party notice audit, kept in the private archive). Every packaged file is
# named and content-checked by scripts/build/third-party-notices.json, because
# the directory glob this replaced shipped whatever filename it happened to
# find: it missed the ONNX Runtime binary's notices and FluidAudio's nested
# texts entirely, and copied checkouts that were no longer in Package.resolved.
# A missing, corrupt or drifted input is a failed build, not a quiet omission.
python3 scripts/build/package-notices.py "$BUNDLE/Contents/Resources"

cp "$EXEC_PATH" "$BUNDLE/Contents/MacOS/$APP_NAME"
# Every packaged executable, ARCH=native included: a Rosetta host's native
# build is x86_64 and must never become a Reed.app (review 2026-09-06).
./scripts/build/assert-arm64.sh "$BUNDLE/Contents/MacOS/$APP_NAME"

# Extract debug symbols AFTER the binary is in place, so dsymutil captures
# the shipped binary's LC_UUID. Kept with the build for symbolicating the
# crash logs macOS itself writes; Reed sends no crash reports anywhere.
if [[ "$CONFIG" == "release" ]]; then
    echo "==> generating dSYM (all slices)"
    rm -rf "$DSYM_PATH"
    dsymutil "$BUNDLE/Contents/MacOS/$APP_NAME" -o "$DSYM_PATH" || echo "warning: dsymutil failed; macOS crashes won't symbolicate"
fi

cp Info.plist "$BUNDLE/Contents/Info.plist"
# The configuration that actually built this bundle (review 2026-09-08).
/usr/libexec/PlistBuddy -c "Add :ReedBuildConfiguration string $CONFIG" "$BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :ReedBuildArch string $ARCH" "$BUNDLE/Contents/Info.plist"
echo "==> stamped ReedBuildConfiguration=$CONFIG ReedBuildArch=$ARCH"

# App icon (Dock, Finder, ⌘-Tab, etc.). Generated by Tools/build-icns.sh;
# committed to the repo so contributors don't need to regenerate it.
if [[ -f "Reed.icns" ]]; then
    cp Reed.icns "$BUNDLE/Contents/Resources/Reed.icns"
else
    echo "warning: Reed.icns not found — run Tools/build-icns.sh to regenerate" >&2
fi

# Copy SPM-produced resource bundles into the canonical Contents/Resources/
# location. SPM's generated Bundle.module accessor is patched above to consult
# Bundle.main.resourceURL (= Contents/Resources/ on macOS), so this is where
# it'll find them. We also backfill the SPM-emitted Info.plist (only
# CFBundleDevelopmentRegion by default), which macOS 26+ otherwise refuses
# to load via Bundle.init(url:).
shopt -s nullglob
for bundle in "$BIN_PATH"/*.bundle; do
    cp -R "$bundle" "$BUNDLE/Contents/Resources/"
done
for b in "$BUNDLE/Contents/Resources/"*.bundle; do
    [[ -d "$b" ]] || continue
    name="$(basename "$b" .bundle)"
    # A resource bundle can ship with no Info.plist; codesign refuses to sign
    # those. Synthesize a minimal one if absent.
    [[ -f "$b/Info.plist" ]] || printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict/></plist>\n' > "$b/Info.plist"
    pb() { /usr/libexec/PlistBuddy -c "$1" "$b/Info.plist" >/dev/null 2>&1 || true; }
    pb "Add :CFBundleIdentifier string com.local.reed.${name}"
    pb "Add :CFBundlePackageType string BNDL"
    pb "Add :CFBundleName string ${name}"
    pb "Add :CFBundleInfoDictionaryVersion string 6.0"
    pb "Add :CFBundleDevelopmentRegion string en"
done
shopt -u nullglob

# Bundle the Geist / Geist Mono fonts. Info.plist's ATSApplicationFontsPath
# points macOS at this folder, which auto-registers them at launch. The
# OFL-*.txt license files ship alongside the .ttf because the SIL Open Font
# License requires the license to accompany the font when redistributed.
if [[ -d Resources/Fonts ]]; then
    mkdir -p "$BUNDLE/Contents/Resources/Fonts"
    cp Resources/Fonts/*.ttf "$BUNDLE/Contents/Resources/Fonts/"
    cp Resources/Fonts/OFL-*.txt "$BUNDLE/Contents/Resources/Fonts/"
fi

# Bundle the dictation cue sound. Loaded at runtime via Bundle.main (same
# rationale as Fonts above — Bundle.module's macOS resource path is broken).
if [[ -d Resources/Sounds ]]; then
    mkdir -p "$BUNDLE/Contents/Resources/Sounds"
    cp Resources/Sounds/*.wav "$BUNDLE/Contents/Resources/Sounds/"
fi

# Bundle the FastEnhancer denoise model. Loaded at runtime via Bundle.main
# (same rationale as Fonts/Sounds above — Bundle.module's macOS resource
# path is broken). Statically linked ONNX Runtime needs no separate
# framework-copy/codesign step here (verified: `otool -L` on a binary built
# against this same SPM dependency shows no onnxruntime dylib/framework).
if [[ -d Resources/Models ]]; then
    mkdir -p "$BUNDLE/Contents/Resources/Models"
    cp Resources/Models/*.onnx "$BUNDLE/Contents/Resources/Models/"
    cp Resources/Models/LICENSE-*.txt "$BUNDLE/Contents/Resources/Models/"
fi

# Embed Sparkle.framework (the auto-updater). SwiftPM builds it into BIN_PATH
# and links Reed against `@rpath/Sparkle.framework/...`, but doesn't copy it
# into the .app — that's our job. The framework also ships nested helpers
# (XPC services, Updater.app, Autoupdate) that each need their own signature;
# they get signed below alongside the other nested bundles.
if [[ -d "$BIN_PATH/Sparkle.framework" ]]; then
    mkdir -p "$BUNDLE/Contents/Frameworks"
    cp -R "$BIN_PATH/Sparkle.framework" "$BUNDLE/Contents/Frameworks/"
    # SwiftPM only bakes `@loader_path` (= Contents/MacOS/) into the binary;
    # add the canonical @executable_path/../Frameworks so dyld finds Sparkle
    # at the standard macOS location.
    install_name_tool -add_rpath @executable_path/../Frameworks \
        "$BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || true
fi

# Pick the best available signing identity.
#   Distribution: "Developer ID Application" (notarizable, runs anywhere)
#   Local dev:    "Apple Development"        (works on dev machine, can't be notarized)
#   Fallback:     ad-hoc                     (TCC grants won't persist across rebuilds)
DEVID_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/{print $2; exit}')"
DEV_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development/{print $2; exit}')"

# Allow caller to force a mode:    BUILD_MODE=dev  or  BUILD_MODE=release
MODE="${BUILD_MODE:-auto}"
if [[ "$MODE" == "auto" ]]; then
    [[ -n "$DEVID_IDENTITY" ]] && MODE=release || MODE=dev
fi

# Sign nested bundles before the outer .app. `codesign --deep` silently skips
# resource-only bundles (no Mach-O executable), which leaves them unsigned and
# fails to load on macOS 26+ under Hardened Runtime. `--deep` is also officially
# deprecated for distribution; sign each component explicitly instead.
#
# For Sparkle.framework, sign innermost-out: the XPC services and Updater.app
# inside the framework first, then the framework itself. Sparkle's installer
# and downloader run as separate processes and need their own signatures with
# the hardened runtime so Gatekeeper accepts the chain on download.
sign_inner() {
    local identity="$1" extra_flags="$2"
    shopt -s nullglob
    # Sparkle.framework nested components (innermost first).
    local sparkle="$BUNDLE/Contents/Frameworks/Sparkle.framework"
    if [[ -d "$sparkle" ]]; then
        for nested in \
            "$sparkle/Versions/B/XPCServices/Installer.xpc" \
            "$sparkle/Versions/B/XPCServices/Downloader.xpc" \
            "$sparkle/Versions/B/Updater.app" \
            "$sparkle/Versions/B/Autoupdate"; do
            [[ -e "$nested" ]] || continue
            # shellcheck disable=SC2086
            codesign --force $extra_flags --sign "$identity" "$nested"
        done
        # shellcheck disable=SC2086
        codesign --force $extra_flags --sign "$identity" "$sparkle"
    fi
    # SPM resource bundles (e.g. KeyboardShortcuts).
    for b in "$BUNDLE/Contents/Resources/"*.bundle; do
        [[ -d "$b" ]] || continue
        # shellcheck disable=SC2086
        codesign --force $extra_flags --sign "$identity" "$b"
    done
    shopt -u nullglob
}

case "$MODE" in
release)
    if [[ -z "$DEVID_IDENTITY" ]]; then
        echo "ERROR: BUILD_MODE=release but no Developer ID Application cert found" >&2
        exit 1
    fi
    echo "==> signing with Developer ID + hardened runtime (notarizable)"
    sign_inner "$DEVID_IDENTITY" "--options runtime"
    codesign --force --options runtime \
        --entitlements "$ENTITLEMENTS" \
        --sign "$DEVID_IDENTITY" "$BUNDLE"
    ;;
dev)
    if [[ -n "$DEV_IDENTITY" ]]; then
        echo "==> signing with: $DEV_IDENTITY (dev, no hardened runtime)"
        sign_inner "$DEV_IDENTITY" ""
        codesign --force --sign "$DEV_IDENTITY" "$BUNDLE"
    else
        echo "==> no developer identity found, falling back to ad-hoc"
        sign_inner - ""
        codesign --force --sign - "$BUNDLE"
    fi
    ;;
*)
    echo "ERROR: unknown BUILD_MODE=$MODE (use 'auto', 'dev', or 'release')" >&2
    exit 1
    ;;
esac

echo "==> verifying signature"
codesign --verify --verbose=2 "$BUNDLE"

echo "==> done ($MODE, $CONFIG, $ARCH)"
echo
echo "Run:      open ./$BUNDLE"
echo "Install:  cp -R ./$BUNDLE /Applications/"
if [[ -x "./notarize.sh" ]]; then
    echo "Notarize: ./notarize.sh   (only valid for release builds)"
fi
