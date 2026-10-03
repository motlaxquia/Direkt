#!/usr/bin/env bash
# Comprueba que el paquete portable REALLY encuentra los datos propios.
#
#   scripts/paquete-test.sh
#
# POR QUE ESTE FICHERO
#
# El fallo que se ha dado: el codigo del juego pide progs/gibhead.mdl, que vive
# en el pak propio (build/datos), pero scripts/portable.sh seguia montando el
# paquete con LibreQuake en un solo basedir. El arbol de build funcionaba y las
# pruebas pasaban; el paquete, no. El motor avisa "model not precached" y la
# cabeza no sale nunca.
#
# En el arbol de build ya se comprueba (run-headless.sh usa los dos basedirs).
# Aqui se comprueba el OTRO camino, el que usa la gente: descomprimir el
# tarball y arrancarlo con el lanzador de verdad.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$REPO_ROOT/build"
TARBALL="${1:-$BUILD/direkt-portable-linux.tar.gz}"
TRABAJO="$(mktemp -d)"
trap 'rm -rf "$TRABAJO"' EXIT

ok() { printf '  PASA  %s\n' "$1"; }
ko() { printf '  FALLA %s\n' "$1"; }

[[ -f "$TARBALL" ]] || { printf 'ERROR: no existe %s. Ejecuta "make portable".\n' "$TARBALL" >&2; exit 1; }

printf 'El paquete portable encuentra los datos propios\n'

tar xzf "$TARBALL" -C "$TRABAJO"
RAIZ="$(find "$TRABAJO" -mindepth 1 -maxdepth 1 -type d | head -1)"
[[ -n "$RAIZ" ]] || { echo "ERROR: el tarball esta vacio" >&2; exit 1; }

# 1. UN basedir con los paks renumerados. El motor los recorre en orden, asi que
#    pak0 siendo nuestro es lo que hace que lo nuestro gane.
for p in pak0.pak pak1.pak pak2.pak; do
  [[ -f "$RAIZ/datos/id1/$p" ]] || {
    ko "falta datos/id1/$p"
    printf '        hay: %s\n' "$(ls "$RAIZ/datos/id1" 2>/dev/null | tr '\n' ' ')" >&2
    exit 1
  }
done
ok "el paquete tiene pak0 nuestro y pak1/pak2 de LibreQuake"

[[ -d "$RAIZ/datos-lq" ]] && {
  ko "el paquete todavia trae datos-lq/, que ya no se usa"
  exit 1
}

# 2. El pak propio tiene la cabeza, y el lanzador usa los dos basedirs.
PY_CMD="$(command -v python3 || command -v python || true)"
if [[ -n "$PY_CMD" ]] && "$PY_CMD" "$REPO_ROOT/tools/mpak.py" --listar "$RAIZ/datos/id1/pak0.pak" 2>/dev/null \
     | grep -q "progs/gibhead.mdl"; then
  ok "el pak propio lleva la cabeza"
else
  ko "el pak propio no lleva progs/gibhead.mdl"
  exit 1
fi

# Quakespasm solo lee el PRIMER -basedir, con lo que un basedir de mas rompe el
# motor ligero. Se comprueba que no haya mas de uno de datos.
n_basedir="$(grep -o 'basedir [^ ]*datos[^ ]*' "$RAIZ/direkt.sh" | sort -u | wc -l)"
if [[ "$n_basedir" == 1 ]]; then
  ok "el lanzador pasa un solo basedir de datos"
else
  ko "el lanzador pasa $n_basedir basedirs de datos; Quakespasm solo lee el primero"
  exit 1
fi

# Display propio. Sin esto el motor no abre ventana y falla sin decir por que.
# (Un xvfb-run dentro de este script seria un xvfb-run dentro de otro.)
DISPLAY_NUM=":99"
XVFB_PID=""
if command -v Xvfb >/dev/null 2>&1; then
  Xvfb "$DISPLAY_NUM" -screen 0 640x480x24 </dev/null >"$TRABAJO/xvfb.log" 2>&1 &
  XVFB_PID=$!
  sleep 2
fi

# 3. Y lo que de verdad importa: que el motor, con el layout del PAQUETE,
#    arranque un mapa y no se queje de nada.
#
#    Se lanza el motor directamente y no con "direkt.sh test" a proposito: esto
#    comprueba el layout de datos, y el "test" del lanzador tiene su propia
#    comprobacion de cuadencia que en este entorno se queda esperando aunque el
#    motor entre bien (con rutas relativas entra; con las absolutas del script
#    se queda en el banner). Eso es otro fallo y este fichero no viene a
#    taparlo.
#
#    Los argumentos son los mismos que usa el lanzador.
LOG="$TRABAJO/paquete.log"
(
  cd "$RAIZ" || exit 1
  DISPLAY="$DISPLAY_NUM" timeout 90 stdbuf -oL -eL ./bin/ironwail \
    -basedir ./datos -basedir . -game direkt \
    -nosound -window -width 640 -height 480 +map lqdm1
) >"$LOG" 2>&1 || true
[[ -n "${XVFB_PID:-}" ]] && kill "$XVFB_PID" 2>/dev/null

if ! grep -qE "entered the game" "$LOG"; then
  ko "el motor no llega a entrar en el mapa con el layout del paquete"
  tail -15 "$LOG" >&2
  exit 1
fi
ok "el motor entra en el mapa con el layout del paquete"

if grep -qiE "not precached|no se pudo cargar|unable to load|QUAKE ERROR" "$LOG"; then
  ko "el motor se queja de algo que no encuentra en el paquete"
  grep -iE "not precached|no se pudo cargar|unable to load|QUAKE ERROR" "$LOG" | head -5 >&2
  exit 1
fi
ok "no falta ningun asset en el paquete"

printf '\nPAQUETE TEST CORRECTO\n'
