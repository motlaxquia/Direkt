# Direkt -- orquestador de build, datos y pruebas.
#
#   make setup     instala las dependencias del sistema
#   make deps      descarga motor + datos (verifica SHA-256)
#   make engine    compila el motor
#   make game      compila la logica de juego (QuakeC -> progs.dat)
#   make run       ejecuta el juego con pantalla
#   make run-headless   ejecuta el juego sin pantalla (Xvfb + software GL)
#   make shot MAP=e1m1  arranca, juega un rato y guarda una captura
#   make test      smoke test headless completo
#   make portable  empaqueta para el sistema en el que se ejecuta (binarios + datos + fuente)
#                   DIREKT_OS=macos|windows|linux fuerza otro destino
#   make clean / distclean

SHELL := /bin/bash
# .SHELLFLAGS es de GNU Make 4.0. El make de serie de macOS es el 3.81 y no lo
# tiene, asi que en macOS hay que instalar make con brew; en MSYS2, pacman.
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

REPO     := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
BUILD    := $(REPO)/build
BIN      := $(BUILD)/bin
ENGINE   := $(BUILD)/src/ironwail
LQ       := $(BUILD)/lq/full          # basedir valido: contiene id1/pak0.pak
IW_VER   := $(BUILD)/.engine-stamp

# El generador de .bsp es codigo nuestro y solo depende de libc y libm, asi que
# no necesita configuracion ni pkg-config. Cada .c define _GNU_SOURCE donde la
# necesita, asi que aqui no se pasa -D_GNU_SOURCE (redefine y avisa).
CC       ?= cc
CFLAGS   ?= -std=c11 -O2 -Wall -Wextra -Wno-unused-parameter

