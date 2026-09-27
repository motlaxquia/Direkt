#!/usr/bin/env bash
# Copia junto a los ejecutables las DLL que necesitan, y comprueba que no falte
# ninguna.
#
# En Linux y en macOS esto no hace nada: ahi los binarios se enlazan contra
# librerias del sistema o se dejan en /usr/lib, y se encuentran solas. En
# Windows no: un .exe de MinGW busca sus DLL en la misma carpeta y en el PATH, y
# si no las tiene no arranca. Y "no arrancar" en un .exe es silencioso: no
# imprime ni un error, solo sale con codigo distinto de cero. Asi que en Windows
# el selftest del editor fallaba sin decir una sola palabra.
#
# Sin esto, ademas, el paquete de Windows tampoco funcionaria en el equipo de
# nadie, porque en el de quien lo compila las DLL estaban en el MSYS2.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${DIREKT_BIN:-$REPO_ROOT/build/bin}"

# Si no se esta en Windows, no hay nada que hacer.
case "$(uname -s 2>/dev/null)" in
MINGW*|MSYS*|CYGWIN*) ;;
*)
	exit 0
	;;
esac

# Las DLL del propio Windows (kernel32, opengl32, gdi32...) las trae el sistema y
# no hay que copiarlas. Las de MINGW64 son las que hay que llevar, y estan en
# $prefix/bin.
prefix="${MINGW_PREFIX:-/mingw64}"

[ -d "$BIN" ] || { echo "copy-runtime-dlls: no existe $BIN" >&2; exit 1; }

# Nombre de todas las DLL que necesitan los .exe de la carpeta, deduplicado.
# ldd imprime una linea por dependencia:
#     libSDL2.dll => /mingw64/bin/libSDL2.dll   (0x...)
#     KERNEL32.dll                              (0x...)
# Las del segundo tipo las resuelve el sistema y se dejan.
dependencias() {
	local exe
	for exe in "$BIN"/*.exe; do
		[ -f "$exe" ] || continue
		ldd "$exe" 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /\.dll$/) print $i }'
	done | sort -u
}

faltan=0
while read -r dll; do
	case "$dll" in
	/*) ;;
	*) continue ;; # sin ruta: la trae el sistema
	esac
	case "$dll" in
	"$prefix"/*) ;;
	*) continue ;; # de otro sitio: no es nuestra
	esac
	base="$(basename "$dll")"
	if [ ! -f "$BIN/$base" ]; then
		cp -n "$dll" "$BIN/" 2>/dev/null || true
	fi
	if [ ! -f "$BIN/$base" ]; then
		echo "    AVISO: falta $base y no se ha podido copiar de $dll" >&2
		faltan=$((faltan + 1))
	fi
done < <(dependencias)

# Al final se vuelve a comprobar. Esto es lo que hace util al script: si falta
# alguna DLL, el .exe no va a arrancar, y eso en Windows no dice nada. Mejor que
# el fallo salga aqui, con el nombre de la libreria, y no tres pasos mas tarde
# como un "FALLA" sin explicar.
n=0
while read -r dll; do
	case "$dll" in
	"$prefix"/*) ;;
	*) continue ;;
	esac
	base="$(basename "$dll")"
	if [ ! -f "$BIN/$base" ]; then
		echo "    FALTA $base (la necesita $(basename "$(ls "$BIN"/*.exe 2>/dev/null | head -1)" 2>/dev/null))" >&2
		n=$((n + 1))
	fi
done < <(dependencias)

total="$(find "$BIN" -maxdepth 1 -iname '*.dll' | wc -l)"
if [ "$total" -gt 0 ]; then
	echo "    $total DLL junto a los .exe"
	find "$BIN" -maxdepth 1 -iname '*.dll' -printf '      %f\n' 2>/dev/null || \
		ls "$BIN" | grep -i '\.dll$' | sed 's/^/      /'
fi

if [ "$n" -gt 0 ] || [ "$faltan" -gt 0 ]; then
	echo "ERROR: hay DLL que los .exe necesitan y no tienen al lado. En Windows" >&2
	echo "       eso significa que no van a arrancar." >&2
	exit 1
fi
