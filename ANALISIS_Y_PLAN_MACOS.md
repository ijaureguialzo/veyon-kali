# Análisis: compilación de Veyon para Kali → adaptación a macOS

Fecha: 2026-10-20
Ámbito: repositorio `veyon-kali` (orquestación Ansible + build Docker) y el árbol
`build/veyon` (checkout de `https://github.com/veyon/veyon.git`, commit
`0c629d993`, v4.11.2).

---

## 1. Qué hace hoy el proyecto (flujo de compilación para Kali)

### 1.1 Capas del repositorio

```
veyon-kali/
├── Makefile                    # orquestación: `docker run` por arquitectura
├── scripts/build-veyon.sh      # lógica real del build (dentro del contenedor)
├── build/veyon/                # checkout de upstream Veyon + submodules
├── package/                    # .deb generados (salida; ignorada por git)
├── roles/instalar-veyon/       # Ansible: copia el .deb y lo instala con apt
├── vars/main.yml               # version_paquete: veyon_4.11.2.7_amd64.deb
└── playbook.yml                # profesor + alumnos
```

### 1.2 `Makefile` (targets)

| Target | Qué hace |
|---|---|
| `make arm64` | `docker run --platform linux/arm64` de `kalilinux/kali-rolling` |
| `make amd64` | `docker run --platform linux/amd64` (emulado por qemu) |
| `make` / `all` | Ambos en secuencia |
| `make download-src` | `git clone --recursive` + `git pull --recurse-submodules` si falta `build/veyon` |
| `make setup-ssh` | Copia la clave pública a cada host del inventario |
| `make apply` | `ansible-playbook` con `vars/main.yml` |

Montajes used por `make arm64`/`amd64`:

```
-v ./build/veyon:/src:ro        # fuente en read-only
-v ./scripts:/scripts:ro        # script de build
-v ./package:/out               # salida de .deb
```

### 1.3 `scripts/build-veyon.sh` (dentro del contenedor)

1. `apt-get update` + instalación de dependencias de build.
2. `cp -a /src /work` → copia editable (porque `/src` es `:ro`).
3. `git submodule update --init --recursive` (por si el mount no los trae).
4. **Parche `-Werror`** con `sed` sobre `cmake/modules/SetDefaultTargetProperties.cmake`:
   añade `-Wno-error=format-overflow -Wno-error=format-truncation -Wno-error=maybe-uninitialized`
   (3 falsos positivos de GCC 15).
5. `cmake -G Ninja` con:
   ```
   -DCMAKE_BUILD_TYPE=RelWithDebInfo
   -DCMAKE_INSTALL_PREFIX=/usr
   -DWITH_QT6=OFF            # Kali no tiene qt6-base-dev, sí qtbase5-dev
   -DWITH_BUNDLED_LIBVNC=ON  # libvncserver-dev no está en los repos de Kali
   -DWITH_TRANSLATIONS=OFF
   -DWITH_LTO=OFF
   -DWITH_TESTS=OFF
   ```
6. `ninja -j$(nproc)`.
7. `fakeroot ninja package` → CPack `DEB` → `veyon_<ver>_<arch>.deb`.
8. Verificación: `dpkg -i`, `apt-get install -f`, `veyon-cli about`.

### 1.4 Dependencias de build en el contenedor

```
build-essential cmake ninja-build git fakeroot dpkg-dev
pkg-config xorg-dev libx11-dev
qtbase5-dev qtbase5-private-dev
libqca-qt5-2-dev libqca-qt5-2-plugins
libssl-dev libpam0g-dev zlib1g-dev libpng-dev libjpeg-dev liblzo2-dev
libldap-dev libsasl2-dev libproc2-dev libfakekey-dev
libxkbcommon-x11-dev libxcb-xinput-dev libxcb1-dev
file xz-utils
```

### 1.5 Despliegue

`roles/instalar-veyon/tasks/main.yml` copia `package/{{ version_paquete }}` a
`/tmp/veyon.deb` en cada host y lo instala con `ansible.builtin.apt`.
`vars/main.yml` fija `version_paquete: veyon_4.11.2.7_amd64.deb`.

### 1.6 Resumen: el build es 100 % Linux

El build no usa ninguna abstracción de plataforma: es un `apt` + `cmake` +
`CPack/DEB` + `dpkg` dentro de una imagen Debian. macOS no tiene `apt`, ni
`dpkg`/`fakeroot`, ni `systemd`, ni `X11` como obligatorio, ni `libproc2`,
ni `PAM` con la misma API.

---

## 2. Estado real de Veyon respecto a macOS

### 2.1 Lo que ya existe en upstream

| Pieza | Estado |
|---|---|
| `CMakeLists.txt:109` `if(APPLE) set(VEYON_BUILD_APPLE 1)` | **Variable declarada pero nunca usada.** No hay `add_subdirectory(macos)` en ningún sitio. |
| `cmake/CPackDefinitions.cmake:92` `elseif(CMAKE_SYSTEM_NAME MATCHES "Darwin")` → `CPACK_GENERATOR "PackageMake"` | **Rama muerta** (ver más abajo). |
| `cmake/modules/FindLdap.cmake:65` `if(APPLE)` → busca `LDAP` en `/System/Library/Frameworks` | Rango heredado de kldap; irrelevante con `openldap` de Homebrew. |
| `3rdparty/x11vnc/src/macosx*.c` (macosx.c, macosxCG.c, macosxCGP.c, macosxCGS.c, macosx_opengl.c) | Código de captura de pantalla **nativo de macOS** (Carbon/CoreGraphics) presente en el submodule de x11vnc. Está compilado en el plugin `x11vnc-builtin` pero **guardado por `#if defined(HAVE_MACOSX_NATIVE_DISPLAY)`**, que nunca se define. |
| `core/src/VncView.cpp`, `core/src/LockWidget.cpp`, `core/src/Configuration/LocalStore.cpp`, `cli/src/main.cpp` | Usan `Q_OS_LINUX` / `Q_OS_WIN` — tienen rama `#else` genérica que **ya es válida en macOS**. |

Histórico: `git log --all` muestra que en las ramas antiguas (1.0) existió
`ica/x11/x11vnc/macosx.c`. Nunca existió un plugin de plataforma macOS.

### 2.2 Lo que falta (bloqueantes)

#### B1 — No existe plugin de plataforma macOS → `qFatal` en tiempo de ejecución

`core/src/PlatformPluginManager.cpp:46`:

```cpp
if( m_platformPlugin == nullptr )
{
    qFatal( "PlatformPluginManager: no platform plugin available!" );
}
```

`plugins/platform/CMakeLists.txt` solo construye `windows` y `linux`.
Sin un plugin `*-platform`, **todos** los binarios (`veyon-master`,
`veyon-cli`, `veyon-configurator`, `veyon-server`, `veyon-worker`) abortan al
arrancar. Este es el bloqueante nº1.

La interfaz a implementar (`core/src/Platform*Functions.h`) suma **~40 métodos
virtuales puros** en 7 clases:

