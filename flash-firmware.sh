#!/bin/zsh
# Flash the ESP32-S3 bridge firmware. Plug the board in (either USB-C port works), then:
#   ./flash-firmware.sh [firmware.bin]
# Without an argument it downloads the firmware from the latest GitHub release.
set -e
REPO=NorwayXZ/PhoneNotify
DIR=$(mktemp -d)
BIN=${1:-}
if [ -z "$BIN" ]; then
  URL=$(curl -fsSL https://api.github.com/repos/$REPO/releases/latest | grep -o '"browser_download_url": *"[^"]*firmware[^"]*\.bin"' | head -1 | cut -d'"' -f4)
  BIN=$DIR/firmware.bin; curl -fL# "$URL" -o "$BIN"
fi
python3 -m venv "$DIR/venv" >/dev/null && "$DIR/venv/bin/pip" -q install esptool
PORT=$(ls /dev/cu.usbmodem* /dev/cu.wchusbserial* 2>/dev/null | head -1)
[ -z "$PORT" ] && { echo "No board found. Plug in the ESP32-S3 (if it still isn't found: hold BOOT, tap RST, release BOOT)."; exit 1; }
pkill -x PhoneNotify 2>/dev/null || true
echo "⚡️ Flashing $PORT …"
"$DIR/venv/bin/esptool" --chip esp32s3 --port "$PORT" --baud 921600 write-flash 0x0 "$BIN"
echo "✅ Done. Move the cable to the port labelled USB, then open PhoneNotify."
