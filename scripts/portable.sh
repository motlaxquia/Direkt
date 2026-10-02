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
#
# quakespasm va el primero y es opcional: si esta compilado se incluye, que es
# cuando el paquete sirve para equipos sin OpenGL 4.3. Si no, el paquete sale sin
# el y el lanzador lo dice en vez de fallar al arrancar.
# Con "if" y no con "[ ... ] && ...": lo segundo, si la condicion es falsa,
# devuelve error y con set -e el script se para. En Linux lo seria siempre.
if [ "$OS" = windows ]; then
	BIN_EXT=".exe"
else
	BIN_EXT=""
fi
for b in quakespasm ironwail direkt-bsp direkt-edit; do
	src="$BIN/$b$BIN_EXT"
	[ -f "$src" ] || src="$BIN/$b"
	if [ ! -f "$src" ]; then
		if [ "$b" = "quakespasm" ]; then
			echo "    quakespasm no compilado: el paquete sale sin motor ligero"
			continue
		fi
		echo "portable: falta $b$BIN_EXT en $BIN" >&2
		exit 1
	fi
	cp "$src" "$STAGE/bin/$b$BIN_EXT"
	echo "    $b$BIN_EXT"
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

### Si un motor falla

Si al arrancar salta un error de OpenGL o de shaders, prueba con el otro:

    ./direkt.sh motor quakespasm

Es el mismo juego, los mismos mapas y el mismo codigo: lo unico que cambia es
el dibujado. Quakespasm es mucho menos exigente con la tarjeta.

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

### Si un motor falla

Si al arrancar salta un error de OpenGL o de shaders, prueba con el otro:

    ./direkt.sh motor quakespasm

Es el mismo juego, los mismos mapas y el mismo codigo: lo unico que cambia es
el dibujado. Quakespasm es mucho menos exigente con la tarjeta.

### Forzar uno u otro

    DIREKT_SOFTWARE_GL=1 ./direkt.sh         # ir siempre por software
    DIREKT_MOTOR=ironwail ./direkt.sh        # forzar el motor principal
    DIREKT_MOTOR=quakespasm ./direkt.sh      # forzar el motor ligero
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
# El motor se elige solo segun lo que de verdad anuncie la maquina. Se puede
# forzar con DIREKT_MOTOR=ironwail o DIREKT_MOTOR=quakespasm, y DIREKT_SOFTWARE_GL=1
# fuerza el rasterizador por software de Mesa.

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

# Que motor hay elegido.
#
# El orden es: la variable de entorno manda sobre todo, luego el fichero de
# configuracion del paquete, luego la deteccion automatica. El fichero existe
# porque pedir que se ponga una variable de entorno antes de cada partida no es
# una manera de hacer las cosas, y el comando "direkt.sh motor <nombre>" deja la
# eleccion escrita.
CONF="$AQUI/direkt.conf"

motor_configurado() {
	local v=""
	if [ -f "$CONF" ]; then
		v="$(sed -n 's/^[[:space:]]*motor[[:space:]]*=[[:space:]]*\([a-z]*\).*/\1/p' "$CONF" | head -1)"
	fi
	case "$v" in
	ironwail|quakespasm) printf '%s' "$v" ;;
	*) printf 'auto' ;;
	esac
}

motor_poner() {
	case "$1" in
	ironwail|quakespasm|auto) ;;
	*)
		echo "  motores posibles: ironwail, quakespasm, auto" >&2
		return 1
		;;
	esac
	local actual
	actual="$(motor_configurado)"
	if [ "$actual" = "$1" ]; then
		echo "  ya esta en $1"
		return 0
	fi
	# Se reescribe solo la linea del motor y se deja el resto, que puede haber
	# puesto la gente a mano.
	if [ -f "$CONF" ]; then
		sed -i.bak "s/^[[:space:]]*motor[[:space:]]*=.*/motor = $1/" "$CONF" && rm -f "$CONF.bak"
	else
		printf 'motor = %s\n' "$1" >"$CONF"
	fi
	echo "  motor = $1  (quedado en $CONF)"
}

