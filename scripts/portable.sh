#!/usr/bin/env bash
# Empaqueta una version portable de Direkt: los binarios ya compilados, los
# datos del juego y TODO el codigo fuente.
#
# GPL-2.0, ver LICENSE en la raiz del repositorio.
#
# El codigo fuente no es un adorno. Direkt es GPL, el motor tambien, y los datos
# de LibreQuake cuentan como GPL porque pop.lmp va dentro de pak1.pak junto a
# los mapas. Un binario GPL necesita el fuente completo delante, asi que aqui se
# mete TODO: nuestro codigo, el QC, y el tarball del motor con su SHA-256 para
# que se pueda recompilar sin red.
#
# Lo que NO se mete, y por que:
#
#   - build/lq/full entero menos nada. Faltaria un mapa o un sonido, y el
#     directorio de datos es lo que mas se nota si esta incompleto.
#   - El tarball del motor SI, y con su SHA-256, para que `make engine` pueda
#     reconstruirse dentro del paquete sin descargar nada.
#   - Los .bsp que genera el propio direkt-bsp no se meten: se generan en un
#     segundo con el generador que va incluido, y meterlos seria meter un
#     producto que ya se puede reproducir.

set -euo pipefail

# Sistema destino del paquete. Se empaqueta para el que se este compilando, que
# es como lo llama el workflow de GitHub Actions. Los tres usan el mismo
# generador y los mismos datos; lo que cambia es el lanzador y el contenedor.
# sha256sum es de coreutils y no viene en macOS, donde el mismo hash se pide
# con shasum -a 256. La salida es identica en los dos casos.
# Es un array y no una variable porque "shasum -a 256" son dos palabras: con
# "$HASH_CMD" entrecomillado se buscaria un binario llamado literalmente
# "shasum -a 256", que no existe.
if command -v sha256sum >/dev/null 2>&1; then
	HASH_CMD=(sha256sum)
elif command -v shasum >/dev/null 2>&1; then
	HASH_CMD=(shasum -a 256)
else
	echo "portable: hace falta sha256sum o shasum para incluir el hash" >&2
	exit 1
fi

OS="${DIREKT_OS:-linux}"
case "$OS" in
linux|macos|windows) ;;
*)
	echo "portable: sistema desconocido '$OS'. Usa linux, macos o windows." >&2
	exit 1
	;;
esac

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$REPO/build"
BIN="$BUILD/bin"
LQ="$BUILD/lq/full"
STAGE="$BUILD/portable"
# La extension va con el formato. En Windows se guarda en .zip, que es lo que
# el explorador de archivos abre con doble clic sin preguntar nada. Con un .zip
# dentro de un .tar.gz (que es lo que salia antes) el mensaje de "descomprime
# el .zip" era cierto y el fichero no lo era, y tar xzf dessus no sacaba nada
# util.
if [ "$OS" = windows ]; then
	OUT="$BUILD/direkt-portable-$OS.zip"
else
	OUT="$BUILD/direkt-portable-$OS.tar.gz"
fi
NOMBRE="direkt-portable-$OS"

die() { echo "portable: $*" >&2; exit 1; }

# --- que este todo lo que hace falta -----------------------------------------
[ -x "$BIN/ironwail" ]     || die "falta el motor; ejecuta 'make engine'"
[ -x "$BIN/direkt-bsp" ]   || die "falta el generador; ejecuta 'make bsp'"
[ -x "$BIN/direkt-edit" ]  || die "falta el editor; ejecuta 'make edit'"
[ -f "$REPO/direkt/progs.dat" ] || die "falta la logica de juego; ejecuta 'make game'"
[ -f "$LQ/id1/pak0.pak" ]  || die "faltan los datos; ejecuta 'make data'"
[ -f "$BUILD/cache/ironwail-src.tar.gz" ] || die "falta el tarball del motor; ejecuta 'make deps'"

echo "==> Preparando $NOMBRE en $STAGE"
rm -rf "$STAGE"
mkdir -p "$STAGE"

