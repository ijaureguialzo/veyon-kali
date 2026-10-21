#!/bin/bash
# deploy-veyon-macos.sh — Hace autosuficiente el bundle Veyon.app.
#
# Ejecuta macdeployqt sobre el bundle para copiar dentro de él todos los
# frameworks Qt y las librerías nativas de las que depende (OpenSSL, LDAP,
# SASL, libvncclient, QCA), y reescribe los runpath para que apunten a la
# copia local.  El resultado no depende de la instalación de Homebrew.
#
# Uso:
#     ./scripts/deploy-veyon-macos.sh
#
# Espera el bundle en build/veyon-macos/build/Veyon.app

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

BUILD_DIR="${VEYON_MACOS_BUILD_DIR:-$PROJECT_DIR/build/veyon-macos/build}"
BUNDLE="$BUILD_DIR/Veyon.app"
FRAMEWORKS_DIR="$BUNDLE/Contents/Frameworks"

if [ ! -d "$BUNDLE" ]; then
    echo "ERROR: no existe el bundle $BUNDLE"
    echo "       ejecuta primero:  ninja -C $BUILD_DIR macos_bundle"
    exit 1
fi

# Localizar macdeployqt: Homebrew, el keg de qtbase o el Qt del SDK.
find_macdeployqt() {
    if command -v macdeployqt >/dev/null 2>&1; then
        command -v macdeployqt
        return 0
    fi
    for candidate in \
        /opt/homebrew/opt/qtbase/bin/macdeployqt \
        /usr/local/opt/qtbase/bin/macdeployqt \
        /opt/homebrew/opt/qt/bin/macdeployqt \
        /usr/local/opt/qt/bin/macdeployqt
    do
        [ -x "$candidate" ] && { echo "$candidate"; return 0; }
    done
    return 1
}

if ! MACDEPLOYQT="$(find_macdeployqt)"; then
    echo "ERROR: no se encuentra macdeployqt"
    echo "       brew install qtbase"
    exit 1
fi

echo "── Desplegar frameworks en el bundle ──"
echo "    macdeployqt: $MACDEPLOYQT"

# macdeployqt espera un ejecutable o un bundle.  Se le pasa el bundle
# completo para que también copie los plugins de QCA.
"$MACDEPLOYQT" "$BUNDLE" -always-overwrite

# ---------------------------------------------------------------------------
# Frameworks Qt adicionales
# ---------------------------------------------------------------------------

# macdeployqt sólo copia los frameworks que los ejecutables del bundle
# necesitan de forma directa.  Los plugins de Qt que el propio macdeployqt
# copia al directorio de plugins pueden depender de frameworks adicionales
# que no llegan al bundle, como QtSvg, del que depende el motor de iconos
# SVG.  Sin él, el plugin no puede cargarse.
echo "── Copiar los frameworks Qt que falten ──"

