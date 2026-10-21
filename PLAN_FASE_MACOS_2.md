# Fase 2 de la adaptación a macOS

Estado: 2026-10-21. Objetivo: cerrar las cuatro líneas que quedaron
pendientes tras conseguir un bundle autosuficiente.

Las cuatro líneas son independientes entre sí, así que se pueden tacklear
y commitear por separado.

## Resumen del estado

| Línea | Estado | Commit |
|---|---|---|
| 1. Captura nativa con ScreenCaptureKit | **Implementada**, falta validarla en un equipo con display activo | `e42235a9` |
| 2. `veyon-service` como launchd real | **Implementada**, falta validar el LaunchDaemon con root | `6275ce14` |
| 3. Firma Developer ID y notarización | **Descartada** (requiere identidad de pago) | — |
| 4. Rol de Ansible `roles/instalar-veyon-macos` | **Descartada** (no se va a automatizar el despliegue) | — |

Los detalles de la línea 1 se encuentran en `ANALISIS_Y_PLAN_MACOS.md`,
sección 8.8.

## Línea 1 — Captura nativa con ScreenCaptureKit

### Situación actual

El backend de captura de pantalla es **responsabilidad del plugin de
servidor VNC**, no del plugin de plataforma. En upstream, cada sistema
operativo tiene su propio plugin en `plugins/vncserver/`:

| Sistema | Plugin | Técnica |
|---|---|---|
| Linux | `x11vnc-builtin` | X11 / XShm |
| Linux | `pipewire` | PipeWire |
| Windows | `ultravnc-builtin` | UltraVNC |
| todos | `external` | delega en un servidor VNC externo |
| todos | `headless` | framebuffer estático, sin captura |

En macOS no hay ningún plugin de captura. El que se usa es
`external-vnc-server`, que no captura nada por sí mismo: espera a que
otro programa (por ejemplo `x11vnc`, que no existe en macOS) haga el
trabajo. Es decir, **en macOS hoy no hay captura de pantalla**.

### Decisión de diseño

Implementar un plugin nuevo `plugins/vncserver/screencapturekit/` que:

1. Use `SCStream` (ScreenCaptureKit, macOS 13+) para obtener frames.
2. Mantenga un framebuffer `QImage` como el `HeadlessVncServer` hace, y lo
   actualice con `rfbMarkRectAsModified()`.

El plugin `headless` es el modelo más cercano: ya gestiona un
`rfbScreenInfoPtr` con un framebuffer propio y llama a
`rfbProcessEvents()`. La diferencia es que en lugar de un framebuffer
estático, el framebuffer se rellena con las capturas de pantalla.

Puntos a resolver:

- **Permisos TCC**: `SCShareableContent` requiere el permiso de
  *Screen Recording*. Sin él, `SCShareableContent.current` lanza una
  excepción. Hay que detectarlo y devolver un error claro en lugar de
  fallar en silencio.
- **Threading**: `SCStream` entrega los frames en un callback propio. El
  framebuffer de libVNC lo lee el hilo del servidor VNC. Hay que
  sincronizar con un mutex.
- **Escala y color**: `SCStreamConfiguration` permite fijar `width`,
  `height` y el formato de pixel. Conviene pedir `kCVPixelFormatType_32BGRA`
  para convertir a `QImage::Format_RGB32` (que es lo que espera libVNC
  con los shifts 16/8/0).
- **Multi-monitor**: `SCStream` puede capturar todos los displays con
  `configuration.capturesAudio = false` y
  `SCContentFilter(display:excludingWindows:)` por display, o el
  `SCContentFilter` de escritorio completo. La versión simple captura
  todos los monitores en una imagen combinada.
- **Degradación**: si `SCShareableContent` no está disponible (macOS
  < 13), hay que devolver un error claro.

### Plan de implementación

1. Crear `plugins/vncserver/screencapturekit/` con:
   - `ScreenCaptureKitVncServer.{h,cpp}` — el plugin.
   - `ScreenCaptureKitConfiguration.{h,cpp}` — configuración (fps, ancho,
     alto, capturar todos los monitores).
   - `ScreenCaptureKitVncServerConfigurationWidget.{h,cpp,ui}` — widget de
     configuración para el Configurator.
2. Reutilizar la estructura de `HeadlessVncServer` para el framebuffer y
   el ciclo `rfbProcessEvents()`.
3. Añadir el subdirectorio a `plugins/vncserver/CMakeLists.txt` con la
   condición `if(APPLE)`.
4. Registrarlo con `Plugin::ProvidesDefaultImplementation` para que sea el
   plugin por defecto en macOS.
5. Probarlo con `veyon-cli` / `veyon-master` y un cliente VNC.

### Dependencias

- `ScreenCaptureKit.framework`, `CoreMedia.framework`, `CoreVideo.framework`,
  `AVFoundation.framework` (para `CMSampleBuffer`).
