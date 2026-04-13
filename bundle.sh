#!/bin/bash
# Creates Patina.app bundle from the compiled binary.
# No Xcode, no signing. Just a folder structure macOS recognizes.
set -euo pipefail

cd "$(dirname "$0")"

# Build first if binary missing
if [ ! -f patina ]; then
    echo "[bundle] Binary not found, building..."
    ./build.sh
fi

APP="Patina.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp patina "$APP/Contents/MacOS/patina"

cat > "$APP/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>work.patina</string>
    <key>CFBundleName</key>
    <string>Patina</string>
    <key>CFBundleDisplayName</key>
    <string>Patina</string>
    <key>CFBundleExecutable</key>
    <string>patina</string>
    <key>CFBundleVersion</key>
    <string>0.1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAccessibilityUsageDescription</key>
    <string>Patina reads which apps, windows, and UI elements you interact with to detect workflow patterns. No screenshots or screen recording. Passwords and secure text fields are never captured.</string>
    <key>NSInputMonitoringUsageDescription</key>
    <string>Patina observes mouse clicks to detect which UI elements you interact with. Clicks are not recorded — only the element you clicked on.</string>
</dict>
</plist>
PLIST

echo "[bundle] Created $APP ($(du -sh "$APP" | cut -f1))"
echo "[bundle] Test locally: open $APP"
echo "[bundle] Package for release: tar czf patina-0.1.0-arm64.tar.gz $APP"
