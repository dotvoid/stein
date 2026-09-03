#!/usr/bin/env bash
# Builds Stein.app.
#
# Assembled by hand rather than by xcodebuild: this machine has only the Command
# Line Tools, so there is no Xcode to build a bundle for us. That is fine - an
# app bundle is a directory, an Info.plist and a signature.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

CONFIGURATION=release
INSTALL=no
RUN=no
RESET_PERMISSION=no
VERSION=0.1.0
BUILD_NUMBER=1
BUNDLE_ID=com.dotvoid.stein

usage() {
  cat <<'USAGE'
usage: ./build.sh [--debug] [--install] [--run] [--reset-permission]

  --debug     build the debug configuration instead of release
  --install   move the built app to /Applications (replacing what is there)
  --run       relaunch the app when the build finishes
  --reset-permission
              forget the existing Accessibility grant so the new build prompts
              for a fresh one. Ad-hoc signatures change on every rebuild, and
              macOS then lists the app as allowed while silently denying it -
              which looks exactly like Stein being broken.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --debug) CONFIGURATION=debug ;;
    --install) INSTALL=yes ;;
    --run) RUN=yes ;;
    --reset-permission) RESET_PERMISSION=yes ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 64 ;;
  esac
  shift
done

echo "==> Compiling ($CONFIGURATION)"
swift build -c "$CONFIGURATION"
BINARY="$(swift build -c "$CONFIGURATION" --show-bin-path)/Stein"

# The icon is generated rather than committed as a binary blob.
ICON="$ROOT/Resources/AppIcon.icns"
if [ ! -f "$ICON" ]; then
  echo "==> Drawing app icon"
  ICON_TOOL="$(mktemp -d)/makeicon"
  swiftc -O "$ROOT/Tools/MakeIcon.swift" -o "$ICON_TOOL"
  "$ICON_TOOL" "$ICON"
fi

APP="$ROOT/build/Stein.app"
echo "==> Assembling $(basename "$APP")"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Stein"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>Stein</string>
  <key>CFBundleExecutable</key><string>Stein</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Stein</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <!-- No Dock icon and no app menu: Stein lives in the status bar. Set here as
       well as in code so no icon flashes in the Dock during launch. -->
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright (c) 2026 Danne Lundqvist. MIT licensed.</string>
</dict>
</plist>
PLIST

plutil -lint -s "$APP/Contents/Info.plist"

# Ad-hoc signature with a fixed identifier. macOS keys the Accessibility grant to
# the signature, so a stable identifier makes the grant survive rebuilds more
# often than it otherwise would.
echo "==> Signing (ad-hoc)"
codesign --force --sign - --identifier "$BUNDLE_ID" --timestamp=none "$APP"
codesign --verify --strict "$APP"

if [ "$INSTALL" = yes ]; then
  echo "==> Installing to /Applications"
  # Quit the running copy first: replacing a running bundle is how you get an app
  # that half-works until the next login.
  osascript -e 'quit app "Stein"' 2>/dev/null || true
  rm -rf /Applications/Stein.app
  cp -R "$APP" /Applications/Stein.app
  # Then take the staging copy away, so an install leaves exactly one Stein on
  # the machine. Two bundles claiming the same identifier is not a tidiness
  # problem: macOS keys the Accessibility grant to the bundle's path, so
  # whichever one was not granted is silently denied while still appearing in the
  # allowed list - and if both ever run, they share one store with no locking
  # between them and fight over every window on screen.
  rm -rf "$APP"
  APP=/Applications/Stein.app
fi

if [ "$RESET_PERMISSION" = yes ]; then
  echo "==> Resetting the Accessibility grant"
  osascript -e 'quit app "Stein"' 2>/dev/null || true
  tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
fi

if [ "$RUN" = yes ]; then
  echo "==> Launching"
  osascript -e 'quit app "Stein"' 2>/dev/null || true
  sleep 1
  open "$APP"
fi

echo ""
echo "Built: $APP"
echo ""
echo "  Diagnostics (no UI):  $APP/Contents/MacOS/Stein --check"
echo "  Launch:               open $APP"
echo ""
echo "Stein needs Accessibility access. If macOS is holding a stale grant from an"
echo "earlier build, reset it with:  tccutil reset Accessibility $BUNDLE_ID"
