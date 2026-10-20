#!/bin/bash
# package-veyon-macos.sh — Empaqueta el bundle Veyon.app en un disco DMG.
#
# Uso:
#     ./scripts/package-veyon-macos.sh
#
# Espera que el bundle ya exista en build/veyon-macos/build/Veyon.app
# (lo produce el target "macos_bundle" de CMake).
#
# Resultado:
#     build/veyon-macos/build/Veyon-<version>.dmg
#
# El DMG contiene el bundle Veyon.app y un symlink a /Applications, de forma
# que el usuario pueda arrastrar la aplicación sobre la carpeta.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

BUILD_DIR="${VEYON_MACOS_BUILD_DIR:-$PROJECT_DIR/build/veyon-macos/build}"
BUNDLE="$BUILD_DIR/Veyon.app"
STAGING="$BUILD_DIR/dmg-staging"
OUT_DIR="$BUILD_DIR"

if [ ! -d "$BUNDLE" ]; then
    echo "ERROR: no existe el bundle $BUNDLE"
    echo "       ejecuta primero:  ninja -C $BUILD_DIR macos_bundle"
    exit 1
fi

VERSION="$(defaults read "$BUNDLE/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "0.0.0")"
DMG="$OUT_DIR/Veyon-$VERSION.dmg"

echo "── Empaquetar Veyon $VERSION para macOS ──"

# 1. Staging: el bundle + el symlink a /Applications ────────────────────────
echo "── preparar staging ──"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -a "$BUNDLE" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# 2. Crear el DMG ───────────────────────────────────────────────────────────
echo "── crear DMG ──"
rm -f "$DMG"

# El volumen intermedio se monta y se configura con AppleScript, ya que
# hdiutil por sí solo no puede fijar el layout del Finder.
TMP_DMG="$BUILD_DIR/Veyon-tmp.dmg"

hdiutil create \
    -srcfolder "$STAGING" \
    -volname "Veyon" \
    -fs "HFS+" \
    -format "UDRW" \
    -ov \
    "$TMP_DMG" >/dev/null

# Montar el volumen para aplicar el layout del Finder
MOUNT_DIR="$(mktemp -d)/mnt"
mkdir -p "$MOUNT_DIR"
hdiutil attach "$TMP_DMG" -readwrite -noverify -noautoopen -mountpoint "$MOUNT_DIR" >/dev/null

# Ocultar la carpeta de recursos del Finder y activar el layout
osascript <<APPLESCRIPT >/dev/null 2>&1 || true
tell application "Finder"
    tell disk "Veyon"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 150, 800, 550}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 96
        close
        open
        update without registering applications
        delay 2
    end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNT_DIR" >/dev/null

# Comprimir la imagen
hdiutil convert "$TMP_DMG" -format UDZO -o "$DMG" >/dev/null
rm -f "$TMP_DMG"
rm -rf "$STAGING"

if [ ! -f "$DMG" ]; then
    echo "ERROR: no se generó el DMG"
    exit 1
fi

SIZE="$(du -h "$DMG" | cut -f1)"
echo
echo "==> OK: $DMG  ($SIZE)"
echo "    Montar con:  hdiutil attach \"$DMG\""