- El target debe compilarse como Objective-C++.

## Línea 2 — `veyon-service` como launchd real

### Situación actual

`MacOSServiceFunctions::manageServerInstances()` está vacío, y
`runAsService()` invoca el entry point directamente. En Linux, el servicio
`veyon-service`:

1. Escucha en el login manager de systemd las sesiones de usuario.
2. Arranca un `veyon-server` por sesión, con el entorno de esa sesión.
3. Reinicia los servidores que se caen.

En macOS el equivalente es:

- `launchd` con un `LaunchDaemon` del sistema (`/Library/LaunchDaemons`).
- El daemon de sistema **no** tiene acceso al espacio de nombres gráfico
  del usuario. Para poder capturar la pantalla e inyectar teclado, el
  servidor debe correr **dentro de la sesión del usuario**.
- launchd ofrece `LaunchAgents` (`~/Library/LaunchAgents`) para servicios
  por usuario, que sí se lanzan en el namespace del usuario (Aqua session).
- El estándar en macOS es un `LaunchDaemon` del sistema que, al detectar
  un usuario en la sesión gráfica, lanza un `LaunchAgent` en su contexto
  mediante `launchctl asuser <uid> ...` o `launchctl bootstrap gui/<uid>`.

### Decisión de diseño

Implementar un modelo de dos niveles, que es el patrón canónico de macOS:

1. **`io.veyon.veyon-service` (LaunchDaemon, sistema)**
   - Se ejecuta como root.
   - Detecta el usuario de la sesión gráfica activa.
   - Para cada usuario detectado, lanza el agente de usuario.

2. **`io.veyon.veyon-server.<user>` (LaunchAgent, usuario)**
   - Se ejecuta dentro de la sesión Aqua del usuario.
   - Arranca `veyon-server` con el entorno del usuario.
   - launchd lo relanza si se cae (`KeepAlive`).

Para la detección del usuario de la sesión gráfica, las APIs de macOS son:

- `SCDynamicStoreCopyConsoleUser()` (de `SystemConfiguration.framework`) —
  devuelve el nombre del usuario de la sesión de consola.
- Alternativa sin dependencias adicionales: leer
  `/System/Library/CoreServices/loginwindow.plist` no es fiable. La forma
  canónica sin framework extra es `SCDynamicStoreCopyConsoleUser`.

Alternativamente, `scutil` o `stat /dev/console` (el propietario del device
`/dev/console` es el usuario de la sesión gráfica). `stat` sobre
`/dev/console` es simple y no requiere frameworks adicionales; es la
técnica que usa mucha documentación al respecto. Conviene usar
`SCDynamicStoreCopyConsoleUser` porque distingue entre la sesión de
consola y una sesión remota, y no requiere lanzar procesos.

El servicio debe:

- Actualizar la lista de sesiones cada cierto tiempo (o al recibir
  señales de `launchd`).
- Parar los servidores de las sesiones que desaparecen.
- Usar `ServiceDataManager` para compartir el token de datos del servicio
  con los servidores, igual que hace Linux.

### Plan de implementación

1. Crear `plugins/platform/macos/MacOSServiceCore.{h,cpp}`:
   - Sondaje periódico de la sesión de consola.
   - Arranque/parada de servidores por usuario.
2. Crear `plugins/platform/macos/MacOSServerProcess.{h,cpp}`:
   - Lanza `veyon-server` con el entorno del usuario.
   - Hereda de `QProcess`, como `LinuxServerProcess`.
3. `MacOSServiceFunctions::manageServerInstances()` instancia
   `MacOSServiceCore` y ejecuta el bucle.
4. `MacOSServiceFunctions::install()` debe generar un plist de LaunchDaemon
   válido:
   - `Label`, `ProgramArguments`, `RunAtLoad`, `KeepAlive`,
     `ProcessType` (Background, no Interactive), `SessionCreate` (para
     LaunchDaemons que lanzan procesos en la sesión del usuario).
   - Para el LaunchAgent: `LimitLoadToSessionType` = `Aqua`.
5. `MacOSServiceFunctions::runAsService()` debe funcionar tanto como
   LaunchDaemon (root) como cuando se invoca directamente.
6. Registrar el servicio en el bundle: `veyon-service` ya está en
   `Contents/MacOS/`.

### Validación

- Instalación real: copiar el bundle a `/Applications`, instalar el
  plist en `/Library/LaunchDaemons`, `launchctl bootstrap system`.
- Requiere `sudo`, que no está disponible en este entorno: se valida
  con un LaunchAgent de usuario (sin `sudo`) y con la comprobación
  sintáctica del plist del daemon.

## Línea 3 — Firma Developer ID y notarización

> **Descartada.** Requiere una identidad Developer ID de pago y un perfil
> de notarización. El bundle se mantiene firmado *ad hoc*, lo que permite
> ejecutarlo localmente pero impide distribuirlo en otros equipos.

