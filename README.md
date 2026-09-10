# veyon-kali

Instalación de Veyon en un aula con Kali Linux.

## Prerrequisitos

### 1. Habilitar SSH en cada host

```shell
sudo systemctl start ssh.service
sudo systemctl enable ssh.service
```

### 2. Configurar el inventario

Copia el ejemplo y rellena las direcciones de los hosts del aula
(grupo `alumnos`):

```shell
cp inventory/hosts.ini.example inventory/hosts.ini
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
