#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ARCH=x86_64
RUST_TARGET=x86_64-apple-darwin
BUILD_CONFIGURATION="${RELAY_BUILD_CONFIGURATION:-release}"
# Internal bundle builder. Public builds go through build_and_run.sh so that
# Apple acceptance and ticket validation happen before delivery or launch.
if [[ -z "${RELAY_SIGN_IDENTITY:-}" || "$RELAY_SIGN_IDENTITY" == - ]]; then
  echo 'A Developer ID signing identity is required. Use ./script/build_and_run.sh.' >&2
  exit 1
fi
if [[ -z "${RELAY_DIST_DIR:-}" ]]; then
  echo 'An isolated RELAY_DIST_DIR is required for the bundle builder.' >&2
  exit 1
fi
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export MACOSX_DEPLOYMENT_TARGET=14.0
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT_DIR/build/swift-module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE" "$ROOT_DIR/build/swiftpm-cache" "$ROOT_DIR/build/swiftpm-config" "$ROOT_DIR/build/swiftpm-security"
cd "$ROOT_DIR"
cargo run --locked -p relay-media-build
CARGO_ARGS=(build --locked -p relay-core --target "$RUST_TARGET")
if [[ "$BUILD_CONFIGURATION" == release ]]; then CARGO_ARGS+=(--release); fi
cargo "${CARGO_ARGS[@]}"
export RUST_LIB_DIR="$ROOT_DIR/target/$RUST_TARGET/$BUILD_CONFIGURATION"
SWIFT_SCRATCH="$ROOT_DIR/build/swift-$BUILD_ARCH"
SWIFT_ARGS=(--disable-sandbox --cache-path "$ROOT_DIR/build/swiftpm-cache" --config-path "$ROOT_DIR/build/swiftpm-config" --security-path "$ROOT_DIR/build/swiftpm-security" --package-path "$ROOT_DIR/native/macos" --scratch-path "$SWIFT_SCRATCH" --arch "$BUILD_ARCH" --configuration "$BUILD_CONFIGURATION")
swift build "${SWIFT_ARGS[@]}" --product Relay
BIN_DIR="$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)"
DIST_DIR="${RELAY_DIST_DIR:-$ROOT_DIR/dist/intel}"
mkdir -p "$DIST_DIR"
FINAL_BUNDLE="$DIST_DIR/RELAY.app"
APP_BUNDLE="$DIST_DIR/.RELAY-build-$$.app"
trap 'rm -rf "$APP_BUNDLE"' EXIT
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Frameworks" "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/Helpers"
cp "$ROOT_DIR/build/media/install/bin/ffmpeg" "$ROOT_DIR/build/media/install/bin/ffprobe" "$ROOT_DIR/build/media/install/bin/mediainfo" "$APP_BUNDLE/Contents/Helpers/"
cp "$ROOT_DIR/media-dependencies.json" "$ROOT_DIR/build/media/build-receipt.json" "$APP_BUNDLE/Contents/Resources/"
mkdir -p "$APP_BUNDLE/Contents/Resources/DependencySources" "$APP_BUNDLE/Contents/Resources/DependencyLicenses"
/usr/bin/python3 - "$ROOT_DIR" "$APP_BUNDLE" <<'PY'
import json, pathlib, shutil, sys
root, bundle = map(pathlib.Path, sys.argv[1:])
resources = bundle / 'Contents/Resources'
sources = json.loads((root / 'media-dependencies.json').read_text())['sources']
for source in sources:
    shutil.copy2(root / 'build/media/downloads' / source['archive'], resources / 'DependencySources')
    directory = root / 'build/media' / source['directory']
    licenses = [('COPYING.LGPLv2.1', 'FFmpeg-LGPL-2.1.txt')] if source['name'] == 'ffmpeg' else [
        ('MediaInfo/License.html', 'MediaInfo.html'), ('MediaInfoLib/License.html', 'MediaInfoLib.html'),
        ('ZenLib/License.txt', 'ZenLib.txt')]
    for origin, name in licenses:
        shutil.copy2(directory / origin, resources / 'DependencyLicenses' / name)
PY

cp "$BIN_DIR/Relay" "$APP_BUNDLE/Contents/MacOS/Relay"
cp "$RUST_LIB_DIR/librelay_core.dylib" "$APP_BUNDLE/Contents/Frameworks/"
if [[ ! -f "$ROOT_DIR/build/Relay.icns" || "$ROOT_DIR/script/create_relay_icon.swift" -nt "$ROOT_DIR/build/Relay.icns" ]]; then
  swift "$ROOT_DIR/script/create_relay_icon.swift" "$ROOT_DIR/build/Relay.iconset"
  iconutil -c icns "$ROOT_DIR/build/Relay.iconset" -o "$ROOT_DIR/build/Relay.icns"
