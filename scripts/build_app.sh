#!/bin/zsh
# Builds OldMapMatcher.app from the Swift package (no Xcode project needed).
# Usage: scripts/build_app.sh [--open | --install]
#   --install copies it to /Applications (replacing an earlier copy) and opens it.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product OldMapMatcher
BIN="$(swift build -c release --show-bin-path)/OldMapMatcher"

APP=build/OldMapMatcher.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/OldMapMatcher"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Old Map Matcher</string>
    <key>CFBundleDisplayName</key><string>Old Map Matcher</string>
    <key>CFBundleIdentifier</key><string>com.github.odjaahla.oldmapmatcher</string>
    <key>CFBundleExecutable</key><string>OldMapMatcher</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
if [[ "${1:-}" == "--open" ]]; then open "$APP"; fi
if [[ "${1:-}" == "--install" ]]; then
    osascript -e 'quit app id "com.github.odjaahla.oldmapmatcher"' 2>/dev/null || true
    DEST="/Applications/Old Map Matcher.app"
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    echo "Installed $DEST"
    open "$DEST"
fi
