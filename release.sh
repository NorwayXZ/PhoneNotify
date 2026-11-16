#!/bin/zsh
# Build everything and publish a GitHub release:  ./release.sh
set -e
cd "$(dirname "$0")"
VER=$(cat VERSION)
./build.sh --no-install
(cd esp32 && .venv/bin/pio run)
mkdir -p dist
B=esp32/.pio/build/esp32s3
BA=$(find ~/.platformio/packages/framework-arduinoespressif32 -name boot_app0.bin | head -1)
esp32/.venv/bin/esptool --chip esp32s3 merge-bin -o dist/PhoneNotify-firmware-esp32s3.bin --flash-mode dio --flash-size 8MB \
  0x0 $B/bootloader.bin 0x8000 $B/partitions.bin 0xe000 "$BA" 0x10000 $B/firmware.bin
rm -f dist/PhoneNotify-macOS-*.zip(N)
ditto -c -k --keepParent build/PhoneNotify.app dist/PhoneNotify-macOS-$VER.zip
gh release create "v$VER" dist/PhoneNotify-macOS-$VER.zip dist/PhoneNotify-firmware-esp32s3.bin \
  --title "PhoneNotify $VER" --notes-file RELEASE_NOTES.md