fi
cp "$ROOT_DIR/build/Relay.icns" "$APP_BUNDLE/Contents/Resources/Relay.icns"
cp "$ROOT_DIR/native/macos/Sources/Relay/Resources/tmdb.svg" "$APP_BUNDLE/Contents/Resources/TMDB.svg"
cp "$ROOT_DIR/native/macos/Sources/Relay/Resources/Attribution.txt" "$APP_BUNDLE/Contents/Resources/Attribution.txt"
install_name_tool -id '@rpath/librelay_core.dylib' "$APP_BUNDLE/Contents/Frameworks/librelay_core.dylib"
install_name_tool -delete_rpath "$RUST_LIB_DIR" "$APP_BUNDLE/Contents/MacOS/Relay" 2>/dev/null || true
RUST_LINK="$(otool -L "$APP_BUNDLE/Contents/MacOS/Relay" | awk '/librelay_core[.]dylib/{print $1;exit}')"
if [[ -z "$RUST_LINK" ]]; then echo "The app has no Rust library link." >&2; exit 1; fi
install_name_tool -change "$RUST_LINK" '@rpath/librelay_core.dylib' "$APP_BUNDLE/Contents/MacOS/Relay"
cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Relay</string>
<key>CFBundleIdentifier</key><string>com.tlolabs.relay</string>
<key>CFBundleName</key><string>RELAY</string>
<key>CFBundleDisplayName</key><string>RELAY</string>
<key>CFBundleVersion</key><string>3</string>
<key>CFBundleIconFile</key><string>Relay.icns</string>
<key>CFBundleShortVersionString</key><string>0.2.1</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>Video</string>
<key>CFBundleTypeRole</key><string>Viewer</string>
<key>LSHandlerRank</key><string>Alternate</string>
<key>LSItemContentTypes</key><array>
<string>public.movie</string><string>public.mpeg-4</string><string>com.apple.m4v-video</string>
<string>com.apple.quicktime-movie</string><string>public.avi</string>
<string>org.matroska.mkv</string><string>org.webmproject.webm</string><string>public.mpeg-2-transport-stream</string>
</array>
<key>CFBundleTypeExtensions</key><array>
<string>mp4</string><string>m4v</string><string>mkv</string><string>mov</string><string>avi</string><string>webm</string><string>ts</string>
</array>
</dict></array>
<key>UTImportedTypeDeclarations</key><array>
<dict>
<key>UTTypeIdentifier</key><string>org.matroska.mkv</string>
<key>UTTypeDescription</key><string>Matroska video</string>
<key>UTTypeConformsTo</key><array><string>public.movie</string></array>
<key>UTTypeTagSpecification</key><dict>
<key>public.filename-extension</key><array><string>mkv</string></array>
<key>public.mime-type</key><string>video/x-matroska</string>
</dict></dict>
<dict>
<key>UTTypeIdentifier</key><string>org.webmproject.webm</string>
<key>UTTypeDescription</key><string>WebM video</string>
<key>UTTypeConformsTo</key><array><string>public.movie</string></array>
<key>UTTypeTagSpecification</key><dict>
<key>public.filename-extension</key><array><string>webm</string></array>
<key>public.mime-type</key><string>video/webm</string>
</dict></dict>
</array>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSAppleEventsUsageDescription</key><string>RELAY processes videos directly using its bundled media tools. Apple Events are used only when inspecting or recovering legacy iFlicks jobs or running optional compatibility fixtures.</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
for helper in "$APP_BUNDLE"/Contents/Helpers/*; do
  codesign --force --sign "$RELAY_SIGN_IDENTITY" --timestamp --options runtime "$helper"
  lipo "$helper" -verify_arch "$BUILD_ARCH"
done
codesign --force --sign "$RELAY_SIGN_IDENTITY" --timestamp --options runtime "$APP_BUNDLE/Contents/Frameworks/librelay_core.dylib"
codesign --force --sign "$RELAY_SIGN_IDENTITY" --timestamp --options runtime --entitlements "$ROOT_DIR/native/macos/Relay.entitlements" "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"
lipo "$APP_BUNDLE/Contents/MacOS/Relay" -verify_arch "$BUILD_ARCH"
lipo "$APP_BUNDLE/Contents/Frameworks/librelay_core.dylib" -verify_arch "$BUILD_ARCH"
if [[ -e "$FINAL_BUNDLE" ]]; then
  PREVIOUS_BUNDLE="$DIST_DIR/.RELAY-previous-$$.app"
  mv "$FINAL_BUNDLE" "$PREVIOUS_BUNDLE"
fi
if ! mv "$APP_BUNDLE" "$FINAL_BUNDLE"; then
  if [[ -n "${PREVIOUS_BUNDLE:-}" ]]; then mv "$PREVIOUS_BUNDLE" "$FINAL_BUNDLE"; fi
  exit 1
fi
if [[ -n "${PREVIOUS_BUNDLE:-}" ]]; then rm -rf "$PREVIOUS_BUNDLE"; fi
APP_BUNDLE="$FINAL_BUNDLE"
trap - EXIT
printf 'Built %s\n' "$APP_BUNDLE"