| Interfaz | Métodos | Observaciones |
|---|---|---|
| `PlatformCoreFunctions` | 17 | `reboot`, `powerDown`, `raiseWindow`, `disableScreenSaver`, `setSystemUiState`, `isRunningAsAdmin`, `runProgramAsAdmin`, `runProgramAsUser`, `queryDisplayDeviceName`… |
| `PlatformFilesystemFunctions` | 7 | `openFileSafely`, `setFileOwnerGroup`, `findFileLockingProcess` |
| `PlatformInputDeviceFunctions` | 3 | `enable/disableInputDevices`, `createKeyboardShortcutTrapper` |
| `PlatformNetworkFunctions` | 4 | `ping`, `configureFirewallException`, `configureSocketKeepalive` |
| `PlatformServiceFunctions` | 8 | `runAsService`, `install/uninstall`, `setStartMode` |
| `PlatformSessionFunctions` | 8 | `currentSessionId`, `currentSessionUptime`, `currentSessionHostName`… |
| `PlatformUserFunctions` | 7 | `userGroups`, `prepareLogon`, `performLogon`, `logoff`, `authenticate` |

La implementación Linux existente (`plugins/platform/linux/`) son **5.489
líneas** y dependen de: systemd, D-Bus (KDE/GNOME/MATE/XFCE), `libproc2`,
PAM, X11/XTest, `libfakekey`, `/proc`. Nada de eso es portable.

#### B2 — Falta un backend de captura de pantalla en macOS

El servidor VNC en Linux usa:
- `x11vnc-builtin` (captura X11 vía XGetImage) → solo Linux.
- `pipewire` (portal XDG) → solo Linux.
- `headless` → framebuffer vacío de 640x480 (no sirve para monitorizar).
- `external` → delega en un VNC externo.

En macOS no hay ninguna opción real. **Sin captura de pantalla no hay
monitorización**, que es la función principal de Veyon.

La pieza que falta: un backend de captura a nivel CoreGraphics
(`CGDisplayCreateImage` / `CGWindowListCreateImage` / `ScreenCaptureKit`).
Existe código histórico reutilizable en `3rdparty/x11vnc/src/macosxCG.c` y
`macosxCGS.c` (Carbon, obsoleto desde 10.8 pero el pattern sirve de guía),
y `macosx_opengl.c` (OpenGL capture). Alternativa moderna y con soporte de
multi-monitor: **ScreenCaptureKit** (macOS 12.3+), mucho más limpio que
CoreGraphics para streaming.

#### B3 — Inyección de eventos de entrada

`LinuxInputDeviceFunctions` usa XTest + `libfakekey` (uinput).
En macOS el equivalente es:
- `CGEventCreateKeyboardEvent` / `CGEventPost` (sintético, no necesita permisos).
- `CGEventCreateScrollWheelEvent`.
- `CGRequestScreenCaptureAccess` / `CGPreflightScreenCaptureAccess` (permisos).

Ojo: desde macOS 10.15 (Catalina) capturar pantalla requiere **Screen
Recording** permission; desde 10.14 la inyección de teclado requiere
**Accessibility** permission. Esto **no** se puede eludir con un `.app`
firmado y notarizado: el usuario debe conceder permisos en
Ajustes del Sistema → Privacidad y seguridad. Esto es una diferencia
**de producto** respecto a Linux, no un problema de compilación, y hay que
documentarlo.

#### B4 — Sistema de servicios / sesión

- `veyon-service` en Linux es un servicio systemd (`veyon.service.in`).
  En macOS lo natural es **launchd** (`com.veyon.veyon-service.plist`).
- `LinuxSessionFunctions` (525 líneas) consulta systemd-logind, ConsoleKit,
  GNOME/KDE session managers. En macOS: `SCDynamicStore`, `NSWorkspace`,
  `libproc`, `utmpx`, `IOKit`.
- `LinuxServiceFunctions::runAsService` ejecuta el entry point directamente
  (solo funciona porque systemd lo lanza). En macOS hay que distinguir
  "lanzado por launchd" (dentro del contexto de `launchd`) vs "ejecutado en
  primer plano" — el patrón habitual es un binario helper que hace `fork()` +
  setsid + IPC, o `SMAppService` (macOS 13+).

#### B5 — `xdg_install` / `.desktop` / polkit

`master/CMakeLists.txt` y `configurator/CMakeLists.txt` instalan ficheros
`.desktop` + iconos XDG solo si `VEYON_BUILD_LINUX`. En macOS hay que generar
un bundle `.app` con `Info.plist` y un icono `.icns`.

#### B6 — Detalles de CMake que rompen en macOS

| Fichero | Problema | Solución |
|---|---|---|
| `cmake/modules/SetDefaultTargetProperties.cmake:33` | `set_target_properties(... LINK_FLAGS "-Wl,-no-undefined")` | **El linker de macOS (ld64) no soporta `-no-undefined`** → error de link. Hay que condicionar a `if(NOT APPLE)`. |
| `cmake/modules/SetDefaultTargetProperties.cmake:25` | `-flto=${CPU_COUNT} -fno-fat-lto-objects` con GCC | En macOS el compilador es Clang → ya hay una rama `else()` que usa `INTERPROCEDURAL_OPTIMIZATION`, pero `WITH_LTO=ON` en Clang con CMake ≥ 3.9 funciona; conviene `WITH_LTO=OFF` en la primera iteración. |
| `cmake/modules/CPackDefinitions.cmake:92` | Rama Darwin → `CPACK_GENERATOR "PackageMake"` | **Es un bug latente**: la rama Darwin está *antes* de la detección de Debian, así que en macOS nunca se generan `.deb`. Y `PackageMake` requiere un `Makefile` de `package/` que no existe. Hay que escribir la rama macOS (DragNDrop / TGZ). |
| `CMakeLists.txt:113` | `if(UNIX AND NOT ANDROID) set(VEYON_BUILD_LINUX 1)` | En macOS `UNIX` es `True` → `VEYON_BUILD_LINUX=1` **y** `VEYON_BUILD_APPLE=1`. Varios `if(VEYON_BUILD_LINUX)` se activarían en macOS (plugin de plataforma Linux, x11vnc, pipewire, `xdg_install`, servicio systemd). **Hay que corregir a `if(UNIX AND NOT ANDROID AND NOT APPLE)`.** |
| `core/src/PluginManager.cpp:65,72` | `loadPlugins("*-platform" + VeyonCore::sharedLibrarySuffix())` | `VEYON_SHARED_LIBRARY_SUFFIX` = `CMAKE_SHARED_LIBRARY_SUFFIX` = **`.dylib`** en macOS, pero los plugins se construyen con `add_library(... MODULE ...)` → en macOS CMake produce **`.so`** (verificado: `CMAKE_SHARED_MODULE_SUFFIX=.so`). **El cargador de plugins no encontraría ningún plugin → `qFatal` de nuevo.** Hay que usar `CMAKE_SHARED_MODULE_SUFFIX` para plugins y `CMAKE_SHARED_LIBRARY_SUFFIX` para la lib `veyon-core`. |
| `core/src/VeyonCore.cpp:164` `pluginDir()` | `VEYON_PLUGIN_DIR` = `"../${VEYON_LIB_DIR}"` (relativo al binario) | En un bundle `.app` hay que usar `Contents/MacOS/../PlugIns` o `Contents/Resources`. |
| `core/src/VeyonCore.cpp:171` `translationsDirectory()` | `applicationDirPath() + VEYON_TRANSLATIONS_DIR` | Rutas relativas OK en bundle, pero conviene absoluto. |
| `cmake/modules/FindLdap.cmake` | Rama `if(APPLE)` busca `LDAP` en `/System/Library/Frameworks` | Con `openldap` de Homebrew hay que usar la ruta no-Apple (`find_library(Ldap_LIBRARIES NAMES ldap)`). Corregir la condición. |
| `plugins/ldap/kldap` (submodule) | `kldap` (Qt6/KF6) vs `kldap-qt5` | En macOS con Qt6 funciona `kldap`; con Qt5, `kldap-qt5`. El CMakeLists del proyecto ya selecciona por `WITH_QT6` — verificar. |