# --- binarios y logica de juego ---------------------------------------------
echo "    binarios"
mkdir -p "$STAGE/bin" "$STAGE/direkt"
# En Windows los binarios se llaman .exe, y en los demas no. No se deja que sea
# el shell el que resuelva el nombre: cp no siempre anade el .exe por su cuenta,
# y un cp que falla a mitad del empaquetado se lleva por delante el stage entero.
# Con "if" y no con "[ ... ] && ...": lo segundo, si la condicion es falsa,
# devuelve error y con set -e el script se para. En Linux lo seria siempre.
if [ "$OS" = windows ]; then
	BIN_EXT=".exe"
else
	BIN_EXT=""
fi
for b in ironwail direkt-bsp direkt-edit; do
	src="$BIN/$b$BIN_EXT"
	[ -f "$src" ] || src="$BIN/$b"
	[ -f "$src" ] || { echo "portable: falta $b$BIN_EXT en $BIN" >&2; exit 1; }
	cp "$src" "$STAGE/bin/$b$BIN_EXT"
done
# En Windows los .exe necesitan las DLL de MINGW64 en la misma carpeta, o no
# arrancan. En Linux y macOS esto no hace nada.
"$REPO/scripts/copy-runtime-dlls.sh" || true
# Las DLL que se hayan copiado en build/bin, al paquete. En los otros sistemas
# no hay ninguna, y el glob no casa con nada.
for dll in "$BIN"/*.dll "$BIN"/*.DLL; do
	[ -f "$dll" ] || continue
	cp "$dll" "$STAGE/bin/"
	echo "    $(basename "$dll")"
done
cp "$REPO/direkt/progs.dat" "$STAGE/direkt/"

# --- datos ------------------------------------------------------------------
# Sin_LINK ni nada: se copia el arbol tal cual para que las rutas internas del
# pak sigan valiendo.
echo "    datos del juego"
mkdir -p "$STAGE/datos"
cp -a "$LQ/." "$STAGE/datos/"

# --- fuente -----------------------------------------------------------------
echo "    codigo fuente"
mkdir -p "$STAGE/fuente"
for d in src game scripts tools docs patches ci; do
	[ -d "$REPO/$d" ] && cp -a "$REPO/$d" "$STAGE/fuente/"
done
cp "$REPO/Makefile" "$REPO/LICENSE" "$REPO/README.md" "$REPO/THIRD_PARTY.md" \
   "$STAGE/fuente/"

# El tarball del motor va con su hash, que es lo que verifica fetch-deps.sh. Sin
# esto el paquete compila pero no se puede reconstruir el motor sin red.
echo "    tarball del motor"
mkdir -p "$STAGE/fuente/cache"
cp "$BUILD/cache/ironwail-src.tar.gz" "$STAGE/fuente/cache/"
# El hash va en formato "sha256sum -c", que es el que luego leen los scripts de
# este paquete. En macOS no hay sha256sum, hay shasum: los dos dan el mismo
# formato de salida y el fichero se comprueba igual en los tres sistemas.
( cd "$STAGE/fuente/cache" && "${HASH_CMD[@]}" ironwail-src.tar.gz > ironwail-src.tar.gz.sha256 )

# --- nota de entorno por sistema -------------------------------------------
# El motor exige OpenGL 4.3 en los tres sistemas, pero lo que ofrece cada uno
# es distinto, y conviene decirlo claro en el propio paquete y no en un
# aviso de la pagina web.
case "$OS" in
macos)
	cat > "$STAGE/LEE-ME-ENTORNO.md" <<'FIN'
## Este paquete en macOS

El motor de Ironwail pide **OpenGL 4.3**, porque usa *compute shaders* para
dibujar el mundo.

El problema: el OpenGL que trae macOS llega como mucho a **4.1**, y no hay
forma de subirlo desde el sistema. En un Mac con una GPU de Apple, este paquete
puede que no llegue a arrancar y se quede en:

    OpenGL 4.3 required, found 4.1

Esto no se arregla con un conmutador ni con un instalador: es un tope del
sistema. Por eso el paquete se publica **para que se pruebe**, y no como algo
que esté garantizado.

### Qué hacer

1. Probarlo. A veces un Mac con una GPU discreta anuncia mas de 4.1:
       ./direkt.sh test
2. Si falla por la version de GL, este SO no es valido para este motor. Las
   salidas son: usar la version de Linux bajo un entorno grafico virtualizado,
   o esperar a que el motor tenga un backend que no dependa de OpenGL.

### Lo que si funciona en macOS

El generador de `.bsp` (`direkt-bsp`) y el editor (`direkt-edit`) no dependen
de la version de OpenGL que tenga el motor, asi que son usables.
FIN
	;;
windows)
	cat > "$STAGE/LEE-ME-ENTORNO.md" <<'FIN'
## Este paquete en Windows

El motor de Ironwail pide **OpenGL 4.3**. Windows por si solo no da ninguna
version: lo pone el driver de la tarjeta grafica, y por eso hay maquinas que
funcionan y maquinas que no.

### Si dice que no llega

    OpenGL 4.3 required, found 1.1

Actualiza el driver desde el fabricante de tu tarjeta (NVIDIA, AMD, Intel) o
desde Windows Update. En un equipo deSobremesa antiguo o un portatil con
grafica integrada, el driver de Microsoft es el que peor suele quedar.

### Doble clic

`direkt.bat` llama a `direkt.sh`, que necesita `bash` (viene con Git Bash y con
MSYS2). Si no lo tienes, el `.bat` va directo al motor, asi que el juego
funciona igual; lo que se pierde es el aviso automatico cuando el OpenGL de la
maquina no llega.
FIN
	;;
*)
	cat > "$STAGE/LEE-ME-ENTORNO.md" <<'FIN'
## Este paquete en Linux

El motor de Ironwail pide **OpenGL 4.3**, porque usa *compute shaders* para
dibujar el mundo. Con una tarjeta grafica normal no hay nada que hacer.

### Si dice que no llega

    OpenGL 4.3 required, found 2.1

El lanzador lo detecta y se reintenta solo con el rasterizador por software de
Mesa (`llvmpipe`), que da OpenGL 4.5. Va mas lento, pero dibuja. Para saber si
eso se esta usando:

    glxinfo -B | grep -i "OpenGL version"

Si el paquete se usa en una maquina virtual, o con drivers viejos, conviene
tener instalado el rasterizador:

    sudo apt install libgl1-mesa-dri libglx-mesa0

### Forzar uno u otro

    DIREKT_SOFTWARE_GL=1 ./direkt.sh    # ir siempre por software
    DIREKT_FORCE_GL=1 ./direkt.sh       # no tocar el GL, pase lo que pase
FIN
	;;
esac

# --- lanzador ---------------------------------------------------------------
# El lanzador de verdad es un script de shell, y va siempre en el paquete. En
# macOS y en Windows, que no lo ejecutan con doble clic, se anade encima un
# envoltorio de tres lineas que lo llama.
#
# Se evita duplicar la logica: el de shell resuelve lo de verdad (detectar el
# OpenGL, caer a llvmpipe, pasar argumentos) y los envoltorios solo delegan.
cat > "$STAGE/direkt.sh" <<'FIN'
#!/usr/bin/env bash
# Lanzador de Direkt.
#
#   ./direkt.sh            abre el juego
#   ./direkt.sh test       comprueba que el paquete arranca de verdad
#   ./direkt.sh editor     abre el editor de niveles
#   ./direkt.sh bsp a b    compila el mapa a en b.bsp
#   ./direkt.sh shell      deja una shell con el directorio en $PATH
set -euo pipefail
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$AQUI/bin:$PATH"

# El motor se llama ironwail en Linux y macOS, y ironwail.exe en Windows. En
# MSYS2 el shell resuelve el .exe por su cuenta, pero en macOS con Homebrew no,
# y en un Windows donde solo haya Git Bash tampoco. Se prueban los dos nombres.
# Aqui no se puede usar "[ ... ] && ..." porque con set -e, que esta puesto, si
# la condicion es falsa el lanzador se para. En Linux lo seria siempre, claro.
EDIT_EXT=""
if [ -x "$AQUI/bin/direkt-edit.exe" ]; then
	EDIT_EXT=".exe"
fi
IRONWAIL="$AQUI/bin/ironwail"
[ -x "$IRONWAIL" ] || IRONWAIL="$AQUI/bin/ironwail.exe"
[ -x "$IRONWAIL" ] || { echo "no encuentro el motor en $AQUI/bin" >&2; exit 1; }

# El generador de .bsp saca las texturas de ahi. En el repositorio mira en
# build/lq/full/id1, que aqui no existe: sin esto el .bsp sale sin lump
# TEXTURES y el motor pinta con la textura por defecto.
export DIREKT_GAMEDIR="$AQUI/datos/id1"

# El motor pide OpenGL 4.3 (Quake/gl_vidsdl.c: MIN_GL_VERSION 4.3) porque usa
# compute shaders para dibujar el mundo. En una tarjeta de verdad no hay
# problema, pero en una maquina virtual, un portatil viejo, o un linux con los
# drivers a medias, el GL que se anuncia se queda en 1.x o 2.x y el motor aborta
# con "OpenGL 4.3 required, found 2.1".
#
# Mesa trae un rasterizador por software, llvmpipe, que SI da OpenGL 4.5 con
# compute shaders. Va lento, pero funciona. En vez de solo documentarlo se
# resuelve aqui: antes de arrancar se pregunta que version de GL hay, y si no
# llega se cae a llvmpipe.
#
# Se sondea ANTES de lanzar y luego se hace exec, a proposito: si se lanzara el
# motor y se esperara a ver si se queja, habria que meter su salida en un
# fichero para poder reintentar, y el usuario se quedaria sin ver nada durante
# toda la partida. Con exec, la ventana, el teclado y las senales siguen siendo
# las del propio motor.
#
# DIREKT_SOFTWARE_GL=1 lo fuerza, y DIREKT_FORCE_GL=1 deja el GL del sistema
# aunque no llegue.

usar_llvmpipe() {
	export LIBGL_ALWAYS_SOFTWARE=1
	export GALLIUM_DRIVER=llvmpipe
	export MESA_GL_VERSION_OVERRIDE="${MESA_GL_VERSION_OVERRIDE:-4.5COMPAT}"
	export MESA_DEBUG=silent
	# llvmpipe se reserva la mitad de los nucleos por defecto, y con eso el
	# juego va a trompicones aunque la version de GL sea la correcta.
	# nproc es de coreutils y no viene en macOS, que lo llama distinto.
	local nucleos
	nucleos="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)"
	export LP_NUM_THREADS="${DIREKT_THREADS:-$nucleos}"
}

# Version de OpenGL que anuncia el sistema, o vazia si no se puede saber.
version_gl() {
	local v
	if [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
		return 1
	fi
	command -v glxinfo >/dev/null 2>&1 || return 1
	v="$(glxinfo -B 2>/dev/null | sed -n 's/.*OpenGL version string: *\([0-9][0-9.]*\).*/\1/p' | head -1)"
	[ -n "$v" ] || return 1
	printf '%s' "$v"
}