# Los plugins de Qt del directorio de plugins pueden necesitar frameworks
# que no están entre las dependencias de los ejecutables.
for qt_plugin in "$BUNDLE"/Contents/PlugIns/*/*.dylib; do
    [ -f "$qt_plugin" ] || continue
    while read -r dep; do
        case "$dep" in
            @rpath/*.framework/Versions/*)
                fw="$(echo "$dep" | sed 's|^@rpath/||; s|/Versions/.*||')"
                # "fw" ya incluye el sufijo .framework.
                [ -d "$FRAMEWORKS_DIR/$fw" ] && continue
                for keg in /opt/homebrew/opt/*/lib /usr/local/opt/*/lib; do
                    [ -d "$keg/$fw" ] || continue
                    cp -R "$keg/$fw" "$FRAMEWORKS_DIR/" 2>/dev/null || true
                    chmod -R u+w "$FRAMEWORKS_DIR/$fw" 2>/dev/null || true
                    echo "    $fw (requerido por $(basename "$qt_plugin"))"
                    break
                done
                ;;
        esac
    done < <(otool -L "$qt_plugin" 2>/dev/null | tail -n +2 | awk '{print $1}')
done

# ---------------------------------------------------------------------------
# Funciones auxiliares
# ---------------------------------------------------------------------------

# Localiza la biblioteca real a la que apunta una ruta de Homebrew, para
# poder copiarla al bundle.
resolve_homebrew_library() {
    local path="$1"

    # Resolver los enlaces simbólicos intermedios.
    local dir base candidate
    dir="$(dirname "$path")"
    base="$(basename "$path")"

    if [ ! -e "$path" ]; then
        # Buscar la biblioteca con el mismo nombre en los kegs instalados.
        local keg
        for keg in /opt/homebrew/opt/*/lib /usr/local/opt/*/lib; do
            [ -d "$keg" ] || continue
            candidate="$keg/$base"
            [ -e "$candidate" ] && { echo "$candidate"; return 0; }
        done
        return 1
    fi

    echo "$path"
}

# Copia una biblioteca de Homebrew al directorio de frameworks del bundle,
# resolviendo los enlaces simbólicos para poder reescribir su identificador.
copy_homebrew_library() {
    local path="$1"
    local resolved
    resolved="$(resolve_homebrew_library "$path")" || return 1

    local base
    base="$(basename "$resolved")"
    local target="$FRAMEWORKS_DIR/$base"

    # Si ya está en el bundle, no hace falta copiarla de nuevo.
    if [ -e "$target" ] && [ ! -L "$target" ]; then
        echo "$target"
        return 0
    fi

    cp -L "$resolved" "$target" 2>/dev/null || cp "$resolved" "$target" 2>/dev/null || return 1
    chmod u+w "$target" 2>/dev/null || true
    echo "$target"
}

# Reescribe las rutas absolutas de Homebrew de un binario a rutas @rpath
# relativas al bundle.
rewrite_homebrew_paths() {
    local binary="$1"
    [ -f "$binary" ] || return 0

    local deps
    deps="$(otool -L "$binary" 2>/dev/null | tail -n +2 | awk '{print $1}')"

    for dep in $deps; do
        case "$dep" in
            /opt/homebrew/*|/usr/local/*)
                local rel fw base fwdir fver
                case "$dep" in
                    *.framework/Versions/*)
                        # /opt/.../QtCore.framework/Versions/A/QtCore
                        # -> QtCore.framework
                        fwdir="${dep%%.framework/Versions/*}"
                        fw="$(basename "$fwdir").framework"
                        # La versión del framework no es necesariamente "A",
                        # por lo que se usa la que declara la dependencia.
                        fver="${dep#*".framework/Versions/"}"
                        fver="${fver%%/*}"
                        rel="@rpath/$fw/Versions/$fver/$(basename "$fwdir")"
                        ;;
                    *)
                        base="$(basename "$dep")"
                        rel="@rpath/$base"
                        ;;
                esac

                if [ -n "$fw" ]; then
                    # El framework tiene que estar copiado en el bundle.
                    if [ -d "$FRAMEWORKS_DIR/$fw" ]; then
                        install_name_tool -change "$dep" "$rel" "$binary" 2>/dev/null || true
                    fi
                else
                    # La biblioteca tiene que estar copiada en el bundle.
                    if [ -e "$FRAMEWORKS_DIR/$base" ] || \
                       [ -e "$BUNDLE/Contents/Resources/lib/$base" ]; then
                        install_name_tool -change "$dep" "$rel" "$binary" 2>/dev/null || true
                        # Algunas bibliotecas de Homebrew son enlaces
                        # simbólicos a otra versión del mismo nombre, y en
                        # ese caso el identificador sigue apuntando a la
                        # ruta original.
                        install_name_tool -id "@rpath/$base" "$binary" 2>/dev/null || true
                    fi
                fi
                ;;
        esac
    done

    # El identificador del propio binario (install name) también puede
    # apuntar a la ruta de Homebrew.  En el caso de un framework, el
    # identificador es la ruta del binario dentro de Versions/<version>.
    local self_id
    self_id="$(otool -D "$binary" 2>/dev/null | tail -n +2 | head -1)"
    case "$self_id" in
        /opt/homebrew/*|/usr/local/*)
            local self_rel self_fw self_fwdir self_fver
            case "$self_id" in
                *.framework/Versions/*)
                    self_fwdir="${self_id%%.framework/Versions/*}"
                    self_fw="$(basename "$self_fwdir").framework"
                    self_fver="${self_id#*".framework/Versions/"}"
                    self_fver="${self_fver%%/*}"
                    self_rel="@rpath/$self_fw/Versions/$self_fver/$(basename "$self_fwdir")"
                    ;;
                *)
                    self_rel="@rpath/$(basename "$self_id")"
                    ;;
            esac
            install_name_tool -id "$self_rel" "$binary" 2>/dev/null || true
            ;;
    esac
}

# Enumera todos los binarios Mach-O del bundle.
bundle_binaries() {
    find "$BUNDLE" \
        \( -name "*.dylib" -o -name "*.so" -o -name "*.framework" \) \
        -type f 2>/dev/null | while read -r binary; do
            file "$binary" 2>/dev/null | grep -q "Mach-O" && echo "$binary"
        done
    for app in "$BUNDLE"/Contents/MacOS/*; do
        [ -f "$app" ] && echo "$app"
    done
    # Los frameworks tienen su ejecutable dentro de Versions/<version>, y la
    # versión no es necesariamente "A": por ejemplo qca-qt6 usa "2".
    for framework in "$FRAMEWORKS_DIR"/*.framework; do
        [ -d "$framework" ] || continue
        for version in "$framework"/Versions/*; do
            [ -d "$version" ] || continue
            for binary in "$version"/*; do
                [ -f "$binary" ] || continue
                file "$binary" 2>/dev/null | grep -q "Mach-O" && echo "$binary"
            done
        done
    done
}

# ---------------------------------------------------------------------------
# Runpath de los plugins
# ---------------------------------------------------------------------------

# macdeployqt reescribe el runpath de los ejecutables a
# @executable_path/../Frameworks, pero los plugins viven en Contents/PlugIns
# y necesitan dos rutas adicionales: la del core library y la de los
# frameworks.
echo "── Ajustar los runpath de los plugins ──"
for plugin in "$BUNDLE"/Contents/PlugIns/*.so; do
    [ -f "$plugin" ] || continue
    # En un plugin, @executable_path apunta a Contents/PlugIns, por lo que
    # la ruta correcta hacia los frameworks es @loader_path/../Frameworks.
    # Si no se reescribe, el plugin acaba cargando el Qt de Homebrew.
    # install_name_tool exige la ruta exacta, por lo que se recorren todas
    # las dependencias que empiecen por el prefijo problemático.
    while read -r dep; do
        case "$dep" in
            @executable_path/../Frameworks/*)
                install_name_tool -change "$dep" "@loader_path/../Frameworks/${dep#@executable_path/../Frameworks/}" \
                    "$plugin" 2>/dev/null || true
                ;;
        esac
    done < <(otool -L "$plugin" 2>/dev/null | tail -n +2 | awk '{print $1}')
    install_name_tool -add_rpath "@loader_path/../Resources/lib" "$plugin" 2>/dev/null || true
    install_name_tool -add_rpath "@loader_path/../Frameworks" "$plugin" 2>/dev/null || true
done

# Los ejecutables y los plugins necesitan el runpath hacia el directorio
# de frameworks del bundle.
for binary in "$BUNDLE"/Contents/MacOS/* "$BUNDLE"/Contents/PlugIns/*.so; do
    [ -f "$binary" ] || continue
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$binary" 2>/dev/null || true
    install_name_tool -add_rpath "@loader_path/../Frameworks" "$binary" 2>/dev/null || true
done

# Los plugins de Qt que macdeployqt copia en los subdirectorios de
# Contents/PlugIns (motores de iconos, formatos de imagen, estilos, ...) se
# compilan con runpaths pensados para la instalación de Homebrew, que no
# existen dentro del bundle.  Como viven un nivel por debajo de
# Contents/PlugIns, el directorio de frameworks está dos niveles más arriba.
for qt_plugin in "$BUNDLE"/Contents/PlugIns/*/*.dylib; do
    [ -f "$qt_plugin" ] || continue
    install_name_tool -add_rpath "@loader_path/../../Frameworks" "$qt_plugin" 2>/dev/null || true
    install_name_tool -add_rpath "@loader_path/../Frameworks" "$qt_plugin" 2>/dev/null || true
