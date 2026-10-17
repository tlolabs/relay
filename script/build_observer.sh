#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-run}"
BUILD_ARCH=x86_64
RUST_TARGET=x86_64-apple-darwin
BUILD_CONFIGURATION="${RELAY_BUILD_CONFIGURATION:-debug}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export MACOSX_DEPLOYMENT_TARGET=14.0
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT_DIR/build/swift-module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE" "$ROOT_DIR/build/swiftpm-cache" "$ROOT_DIR/build/swiftpm-config" "$ROOT_DIR/build/swiftpm-security"
case "$MODE" in run|--build|--verify|--debug|--logs|--telemetry) ;; *) echo "Usage: $0 [--build|--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;; esac
if [[ "$MODE" != --build ]] && pgrep -x RelayObserver >/dev/null; then
  pkill -TERM -x RelayObserver
  for ((i=0; i<100; i++)); do
    if ! pgrep -x RelayObserver >/dev/null; then break; fi
    sleep 0.1
  done
  if pgrep -x RelayObserver >/dev/null; then echo "Close the running observer before rebuilding; its capture was not force-killed." >&2; exit 1; fi
fi
cd "$ROOT_DIR"
CARGO_ARGS=(build --locked -p relay-observer-core --target "$RUST_TARGET")
if [[ "$BUILD_CONFIGURATION" == release ]]; then CARGO_ARGS+=(--release); fi
cargo "${CARGO_ARGS[@]}"
export RUST_LIB_DIR="$ROOT_DIR/target/$RUST_TARGET/$BUILD_CONFIGURATION"
SWIFT_SCRATCH="$ROOT_DIR/build/swift-$BUILD_ARCH"
SWIFT_ARGS=(--disable-sandbox --cache-path "$ROOT_DIR/build/swiftpm-cache" --config-path "$ROOT_DIR/build/swiftpm-config" --security-path "$ROOT_DIR/build/swiftpm-security" --package-path "$ROOT_DIR/native/macos" --scratch-path "$SWIFT_SCRATCH" --arch "$BUILD_ARCH" --configuration "$BUILD_CONFIGURATION")
swift build "${SWIFT_ARGS[@]}" --product RelayObserver
BIN_DIR="$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)"
APP_BUNDLE="$ROOT_DIR/dist/intel/RELAY Observer.app"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Frameworks" "$APP_BUNDLE/Contents/Resources"
cp "$BIN_DIR/RelayObserver" "$APP_BUNDLE/Contents/MacOS/RelayObserver"
cp "$RUST_LIB_DIR/librelay_observer_core.dylib" "$APP_BUNDLE/Contents/Frameworks/"
if [[ ! -f "$ROOT_DIR/build/Observer.icns" || "$ROOT_DIR/script/create_icon.swift" -nt "$ROOT_DIR/build/Observer.icns" ]]; then
  swift "$ROOT_DIR/script/create_icon.swift" "$ROOT_DIR/build/Observer.iconset"
  iconutil -c icns "$ROOT_DIR/build/Observer.iconset" -o "$ROOT_DIR/build/Observer.icns"
fi
cp "$ROOT_DIR/build/Observer.icns" "$APP_BUNDLE/Contents/Resources/Observer.icns"
install_name_tool -id '@rpath/librelay_observer_core.dylib' "$APP_BUNDLE/Contents/Frameworks/librelay_observer_core.dylib"
RUST_LINK="$(otool -L "$APP_BUNDLE/Contents/MacOS/RelayObserver" | awk '/librelay_observer_core[.]dylib/{print $1;exit}')"
if [[ -z "$RUST_LINK" ]]; then echo "The app has no Rust library link." >&2; exit 1; fi
install_name_tool -change "$RUST_LINK" '@rpath/librelay_observer_core.dylib' "$APP_BUNDLE/Contents/MacOS/RelayObserver"
cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>RelayObserver</string>
<key>CFBundleIdentifier</key><string>com.tlolabs.relay.observer</string>
<key>CFBundleName</key><string>RELAY Observer</string>
<key>CFBundleDisplayName</key><string>RELAY Observer</string>
<key>CFBundleVersion</key><string>3</string>
<key>CFBundleIconFile</key><string>Observer.icns</string>
<key>CFBundleShortVersionString</key><string>0.2.1</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSAppleEventsUsageDescription</key><string>RELAY Observer reads iFlicks video IDs, paths and processing status for a diagnostic timeline. It does not start or change processing.</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP_BUNDLE/Contents/Frameworks/librelay_observer_core.dylib"
codesign --force --sign - "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"
lipo "$APP_BUNDLE/Contents/MacOS/RelayObserver" -verify_arch "$BUILD_ARCH"
lipo "$APP_BUNDLE/Contents/Frameworks/librelay_observer_core.dylib" -verify_arch "$BUILD_ARCH"
printf 'Built %s\n' "$APP_BUNDLE"
if [[ "$MODE" == --build ]]; then exit 0; fi
case "$MODE" in
  run) open -n "$APP_BUNDLE" ;;
  --verify) open -n "$APP_BUNDLE"; sleep 2; pgrep -x RelayObserver ;;
  --debug) lldb -- "$APP_BUNDLE/Contents/MacOS/RelayObserver" ;;
  --logs|--telemetry) open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "RelayObserver"' ;;
esac
