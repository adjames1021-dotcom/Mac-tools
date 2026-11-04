#!/bin/bash
# Builds MacTools.app from source with Apple's Swift compiler (Xcode or the free Command Line Tools).
#
#   ./build.sh            build only if the source changed
#   ./build.sh --force    always rebuild
#   ./build.sh --install  also copy the app to /Applications (or ~/Applications)
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(pwd)"
APP_NAME="MacTools"
BUNDLE_ID="com.mactools.toolbox"
MIN_MACOS="13.0"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
STAMP="$BUILD_DIR/.build-hash"

FORCE=0
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    -f|--force) FORCE=1 ;;
    -i|--install) INSTALL=1 ;;
    -h|--help)
      sed -n '2,7p' build.sh
      exit 0
      ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

install_app() {
  local dest="/Applications"
  if [[ ! -w "$dest" ]]; then
    dest="$HOME/Applications"
    mkdir -p "$dest"
  fi
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  rm -rf "$dest/$APP_NAME.app"
  cp -R "$APP" "$dest/"
  echo "📦 Installed to $dest/$APP_NAME.app"
}

# 1. Check for macOS and a Swift compiler -------------------------------------------------
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "❌ MacTools can only be built on macOS."
  exit 1
fi

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "❌ Apple's Swift compiler isn't installed yet."
  echo "   Opening the installer for the free Xcode Command Line Tools…"
  xcode-select --install >/dev/null 2>&1 || true
  echo "   Click “Install”, wait for it to finish, then run MacTools again."
  exit 2
fi
SWIFTC="$(xcrun --find swiftc)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

# 2. Work out whether anything changed ----------------------------------------------------
SOURCES=()
while IFS= read -r file; do
  SOURCES+=("$file")
done < <(find Sources -name '*.swift' | sort)

if [[ ${#SOURCES[@]} -eq 0 ]]; then
  echo "❌ No Swift sources found in $ROOT/Sources"
  exit 1
fi

HASH="$( { cat "${SOURCES[@]}" Resources/Info.plist Scripts/make_icon.swift build.sh; uname -m; "$SWIFTC" --version 2>&1; } | shasum -a 256 | cut -d' ' -f1)"

if [[ $FORCE -eq 0 && -x "$APP/Contents/MacOS/$APP_NAME" && -f "$STAMP" && "$(cat "$STAMP")" == "$HASH" ]]; then
  echo "✅ MacTools is up to date."
  if [[ $INSTALL -eq 1 ]]; then install_app; fi
  exit 0
fi

OLD_CDHASH=""
if [[ -d "$APP" ]]; then
  OLD_CDHASH="$(codesign -dvvv "$APP" 2>&1 | awk -F= '/^CDHash=/{print $2}' || true)"
fi

# 3. Compile ------------------------------------------------------------------------------
ARCH="$(uname -m)"
mkdir -p "$BUILD_DIR"
TMP_BIN="$BUILD_DIR/$APP_NAME.bin"
echo "🔨 Building MacTools for $ARCH (${#SOURCES[@]} files). The first build takes a minute or two…"
"$SWIFTC" -O -swift-version 5 -parse-as-library \
  -sdk "$SDK" -target "$ARCH-apple-macos$MIN_MACOS" \
  -module-name "$APP_NAME" \
  -o "$TMP_BIN" "${SOURCES[@]}"

# 4. Assemble the .app bundle -------------------------------------------------------------
# Quit a running copy so the new version is the one that opens.
pkill -x "$APP_NAME" >/dev/null 2>&1 || true

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$TMP_BIN" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# App icon (optional – the build still succeeds if this step fails)
make_icon() {
  local work="$BUILD_DIR/icon-work"
  rm -rf "$work"
  mkdir -p "$work/AppIcon.iconset"
  "$SWIFTC" -O -sdk "$SDK" -target "$ARCH-apple-macos$MIN_MACOS" Scripts/make_icon.swift -o "$work/make_icon" >/dev/null 2>&1 || return 1
  "$work/make_icon" "$work/icon_1024.png" || return 1
  local s
  for s in 16 32 128 256 512; do
    sips -z $s $s "$work/icon_1024.png" --out "$work/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null 2>&1 || return 1
    sips -z $((s * 2)) $((s * 2)) "$work/icon_1024.png" --out "$work/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null 2>&1 || return 1
  done
  iconutil -c icns "$work/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns" || return 1
  rm -rf "$work"
}
make_icon || echo "   (App icon skipped)"

# Ad-hoc code signature so macOS can remember the permissions you grant.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "⚠️  Code signing failed – the app will still run."

echo "$HASH" > "$STAMP"

# A rebuilt app has a new signature, so macOS ignores permissions granted to the old one.
# Clear the stale entries so you get a fresh, working prompt instead of a switch that does nothing.
NEW_CDHASH="$(codesign -dvvv "$APP" 2>&1 | awk -F= '/^CDHash=/{print $2}' || true)"
if [[ -n "$OLD_CDHASH" && "$OLD_CDHASH" != "$NEW_CDHASH" ]]; then
  for service in Accessibility ListenEvent PostEvent ScreenCapture; do
    tccutil reset "$service" "$BUNDLE_ID" >/dev/null 2>&1 || true
  done
  echo "ℹ️  MacTools was updated – macOS will ask for its permissions again."
fi

touch "$APP"
echo "✅ Built $APP"

if [[ $INSTALL -eq 1 ]]; then install_app; fi