#### B7 — Dependencias de terceros en macOS

| Dependencia | Homebrew | Nota |
|---|---|---|
| Qt 6 | `brew install qt` (6.12.0) | Trae `qthttpserver` → el plugin `webapi` compila con `Qt6::HttpServer` (no hace falta el submodule `3rdparty/qthttpserver`). |
| QCA | `brew install qca` (2.3.12) | Necesario: `find_package(Qca-qt6 REQUIRED)`. Es la dependencia más delicada: QCA + macOS + `openssl@4` requiere que los plugins criptográficos se_REGISTER en `QCA::` — hay que verificar `qca-qt6-plugins` (Homebrew los instala en `$(brew --prefix)/lib/qca-qt6-plugins`). |
| libvncserver | `brew install libvncserver` (0.9.15) | Alternativa a `-DWITH_BUNDLED_LIBVNC=ON`. **Ojo**: el `FindLibVNCServer.cmake` del proyecto exige **≥ 0.9.14** → 0.9.15 cumple. |
| openldap | `brew install openldap` | + `cyrus-sasl` |
| lzo, libpng, jpeg-turbo, zlib, openssl@3 | ya presentes / `brew install` | |
| libfakekey | ✗ no existe | Solo lo usa el plugin de plataforma Linux → irrelevante en macOS. |
| libproc2 | ✗ no existe (macOS usa `libproc`) | Solo Linux. |

#### B8 — El paquete de salida

- macOS: no existe `.deb`; el formato es `.dmg` / `.pkg` / `.app` + `CPack`
  con generador `DragNDrop` o `TGZ`.
- El `roles/instalar-veyon` de Ansible (`ansible.builtin.apt` con `deb:`)
  **no** sirve para macOS → hace falta un rol nuevo (`instalar-veyon-macos`)
  con `ansible.builtin.dmg` / `command` / `homebrew_cask`, o simplemente
  distribuir el `.app` y usar `launchd`.

---

## 3. Veredicto

### ¿Se puede adaptar la compilación para macOS?

**Sí, pero no es un simple "cambiar el contenedor Docker".** Hay que
distinguir dos objetivos muy distintos:

| Objetivo | Dificultad | Descripción |
|---|---|---|
| **A. Compilar el *master* para macOS** (el profesor usa Veyon desde el Mac) | **Media** | `veyon-master` + `veyon-cli` + `veyon-configurator` son ~95 % Qt puro, sin X11, sin systemd, sin D-Bus de sesión. Solo falta un plugin de plataforma macOS *reducido* (funciones core, filesystem, network, user) + un backend de captura de pantalla. |
| **B. Compilar el *cliente/servidor* para macOS** (un Mac como alumno del aula) | **Alta** | Requiere además: captura de pantalla nativa (ScreenCaptureKit/CoreGraphics), inyección de eventos (CGEvent), servicio launchd, gestión de sesiones, permisos TCC, notarización y firma de código. |

**Recomendación: empezar por A** (macOS como *maestro*), porque:
- Es el caso de uso real de este repo (el profesor controla el aula; los
  alumnos son Kali).
- Desbloquea el 90 % del código sin tocar el core.
- Aporta un cliente VNC nativo en macOS para ver a los alumnos Kali, algo que
  hoy no existe (`veyon-master` es un cliente VNC completo, `VncView`).

**Y añadir el build de macOS como un *segundo objetivo* del Makefile**, no
sustituyendo al de Kali.

### Esfuerzo estimado

| Fase | Contenido | Esfuerzo |
|---|---|---|
| 0 | Baseline: que `cmake` configure en macOS sin errores | 0,5–1 día |
| 1 | Arreglar CMake multiplataforma (`SetDefaultTargetProperties`, `CPackDefinitions`, `VEYON_BUILD_LINUX`, sufijo de plugins) | 1 día |
| 2 | Plugin de plataforma macOS (mínimo viable) | 3–5 días |
| 3 | Backend de captura de pantalla (CoreGraphics o ScreenCaptureKit) | 3–5 días |
| 4 | Empaquetado `.app` / `.dmg` + `Info.plist` + iconos | 1–2 días |
| 5 | launchd + gestión de sesión | 2–3 días |
| 6 | Inyección de eventos + permisos TCC | 2–4 días |
| 7 | Notarización / firma / tests en hardware real | 2 días |

**Total para A: ~6–9 días. Para A+B: ~15–20 días.**

---

## 4. Plan detallado

### Fase 0 — Baseline: que CMake configure en macOS (0,5–1 día)

**Objetivo:** que `cmake` configure sin errores en macOS, aunque no compile
todo.

Tareas:
1. Crear `scripts/build-veyon-macos.sh` (equivalente macOS del script Linux,
   pero con `brew` en vez de `apt`).
2. Instalar deps:
   ```bash
   brew install cmake ninja qt qca libvncserver openldap cyrus-sasl \
                lzo libpng jpeg-turbo openssl@3 pkg-config
   ```
3. Configurar:
   ```bash
   cmake -S . -B build-macos -G Ninja \
     -DCMAKE_BUILD_TYPE=RelWithDebInfo \
     -DCMAKE_PREFIX_PATH="$(brew --prefix)" \
     -DCMAKE_OSX_DEPLOYMENT_TARGET="13.0" \
     -DWITH_QT6=ON \
     -DWITH_LTO=OFF \
     -DWITH_TRANSLATIONS=OFF \
     -DWITH_TESTS=OFF
   ```
4. **Smoke test** del subconjunto portable:
   ```bash
   ninja veyon-core veyon-cli
   ./cli/veyon-cli about
   ```

**Entregable:** `scripts/build-veyon-macos.sh` + log de los errores reales.

### Fase 1 — Arreglos de CMake multiplataforma (1 día)

Todos en el árbol `build/veyon` (o como parche en `scripts/`, aplicado en una
copia editable, siguiendo el patrón existente del `sed` de `-Werror`).

