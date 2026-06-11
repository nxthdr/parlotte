#!/usr/bin/env bash
set -euo pipefail

# Produces a signed archive and a .pkg ready for App Store Connect upload.
# Uses automatic signing via the DEVELOPMENT_TEAM set in project.yml — Xcode
# must be signed into the matching Apple ID (Xcode → Settings → Accounts).
#
# Output:
#   build/Parlotte.xcarchive        — the archive (open in Xcode Organizer to inspect)
#   build/export/Parlotte.pkg       — signed installer package for MAS upload
#
# Upload with:
#   xcrun altool --upload-app -f build/export/Parlotte.pkg -t macos \\
#     -u <apple-id> -p <app-specific-password>
# or drag the .pkg into the Transporter.app from the Mac App Store.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APPLE_DIR="$REPO_ROOT/apple/Parlotte"
BUILD_DIR="$APPLE_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/Parlotte.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"

# Team ID: prefer $DEVELOPMENT_TEAM env var, else pull from the gitignored
# Config.xcconfig. Keeping the ID out of the repo is defense-in-depth — it's
# embedded in the shipped binary anyway, but there's no reason to publish it.
if [ -z "${DEVELOPMENT_TEAM:-}" ]; then
    CONFIG_FILE="$APPLE_DIR/Config.xcconfig"
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "error: $CONFIG_FILE missing. Copy Config.xcconfig.example and fill in DEVELOPMENT_TEAM." >&2
        exit 1
    fi
    DEVELOPMENT_TEAM="$(awk -F'=' '/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=/ { gsub(/[[:space:]]/, "", $2); print $2 }' "$CONFIG_FILE")"
    if [ -z "$DEVELOPMENT_TEAM" ]; then
        echo "error: DEVELOPMENT_TEAM not set in $CONFIG_FILE" >&2
        exit 1
    fi
fi

# Ensure Rust static lib + Swift bindings are up to date (release config).
"$REPO_ROOT/scripts/build-apple.sh" release

# Regenerate xcodeproj.
"$REPO_ROOT/scripts/gen-xcodeproj.sh"

cd "$APPLE_DIR"

echo "Archiving Parlotte..."
# -allowProvisioningUpdates lets xcodebuild register the App ID and create the
# distribution provisioning profile automatically against the signed-in
# account, instead of failing with "No profiles for 'dev.nxthdr.Parlotte'".
xcodebuild archive \
    -project Parlotte.xcodeproj \
    -scheme Parlotte \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination 'generic/platform=macOS' \
    -allowProvisioningUpdates

# Export options for Mac App Store upload. Pre-generated via:
#   xcodebuild -exportArchive -exportOptionsPlist <stub>
# The method key selects "app-store" (MAS) vs "developer-id" (direct distribution).
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"
cat > "$EXPORT_OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store</string>
    <key>destination</key>
    <string>export</string>
    <key>teamID</key>
    <string>${DEVELOPMENT_TEAM}</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
EOF

echo "Exporting archive..."
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -allowProvisioningUpdates

echo ""
echo "Archive: $ARCHIVE_PATH"
echo "Package: $EXPORT_PATH/Parlotte.pkg"
echo ""
echo "Next steps:"
echo "  1. Drag $EXPORT_PATH/Parlotte.pkg into Transporter.app, or run:"
echo "     xcrun altool --upload-app -f '$EXPORT_PATH/Parlotte.pkg' -t macos -u <apple-id> -p <app-specific-password>"
echo "  2. In App Store Connect, the build will appear under Parlotte → TestFlight → macOS Builds after processing (~10-20 min)."
