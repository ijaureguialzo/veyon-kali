#!/bin/bash
# build-veyon-macos.sh — Compila Veyon para macOS en un host macOS (arm64/x86_64).
#
# A diferencia de build-veyon.sh (que corre dentro de un contenedor Kali),
# este script compila directamente sobre el host.  Para no tocar el checkout
# upstream se trabaja sobre una copia editable en $WORK_DIR a la que se le
# aplican los parches de patches/.
#
# El checkout upstream es el ÚNICO que usa todo el proyecto (build/veyon por
# defecto): se resuelve con scripts/veyon-source.sh y se actualiza antes de
# compilar, de modo que la copia de trabajo parte siempre del mismo código.
#
# Uso:
#     ./scripts/build-veyon-macos.sh              # build completo + bundle + DMG
#     ./scripts/build-veyon-macos.sh --no-package # solo build
#     ./scripts/build-veyon-macos.sh --no-build   # solo configure
#     ./scripts/build-veyon-macos.sh --clean      # limpia el workspace
#     ./scripts/build-veyon-macos.sh --no-update  # no actualiza el checkout
#
# Requisitos: Xcode CLT, Homebrew con qtbase/qttools/qtshadertools/qttranslations/
# qt5compat/qca/libvncserver/openldap/cyrus-sasl/ninja.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Checkout ÚNICO de Veyon (scripts/veyon-source.sh es la fuente de verdad).
SOURCE_DIR="$(bash "$SCRIPT_DIR/veyon-source.sh" path)"
PATCH_DIR="$PROJECT_DIR/patches"
WORK_DIR="${VEYON_MACOS_WORK_DIR:-$PROJECT_DIR/build/veyon-macos}"
BUILD_DIR="$WORK_DIR/build"
JOBS="${VEYON_MACOS_JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

PREFIX="${VEYON_MACOS_PREFIX:-/opt/homebrew}"
if [ -x /usr/local/bin/brew ] && [ ! -d "$PREFIX" ]; then
    PREFIX="/usr/local"
fi

DEPLOYMENT_TARGET="${VEYON_MACOS_DEPLOYMENT_TARGET:-14.0}"

DO_BUILD=1
DO_CLEAN=0
DO_PACKAGE=1
DO_UPDATE=1
for arg in "$@"; do
    case "$arg" in
        --no-build) DO_BUILD=0 ;;
        --clean)    DO_CLEAN=1 ;;
        --no-package) DO_PACKAGE=0 ;;
        --no-update) DO_UPDATE=0 ;;
        *) echo "Opción desconocida: $arg" >&2; exit 2 ;;
    esac
done

echo "──  Veyon para macOS  ──"
echo "    source : $SOURCE_DIR"
echo "    work   : $WORK_DIR"
echo "    prefix : $PREFIX"
echo "    target : macOS $DEPLOYMENT_TARGET"

# 1. Verificación de dependencias ───────────────────────────────────────────
if [ "$DO_CLEAN" -eq 0 ]; then
    echo "── comprobar dependencias ──"
    MISSING=""
    for tool in cmake ninja git; do
        command -v "$tool" >/dev/null 2>&1 || MISSING="$MISSING $tool"
    done
    if [ -n "$MISSING" ]; then
        echo "   ERROR: faltan herramientas:$MISSING"
        echo "   brew install cmake ninja"
        exit 1
    fi
    # Homebrew only symlinks a subset of the Qt frameworks into $PREFIX/lib,
    # so the keg directories are searched as well.
    find_framework() {
        local name="$1"
        for candidate in \
            "$PREFIX/lib/$name.framework" \
            "$PREFIX/opt/qtbase/lib/$name.framework" \
            "$PREFIX/opt/qt5compat/lib/$name.framework" \
            "$PREFIX/opt/qca/lib/$name.framework"
        do
            [ -e "$candidate" ] && return 0
        done
        return 1
    }

    for lib in QtCore QtNetwork QtWidgets qca-qt6; do
        if ! find_framework "$lib"; then
            echo "   ERROR: falta la librería $lib en $PREFIX"
            echo "   brew install qtbase qttools qtshadertools qttranslations qt5compat qca"
            exit 1
        fi
    done
