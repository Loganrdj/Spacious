#!/usr/bin/env bash
# Builds Spacious and packages it as a DMG.
#
#   scripts/release.sh [version]
#
# With Developer ID credentials in the environment, the app and DMG are signed
# and notarized. Without them, the app is signed with an "Apple Development"
# certificate from the keychain if there is one (not notarized, but macOS
# keeps permissions like Accessibility across updates), else ad-hoc.
#
#   DEVELOPER_ID_IDENTITY  e.g. "Developer ID Application: Logan Moss (434QVQFFXL)"
#   APPLE_TEAM_ID          e.g. 434QVQFFXL
#   APPLE_ID               Apple ID email used for notarization
#   APP_SPECIFIC_PASSWORD  app-specific password for that Apple ID
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${1:-$(grep -m1 'MARKETING_VERSION' project.yml | sed -E 's/.*"(.*)".*/\1/')}"
BUILD_DIR="build/release"
APP="$BUILD_DIR/export/Spacious.app"
DMG="build/Spacious-$VERSION.dmg"

rm -rf "$BUILD_DIR" "$DMG"
mkdir -p "$BUILD_DIR"

command -v xcodegen >/dev/null || { echo "xcodegen is required: brew install xcodegen"; exit 1; }
xcodegen generate --quiet

SIGNED=0
if [[ -n "${DEVELOPER_ID_IDENTITY:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
  SIGNED=1
  SIGN_ARGS=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$DEVELOPER_ID_IDENTITY" "DEVELOPMENT_TEAM=$APPLE_TEAM_ID" "OTHER_CODE_SIGN_FLAGS=--timestamp")
elif DEV_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 '"Apple Development' | sed -E 's/.*"(.*)"/\1/') && [[ -n "$DEV_IDENTITY" ]]; then
  # Team ID is the certificate's organizational unit.
  DEV_TEAM=$(security find-certificate -c "$DEV_IDENTITY" -p | openssl x509 -noout -subject | sed -E 's/.*OU ?= ?([A-Z0-9]+).*/\1/')
  echo "⚠️  No Developer ID credentials. Signing with \"$DEV_IDENTITY\" (not notarized)."
  SIGN_ARGS=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$DEV_IDENTITY" "DEVELOPMENT_TEAM=$DEV_TEAM" "OTHER_CODE_SIGN_FLAGS=--timestamp")
else
  echo "⚠️  No signing certificate found. Building an ad-hoc signed, un-notarized DMG."
  SIGN_ARGS=(CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual)
fi

echo "▶︎ Archiving Spacious $VERSION"
xcodebuild -project Spacious.xcodeproj -scheme Spacious -configuration Release \
  -archivePath "$BUILD_DIR/Spacious.xcarchive" \
  MARKETING_VERSION="$VERSION" \
  "${SIGN_ARGS[@]}" \
  archive | tail -n 3

mkdir -p "$BUILD_DIR/export"
if [[ $SIGNED == 1 ]]; then
  cat > "$BUILD_DIR/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$APPLE_TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict>
</plist>
EOF
  xcodebuild -exportArchive -archivePath "$BUILD_DIR/Spacious.xcarchive" \
    -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" -exportPath "$BUILD_DIR/export" | tail -n 2
else
  cp -R "$BUILD_DIR/Spacious.xcarchive/Products/Applications/Spacious.app" "$APP"
fi

echo "▶︎ Creating DMG"
STAGING="$BUILD_DIR/dmg"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Spacious" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null

if [[ $SIGNED == 1 ]]; then
  codesign --sign "$DEVELOPER_ID_IDENTITY" --timestamp "$DMG"
  if [[ -n "${APPLE_ID:-}" && -n "${APP_SPECIFIC_PASSWORD:-}" ]]; then
    echo "▶︎ Notarizing (this can take a few minutes)"
    xcrun notarytool submit "$DMG" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
      --password "$APP_SPECIFIC_PASSWORD" --wait
    xcrun stapler staple "$DMG"
  else
    echo "⚠️  APPLE_ID / APP_SPECIFIC_PASSWORD not set. Skipping notarization."
  fi
fi

echo "✅ $DMG"