# Devuelve 0 si la version anuncia menos de 4.3, o si no se puede saber.
gl_insuficiente() {
	local v major minor
	v="$(version_gl)" || return 0          # no se sabe: se asume que vale
	major="${v%%.*}"
	minor="${v#*.}"; minor="${minor%%.*}"
	[ -n "$major" ] || return 0
	[ "$major" -lt 4 ] && return 0
	[ "$major" -gt 4 ] && return 1
	[ "${minor:-0}" -lt 3 ] && return 0
	return 1
}

jugar() {
	local v
	if [ "${DIREKT_FORCE_GL:-0}" = 1 ]; then
		:  # el usuario ha dicho que no se toque el GL
	elif [ "${DIREKT_SOFTWARE_GL:-0}" = 1 ]; then
		usar_llvmpipe
	elif gl_insuficiente; then
		v="$(version_gl)"
		echo "  OpenGL del sistema: ${v:-desconocido}, y el motor pide 4.3."
		echo "  Se arranca con el rasterizador por software de Mesa (llvmpipe)."
		echo "  Va mas despacio, pero dibuja. Para no hacerlo:"
		echo "      DIREKT_FORCE_GL=1 ./direkt.sh"
		echo
		usar_llvmpipe
	fi
	exec "$IRONWAIL" -basedir "$AQUI/datos" -basedir "$AQUI" -game direkt "$@"
}