done

# ---------------------------------------------------------------------------
# Core library y biblioteca auxiliar de LDAP
# ---------------------------------------------------------------------------

# El core library también debe resolverse desde los plugins.  Vive en
# Contents/Resources/lib, que es donde lo coloca el target del bundle.
CORE_LIB="$BUNDLE/Contents/Resources/lib/libveyon-core.dylib"
if [ -f "$CORE_LIB" ]; then
    chmod u+w "$CORE_LIB" 2>/dev/null || true
    install_name_tool -id "@rpath/libveyon-core.dylib" "$CORE_LIB" 2>/dev/null || true
    install_name_tool -add_rpath "@loader_path" "$CORE_LIB" 2>/dev/null || true
    install_name_tool -add_rpath "@loader_path/../../Frameworks" "$CORE_LIB" 2>/dev/null || true
fi

# kldap-light es una biblioteca auxiliar del plugin de LDAP, no un plugin, y
# por eso no la copia macdeployqt.  El plugin la busca a través de @rpath.
KLDAP_SRC="$BUILD_DIR/plugins/ldap/kldap/libkldap-light.dylib"
if [ -f "$KLDAP_SRC" ]; then
    echo "── Copiar la biblioteca auxiliar de LDAP ──"
    cp "$KLDAP_SRC" "$BUNDLE/Contents/Resources/lib/"
    chmod u+w "$BUNDLE/Contents/Resources/lib/libkldap-light.dylib" 2>/dev/null || true
    install_name_tool -id "@rpath/libkldap-light.dylib" \
        "$BUNDLE/Contents/Resources/lib/libkldap-light.dylib" 2>/dev/null || true
    install_name_tool -add_rpath "@loader_path" \
        "$BUNDLE/Contents/Resources/lib/libkldap-light.dylib" 2>/dev/null || true
    install_name_tool -add_rpath "@loader_path/../../Frameworks" \
        "$BUNDLE/Contents/Resources/lib/libkldap-light.dylib" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Providers criptográficos de QCA
