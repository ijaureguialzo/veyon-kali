#!/usr/bin/env bash
# install-veyon-macos.sh — Instala el bundle de Veyon en /Applications.
#
# Uso:
#     ./scripts/install-veyon-macos.sh
#     ./scripts/install-veyon-macos.sh --uninstall
#
# El script instala el bundle canonico en /Applications y deja el equipo en
# un estado en el que la aplicacion se abre sin el aviso de Gatekeeper
# ("Apple no ha podido verificar...").
#
# Por que hace falta
# ----------------
#
# El bundle se firma ad hoc, porque no hay un certificado de Developer ID.
# Una firma ad hoc no pasa la validacion de Gatekeeper: el sistema no puede
# comprobar que el binario proceda de un desarrollador identificado.  Si el
# bundle ademas lleva el atributo com.apple.quarantine, Gatekeeper mata el
# proceso antes de que arranque:
#
#     $ /Applications/Veyon.app/Contents/MacOS/veyon-cli about
#     Killed: 9
#
# El aviso que ve el usuario viene de ahi, no de la firma en si.  La
# solucion para un bundle construido en local es quitar el atributo de
# quarantine, que es lo que hdiutil y los navegadores ponen al descargar
# un fichero.
#
# Este script hace tres cosas:
#
#   1. Copia el bundle en /Applications.
#   2. Quita el atributo com.apple.quarantine de forma recursiva.
#   3. Registra la aplicacion en la base de datos de reglas de Gatekeeper,
#      si el sistema lo permite sin privilegios de administrador.
#
# Para una distribucion publica haria falta un certificado de Developer ID
# y la notarizacion, que es un camino distinto y no se cubre aqui.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

BUNDLE="${VEYON_MACOS_BUNDLE:-$PROJECT_DIR/build/veyon-macos/build/Veyon.app}"
INSTALL_DIR="/Applications"
INSTALLED_BUNDLE="$INSTALL_DIR/Veyon.app"
BUNDLE_ID="io.veyon.veyon"

MODE="install"
if [ "${1:-}" = "--uninstall" ]; then
    MODE="uninstall"
elif [ $# -gt 0 ]; then
    echo "Uso: $0 [--uninstall]" >&2
    exit 1
fi

echo "── instalacion local de Veyon (modo: $MODE) ──"

if [ "$MODE" = "uninstall" ]; then
    if [ -d "$INSTALLED_BUNDLE" ]; then
        rm -rf "$INSTALLED_BUNDLE"
        echo "    $INSTALLED_BUNDLE eliminado"
    else
        echo "    no habia nada instalado en $INSTALLED_BUNDLE"
    fi

    # La regla de Gatekeeper se retira cuando el bundle ya no existe.
    spctl --remove "$BUNDLE_ID" 2>/dev/null && echo "    regla de Gatekeeper retirada" || true

    echo "==> OK: aplicacion eliminada"
    exit 0
fi

# 1. Comprobar el bundle ────────────────────────────────────────────────────
if [ ! -d "$BUNDLE" ]; then
    echo "ERROR: no existe el bundle $BUNDLE" >&2
    echo "       compílalo con: ./scripts/build-veyon-macos.sh" >&2
    exit 1
fi

# 2. Copiar el bundle ───────────────────────────────────────────────────────
echo "── copiar el bundle ──"
if [ "$BUNDLE" = "$INSTALLED_BUNDLE" ]; then
    echo "    ya esta en $INSTALL_DIR"
else
    rm -rf "$INSTALLED_BUNDLE"
    cp -R "$BUNDLE" "$INSTALLED_BUNDLE"
    echo "    instalado en $INSTALLED_BUNDLE"
fi

# 3. Quitar el atributo de quarantine ───────────────────────────────────────
# Es el paso que evita el aviso de Gatekeeper.  Se hace de forma
# recursiva porque el atributo puede estar en cualquier fichero del
# bundle, y basta con que este en el ejecutable principal para que el
# sistema mate el proceso.
echo "── quitar el atributo de quarantine ──"
if xattr -dr com.apple.quarantine "$INSTALLED_BUNDLE" 2>/dev/null; then
    echo "    ok"
elif xattr -r "$INSTALLED_BUNDLE" 2>/dev/null | grep -q "com.apple.quarantine"; then
    echo "    ERROR: no se ha podido quitar el atributo de quarantine" >&2
    echo "           ejecuta:  xattr -dr com.apple.quarantine \"$INSTALLED_BUNDLE\"" >&2
    exit 1
else
    echo "    ok (no habia atributo de quarantine)"
fi

# 4. Registrar la aplicacion en las reglas de Gatekeeper ──────────────────
# Esta parte necesita privilegios de administrador, porque escribe en
# /var/db/spctl.  Si no estan disponibles, no es un problema: el bundle
# ya se puede abrir sin el aviso gracias al paso anterior.
echo "── registrar la aplicacion en Gatekeeper ──"
if spctl --add --label "$BUNDLE_ID" "$INSTALLED_BUNDLE" 2>/dev/null; then
    echo "    regla registrada"
else
    echo "    omitido: la base de datos de reglas requiere privilegios de administrador"
    echo "    no hace falta: sin el atributo de quarantine la aplicacion se abre"
fi

# 5. Comprobar que la aplicacion arranca ───────────────────────────────────
echo "── comprobar la instalacion ──"
if out="$("$INSTALLED_BUNDLE/Contents/MacOS/veyon-cli" about 2>&1)"; then
    echo "$out" | head -3 | sed 's/^/    /'
else
    echo "    ERROR: la aplicacion no arranca" >&2
    echo "$out" | head -5 | sed 's/^/    /' >&2
    exit 1
fi

echo
echo "==> OK: Veyon instalado en $INSTALLED_BUNDLE"
echo "    Para el servicio launchd:  sudo ./scripts/install-veyon-service-macos.sh"