| # | Fichero | Cambio |
|---|---|---|
| 1.1 | `CMakeLists.txt:112` | `if(UNIX AND NOT ANDROID AND NOT APPLE)` → evita activar `VEYON_BUILD_LINUX` en macOS |
| 1.2 | `CMakeLists.txt` | `if(VEYON_BUILD_APPLE) add_subdirectory(plugins/platform/macos) endif()` |
| 1.3 | `cmake/modules/SetDefaultTargetProperties.cmake:33` | Envolver `-Wl,-no-undefined` en `if(NOT APPLE)` (ld64 no lo soporta) |
| 1.4 | `cmake/modules/CPackDefinitions.cmake:92` | Sustituir la rama `PackageMake` por `DragNDrop` + `CPACK_DMG_VOLUME_NAME`, `CPACK_DMG_FORMAT=UDZO` |
| 1.5 | `core/src/veyonconfig.h.in` | Añadir `VEYON_SHARED_MODULE_SUFFIX "@CMAKE_SHARED_MODULE_SUFFIX@"` |
| 1.6 | `core/src/VeyonCore.h/.cpp` | Añadir `sharedModuleSuffix()`; `PluginManager::loadPlatformPlugins()` debe filtrar por `*-platform` + **módulo** suffix, y `loadPlugins()` por el de librería |
| 1.7 | `cmake/modules/FindLdap.cmake:65` | Corregir la rama `if(APPLE)` (no buscar en `/System/Library/Frameworks` con Homebrew) |
| 1.8 | `core/src/Configuration/LocalStore.cpp:197` | `QSettings::NativeFormat` en macOS escribe en `~/Library/Preferences/...` — correcto, pero `SystemScope` escribe en `/Library/Preferences` y requiere permisos → considerar `QSettings::IniFormat` para el scope de sistema |

> **Verificado empíricamente (CMake 4.4.4, macOS):**
> `CMAKE_SHARED_LIBRARY_SUFFIX=.dylib`, `CMAKE_SHARED_MODULE_SUFFIX=.so`.
> Un `add_library(foo MODULE ...)` produce `libfoo.so` en macOS.
> ⇒ El filtro actual `"*-platform" + ".dylib"` **no encuentra nada** en macOS.

### Fase 2 — Plugin de plataforma macOS (3–5 días)

Nuevo directorio `plugins/platform/macos/` con las 7 interfaces.

**Interfaz y classe:**

```cpp
// MacOSPlatformPlugin.h
class MacOSPlatformPlugin : public QObject, public PlatformPluginInterface
{
    Q_OBJECT
    Q_INTERFACES(PlatformPluginInterface)
public:
    explicit MacOSPlatformPlugin(QObject* parent = nullptr);
    PlatformCoreFunctions& coreFunctions() override;
    PlatformFilesystemFunctions& filesystemFunctions() override;
    PlatformInputDeviceFunctions& inputDeviceFunctions() override;
    PlatformNetworkFunctions& networkFunctions() override;
    PlatformServiceFunctions& serviceFunctions() override;
    PlatformSessionFunctions& sessionFunctions() override;
    PlatformUserFunctions& userFunctions() override;
};
```

**Implementación por interfaz (mínimo viable para el *master*):**

| Interfaz | Implementación macOS propuesta |
|---|---|
| `CoreFunctions` | `raiseWindow` → `NSApplication activateIgnoringOtherApps` + `setLevel(NSFloatingWindowLevel)`; `disableScreenSaver` → `IOPMAssertionCreateWithName(kIOPMAssertionTypeNoDisplaySleep)`; `reboot`/`powerDown` → `osascript -e 'tell app "System Events" to shut down'` (o `shutdown -h now`); `isRunningAsAdmin` → `geteuid()==0`; `runProgramAsAdmin` → `osascript ... do shell script ... with administrator privileges`; `activeDesktopName` → `"macOS"`; `queryDisplayDeviceName` → `NSScreen.localizedName`; `getApplicationName` → `proc_pidpath` + `NSRunningApplication` |
| `FilesystemFunctions` | `personalAppDataPath` → `QStandardPaths::AppDataLocation`; `globalAppDataPath` → `/Library/Application Support/Veyon`; `openFileSafely` → `QFile` + `chmod`/`chown`; `findFileLockingProcess` → `lsof` |
| `InputDeviceFunctions` | `enable/disableInputDevices` → no-op o `CGAssociateMouseAndMouseCursorPosition`; `createKeyboardShortcutTrapper` → implementación Qt pura (`QShortcut`/`eventFilter`) reusando el patrón de `core/src/KeyboardShortcutTrapper.h` |
| `NetworkFunctions` | `ping` → `/sbin/ping -c1 -W <ms>`; `configureFirewallException` → no-op (el firewall de macOS lo gestiona `/usr/libexec/ApplicationFirewall/socketfilterfw`); `configureSocketKeepalive` → `setsockopt(SO_KEEPALIVE)`; `defaultRouteNetworkInterface` → `QNetworkInterface` (nativo en Qt) |
| `ServiceFunctions` | `runAsService` → detectar si estamos en el contexto de launchd (`getenv("XPC_SERVICE_NAME")`) y, si no, hacer `fork()`+`setsid()`+IPC; `install/uninstall` → escribir/eliminar el plist en `/Library/LaunchDaemons` + `launchctl bootstrap` |
| `SessionFunctions` | `currentSessionHostName` → `gethostname()`; `currentSessionUptime` → `sysctl(KERN_BOOTTIME)`; `currentSessionClientAddress` → `getpeername`/`SCDynamicStore`; `currentSessionType` → `"console"` |
| `UserFunctions` | `userGroups` → `dscl . -read /Groups` o `id -Gn`; `queryCurrentUserProperty` → `NSUserName()`, `NSFullUserName()`, `NSHomeDirectory()`; `prepareLogon/performLogon` → `launchctl asuser <uid>` + `su -l <user>`; `authenticate` → `dscl . -authonly` o `opendirectory` |

**Nota crítica sobre `PlatformSessionFunctions`:** la implementación Linux
(525 líneas) cubre GNOME/KDE/systemd/ConsoleKit. La versión macOS puede ser
**muy** simple (un solo usuario por máquina en la práctica), pero debe
implementar la interfaz completa porque es `= 0` puro.

**CMakeLists del plugin:**

```cmake
include(BuildVeyonPlugin)

build_veyon_plugin(macos-platform
    NAME MacOSPlatform
    SOURCES
    MacOSPlatformPlugin.cpp
    MacOSCoreFunctions.cpp
    MacOSFilesystemFunctions.cpp
    MacOSInputDeviceFunctions.cpp
    MacOSNetworkFunctions.cpp
    MacOSServiceFunctions.cpp
    MacOSSessionFunctions.cpp
    MacOSUserFunctions.cpp
    ../common/LogonHelper.cpp
    ../common/PersistentLogonCredentials.cpp
    )

target_link_libraries(macos-platform PRIVATE
    Qt${QT_MAJOR_VERSION}::Network
    ${CMAKE_DL_LIBS}
    "-framework AppKit"
    "-framework CoreGraphics"
    "-framework IOKit"
    "-framework ServiceManagement"
    )
```

### Fase 3 — Backend de captura de pantalla (3–5 días)

**Decisión clave: CoreGraphics vs ScreenCaptureKit.**

| | CoreGraphics (`CGDisplayCreateImage`) | ScreenCaptureKit |
|---|---|---|
| Época | 10.2+ | 12.3+ |
| Multimonitor | Sí, pero hay que componer a mano | Nativo (`SCContentFilter` multi-display) |
| Permisos | Screen Recording (10.15+) | Screen Recording (10.15+) |
| Curva de actualización | Manual (timer) | Nativa, por cambios |
| Rendimiento | OK a 30 fps | Mejor |
| API | C, síncrona | Async/Swift-friendly (ObjC++) |

**Recomendación: ScreenCaptureKit** si se exige macOS 13+; si hay que
soportar 12.0, CoreGraphics como *fallback*.

