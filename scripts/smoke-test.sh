#!/usr/bin/env bash
# Smoke test de Direkt: comprueba la cadena completa, de punta a punta.
#
#   make test
#
# Son tres cosas y las tres tienen que pasar:
#
#   1. DATOS   Los tres sprites de LibreQuake se validan con tools/sprinfo.py y
#              todo lo que el juego precarga existe de verdad en los PAK.
#   2. ARRANQUE El motor carga NUESTRO progs.dat, encuentra el punto de
#              aparicion y no se queja de ninguna entidad sin funcion de spawn.
#   3. RENDER  Los sprites de LibreQuake se DIBUJAN. Esto se mide, no se supone:
#              se compara una captura con el escaparate compilado contra otra
#              sin el, y la zona central de la pantalla tiene que encenderse.
#
# El interruptor del escaparate es de compilacion (DIREKT_NOSHOWCASE, ver el
# target game-noshowcase del Makefile) y no un cvar porque el motor no tiene
# ningun comando para crear un cvar: "direkt_showcase 1" en un cfg responde
# Unknown command.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$REPO_ROOT/build"
MAP="${MAP:-lqdm1}"
SETTLE="${SETTLE:-6}"
SHOTS="$BUILD/shots"
LOGS="$BUILD/logs"
PROGS="$REPO_ROOT/direkt/progs.dat"
PROGS_NS="$BUILD/progs-noshowcase.dat"

# La diferencia de brillo en el centro entre las dos capturas fue de ~21 niveles
# sobre ~255, con el ruido de animacion del mapa en el orden de 1. Un umbral de
# 10 deja margen de sobra sin poder ser un falso positivo.
DELTA_MIN="${DELTA_MIN:-10}"

