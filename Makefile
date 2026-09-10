#!make

help: _header
	${info }
	@echo Opciones:
	@echo ---------
	@echo setup-ssh
	@echo apply
	@echo ---------

_header:
	@echo -----
	@echo Veyon
	@echo -----

setup-ssh:
	@ssh-copy-id -i ~/.ssh/id_rsa.pub ciber@172.20.131.100

apply:
	@ansible-playbook -i inventory/hosts.ini playbook.yml --ask-become-pass