# ---------------------------------------------------------------------------

# Los plugins de QCA son dinámicos y se cargan en runtime.  Sólo se
# empaquetan los providers que Veyon utiliza: el resto (NSS, Botan, GnuTLS,
# PKCS#11) arrastran un elevado número de dependencias y se pueden instalar
# aparte en el equipo destino.
#
# QCA busca los providers en el subdirectorio "crypto" de cada una de sus
# rutas de plugins, de modo que deben instalarse en
# Contents/PlugIns/crypto y no directamente en Contents/PlugIns.
QCA_SRC="/opt/homebrew/opt/qca/lib/qt/plugins"
QCA_PROVIDERS="ossl softstore logger cyrus-sasl"
if [ -d "$QCA_SRC/crypto" ]; then
    echo "── Copiar los plugins criptográficos de QCA ──"
    mkdir -p "$BUNDLE/Contents/PlugIns/crypto"
    for provider in $QCA_PROVIDERS; do
        for lib in "$QCA_SRC/crypto/"*"$provider"*.dylib; do
            [ -f "$lib" ] || continue
            cp -L "$lib" "$BUNDLE/Contents/PlugIns/crypto/" 2>/dev/null || \
                cp "$lib" "$BUNDLE/Contents/PlugIns/crypto/" 2>/dev/null || true
        done
    done
    chmod -R u+w "$BUNDLE/Contents/PlugIns/crypto" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Closure de las dependencias que no son de Qt
