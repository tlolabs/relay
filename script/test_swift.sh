#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export MACOSX_DEPLOYMENT_TARGET=14.0
export CLANG_MODULE_CACHE_PATH="$ROOT/build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/build/swift-module-cache"
export RUST_LIB_DIR="$ROOT/target/x86_64-apple-darwin/debug"
cd "$ROOT"
cargo run --locked -p relay-media-build
cargo build --locked --workspace --target x86_64-apple-darwin
swift test --disable-sandbox --cache-path "$ROOT/build/swiftpm-cache" \
    --config-path "$ROOT/build/swiftpm-config" --security-path "$ROOT/build/swiftpm-security" \
    --package-path "$ROOT/native/macos" --scratch-path "$ROOT/build/swift-x86_64" --arch x86_64 "$@"
