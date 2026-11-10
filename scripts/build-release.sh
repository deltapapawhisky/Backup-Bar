#!/bin/bash
set -euo pipefail

# Builds a Developer ID signed, notarized and stapled zip for a GitHub release.
# Requires the Developer ID Application certificate for FAVR LIMITED (QMK68Z7M52)
# and a notarytool keychain profile for that team (shared with MacLayout).

# Configuration
APP_NAME="BackupBar"
SCHEME="BackupBar"
PROJECT="BackupBar.xcodeproj"
NOTARIZE_PROFILE="${NOTARIZE_PROFILE:-MacLayout-Notarize}"

# Paths
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${PROJECT_DIR}/build/release"
ARCHIVE_PATH="${BUILD_DIR}/${APP_NAME}.xcarchive"
EXPORT_PATH="${BUILD_DIR}/export"
APP_PATH="${EXPORT_PATH}/${APP_NAME}.app"

cd "$PROJECT_DIR"

echo "=== Building ${APP_NAME} ==="
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Step 1: Archive
echo "--- Archiving ---"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -archivePath "$ARCHIVE_PATH" \
  -configuration Release \
  CODE_SIGN_STYLE=Automatic \
  | tail -5

# Step 2: Export with Developer ID signing
echo "--- Exporting ---"
cat > "${BUILD_DIR}/ExportOptions.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "${BUILD_DIR}/ExportOptions.plist" \
  -exportPath "$EXPORT_PATH" \
  | tail -5

# Step 3: Verify code signing
echo "--- Verifying code signature ---"
codesign --verify --deep --strict "$APP_PATH"
SIGNATURE=$(codesign -dv --verbose=4 "$APP_PATH" 2>&1)
echo "$SIGNATURE" | grep "Authority=Developer ID Application" \
  || { echo "Not signed with a Developer ID certificate"; exit 1; }
echo "Code signature verified."

# Step 4: Notarize. notarytool exits 0 even when Apple rejects the upload, so check the status.
echo "--- Notarizing (this may take a few minutes) ---"
SUBMIT_ZIP="${BUILD_DIR}/${APP_NAME}-notarize.zip"
ditto -c -k --keepParent "$APP_PATH" "$SUBMIT_ZIP"
RESULT=$(xcrun notarytool submit "$SUBMIT_ZIP" \
  --keychain-profile "$NOTARIZE_PROFILE" \
  --wait \
  --output-format json)
STATUS=$(echo "$RESULT" | /usr/bin/python3 -c "import json,sys; print(json.load(sys.stdin).get('status'))")
if [ "$STATUS" != "Accepted" ]; then
  echo "Notarization failed with status: ${STATUS}"
  echo "$RESULT"
  echo "Details: xcrun notarytool log <id> --keychain-profile ${NOTARIZE_PROFILE}"
  exit 1
fi

# Step 5: Staple the ticket to the app (a zip can't be stapled) and check Gatekeeper accepts it
echo "--- Stapling ---"
xcrun stapler staple "$APP_PATH"
spctl --assess --type execute -vv "$APP_PATH"

# Step 6: Zip the stapled app for the release
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" \
  "${APP_PATH}/Contents/Info.plist")
BUILD_NUM=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" \
  "${APP_PATH}/Contents/Info.plist")
ZIP_PATH="${PROJECT_DIR}/build/${APP_NAME}-v${VERSION}.app.zip"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo ""
echo "=== Done! ==="
echo "Zip: $ZIP_PATH"
echo "Version: ${VERSION} (build ${BUILD_NUM})"
echo ""
echo "Next step: upload the zip to the v${VERSION} GitHub release."