# Comprobacion autonoma: no necesita el arbol de desarrollo ni fteqcc, solo lo
# que va en el paquete.
#
# El motor NO se para con -quit: hay que esperarlo a que el mundo este listo y
# mandarle SIGTERM, que es lo que hace el banco de pruebas del repo. -quit se
# ignora y el motor se queda aqui para siempre.
comprobar() {
	local log pid i espera=180
	local -a lanzo

	log="$(mktemp)"
	if [ -n "${DISPLAY:-}" ]; then
		lanzo=("$IRONWAIL")
	elif command -v xvfb-run >/dev/null 2>&1; then
		lanzo=(xvfb-run -a "$IRONWAIL")
	else
		echo "  no hay pantalla ni xvfb-run: se prueba a pelo y puede que el"
		echo "  motor no pueda abrir una ventana"
		lanzo=("$IRONWAIL")
	fi

	if [ "${DIREKT_FORCE_GL:-0}" != 1 ] && { [ "${DIREKT_SOFTWARE_GL:-0}" = 1 ] || gl_insuficiente; }; then
		usar_llvmpipe
	fi

	"${lanzo[@]}" -basedir "$AQUI/datos" -basedir "$AQUI" -game direkt \
		-nosound -window -width 640 -height 480 +map lqdm1 >"$log" 2>&1 &
	pid=$!

	# La senal de que el mundo esta listo la da la propia logica de juego: si
	# encuentra el punto de aparicion, el mapa esta cargado y el jugador existe.
	for ((i = 0; i < espera; i++)); do
		grep -q "punto de aparicion" "$log" && break
		kill -0 "$pid" 2>/dev/null || break
		sleep 1
	done

	if grep -q "punto de aparicion" "$log"; then
		rc=0
	else
		echo "  FALLA: el mundo no llego a estar listo en ${espera}s"
		grep -iE "OpenGL [0-9.]+ required" "$log" | head -2
		tail -20 "$log"
		rc=1
	fi

	kill -TERM "$pid" 2>/dev/null || true
	for ((i = 0; i < 20; i++)); do
		kill -0 "$pid" 2>/dev/null || break
		sleep 0.25
	done
	kill -KILL "$pid" 2>/dev/null || true
	wait "$pid" 2>/dev/null || true

	# OJO con el filtro: el motor avisa en minusculas de los cfg OPCIONALES que
	# no encuentra, y "couldn't exec autoexec.cfg" es normal y sale siempre. Lo
	# que si seria grave es que no encuentre NUESTRO cfg.
	if grep -qiE 'Sys_Error|Segmentation fault' "$log"; then
		echo "  FALLA: el log tiene un error grave:"
		grep -iE 'Sys_Error|Segmentation fault' "$log" | head
		rc=1
	fi

	if [ "$rc" -eq 0 ]; then
		echo "  PASA: el motor arranco, cargo el mapa y encontro el spawn"
	fi

	rm -f "$log"
	return "$rc"
}

