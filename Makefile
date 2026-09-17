#!make

# Parámetros configurables
SSH_USER  ?= ciber
SSH_KEY   ?= $(HOME)/.ssh/id_rsa.pub
INVENTORY ?= inventory/hosts.ini

# Makefile — Compila Veyon .deb para Kali Linux vía Docker
#
# Uso:
#    make            # arm64 nativo + amd64 emulado
#    make arm64      # solo arm64 (~5 min en Apple Silicon)
#    make amd64      # solo amd64 (emulado, ~15-30 min)
#    make clean      # contenedores intermedios + ./out
#
# Requisitos:
#    * Docker daemon activo
#    * Imagen:
#        docker pull --platform linux/arm64 kalilinux/kali-rolling
#        docker pull --platform linux/amd64 kalilinux/kali-rolling
#    * Submodules:  git submodule update --init --recursive
#    * (opcional en ARM) qemu/binfmt registrado en Docker Desktop para amd64
#
# Diseño:
#     * La fuente se monta en modo read-only (/src:ro) para no tocar el árbol
#       del anfitrión.
#     * build-veyon.sh copia la fuente a /work (escritura) y aplica ahí el
#       parche GCC-15 de -Werror (3 falsos positivos: format-overflow /
#       format-truncation / maybe-uninitialized), conservando -Werror para
#       el resto de objetivos.
#     * El .deb final se copia a ./out/.

SHELL    := /bin/bash
SRC      := ./build/veyon
OUT      := ./package
IMAGE    ?= kalilinux/kali-rolling
SCRIPT   := /bin/bash /scripts/build-veyon.sh

help: _header
	${info }
	@echo Opciones:
	@echo -------------------
	@echo setup-ssh
	@echo -------------------
	@echo download-src
	@echo arm64 / amd64 / all
	@echo -------------------
	@echo apply
	@echo -------------------

_header:
	@echo -----
	@echo Veyon
	@echo -----

# Recorre inventory/hosts.ini y copia la clave SSH a cada uno de sus hosts.
setup-ssh:
	@SSH_USER="$(SSH_USER)" SSH_KEY="$(SSH_KEY)" bash scripts/setup-ssh.sh "$(INVENTORY)"

apply:
	@ansible-playbook -i "$(INVENTORY)" playbook.yml --ask-become-pass

## all: arm64 + amd64
all: arm64 amd64

## arm64 nativo
arm64:
	@echo "── veyon .deb  arch=arm64  imagen=$(IMAGE) ──"
	@mkdir -p $(OUT)
	@docker run --rm --platform linux/arm64 \
		-v $(SRC):/src:ro \
		-v $(CURDIR)/scripts:/scripts:ro \
		-v $(OUT):/out \
		$(IMAGE) \
		$(SCRIPT)

## amd64 emulado en ARM (requiere qemu binfmt en Docker Desktop)
amd64:
	@echo "── veyon .deb  arch=amd64  imagen=$(IMAGE) ──"
	@mkdir -p $(OUT)
	@docker run --rm --platform linux/amd64 \
		-v $(SRC):/src:ro \
		-v $(CURDIR)/scripts:/scripts:ro \
		-v $(OUT):/out \
		$(IMAGE) \
		$(SCRIPT)

download-src:
	@if [ ! -d build/veyon ]; then git clone --recursive https://github.com/veyon/veyon.g build/veyon; fi
	@cd build/veyon && git pull --recurse-submodules
