#!/usr/bin/env bash
# regen-macos-plugin-patch.sh — Regenera el parche del plugin de plataforma macOS.
#
# El workspace macOS (build/veyon-macos) se recrea desde cero en cada
# ejecución de build-veyon-macos.sh a partir de los parches de patches/.
# Por eso, cualquier cambio hecho en el workspace debe reflejarse en el
# parche 0011 ANTES de volver a compilar, o el cambio se pierde.
#
# Este script regenera el parche 0011 a partir del estado actual del
# workspace, que debe contener ya los cambios deseados.
#
# Uso:
#   1. Editar build/veyon-macos/plugins/platform/macos/*
#   2. ./scripts/regen-macos-plugin-patch.sh
#   3. ./scripts/build-veyon-macos.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

WORK_DIR="${VEYON_MACOS_WORK_DIR:-$PROJECT_DIR/build/veyon-macos}"
PATCH_FILE="$PROJECT_DIR/patches/0011-platform-add-macos-platform-plugin.patch"
MACOS_DIR="plugins/platform/macos"

# Los ficheros que viven en otro parche no deben entrar aquí, porque git
# aplicaría los dos y el segundo fallaría sobre un fichero ya creado.
# Por defecto se excluyen los cinco ficheros del parche 0020 (funciones
# nativas).  Se puede cambiar con EXCLUDE_FILES al invocar el script.
EXCLUDE_FILES="${EXCLUDE_FILES:-CMakeLists.txt,MacOSNetworkFunctions.cpp,MacOSNetworkFunctions.h,MacOSSessionFunctions.cpp,MacOSUserFunctions.cpp}"

if [ ! -d "$WORK_DIR/$MACOS_DIR" ]; then
    echo "ERROR: no se encuentra el workspace del plugin macOS en $WORK_DIR" >&2
    echo "       ejecuta primero: $SCRIPT_DIR/build-veyon-macos.sh --no-build" >&2
    exit 1
fi

cd "$WORK_DIR"

# El parche es un "new file" por cada fichero del plugin, así que se genera
# con "git diff --no-index" contra /dev/null.  Es lo que produce un parche
# aplicable sobre el checkout upstream.
python3 - "$MACOS_DIR" "$PATCH_FILE" "${EXCLUDE_FILES:-}" <<'PY'
import os
import subprocess
import sys

macos_dir = sys.argv[1]
patch_file = sys.argv[2]

# Los ficheros que viven en otro parche no deben entrar aquí, porque git
# aplicaría los dos y el segundo fallaría sobre un fichero ya creado.
exclude = set(sys.argv[3].split(",")) if len(sys.argv) > 3 and sys.argv[3] else set()

files = sorted(
    f for f in os.listdir(macos_dir)
    if f.endswith((".cpp", ".h", ".txt")) and f not in exclude
)

parts = []
for name in files:
    path = f"{macos_dir}/{name}"
    proc = subprocess.run(
        ["git", "diff", "--no-index", "--binary", "/dev/null", path],
        capture_output=True, text=True)
    out = proc.stdout
    # Normalizar las rutas de la cabecera del diff.
    out = out.replace(
        f"diff --git b/{path} b/{path}",
        f"diff --git a/{path} b/{path}")
    out = out.replace(f"+++ b/{os.path.abspath(path)}", f"+++ b/{path}")
    out = out.replace(f"--- a/{os.path.abspath(path)}", "--- /dev/null")
    parts.append(out)

with open(patch_file, "w") as f:
    f.write("".join(parts))

print(f"parche regenerado: {patch_file} ({len(files)} ficheros)")
for name in files:
    print(f"    {name}")
if exclude:
    print(f"excluidos (viven en otro parche): {', '.join(sorted(exclude))}")
PY
