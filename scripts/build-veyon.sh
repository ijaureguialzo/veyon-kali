#!/bin/bash
# build-veyon.sh — Se ejecuta DENTRO de un contenedor kalilinux/kali-rolling.
# Uso del Makefile:
#     docker run --rm --platform linux/<arch> \
#          -v <repo>:/src:ro -v <host_out>:/out \
#          kalilinux/kali-rolling /bin/bash /src/build-veyon.sh
#
# La fuente /src está en read-only; una copia editable se crea en /work
# para aplicar el parche de GCC-15 sin alterar el árbol del host.
# /src es el checkout ÚNICO de Veyon: el anfitrión lo deja actualizado antes
# de lanzar el contenedor (make download-src / scripts/veyon-source.sh), así
# que aquí solo se inicializan los submodules que falten en la copia.
# Resultado: /out/veyon_<version>_<arch>.deb

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
# Ningún comando de git debe abrir un pager dentro del contenedor.
export GIT_PAGER=cat
export PAGER=cat

echo "──  Veyon .deb    arch: $(uname -m)    ──"

# 1. Dependencias de build ─────────────────────────────────────────────────
# El CDN de http.kali.org reparte cada petición a un mirror distinto, y si
# dos de esos mirrors no están sincronizados entre sí la InRelease y el
# Packages no casan: apt-get update aborta con "File has unexpected size
# ... Mirror sync in progress?" y la compilación se cae sin motivo aparente.
# Fijando un mirror concreto, ambos archivos salen siempre del mismo sitio.
# Si el primero no responde, se va probando el siguiente.
KALI_MIRRORS="${KALI_MIRRORS:-http://mirror.raiolanetworks.com/kali/ http://mirror.es.cdn-perfprod.com/kali/ http://ftp.halifax.rwth-aachen.de/kali/}"
KALI_SOURCES=/etc/apt/sources.list.d/kali.sources

set_kali_mirror() {
    local mirror="$1"
    if [ -f "$KALI_SOURCES" ]; then
        # Formato deb822 (Kali actual): "URIs: http://http.kali.org/kali/"
        sed -i "s|^URIs:.*|URIs: $mirror|" "$KALI_SOURCES"
    else
        # Formato clásico de una línea por repositorio
        sed -i "s|http://[a-z0-9./-]*kali[a-z0-9./-]*|${mirror%/}|g" /etc/apt/sources.list
    fi
}