# ---------------------------------------------------------------------------

# macdeployqt se encarga de Qt, pero no de OpenSSL, OpenLDAP, SASL,
# libvncclient o QCA.  Se calculan de forma transitiva las bibliotecas que
# faltan, para copiar únicamente las necesarias en lugar de todas las del
# sistema.
echo "── Calcular el cierre de dependencias ──"

declare -a PENDING=()

# Con "set -u" una array vacía no se puede expandir, por lo que se declaran
# como variables simples con un valor centinela.
SEEN=" "
SEEN_PATHS=" "

enqueue_dependency() {
    local path="$1"
    local base
    base="$(basename "$path")"

    case "$SEEN" in
        *" $base "*) return 0 ;;
    esac
    SEEN="$SEEN$base "
    SEEN_PATHS="$SEEN_PATHS$path "
    PENDING+=("$path")
}

# Sembrar el recorrido con los binarios raíz del bundle: los ejecutables,
# los plugins de Veyon y los providers de QCA.  Sin esto, el cierre sólo
# descubriría las dependencias de las librerías ya copiadas por
# macdeployqt, y se escaparían las dylibs no-Qt que necesitan los plugins.
for root in "$BUNDLE"/Contents/MacOS/* "$BUNDLE"/Contents/PlugIns/*.so \
            "$BUNDLE"/Contents/PlugIns/crypto/*.dylib
do
    [ -f "$root" ] || continue
    file "$root" 2>/dev/null | grep -q "Mach-O" || continue
    enqueue_dependency "$root"
done

# Recorrer el grafo de dependencias, resolviendo los enlaces simbólicos.
while [ "${#PENDING[@]}" -gt 0 ]; do
    current="${PENDING[0]}"
    PENDING=("${PENDING[@]:1}")

    [ -f "$current" ] || continue
    file "$current" 2>/dev/null | grep -q "Mach-O" || continue

    deps="$(otool -L "$current" 2>/dev/null | tail -n +2 | awk '{print $1}')"
    for dep in $deps; do
        case "$dep" in
            /opt/homebrew/*|/usr/local/*)
                resolved="$(resolve_homebrew_library "$dep")" || continue
                enqueue_dependency "$resolved"
                ;;
        esac
    done
done

# Copiar las bibliotecas del cierre que todavía no están en el bundle.
for path in $SEEN_PATHS; do
    [ -n "$path" ] || continue
    # Los frameworks ya los copia macdeployqt.
    case "$path" in
        *.framework/Versions/*) continue ;;
        "$BUNDLE"/*) continue ;;
    esac
    base="$(basename "$path")"
    [ -e "$FRAMEWORKS_DIR/$base" ] && continue
    copy_homebrew_library "$path" >/dev/null || true
done

# Los frameworks de Qt y de Homebrew se compilan con runpaths pensados para
# su instalación original, que no existen dentro del bundle.  Desde
# Contents/Frameworks/<framework>.framework/Versions/<version>/, las rutas
# útiles son las relativas al propio directorio del framework y las que
# suben hasta Contents/Frameworks.
echo "── Ajustar los runpath de los frameworks ──"
for framework in "$FRAMEWORKS_DIR"/*.framework; do
    [ -d "$framework" ] || continue
    for version in "$framework"/Versions/*; do
        [ -d "$version" ] || continue
        for binary in "$version"/*; do
            [ -f "$binary" ] || continue
            file "$binary" 2>/dev/null | grep -q "Mach-O" || continue
            chmod u+w "$binary" 2>/dev/null || true
            # Dentro de un framework, @executable_path apunta al ejecutable
            # de la aplicación, no al propio framework, por lo que las
            # dependencias que lo usan se resuelven desde @loader_path.
            while read -r dep; do
                case "$dep" in
                    @executable_path/../Frameworks/*)
                        install_name_tool -change "$dep" \
                            "@loader_path/../../../${dep#@executable_path/../Frameworks/}" \
                            "$binary" 2>/dev/null || true
                        ;;
                esac
            done < <(otool -L "$binary" 2>/dev/null | tail -n +2 | awk '{print $1}')
            # El directorio del propio binario y el de los frameworks del
            # bundle, que están tres niveles más arriba.
            install_name_tool -add_rpath "@loader_path" "$binary" 2>/dev/null || true
            install_name_tool -add_rpath "@loader_path/../../.." "$binary" 2>/dev/null || true
            install_name_tool -add_rpath "@loader_path/../../../.." "$binary" 2>/dev/null || true
        done
    done
done

# ---------------------------------------------------------------------------
# Reescritura de las rutas absolutas
# ---------------------------------------------------------------------------

# Las bibliotecas sueltas del directorio Frameworks también pueden enlazar
# con rutas absolutas de Homebrew, por ejemplo libbrotlicommon.1.dylib, que
# además se referencia a sí misma.
for library in "$FRAMEWORKS_DIR"/*.dylib; do
    [ -f "$library" ] || continue
    # macdeployqt copia las bibliotecas como enlaces simbólicos; hay que
    # convertirlas en ficheros reales para poder reescribir su identificador.
    if [ -L "$library" ]; then
        target="$(readlink "$library")"
        rm -f "$library"
        cp -L "$target" "$library" 2>/dev/null || \
            cp "$target" "$library" 2>/dev/null || true
    fi
    chmod u+w "$library" 2>/dev/null || true
    # Su propio runpath debe apuntar al directorio de frameworks.
    install_name_tool -add_rpath "@loader_path" "$library" 2>/dev/null || true
    # Estas bibliotecas se compilan con dependencias que apuntan a
    # @executable_path/../Frameworks, que dentro del bundle corresponde a
    # Contents/Frameworks, el directorio en el que viven.
    while read -r dep; do
        case "$dep" in
            @executable_path/../Frameworks/*)
                install_name_tool -change "$dep" \
                    "@loader_path/${dep#@executable_path/../Frameworks/}" \
                    "$library" 2>/dev/null || true
                ;;
        esac
    done < <(otool -L "$library" 2>/dev/null | tail -n +2 | awk '{print $1}')
    # El identificador de la biblioteca no debe apuntar a la ruta de
    # Homebrew, sino a la ruta relativa del bundle.
    libname="$(basename "$library")"
    install_name_tool -id "@rpath/$libname" "$library" 2>/dev/null || true
done

# La reescritura se hace de forma iterativa: una biblioteca puede depender de
# otra que todavía no se ha copiado, por lo que se repite hasta que no queda
# ninguna ruta absoluta.
echo "── Reescribir las rutas absolutas ──"
for pass in 1 2 3 4 5; do
    changed=0
    while read -r binary; do
        [ -f "$binary" ] || continue
        if otool -L "$binary" 2>/dev/null | grep -q "homebrew"; then
            rewrite_homebrew_paths "$binary"
            changed=1
        fi
    done < <(bundle_binaries)
    [ "$changed" -eq 0 ] && break
done

# Los plugins de QCA están en un subdirectorio, por lo que su runpath hacia
# los frameworks es un nivel más arriba.
for qca_plugin in "$BUNDLE"/Contents/PlugIns/crypto/*.dylib; do
    [ -f "$qca_plugin" ] || continue
    install_name_tool -add_rpath "@loader_path" "$qca_plugin" 2>/dev/null || true
    install_name_tool -add_rpath "@loader_path/../../Frameworks" "$qca_plugin" 2>/dev/null || true
    install_name_tool -add_rpath "@loader_path/../../Resources/lib" "$qca_plugin" 2>/dev/null || true
done

# ---------------------------------------------------------------------------
# Neutralizar la ruta de plugins compilada en QCA
# ---------------------------------------------------------------------------

# QCA compila en su framework la ruta en la que se instalaron sus plugins
# (la macro QCA_PLUGIN_PATH) y la añade siempre a la lista de rutas que
# explora, además de las que registra la aplicación.  Esa ruta apunta al
# prefix de Homebrew, por lo que el bundle acababa cargando los providers
# de QCA del sistema en lugar de los suyos.
#
# La ruta compilada es un literal UTF-16 dentro de la sección __ustring del
# framework.  Sustituirla por una ruta inexistente hace que QDir::canonicalPath()
# devuelva una cadena vacía y QCA la descarte, de modo que sólo se exploran
# las rutas que la aplicación registra, que dentro del bundle apuntan a
# Contents/PlugIns.
#
# QStringLiteral fija la longitud del literal en el código, así que el
# replacement tiene que tener exactamente el mismo número de caracteres.
echo "── Neutralizar la ruta de plugins de QCA ──"
QCA_FRAMEWORK="$FRAMEWORKS_DIR/qca-qt6.framework"
for qca_binary in "$QCA_FRAMEWORK"/Versions/*/qca-qt6; do
    [ -f "$qca_binary" ] || continue

    python3 - "$qca_binary" <<'PYTHON'
