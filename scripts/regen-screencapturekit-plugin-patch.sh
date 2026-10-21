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
SMOKE_PATCH_FILE="$PROJECT_DIR/patches/0021-vncserver-add-screencapturekit-smoke-test.patch"
PLUGIN_DIR="plugins/vncserver/screencapturekit"

# Fichers existentes que se modifican junto con el plugin nuevo.
MODIFIED_FILES="plugins/vncserver/CMakeLists.txt plugins/vncserver/headless/HeadlessVncServer.h"

# El smoke test es una prueba aislada del capturador.  No forma parte del
# plugin ni se instala, asi que va en un parche aparte: el parche del
# plugin se puede aplicar sin el, y el parche del smoke test se puede
# revisar de forma independiente.
SMOKE_FILES="sck_smoke_test.cpp"

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
python3 - "$PLUGIN_DIR" "$PATCH_FILE" "$SMOKE_PATCH_FILE" "$UPSTREAM_DIR" \
           "$MODIFIED_FILES" "$SMOKE_FILES" <<'PY'
import os
import subprocess
import sys

plugin_dir = sys.argv[1]
patch_file = sys.argv[2]
smoke_patch_file = sys.argv[3]
upstream_dir = sys.argv[4]
modified_files = sys.argv[5].split()
smoke_files = sys.argv[6].split()

all_files = sorted(
    f for f in os.listdir(plugin_dir)
    if f.endswith((".cpp", ".h", ".mm", ".txt", ".ui"))
)

# Los ficheros del smoke test van a su propio parche.
files = [f for f in all_files if f not in smoke_files]


def new_file_diff(path):
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
    return out


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


def new_file_diff_from_content(path, content):
    """Genera el diff de un fichero nuevo a partir de su contenido.

    El diff se genera contra un directorio temporal que reproduce la
    ruta final del fichero, de modo que las cabeceras del parche
    contengan la ruta relativa correcta y no una ruta absoluta del
    directorio temporal, que no seria portable.
    """
    import shutil
    import tempfile

    tmp_dir = tempfile.mkdtemp(prefix="veyon-sck-patch-")
    try:
        target = os.path.join(tmp_dir, path)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "w") as f:
            f.write(content)

        proc = subprocess.run(
            ["git", "diff", "--no-index", "--binary", "/dev/null", target],
            capture_output=True, text=True)
        out = proc.stdout
        out = out.replace(
            f"diff --git b/{target} b/{target}",
            f"diff --git a/{path} b/{path}")
        out = out.replace(f"+++ b/{target}", f"+++ b/{path}")
        out = out.replace(f"--- a/{target}", "--- /dev/null")
        return out
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


parts = [new_file_diff(f"{plugin_dir}/{name}") for name in files]

# Los ficheros ya existentes que se modifican se diffen contra el checkout
# upstream, de modo que el parche sea aplicable sobre él.
for path in modified_files:
    parts.append(modified_file_diff(upstream_dir, path))

# El CMakeLists.txt del plugin se genera sin el bloque del smoke test, que
# va en su propio parche.  Asi 0018 no depende de la prueba.
plugin_cmake = f"{plugin_dir}/CMakeLists.txt"
current = open(plugin_cmake).read()
marker = "\n# Standalone test of the capturer."
if marker in current:
    without_content = current[:current.index(marker)]
    parts = [p for p in parts
             if not p.startswith(f"diff --git a/{plugin_cmake} ")]
    parts.append(new_file_diff_from_content(plugin_cmake, without_content))

with open(patch_file, "w") as f:
    f.write("".join(parts))

print(f"parche regenerado: {patch_file} ({len(files)} ficheros nuevos, "
      f"{len(modified_files)} modificados)")
for name in files:
    print(f"    + {name}")
for name in modified_files:
    print(f"    ~ {name}")

# El smoke test genera un parche propio con su fichero y un parche de
# modificacion del CMakeLists.txt del plugin, que en 0018 se crea sin el
# bloque del smoke test.  Asi el parche del plugin se puede aplicar y
# compilar sin la prueba, y el smoke test queda aislado en 0021.
smoke_parts = [new_file_diff(f"{plugin_dir}/{name}") for name in smoke_files]

# El CMakeLists.txt del plugin se genera sin el bloque del smoke test en
# 0018.  Aqui se produce el diff que lo anade, contra la version de 0018.
plugin_cmake = f"{plugin_dir}/CMakeLists.txt"
without_smoke = os.path.join(upstream_dir, "plugins", "vncserver",
                             "screencapturekit", "CMakeLists.txt")
with_smoke = os.path.join(os.getcwd(), plugin_cmake)

# La version sin smoke test se reconstruye quitando el bloque final del
# fichero actual.
current = open(with_smoke).read()
marker = "\n# Standalone test of the capturer."
if marker in current:
    without_content = current[:current.index(marker)]
else:
    without_content = current

os.makedirs(os.path.dirname(without_smoke), exist_ok=True)
with open(without_smoke, "w") as f:
    f.write(without_content)

smoke_parts.append(modified_file_diff(
    upstream_dir, plugin_cmake))

with open(smoke_patch_file, "w") as f:
    f.write("".join(smoke_parts))

print(f"parche regenerado: {smoke_patch_file} ({len(smoke_files)} ficheros nuevos, "
      f"1 modificado)")
for name in smoke_files:
    print(f"    + {name}")
print(f"    ~ {plugin_dir}/CMakeLists.txt")
PY
