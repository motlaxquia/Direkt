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
#   make clean / distclean

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

REPO     := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
BUILD    := $(REPO)/build
BIN      := $(BUILD)/bin
ENGINE   := $(BUILD)/src/ironwail
LQ       := $(BUILD)/lq/full          # basedir valido: contiene id1/pak0.pak
IW_VER   := $(BUILD)/.engine-stamp

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
        test clean distclean engine-clean data-clean patch-refresh

help:
	@sed -n '2,12p' $(firstword $(MAKEFILE_LIST)) | sed 's/^# \?//'

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

$(GAME_PROGS): $(GAME_SOURCES)
	@command -v fteqcc >/dev/null || { \
		echo "ERROR: falta fteqcc. Ejecuta 'make setup'." >&2; exit 1; }
	@echo "==> Compilando la logica de juego -> direkt/progs.dat"
	@mkdir -p $(REPO)/direkt
	@cd $(REPO)/game && fteqcc progs.src
	@test -s $(GAME_PROGS) || { echo "ERROR: fteqcc no produjo progs.dat" >&2; exit 1; }
	@echo "    ok: $$(stat -c%s $(GAME_PROGS)) bytes"

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
	@echo "    ok: $$(stat -c%s $(GAME_PROGS_NS)) bytes"
	@$(MAKE) --no-print-directory game

run: game
	@$(ENGINE_BIN) -basedir $(LQ) -basedir $(REPO) -game direkt $(ARGS)

run-headless: game
	@$(REPO)/scripts/run-headless.sh --map $(MAP) --settle $(SETTLE) --min-lit $(MIN_LIT)

shot: game
	@$(REPO)/scripts/run-headless.sh --map $(MAP) --settle $(SETTLE) --min-lit $(MIN_LIT) --shot

# El smoke test necesita el motor, las dos variantes de progs.dat y los datos.
test: engine game game-noshowcase
	@$(REPO)/scripts/smoke-test.sh

# ------------------------------------------------------------------ limpieza
clean:
	@rm -rf $(BUILD)/engine-build $(BIN) $(GAME_PROGS) $(GAME_PROGS_NS) \
		$(BUILD)/logs $(BUILD)/shots
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