import re
import sys

binary = sys.argv[1]
data = open(binary, "rb").read()

# La ruta compilada es un literal UTF-16LE, es decir, una secuencia de
# caracteres anchos con los bytes nulos intercalados.  Se recorren todas
# las cadenas de ese tipo que empiezan por una barra y se seleccionan las
# que apuntan a un directorio de plugins.
ustrings = re.compile(rb"(?:(?:[ -~]\x00){2,})")
candidates = []
for match in ustrings.finditer(data):
    text = match.group().decode("utf-16-le")
    if not text.startswith("/"):
        continue
    if "qt/plugins" in text or "plugins/crypto" in text:
        candidates.append((match, text))

if not candidates:
    print("    no se encontró ninguna ruta de plugins compilada")
    sys.exit(0)

for match, text in candidates:
    # Sustitución por una ruta imposible, manteniendo la longitud exacta.
    replacement = "/nonexistent-veyon-qca-plugins"
    if len(replacement) > len(text):
        replacement = replacement[:len(text)]
    padded = replacement + "\x00" * (len(text) - len(replacement))
    data = data[:match.start()] + padded.encode("utf-16-le") + data[match.end():]
    print("    %s -> %s" % (text, replacement))

open(binary, "wb").write(data)
PYTHON
    chmod u+w "$qca_binary" 2>/dev/null || true
