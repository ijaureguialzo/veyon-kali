#!make

# Parámetros configurables
SSH_USER  ?= ciber
SSH_KEY   ?= $(HOME)/.ssh/id_rsa.pub
INVENTORY ?= inventory/hosts.ini

# Makefile — Compila Veyon .deb para Kali Linux vía Docker
#                 y Veyon para macOS de forma nativa
#
# Uso:
#    make            # arm64 nativo + amd64 emulado
#    make arm64      # solo arm64 (~5 min en Apple Silicon)
#    make amd64      # solo amd64 (emulado, ~15-30 min)
#    make macos      # build nativo para macOS (arm64/x86_64)
#    make clean      # contenedores intermedios + ./out
#
# Requisitos:
#    * Docker daemon activo
#    * Imagen:
#        docker pull --platform linux/arm64 kalilinux/kali-rolling
#        docker pull --platform linux/amd64 kalilinux/kali-rolling
#    * (opcional en ARM) qemu/binfmt registrado en Docker Desktop para amd64
#    * La fuente (checkout + submodules) la deja lista `make download-src`
#
# Diseño:
#     * Todos los procesos usan UNA SOLA copia del repositorio Git de Veyon
#       (build/veyon por defecto).  scripts/veyon-source.sh es la única fuente
#       de verdad: define dónde vive ese checkout, lo clona si falta y lo
#       deja actualizado antes de cada compilación.
#     * La fuente se monta en modo read-only (/src:ro) para no tocar el árbol
#       del anfitrión.
#     * build-veyon.sh copia la fuente a /work (escritura) y aplica ahí el
#       parche GCC-15 de -Werror (3 falsos positivos: format-overflow /
#       format-truncation / maybe-uninitialized), conservando -Werror para
#       el resto de objetivos.
#     * El .deb final se copia a ./out/.
#
# Para macOS:
#     * build-veyon-macos.sh trabaja sobre una copia editable en
#       build/veyon-macos y aplica los parches de patches/, de forma que el
#       checkout upstream en build/veyon queda intacto.
#     * El resultado es un stage ejecutable en build/veyon-macos/build/stage.
#
# Fuente única de Veyon:
#     * download-src clona/actualiza el checkout único y sus submodules.
#     * arm64/amd64 dependen de download-src: el contenedor monta el checkout
#       en read-only, así que la actualización se hace en el anfitrión.
#     * macOS no depende de download-src porque build-veyon-macos.sh actualiza
#       el mismo checkout por su cuenta (mismo helper, misma copia).

SHELL    := /bin/bash
ROOT_DIR := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
# Checkout único de Veyon (scripts/veyon-source.sh decide dónde vive).
SRC      := $(shell bash $(ROOT_DIR)/scripts/veyon-source.sh path 2>/dev/null || echo $(ROOT_DIR)/build/veyon)
OUT      := ./package
IMAGE    ?= kalilinux/kali-rolling
SCRIPT   := /bin/bash /scripts/build-veyon.sh
PREFIX   ?= /opt/homebrew

.PHONY: help _header setup-ssh apply all arm64 amd64 macos macos-package \
        macos-install macos-clean download-src

help: _header
	${info }
	@echo Opciones:
	@echo -------------------
	@echo setup-ssh
	@echo -------------------
	@echo download-src
	@echo arm64 / amd64 / all / macos / macos-package
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

## arm64 nativo (actualiza antes el checkout único de Veyon)
arm64: download-src
	@echo "── veyon .deb  arch=arm64  imagen=$(IMAGE) ──"
	@mkdir -p $(OUT)
	@docker run --rm --platform linux/arm64 \
		-v $(SRC):/src:ro \
		-v $(ROOT_DIR)/scripts:/scripts:ro \
		-v $(OUT):/out \
		$(IMAGE) \
		$(SCRIPT)

## amd64 emulado en ARM (requiere qemu binfmt en Docker Desktop)
amd64: download-src
	@echo "── veyon .deb  arch=amd64  imagen=$(IMAGE) ──"
	@mkdir -p $(OUT)
	@docker run --rm --platform linux/amd64 \
		-v $(SRC):/src:ro \
		-v $(ROOT_DIR)/scripts:/scripts:ro \
		-v $(OUT):/out \
		$(IMAGE) \
		$(SCRIPT)

## macos nativo (requiere Xcode CLT y las dependencias de Homebrew)
## El script actualiza el checkout único de Veyon antes de compilar.
macos:
	@echo "── veyon  macOS nativo  prefix=$(PREFIX) ──"
	@PREFIX="$(PREFIX)" bash scripts/build-veyon-macos.sh

## macos-package: solo reempaqueta el bundle existente en un DMG
macos-package:
	@bash scripts/package-veyon-macos.sh

## macos-install: instala el bundle en /Applications y evita el aviso de Gatekeeper
macos-install:
	@bash scripts/install-veyon-macos.sh

## macos-clean: elimina el workspace de compilación de macOS
macos-clean:
	@bash scripts/build-veyon-macos.sh --clean

## download-src: deja el checkout ÚNICO de Veyon clonado y actualizado
download-src:
	@bash $(ROOT_DIR)/scripts/veyon-source.sh update
