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
#
# La imagen se prepara con diskutil en lugar de hdiutil: los subcomandos
# attach/detach de hdiutil están obsoletos en los macOS recientes y emiten
# la advertencia "use 'diskutil image attach ...' instead".  diskutil es
# además la interfaz de disco con la cuenta de administración.  La única
# excepción es la compresion final a UDZO, que sigue haciendo hdiutil:
# diskutil no tiene subcomando de conversion y convert no está deprecado.

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

# 1. Staging: el bundle + el symlink a /Applications ────────────────────────
echo "── preparar staging ──"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -a "$BUNDLE" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# El tamaño de la imagen se calcula a partir del contenido del staging, con
# un margen generoso para el sistema de ficheros y para el journal.
STAGING_BYTES="$(du -sk "$STAGING" | cut -f1)"
IMG_SIZE_MB=$(( STAGING_BYTES / 1024 * 2 + 400 ))

VOLUME_NAME="Veyon"

echo "── Empaquetar Veyon $VERSION para macOS ──"

# 2. Crear la imagen de disco ──────────────────────────────────────────────
echo "── crear imagen de disco ──"
rm -f "$DMG"

# Se crea una imagen vacía con diskutil.  El sistema de ficheros es APFS:
# es lo que admite "diskutil image create blank" (junto con ExFAT y MS-DOS)
# y basta para montar el DMG en cualquier macOS >= 10.14, muy por delante
# del requisito de la aplicacion (macOS 14).  El tamaño se especifica en
# bytes, porque diskutil no acepta sufijos como "400m".
rm -f "$DMG"

TMP_DIR="$(mktemp -d)"
TMP_IMG="$TMP_DIR/Veyon.dmg"

diskutil image create blank \
    --size "$(( IMG_SIZE_MB * 1024 * 1024 ))" \
    --fs APFS \
    --volname "$VOLUME_NAME" \
    "$TMP_IMG"

# 3. Adjuntar la imagen y formatear el volumen ──────────────────────────────
echo "── formatear volumen ──"

DEVICE=""
cleanup() {
    if [ -n "${MOUNT_DIR:-}" ] && [ -d "${MOUNT_DIR}" ]; then
        diskutil unmount force "$MOUNT_DIR" >/dev/null 2>&1 || true
    fi
    if [ -n "${DEVICE:-}" ] && [ -b "$DEVICE" ]; then
        diskutil eject "$DEVICE" >/dev/null 2>&1 || true
    fi
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# Se adjunta la imagen y se monta su volumen.  El adjuntar y el montaje se
# hacen con diskutil, que trabaja sobre el dispositivo de bloque.
#
# La imagen se crea con el esquema de particiones de Apple, por lo que el
# volumen de datos es la segunda particion del dispositivo.
ATTACH_OUTPUT="$(diskutil image attach "$TMP_IMG")"

DEVICE="$(printf '%s' "$ATTACH_OUTPUT" | grep -o '/dev/disk[0-9]*' | head -1)"
PARTITION="$(printf '%s' "$ATTACH_OUTPUT" | grep -o '/dev/disk[0-9]*s[0-9]*' | tail -1)"

if [ -z "$DEVICE" ] || [ -z "$PARTITION" ]; then
    echo "ERROR: no se pudo adjuntar la imagen de disco"
    exit 1
fi

# El punto de montaje del volumen ya viene dado por el adjuntar.
MOUNT_DIR="$(diskutil info "$PARTITION" | grep 'Mount Point:' | sed -e 's/^.*: *//' -e 's#^/$##')"

if [ -z "$MOUNT_DIR" ] || [ ! -d "/$MOUNT_DIR" ]; then
    echo "ERROR: no se pudo montar el volumen formateado"
    exit 1
fi

MOUNT_DIR="/$MOUNT_DIR"

# 4. Copiar el contenido y crear el symlink a /Applications ────────────────
echo "── copiar contenido ──"
ditto "$BUNDLE" "$MOUNT_DIR/Veyon.app"
ln -s /Applications "$MOUNT_DIR/Applications"

# Se copian los metadatos de los ficheros con ditto.
chmod -R a+rX "$MOUNT_DIR/Veyon.app"

# 5. Ocultar la carpeta de recursos y activar el layout del Finder ─────────
echo "── configurar layout ──"
osascript <<APPLESCRIPT >/dev/null 2>&1 || true
tell application "Finder"
    tell disk "$VOLUME_NAME"
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

# 6. Desmontar y expulsar el volumen ───────────────────────────────────────
echo "── desmontar volumen ──"
diskutil unmount "$MOUNT_DIR" >/dev/null
diskutil eject "$DEVICE" >/dev/null

DEVICE=""

# 7. Comprimir la imagen ────────────────────────────────────────────────────
echo "── comprimir imagen ──"
# UDZO solo se consigue con hdiutil: "diskutil image" no tiene subcomando
# de conversion, y "hdiutil convert" no está deprecado (no emite la
# advertencia que si emiten attach/detach/mount).
hdiutil convert "$TMP_IMG" -format UDZO -o "$DMG" -quiet

rm -rf "$STAGING"

if [ ! -f "$DMG" ]; then
    echo "ERROR: no se generó el DMG"
    exit 1
fi

SIZE="$(du -h "$DMG" | cut -f1)"
echo
echo "==> OK: $DMG  ($SIZE)"
echo "    Montar con:  diskutil image attach \"$DMG\"   (o doble clic en el Finder)"