ENGINE_BIN    := $(BIN)/ironwail
GAME_PROGS    := $(REPO)/direkt/progs.dat
# Variante de la prueba de humo: mismo codigo, sin el escaparate de sprites.
# Dos binarios deterministas son mejores que un cvar, porque el motor no tiene
# forma de crear un cvar desde la linea de comandos.
GAME_PROGS_NS := $(BUILD)/progs-noshowcase.dat
GAME_SOURCES  := $(wildcard $(REPO)/game/qc/*.qc) $(REPO)/game/progs.src

MAP ?= lqdm1
SETTLE ?= 4
MIN_LIT ?= 15

# cvar de render para software: sin esto Ironwail pide compute shaders
# y un rasterizador de verdad
SOFTGL := LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe MESA_GL_VERSION_OVERRIDE=4.5COMPAT

.PHONY: help setup deps engine game game-noshowcase run run-headless shot \
        bsp bsp-test edit editor-test test portable clean distclean engine-clean data-clean patch-refresh

help:
	@sed -n '2,12p' $(firstword $(MAKEFILE_LIST)) | sed 's/^# \?//'
	@echo
	@echo "mapas:    make bsp        compila el generador de .bsp"
	@echo "          make bsp-test  compila, valida y prueba la colision"
	@echo "editor:   make edit        compila el editor de niveles"
	@echo "          make editor-test  prueba el editor y dibuja un fotograma"
	@echo "          make run-edit     abre el editor (MAPFILE=mapa.map)"
	@echo "paquete:  make portable     .tar.gz (o .zip en Windows) con binarios, datos y fuente"

setup:
	@$(REPO)/scripts/setup-deps.sh

deps:
	@$(REPO)/scripts/fetch-deps.sh all
	@$(REPO)/scripts/check-gl.sh

engine: $(ENGINE_BIN)

$(ENGINE_BIN): $(IW_VER)
	@:

$(IW_VER): $(ENGINE)/.patches-applied
	@echo "==> Configurando el motor (CMake)"
	@cmake -S $(ENGINE) -B $(BUILD)/engine-build -DCMAKE_BUILD_TYPE=Release
	@echo "==> Compilando el motor"
	@cmake --build $(BUILD)/engine-build --parallel
	@mkdir -p $(BIN)
	@cp $(BUILD)/engine-build/ironwail $(ENGINE_BIN)
	@touch $@

# La logica de juego se compila con fteqcc. Los .qc estan en game/qc/ y el
# punto de entrada en game/progs.src.
#
# OJO: fteqcc ignora -o y escribe SIEMPRE donde diga el "#pragma progs_dat" de
# progs.src, que es direkt/progs.dat. Por eso la variante sin escaparate se
# aparta despues de compilar y luego se vuelve a compilar la buena.
# El smoke test mueve progs.dat de un lado a otro, asi que fiarse de la marca de
# tiempo de los ficheros es fragil: game y game-noshowcase fuerzan la
# recompilacion. fteqcc tarda menos de un segundo.
game:
	@$(MAKE) --no-print-directory -B $(GAME_PROGS)

# En las tres recetas de aqui, el tamano se saca con
#     stat -c%s FICHERO 2>/dev/null || stat -f %z FICHERO
# porque el stat de coreutils (Linux, MSYS2) y el de BSD (macOS) no se
# entienden: el primero usa -c y el segundo -f.
#
# Todo el condicional va en UNA sola linea de receta a proposito: cada linea de
# una receta es una invocacion de shell distinta, asi que un "exit 0" a mitad
# solo terminaba esa linea y make seguia con la siguiente. Aqui, en cambio, o se
# compila con fteqcc o se usa el progs.dat que ya venia en el repo.
$(GAME_PROGS): $(GAME_SOURCES)
	@if command -v fteqcc >/dev/null; then \
		echo "==> Compilando la logica de juego -> direkt/progs.dat"; \
		mkdir -p $(REPO)/direkt; \
		(cd $(REPO)/game && fteqcc progs.src); \
		test -s '$(GAME_PROGS)' || { echo "ERROR: fteqcc no produjo progs.dat" >&2; exit 1; }; \
		echo "    ok: $$(stat -c%s '$(GAME_PROGS)' 2>/dev/null || stat -f %z '$(GAME_PROGS)') bytes"; \
	elif [ -s '$(GAME_PROGS)' ]; then \
		echo "==> No hay fteqcc. Se usa el progs.dat del repo ($$(stat -c%s '$(GAME_PROGS)' 2>/dev/null || stat -f %z '$(GAME_PROGS)') bytes)."; \
		echo "    Para recompilarlo: instala fteqcc con 'make setup' y repite."; \
	else \
		echo "ERROR: falta fteqcc y no hay progs.dat en el repo." >&2; exit 1; \
	fi

game-noshowcase:
	@rm -f $(GAME_PROGS_NS) $(GAME_PROGS)
	@$(MAKE) --no-print-directory -B $(GAME_PROGS_NS)

$(GAME_PROGS_NS): $(GAME_SOURCES)
	@command -v fteqcc >/dev/null || { \
		echo "ERROR: falta fteqcc. Ejecuta 'make setup'." >&2; exit 1; }
	@mkdir -p $(BUILD)
	@echo "==> Compilando la variante sin escaparate -> $(GAME_PROGS_NS)"
	@mkdir -p $(REPO)/direkt
	@cd $(REPO)/game && fteqcc -DDIREKT_NOSHOWCASE progs.src
	@test -s $(GAME_PROGS) || { echo "ERROR: fteqcc no produjo progs.dat" >&2; exit 1; }
	@mv $(GAME_PROGS) $(GAME_PROGS_NS)
	@rm -f $(REPO)/game/progs.lno
	@echo "    ok: $$(stat -c%s $(GAME_PROGS_NS) 2>/dev/null || stat -f %z $(GAME_PROGS_NS)) bytes"
	@$(MAKE) --no-print-directory game

run: game
	@$(ENGINE_BIN) -basedir $(LQ) -basedir $(REPO) -game direkt $(ARGS)

run-headless: game
	@$(REPO)/scripts/run-headless.sh --map $(MAP) --settle $(SETTLE) --min-lit $(MIN_LIT)

run-edit: edit
	@$(EDIT_BIN) $(MAPFILE)

# El portable es lo que se puede pasar a alguien: los tres binarios, los datos y
# el fuente entero. El fuente va porque el binario es GPL (ver THIRD_PARTY.md),
# y el tarball del motor tambien, para que se pueda recompilar sin red.
# El paquete lleva el nombre del sistema destino, porque hay tres y la pagina
# web tiene que poder ofrecer el de cada uno. En Linux sale .tar.gz y en Windows
# .zip, que es lo que abre el explorador de archivos sin preguntar nada.
OS_DETECT := $(shell uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' | sed 's/^darwin$$/macos/')
OS_TARGET := $(or $(DIREKT_OS),$(OS_DETECT),linux)
PORTABLE := $(BUILD)/direkt-portable-$(OS_TARGET).tar.gz

portable: engine game bsp edit
	@echo "==> Paquete para $(OS_TARGET)"
	@DIREKT_OS=$(OS_TARGET) $(REPO)/scripts/portable.sh

shot: game
	@$(REPO)/scripts/run-headless.sh --map $(MAP) --settle $(SETTLE) --min-lit $(MIN_LIT) --shot

# El smoke test necesita el motor, las dos variantes de progs.dat y los datos.
test: engine game game-noshowcase bsp edit
	@$(REPO)/scripts/smoke-test.sh
	@$(REPO)/scripts/bsp-test.sh
	@$(REPO)/scripts/editor-test.sh

# ------------------------------------------------- compilador de mapas (.bsp)
# El motor no trae ninguno y LibreQuake no distribuye los .map, asi que para
# tener mapas propios hay que escribirlos desde cero. De momento solo el
# subconjunto clasico de .map (caras planas), que es el de los mapas de
# LibreQuake.
# El nucleo (geometria, .map, compilacion y escritura) lo comparten el
# compilador de .bsp y el editor. Cada uno anade su main y lo suyo encima.
CORE_SRC  := common.c brush.c map.c compile.c clip.c write.c tex.c light.c
CORE_HDR  := direktbsp.h tex.h
BSP_BIN   := $(BIN)/direkt-bsp
EDIT_BIN  := $(BIN)/direkt-edit
BSP_SRC   := $(addprefix $(REPO)/src/,$(CORE_SRC)) $(REPO)/src/main.c
MAP       ?= lqdm1
BSP_MAP   ?= $(REPO)/src/test/habitacion.map

EDIT_SRC  := $(addprefix $(REPO)/src/,$(CORE_SRC) ed_doc.c ed_view.c ed_gui.c \
                              edtex.c ed_test.c ed_main.c)
EDIT_HDR  := editor.h ed_view.h ed_gui.h edtex.h
EDIT_LIBS := $(shell pkg-config --libs sdl2 2>/dev/null) -lGL -lm

bsp: $(BSP_BIN)

$(BSP_BIN): $(BSP_SRC) $(addprefix $(REPO)/src/,$(CORE_HDR))
	@mkdir -p $(BIN)
	@echo "==> Compilando el generador de .bsp -> $(BSP_BIN)"
	@$(CC) $(CFLAGS) -I$(REPO)/src -o $@ $(BSP_SRC) -lm
	@test -x $@ || { echo "ERROR: no se produjo $(BSP_BIN)" >&2; exit 1; }
	@echo "    ok"

# El editor necesita SDL2 y OpenGL, que ya estan porque el motor los usa.
edit: $(EDIT_BIN)

$(EDIT_BIN): $(EDIT_SRC) $(addprefix $(REPO)/src/,$(CORE_HDR) $(EDIT_HDR))
	@command -v pkg-config >/dev/null || { \
		echo "ERROR: falta pkg-config, necesario para SDL2" >&2; exit 1; }
	@pkg-config --exists sdl2 || { \
		echo "ERROR: falta SDL2 (libsdl2-dev). El motor tambien lo necesita." >&2; exit 1; }
	@mkdir -p $(BIN)
	@echo "==> Compilando el editor -> $(EDIT_BIN)"
	@$(CC) $(CFLAGS) -I$(REPO)/src $(shell pkg-config --cflags sdl2) \
		-o $@ $(EDIT_SRC) $(EDIT_LIBS)
	@test -x $@ || { echo "ERROR: no se produjo $(EDIT_BIN)" >&2; exit 1; }
	@echo "    ok"

# bsp-test compila un mapa de prueba, lo valida y comprueba la colision.
bsp-test: $(BSP_BIN)
	@$(REPO)/scripts/bsp-test.sh

# editor-test prueba el documento sin pantalla y dibuja un fotograma con Xvfb.
editor-test: $(EDIT_BIN)
	@$(REPO)/scripts/editor-test.sh

# ------------------------------------------------------------------ limpieza
# El stage del portable son 240 MB de datos copiados: se van con clean, que ya
# limpia lo generado, y no hace falta esperar a distclean para recuperar el
# espacio. El .tar.gz tambien se va: se regenera en un momento.
clean:
	@rm -rf $(BUILD)/engine-build $(BIN) $(GAME_PROGS) $(GAME_PROGS_NS) \
		$(BUILD)/logs $(BUILD)/shots $(BUILD)/portable
		$(wildcard $(BUILD)/direkt-portable-*.tar.gz) $(wildcard $(BUILD)/direkt-portable-*.zip)
	@echo "limpio"

engine-clean:
	@rm -rf $(BUILD)/src/ironwail $(BUILD)/engine-build $(IW_VER) $(ENGINE_BIN)
	@echo "motor listo para volver a extraer"

data-clean:
	@rm -rf $(BUILD)/lq
	@echo "datos de LibreQuake borrados"

distclean:
	@rm -rf $(BUILD)
	@echo "build/ borrado por completo"

# Regenera build/src/ironwail desde el tarball y reaplica los parches.
# Usar tras editar patches/*.patch
patch-refresh: engine-clean deps
	@$(REPO)/scripts/fetch-deps.sh engine
