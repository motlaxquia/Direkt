#!/usr/bin/env bash
# Copia junto a los ejecutables las DLL que necesitan.
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
BIN="$REPO_ROOT/build/bin"

# Si no se esta en Windows, no hay nada que hacer.
case "$(uname -s 2>/dev/null)" in
MINGW*|MSYS*|CYGWIN*) ;;
*)
  exit 0
  ;;
esac

# Las DLL del propio Windows (kernel32, opengl32, gdi32...) las trae el sistema
# y no hay que copiarlas. Las de MINGW64 son las que hay que llevar, y en
# /mingw64/bin.
pref="${MINGW_PREFIX:-/mingw64}"

[ -d "$BIN" ] || { echo "copy-runtime-dlls: no existe $BIN" >&2; exit 1; }

copiadas=0
for exe in "$BIN"/*.exe; do
	[ -f "$exe" ] || continue
	# ldd imprime una linea por dependencia: "nombre => ruta (0x...)". Las que
	# no tienen ruta son las que el sistema resuelve solo, y se ignoran.
	ldd "$exe" 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /\.dll$/) print $i }' |
	while read -r dll; do
		case "$dll" in
		/*) ;;
		*) continue ;;
		esac
		# Solo las de MINGW64. /c/Windows/System32 y las de la API de Windows
		# no se copian.
		case "$dll" in
		"$pref"/*)
			cp -n "$dll" "$BIN/" 2>/dev/null && :
			;;
		esac
	done
done

# ldd con "while" en un subshell no actualiza la variable de fuera, asi que se
# cuenta aparte lo que hay ahora mismo en la carpeta.
copiadas="$(find "$BIN" -maxdepth 1 -iname '*.dll' | wc -l)"
if [ "$copiadas" -gt 0 ]; then
	echo "    $copiadas DLL junto a los .exe"
	find "$BIN" -maxdepth 1 -iname '*.dll' -printf '      %f\n' 2>/dev/null || \
		ls "$BIN" | sed 's/^/      /'
fi
