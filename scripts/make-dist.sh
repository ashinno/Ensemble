#!/bin/zsh
# Builds a Release copy of Ensemble, ad-hoc signs it and zips it into dist/ for
# copying to another Mac (AirDrop, USB, shared folder…).
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project Ensemble.xcodeproj -scheme Ensemble -configuration Release \
  -derivedDataPath build CODE_SIGN_IDENTITY="-" build -quiet
APP="build/Build/Products/Release/Ensemble.app"
codesign --force --deep --sign - "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
OUT="dist/Ensemble-$VERSION.zip"
rm -f "$OUT"
ditto -c -k --keepParent "$APP" "$OUT"
echo "Built $OUT ($(du -h "$OUT" | cut -f1))"
echo
echo "On the other Mac:"
echo "  1. Copy the zip over (AirDrop is easiest) and double-click it to unzip."
echo "  2. Move Ensemble.app to /Applications."
echo "  3. First launch: right-click → Open (it is ad-hoc signed, not notarized),"
echo "     or run:  xattr -dr com.apple.quarantine /Applications/Ensemble.app"