case "${1:-jugar}" in
jugar)   jugar ;;
test)    comprobar ;;
editor)  exec "$AQUI/bin/direkt-edit$EDIT_EXT" "${2:-}" ;;
bsp)     exec "$AQUI/bin/direkt-bsp$EDIT_EXT" "$2" "$3" ;;
shell)   echo "PATH=$AQUI/bin:$PATH"; exec "${SHELL:-/bin/sh}" ;;
*)       jugar "$@" ;;
esac
FIN
chmod +x "$STAGE/direkt.sh"

# Envoltorios para los sistemas que no ejecutan un .sh con doble clic.
case "$OS" in
macos)
	cat > "$STAGE/direkt.command" <<'FIN'
#!/bin/sh
# Doble clic desde Finder. Finder ejecuta esto con su propio shell, asi que
# solo delega en el lanzador de verdad.
AQUI="$(cd "$(dirname "$0")" && pwd)"
exec "$AQUI/direkt.sh" "$@"
FIN
	chmod +x "$STAGE/direkt.command"
	;;
windows)
	cat > "$STAGE/direkt.bat" <<'FIN'
@echo off
REM Doble clic desde el explorador. El lanzador de verdad es un script de shell,
REM asi que se le llama con bash, que viene con Git Bash y con MSYS2; y si no
REM esta, se va directo al motor, que es lo unico imprescindible.
setlocal
set "AQUI=%~dp0"
where bash >nul 2>&1
if %ERRORLEVEL%==0 (
  bash "%AQUI%direkt.sh" %*
) else (
  "%AQUI%bin\ironwail.exe" -basedir "%AQUI%datos" -basedir "%AQUI%" -game direkt %*
)
endlocal
FIN
	;;
