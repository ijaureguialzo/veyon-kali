# veyon-kali

Instalación de Veyon en un aula con Kali Linux.

## Compilar los paquetes

Los tres paquetes (`.deb` arm64, `.deb` amd64 y el bundle de macOS) se
construyen en local con `make`:

```shell
make all       # arm64 + amd64 + macOS
make arm64     # solo el .deb arm64
make amd64     # solo el .deb amd64
make macos     # solo el bundle y el DMG de macOS
make help      # lista los objetivos
```

La misma compilación se ejecuta en GitHub Actions
(`.github/workflows/build.yml`): cada `.deb` se compila en Docker con el
mismo Makefile, y el paquete de macOS en un runner macOS.  Los artefactos
se publican en cada ejecución y, al subir una etiqueta `v*`, se adjuntan
además a la release de GitHub.

## Prerrequisitos

### 1. Habilitar SSH en cada host

```shell
sudo systemctl start ssh.service
sudo systemctl enable ssh.service
```

### 2. Configurar el inventario

Copiar los archivos de ejemplo y rellenar los datos en cada uno de ellos:

```shell
cp inventory/hosts.ini.example inventory/hosts.ini
cp roles/configurar-profesor/files/ordenadores.csv.example roles/configurar-profesor/files/ordenadores.csv
cp vars/main.yml.example vars/main.yml
```

### 3. Copiar la clave SSH a todos los hosts

`make setup-ssh` recorre `inventory/hosts.ini`, extrae la dirección de
cada host y copia la clave pública (`~/.ssh/id_rsa.pub` por defecto)
para el usuario `ciber` a cada uno de ellos:

```shell
make setup-ssh
```

Para una copia totalmente automática, sin que te pida la contraseña,
pásala como variable `SSHPASS` (requiere [`sshpass`](https://github.com/stevej62/sshpass)):

```shell
SSHPASS='mi_password' make setup-ssh
```

También puedes cambiar el usuario o la clave:

```shell
make setup-ssh SSH_USER=ciber SSH_KEY=~/.ssh/id_ed25519.pub
```

## Lanzar el playbook

```shell
make apply
```

> Pedirá la contraseña del usuario para poder elevar privilegios y hacer la instalación.
