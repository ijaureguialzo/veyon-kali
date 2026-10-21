#!/usr/bin/env bash
# install-veyon-service-macos.sh — Instala y activa el servicio launchd de Veyon.
#
# Uso:
#     sudo ./scripts/install-veyon-service-macos.sh
#     sudo ./scripts/install-veyon-service-macos.sh --uninstall
#
# El servicio de Veyon en macOS tiene dos niveles, igual que en Linux:
#
#   - io.veyon.veyon-service es un LaunchDaemon del sistema.  Se ejecuta
#     como root y vigila la sesión de la consola.
#   - io.veyon.veyon-server es un LaunchAgent por usuario.  El servicio lo
#     escribe en ~/Library/LaunchAgents del usuario que está logged in en la
#     consola y lo carga en el dominio "gui/<uid>", de modo que el servidor
#     Veyon corre dentro de la sesión Aqua y tiene acceso al window server.
#
# El segundo nivel es imprescindible: un LaunchDaemon no puede capturar la
# pantalla ni inyectar teclado, porque no pertenece a ninguna sesión gráfica.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

BUNDLE="${VEYON_MACOS_BUNDLE:-$PROJECT_DIR/build/veyon-macos/build/Veyon.app}"
INSTALL_DIR="/Applications"
INSTALLED_BUNDLE="$INSTALL_DIR/Veyon.app"
DAEMON_DIR="/Library/LaunchDaemons"
DAEMON_PLIST="$DAEMON_DIR/io.veyon.veyon-service.plist"
DAEMON_LABEL="io.veyon.veyon-service"

MODE="install"
if [ "${1:-}" = "--uninstall" ]; then
    MODE="uninstall"
elif [ $# -gt 0 ]; then
    echo "Uso: $0 [--uninstall]" >&2
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: este script necesita privilegios de root (usa sudo)" >&2
    exit 1
fi

echo "── servicio launchd de Veyon (modo: $MODE) ──"

if [ "$MODE" = "uninstall" ]; then
    # Detener y descargar el daemon.
    launchctl bootout "system/$DAEMON_LABEL" 2>/dev/null || true
    rm -f "$DAEMON_PLIST"
    echo "    daemon eliminado"

    # Detener y eliminar los launch agents de todos los usuarios.  La lista
    # de usuarios se obtiene de Open Directory, porque el home de una cuenta
    # no tiene por qué estar en /Users.
    while read -r user; do
        [ -n "$user" ] || continue
        home="$(dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
        [ -n "$home" ] || continue
        plist="$home/Library/LaunchAgents/io.veyon.veyon-server.plist"
        [ -e "$plist" ] || continue
        uid="$(id -u "$user" 2>/dev/null || echo "")"
        if [ -n "$uid" ]; then
            launchctl bootout "gui/$uid/io.veyon.veyon-server" 2>/dev/null || true
        fi
        rm -f "$plist"
        echo "    launch agent de $user eliminado"
    done < <(dscl . -list /Users 2>/dev/null | awk '!/^_/ && NF')

    echo "==> OK: servicio eliminado"
    exit 0
fi

# 1. Comprobar el bundle ────────────────────────────────────────────────────
if [ ! -d "$BUNDLE" ]; then
    echo "ERROR: no existe el bundle $BUNDLE" >&2
    echo "       compílalo con: ./scripts/build-veyon-macos.sh" >&2
    exit 1
fi

SERVER_PATH="$BUNDLE/Contents/MacOS/veyon-server"
SERVICE_PATH="$BUNDLE/Contents/MacOS/veyon-service"

if [ ! -x "$SERVER_PATH" ] || [ ! -x "$SERVICE_PATH" ]; then
    echo "ERROR: el bundle no contiene veyon-server ni veyon-service" >&2
    exit 1
fi

# 2. Instalar el bundle en /Applications ───────────────────────────────────
if [ ! -d "$INSTALLED_BUNDLE" ] || [ "$BUNDLE" != "$INSTALLED_BUNDLE" ]; then
    echo "── instalar el bundle en $INSTALL_DIR ──"
    rm -rf "$INSTALLED_BUNDLE"
    cp -R "$BUNDLE" "$INSTALLED_BUNDLE"
    echo "    instalado en $INSTALLED_BUNDLE"
fi

# Las rutas del LaunchDaemon tienen que apuntar a la instalación final, no
# al directorio de compilación, que se puede borrar en cualquier momento.
INSTALLED_SERVICE_PATH="$INSTALLED_BUNDLE/Contents/MacOS/veyon-service"

if [ ! -x "$INSTALLED_SERVICE_PATH" ]; then
    echo "ERROR: no se encuentra $INSTALLED_SERVICE_PATH tras la instalación" >&2
    exit 1
fi

# 3. Escribir el LaunchDaemon ──────────────────────────────────────────────
echo "── instalar el LaunchDaemon ──"
mkdir -p "$DAEMON_DIR"

cat > "$DAEMON_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$DAEMON_LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$INSTALLED_SERVICE_PATH</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ProcessType</key>
	<string>Background</string>
	<key>SessionCreate</key>
	<true/>
	<key>ServiceDescription</key>
	<string>Veyon Service</string>
</dict>
</plist>
EOF

chmod 644 "$DAEMON_PLIST"

# 4. Validar y cargar el daemon ────────────────────────────────────────────
if ! plutil -lint "$DAEMON_PLIST" >/dev/null 2>&1; then
    echo "ERROR: el LaunchDaemon generado no es válido" >&2
    exit 1
fi

launchctl bootout "system/$DAEMON_LABEL" 2>/dev/null || true
launchctl bootstrap "system" "$DAEMON_PLIST"

echo "── estado ──"
launchctl print "system/$DAEMON_LABEL" 2>/dev/null | grep -E "^\s*state = |^\s*pid = " | head -3 || true

echo "==> OK: servicio launchd instalado y cargado"
echo "    Los permisos TCC (Screen Recording y Accessibility) hay que concederlos"
echo "    manualmente en Ajustes del Sistema > Privacidad y seguridad."