done

# ---------------------------------------------------------------------------
# Neutralizar el directorio de módulos de OpenSSL
# ---------------------------------------------------------------------------

# OpenSSL 4 compila en su biblioteca la ruta en la que se instalaron sus
# providers opcionales (el legacy provider) y los carga automáticamente al
# inicializarse.  Esa ruta apunta al prefix de Homebrew, por lo que el
# bundle acababa dependiendo de él.
#
# El provider legacy sólo aporta algoritmos que Veyon no utiliza, de modo
# que se sustituye la ruta por una inexistente: OpenSSL deja de buscarlo y
# sigue funcionando con los providers que ya trae incorporados.
echo "── Neutralizar el directorio de módulos de OpenSSL ──"
for crypto_lib in "$FRAMEWORKS_DIR"/libcrypto*.dylib; do
    [ -f "$crypto_lib" ] || continue

    python3 - "$crypto_lib" <<'PYTHON'
import re
import sys

binary = sys.argv[1]
data = open(binary, "rb").read()

# La ruta compilada es un literal ASCII terminado en null, dentro de la
# sección __cstring, por lo que se puede sustituir conservando la longitud.
pattern = re.compile(rb"/[ -~]{4,}/ossl-modules")
matches = list(pattern.finditer(data))

if not matches:
    print("    no se encontró ningún directorio de módulos de OpenSSL")
    sys.exit(0)