fi

# 2. Workspace editable a partir del checkout upstream ──────────────────────
if [ "$DO_CLEAN" -eq 1 ]; then
    echo "── limpiar workspace ──"
    rm -rf "$WORK_DIR"
    exit 0
fi

# 2b. Actualizar el checkout ÚNICO de Veyon antes de compilar ───────────────
# Se hace aquí y no solo en "make download-src" para que el script compile
# siempre contra el mismo código, esté se invoque desde el Makefile o a mano.
if [ "$DO_UPDATE" -eq 1 ]; then
    echo "── actualizar checkout de Veyon ──"
    bash "$SCRIPT_DIR/veyon-source.sh" update
fi

echo "── preparar workspace ──"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cp -a "$SOURCE_DIR/." "$WORK_DIR/"

echo "── submodules ──"
cd "$WORK_DIR"
git submodule sync --recursive >/dev/null 2>&1 || true
git submodule update --init --recursive >/dev/null 2>&1 || true
git submodule status | sed 's/^/     /'

# 3. Aplicar parches ────────────────────────────────────────────────────────
# El checkout upstream se actualiza antes de compilar, así que su contexto
# puede haber cambiado desde que se generó un parche.  Cuando el parche ya no
# aplica limpiamente se intenta una fusión a tres vías, que resuelve los
# cambios de contexto siempre que no se contradigan.
echo "── aplicar parches ──"
for patch in "$PATCH_DIR"/*.patch; do
    [ -e "$patch" ] || continue
    name="$(basename "$patch")"
    if git apply --check "$patch" >/dev/null 2>&1; then
        git apply "$patch"
        echo "     aplicado  $name"
    elif git apply --reverse --check "$patch" >/dev/null 2>&1; then
        echo "     ya aplicado  $name"
    else
        merge_out="$(LC_ALL=C git apply --3way --check "$patch" 2>&1 || true)"
        if printf '%s' "$merge_out" | grep -qi "conflict"; then
            echo "     ERROR: $name no aplica (el upstream cambió el contexto)"
            echo "            revisa el parche o quítalo si el upstream ya lo incluye"
            exit 1
        fi
        if LC_ALL=C git apply --3way "$patch" >/dev/null 2>&1; then
            echo "     fusionado  $name"
        else
            echo "     ERROR al aplicar $name"
            exit 1
        fi
    fi
done

# 4. CMake configure ────────────────────────────────────────────────────────
echo "── CMake configure ──"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
cmake -G Ninja \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_PREFIX_PATH="$PREFIX" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    -DCMAKE_INSTALL_PREFIX="$WORK_DIR/install" \
    -DWITH_QT6=ON \
    -DWITH_LTO=OFF \
    -DWITH_TRANSLATIONS=OFF \
    -DWITH_TESTS=OFF \
    "$WORK_DIR" 2>&1 | tail -25

if [ "$DO_BUILD" -eq 0 ]; then
    echo "── configure completado (--no-build) ──"
    exit 0
fi

# 5. Compilar ───────────────────────────────────────────────────────────────
echo "── Ninja build (-j $JOBS) ──"
ninja -j "$JOBS"

# 6. Stage de ejecución con el mismo layout que el bundle ─────────────────
#    El bundle usa Contents/MacOS, Contents/PlugIns y Contents/Resources/lib,
#    y VEYON_PLUGIN_DIR apunta a "../PlugIns", por lo que el stage replica esa
#    estructura para que los ejecutables de desarrollo se comporten igual que
#    los del bundle.
echo "── preparar stage de ejecución ──"
STAGE_DIR="$BUILD_DIR/stage"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR/bin" "$STAGE_DIR/PlugIns" "$STAGE_DIR/Resources/lib"
for app in cli/veyon-cli master/veyon-master configurator/veyon-configurator \
           server/veyon-server service/veyon-service worker/veyon-worker; do
    [ -f "$BUILD_DIR/$app" ] && cp "$BUILD_DIR/$app" "$STAGE_DIR/bin/"
done
cp "$BUILD_DIR/core/libveyon-core.dylib" "$STAGE_DIR/Resources/lib/" 2>/dev/null || true
for plugin_dir in "$BUILD_DIR"/plugins/*/; do
    [ -d "$plugin_dir" ] || continue
    find "$plugin_dir" -maxdepth 1 -name "*.so" -exec cp {} "$STAGE_DIR/PlugIns/" \; 2>/dev/null || true
