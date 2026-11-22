#!/bin/bash
# Signs "MPC Loader.app" with a Developer ID certificate, has Apple notarise it, and makes a signed,
# notarised disk image to share. Runs on the build machine. docs/SIGNING.md explains the setup.
#
#   scripts/sign-and-notarise.sh
#
# Reads these from the environment. GitHub keeps them as repository secrets:
#   MACOS_CERTIFICATE_P12       the Developer ID Application certificate and its key, as base64 text
#   MACOS_CERTIFICATE_PASSWORD  the password the certificate was exported with
#   APPLE_ID                    the email address of the Apple Account in the developer program
#   APPLE_APP_PASSWORD          an app-specific password for that Apple Account
#   APPLE_TEAM_ID               the developer account's Team ID
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/MPC Loader.app"
DMG="dist/MPC-Loader.dmg"

for name in MACOS_CERTIFICATE_P12 MACOS_CERTIFICATE_PASSWORD APPLE_ID APPLE_APP_PASSWORD APPLE_TEAM_ID; do
  if [ -z "${!name:-}" ]; then
    echo "$name is missing. Check the repository secrets against docs/SIGNING.md." >&2
    exit 1
  fi
done

WORK="$(mktemp -d)"
KEYCHAIN="$WORK/signing.keychain-db"
KEYCHAIN_PASSWORD="$(uuidgen)"
cleanup() {
  security delete-keychain "$KEYCHAIN" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# 1. A keychain of its own for the certificate, deleted again at the end.
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 3600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
printf '%s' "$MACOS_CERTIFICATE_P12" | base64 --decode > "$WORK/certificate.p12"
if ! security import "$WORK/certificate.p12" -k "$KEYCHAIN" -P "$MACOS_CERTIFICATE_PASSWORD" -T /usr/bin/codesign >/dev/null; then
  echo "The certificate couldn't be opened. Check MACOS_CERTIFICATE_P12 and MACOS_CERTIFICATE_PASSWORD (docs/SIGNING.md, steps 3 and 6)." >&2
  exit 1
fi
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
# Searched alongside the usual keychains, so codesign can find the certificate.
existing=()
while IFS= read -r line; do
  line="${line#"${line%%[![:space:]]*}"}"
  existing+=("${line//\"/}")
done < <(security list-keychains -d user)
security list-keychains -d user -s "$KEYCHAIN" "${existing[@]}"

IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN" | awk -F'"' '/Developer ID Application/ { print $2; exit }')"
if [ -z "$IDENTITY" ]; then
  echo "No Developer ID Application certificate was found in MACOS_CERTIFICATE_P12. It may be another kind of certificate (docs/SIGNING.md, step 2)." >&2
  exit 1
fi
echo "Signing as: $IDENTITY"

notarise() {  # notarise <file>: sends it to Apple and waits for the verdict
  local file="$1" result="$WORK/notary.json" status id
  xcrun notarytool submit "$file" --apple-id "$APPLE_ID" --password "$APPLE_APP_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" --wait --timeout 45m --output-format json > "$result" || true
  status="$(plutil -extract status raw -o - "$result" 2>/dev/null || echo "no answer")"
  id="$(plutil -extract id raw -o - "$result" 2>/dev/null || true)"
  echo "Notarisation of $(basename "$file"): $status"
  if [ "$status" != "Accepted" ]; then
    cat "$result" >&2 || true
    if [ -n "$id" ]; then
      xcrun notarytool log "$id" --apple-id "$APPLE_ID" --password "$APPLE_APP_PASSWORD" --team-id "$APPLE_TEAM_ID" >&2 || true
    fi
    echo "Apple didn't accept $(basename "$file"). If it says the login failed, check APPLE_ID, APPLE_APP_PASSWORD and APPLE_TEAM_ID (docs/SIGNING.md, steps 4 to 6)." >&2
    exit 1
  fi
}

# 2. The app: signed with the hardened runtime Apple requires, notarised, then stapled so that
#    it opens without a warning even on a Mac that is offline.
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"
ditto -c -k --keepParent "$APP" "$WORK/MPC Loader.zip"
notarise "$WORK/MPC Loader.zip"
xcrun stapler staple "$APP"

# 3. The disk image people download: made from the stapled app, then signed, notarised and stapled too.
scripts/make-dmg.sh "$APP" "$DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
notarise "$DMG"
xcrun stapler staple "$DMG"

# 4. Gatekeeper's verdict, as a Mac that downloaded them would give it.
spctl --assess --type execute --verbose=2 "$APP"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
echo "Signed and notarised: $APP and $DMG"