**Integración en Veyon:** el backend debe implementarse como un **nuevo
plugin `vncserver`** (p. ej. `plugins/vncserver/macos-builtin/`) siguiendo el
modelo de `plugins/vncserver/headless/HeadlessVncServer.cpp`, que ya usa
`rfbGetScreen()` / `rfbInitServer()` de libvncserver y solo difiere en cómo
llena el framebuffer:

```cpp
// MacOSVncServer.cpp — esqueleto
void MacOSVncServer::captureFrame()
{
    // 1) SCStream o CGDisplayCreateImage → QImage (convertir BGRA→RGBA)
    // 2) copiar a rfbScreen->frameBuffer
    // 3) rfbMarkRectAsModified( rfbScreen, 0, 0, w, h );
}
```

Alternativa más rápida si el tiempo aprieta: usar el **`external-vnc-server`**
ya existente en el proyecto, que delega la captura en un VNC server externo
macOS (p. ej. `macvnc`/`yabai`/`screensharingd`). Es un *workaround* de
48 horas que da el 100 % de la funcionalidad de monitorización sin escribir
una línea de ScreenCaptureKit, y es un buen paso intermedio para validar
todo lo demás (plugin de plataforma, empaquetado, etc.).

**Permisos TCC (obligatorio documentar):**
- `NSScreenCaptureUsageDescription` en `Info.plist`.
- `CGPreflightScreenCaptureAccess()` / `CGRequestScreenCaptureAccess()`.
- El usuario debe aprobar en *Ajustes del Sistema → Privacidad y seguridad →
  Grabación de pantalla*.
- AlDistribution vía Homebrew (`brew install --cask`) evita el problema de
  "no se puede abrir porque el desarrollador no está verificado" (quarantine
  attribute); un `.dmg` firmado + notarizado lo evita del todo.

### Fase 4 — Empaquetado macOS (1–2 días)

1. **Bundle `.app`:** con `install(FILES ...)` + un `Info.plist` generado por
   CMake, o mejor con `MACOSX_BUNDLE`:
   ```cmake
   set_target_properties(veyon-master PROPERTIES
       MACOSX_BUNDLE TRUE
       MACOSX_BUNDLE_BUNDLE_NAME "Veyon Master"
       MACOSX_BUNDLE_GUI_IDENTIFIER "io.veyon.veyon-master"
       MACOSX_BUNDLE_ICON_FILE "veyon-master.icns"
       MACOSX_BUNDLE_BUNDLE_VERSION "${VERSION_MAJOR}.${VERSION_MINOR}.${VERSION_PATCH}"
       )
   ```
   - `veyon-master` y `veyon-configurator` → `MACOSX_BUNDLE TRUE` (GUI).
   - `veyon-cli`, `veyon-server`, `veyon-worker` → sin bundle (consola).
2. **Iconos `.icns`:** los `.svg`/`.xpm`/`.png` que hay no sirven; hay que
   generar `.icns` con `iconutil` a partir de un `.iconset`.
3. **Plugins dentro del bundle:** `Contents/MacOS/../PlugIns` → hay que
   redefinir `VEYON_PLUGIN_DIR` para Apple:
   ```cmake
   if(APPLE)
       set(VEYON_PLUGIN_DIR "../PlugIns")
       set(VEYON_INSTALL_PLUGIN_DIR "PlugIns")
   endif()
   ```
4. **Traducciones:** `Contents/Resources/translations`.
5. **CPack:** generador `DragNDrop` → `.dmg`; o `TGZ` → `.tar.gz` con un
   `postinstall` que copie a `/Applications`.
6. **Firma y notarización** (opcional pero recomendado para evitar el
   quarantine):
   ```bash
   codesign --deep --force --options runtime --sign "Developer ID Application: ..." Veyon.app
   xcrun notarytool submit Veyon.dmg --keychain-profile "AC_PROFILE" --wait
   xcrun stapler staple Veyon.dmg
   ```

### Fase 5 — launchd y sesiones (2–3 días)

`launchd` en lugar de systemd:

```xml
<!-- com.veyon.veyon-service.plist -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>            <string>io.veyon.veyon-service</string>
    <key>ProgramArguments</key> <array><string>/usr/local/bin/veyon-service</string></array>
    <key>RunAtLoad</key>        <true/>
    <key>KeepAlive</key>        <true/>
    <key>UserName</key>         <string>root</string>
    <key>ProcessType</key>      <string>Interactive</string>
</dict>
</plist>
```

- Instalación: `cp com.veyon.veyon-service.plist /Library/LaunchDaemons/` +
  `launchctl bootstrap system /Library/LaunchDaemons/com.veyon.veyon-service.plist`.
- Equivalente moderno (macOS 13+): `SMAppService` (solo para apps del
  *App Store* signed; no apto aquí) → usar `launchctl` directamente.
- `veyon-service` debe distinguir "soy el proceso de launchd" de "ejecutado a
  mano" (patrón de `launchd`: el helper hace `fork()`, cierra fds, y el padre
  envía el resultado por un socket Unix).

### Fase 6 — Entrada y permisos (2–4 días)

- `CGEventCreateKeyboardEvent` + `CGEventPost(kCGHIDEventTap)` para teclado.
- `CGEventCreateMouseEvent` para ratón.
- `CGEventTapCreate` para capturar teclado (interceptar Alt-Tab).
- Permisos: *Accessibility* (kTCCServiceAccessibility) para inyección de
  eventos; *Screen Recording* para captura.
- `com.apple.security.*` entitlements (para una app firmada y distribuida
  fuera del Mac App Store):
  ```
  com.apple.security.device.camera        (no)
  com.apple.security.automation.apple-events
  com.apple.security.device.audio-input   (no)
  com.apple.security.cs.allow-unsigned-executable-memory
  com.apple.security.cs.disable-library-validation
  ```

### Fase 7 — Integración en el repositorio `veyon-kali` (1 día)

**`Makefile`:**

```make
SRC      := ./build/veyon
OUT      := ./package
MACOUT   := ./package/macos
IMAGE    ?= kalilinux/kali-rolling

## macOS: compila Veyon para el host macOS (arm64)
macos:
	@mkdir -p $(MACOUT)
	@bash scripts/build-veyon-macos.sh "$(SRC)" "$(MACOUT)"

## macOS + Kali: ambos
all: macos arm64 amd64
```

**Nuevo `scripts/build-veyon-macos.sh`:**

```bash
#!/bin/bash
set -euo pipefail
SRC="${1:-/src}"; OUT="${2:-/out}"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cp -a "$SRC/." "$WORK/"

cd "$WORK"
git submodule update --init --recursive || true

# Arreglos de CMake para macOS (aplicados sobre la copia, no sobre el host)
# ... sed/patch de SetDefaultTargetProperties.cmake, CPackDefinitions.cmake, etc.

cmake -S "$WORK" -B "$WORK/build" -G Ninja \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_PREFIX_PATH="$(brew --prefix)" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
  -DWITH_QT6=ON -DWITH_LTO=OFF -DWITH_TRANSLATIONS=ON -DWITH_TESTS=OFF

cmake --build "$WORK/build" -j "$(sysctl -n hw.ncpu)"
cmake --build "$WORK/build" --target package
cp "$WORK"/build/*.dmg "$OUT"/
```

