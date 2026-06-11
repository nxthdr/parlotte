#!/usr/bin/env bash
set -euo pipefail

# Validate and upload the exported .pkg to App Store Connect (TestFlight) using
# an App Store Connect API key — no Apple ID password or Transporter needed.
#
# One-time setup:
#   1. App Store Connect → Users and Access → Integrations → App Store Connect
#      API → generate a key with the "App Manager" role. Download the .p8
#      (only offered once) and note the Key ID and Issuer ID.
#   2. Place the key where altool looks for it:
#        mkdir -p ~/.appstoreconnect/private_keys
#        mv ~/Downloads/AuthKey_<KEYID>.p8 ~/.appstoreconnect/private_keys/
#   3. Copy apple/Parlotte/AppStoreConnect.local.example to
#      apple/Parlotte/AppStoreConnect.local and fill in the two IDs (gitignored).
#
# Then: ./scripts/archive.sh && ./scripts/upload.sh

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$REPO_ROOT/apple/Parlotte/build/export/Parlotte.pkg"
CRED_FILE="$REPO_ROOT/apple/Parlotte/AppStoreConnect.local"

# Credentials: prefer env vars; otherwise source the gitignored local file.
if [ -f "$CRED_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CRED_FILE"
fi

: "${ASC_KEY_ID:?Set ASC_KEY_ID (App Store Connect API Key ID) in env or $CRED_FILE}"
: "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID (App Store Connect API Issuer ID) in env or $CRED_FILE}"

if [ ! -f "$PKG" ]; then
    echo "error: $PKG not found. Run ./scripts/archive.sh first." >&2
    exit 1
fi

echo "Validating $PKG..."
xcrun altool --validate-app \
    -f "$PKG" -t macos \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"

echo "Uploading to App Store Connect..."
xcrun altool --upload-app \
    -f "$PKG" -t macos \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"

echo ""
echo "Done. The build will appear under TestFlight → macOS Builds after"
echo "processing (~10-20 min). Assign it to your tester group there."
