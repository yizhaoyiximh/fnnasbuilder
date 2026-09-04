#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
xcodegen generate

BUILD_DIR="build-release"
DIST_DIR="dist-release"
APP_NAME="FnNAS Builder.app"
DMG_PATH="$DIST_DIR/FnNASBuilder-1.0.0.dmg"

rm -rf "$BUILD_DIR" "$DIST_DIR"
xcodebuild \
  -project FnNASBuilder.xcodeproj \
  -scheme FnNASBuilder \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_IDENTITY=- \
  build

mkdir -p "$DIST_DIR"
cp -R "$BUILD_DIR/Build/Products/Release/$APP_NAME" "$DIST_DIR/"

DMG_STAGING="$(mktemp -d "${TMPDIR:-/tmp}/fnnas-dmg.XXXXXX")"
trap 'rm -rf "$DMG_STAGING"' EXIT
cp -R "$DIST_DIR/$APP_NAME" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"
hdiutil create \
  -volname "FnNAS Builder" \
  -srcfolder "$DMG_STAGING" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo "已生成：$DIST_DIR/$APP_NAME"
echo "已生成：$DMG_PATH"
