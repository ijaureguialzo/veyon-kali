# Compilar Veyon → .deb para Kali Linux desde un Mac vía Docker

Proceso verificado el 2026-09-14. Produce **dos paquetes** — `arm64` (nativo) y
`amd64` (emulado) — a partir del contenedor `kalilinux/kali-rolling`, sin tocar
la máquina Kali remota.

## Entorno

- Host: Mac Apple-Silicon (`aarch64`), Docker Desktop.
- Imagen: `kalilinux/kali-rolling` (multi-arquitectura; mismo digest para las
  dos arquitecturas).
- Fuente: el checkout **único** de Veyon en `build/veyon` (submodules
  incluidos), que `scripts/veyon-source.sh` clona y mantiene actualizado.

## Requisitos previos

```bash
# 1. Fuente (opcional: make arm64/amd64 ya lo hacen por su cuenta)
make download-src  # clona build/veyon si falta y lo actualiza
                   # (fetch + fast-forward + submodules: ultravnc, x11vnc,
                   #  libvncserver, libfakekey, qthttpserver, kldap,
                   #  kldap-qt5 + anidados: doxygen-awesome-css, novnc, http-parser)

# 2. Imagen kali en ambas arquitecturas
docker pull --platform linux/arm64 kalilinux/kali-rolling
docker pull --platform linux/amd64 kalilinux/kali-rolling
```

## Ejecutar

```bash
cd ~/proyectos/veyon-kali
make arm64          # ~3-5 min (nativo)     -> package/veyon_<version>_arm64.deb
make amd64          # ~15-30 min (emulado)   -> package/veyon_<version>_amd64.deb
make all            # arm64 + amd64 + el paquete de macOS
make clean          # borra los .deb generados y el workspace de macOS
```

`make arm64` y `make amd64` actualizan antes el checkout de Veyon: el
contenedor monta esa misma copia en read-only (`/src`), así que la fuente que
compila es siempre la última del upstream.

## Compilación continua

`.github/workflows/build.yml` compila los tres paquetes con el mismo
Makefile:

| Job | Runner | Paquete |
|---|---|---|
| `deb` (arm64) | `ubuntu-24.04-arm` | `veyon_<version>_arm64.deb` |
| `deb` (amd64) | `ubuntu-24.04` | `veyon_<version>_amd64.deb` |
| `macos` | `macos-14` | `Veyon-<version>.dmg` |

Se dispara al hacer push a `main`, al abrir un PR y a mano (*Run
workflow*).  Desde ese formulario se puede elegir el runner de la build
arm64: el nativo (`ubuntu-24.04-arm`, rápido y gratis en repositorios
públicos) o uno x86_64 con emulación con qemu, si el repositorio es
privado y no hay runners ARM.

Cada ejecución sube los paquetes como artefactos y, al publicar una
etiqueta `v*`, se crea además una release de GitHub con los tres
ficheros.

## Resultado verificado

| Archivo | Arquitectura | Size | veyon-cli about |
|---|---|---|---|
| `package/veyon_4.11.4.14_arm64.deb` | `arm64` | 1.6 MB | `…/built against 5.15.19/arm64-little_endian-lp64` |
| `package/veyon_4.11.4.14_amd64.deb` | `amd64` | 1.8 MB | `…/built against 5.15.19/x86_64-little_endian-lp64` |

Ambos se instalan limpiamente con `dpkg -i` tras `apt-get install -f`; `veyon-cli`
informa `Veyon 4.11.4 / Qt 5.15.19 / OpenSSL 3.6.5`.

## Decisiones clave de configuración

- **Qt5, no Qt6**: `kalilinux/kali-rolling` trae runtime Qt6 pero **no**
  `qt6-base-dev`; sí trae `qtbase5-dev`. → `-DWITH_QT6=OFF`.
- **libVNC empaquetado**: `libvncserver-dev` no existe en repos Kali. →
  `-DWITH_BUNDLED_LIBVNC=ON` (usa `3rdparty/libvncserver`).
- **Parche GCC 15+ `-Werror`**: Veyon compila con `-Werror` en todos los
  objetivos (ver `cmake/modules/SetDefaultTargetProperties.cmake:16`). El
  GCC 15 del contenedor emite 3 **falsos positivos** que rompen el build:
  - `format-overflow` / `format-truncation` en `3rdparty/libvncserver/include/rfb/rfbproto.h:252`
  - `maybe-uninitialized` en `plugins/platform/linux/LinuxServerProcess.cpp`
    (por `QString::d` vía `qstringbuilder.h`/`QConcatenable`)

  Solución mínima: demorar solo esas 3 familias a `warning`, conservando
  `-Werror` para el resto:

  ```bash
  sed -i \
    's/PRIVATE "-Wall;-Werror")/PRIVATE "-Wall;-Werror;-Wno-error=format-overflow;-Wno-error=format-truncation;-Wno-error=maybe-uninitialized")/' \
    cmake/modules/SetDefaultTargetProperties.cmake
  ```

  El parche se aplica **en `/work` dentro del contenedor**, no en la fuente
  montada (`:ro`), así el árbol del host no se altera.

- **Dependencias de build a instalar en el contenedor** (no vienen en la
  imagen Kali):
  ```
  build-essential cmake ninja-build git fakeroot dpkg-dev
  pkg-config xorg-dev libx11-dev
  qtbase5-dev qtbase5-private-dev
  libqca-qt5-2-dev libqca-qt5-2-plugins
  libssl-dev libpam0g-dev zlib1g-dev libpng-dev libjpeg-dev liblzo2-dev
  libldap-dev libsasl2-dev libproc2-dev libfakekey-dev
  libxkbcommon-x11-dev libxcb-xinput-dev libxcb1-dev
  file xz-utils         # file -> libmagic (necesario a CPACK_DEBIAN_PACKAGE_SHLIBDEPS)
  ```

- **webapi/Qt5HttpServer**: `plugins/webapi` hace `find_package(Qt5HttpServer)`.
  No existe en repos Kali, es **no-fatal**: CMake avisa y usa el
  `3rdparty/qthttpserver` (submodule, con `http-parser`). No hace falta
  `-DWITH_WEBAPI=OFF`.

## Diferencias Kali ↔ Debian (resumen)

| Aspecto | Afecta? |
|---|---|
| Sufijos `…t64` de trixie (`libqt5core5t64`, `libpng16-16`, `liblzo2-2`, `libproc2-1`, `libssl3t64`) | **No** — CMake/CPack calcula `Depends` correctos via `shlibdeps`. |
| `libvncserver-dev` no en repos | **Sí** → `-DWITH_BUNDLED_LIBVNC=ON`. |
| `qt6-base-dev` no presente | **Sí** → `-DWITH_QT6=OFF` (ruta Qt5). |
| `gcc-15` con 3 falsos positivos | **Sí** → sed parche en `SetDefaultTargetProperties.cmake`. |
| `file` (libmagic) no por defecto | **Sí** → añadir a `apt-get install`. |
| `--network=host` de Docker | **No aplica** en macOS — omitido; DNS de bridge funciona para `apt`. |
| amd64 en Apple-Silicon | **Emulación qemu** vía `--platform linux/amd64`, funciona sin registro extra. |

## Archivos de este proceso

- `Makefile` — orquestación `docker run`.
- `build-veyon.sh` — la lógica que corrobora dentro del contenedor
  (apt → copiar a `/work` → parche → CMake → Ninja → CPack → verificar).
- `package/veyon_4.11.4.14_arm64.deb`
- `package/veyon_4.11.4.14_amd64.deb`
