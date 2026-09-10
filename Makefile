#!make

# Parámetros configurables
SSH_USER  ?= ciber
SSH_KEY   ?= $(HOME)/.ssh/id_rsa.pub
INVENTORY ?= inventory/hosts.ini

help: _header
	${info }
	@echo Opciones:
	@echo ---------
	@echo setup-ssh   Copia la clave SSH a todos los hosts del inventario
	@echo apply       Ejecuta el playbook de Veyon
	@echo ---------
	@echo
	@echo Para copiar sin pedir la contraseña:
	@echo   SSHPASS='mi_password' make setup-ssh

_header:
	@echo -----
	@echo Veyon
	@echo -----

# Recorre inventory/hosts.ini y copia la clave SSH a cada uno de sus hosts.
setup-ssh:
	@SSH_USER="$(SSH_USER)" SSH_KEY="$(SSH_KEY)" bash scripts/setup-ssh.sh "$(INVENTORY)"

apply:
	@ansible-playbook -i "$(INVENTORY)" playbook.yml --ask-become-pass