**Nuevo rol Ansible `roles/instalar-veyon-macos/tasks/main.yml`:**

```yaml
---
- name: Copiar el paquete DMG
  ansible.builtin.copy:
    src: "package/macos/{{ version_paquete_macos }}"
    dest: /tmp/veyon.dmg
    mode: '0644'

- name: Montar el DMG
  ansible.builtin.command:
    cmd: hdiutil attach /tmp/veyon.dmg -nobrowse -mountpoint /tmp/veyon-mount
  changed_when: false

- name: Copiar la aplicación a /Applications
  ansible.builtin.copy:
    src: /tmp/veyon-mount/Veyon.app
    dest: /Applications/
    # cp con -R para preservar el bundle
  delegate_to: localhost   # <- si el master es el propio Mac

- name: Desmontar el DMG
  ansible.builtin.command:
    cmd: hdiutil detach /tmp/veyon-mount
  changed_when: false
```

> Nota: el `playbook.yml` actual despliega el `.deb` en el **profesor** y los
> **alumnos**. Si el profesor pasa a usar macOS, el grupo `profesor` debe
> apuntar al Mac y usar el rol nuevo. Si el profesor sigue en Kali, el build
> de macOS es opcional (un `.app` adicional para el profesor).

### Fase 8 — Documentación (0,5 día)

- Nuevo `COMPILE_MACOS.md` (simétrico a `COMPILE_DEB_KALI_DOCKER.md`).
- Sección en `README.md` sobre requisitos TCC y el flujo de instalación.
- Actualizar `COMPILE_DEB_KALI_DOCKER.md` si se toca `scripts/build-veyon.sh`
  (no debería).

---

## 5. Riesgos y mitigaciones

| # | Riesgo | Impacto | Mitigación |
|---|---|---|---|
| R1 | **Permisos TCC** (Screen Recording / Accessibility) no se pueden automatizar | Alto | El usuario debe concederlos manualmente. Documentar + `CGRequestScreenCaptureAccess()` con diálogo. Usar `external-vnc-server` como workaround inicial. |
| R2 | QCA en macOS no encuentra los plugins (afecta a criptografía/auth) | Alto | Verificar `qca-qt6-plugins` de Homebrew y `QCA::` en runtime. Alternativa: `WITH_QT6=OFF` + `qca` de Homebrew (2.3.12) que ya trae `qca-qt5-plugins`. |
| R3 | El sufijo `.dylib` vs `.so` rompe la carga de plugins | Alto | Fase 1.6 (verificado empíricamente). |
| R4 | `-Wl,-no-undefined` rompe el link en macOS | Alto | Fase 1.3 (verificado empíricamente con `ld`). |
| R5 | `VEYON_BUILD_LINUX` se activa en macOS y compila el plugin Linux (X11/proc2) | Alto | Fase 1.1. |
| R6 | Apple Silicon: `arm64` nativo, pero sin Rosetta para `x86_64` | Bajo | Compilar solo `arm64`; no hace falta universal. |
| R7 | Notarización rechazada por usar APIs privadas | Medio | Evitar APIs privadas; `ScreenCaptureKit` es público desde 12.3. |
| R8 | CMake 4.x rompe con `cmake_minimum_required(VERSION 3.10)` de los submodules | Medio | CMake local es 4.4.4 → `libvncserver` (3.10), `ultravnc` (3.10), `qthttpserver` (3.15) fallan. **Fijar `cmake_policy(VERSION 3.x)` o usar un CMake ≤ 3.31 mientras tanto.** Verificar. |
| R9 | El árbol de Veyon upstream no acepta los parches (upstream no tiene soporte macOS) | Medio | Mantener los parches en `scripts/` (copia + `patch`) en vez de editar `build/veyon` directamente. El patrón `cp -a` + `sed` ya existe en `build-veyon.sh` → reutilizarlo. |
| R10 | Qca-qt6 `Core5Compat` no está en Homebrew `qt` | Bajo | `qt5compat` es dependencia de `qt` en Homebrew → está. |

---

## 6. Enfoque recomendado (iterativo, con hitos verificables)

```
Hito 1  ──►  cmake configure OK en macOS + `veyon-cli about` funciona
             (plugin de plataforma stub que devuelve valores por defecto)
Hito 2  ──►  `veyon-master` arranca, lista un host de prueba, se conecta
             (sin imagen todavía)
Hito 3  ──►  Captura de pantalla real (CoreGraphics o SCK) → miniaturas
             correctas en el master
Hito 4  ──►  Control remoto (teclado + ratón) → Control+V sobre un Mac
Hito 5  ──►  Empaquetado: `.app` + `.dmg` instalado y ejecutable en un Mac
             limpio
Hito 6  ──►  launchd + autoinicio + `veyon-service` como "servidor"
Hito 7  ──►  Integración en `veyon-kali` (Makefile + Ansible) y docs
```

Cada hito es verificable de forma independiente y se puede abandonar sin
perder trabajo.

**Estrategia de riesgo principal:** empezar por el **workaround de
`external-vnc-server`** (Hito 2 → 3 acelerados) y sólo invertir en
ScreenCaptureKit cuando el resto del pipeline esté sólido.

---

## 7. Resumen ejecutivo

1. **El build actual es 100 % Linux** (apt + dpkg/fakeroot + CPack/DEB +
   systemd + X11 + D-Bus de sesión). No hay ninguna abstracción multiplataforma
   en el pipeline de build.

2. **Upstream Veyon no soporta macOS**: existe la *flag* `VEYON_BUILD_APPLE`
   y código histórico de x11vnc para macOS, pero **no hay plugin de
   plataforma**, y sin él todos los binarios hacen `qFatal` al arrancar.

3. **Se puede adaptar**, pero es un trabajo de desarrollo de plataforma
   (plugin de plataforma + backend de pantalla + launchd + empaquetado), no
   una simple adaptación del script de build.

4. **Vía rápida (recomendada)**: compilar el *master* para macOS
   (`veyon-master` + `veyon-cli` + `veyon-configurator`) como objetivo
   adicional del `Makefile`. El master es ~95 % Qt puro; el trabajo real está
   en el plugin de plataforma (~40 métodos) y en la captura de pantalla.

5. **Empaquetado**: sustituir el `.deb` por `.dmg`/`.app`; el rol de Ansible
   `instalar-veyon` (basado en `apt`) no aplica → rol nuevo.

6. **Diferencia de producto inevitable**: los permisos TCC (Screen Recording
   y Accessibility) requieren intervención manual del usuario final, algo que
   en Linux no existe. Debe documentarse desde el principio.

---

## 8. Estado real de implementación (actualizado 2026-10-21)

Lo que sigue describe **lo que ya está hecho y verificado**, no lo planificado.

### 8.1 Resultado

| Objetivo | Estado | Verificación |
|---|---|---|
| Configure de CMake en macOS | ✅ Funcional | `cmake -S . -B build -G Ninja` sin errores |
| Build completo (Qt 6.12, arm64) | ✅ Funcional | ~35 s desde cero con Ninja |
| `veyon-cli` / `veyon-master` / `veyon-configurator` | ✅ Funcional | ventana "Veyon Logon" abierta en macOS |
| Plugin de plataforma macOS | ✅ Funcional | `MacOSPlatformPlugin` cargado, 15 plugins |
| Bundle `Veyon.app` | ✅ Funcional | se ejecuta **sin `DYLD_LIBRARY_PATH`** |
| Bundle autosuficiente | ✅ Funcional | **0 referencias** a Homebrew en runtime y en `otool -L` |
| Disco `Veyon-4.11.2.dmg` | ✅ Funcional | contiene bundle + symlink a `/Applications` |
| Build Kali `arm64` | ✅ Intacto | `veyon_4.11.2.0_arm64.deb` generado y validado |