echo "── apt-get update ──"
update_apt_index() {
    local attempt delay=5 mirror
    local -a mirrors
    read -r -a mirrors <<< "$KALI_MIRRORS"
    [ ${#mirrors[@]} -gt 0 ] || mirrors=("http://http.kali.org/kali/")
    for attempt in 1 2 3 4; do
        mirror="${mirrors[$(( (attempt - 1) % ${#mirrors[@]} ))]}"
        set_kali_mirror "$mirror"
        echo "   mirror: $mirror"
        if apt-get -o Acquire::Retries=3 -o Acquire::http::Timeout=60 update -qq 2>&1 | tail -3; then
            return 0
        fi
        if [ "$attempt" -lt 4 ]; then
            echo "   (intento $attempt/4 fallido con este mirror; se prueba otro en ${delay}s)"
            sleep "$delay"
            delay=$((delay * 2))
        fi
    done
    return 1
}
if ! update_apt_index; then
    echo "   ERROR: no se pudo actualizar el índice de paquetes de Kali"
    exit 1
fi

echo "── instalar dependencias de build (Qt5 + libvnc empaquetado) ──"
if ! apt-get install -y --no-install-recommends \
    build-essential cmake ninja-build git fakeroot dpkg-dev \
    pkg-config xorg-dev libx11-dev \
    qtbase5-dev qtbase5-private-dev \
    libqca-qt5-2-dev libqca-qt5-2-plugins \
    libssl-dev libpam0g-dev \
    zlib1g-dev libpng-dev libjpeg-dev liblzo2-dev \
    libldap-dev libsasl2-dev libproc2-dev libfakekey-dev \
    libxkbcommon-x11-dev libxcb-xinput-dev libxcb1-dev \
    file xz-utils \
     2>&1 | tail -15; then
    echo "   ERROR: no se pudieron instalar las dependencias de build"
    exit 1
fi

# 2. Copiar fuente a workspace editable (/work) — /src es read-only ───────────
echo "── preparar workspace /work ──"
rm -rf /work
cp -a /src /work

# 2b. Inicializar submodules (la fuente montada puede no tenerlos desplegados) ──
echo "── git submodules ──"
cd /work
git submodule sync --recursive >/dev/null 2>&1 || true
git submodule update --init --recursive 2>&1 | tail -15
echo "   subs desplegados:"
git submodule status | sed 's/^/     /'

# 3. Parche GCC 15+ falsos positivos ────────────────────────────────────────
# Veyon escala a error con -Werror todos los warnings.  En GCC 15+ se
# producen 3 falsos positivos que rompen el build.  Se demuestran
# individualmente a nivel warning; -Werror se conserva para el resto.
#    format-overflow       3rdparty/libvncserver/include/rfb/rfbproto.h
#    format-truncation     (mismo sitio)
#    maybe-uninitialized   LinuxServerProcess.cpp ( QString::d )
F=/work/cmake/modules/SetDefaultTargetProperties.cmake
echo "── parche -Werror ──"
if [ ! -f "$F" ]; then
   echo "   F no encontrado, se omite"
else
   if grep -q 'Wno-error=format-truncation' "$F"; then
      echo "   ya aplicado"
   else
      sed -i \
         's/PRIVATE "-Wall;-Werror")/PRIVATE "-Wall;-Werror;-Wno-error=format-overflow;-Wno-error=format-truncation;-Wno-error=maybe-uninitialized")/' \
         "$F"
      echo "   parche: $(grep -n 'Wno-error=format-truncation' "$F" || echo 'ok')"
   fi
fi

# 4. CMake configure ────────────────────────────────────────────────────────
echo "── CMake configure ──"
mkdir -p /work/build && cd /work/build
cmake -G Ninja \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DWITH_QT6=OFF \
    -DWITH_BUNDLED_LIBVNC=ON \
    -DWITH_TRANSLATIONS=OFF \
    -DWITH_LTO=OFF \
    -DWITH_TESTS=OFF \
    .. 2>&1 | tail -25

# 5. Compilar ───────────────────────────────────────────────────────────────
echo "── Ninja build (-j $(nproc)) ──"
ninja -j "$(nproc)"

# 6. Generar .deb via CPack de CMake (fakeroot) ─────────────────────────────
echo "── CPack → .deb (fakeroot) ──"
fakeroot ninja package 2>&1 | tail -15

DEB="$(ls veyon_*.deb 2>/dev/null | head -1)"
if [ -z "$DEB" ]; then
   echo "ERROR: no se generó .deb"
   exit 1
fi

mkdir -p /out
cp "$DEB" /out/
echo "==> OK:     $(basename "$DEB")    ->  /out/"

# 7. Verificación: instalar el .deb y resolver deps runtime ─────────────────────
echo "── verificación (instalar + veyon-cli about) ──"
dpkg -i "$DEB" >/dev/null 2>&1 || true
# Resuelve las deps de runtime que faltan (Apt elige la variante t64 por arqu).
apt-get install -f -y --no-install-recommends >>/tmp/rt.log 2>&1 || {
   echo "   (aviso) deps runtime sin resolver; ver /tmp/rt.log:"; tail -5 /tmp/rt.log 2>/dev/null || true;
}
echo "── veyon-cli about ──"
veyon-cli about 2>&1 | sed 's/^/    /' || echo "    (no se pudo ejecutar el binario)"


