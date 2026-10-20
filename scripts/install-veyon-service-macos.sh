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

    # Detener y eliminar los launch agents de los usuarios conocidos.
    for plist in /Users/*/Library/LaunchAgents/io.veyon.veyon-server.plist; do
        [ -e "$plist" ] || continue
        user="$(basename "$(dirname "$(dirname "$plist")")")"
        uid="$(id -u "$user" 2>/dev/null || echo "")"
        if [ -n "$uid" ]; then
            launchctl bootout "gui/$uid/io.veyon.veyon-server" 2>/dev/null || true
        fi
        rm -f "$plist"
        echo "    launch agent de $user eliminado"
    done

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
if [ ! -d "/Applications/Veyon.app" ] || [ "$BUNDLE" != "/Applications/Veyon.app" ]; then
    echo "── instalar el bundle en /Applications ──"
    rm -rf "/Applications/Veyon.app"
    cp -R "$BUNDLE" "/Applications/Veyon.app"
    echo "    instalado en /Applications/Veyon.app"
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
		<string>$SERVICE_PATH</string>
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
