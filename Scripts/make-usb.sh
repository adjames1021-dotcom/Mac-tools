#!/bin/bash
# Lays out MacTools Lite on a USB stick (or any folder):
#   Scripts/make-usb.sh /Volumes/MYSTICK
# Builds MacToolsLite.app, then copies the app, the Windows toolkit and a README to the target.
# Existing "MacToolsLite Data" and "Reports" folders on the target are kept.
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="${1:-}"
[[ -n "$TARGET" && -d "$TARGET" ]] || { echo "Usage: Scripts/make-usb.sh /Volumes/STICK  (the folder must exist)"; exit 1; }
[[ -w "$TARGET" ]] || { echo "❌ Can't write to $TARGET"; exit 1; }
TARGET="$(cd "$TARGET" && pwd)"

./build.sh --lite

APP="build.noindex/MacToolsLite.app"
# --noextattr: no ._ clutter on FAT/exFAT sticks; the signature lives in _CodeSignature, so it survives.
rm -rf "$TARGET/MacToolsLite.app.new"
ditto --noextattr --noqtn "$APP" "$TARGET/MacToolsLite.app.new"
rm -rf "$TARGET/MacToolsLite.app"
mv "$TARGET/MacToolsLite.app.new" "$TARGET/MacToolsLite.app"

mkdir -p "$TARGET/Tools" "$TARGET/Reports"
cp Lite/Tools/mac-report.sh Lite/Tools/WinTools.ps1 "$TARGET/Tools/"
cp "Lite/Windows Tools.bat" Lite/README.txt "$TARGET/"
chmod +x "$TARGET/Tools/mac-report.sh"

# cp leaves ._ AppleDouble files on FAT/exFAT sticks; merge them away.
dot_clean -m "$TARGET" 2>/dev/null || true

codesign --verify --deep "$TARGET/MacToolsLite.app" || echo "⚠️  The copied app's signature didn't verify – rebuild with ./build.sh --lite --force"
echo "✅ MacTools Lite is ready in $TARGET ($(du -sh "$TARGET/MacToolsLite.app" "$TARGET/Tools" | awk '{print $1}' | paste -sd+ -) used)"
