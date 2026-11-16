#!/bin/zsh
# Build PhoneNotify.app (universal arm64 + x86_64).
#   ./build.sh            build + install to /Applications and restart it
#   ./build.sh --no-install   build only (used by release.sh)
set -e
cd "$(dirname "$0")"
VER=$(cat VERSION)
APP=build/PhoneNotify.app
rm -rf $APP; mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp Info.plist $APP/Contents/
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VER" $APP/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VER//./}" $APP/Contents/Info.plist
cp Resources/AppIcon.icns $APP/Contents/Resources/
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target $arch-apple-macos13.0 Sources/*.swift -o build/PhoneNotify-$arch
done
lipo -create build/PhoneNotify-arm64 build/PhoneNotify-x86_64 -output $APP/Contents/MacOS/PhoneNotify
rm build/PhoneNotify-arm64 build/PhoneNotify-x86_64
# sign with a local Apple Development identity if there is one, otherwise ad-hoc
if security find-identity -v -p codesigning | grep -q "Apple Development"; then
  codesign --force --deep -s "Apple Development" $APP
else
  codesign --force --deep -s - $APP
fi
echo "built $APP ($VER)"
[[ "$1" == "--no-install" ]] && exit 0
pkill -x PhoneNotify 2>/dev/null || true
rm -rf /Applications/PhoneNotify.app && cp -R $APP /Applications/
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/PhoneNotify.app
echo "installed /Applications/PhoneNotify.app"
