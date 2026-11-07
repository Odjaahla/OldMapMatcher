#!/bin/zsh
# Builds the iPhone app and installs it on a connected (or Wi-Fi paired) iPhone.
# Usage: scripts/build_phone.sh [device name or UDID]   (default: the first paired physical iPhone)
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

(cd iOS && xcodegen generate --quiet)

if [[ -z "${1:-}" ]]; then
    JSON=$(mktemp)
    xcrun devicectl list devices --quiet --json-output "$JSON" >/dev/null
    DEVICE=$(python3 -c 'import json,sys
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    h = d["hardwareProperties"]
    if h.get("reality") == "physical" and h.get("platform") == "iOS":
        print(h["udid"]); break' "$JSON")
    rm -f "$JSON"
else
    DEVICE=$1
fi
[[ -n "$DEVICE" ]] || { echo "No paired iPhone found (xcrun devicectl list devices)"; exit 1; }

xcodebuild -project iOS/OldMaps.xcodeproj -scheme OldMaps -configuration Release \
    -destination generic/platform=iOS -derivedDataPath build/ios -allowProvisioningUpdates \
    -quiet build

APP=build/ios/Build/Products/Release-iphoneos/OldMaps.app
xcrun devicectl device install app --device "$DEVICE" "$APP"
xcrun devicectl device process launch --device "$DEVICE" com.github.odjaahla.oldmaps || true