### 8.2 Estructura añadida al repositorio

```
veyon-kali/
├── patches/                                  # 16 parches, se aplican en orden
│   ├── 0001-cmake-exclude-linux-build-on-apple.patch
│   ├── 0002-cmake-findldap-macos-homebrew.patch
│   ├── 0003-cmake-findsasl2-macos-homebrew.patch
│   ├── 0004-ldap-include-sasl2-dir.patch
│   ├── 0005-cmake-qt-nodiscard-file-open.patch
│   ├── 0006-cmake-no-undefined-ld-flag-on-apple.patch
│   ├── 0007-core-vncserverprotocol-format-truncation.patch
│   ├── 0008-core-pch-stack-protector-collision.patch
│   ├── 0009-core-plugin-module-suffix.patch
│   ├── 0010-platform-add-macos-plugin.patch
│   ├── 0011-platform-add-macos-platform-plugin.patch
│   ├── 0012-core-logger-macos-symlink-logpath.patch
│   ├── 0014-cmake-macos-bundle-target.patch
│   ├── 0015-cmake-copy-plugins-to-bundle.patch
│   ├── 0016-cmake-macos-info-plist.patch
│   └── 0017-core-register-plugin-library-path-before-qca.patch
├── scripts/
│   ├── build-veyon.sh          # sin cambios (Kali)
│   ├── build-veyon-macos.sh    # NUEVO: build nativo macOS
│   ├── deploy-veyon-macos.sh   # NUEVO: bundle autosuficiente
│   └── package-veyon-macos.sh  # NUEVO: bundle .app → DMG
└── build/veyon-macos/          # workspace editable (generado, no versionado)
```

El checkout upstream en `build/veyon` **permanece intacto**: todo cambio vive en
los parches, que se aplican sobre una copia en `build/veyon-macos`.

### 8.3 Uso

```sh
# Build completo + bundle + DMG
make macos

# Solo build (sin empaquetar)
./scripts/build-veyon-macos.sh --no-package

# Solo configure
./scripts/build-veyon-macos.sh --no-build

# Limpiar el workspace
make macos-clean

# Reempaquetar el bundle existente
make macos-package
```

Resultados:

```
build/veyon-macos/build/Veyon.app          # bundle
build/veyon-macos/build/Veyon-4.11.2.dmg    # disco instalable
build/veyon-macos/build/stage/              # ejecutables con rpath de desarrollo
```

### 8.4 Dependencias Homebrew

```sh
brew install cmake ninja \
            qtbase qttools qtshadertools qttranslations qt5compat qthttpserver \
            qca libvncserver openldap cyrus-sasl
```

Se evita el metaformula `qt` porque arrastra WebEngine y decenas de
dependencias innecesarias.

### 8.5 Bloqueantes de código resueltos

| Síntoma | Causa | Resolución |
|---|---|---|
| `Could NOT find Ldap` | `LDAP.framework` del SDK enrutado por CMake | `FindLdap.cmake` busca OpenLDAP de Homebrew en Apple (parche 0002) |
| `sasl_client_init is deprecated` | SASL obsoleto del SDK | `FindSasl2.cmake` prefiere el keg de Homebrew (parche 0003) |
| `ld: unknown options: -no-undefined` | flag GNU inexistente en `ld64` | se omite en Apple (parche 0006) |
| `using declaration refers into 'Base'` | PCH con Objective-C++ | `SKIP_PRECOMPILE_HEADERS` en los `.mm` |
| `QFile::open() [[nodiscard]]` | Qt 6.10+ con `-Werror` | `QT_NO_USE_NODISCARD_FILE_OPEN` (parche 0005) |
| `no platform plugin available!` | plugins CMake `MODULE` son `.so`, se buscaban `.dylib` | `VEYON_MODULE_LIBRARY_SUFFIX` (parche 0009) |
| `Log path ... is a symlink/junction` | `/var` es symlink a `/private/var` en macOS | se omite la comprobación en Apple (parche 0012) |
| `-Wformat-truncation` | buffer RFB de 13 bytes, envío de 12 | parche 0007 |
| PCH pierde `-fstack-protector-strong` | sobrescritura de `COMPILE_OPTIONS` | `target_compile_options` (parche 0008) |
| QCA carga los providers de Homebrew | ruta de plugins compilada en el framework de QCA | ruta neutralizada + `initLibraryPaths()` (parche 0017) |
| El bundle carga el *legacy provider* de OpenSSL de Homebrew | `MODULESDIR` compilado en `libcrypto` | directorio neutralizado en el despliegue |

### 8.6 Estado funcional del plugin macOS

| Área | Estado |
|---|---|
| Core | ✅ logging unificado, prevención de sleep (IOKit), reinicio, privilegios (AppleScript), `NSRunningApplication` |
| Filesystem | ✅ `Application Support`, ownership/perms POSIX, detección de bloqueos (`libproc`) |
| Input | ⚠️ `CGEventTap` para atajos; requiere permiso **Accessibility** |
| Network | ⚠️ keepalive TCP e interfaz por defecto; ping/firewall/velocidad en *stub* |
| Service | ⚠️ plist y `launchctl`; instalación aún no validada en un sistema real |
| Session | ⚠️ hostname, uptime, variables de entorno; CFPreferences en *stub* |
| User | ✅ grupos y autenticación Open Directory (`dscl -authonly`); logon/logoff gráfico no soportado |
| Captura de pantalla | ❌ sin backend nativo; `external-vnc-server` es la vía inicial |

### 8.7 Bundle autosuficiente

El bundle generado por `scripts/deploy-veyon-macos.sh` no depende de la
instalación de Homebrew en tiempo de ejecución. Las dos piezas que lo hacen
posible merecen detalle, porque no son obvias.

#### Carga de los providers de QCA

QCA compila en su framework la ruta en la que se instalaron sus plugins
(la macro `QCA_PLUGIN_PATH`) y la añade **siempre** a la lista de rutas que
explora, por encima de las que registra la aplicación:

```cpp
// qca_core.cpp (QCA::pluginPaths)
paths += QCoreApplication::libraryPaths();
paths << QDir(QStringLiteral(QCA_PLUGIN_PATH)).canonicalPath();
```

En el framework de Homebrew ese literal es
`/opt/homebrew/Cellar/qca/2.3.12_1/lib/qt/plugins`, codificado como
`QStringLiteral` (UTF-16LE) en la sección `__ustring`. Por eso el bundle
cargaba los providers de Homebrew —y con ellos una segunda copia de Qt— en
lugar de los suyos.

La solución tiene tres partes:

1. **Los providers van en `Contents/PlugIns/crypto`.** QCA busca en el
   subdirectorio `crypto` de cada ruta, no en la raíz.