jugar() {
	local v motor=""
	local iron="$AQUI/bin/ironwail"; [ -x "$iron" ] || iron="$AQUI/bin/ironwail.exe"
	local qs="$AQUI/bin/quakespasm";   [ -x "$qs" ]   || qs="$AQUI/bin/quakespasm.exe"
	[ -x "$qs" ] || qs=""

	# Que motor se usa, y por que. Hay dos motores en el paquete y la decision se
	# toma aqui, una vez, antes de arrancar.
	#
	# Ironwail dibuja el mundo con compute shaders y por eso pide OpenGL 4.3. Es
	# el mejor de los dos donde llega.
	#
	# Quakespasm dibuja lo mismo con shaders sencillos y arranca con OpenGL 1.5.
	# En un PC viejo, con grafica integrada o en una maquina virtual, donde
	# Ironwail se niega a arrancar, este si. Y va mas rapido que el otro con el
	# rasterizador por software, porque sus shaders son mucho mas baratos.
	#
	# O sea: donde no llega la GPU, mejor motor por software que mejor motor
	# por hardware.
	local elegido="${DIREKT_MOTOR:-$(motor_configurado)}"
	if [ "$elegido" = "ironwail" ]; then
		motor="ironwail"
	elif [ "$elegido" = "quakespasm" ]; then
		motor="quakespasm"
	elif gl_insuficiente; then
		v="$(version_gl)"
		if [ -n "$qs" ]; then
			motor="quakespasm"
			echo "  OpenGL del sistema: ${v:-desconocido}. El motor principal pide 4.3, y"
			echo "  aqui no llega, asi que se usa el motor ligero, que dibuja lo mismo"
			echo "  con OpenGL 1.5. Para forzar el otro:"
			echo "      DIREKT_MOTOR=ironwail ./direkt.sh"
		else
			motor="ironwail"
			echo "  OpenGL del sistema: ${v:-desconocido}, y el motor pide 4.3."
			echo "  Este paquete no trae el motor ligero, asi que se cae al"
			echo "  rasterizador por software de Mesa, que va mas despacio."
			usar_llvmpipe
		fi
		echo
	elif [ -n "$iron" ]; then
		motor="ironwail"
	else
		motor="quakespasm"
	fi

	if [ "${DIREKT_SOFTWARE_GL:-0}" = 1 ]; then
		usar_llvmpipe
	fi

	if [ "$motor" = "quakespasm" ]; then
		[ -n "$qs" ] || { echo "este paquete no trae el motor ligero" >&2; exit 1; }
		echo "  Motor: Quakespasm (ligero)"
		exec "$qs" -basedir "$AQUI/datos" -basedir "$AQUI" -game direkt "$@"
	fi

	echo "  Motor: Ironwail (OpenGL 4.3)"
	exec "$IRONWAIL" -basedir "$AQUI/datos" -basedir "$AQUI" -game direkt "$@"
}

# Dice si el mundo ya esta listo en un log, sea cual sea el motor.
#
# La senal de referencia es "entered the game", que es la linea de protocolo de
# Quake y la imprimen LOS DOS motores: "LQ Player entered the game". Antes se
# miraba solo "punto de aparicion", que es un mensaje de nuestro codigo y llega
# por localcmd; con el motor ligero ese mensaje no llegaba a tiempo y el test
# se comia 180 s de espera para fallar. Un motor nuevo, o el mismo con otro
# tiempo de arranque, no tendria por que tirar el banco.
mundo_listo() {
	grep -qE "entered the game|punto de aparicion" "$1"
}

# stdbuf saca la salida linea a linea.
#
# No es cosmetico: Quakespasm guarda la consola en un bufer y lo vacia al salir,
# asi que mientras corre el log se queda en las dos o tres primeras lineas. Ir a
# mirar ahi si el mundo esta cargado no funciona: se espera 180 s a que algo que
# ya habia pasado pero que no se lee hasta el kill. Con stdbuf aparece en
# seguida. Ironwail escribe directamente y no lo necesita, pero no hace daño.
#
# Se declara con array y no con "[ ... ] && ..." porque con set -e, si la
# condicion es falsa, el script se para. Y se invoca con ${arr[@]+...} porque el
# bash 3.2 de macOS peta con "${arr[@]}" si el array esta vacio y hay set -u.
STDBUF=()
if command -v stdbuf >/dev/null 2>&1; then
	STDBUF=(stdbuf -oL -eL)
fi

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

	# Que motor se prueba es la misma decision que en jugar(): si el OpenGL no
	# llega a 4.3 y hay motor ligero, se prueba con el ligero. Si no hay motor
	# ligero, se cae al rasterizador por software.
	local qs="$AQUI/bin/quakespasm"
	[ -x "$qs" ] || qs="$AQUI/bin/quakespasm.exe"
	if [ "${DIREKT_MOTOR:-$(motor_configurado)}" != "ironwail" ] && gl_insuficiente && [ -x "$qs" ]; then
		lanzo=("$qs")
		echo "  OpenGL insuficiente: se prueba con el motor ligero"
	elif [ "${DIREKT_SOFTWARE_GL:-0}" = 1 ] || gl_insuficiente; then
		usar_llvmpipe
	fi

	${STDBUF[@]+"${STDBUF[@]}"} "${lanzo[@]}" -basedir "$AQUI/datos" -basedir "$AQUI" -game direkt \
		-nosound -window -width 640 -height 480 +map lqdm1 >"$log" 2>&1 &
	pid=$!

	for ((i = 0; i < espera; i++)); do
		mundo_listo "$log" && break
		kill -0 "$pid" 2>/dev/null || break
		sleep 1
	done

	if mundo_listo "$log"; then
		rc=0
	else
		echo "  FALLA: el mundo no llego a estar listo en ${espera}s (con $(basename "${lanzo[${#lanzo[@]}-1]}"))"
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
motor)
	case "${2:-}" in
	"")      echo "  motor elegido: $(motor_configurado)  (auto, ironwail o quakespasm)" ;;
	*)       motor_poner "$2" ;;
	esac
	;;
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
	echo "En macOS el motor principal no arranca: el OpenGL del sistema se queda"
	echo "en 4.1 y el necesita 4.3. El lanzador usa solo el motor ligero. Si"
	echo "quieres el otro, se cambia asi:"
	echo "    ./direkt.sh motor ironwail"
	echo "Ver LEE-ME-ENTORNO.md."
	;;
*)
	echo "Para usarlo:"
	echo "    tar xzf $(basename "$OUT")"
	echo "    cd $NOMBRE"
	echo "    ./direkt.sh"
	;;
esac
