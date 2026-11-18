#!/bin/bash
# Builds build/Launchcheck.app.
#   --open        launch it afterwards
#   --install     copy it to /Applications and link the CLI as /usr/local/bin/launchcheck (or ~/.local/bin/launchcheck)
#   --dmg         also write build/Launchcheck-<version>.dmg, a universal build for sharing
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f Resources/AppIcon.icns ] || swift scripts/make-icon.swift "$PWD"

ARCHS=()
case " $* " in *" --dmg "*) ARCHS=(--arch arm64 --arch x86_64) ;; esac

swift build -c release ${ARCHS[@]+"${ARCHS[@]}"}
BIN_DIR="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)"
APP="build/Launchcheck.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Launchcheck" "$APP/Contents/MacOS/Launchcheck"
cp "$BIN_DIR/launchcheck-cli" "$APP/Contents/Resources/launchcheck-cli"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >/dev/null 2>&1   # ad-hoc signature so macOS will launch it locally
echo "Built $APP ($VERSION)"

for arg in "$@"; do
  case "$arg" in
    --install)
      pkill -x Launchcheck 2>/dev/null || true
      rm -rf /Applications/Launchcheck.app
      cp -R "$APP" /Applications/
      echo "Installed /Applications/Launchcheck.app"
      for dir in /usr/local/bin "$HOME/.local/bin"; do
        if mkdir -p "$dir" 2>/dev/null && ln -sf /Applications/Launchcheck.app/Contents/Resources/launchcheck-cli "$dir/launchcheck" 2>/dev/null; then
          echo "Linked CLI: $dir/launchcheck"
          break
        fi
      done
      open /Applications/Launchcheck.app ;;
    --open)
      pkill -x Launchcheck 2>/dev/null || true
      open "$APP" ;;
    --dmg)
      STAGE="$(mktemp -d)"
      cp -R "$APP" "$STAGE/"
      ln -s /Applications "$STAGE/Applications"
      DMG="build/Launchcheck-$VERSION.dmg"
      rm -f "$DMG"
      hdiutil create -volname Launchcheck -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
      rm -rf "$STAGE"
      echo "Wrote $DMG" ;;
  esac
done