esac

# --- nota de procedencia ----------------------------------------------------
# Se escribe con la fecha y el commit. Sin esto no se puede saber de donde sale
# un paquete que aparece en un ftp.
{
	echo "Direkt portable"
	echo
	echo "  generado   $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
	if git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
		echo "  commit     $(git -C "$REPO" rev-parse HEAD)"
		echo "  arbol      $(git -C "$REPO" status --porcelain | wc -l) fichero(s) sin commitear"
	fi
	# La variable del script de fetch lleva comillas; aqui se quitan, que si
	# no el hash sale con comillas y no se puede comparar con el SHA-256.
	echo "  motor      $(grep -m1 '^IRONWAIL_COMMIT=' "$REPO/scripts/fetch-deps.sh" | cut -d= -f2- | tr -d '"')"
	echo "  datos      LibreQuake (pak0.pak + pak1.pak)"
	echo
	echo "Licencia GPL-2.0. El fuente completo va en fuente/; el tarball del motor"
	echo "va en fuente/cache/ con su SHA-256."
} > "$STAGE/FUENTE-DEL-PAQUETE.txt"

# --- empaquetar -------------------------------------------------------------
# Se mete el contenido de $STAGE dentro de un directorio con nombre, para que al
# descomprimir no aparezcan 40 carpetas sueltas en el directorio de trabajo.
echo "==> Empaquetando"
rm -rf "$BUILD/$NOMBRE"
cp -a "$STAGE" "$BUILD/$NOMBRE"

case "$OS" in
windows)
	# Un .zip, porque es lo que el explorador de archivos abre con doble clic
	# sin preguntar nada. En Windows 11 el .tar.gz tambien se abre, pero el
	# usuario tiene que aceptarlo a mano y parece que se ha roto.
	if command -v zip >/dev/null 2>&1; then
		rm -f "$OUT"
		(cd "$BUILD" && zip -qr "$OUT" "$NOMBRE")
	else
		# Sin 'zip' no se puede hacer un .zip de verdad, y renombrar un tar a
		# .zip seria dar por bueno un fichero que no se abre. Se dice y se deja
		# el nombre bueno, que es el que ya espera la pagina de descarga.
		echo "    aviso: no hay 'zip' en este sistema y no se puede empaquetar en"
		echo "    .zip. En Windows, sin 'zip' el paquete no sale: instalalo con"
		echo "    'pacman -S zip'."
		exit 1
	fi
	;;
*)
	tar czf "$OUT" -C "$BUILD" "$NOMBRE"
	;;
esac
rm -rf "$BUILD/$NOMBRE"

echo "==> $OUT"
ls -lh "$OUT" | awk '{print "    " $5 "  " $9}'
echo
case "$OS" in
windows)
	echo "Para usarlo:"
	echo "    descomprime el .zip"
	echo "    cd $NOMBRE"
	echo "    doble clic en direkt.bat"
	;;
macos)
	echo "Para usarlo:"
	echo "    tar xzf $(basename "$OUT")"
	echo "    cd $NOMBRE"
	echo "    doble clic en direkt.command"
	echo
	echo "La primera vez macOS lo bloqueara porque el paquete viene de internet."
	echo "Si es asi, desde una terminal dentro de la carpeta:"
	echo "    xattr -dr com.apple.quarantine ."
	echo
	echo "Y el motor pide OpenGL 4.3, que es mas de lo que ofrece el OpenGL de"
	echo "macOS. En un Mac con una GPU de Apple puede que no llegue; en ese caso"
	echo "este paquete no es la mejor opcion. Ver LEE-ME-ENTORNO.md."
	;;
*)
	echo "Para usarlo:"
	echo "    tar xzf $(basename "$OUT")"
	echo "    cd $NOMBRE"
	echo "    ./direkt.sh"
	;;
esac
