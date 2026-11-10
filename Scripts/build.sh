#!/usr/bin/env bash
# Builds build/Parvus.app (ad-hoc signed) and dist/Parvus.dmg.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --arch arm64 --product Parvus
BIN="$(swift build -c release --arch arm64 --show-bin-path)"
APP="build/Parvus.app"
rm -rf "$APP" dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" dist
cp "$BIN/Parvus" "$APP/Contents/MacOS/Parvus"
cp Resources/Info.plist "$APP/Contents/Info.plist"
echo -n "APPL????" > "$APP/Contents/PkgInfo"
codesign --force --sign - --identifier com.parobita.parvus "$APP"
codesign --verify --strict --verbose=2 "$APP"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/" && ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Parvus" -srcfolder "$STAGE" -fs HFS+ -format UDZO -quiet dist/Parvus.dmg
echo "built $APP and dist/Parvus.dmg"
