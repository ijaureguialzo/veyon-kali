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

if [ ! -d "$WORK_DIR/$MACOS_DIR" ]; then
    echo "ERROR: no se encuentra el workspace del plugin macOS en $WORK_DIR" >&2
    echo "       ejecuta primero: $SCRIPT_DIR/build-veyon-macos.sh --no-build" >&2
    exit 1
fi

cd "$WORK_DIR"

# El parche es un "new file" por cada fichero del plugin, así que se genera
# con "git diff --no-index" contra /dev/null.  Es lo que produce un parche
# aplicable sobre el checkout upstream.
python3 - "$MACOS_DIR" "$PATCH_FILE" <<'PY'
import os
import subprocess
import sys

macos_dir = sys.argv[1]
patch_file = sys.argv[2]

files = sorted(
    f for f in os.listdir(macos_dir)
    if f.endswith((".cpp", ".h", ".txt"))
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
PY
