#!/usr/bin/env bash
# Prueba del generador de .bsp (build/bin/direkt-bsp).
#
#   scripts/bsp-test.sh
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
# El paso 4 necesita el motor y los datos, o sea make engine primero.
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
python3 - "$BUILD/bsp-roto.bsp" <<'PY'
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
    salida="$(python3 "$REPO_ROOT/scripts/hullcheck.py" "$m" "$OUT" | tail -1)"
    if grep -qE "^0 discrepancias" <<<"$salida"; then
      pass "$nombre: $salida"
    else
      fail "$nombre: $salida"
      python3 "$REPO_ROOT/scripts/hullcheck.py" "$m" "$OUT" | grep MAL | sed 's/^/        /' >&2 || true
    fi
  done
fi

# ------------------------------------------------------------------- 5. motor
head_ "5. El motor carga el mapa y el jugador se apoya y anda"
if [[ ! -x "$ENGINE_BIN" ]]; then
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
