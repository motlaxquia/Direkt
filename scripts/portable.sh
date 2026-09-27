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

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$REPO/build"
BIN="$BUILD/bin"
LQ="$BUILD/lq/full"
STAGE="$BUILD/portable"
OUT="$BUILD/direkt-portable.tar.gz"
NOMBRE="direkt-portable"

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
cp "$BIN/ironwail" "$BIN/direkt-bsp" "$BIN/direkt-edit" "$STAGE/bin/"
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
( cd "$STAGE/fuente/cache" && sha256sum ironwail-src.tar.gz > ironwail-src.tar.gz.sha256 )

# --- lanzador ---------------------------------------------------------------
# El motor toma el directorio de datos con -basedir y el de la logica con
# -game. El lanzador se encarga de eso para que no haya que memorizar los
# parametros, y de plano para que funcione desde donde se descomprima.
cat > "$STAGE/direkt.sh" <<'FIN'
#!/usr/bin/env bash
# Lanzador de Direkt. Se llama desde donde este el paquete.
#
#   ./direkt.sh            abre el juego con el mapa inicial
#   ./direkt.sh editor     abre el editor de niveles
#   ./direkt.sh bsp a b    compila el mapa a en b.bsp
#   ./direkt.sh test       comprueba que el paquete arranca de verdad
#   ./direkt.sh shell      deja una shell con el directorio en $PATH
set -euo pipefail
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$AQUI/bin:$PATH"

# El generador de .bsp saca las texturas de ahi. En el repositorio mira en
# build/lq/full/id1, que aqui no existe: sin esto el .bsp sale sin lump TEXTURES
# y el motor pinta todo con la textura por defecto.
export DIREKT_GAMEDIR="$AQUI/datos/id1"

jugar() {
	exec "$AQUI/bin/ironwail" -basedir "$AQUI/datos" -basedir "$AQUI" \
		-game direkt "$@"
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
		# Ya hay pantalla. No se levanta otro Xvfb por encima: dos anidados se
		# quedan esperando el uno al otro y esto no termina nunca.
		lanzo=("$AQUI/bin/ironwail")
	elif command -v xvfb-run >/dev/null 2>&1; then
		lanzo=(xvfb-run -a "$AQUI/bin/ironwail")
	else
		echo "  no hay pantalla ni xvfb-run: se prueba a pelo y puede que el"
		echo "  motor no pueda abrir una ventana"
		lanzo=("$AQUI/bin/ironwail")
	fi

	"${lanzo[@]}" -basedir "$AQUI/datos" -basedir "$AQUI" -game direkt \
		-nosound -window -width 640 -height 480 +map lqdm1 >"$log" 2>&1 &
	pid=$!

	# La senal de que el mundo esta listo la da la propia logica de juego: si
	# encuentra el punto de aparicion, el mapa esta cargado y el jugador
	# existe. Con rasterizado por software esto lleva mas de un minuto, asi que
	# el margen es de 180 s.
	for ((i = 0; i < espera; i++)); do
		grep -q "punto de aparicion" "$log" && break
		kill -0 "$pid" 2>/dev/null || break
		sleep 1
	done

	if grep -q "punto de aparicion" "$log"; then
		rc=0
	else
		echo "  FALLA: el mundo no llego a estar listo en ${espera}s"
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
	# que si seria grave es que no encuentre NUESTRO cfg, el del smoke test.
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
editor)  exec "$AQUI/bin/direkt-edit" "${2:-}" ;;
bsp)     exec "$AQUI/bin/direkt-bsp" "$2" "$3" ;;
shell)   echo "PATH=$AQUI/bin:$PATH"; exec "${SHELL:-/bin/sh}" ;;
*)       jugar "$@" ;;
esac
FIN
chmod +x "$STAGE/direkt.sh"

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
tar czf "$OUT" -C "$BUILD" "$NOMBRE"
rm -rf "$BUILD/$NOMBRE"

echo "==> $OUT"
ls -lh "$OUT" | awk '{print "    " $5 "  " $9}'
echo
echo "Para usarlo:"
echo "    tar xzf $(basename "$OUT")"
echo "    cd $NOMBRE"
echo "    ./direkt.sh"
