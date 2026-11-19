#!/bin/bash
# Builds MacTools.app from source with Apple's Swift compiler (Xcode or the free Command Line Tools).
#
#   ./build.sh               build only if the source changed
#   ./build.sh --force       always rebuild
#   ./build.sh --install     also copy the app to /Applications (or ~/Applications)
#   ./build.sh --dest PATH   copy the finished app to PATH (used by the in-app updater)
#   ./build.sh --no-quit     don't quit a running copy of MacTools (used by the in-app updater)
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(pwd)"
APP_NAME="MacTools"
BUNDLE_ID="com.mactools.toolbox"
MIN_MACOS="13.0"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
STAMP="$BUILD_DIR/.build-hash"
CERT_NAME="MacTools Local Code Signing"

FORCE=0
INSTALL=0
NO_QUIT=0
DEST=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--force) FORCE=1 ;;
    -i|--install) INSTALL=1 ;;
    --no-quit) NO_QUIT=1 ;;
    --dest)
      shift
      DEST="${1:-}"
      [[ -n "$DEST" ]] || { echo "--dest needs a path"; exit 1; }
      ;;
    -h|--help)
      sed -n '2,9p' build.sh
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
  shift
done

quit_running_app() {
  [[ $NO_QUIT -eq 1 ]] && return 0
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
}

# Copies the built app over another app bundle (keeps the code signature intact).
copy_app_to() {
  local target="$1"
  [[ "$target" == "$APP" ]] && return 0
  mkdir -p "$(dirname "$target")"
  rm -rf "$target.new"
  ditto "$APP" "$target.new"
  rm -rf "$target"
  mv "$target.new" "$target"
}

install_app() {
  local dest="/Applications"
  if [[ ! -w "$dest" ]]; then
    dest="$HOME/Applications"
    mkdir -p "$dest"
  fi
  # Already installed and identical: don't quit a running MacTools for nothing.
  if cmp -s "$APP/Contents/MacOS/$APP_NAME" "$dest/$APP_NAME.app/Contents/MacOS/$APP_NAME" &&
     cmp -s "$APP/Contents/Info.plist" "$dest/$APP_NAME.app/Contents/Info.plist"; then
    echo "📦 $dest/$APP_NAME.app is up to date."
    return 0
  fi
  quit_running_app
  copy_app_to "$dest/$APP_NAME.app"
  echo "📦 Installed to $dest/$APP_NAME.app"
}

# Prints the code-signing "designated requirement" (what macOS uses to remember permissions).
requirement_of() {
  [[ -d "$1" ]] || return 0
  codesign -d -r- "$1" 2>&1 | sed -n 's/^designated => //p' || true
}

