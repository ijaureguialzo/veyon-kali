#!/usr/bin/env bash
# regen-macos-master-configurator-patch.sh — Regenera el parche del boton de
# configuracion del Veyon Master.
#
# El boton abre el Veyon Configurator, que vive en el mismo bundle que el
# master.  Como el master y el configurador son ejecutables separados, y el
# configurador puede necesitar privilegios de administrador, se lanza como
# proceso independiente.
#
# Uso:
#   1. Editar build/veyon-macos/master/src/MainWindow.*
#   2. ./scripts/regen-macos-master-configurator-patch.sh
#   3. ./scripts/build-veyon-macos.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

WORK_DIR="${VEYON_MACOS_WORK_DIR:-$PROJECT_DIR/build/veyon-macos}"
UPSTREAM_DIR="${VEYON_UPSTREAM_DIR:-$PROJECT_DIR/build/veyon}"
PATCH_FILE="$PROJECT_DIR/patches/0022-master-add-configurator-button.patch"

MODIFIED_FILES="master/src/MainWindow.cpp master/src/MainWindow.h master/src/MainWindow.ui"

if [ ! -d "$WORK_DIR" ]; then
    echo "ERROR: no se encuentra el workspace en $WORK_DIR" >&2
    exit 1
fi

if [ ! -d "$UPSTREAM_DIR" ]; then
    echo "ERROR: no se encuentra el checkout upstream en $UPSTREAM_DIR" >&2
    exit 1
fi

cd "$WORK_DIR"

python3 - "$PATCH_FILE" "$UPSTREAM_DIR" "$MODIFIED_FILES" <<'PY'
import os
import subprocess
import sys

patch_file = sys.argv[1]
upstream_dir = sys.argv[2]
modified_files = sys.argv[3].split()


def modified_file_diff(upstream_dir, path):
    upstream = os.path.join(upstream_dir, path)
    if not os.path.exists(upstream):
        sys.exit(f"ERROR: no existe el fichero upstream {upstream}")

    proc = subprocess.run(
        ["git", "diff", "--no-index", upstream, path],
        capture_output=True, text=True)
    out = proc.stdout
    # "git diff --no-index" escribe la ruta absoluta del fichero upstream
    # en la cabecera del diff, de modo que el parche no seria portable.  Se
    # reescribe a rutas relativas al checkout upstream.
    out = out.replace(f"diff --git a{upstream} b/{path}",
                      f"diff --git a/{path} b/{path}")
    out = out.replace(f"--- a{upstream}", f"--- a/{path}")
    out = out.replace(f"+++ b{upstream}", f"+++ b/{path}")
    return out


parts = [modified_file_diff(upstream_dir, path) for path in modified_files]

with open(patch_file, "w") as f:
    f.write("".join(parts))

print(f"parche regenerado: {patch_file} ({len(modified_files)} modificados)")
for path in modified_files:
    print(f"    ~ {path}")
PY
