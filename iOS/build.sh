#!/bin/zsh
# Build & install the pairing companion on a USB-connected iPhone.
#   DEVELOPMENT_TEAM=XXXXXXXXXX BUNDLE_PREFIX=com.yourname ./build.sh
set -e
cd "$(dirname "$0")"
: ${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM (Xcode → Settings → Accounts → your team ID)}
: ${BUNDLE_PREFIX:=com.$(whoami)}
export DEVELOPMENT_TEAM BUNDLE_PREFIX
xcodegen generate
DEV=$(xcrun devicectl list devices 2>/dev/null | awk '/available/ {print $3; exit}')
[ -z "$DEV" ] && { echo "No iPhone found: connect it by USB and unlock it."; exit 1; }
xcodebuild -project MacNotifyCompanion.xcodeproj -scheme MacNotifyCompanion -destination "id=$DEV" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration -derivedDataPath build build | grep -E "error|BUILD"
xcrun devicectl device install app --device "$DEV" build/Build/Products/Debug-iphoneos/MacNotifyCompanion.app
echo "Installed. On the iPhone: Settings → General → VPN & Device Management → trust the developer, then open「Mac通知」."
