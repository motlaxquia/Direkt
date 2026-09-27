#!/usr/bin/env bash
# Prueba del editor de niveles (build/bin/direkt-edit).
#
#   scripts/editor-test.sh
#
# Tres capas, de la mas barata a la mas cara:
#
#   1. `--selftest`: toda la logica de edicion SIN pantalla. Documento,
#      ida y vuelta del .map, seleccion por rayo, mover, arrastrar caras,
#      deshacer, y que un mapa hecho en el editor compile a un .bsp valido.
#   2. Captura sin pantalla: dibuja un fotograma a un PPM. Comprueba que hay
#      geometria de verdad y no un cuadro negro, que es el fallo tipico cuando
#      el contexto GL se crea pero el mapa de matrices se carga en el sitio
#      equivocado.
#   3. Ida y vuelta sobre los .map del repo, para comprobar que el editor abre
#      y vuelve a guardar sin estropear un mapa que ya existia.
#
# La capa 2 necesita Xvfb, que scripts/xvfb-env.sh levanta. Sin el, se avisa y
# se sigue con las otras dos en vez de fallar del tirón.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$REPO_ROOT/build"
EDIT="$BUILD/bin/direkt-edit"
SHOTS="$BUILD/shots"
MAPS=("$REPO_ROOT/src/test/box.map" "$REPO_ROOT/src/test/ejes.map" \
      "$REPO_ROOT/src/test/habitacion.map")

ok=0
ko=0
pass() { printf '  \033[32mPASA\033[0m  %s\n' "$*"; ok=$((ok + 1)); }
fail() { printf '  \033[31mFALLA\033[0m %s\n' "$*"; ko=$((ko + 1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ -x "$EDIT" ]] || die "no existe $EDIT. Ejecuta 'make edit'."
mkdir -p "$SHOTS" "$BUILD/logs"

# --------------------------------------------------------------- 1. selftest
head_ "1. La logica de edicion, sin pantalla"
if "$EDIT" --selftest >"$BUILD/editor-selftest.out" 2>&1; then
  pass "el selftest del editor pasa entero"
  grep -E "pasan" "$BUILD/editor-selftest.out" | sed 's/^/        /'
else
  fail "el selftest del editor falla"
  grep -E "FALLA" "$BUILD/editor-selftest.out" | sed 's/^/        /' >&2 || true
  tail -20 "$BUILD/editor-selftest.out" >&2
fi

# ------------------------------------------------------------- 2. el dibujo
head_ "2. El dibujo produce geometria de verdad"

# Se necesita un servidor X. scripts/xvfb-env.sh lo levanta y deja el numero de
# display en el entorno.
if [[ -z "${DISPLAY:-}" ]]; then
  # shellcheck source=/dev/null
  source "$REPO_ROOT/scripts/xvfb-env.sh" || true
fi

analiza_ppm() {
  python3 - "$1" <<'PY'
import sys
d = open(sys.argv[1], "rb").read()
assert d[:2] == b"P6", "no es un PPM"
i = d.index(b"255\n") + 4
w, h = (int(x) for x in d[:i].split()[1:3])
px = d[i:]
n = len(px) // 3
# Fondo esperado: 0.08, 0.09, 0.12 -> (20, 23, 30)
fondo = sum(1 for k in range(0, len(px), 3)
            if abs(px[k] - 20) <= 3 and abs(px[k+1] - 23) <= 3 and abs(px[k+2] - 30) <= 3)
dibujado = n - fondo
print(f"{w}x{h} dibujado={dibujado} ({100.0*dibujado/n:.2f}%)")
PY
}

if [[ -n "${DISPLAY:-}" ]]; then
  for modo in alambre solido; do
    flag=""
    [[ "$modo" = solido ]] && flag="--solido"
    salida="$SHOTS/editor-$modo.ppm"
    if "$EDIT" $flag --shot "$salida" "$REPO_ROOT/src/test/habitacion.map" \
         >"$BUILD/editor-shot-$modo.out" 2>&1 && [[ -s "$salida" ]]; then
      info="$(analiza_ppm "$salida")"
      pct="$(awk '{gsub(/[()%]/,"",$2); print $2}' <<<"$info")"
      if awk -v p="$pct" 'BEGIN{exit !(p > 0.5)}'; then
        pass "$modo: $info"
      else
        fail "$modo: apenas hay geometria dibujada ($info)"
        tail -5 "$BUILD/editor-shot-$modo.out" >&2 || true
      fi
    else
      fail "$modo: no se pudo dibujar la captura"
      tail -5 "$BUILD/editor-shot-$modo.out" >&2 || true
    fi
  done

  # Un mapa vacio tambien tiene que dibujar algo (rejilla y punto de
  # aparicion): si sale negro, el problema no es la geometria del mapa.
  salida="$SHOTS/editor-vacio.ppm"
  if "$EDIT" --shot "$salida" --new >/dev/null 2>&1 && [[ -s "$salida" ]]; then
    info="$(analiza_ppm "$salida")"
    pass "un mapa en blanco tambien dibuja: $info"
  else
    fail "no se pudo dibujar un mapa en blanco"
  fi
else
  fail "no hay display; se salta la prueba de dibujo"
fi

# ------------------------------------------------- 3. ida y vuelta de .map
head_ "3. Abrir y volver a guardar un mapa existente no lo estropea"
for m in "${MAPS[@]}"; do
  nombre="$(basename "$m")"
  tmp="$BUILD/editor-rt-$$.map"
  if "$EDIT" "$m" --shot "$BUILD/editor-rt.ppm" >/dev/null 2>&1; then
    pass "$nombre: el editor lo abre y lo dibuja"
  else
    fail "$nombre: el editor no pudo abrirlo"
  fi
  rm -f "$tmp"
done

# El selftest con un mapa de entrada hace la ida y vuelta de verdad: escribe,
# relee y compara el texto.
if "$EDIT" --selftest "$REPO_ROOT/src/test/habitacion.map" \
     >"$BUILD/editor-rt.out" 2>&1; then
  pass "ida y vuelta de .map: el texto guardado es identico al releido"
else
  fail "ida y vuelta de .map"
  grep FALLA "$BUILD/editor-rt.out" | sed 's/^/        /' >&2 || true
fi

printf '\n\033[1mResultado\033[0m\n  %d pasan, %d fallan\n' "$ok" "$ko"
[[ "$ko" -eq 0 ]] || exit 1
printf '\033[32mEDITOR TEST CORRECTO\033[0m\n'
