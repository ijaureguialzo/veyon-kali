#!make

# Makefile — Compila Veyon .deb para Kali Linux vía Docker
#                 y Veyon para macOS de forma nativa
#
# Uso:
#    make               # arm64 nativo + amd64 emulado
#    make arm64         # solo arm64 (~5 min en Apple Silicon)
#    make amd64         # solo amd64 (emulado, ~15-30 min)
#    make macos         # build nativo para macOS (arm64/x86_64)
#    make macos-package # reempaqueta el bundle existente en un DMG
#    make macos-install # instala el bundle en /Applications
#    make clean         # borra los .deb generados y el workspace de macOS
#    make help          # lista los objetivos
#
# Requisitos:
#    * Docker daemon activo
#    * Imagen:
#        docker pull --platform linux/arm64 kalilinux/kali-rolling
#        docker pull --platform linux/amd64 kalilinux/kali-rolling
#    * (opcional en ARM) qemu/binfmt registrado en Docker Desktop para amd64
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
#       format-truncation / maybe-uninitialized), conservando -Werror para el
#       resto de objetivos.
#     * El .deb final se copia a ./package/.
#
# Para macOS:
#     * build-veyon-macos.sh trabaja sobre una copia editable en
#       build/veyon-macos y aplica los parches de patches/, de forma que el
#       checkout upstream en build/veyon queda intacto.
#     * El resultado es un stage ejecutable en build/veyon-macos/build/stage.
#     * "make clean" borra ese workspace; el checkout upstream no se toca.

SHELL    := /bin/bash
ROOT_DIR := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
# Checkout único de Veyon (scripts/veyon-source.sh decide dónde vive).
SRC      := $(shell bash $(ROOT_DIR)/scripts/veyon-source.sh path 2>/dev/null || echo $(ROOT_DIR)/build/veyon)
OUT      := ./package
IMAGE    ?= kalilinux/kali-rolling
SCRIPT   := /bin/bash /scripts/build-veyon.sh
PREFIX   ?= /opt/homebrew
# Mirrors de Kali para el índice de paquetes.  El CDN de http.kali.org reparte
# cada petición a un mirror distinto y, si dos no están sincronizados entre
# sí, apt-get update aborta; por eso se fija uno y se van probando.
KALI_MIRRORS ?= http://mirror.raiolanetworks.com/kali/ http://mirror.es.cdn-perfprod.com/kali/ http://ftp.halifax.rwth-aachen.de/kali/

# Despliegue en los hosts del aula (ansible)
SSH_USER  ?= ciber
SSH_KEY   ?= $(HOME)/.ssh/id_rsa.pub
INVENTORY ?= inventory/hosts.ini

.PHONY: all arm64 amd64 macos macos-package macos-install clean download-src \
        setup-ssh apply help

## all: arm64 + amd64 (objetivo por omisión)
all: arm64 amd64

## arm64: .deb arm64 nativo, compilado en Docker
arm64: download-src
	@echo "── veyon .deb  arch=arm64  imagen=$(IMAGE) ──"
	@mkdir -p $(OUT)
	@docker run --rm --platform linux/arm64 \
		-v $(SRC):/src:ro \
		-v $(ROOT_DIR)/scripts:/scripts:ro \
		-v $(OUT):/out \
		-e KALI_MIRRORS="$(KALI_MIRRORS)" \
		$(IMAGE) \
		$(SCRIPT)

## amd64: .deb amd64 emulado en Docker
amd64: download-src
	@echo "── veyon .deb  arch=amd64  imagen=$(IMAGE) ──"
	@mkdir -p $(OUT)
	@docker run --rm --platform linux/amd64 \
		-v $(SRC):/src:ro \
		-v $(ROOT_DIR)/scripts:/scripts:ro \
		-v $(OUT):/out \
		-e KALI_MIRRORS="$(KALI_MIRRORS)" \
		$(IMAGE) \
		$(SCRIPT)

## macos: bundle y DMG nativos de macOS
macos:
	@echo "── veyon  macOS nativo  prefix=$(PREFIX) ──"
	@PREFIX="$(PREFIX)" bash scripts/build-veyon-macos.sh

## macos-package: reempaqueta el bundle existente en un DMG
macos-package:
	@bash scripts/package-veyon-macos.sh

## macos-install: instala el bundle en /Applications y evita el aviso de Gatekeeper
macos-install:
	@bash scripts/install-veyon-macos.sh

## clean: borra los .deb generados y el workspace de macOS
##        (el checkout upstream en build/veyon se conserva)
clean:
	@echo "── limpiar ──"
	@rm -rf $(OUT)
	@rm -rf $(ROOT_DIR)/build/veyon-macos
	@for id in $$(docker ps -aq --filter name=veyon 2>/dev/null); do \
		docker rm -f "$$id" >/dev/null 2>&1 || true; \
	done
	@echo "    limpio (se conserva el checkout de Veyon en build/veyon)"

## download-src: clona/actualiza el checkout ÚNICO de Veyon y sus submodules
download-src:
	@bash $(ROOT_DIR)/scripts/veyon-source.sh update

# ── Despliegue ─────────────────────────────────────────────────────────────

## setup-ssh: copia la clave SSH a los hosts del inventario
setup-ssh:
	@SSH_USER="$(SSH_USER)" SSH_KEY="$(SSH_KEY)" bash scripts/setup-ssh.sh "$(INVENTORY)"

## apply: aplica el playbook de ansible a los hosts del inventario
apply:
	@ansible-playbook -i "$(INVENTORY)" playbook.yml --ask-become-pass

## help: lista los objetivos disponibles
help:
	@echo "Veyon — compilación y despliegue"
	@echo
	@echo "Compilación"
	@echo "  all             arm64 + amd64 (por omisión)"
	@echo "  arm64           .deb arm64 nativo   (~5 min en Apple Silicon)"
	@echo "  amd64           .deb amd64 emulado   (~15-30 min)"
	@echo "  macos           bundle y DMG nativos de macOS"
	@echo "  macos-package   reempaqueta el bundle existente en un DMG"
	@echo "  macos-install   instala el bundle en /Applications"
	@echo "  download-src    clona/actualiza el checkout único de Veyon"
	@echo "  clean           borra los .deb generados y el workspace de macOS"
	@echo
	@echo "Despliegue (ansible)"
	@echo "  setup-ssh       copia la clave SSH a los hosts del inventario"
	@echo "  apply           aplica el playbook a los hosts del inventario"
