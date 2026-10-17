#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
PROFILE="${RELAY_NOTARY_PROFILE:-relay-notary}"
MODE="${1:---release}"
case "$MODE" in
  --setup|--check|--release) ;;
  --help|-h)
    cat <<'HELP'
Usage: ./script/notarize.sh [--setup|--check|--release]
  --setup    Save notarization credentials interactively in Keychain.
  --check    Check Xcode, a Developer ID Application identity and credentials.
  --release  Build, sign, submit to Apple, staple, verify and package (default).

RELAY_NOTARY_PROFILE defaults to relay-notary.
RELAY_SIGN_IDENTITY selects a certificate SHA-1 or exact name when several exist.
Successful releases: dist/intel/notarized/RELAY.app and RELAY-Intel.zip.
HELP
    exit 0 ;;
  *) echo "Unknown option: $MODE (use --help)." >&2; exit 2 ;;
esac

xcrun --find notarytool >/dev/null
xcrun --find stapler >/dev/null
xcodebuild -version

if [[ "$MODE" == --setup ]]; then
  cat <<'SETUP'
Use your developer Apple Account, Team ID and an app-specific password from
https://account.apple.com/ (Sign-In and Security → App-Specific Passwords).
Enter secrets only in notarytool's secure prompt; they are stored in Keychain.
SETUP
  read -r -p 'Developer Apple Account email: ' APPLE_ACCOUNT
  read -r -p 'Developer Team ID (10 characters): ' DEVELOPER_TEAM
  if [[ -z "$APPLE_ACCOUNT" || ! "$DEVELOPER_TEAM" =~ ^[A-Z0-9]{10}$ ]]; then
    echo 'Enter your developer Apple Account email and its 10-character Team ID.' >&2
    exit 2
  fi
  exec xcrun notarytool store-credentials "$PROFILE" --apple-id "$APPLE_ACCOUNT" --team-id "$DEVELOPER_TEAM"
fi

# Resolve only valid Developer ID Application identities, never a development
# certificate or an ad-hoc fallback. A matching private key must be in Keychain.
IDENTITIES="$(security find-identity -v -p codesigning | sed -nE 's/^[[:space:]]*[0-9]+\) ([[:xdigit:]]{40}) "(Developer ID Application: .*)"$/\1|\2/p')"
SELECTED=""
COUNT=0
while IFS='|' read -r HASH NAME; do
  [[ -n "$HASH" ]] || continue
  if [[ -z "${RELAY_SIGN_IDENTITY:-}" || "$RELAY_SIGN_IDENTITY" == "$HASH" || "$RELAY_SIGN_IDENTITY" == "$NAME" ]]; then
    SELECTED="$HASH"
    COUNT=$((COUNT + 1))
  fi
done <<< "$IDENTITIES"
if [[ "$COUNT" -ne 1 ]]; then
  if [[ "$COUNT" -eq 0 ]]; then
    echo 'No matching valid Developer ID Application identity with a private key.' >&2
    echo 'In Xcode → Settings → Accounts → your team → Manage Certificates, create Developer ID Application.' >&2
  else
    echo 'Several Developer ID Application identities exist. Set RELAY_SIGN_IDENTITY to one exact name or SHA-1.' >&2
  fi
  exit 1
fi
export RELAY_SIGN_IDENTITY="$SELECTED"
printf 'Signing identity: %s\nKeychain profile: %s\n' "$SELECTED" "$PROFILE"
if ! xcrun notarytool history --keychain-profile "$PROFILE" --output-format plist >/dev/null; then
  echo 'Notarization credentials are unavailable or rejected. Run ./script/notarize.sh --setup.' >&2
  exit 1
fi
if [[ "$MODE" == --check ]]; then
  echo 'Developer ID signing and notarization credentials are ready.'
  exit 0
fi

mkdir -p "$ROOT_DIR/build" "$ROOT_DIR/dist/intel"
WORK_DIR="$(mktemp -d "$ROOT_DIR/build/notarization.XXXXXX")"
trap 'printf "Notarization build and diagnostics: %s\n" "$WORK_DIR"' EXIT
RELAY_BUILD_CONFIGURATION="${RELAY_BUILD_CONFIGURATION:-release}" RELAY_DIST_DIR="$WORK_DIR" "$ROOT_DIR/script/build_relay_bundle.sh"
APP="$WORK_DIR/RELAY.app"
codesign --verify --deep --strict --verbose=2 "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$WORK_DIR/submission.zip"

# Persist the submission ID/status even when Apple rejects the upload or waiting
# times out. Never replace a previously accepted release with an unfinished one.
SUBMIT_EXIT=0
xcrun notarytool submit "$WORK_DIR/submission.zip" --keychain-profile "$PROFILE" \
  --wait --timeout 30m --output-format plist > "$WORK_DIR/submission.plist" || SUBMIT_EXIT=$?
SUBMISSION_ID="$(/usr/libexec/PlistBuddy -c 'Print :id' "$WORK_DIR/submission.plist" 2>/dev/null || true)"
STATUS="$(/usr/libexec/PlistBuddy -c 'Print :status' "$WORK_DIR/submission.plist" 2>/dev/null || true)"
printf 'Apple submission: %s\nStatus: %s\n' "${SUBMISSION_ID:-unavailable}" "${STATUS:-unavailable}"
if [[ -n "$SUBMISSION_ID" ]]; then
  xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$PROFILE" "$WORK_DIR/notary-log.json" || true
fi
if [[ "$SUBMIT_EXIT" -ne 0 || "$STATUS" != Accepted ]]; then
  echo 'Notarization did not finish with Accepted status. Inspect submission.plist and notary-log.json in the diagnostics folder.' >&2
  echo 'For a pending submission, use notarytool info/wait with its ID; do not immediately resubmit.' >&2
  exit 1
fi

xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose=2 "$APP"

STAGE="$(mktemp -d "$ROOT_DIR/dist/intel/.notarized.XXXXXX")"
ditto "$APP" "$STAGE/RELAY.app"
# ZIP the stapled app, not the original submission archive.
ditto -c -k --sequesterRsrc --keepParent "$STAGE/RELAY.app" "$STAGE/RELAY-Intel.zip"
cp "$WORK_DIR/submission.plist" "$STAGE/"
if [[ -f "$WORK_DIR/notary-log.json" ]]; then cp "$WORK_DIR/notary-log.json" "$STAGE/"; fi
FINAL="$ROOT_DIR/dist/intel/notarized"
PREVIOUS=""
if [[ -e "$FINAL" ]]; then
  PREVIOUS="$ROOT_DIR/dist/intel/.notarized-previous-$$"
  mv "$FINAL" "$PREVIOUS"
fi
if ! mv "$STAGE" "$FINAL"; then
  if [[ -n "$PREVIOUS" ]]; then mv "$PREVIOUS" "$FINAL"; fi
  exit 1
fi
if [[ -n "$PREVIOUS" ]]; then rm -rf "$PREVIOUS"; fi
printf 'Notarized app: %s/RELAY.app\nDistributable ZIP: %s/RELAY-Intel.zip\n' "$FINAL" "$FINAL"