pass=0
fail=0
ok()   { printf '  \033[32mPASA\033[0m  %s\n' "$*"; pass=$((pass + 1)); }
ko()   { printf '  \033[31mFALLA\033[0m %s\n' "$*"; fail=$((fail + 1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

centre_mean() {
  python3 - "$1" <<'PY'
import subprocess, sys
p = sys.argv[1]
# El recorte es PORCENTAJE, no un tamaño fijo. La captura es de la pantalla
# entera de Xvfb, que no tiene por que ser la que pidio el juego: si hay otro
# Xvfb ya encendido, o se cambia DIREKT_WIDTH/HEIGHT, el resultado es otro.
# Con 640x480 fijos, una captura de 1280x720 recortaba una zona del borde
# negro, y la medida daba lo mismo con el escaparate puesto y sin el.
raw = subprocess.run(
    ["convert", p, "-gravity", "center", "-crop", "35%x35%+0+0", "+repage",
     "-colorspace", "Gray", "-depth", "8", "gray:-"],
    capture_output=True, check=True).stdout
if not raw:
    print("nan"); raise SystemExit
print(f"{sum(raw) / len(raw):.4f}")
PY
}

head_ "1. Datos de LibreQuake"

PAK="$BUILD/lq/full/id1/pak0.pak"
[[ -f "$PAK" ]] || die "faltan los datos. Ejecuta 'make deps'."

# El inventario del PAK, una sola vez: se reusa para sprites y assets.
pak_list() { python3 "$REPO_ROOT/tools/pakinfo.py" "$PAK" --list; }

# Los tres sprites del juego. El formato es el de QuakeSpasm/Ironwail: cabecera
# de 36 bytes con numframes en 0x18, y detras un int de tipo de frame por cada
# uno, seguido de la imagen.
#
# Ademas del "esta presente" se comprueba el numero real de frames. Es el dato
# que delata un parser mal hecho: si numframes se lee de 0x04, que es donde esta
# la version, sale 1 siempre y el sprite parece valido mientras se pierde toda
# la animacion. Estos numeros estan contados a mano sobre los ficheros.
spr_json="$(python3 "$REPO_ROOT/tools/sprinfo.py" "$PAK" --json 2>/dev/null)" \
  || die "tools/sprinfo.py no pudo leer $PAK"
n_spr="$(printf '%s' "$spr_json" | grep -c '"name":')"
if ((n_spr > 0)); then
  ok "sprinfo valida $n_spr sprites en $PAK"
else
  ko "sprinfo no encontro ningun sprite en $PAK"
fi

for spec in s_bubble:2 s_light:1 s_explod:6; do
  spr="${spec%:*}"
  want="${spec##*:}"
  got="$(printf '%s' "$spr_json" | python3 -c '
import json, sys
nombre = sys.argv[1]
for sprite in json.load(sys.stdin):
    if sprite["name"].endswith("/" + nombre + ".spr"):
        print(sprite["numframes"])
        break
else:
    print(0)
' "$spr")"
  if [[ "$got" == "$want" ]]; then
    ok "$spr: presente y valido, $got frame(s)"
  else
    ko "$spr: esperaba $want frame(s) y hay $got"
  fi
done

# Todo lo que el juego precarga tiene que existir en el PAK. Si no, el motor
# avisa por el log y el resultado depende del que le pase: mejor fallar aqui.
inventory="$(pak_list)"
missing=0
while read -r name; do
  [[ -n "$name" ]] || continue
  if ! printf '%s\n' "$inventory" | grep -qE "[[:space:]]$(sed 's/[.[\*^$]/\\&/g' <<<"$name")$"; then
    printf '        falta en el PAK: %s\n' "$name" >&2
    missing=$((missing + 1))
  fi
done < <(sed -n 's/^[[:space:]]*direkt_precache("\(.*\)");.*/\1/p' \
         "$REPO_ROOT/game/qc/assets.qc" | sort -u)

if ((missing == 0)); then
  ok "todos los assets precargados existen en el PAK"
else
  ko "$missing assets precargados no existen en el PAK"
fi

head_ "2. Arranque con progs.dat propio"

[[ -s "$PROGS" ]]    || die "falta direkt/progs.dat. Ejecuta 'make game'."
[[ -s "$PROGS_NS" ]] || die "falta $PROGS_NS. Ejecuta 'make game-noshowcase'."

# Copia buena del binario con escaparate. Se trabaja sobre una copia para no
# depender del orden de make, y para poder volver a ella al final: durante la
# prueba se instala la variante sin escaparate encima de direkt/progs.dat.
BACKUP="$BUILD/progs-smoke-backup.dat"
cp "$PROGS" "$BACKUP"

run_variant() {
  # $1 = progs.dat a instalar, $2 = etiqueta
  cp "$1" "$PROGS"
  if ! "$REPO_ROOT/scripts/run-headless.sh" --map "$MAP" --settle "$SETTLE" --min-lit 0 \
        >"$BUILD/smoke-$2.out" 2>&1; then
    tail -15 "$BUILD/smoke-$2.out" >&2
    return 1
  fi
  cp "$SHOTS/$MAP.png" "$SHOTS/smoke-$2.png"
  return 0
}

if run_variant "$BACKUP" on; then
  ok "el motor arranca y renderiza con el escaparate"
else
  ko "el motor no arranco con el escaparate"
  die "sin captura no hay nada que medir"
fi

LOG="$LOGS/run-$MAP.log"
grep -q "DIREKT: progs.dat propio cargado" "$LOG" \
  && ok "cargo nuestro progs.dat" \
  || ko "no aparece el marcador de progs.dat propio"

grep -q "DIREKT: hay punto de aparicion" "$LOG" \
  && ok "encontro el punto de aparicion" \
  || ko "no encontro punto de aparicion en $MAP"

grep -q "DIREKT: 3 sprites de LibreQuake en escena" "$LOG" \
  && ok "los 3 sprites se crearon" \
  || ko "no se crearon los sprites"

if grep -q "No spawn function" "$LOG"; then
  ko "quedan entidades del mapa sin funcion de spawn"
  grep -c "No spawn function" "$LOG" >&2
else
  ok "toda entidad del mapa tiene funcion de spawn"
fi

if grep -qE "Host_Error|Segmentation fault" "$LOG"; then
  ko "el motor reporto un error grave"
  grep -nE "Host_Error|Segmentation fault" "$LOG" | head -5 >&2
else
  ok "ningun error grave en el log"
fi

head_ "3. Los sprites se dibujan de verdad"

# Al terminar, direct/progs.dat se queda con la variante con escaparate, que es
# la que se usa en juego.
trap 'cp "$BACKUP" "$PROGS"' EXIT

if run_variant "$PROGS_NS" off; then
  ok "el motor arranca y renderiza sin el escaparate"
else
  ko "el motor no arranco sin el escaparate"
fi

grep -q "DIREKT: escaparate apagado" "$LOGS/run-$MAP.log" \
  && ok "la variante sin escaparase se identifica en el log" \
  || ko "la variante sin escaparate no se identifica"

on_mean="$(centre_mean "$SHOTS/smoke-on.png")"
off_mean="$(centre_mean "$SHOTS/smoke-off.png")"
delta="$(awk "BEGIN{print $on_mean - $off_mean}")"

printf '        centro con sprites    = %s / 255\n' "$on_mean"
printf '        centro sin sprites    = %s / 255\n' "$off_mean"
printf '        diferencia            = %s (minimo %s)\n' "$delta" "$DELTA_MIN"

if awk "BEGIN{exit !($delta > $DELTA_MIN)}"; then
  ok "el escaparate enciende la zona central: los sprites se dibujan"
else
  ko "el escaparate no cambia la imagen: los sprites NO se dibujan"
  echo "        capturas: $SHOTS/smoke-on.png y $SHOTS/smoke-off.png" >&2
fi

head_ "4. El jugador se mueve de verdad"

# El motor hace la fisica (SV_Physics_Client -> SV_WalkMove) y la entrada llega
# por la red como una tecla de verdad: el cfg mete "+forward" y "+right", que
# dejan el estado de la tecla pulsado. Asi se prueba la cadena entera en vez de
# teletransportar al jugador desde QuakeC.
#
# El informe de player.qc no puede imprimir cifras (no hay sprintf ni ftos), asi
# que va por escalones de umbrales sobre un odometro. Se exige haber recorrido
# al menos 500 unidades en 8 segundos, con diferencia amplia respecto a un
# jugador parado.
# Se instala la variante buena: esta seccion prueba el binario que se usa en
# juego, no el que dejo la seccion 3.
cp "$BACKUP" "$PROGS"
if "$REPO_ROOT/scripts/run-headless.sh" --map "$MAP" --settle 8 --min-lit 0 \
      --walk --turn >"$BUILD/smoke-walk.out" 2>&1; then
  ok "el motor arranca con entrada de teclado sintetica"
else
  ko "el motor no arranco con entrada de teclado"
  tail -10 "$BUILD/smoke-walk.out" >&2
fi

walked="$(grep -cE "recorre (de 500 a 1000|mas de 1000)" "$LOGS/run-$MAP.log" || true)"
still="$(grep -c "no se ha movido" "$LOGS/run-$MAP.log" || true)"

if ((walked > 0)); then
  ok "el jugador recorrio mas de 500 unidades ($walked informes)"
else
  ko "el jugador no se movio: la entrada de teclado no llega al servidor"
  echo "        log: $LOGS/run-$MAP.log" >&2
fi

if grep -q 'Unknown command "forward"' "$LOGS/run-$MAP.log"; then
  ko 'el motor recibio "forward" sin el + (el + se pierde en la linea de comandos)'
fi

if ((still == walked)) && ((still > 0)); then
  ko "mitad de los informes dicen que no se mueve: el movimiento es irregular"
fi

head_ "5. El agachado encoge la caja y se puede volver a levantar"

# El impulso 22 pone en marcha una cadena de thinks en player.qc que se agacha,
# comprueba la caja y se levanta. Se comprueba la caja, no solo el aviso: lo que
# deja pasar por un hueco es mins/maxs, y un agachado que solo bajara la
# camara dejaria al jugador con la misma altura y atascado en los huecos.
if "$REPO_ROOT/scripts/run-headless.sh" --map "$MAP" --settle 10 --min-lit 0 \
      --extra "+impulse 22" >"$BUILD/smoke-agachado.out" 2>&1; then
  ok "el motor arranca con la prueba de agachado"
else
  ko "el motor no arranco con la prueba de agachado"
  tail -10 "$BUILD/smoke-agachado.out" >&2
fi

LOG="$LOGS/run-$MAP.log"

if grep -q "el agachado encoge la caja y baja el ojo" "$LOG"; then
  ok "agachado: la caja se encoge y el ojo baja"
elif grep -q "el agachado no encoge la caja" "$LOG"; then
  ko "agachado: la caja NO se encoge: revisa direkt_agacha"
  echo "        log: $LOG" >&2
else
  ko "la prueba de agachado no llego a ejecutarse"
  echo "        log: $LOG" >&2
fi

if grep -q "al levantarse vuelve la caja de pie" "$LOG"; then
  ok "al levantarse vuelve la caja de pie"
else
  ko "al levantarse la caja no vuelve a ser la de pie: el jugador se queda agachado"
  echo "        log: $LOG" >&2
fi

# Agachado se camina mas despacio que de pie. El motor limita la velocidad con
# sv_maxspeed, que es global, asi que el tope se recorta en el QC. Se exige que
# andando agachado no se supere nunca la velocidad de andar de pie.
head_ "6. Agachado se anda mas despacio que de pie"
if "$REPO_ROOT/scripts/run-headless.sh" --map "$MAP" --settle 10 --min-lit 0 \
      --walk --extra "+impulse 20" >"$BUILD/smoke-agachado-walk.out" 2>&1; then
  ok "el motor arranca andando y agachado"
else
  ko "el motor no arranco andando y agachado"
  tail -10 "$BUILD/smoke-agachado-walk.out" >&2
fi

LOG="$LOGS/run-$MAP.log"
agachado_rapido="$(grep -c "velocidad por encima de 200" "$LOG" || true)"
agachado_lento="$(grep -c "velocidad de 50 a 200" "$LOG" || true)"

if ((agachado_rapido > 0)); then
  ko "agachado se mueve a mas de 200: el recorte de velocidad no se aplica"
  echo "        log: $LOG" >&2
elif ((agachado_lento > 0)); then
  ok "agachado se queda por debajo del tope ($agachado_lento informes)"
else
  ko "no se pudo medir la velocidad andando agachado"
  echo "        log: $LOG" >&2
fi

head_ "7. Los objetos del mapa se pueden coger"
if "$REPO_ROOT/scripts/run-headless.sh" --map "$MAP" --settle 25 --min-lit 0 \
      --cfg-line 'alias selftest "impulse 9"' \
      --cfg-line 'wait 120' \
      --cfg-line 'selftest' >"$BUILD/smoke-objetos.out" 2>&1; then
  ok "el motor arranca con el selftest de objetos"
else
  ko "el motor no arranco con el selftest de objetos"
  tail -10 "$BUILD/smoke-objetos.out" >&2
fi

LOG="$LOGS/run-$MAP.log"

# El selftest tiene que terminar recorriendo el mapa entero: si se queda
# enganchado en el mismo objeto, el find devuelve siempre el primero de su
# clase y la linea "el mapa no tiene mas objetos" nunca sale.
if grep -q "el mapa no tiene mas objetos" "$LOG"; then
  ok "el selftest recorrio todos los objetos del mapa"
else
  ko "el selftest no llego al final: se quedo repetir el mismo objeto"
  echo "        log: $LOG" >&2
fi

# Un objeto que da efecto tiene que notarlo, sea del tipo que sea.
# En un mapa de LibreQuake siempre hay botiquines, armaduras y municion.
cura="$(grep -c "objeto cura al jugador" "$LOG" || true)"
armadura="$(grep -c "objeto da armadura" "$LOG" || true)"
municion="$(grep -c "objeto da municion" "$LOG" || true)"
inventario="$(grep -c "objeto da inventario" "$LOG" || true)"

if ((cura > 0)); then
  ok "los botiquines curan ($cura)"
else
  ko "ningun botiquin curo al jugador"
fi

if ((armadura > 0)); then
  ok "las armaduras dan armadura ($armadura)"
else
  ko "ninguna armadura dio armadura"
fi

if ((municion > 0)); then
  ok "las cajas de municion se recogen ($municion)"
else
  ko "ninguna caja de municion se recogio"
fi

if ((inventario > 0)); then
  ok "las armas se anaden al inventario ($inventario)"
else
  ko "ningun arma se anadio al inventario"
fi

# Al cambiar de arma, el contador de municion tiene que pasar al cubo del arma
# nueva. currentammo es el numero grande del HUD y ademas lo consulta el
# disparante para decidir si queda municion: si no se refresca, el HUD ensena
# la cifra del arma anterior y se deja disparar un arma que no tiene balas.
if grep -q "el cambio de arma pasa la municion" "$LOG"; then
  ok "cambiar de arma pasa el contador de municion al cubo nuevo"
elif grep -q "el cambio de arma deja la municion vieja" "$LOG"; then
  ko "cambiar de arma deja la municion del arma anterior: revisa direkt_arma_poner"
  echo "        log: $LOG" >&2
elif ! grep -q "no hay arma de fuego para probar" "$LOG"; then
  ko "la prueba de cambio de arma no llego a ejecutarse"
  echo "        log: $LOG" >&2
fi

# El touch de los objetos tiene que funcionar de verdad. Si el solid se
# asigna despues del setorigin, el objeto se ve pero no se puede coger, y
# casi todo el mapa aparece sin ningun efecto. Se comprueba que por cada
# objeto probado sale alguna linea de tipo o de efecto.
probados="$(grep -c "prueba " "$LOG" || true)"
conefecto=$((cura + armadura + municion + inventario))
if ((probados > 0 && conefecto * 4 < probados)); then
  ko "casi ningun objeto hace nada: revisa el solid antes de setorigin"
  echo "        probados: $probados, con efecto: $conefecto" >&2
fi

head_ "Resultado"
printf '  %d pasan, %d fallan\n\n' "$pass" "$fail"
((fail == 0)) || exit 1
printf '\033[32mSMOKE TEST CORRECTO\033[0m\n'
