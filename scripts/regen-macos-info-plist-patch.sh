#!/usr/bin/env bash
# regen-macos-info-plist-patch.sh — Regenera el parche del Info.plist de macOS.
#
# El parche 0016 añade el módulo cmake/modules/MacOSInfoPlist.cmake, que
# genera el Info.plist del bundle: identidad, icono, permisos y los idiomas
# que declara la aplicación en CFBundleLocalizations.
#
# El workspace macOS (build/veyon-macos) se recrea desde cero en cada
# ejecucion de build-veyon-macos.sh a partir de los parches de patches/.
# Por eso, cualquier cambio hecho en el workspace debe reflejarse en el
# parche ANTES de volver a compilar, o el cambio se pierde.
#
# Uso:
#   1. Editar build/veyon-macos/cmake/modules/MacOSInfoPlist.cmake
#   2. ./scripts/regen-macos-info-plist-patch.sh
#   3. ./scripts/build-veyon-macos.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

WORK_DIR="${VEYON_MACOS_WORK_DIR:-$PROJECT_DIR/build/veyon-macos}"
PATCH_FILE="$PROJECT_DIR/patches/0016-cmake-macos-info-plist.patch"

# Ficheros nuevos que forman parte del parche.
NEW_FILES="cmake/modules/MacOSInfoPlist.cmake"

if [ ! -d "$WORK_DIR" ]; then
    echo "ERROR: no se encuentra el workspace en $WORK_DIR" >&2
    exit 1
fi

cd "$WORK_DIR"

python3 - "$PATCH_FILE" "$NEW_FILES" <<'PY'
import os
import subprocess
import sys

patch_file = sys.argv[1]
new_files = sys.argv[2].split()


def new_file_diff(path):
    proc = subprocess.run(
        ["git", "diff", "--no-index", "--binary", "/dev/null", path],
        capture_output=True, text=True)
    out = proc.stdout
    out = out.replace(
        f"diff --git b/{path} b/{path}",
        f"diff --git a/{path} b/{path}")
    out = out.replace(f"+++ b/{os.path.abspath(path)}", f"+++ b/{path}")
    out = out.replace(f"--- a/{os.path.abspath(path)}", "--- /dev/null")
    return out


parts = [new_file_diff(path) for path in new_files]

with open(patch_file, "w") as f:
    f.write("".join(parts))

print(f"parche regenerado: {patch_file} "
      f"({len(new_files)} ficheros nuevos)")
for path in new_files:
    print(f"    + {path}")
PY