### Situación actual

El bundle se firma **ad hoc** (`codesign --sign -`), lo que permite
ejecutarlo localmente pero no distribuirlo: Gatekeeper lo bloquea en
otros equipos.

### Decisión de diseño

Crear un script `scripts/sign-veyon-macos.sh` que:

1. **Firmado con Developer ID** de todos los binarios, en el orden
   correcto (bibliotecas → plugins → ejecutables → bundle), usando
   `--options runtime` (Hardened Runtime), que es obligatorio para
   notarizar.
2. **Notarización** con `xcrun notarytool submit` (o `altool` en
   versiones antiguas), y `xcrun stapler staple`.
3. El script debe funcionar en dos modos:
   - `--identity <nombre>`: firma con un certificado de Developer ID.
   - Sin identidad: mantiene el firmado ad hoc (para desarrollo).
4. Debe fallar con un mensaje claro si no hay credenciales de Apple
   (clave de API en el keychain, o `-p` / `-i` / `--apple-id`).

Consideraciones importantes:

- **Hardened Runtime** es obligatorio para la notarización. Con el
  hardened runtime activado, la captura de pantalla y la inyección de
  teclado requieren que el usuario conceda los permisos TCC; hay que
  documentarlo.
- El bundle no puede contener symlinks dentro de frameworks que rompan
  la firma. `codesign` los valida; el script debe detectar el fallo.
- `notarytool` requiere un Bundle ID registrado en el portal de
  desarrolladores de Apple; hay que documentarlo.
- Después de `stapler`, el ticket va dentro del bundle y el DMG se
  genera **después** de notarizar, o el DMG se notariza por separado.

### Variables de entorno

- `VEYON_SIGN_IDENTITY`: nombre de la identidad de firma.
- `VEYON_NOTARY_PROFILE`: perfil de `notarytool` (credenciales en el
  keychain).
- `VEYON_BUNDLE_ID`: bundle ID (por defecto `io.veyon.veyon`).

## Línea 4 — Rol de Ansible `roles/instalar-veyon-macos`

> **Descartada.** El despliegue en macOS se hace con
> `scripts/install-veyon-service-macos.sh`, sin automatizar con Ansible.

### Situación actual

`roles/instalar-veyon` copia un `.deb` y usa `ansible.builtin.apt`, que
sólo funciona en Debian. El inventario es de máquinas Kali.

El rol nuevo debe:

1. Copiar el `.app` o el `.dmg` al equipo destino.
2. Instalar la aplicación en `/Applications`.
3. Instalar el `LaunchDaemon` en `/Library/LaunchDaemons`.
4. Habilitar el arranque automático del servicio.
5. Configurar las claves de autenticación (reutilizando la lógica de
   `generar-claves` / `copiar-claves`).
6. Gestionar los permisos TCC.

### Puntos delicados

- **TCC no es automatizable por `sudo`**: los permisos de *Screen
  Recording* y *Accessibility* se conceden desde Preferencias del Sistema
  o mediante un **perfil de configuración** (`.mobileconfig` / PPPC
  profile) que se instala con `profiles install -type enrollment`.
  El rol debe instalar un perfil PPPC; sin él, la captura no funciona.
- `become` en macOS requiere que el usuario remoto esté en el grupo
  `admin`. Con `become: true` y `ansible_become_method: sudo`, funciona.
- El DMG se monta con `hdiutil attach`; hay que desmontarlo siempre.

### Plan

1. `roles/instalar-veyon-macos/tasks/main.yml`:
   - copiar el bundle,
   - instalarlo en `/Applications`,
   - instalar el plist del LaunchDaemon,
   - `launchctl bootstrap` / `enable`,
   - desinstalar versiones anteriores.
2. `roles/instalar-veyon-macos/defaults/main.yml`: rutas y variables.
3. `roles/instalar-veyon-macos/handlers/main.yml`: reinicio del servicio.
4. `roles/instalar-veyon-macos/files/`: plantilla del plist de launchd y
   del perfil PPPC.
5. Un playbook de ejemplo o una entrada condicional en `playbook.yml`
   para los hosts macOS.
6. `vars/main.yml`: variables nuevas (`version_paquete_macos`).

## Orden de ejecución

1. **Línea 2 (launchd)** — es la que más código toca y la que desbloquea
   el servicio real. *Hecho.*
2. **Línea 1 (ScreenCaptureKit)** — la parte más delicada; depende de
   TCC para validarse. *Hecho, pendiente de validación en un equipo con
   la pantalla encendida.*
3. **Línea 3 (firma)** — independiente; se puede hacer en cualquier
   momento. *Descartada.*
4. **Línea 4 (Ansible)** — depende de que 1, 2 y 3 estén cerrados para
   poder instalar y arrancar el servicio de verdad. *Descartada.*

Cada línea termina en un commit Conventional Commits.
