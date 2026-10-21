#!/usr/bin/env bash
# regen-macos-native-functions-patch.sh — Regenera el parche de funciones nativas macOS.
#
# Igual que regen-macos-plugin-patch.sh, el workspace macOS
# (build/veyon-macos) se recrea desde cero en cada compilación a partir de
# patches/.  Por eso, los cambios hechos en el workspace deben reflejarse en
# el parche 0020 ANTES de volver a compilar.
#
# Este parche contiene exclusivamente los ficheros de las funciones
# nativas de red, preferencias y sesión, que están separados del parche
# 0011 por responsabilidad.
#
# Uso:
#   1. Editar build/veyon-macos/plugins/platform/macos/*
#   2. ./scripts/regen-macos-native-functions-patch.sh
#   3. ./scripts/build-veyon-macos.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

WORK_DIR="${VEYON_MACOS_WORK_DIR:-$PROJECT_DIR/build/veyon-macos}"
PATCH_FILE="$PROJECT_DIR/patches/0020-platform-add-macos-native-functions.patch"
MACOS_DIR="plugins/platform/macos"

# Los ficheros que pertenecen al parche 0020.
FILES="CMakeLists.txt,MacOSNetworkFunctions.cpp,MacOSNetworkFunctions.h,MacOSSessionFunctions.cpp,MacOSUserFunctions.cpp"

if [ ! -d "$WORK_DIR/$MACOS_DIR" ]; then
    echo "ERROR: no se encuentra el workspace del plugin macOS en $WORK_DIR" >&2
    echo "       ejecuta primero: $SCRIPT_DIR/build-veyon-macos.sh --no-build" >&2
    exit 1
fi

cd "$WORK_DIR"

python3 - "$MACOS_DIR" "$PATCH_FILE" "$FILES" <<'PY'
import os
import subprocess
import sys

macos_dir = sys.argv[1]
patch_file = sys.argv[2]
files = [f for f in sys.argv[3].split(",") if f]

parts = []
for name in files:
    path = f"{macos_dir}/{name}"
    if not os.path.exists(path):
        print(f"ERROR: no se encuentra {path}", file=sys.stderr)
        sys.exit(1)
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