# Creates a self-signed code-signing certificate once, so every build has the same identity
# and macOS keeps the permissions you granted across updates.
ensure_signing_identity() {
  [[ "${MACTOOLS_ADHOC:-0}" == "1" ]] && return 1
  if security find-identity -p codesigning 2>/dev/null | grep -q "\"$CERT_NAME\""; then
    return 0
  fi
  echo "🔏 Creating a local code-signing certificate (one time only)…"
  local tmp
  tmp="$(mktemp -d)"
  cat > "$tmp/cert.cnf" <<CONF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $CERT_NAME
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONF
  if /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cert.cnf" \
        -keyout "$tmp/key.pem" -out "$tmp/cert.pem" >/dev/null 2>&1 &&
     /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$CERT_NAME" \
        -out "$tmp/cert.p12" -passout pass:mactools >/dev/null 2>&1 &&
     security import "$tmp/cert.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P mactools \
        -T /usr/bin/codesign >/dev/null 2>&1; then
    rm -rf "$tmp"
    echo "   If macOS asks whether codesign may use the key, click “Always Allow”."
    return 0
  fi
  rm -rf "$tmp"
  echo "   (Couldn't create the certificate – using a basic signature instead.)"
  return 1
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

HASH="$( { cat "${SOURCES[@]}" Resources/Info.plist Scripts/make_icon.swift build.sh; cat VERSION 2>/dev/null || true; uname -m; "$SWIFTC" --version 2>&1; } | shasum -a 256 | cut -d' ' -f1)"

if [[ $FORCE -eq 0 && -x "$APP/Contents/MacOS/$APP_NAME" && -f "$STAMP" && "$(cat "$STAMP")" == "$HASH" ]]; then
  echo "✅ MacTools is up to date."
  if [[ -n "$DEST" ]]; then copy_app_to "$DEST"; fi
  if [[ $INSTALL -eq 1 ]]; then install_app; fi
  exit 0
fi

TARGET="${DEST:-$APP}"
OLD_REQ="$(requirement_of "$TARGET")"

# Version information shown in the app and used by the updater.
REPO="$(grep -E '^REPO=' update.conf 2>/dev/null | head -1 | cut -d= -f2- || true)"
BRANCH="$(grep -E '^BRANCH=' update.conf 2>/dev/null | head -1 | cut -d= -f2- || true)"
COMMIT="${MACTOOLS_COMMIT:-}"
# The version number in VERSION: +0.1 for a small update, the next whole number for a full one.
VERSION="$(tr -d '[:space:]' < VERSION 2>/dev/null || true)"
[[ -n "$VERSION" ]] || VERSION="0.0"
SOURCE_KIND="folder"
if [[ -d "$ROOT/.git" ]] && command -v git >/dev/null 2>&1; then
  SOURCE_KIND="git"
  COMMIT="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo "$COMMIT")"
fi

# 3. Compile ------------------------------------------------------------------------------
ARCH="$(uname -m)"
mkdir -p "$BUILD_DIR"
TMP_BIN="$BUILD_DIR/$APP_NAME.bin"
echo "🔨 Building MacTools $VERSION for $ARCH (${#SOURCES[@]} files). This takes a minute or two…"
"$SWIFTC" -O -swift-version 5 -parse-as-library \
  -sdk "$SDK" -target "$ARCH-apple-macos$MIN_MACOS" \
  -module-name "$APP_NAME" \
  -o "$TMP_BIN" "${SOURCES[@]}"

# 4. Assemble the .app bundle -------------------------------------------------------------
quit_running_app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$TMP_BIN" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

PLIST="$APP/Contents/Info.plist"
plutil -replace MTSourceDir -string "$ROOT" "$PLIST"
plutil -replace MTSourceKind -string "$SOURCE_KIND" "$PLIST"
plutil -replace MTCommit -string "$COMMIT" "$PLIST"
plutil -replace MTRepo -string "$REPO" "$PLIST"
plutil -replace MTBranch -string "$BRANCH" "$PLIST"
plutil -replace MTBuildDate -string "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PLIST"
plutil -replace MTVersion -string "$VERSION" "$PLIST"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$PLIST"

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

# 5. Sign ---------------------------------------------------------------------------------
SIGNED=0
if ensure_signing_identity; then
  if codesign --force --deep --sign "$CERT_NAME" "$APP" >/dev/null 2>&1; then
    SIGNED=1
  else
    echo "   (Signing with the local certificate failed – using a basic signature instead.)"
  fi
fi
if [[ $SIGNED -eq 0 ]]; then
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "⚠️  Code signing failed – the app will still run."
fi

echo "$HASH" > "$STAMP"
touch "$APP"

if [[ -n "$DEST" ]]; then copy_app_to "$DEST"; fi

# If the signing identity changed, macOS ignores permissions granted to the old build.
# Clear the stale entries so you get a fresh, working prompt instead of a switch that does nothing.
NEW_REQ="$(requirement_of "$TARGET")"
if [[ -n "$OLD_REQ" && "$OLD_REQ" != "$NEW_REQ" ]]; then
  for service in Accessibility ListenEvent PostEvent ScreenCapture; do
    tccutil reset "$service" "$BUNDLE_ID" >/dev/null 2>&1 || true
  done
  echo "ℹ️  MacTools' signature changed – macOS will ask for its permissions again."
fi

echo "✅ Built $APP"

if [[ $INSTALL -eq 1 ]]; then install_app; fi
