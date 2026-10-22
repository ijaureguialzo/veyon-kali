#!/usr/bin/env bash
# regen-macos-bundle-patch.sh — Regenera el parche del bundle de macOS.
#
# El parche 0014 contiene el target macos_bundle, el soporte de macOS en
# el CMakeLists.txt principal y los modulos de CMake que lo acompanian.
#
# El workspace macOS (build/veyon-macos) se recrea desde cero en cada
# ejecucion de build-veyon-macos.sh a partir de los parches de patches/.
# Por eso, cualquier cambio hecho en el workspace debe reflejarse en el
# parche ANTES de volver a compilar, o el cambio se pierde.
#
# Uso:
#   1. Editar build/veyon-macos/CMakeLists.txt o build/veyon-macos/cmake/modules/*
#   2. ./scripts/regen-macos-bundle-patch.sh
#   3. ./scripts/build-veyon-macos.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

WORK_DIR="${VEYON_MACOS_WORK_DIR:-$PROJECT_DIR/build/veyon-macos}"
# Checkout ÚNICO de Veyon (mismo que usan el Makefile y build-veyon-macos.sh).
UPSTREAM_DIR="$(bash "$SCRIPT_DIR/veyon-source.sh" path)"
PATCH_FILE="$PROJECT_DIR/patches/0014-cmake-macos-bundle-target.patch"
PATCH_DIR="$(dirname "$PATCH_FILE")"

# Ficheros modificados que forman parte del bundle.
MODIFIED_FILES="CMakeLists.txt"

# Ficheros nuevos que forman parte del bundle.
NEW_FILES="cmake/modules/MacOSIcon.cmake"

if [ ! -d "$WORK_DIR" ]; then
    echo "ERROR: no se encuentra el workspace en $WORK_DIR" >&2
    exit 1
fi

if [ ! -d "$UPSTREAM_DIR" ]; then
    echo "ERROR: no se encuentra el checkout upstream en $UPSTREAM_DIR" >&2
    exit 1
fi

cd "$WORK_DIR"

python3 - "$PATCH_FILE" "$PATCH_DIR" "$UPSTREAM_DIR" "$MODIFIED_FILES" "$NEW_FILES" <<'PY'
import os
import shutil
import subprocess
import sys
import tempfile

patch_file = sys.argv[1]
patch_dir = sys.argv[2]
upstream_dir = sys.argv[3]
modified_files = sys.argv[4].split()
new_files = sys.argv[5].split()


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


def modified_file_diff(base, path):
    proc = subprocess.run(
        ["git", "diff", "--no-index", base, path],
        capture_output=True, text=True)
    out = proc.stdout
    # "git diff --no-index" escribe la ruta absoluta del fichero base en la
    # cabecera del diff, de modo que el parche no seria portable.  Se
    # reescribe a rutas relativas al checkout upstream.
    out = out.replace(f"diff --git a{base} b/{path}",
                      f"diff --git a/{path} b/{path}")
    out = out.replace(f"--- a{base}", f"--- a/{path}")
    out = out.replace(f"+++ b{base}", f"+++ b/{path}")
    return out


def build_base():
    """Crea una copia del upstream con los parches anteriores aplicados.

    El parche 0001 ya modifica el CMakeLists.txt principal.  Si el diff de
    este parche se generase contra el upstream intacto, el hunk que cubre
    0001 apareceria aqui tambien, los dos parches se solaparian y el
    segundo fallaria al aplicarse.  Generando el diff contra la base con
    0001 ya aplicado, ese hunk no aparece.
    """
    base_dir = tempfile.mkdtemp(prefix="veyon-bundle-base-")

    for path in modified_files:
        upstream = os.path.join(upstream_dir, path)
        target = os.path.join(base_dir, path)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        shutil.copy2(upstream, target)

    # Se aplican los parches anteriores a este, en orden.
    previous = sorted(
        name for name in os.listdir(patch_dir)
        if name.endswith(".patch") and name < os.path.basename(patch_file)
    )
    for name in previous:
        path = os.path.join(patch_dir, name)
        check = subprocess.run(
            ["git", "apply", "--check", "--whitespace=nowarn", path],
            cwd=base_dir, capture_output=True, text=True)
        if check.returncode != 0:
            continue
        subprocess.run(
            ["git", "apply", "--whitespace=nowarn", path],
            cwd=base_dir, capture_output=True, text=True, check=True)

    return base_dir


base_dir = build_base()
try:
    parts = [new_file_diff(path) for path in new_files]
    parts += [modified_file_diff(os.path.join(base_dir, path), path)
              for path in modified_files]

    with open(patch_file, "w") as f:
        f.write("".join(parts))
finally:
    shutil.rmtree(base_dir, ignore_errors=True)

print(f"parche regenerado: {patch_file} "
      f"({len(new_files)} ficheros nuevos, {len(modified_files)} modificados)")
for path in new_files:
    print(f"    + {path}")
for path in modified_files:
    print(f"    ~ {path}")
PY