done
# El plugin de plataforma vive en plugins/platform/<plataforma>/.
for plugin_dir in "$BUILD_DIR"/plugins/platform/*/; do
    [ -d "$plugin_dir" ] || continue
    find "$plugin_dir" -maxdepth 1 -name "*.so" -exec cp {} "$STAGE_DIR/PlugIns/" \; 2>/dev/null || true
done
# Algunos grupos de plugins tienen un tercer nivel (servidores VNC, backends
# LDAP y backends de la Web API).
for plugin_dir in "$BUILD_DIR"/plugins/vncserver/*/ "$BUILD_DIR"/plugins/ldap/*/ "$BUILD_DIR"/plugins/webapi/*/; do
    [ -d "$plugin_dir" ] || continue
    find "$plugin_dir" -maxdepth 1 -name "*.so" -exec cp {} "$STAGE_DIR/PlugIns/" \; 2>/dev/null || true
done
cp "$BUILD_DIR/plugins/ldap/kldap/libkldap-light.dylib" "$STAGE_DIR/PlugIns/" 2>/dev/null || true

# Aplicar el rpath relativo del bundle a los ejecutables del stage.
for app in "$STAGE_DIR"/bin/*; do
    [ -f "$app" ] || continue
    install_name_tool -add_rpath "@executable_path/../Resources/lib" "$app" 2>/dev/null || true
done

# 7. Verificación ───────────────────────────────────────────────────────────
echo "── verificación (veyon-cli about) ──"
export DYLD_LIBRARY_PATH="$STAGE_DIR/Resources/lib:$STAGE_DIR/PlugIns${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
"$STAGE_DIR/bin/veyon-cli" about 2>&1 | sed 's/^/    /' || {
    echo "    (no se pudo ejecutar el binario)"
    exit 1
}

echo "── plugins cargados ──"
"$STAGE_DIR/bin/veyon-cli" plugin list 2>&1 | grep -v "^Logger:" | sed 's/^/    /' | head -20 || true

echo
echo "==> OK: stage en $STAGE_DIR"
echo "    Ejecuta: DYLD_LIBRARY_PATH=$STAGE_DIR/Resources/lib:$STAGE_DIR/PlugIns $STAGE_DIR/bin/veyon-master"

# 8. Empaquetado: bundle .app y disco DMG ───────────────────────────────────
if [ "$DO_PACKAGE" -eq 1 ]; then
    echo "── bundle .app ──"
    ( cd "$BUILD_DIR" && ninja macos_bundle ) || {
        echo "   ERROR: no se pudo generar el bundle"
        exit 1
    }

    echo "── desplegar frameworks (macdeployqt) ──"
    bash "$SCRIPT_DIR/deploy-veyon-macos.sh" || {
        echo "   ERROR: no se pudieron desplegar los frameworks"
        exit 1
    }

    echo "── DMG ──"
    bash "$SCRIPT_DIR/package-veyon-macos.sh" || {
        echo "   ERROR: no se pudo generar el DMG"
        exit 1
    }
fi
