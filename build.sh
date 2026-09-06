#!/bin/bash
# Builds MenuMon and assembles a .app bundle (no Xcode required — SwiftPM + a
# hand-written Info.plist is enough for a LSUIElement menu bar app).
set -euo pipefail

cd "$(dirname "$0")"
APP="build/MenuMon.app"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/MenuMon" "$APP/Contents/MacOS/MenuMon"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MenuMon</string>
  <key>CFBundleDisplayName</key><string>MenuMon</string>
  <key>CFBundleIdentifier</key><string>local.menumon</string>
  <key>CFBundleExecutable</key><string>MenuMon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" 2>/dev/null || true

echo "Built $APP"
echo "Run:  open $APP"
