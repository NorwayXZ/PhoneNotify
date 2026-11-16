#!/bin/zsh
# One-line install of the latest PhoneNotify release:
#   curl -fsSL https://raw.githubusercontent.com/NorwayXZ/PhoneNotify/main/install.sh | zsh
set -e
REPO=NorwayXZ/PhoneNotify
TMP=$(mktemp -d)
echo "⬇️  Downloading latest PhoneNotify…"
URL=$(curl -fsSL https://api.github.com/repos/$REPO/releases/latest | grep -o '"browser_download_url": *"[^"]*PhoneNotify-macOS[^"]*\.zip"' | head -1 | cut -d'"' -f4)
[ -z "$URL" ] && { echo "No release found"; exit 1; }
curl -fL# "$URL" -o "$TMP/PhoneNotify.zip"
ditto -x -k "$TMP/PhoneNotify.zip" "$TMP"
pkill -x PhoneNotify 2>/dev/null || true
rm -rf /Applications/PhoneNotify.app
mv "$TMP/PhoneNotify.app" /Applications/
xattr -cr /Applications/PhoneNotify.app          # app is not notarized: clear the download quarantine
open /Applications/PhoneNotify.app
echo "✅ Installed /Applications/PhoneNotify.app"