for match in matches:
    text = match.group()
    replacement = b"/nonexistent-ossl-modules"
    if len(replacement) > len(text):
        replacement = replacement[:len(text)]
    padded = replacement + b"\x00" * (len(text) - len(replacement))
    data = data[:match.start()] + padded + data[match.end():]
    print("    %s -> %s" % (text.decode(), replacement.decode()))

open(binary, "wb").write(data)
PYTHON
    chmod u+w "$crypto_lib" 2>/dev/null || true
done

# ---------------------------------------------------------------------------
# Limpieza
# ---------------------------------------------------------------------------

# Una vez reescritas las rutas, se pueden eliminar las bibliotecas que
# ningún componente del bundle usa: arrastran dependencias que no se pueden
# resolver y engordan el paquete.
echo "── Eliminar las bibliotecas sin uso ──"
used_libs="$(
    bundle_binaries | while read -r binary; do
        otool -L "$binary" 2>/dev/null | tail -n +2 | awk '{print $1}'
    done | sed 's|.*/||' | sort -u
)"
for library in "$FRAMEWORKS_DIR"/*.dylib; do
    [ -f "$library" ] || continue
    base="$(basename "$library")"
    # Los providers de QCA se conservan siempre.
    case "$base" in
        libqca-*) continue ;;
    esac
    if ! printf '%s\n' "$used_libs" | grep -qx "$base"; then
        rm -f "$library"
    fi
done

# ---------------------------------------------------------------------------
# Runpaths absolutos
# ---------------------------------------------------------------------------

# Los binarios se compilan con runpaths que apuntan al directorio de
# instalacion del build, que no existe dentro del bundle.  Se eliminan todas
# las rutas absolutas, para que el bundle no dependa de la maquina en la que
# se ha compilado.
#
# La limpieza se hace al final del despliegue, cuando todas las librerias ya
# estan copiadas, porque algunas de ellas reciben su runpath en el momento de
# ser copiadas.
echo "── Eliminar los runpaths absolutos ──"
for binary in "$BUNDLE"/Contents/MacOS/* "$BUNDLE"/Contents/PlugIns/*.so "$BUNDLE"/Contents/PlugIns/*/*.dylib \
              "$BUNDLE"/Contents/Resources/lib/*.dylib "$BUNDLE"/Contents/Frameworks/*/Versions/*/* \
              "$FRAMEWORKS_DIR"/*.dylib; do
    [ -f "$binary" ] || continue
    [ -L "$binary" ] && continue
    chmod u+w "$binary" 2>/dev/null || true
    while read -r rpath; do
        [ -n "$rpath" ] || continue
        case "$rpath" in
            /*)
                install_name_tool -delete_rpath "$rpath" "$binary" 2>/dev/null || true
                ;;
        esac
    done < <(otool -l "$binary" 2>/dev/null | awk '/^ *path /{print $2}')
done

# ---------------------------------------------------------------------------
# Firmado ad hoc
# ---------------------------------------------------------------------------

# Firmar los binarios de forma ad hoc, para que el bundle pueda ejecutarse
# en un equipo con Gatekeeper activo.
echo "── Firmado ad hoc ──"
find "$BUNDLE" \( -name "*.dylib" -o -name "*.so" -o -name "*.framework" \) \
    -exec codesign --force --sign - --timestamp=none {} \; 2>/dev/null || true
for app in "$BUNDLE"/Contents/MacOS/*; do
    [ -f "$app" ] || continue
    codesign --force --sign - --timestamp=none "$app" 2>/dev/null || true
done
codesign --force --sign - --timestamp=none "$BUNDLE" 2>/dev/null || true

echo
echo "==> Bundle desplegado: $BUNDLE"
echo "    Frameworks: $(ls "$FRAMEWORKS_DIR" 2>/dev/null | wc -l | tr -d ' ')"
