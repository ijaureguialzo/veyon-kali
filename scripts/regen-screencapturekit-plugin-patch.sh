#!/usr/bin/env bash
# regen-screencapturekit-plugin-patch.sh — Regenera el parche del plugin VNC de ScreenCaptureKit.
#
# Igual que regen-macos-plugin-patch.sh, pero para el plugin de captura
# nativa de macOS, que vive en plugins/vncserver/screencapturekit/.
#
# El workspace macOS (build/veyon-macos) se recrea desde cero en cada
# ejecución de build-veyon-macos.sh a partir de los parches de patches/.
# Por eso, cualquier cambio hecho en el workspace debe reflejarse en el
# parche ANTES de volver a compilar, o el cambio se pierde.
#
# Uso:
#   1. Editar build/veyon-macos/plugins/vncserver/screencapturekit/*
#   2. ./scripts/regen-screencapturekit-plugin-patch.sh
#   3. ./scripts/build-veyon-macos.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

WORK_DIR="${VEYON_MACOS_WORK_DIR:-$PROJECT_DIR/build/veyon-macos}"
UPSTREAM_DIR="${VEYON_UPSTREAM_DIR:-$PROJECT_DIR/build/veyon}"
PATCH_FILE="$PROJECT_DIR/patches/0018-vncserver-add-screencapturekit-plugin.patch"
PLUGIN_DIR="plugins/vncserver/screencapturekit"

# Fichers existentes que se modifican junto con el plugin nuevo.
MODIFIED_FILES="plugins/vncserver/CMakeLists.txt plugins/vncserver/headless/HeadlessVncServer.h"

if [ ! -d "$WORK_DIR/$PLUGIN_DIR" ]; then
    echo "ERROR: no se encuentra el workspace del plugin en $WORK_DIR" >&2
    echo "       ejecuta primero: $SCRIPT_DIR/build-veyon-macos.sh --no-build" >&2
    exit 1
fi

if [ ! -d "$UPSTREAM_DIR" ]; then
    echo "ERROR: no se encuentra el checkout upstream en $UPSTREAM_DIR" >&2
    exit 1
fi

cd "$WORK_DIR"

# El parche es un "new file" por cada fichero del plugin, así que se genera
# con "git diff --no-index" contra /dev/null.  Es lo que produce un parche
# aplicable sobre el checkout upstream.
python3 - "$PLUGIN_DIR" "$PATCH_FILE" "$UPSTREAM_DIR" "$MODIFIED_FILES" <<'PY'
import os
import subprocess
import sys

plugin_dir = sys.argv[1]
patch_file = sys.argv[2]
upstream_dir = sys.argv[3]
modified_files = sys.argv[4].split()

files = sorted(
    f for f in os.listdir(plugin_dir)
    if f.endswith((".cpp", ".h", ".mm", ".txt", ".ui"))
)

parts = []
for name in files:
    path = f"{plugin_dir}/{name}"
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

# Los ficheros ya existentes que se modifican se diffen contra el checkout
# upstream, de modo que el parche sea aplicable sobre él.
for path in modified_files:
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
    parts.append(out)

with open(patch_file, "w") as f:
    f.write("".join(parts))

print(f"parche regenerado: {patch_file} ({len(files)} ficheros nuevos, "
      f"{len(modified_files)} modificados)")
for name in files:
    print(f"    + {name}")
for name in modified_files:
    print(f"    ~ {name}")
PY