2. **La ruta compilada se neutraliza.** Se sustituye el literal por una
   ruta inexistente conservando su longitud exacta (la longitud de un
   `QStringLiteral` está fijada en el código). `QDir::canonicalPath()`
   devuelve una cadena vacía para una ruta inexistente y QCA la descarta.
3. **La ruta del bundle se registra antes de que arranque QCA.** El
   `PluginManager` añadía `Contents/PlugIns` a las rutas de Qt *después* de
   que `CryptoCore` construyera QCA, que es cuando se escanean los
   providers. El parche 0017 añade `VeyonCore::initLibraryPaths()` antes de
   `initCryptoCore()`.

Resultado: los cuatro providers (`ossl`, `softstore`, `logger`,
`cyrus-sasl`) se cargan desde `Contents/PlugIns/crypto`.

#### Neutralización del directorio de módulos de OpenSSL

OpenSSL 4 compila en `libcrypto` la ruta de sus providers opcionales
(`MODULESDIR`) y carga automáticamente el *legacy provider* al
inicializarse. Esa ruta apuntaba a Homebrew. El *legacy provider* sólo
aporta algoritmos que Veyon no usa, así que la ruta se sustituye por una
inexistente y OpenSSL sigue funcionando con los providers que ya trae
incorporados.

#### Verificación

```sh
# El bundle se copia fuera del directorio de trabajo y se ejecuta con un
# entorno mínimo, sin Homebrew en el PATH.
cp -R build/veyon-macos/build/Veyon.app /tmp/veyon-reloc/
env -i HOME="$HOME" PATH=/usr/bin:/bin \
    DYLD_PRINT_LIBRARIES=1 \
    /tmp/veyon-reloc/Veyon.app/Contents/MacOS/veyon-cli plugin list \
    | grep -cE "Cellar|/opt/homebrew|/usr/local"
# -> 0
```

El mismo escaneo con `otool -L` sobre todos los binarios del bundle
(devuelve 0 referencias) y la ejecución desde el DMG montado confirman que
no queda ninguna dependencia externa.

### 8.8 Captura nativa con ScreenCaptureKit

El backend de captura nativa se implementa como un plugin VNC independiente
en `plugins/vncserver/screencapturekit/`, separado del plugin de plataforma.
De esta forma se puede sustituir el backend de captura sin acoplarlo al
resto del plugin de plataforma macOS.

| Fichero | Contenido |
| --- | --- |
| `ScreenCaptureKitCapturer.{h,mm}` | Propiedad de `SCStream` y conversión de frames |
| `ScreenCaptureKitVncServer.{h,cpp}` | Plugin VNC que alimenta el framebuffer libVNC |
| `ScreenCaptureKitConfiguration.h` | Ajustes del plugin (FPS, display, tamaño máximo) |
| `ScreenCaptureKitVncServerConfigurationWidget.{h,cpp,ui}` | Widget de configuración |

Decisiones de diseño:

- **Objective-C++ sin PCH ni *unity build***: los ficheros `.mm` se aíslan del
  resto para que las cabeceras de Qt y los frameworks de Apple no se
  procesen de forma conjunta.
- **MRC, no ARC**: el proyecto no compila con ARC, por lo que todos los
  objetos Objective-C, *dispatch queues* y *dispatch semaphores* se liberan
  explícitamente en todos los caminos de error.
- **Framebuffer `QImage::Format_RGB32`**: el formato BGRA de ScreenCaptureKit
  coincide con el *endianness* little-endian y con los *shifts* RGB que
  espera libVNC.
- **`kCVPixelFormatType_32BGRA`**: `SCStreamConfiguration.pixelFormat` es un
  `OSType` (*FourCC*), no admite un `CVPixelFormatRef` creado a mano.
- **Sin *precompiled headers* en `ScreenCaptureKitCapturer.mm`**: los
  *headers* de Objective-C++ se procesan de forma aislada.

#### Selección del backend y *fallback*

`SCShareableContent` solo expone los monitores **activos**. En un equipo sin
pantalla encendida, en una sesión remota o en modo *headless* la lista de
`SCDisplay` está vacía y la captura no puede establecerse.

Para que el servidor VNC siga funcionando en esos casos, se añadió el flag
`Plugin::PreferredDefaultImplementation`:

- `ScreenCaptureKitVncServer` se marca como implementación **preferida**: es
  la que se usa en macOS siempre que pueda arrancar.
- `HeadlessVncServer` conserva `ProvidesDefaultImplementation` y actúa de
  *fallback* portátil.
- `VncServer` conserva la lista de implementaciones por defecto restantes y
  las prueba cuando la preferida falla.

Comportamiento observado en un equipo con las pantallas en reposo:

```text
[ERR] ScreenCaptureKitCapturer: "No active display could be captured. ..."
[ERR] VncServer: An error occurred while running the VNC server plugin
[DEBUG] HeadlessVncServer::rfbLogDebug(): Listening for VNC connections on TCP port 11200
```

Los tres puertos (11100, 11200 y 11300) quedan escuchar y el protocolo
responde correctamente:

```text
$ printf '\x00' | nc -w 3 127.0.0.1 11100 | head -c 12
RFB 003.008
```

#### Limitación: la captura de todos los monitores

`SCContentFilter` captura **un** `SCDisplay` por *stream*. La opción
"capturar todos los monitores" usa hoy el primer `SCDisplay` disponible,
mientras que las dimensiones se calculan como la suma de las anchuras y la
altura máxima de todos ellos. La imagen resultante no corresponde con el
filtro aplicado.

Las opciones pendientes son:

1. Crear un `SCStream` por monitor y componer los *frames* en un framebuffer
   virtual (con el *cursor* de cada uno), o bien
2. Cambiar la semántica de la opción a "monitor principal" y Renombrar el
   ajuste en consecuencia.

### 8.9 Limitaciones conocidas

1. **TCC**: Screen Recording y Accessibility hay que concederlos manualmente.
2. **Sin firma ni notarización**: el bundle se firma *ad hoc*, lo que permite
   ejecutarlo localmente pero no distriburlo. Gatekeeper bloqueará la
   instalación en otros equipos hasta que se firme con Developer ID y se
   notarice.
3. **ScreenCaptureKit requiere un display activo**: en máquinas *headless* o
   con las pantallas en reposo el backend nativo no puede arrancar y se usa
   el *fallback* *headless*.
4. **"Todos los monitores" no está implementado**: el filtro y las
   dimensiones no son coherentes entre sí (ver 8.8).
5. **`hdiutil` está obsoleto**: `scripts/package-veyon-macos.sh` genera
   avisos de deprecación; el resultado es válido, pero debería migrarse a
   `diskutil`.

### 8.10 Siguientes pasos pendientes

1. Firmar y notarizar el bundle (`codesign`, `notarytool`).
2. Resolver la captura multi-monitor de ScreenCaptureKit (ver 8.8).
3. Completar los *stubs*: ping, firewall, velocidad de red, CFPreferences,
   logon/logoff.
4. Validar `veyon-service` como servicio launchd en un sistema real.
5. Crear el rol de Ansible `roles/instalar-veyon-macos` para el despliegue.
6. Migrar `scripts/package-veyon-macos.sh` de `hdiutil` a `diskutil`.
7. Validar la captura real en un equipo con la pantalla encendida y el
   permiso de Screen Recording concedido a `Veyon.app`.
