#!/usr/bin/env bash
# Prueba del generador de .bsp (build/bin/direkt-bsp).
#
#   scripts/bsp-test.sh [--sin-motor]
#
# Cuatro capas, de la mas barata a la mas cara:
#
#   1. Los tres .map de src/test compilan sin error.
#   2. --check valida el .bsp YA ESCRITO: offsets, tamanos, indices, ciclos y
#      nodos inalcanzables. El motor no valida nada de eso.
#   3. Las consultas de colision del hull 1 dan lo que dicen las brushes
#      dilatadas. Se replican las tres reglas de SV_RecursiveHullCheck.
#   4. El motor carga el mapa, el jugador se apoya en el suelo y anda hasta
#      toparse con un muro. Esto es lo que de verdad importa.
#
# El paso 4 necesita el motor y los datos, o sea make engine primero, y ademas
# una pantalla: sin ella no hay contexto de OpenGL y el motor no arranca. Con
# --sin-motor se hacen solo los pasos 1 a 3, que es lo que se puede probar en
# macOS o en un runner de Windows.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$REPO_ROOT/build"
BSP="$BUILD/bin/direkt-bsp"
LQ="$BUILD/lq/full"
ENGINE_BIN="$BUILD/bin/ironwail"
MAPS=("$REPO_ROOT/src/test/box.map" "$REPO_ROOT/src/test/ejes.map" \
      "$REPO_ROOT/src/test/habitacion.map")
OUT="$BUILD/lq/full/id1/maps/direkt-test.bsp"
LOG="$BUILD/logs/run-direkt-test.log"

ok=0
ko=0
pass() { printf '  \033[32mPASA\033[0m  %s\n' "$*"; ok=$((ok + 1)); }
fail() { printf '  \033[31mFALLA\033[0m %s\n' "$*"; ko=$((ko + 1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# El interprete de Python no siempre se llama igual. En MSYS2 y en Windows es
# "python", en Linux y en macOS "python3". Se busca una vez aqui y se usa la
# variable en el resto del script, en vez de suponer que existe python3 y que
# el que tester vaya a recordarlo.
PY_CMD="$(command -v python3 || command -v python || true)"
[[ -n "$PY_CMD" ]] || { echo "ERROR: hace falta python3 o python" >&2; exit 1; }

# Sin pantalla no hay forma de arrancar el motor, y en macOS y en un runner de
# Windows no la hay. Con --sin-motor se prueban las secciones 1 a 4, que son
# las que no necesitan ventana; la 5 se deja para Linux.
SIN_MOTOR=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sin-motor) SIN_MOTOR=1 ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) die "opcion desconocida: $1" ;;
  esac
  shift
done

[[ -x "$BSP" ]] || die "no existe $BSP. Ejecuta 'make bsp'."

# ---------------------------------------------------------------- 1. compilar
head_ "1. Los .map de prueba compilan"
for m in "${MAPS[@]}"; do
  nombre="$(basename "$m")"
  if "$BSP" "$m" "$OUT" >/dev/null 2>"$BUILD/bsp-test.err"; then
    pass "$nombre"
  else
    fail "$nombre"
    tail -5 "$BUILD/bsp-test.err" >&2
  fi
done

# ------------------------------------------------------------------ 2. --check
head_ "2. El .bsp escrito pasa el validador"
for m in "${MAPS[@]}"; do
  nombre="$(basename "$m")"
  "$BSP" "$m" "$OUT" >/dev/null 2>&1
  if "$BSP" --check "$OUT" >/dev/null 2>&1; then
    pass "$nombre: offsets, indices y arbol sin ciclos"
  else
    fail "$nombre"
    "$BSP" --check "$OUT" 2>&1 | sed 's/^/        /' >&2
  fi
done

# Un .bsp corrupto TIENE que ser detectado. Si check_bsp se traga cualquier
# cosa, el test de arriba no vale para nada.
head_ "3. El validador detecta un .bsp roto"
cp "$OUT" "$BUILD/bsp-roto.bsp"
# Se cambia el planenum del primer clipnode por uno fuera de rango.
$PY_CMD - "$BUILD/bsp-roto.bsp" <<'PY'
import struct, sys
p = sys.argv[1]
d = bytearray(open(p, "rb").read())
ofs = [struct.unpack_from("<2i", d, 4 + 8 * i) for i in range(15)]
o = ofs[9][0]
n = ofs[1][1] // 20
struct.pack_into("<i", d, o, n + 1000)
open(p, "wb").write(bytes(d))
PY
if "$BSP" --check "$BUILD/bsp-roto.bsp" >/dev/null 2>&1; then
  fail "el validador acepto un clipnode con un plano inventado"
else
  pass "el clipnode con planenum fuera de rango se detecta"
fi

# ---------------------------------------------------------------- 4. colision
head_ "4. La colision del hull 1 coincide con las brushes dilatadas"
if [[ ! -f "$(dirname "$0")/hullcheck.py" ]]; then
  fail "falta scripts/hullcheck.py"
else
  for m in "${MAPS[@]}"; do
    nombre="$(basename "$m")"
    "$BSP" "$m" "$OUT" >/dev/null 2>&1
    salida="$($PY_CMD "$REPO_ROOT/scripts/hullcheck.py" "$m" "$OUT" | tail -1)"
    if grep -qE "^0 discrepancias" <<<"$salida"; then
      pass "$nombre: $salida"
    else
      fail "$nombre: $salida"
      $PY_CMD "$REPO_ROOT/scripts/hullcheck.py" "$m" "$OUT" | grep MAL | sed 's/^/        /' >&2 || true
    fi
  done
fi

# ------------------------------------------------------------------- 5. motor
head_ "5. El motor carga el mapa y el jugador se apoya y anda"
if ((SIN_MOTOR)); then
  echo "  se salta: hace falta pantalla y se pidio --sin-motor"
elif [[ ! -x "$ENGINE_BIN" ]]; then
  fail "no hay motor en $ENGINE_BIN; se salta la prueba en vivo (make engine)"
else
  if "$REPO_ROOT/scripts/run-headless.sh" --map direkt-test --settle 10 --walk --min-lit 0 \
       --cfg-line 'alias probe "impulse 23"' --cfg-line 'wait 200' --cfg-line 'probe' \
       >"$BUILD/bsp-test-motor.out" 2>&1; then
    pass "el motor arranca con el mapa generado por direkt-bsp"
  else
    fail "el motor no arranco"
    tail -10 "$BUILD/bsp-test-motor.out" >&2
  fi
  if grep -q "apoyado en el suelo" "$LOG"; then
    pass "el jugador se apoya en el suelo (FL_ONGROUND)"
  else
    fail "el jugador no se apoya: atraviesa el suelo"
    tail -5 "$LOG" >&2
  fi
  if grep -q "recorre de 200 a 500 unidades\|recorre de 50 a 200 unidades" "$LOG"; then
    pass "el jugador anda y los muros lo paran"
  else
    fail "el jugador no anda o no chocan los muros"
    tail -5 "$LOG" >&2
  fi
fi

printf '\n\033[1mResultado\033[0m\n  %d pasan, %d fallan\n' "$ok" "$ko"
[[ "$ko" -eq 0 ]] || exit 1
printf '\033[32mBSP TEST CORRECTO\033[0m\n'
