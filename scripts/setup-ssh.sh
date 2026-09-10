#!/usr/bin/env bash
#
# Copia la clave pública SSH a todos los hosts del inventario Ansible.
#
# Lee el fichero hosts.ini, extrae la dirección de cada host (ignorando
# cabeceras de grupo [..], comentarios y líneas en blanco) y ejecuta
# ssh-copy-id contra cada uno de forma automatizada.
#
# Uso:
#   scripts/setup-ssh.sh [inventario]
#
# Variables de entorno:
#   SSH_USER      Usuario remoto (por defecto: ciber)
#   SSH_KEY       Clave pública a copiar (por defecto: ~/.ssh/id_rsa.pub)
#   SSHPASS       Contraseña remota. Si se define (y hay sshpass) la copia
#                 es totalmente automática y no pide contraseña. Ejemplo:
#                   SSHPASS='mi_password' make setup-ssh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

INVENTORY_FILE="${1:-$PROJECT_DIR/inventory/hosts.ini}"
USER_NAME="${SSH_USER:-ciber}"
KEY_FILE="${SSH_KEY:-$HOME/.ssh/id_rsa.pub}"

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5"

# Colores solo si la salida es un terminal
if [[ -t 1 ]]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
    BLUE=$'\033[0;34m'; NC=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; BLUE=""; NC=""
fi

die() {
    echo "${RED}error:${NC} $*" >&2
    exit 1
}

# --- Comprobaciones previas ---------------------------------------------------

if [[ ! -f "$INVENTORY_FILE" ]]; then
    example="${INVENTORY_FILE%.ini}.ini.example"
    if [[ -f "$example" ]]; then
        die "no existe '$INVENTORY_FILE'. Cópialo desde el ejemplo:
  cp '$example' '$INVENTORY_FILE'
  y edita las direcciones."
    fi
    die "fichero de inventario no encontrado: $INVENTORY_FILE"
fi

command -v ssh-copy-id >/dev/null 2>&1 \
    || die "ssh-copy-id no está instalado (paquete openssh-client)."

[[ -f "$KEY_FILE" ]] || die "clave pública no encontrada: $KEY_FILE"

# sshpass permite copiar sin pedir la contraseña (automático).
USE_SSHPASS=0
if [[ -n "${SSHPASS:-}" ]]; then
    if command -v sshpass >/dev/null 2>&1; then
        USE_SSHPASS=1
    else
        echo "${YELLOW}aviso:${NC} SSHPASS está definido pero sshpass no está instalado;"
        echo "      se pedirá la contraseña de forma interactiva."
        echo
    fi
else
    echo "Nota: define SSHPASS para una copia totalmente automática, p. ej.:"
    echo "  SSHPASS='mi_password' make setup-ssh"
fi

# --- Lectura de hosts ---------------------------------------------------------
# Muestra "host [usuario]" por línea. Ignora grupos [..], comentarios y
# líneas vacías. Admite variable user= o ansible_user= por host.
read_hosts() {
    awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*\[/ { next }
        /^[[:space:]]*$/ { next }
        {
            host = $1
            user = ""
            for (i = 2; i <= NF; i++)
                if ($i ~ /^(ansible_)?user=/) {
                    sub(/^(ansible_)?user=/, "", $i)
                    user = $i
                }
            if (host != "") print host, user
        }
    ' "$INVENTORY_FILE"
}

hosts="$(read_hosts)"
if [[ -z "$hosts" ]]; then
    die "no se han encontrado hosts en '$INVENTORY_FILE'."
fi

echo "Inventario : ${BLUE}$INVENTORY_FILE${NC}"
echo "Usuario    : ${BLUE}$USER_NAME${NC}"
echo "Clave      : ${BLUE}$KEY_FILE${NC}"
echo "Hosts      : $(echo "$hosts" | wc -l | tr -d ' ')"
if [[ "$USE_SSHPASS" -eq 1 ]]; then
    echo "Modo       : ${GREEN}automático (sshpass)${NC}"
fi
echo

# --- Copia a cada host --------------------------------------------------------

ok=0; fail=0; skipped=0

# El bucle lee por el fd 3 (no por stdin) para que las llamadas ssh de
# dentro no consuman la lista de hosts y salten iteraciones.
while read -r host user <&3; do
    [[ -z "${host:-}" ]] && continue
    target="${user:-$USER_NAME}@${host}"

    echo -n "${BLUE}->${NC} $target ... "

    # Si la clave ya funciona, no hace falta copiarla de nuevo.
    if ssh $SSH_OPTS -o BatchMode=yes "$target" true </dev/null 2>/dev/null; then
        echo "ya configurada"
        skipped=$((skipped + 1))
        continue
    fi

    if [[ "$USE_SSHPASS" -eq 1 ]]; then
        # sshpass toma la contraseña de SSHPASS; sin prompt, se silencia.
        if sshpass -e ssh-copy-id $SSH_OPTS -i "$KEY_FILE" "$target" </dev/null >/dev/null 2>&1; then
            echo "${GREEN}clave copiada${NC}"
            ok=$((ok + 1))
        else
            echo "${RED}fallo (contraseña incorrecta o sin acceso)${NC}"
            fail=$((fail + 1))
        fi
    else
        # Interactivo: deja ver el prompt de contraseña y el progreso.
        if ssh-copy-id $SSH_OPTS -i "$KEY_FILE" "$target"; then
            echo "${GREEN}clave copiada${NC}"
            ok=$((ok + 1))
        else
            echo "${RED}fallo o cancelado${NC}"
            fail=$((fail + 1))
        fi
    fi
done 3<<< "$hosts"

# --- Resumen ------------------------------------------------------------------

echo
echo "Resumen: ${GREEN}$ok configurados${NC}, ${BLUE}$skipped ya configurados${NC}, ${RED}$fail fallos${NC}"

[[ "$fail" -eq 0 ]] || exit 1
