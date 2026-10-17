#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-run}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
case "$MODE" in run|--build|--verify|--debug|--logs|--telemetry) ;; *) echo "Usage: $0 [--build|--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;; esac
if pgrep -x Relay >/dev/null; then
  if [[ "$MODE" == --build ]]; then
    echo 'Close the running RELAY app before rebuilding.' >&2
    exit 1
  fi
  pkill -TERM -x Relay
  for ((i=0; i<100; i++)); do
    if ! pgrep -x Relay >/dev/null; then break; fi
    sleep 0.1
  done
  if pgrep -x Relay >/dev/null; then echo 'Close the running RELAY app before rebuilding; it was not force-killed.' >&2; exit 1; fi
fi

# Build and notarize in isolation. Failures leave the standard app/ZIP intact.
"$ROOT_DIR/script/notarize.sh" --release
DIST_DIR="${RELAY_DIST_DIR:-$ROOT_DIR/dist/intel}"
mkdir -p "$DIST_DIR"
STAGE="$(mktemp -d "$DIST_DIR/.RELAY-delivery.XXXXXX")"
trap 'if [[ -e "$STAGE/previous.app" ]]; then echo "Previous app retained at $STAGE/previous.app" >&2; else rm -rf "$STAGE"; fi' EXIT
ACCEPTED_DIR="$ROOT_DIR/dist/intel/notarized"
ditto "$ACCEPTED_DIR/RELAY.app" "$STAGE/RELAY.app"
cp "$ACCEPTED_DIR/RELAY-Intel.zip" "$STAGE/RELAY-Intel.zip"
xcrun stapler validate "$STAGE/RELAY.app"
codesign --verify --deep --strict "$STAGE/RELAY.app"
spctl --assess --type execute --verbose=2 "$STAGE/RELAY.app"
if pgrep -x Relay >/dev/null; then
  echo 'RELAY was opened during notarization. Close it and rebuild before replacing the app.' >&2
  exit 1
fi
APP_BUNDLE="$DIST_DIR/RELAY.app"
PREVIOUS_BUNDLE="$STAGE/previous.app"
if [[ -e "$APP_BUNDLE" ]]; then mv "$APP_BUNDLE" "$PREVIOUS_BUNDLE"; fi
if ! mv "$STAGE/RELAY.app" "$APP_BUNDLE"; then
  if [[ -e "$PREVIOUS_BUNDLE" ]]; then mv "$PREVIOUS_BUNDLE" "$APP_BUNDLE"; fi
  exit 1
fi
if ! mv -f "$STAGE/RELAY-Intel.zip" "$DIST_DIR/RELAY-Intel.zip"; then
  rm -rf "$APP_BUNDLE"
  if [[ -e "$PREVIOUS_BUNDLE" ]]; then mv "$PREVIOUS_BUNDLE" "$APP_BUNDLE"; fi
  exit 1
fi
rm -rf "$PREVIOUS_BUNDLE"
printf 'Built and notarized %s\nDistributable ZIP: %s/RELAY-Intel.zip\n' "$APP_BUNDLE" "$DIST_DIR"
if [[ "$MODE" == --build ]]; then exit 0; fi
case "$MODE" in
  run) open -n "$APP_BUNDLE" ;;
  --verify) open -n "$APP_BUNDLE"; sleep 2; pgrep -x Relay ;;
  --debug) lldb -- "$APP_BUNDLE/Contents/MacOS/Relay" ;;
  --logs|--telemetry) open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "Relay"' ;;
esac
