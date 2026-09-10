# veyon-kali

Instalación de Veyon en un aula con Kali Linux.

## Prerrequisitos

Habilitar SSH y copiar la clave pública

```shell
sudo systemctl start ssh.service
sudo systemctl enable ssh.service
```

```shell
make setup-ssh
```

## Lanzar el playbook

```shell
make apply
```
