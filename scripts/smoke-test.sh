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

# El interprete de Python no siempre se llama igual. En MSYS2 y en Windows es
# "python", en Linux y en macOS "python3". Se busca una vez aqui y se usa la
# variable en el resto del script, en vez de suponer que existe python3 y que
# el que tester vaya a recordarlo.
PY_CMD="$(command -v python3 || command -v python || true)"
[[ -n "$PY_CMD" ]] || { echo "ERROR: hace falta python3 o python" >&2; exit 1; }
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
  $PY_CMD - "$1" <<'PY'
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

# Nuestro propio pak. Va POR DELANTE de LibreQuake en el motor (es el primer
# -basedir), asi que un asset puede estar aqui y no en LibreQuake. Por eso se
# miran los dos: lo que este en cualquiera de los dos existe para el motor.
PAK_NUESTRO="$BUILD/datos/id1/pak0.pak"
[[ -f "$PAK_NUESTRO" ]] || die "falta el pak propio. Ejecuta 'make assets'."

# El inventario del PAK, una sola vez: se reusa para sprites y assets.
pak_list() { $PY_CMD "$REPO_ROOT/tools/pakinfo.py" "$PAK" --list; }

# Los tres sprites del juego. El formato es el de QuakeSpasm/Ironwail: cabecera
# de 36 bytes con numframes en 0x18, y detras un int de tipo de frame por cada
# uno, seguido de la imagen.
#
# Ademas del "esta presente" se comprueba el numero real de frames. Es el dato
# que delata un parser mal hecho: si numframes se lee de 0x04, que es donde esta
# la version, sale 1 siempre y el sprite parece valido mientras se pierde toda
# la animacion. Estos numeros estan contados a mano sobre los ficheros.
spr_json="$($PY_CMD "$REPO_ROOT/tools/sprinfo.py" "$PAK" --json 2>/dev/null)" \
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
  got="$(printf '%s' "$spr_json" | $PY_CMD -c '
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
nuestros="$("$PY_CMD" "$REPO_ROOT/tools/mpak.py" --listar "$PAK_NUESTRO" | awk '{print $2}')"
librequake="$(pak_list | awk '{print $2}')"
inventory="$nuestros
$librequake"
missing=0
while read -r name; do
  [[ -n "$name" ]] || continue
  if ! printf '%s\n' "$inventory" | grep -qE "(^|[[:space:]])$(sed 's/[.[\*^$]/\\&/g' <<<"$name")$"; then
    printf '        falta en el PAK: %s\n' "$name" >&2
    missing=$((missing + 1))
  fi
done < <(sed -n 's/^[[:space:]]*direkt_precache("\(.*\)");.*/\1/p' \
         "$REPO_ROOT/game/qc/assets.qc" | sort -u)

if ((missing == 0)); then
  ok "todos los assets precargados existen en algun PAK"
else
  ko "$missing assets precargados no existen en ningun PAK"
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
# El jugador tiene UNA vida (DIREKT_MAX_HEALTH), asi que va siempre lleno. Por
# eso tocar un botiquin no cura a nadie: el codigo lo rechaza a proposito porque
# sanar de mas se desperdicia (items.qc, direkt_salud_coger). Antes se comprobaba
# que los botiquines curaran, que era cierto con 100 de vida y ya no lo es.
#
# Lo que se comprueba ahora es lo contrario: que el mapa siga teniendo botiquines
# y que tocarlos no rompa nada. La logica de curar sigue cubierta por el selftest
# del editor, que la prueba con su propio jugador.
cura="$(grep -c "objeto cura al jugador" "$LOG" || true)"
botiquin="$(grep -c "prueba botiquin" "$LOG" || true)"
armadura="$(grep -c "objeto da armadura" "$LOG" || true)"
municion="$(grep -c "objeto da municion" "$LOG" || true)"
inventario="$(grep -c "objeto da inventario" "$LOG" || true)"

# Con una sola vida el jugador va siempre lleno, y un botiquin con la vida llena
# se rechaza a proposito: sanar de mas se desperdicia. Se comprueba que el
# botiquin se toca y que no hace nada, que es lo correcto.
if ((botiquin > 0)); then
  ok "el botiquin se toca y con la vida llena no hace nada ($botiquin)"
else
  ko "no se probo ningun botiquin del mapa"
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

head_ "8. Parkour: el juego ve las teclas y el deslizamiento funciona"

# Las teclas del parkour llegan al juego como impulso, porque el motor solo
# manda "mover, disparar, usar, saltar" y un impulso: ni Shift ni Ctrl se ven de
# otra forma. Shift es el modificador (mas adelante sera el dash) y Ctrl el
# deslizamiento.
#
# Se pulsan de verdad con xdotool. Si xdotool no esta (el banco de Linux lo
# instala, los demas no), se dice y se salta: es mejor que un fallo que parece
# del juego y no lo es.
if ! command -v xdotool >/dev/null 2>&1; then
  printf '  \033[33mNOSE\033[0m  xdotool no esta: las pruebas de teclas no se pueden hacer\n'
else
  LOG="$LOGS/run-$MAP.log"

  # El modificador se ve al pulsar y al soltar. Si no aparecen las dos, el juego
  # no esta viendo la tecla.
  if "$REPO_ROOT/scripts/run-headless.sh" --map "$MAP" --settle 6 --min-lit 0 \
       --golpes "space:4:0.6" --tecla "shift:3" >"$BUILD/parkour-mod.out" 2>&1; then
    _pulsado="$(grep -c "modificador pulsado" "$LOG" || true)"
    _soltado="$(grep -c "modificador soltado" "$LOG" || true)"
    if ((_pulsado > 0 && _soltado > 0)); then
      ok "el juego ve Shift (pulsado $_pulsado, soltado $_soltado)"
    else
      ko "el juego no ve Shift: el motor no pasa la tecla"
      tail -10 "$BUILD/parkour-mod.out" >&2
    fi
  else
    ko "el motor no arranco con Shift pulsada"
    tail -10 "$BUILD/parkour-mod.out" >&2
  fi

  # El suelo tiene que detectarse: sin el, el parkour entero no hace nada.
  # Con --jump el jugador se separa del suelo y vuelve, asi que tienen que verse
  # las dos señales: perderla solo y no volver a encontrarla tambien seria un fallo,
  # por eso se mira que las dos esten.
  if ((_pulsado > 0)); then
    _aire="$(grep -c "en el aire" "$LOG" || true)"
    _suelo="$(grep -c "en el suelo" "$LOG" || true)"
    if ((_aire > 0 && _suelo > 0)); then
      ok "el suelo se detecta y se pierde al saltar"
    else
      ko "el suelo no se detecta bien (aire=$_aire suelo=$_suelo)"
    fi
  fi

  # El salto. El motor no tiene ninguno (esta implementado en el juego, ver
  # direkt_salta), asi que esta comprobacion es la que dice si el jugador se
  # levanta de verdad. Sin --golpes no serviria: "+jump" en una cfg se queda
  # pulsado desde antes de que entre el jugador y el motor se come el flanco.
  # Se mide en la pista de parkour y no en el mapa grande ni en la caja de pruebas:
  # la caja tiene el techo a 64 y el vuelo se corta contra el, y en un mapa con
  # techos bajos la altura sale otra cosa. En la pista se salta a cielo abierto.
  if "$BUILD/bin/direkt-bsp" "$REPO_ROOT/src/test/parkour.map" \
       "$BUILD/datos/id1/maps/parkour.bsp" >"$BUILD/bsp-parkour.out" 2>&1 \
     && "$REPO_ROOT/scripts/run-headless.sh" --map parkour --settle 5 --min-lit 0 \
       --tecla "space:3" >"$BUILD/parkour-salto.out" 2>&1; then
    LOG="$LOGS/run-parkour.log"
    # Lo que se comprueba es el impulso, no la altura a la que llega el jugador. La
    # altura depende de cuantos frames dura el empuje y de cuanto dura cada frame, y
    # las dos cosas son del motor y de la maquina: en la CI el salto medido salia por
    # debajo de 55 con el mismo codigo que aqui da mas de 70. Con un numero fijo, la
    # prueba dependia de la maquina. El impulso lo pone el codigo nuestro y es el
    # mismo siempre, asi que ese si se puede comprobar.
    #
    # Y no solo que el jugador se mueva: que el salto sea del proyecto y no el del
    # motor, que es justo lo que faltaba antes.
    _fuerte="$(grep -c "el salto tira con fuerza" "$LOG" || true)"
    _flojo="$(grep -c "el salto tira flojo" "$LOG" || true)"
    _alto="$(grep -cE "el salto es (alto|gigante)" "$LOG" || true)"

    if ((_fuerte > 0)); then
      ok "el salto aplica el impulso del proyecto ($_fuerte saltos, $_alto altos)"
    else
      ko "nadie ha saltado con el impulso del proyecto: $_flojo flojos"
      echo "        log: $LOG" >&2
      tail -10 "$BUILD/parkour-salto.out" >&2
    fi
  else
    ko "el motor no arranco saltando"
    tail -10 "$BUILD/parkour-salto.out" >&2
  fi

  # Las cuatro habilidades del aire, en la pista de parkour (src/test/parkour.map).
  #
  # La pista va en +X a proposito: el angulo de la camara lo manda el cliente, no el
  # punto de aparicion del mapa, asi que al entrar el jugador mira a +X y la pista
  # tiene que ir en esa direccion para que las pruebas vayan por donde deben.
  #
  # Cada habilidad con su propia puesta en escena, porque dependen de estar en
  #_running_, en el _aire_, o con una pared al lado:
  #
  #   - bunny hop: Shift y espacio a la vez, corriendo por la pista larga.
  #   - dash y planeo: correr hasta el hueco y caer mientras se mantiene Shift. El
  #     dash sale en el aire; el planeo, mientras cae.
  #   - carrera por la pared: correr pegado al muro (nace a 20 unidades) y saltar.
  PARKOUR_LOG="$LOGS/run-parkour.log"

  _parkour() {   # mapa, espera, y el resto de argumentos para run-headless
    local _mapa="$1"; shift
    local _esp="$1"; shift
    "$REPO_ROOT/scripts/run-headless.sh" --map "$_mapa" --settle "$_esp" \
      --min-lit 0 "$@"
  }

  # El mapa tiene que compilar y existir.
  if "$BUILD/bin/direkt-bsp" "$REPO_ROOT/src/test/parkour.map" \
       "$BUILD/datos/id1/maps/parkour.bsp" >"$BUILD/bsp-parkour.out" 2>&1; then
    ok "la pista de parkour compila"
  else
    ko "la pista de parkour no compila"
    tail -5 "$BUILD/bsp-parkour.out" >&2
    PARKOUR_LOG=""
  fi

  if [[ -n "$PARKOUR_LOG" ]]; then
    # 1. Bunny hop: correr con Shift y saltar, con el Shift mantenido y el espacio
    # pulsandose cada 0,5 s.
    #
    # Se hace con dos comandos y no con un acorde Shift+espacio porque, con el
    # acorde, el banco no siempre ve la tecla modificadora continua (ver lo que se
    # cuenta mas abajo del deslizamiento) y entonces solo se engancha un salto. Con
    # pulsaciones separadas se engancha la cadena entera, que es lo que hay que
    # comprobar.
    if _parkour parkour 8 --walk --golpes "space:8:0.5" \
         --tecla "shift:5" --test-de 0.5 >"$BUILD/parkour-bhop.out" 2>&1; then
      # Se cuentan las dos cosas que dicen que la velocidad se conserva:
      #
      #   - "encadenado normal/rapido": la velocidad con la que entra cada salto, que
      #     es justo lo que el bunny hop devuelve al aterrizar.
      #   - "bunny hop normal/rapido": del informe de movimiento, la maxima
      #     horizontal alcanzada en el aire. Si el bunny hop perdiera la velocidad en
      #     cada suelo, esta se quedaria por debajo de 300.
      #
      # Con el banco no siempre se ve la tecla modificadora continua (X11 y sus
      # repeticiones, ya explicado mas abajo), asi que se acepta cualquiera de las
      # dos: las dos necesitan que la velocidad se haya conservado.
      _encadenado="$(grep -c "bunny hop encadenado normal\|bunny hop encadenado rapido" "$PARKOUR_LOG" || true)"
      _maxima="$(grep -c "bunny hop normal\|bunny hop rapido" "$PARKOUR_LOG" || true)"
      if ((_encadenado > 0)); then
        ok "el bunny hop conserva la velocidad al encadenar ($_encadenado saltos)"
      elif ((_maxima > 0)); then
        ok "el bunny hop conserva la velocidad en el aire ($_maxima informes)"
      else
        ko "el bunny hop pierde la velocidad: ni al encadenar ni en el aire"
        grep -oE "bunny hop[a-z ]*" "$PARKOUR_LOG" | sort | uniq -c >&2
      fi
    else
      ko "el motor no arranco con Shift y espacio"
      tail -10 "$BUILD/parkour-bhop.out" >&2
    fi

    # 2. Dash, y en su propia pista (src/test/dash.map), llana y sin una sola pared.
    #
    # En la pista de parkour no se puede medir: el jugador nace a 20 del muro y la
    # carrera por la pared tiene prioridad sobre el dash, se lo come y no dispara.
    # Aqui el banco pulsa adelante + espacio + Shift: el jugador corre, despega, y el
    # despegue con Shift es el dash. El "adelante" va en el acorde porque el dash
    # empuja en la direccion de vuelo y hace falta velocidad de verdad.
    if "$BUILD/bin/direkt-bsp" "$REPO_ROOT/src/test/dash.map" \
         "$BUILD/datos/id1/maps/dash.bsp" >"$BUILD/bsp-dash.out" 2>&1; then
      ok "la pista de dash compila"
    else
      ko "la pista de dash no compila"
      tail -5 "$BUILD/bsp-dash.out" >&2
    fi

    if "$REPO_ROOT/scripts/run-headless.sh" --map dash --settle 1 --min-lit 0 \
         --tecla "w+space+shift:6" >"$BUILD/parkour-dash.out" 2>&1; then
      _dash="$(grep -c "DIREKT: dash" "$BUILD/logs/run-dash.log" || true)"
      if ((_dash > 0)); then
        ok "el dash sale al despegar con Shift ($_dash)"
      else
        ko "el dash no sale al despegar con Shift"
        echo "        log: $BUILD/logs/run-dash.log" >&2
        tail -10 "$BUILD/parkour-dash.out" >&2
      fi
    else
      ko "el motor no arranco con adelante, espacio y Shift"
      tail -10 "$BUILD/parkour-dash.out" >&2
    fi

    # 3. Planeo, en su propia pista (src/test/glide.map).
    #
    # Alli el jugador cae de cabeza desde 3000 y no hay nada que pulsar todavia. El
    # banco le pone Shift a los ~1,5 s, con la caida en curso, y asi el tope de 200
    # entra en juego de verdad. El aviso "frenando la caida" solo sale si el recorte
    # trabajo, asi que es lo unico que demuestra que frena y no solo que se pone.
    if "$BUILD/bin/direkt-bsp" "$REPO_ROOT/src/test/glide.map" \
         "$BUILD/datos/id1/maps/glide.bsp" >"$BUILD/bsp-glide.out" 2>&1; then
      ok "la pista de planeo compila"
    else
      ko "la pista de planeo no compila"
      tail -5 "$BUILD/bsp-glide.out" >&2
    fi

    GLIDE_LOG="$BUILD/logs/run-glide.log"
    if "$REPO_ROOT/scripts/run-headless.sh" --map glide --settle 1 --min-lit 0 \
         --tecla "shift:7" >"$BUILD/parkour-glide.out" 2>&1; then
      _planeo="$(grep -c "DIREKT: planeo frenando la caida" "$GLIDE_LOG" || true)"
      _puesto="$(grep -c "DIREKT: planeo" "$GLIDE_LOG" || true)"

      if ((_puesto > 0)); then
        ok "el planeo se pone mientras se cae ($_puesto avisos)"
      else
        ko "el planeo no se pone nunca"
        echo "        log: $GLIDE_LOG" >&2
        tail -10 "$BUILD/parkour-glide.out" >&2
      fi

      if ((_planeo > 0)); then
        ok "el planeo frena la caida de verdad ($_planeo avisos)"
      else
        ko "el planeo no frena la caida: no sale el aviso del recorte"
        echo "        log: $GLIDE_LOG" >&2
        tail -10 "$BUILD/parkour-glide.out" >&2
      fi
    else
      ko "el motor no arranco con Shift en la pista de planeo"
      tail -10 "$BUILD/parkour-glide.out" >&2
    fi

    # 4. Carrera por la pared: correr pegado al muro y saltar.
    if _parkour parkour 8 --walk --golpes "space:6:0.5" \
         --tecla "shift:5" --test-de 0.5 >"$BUILD/parkour-muro.out" 2>&1; then
      _muro="$(grep -c "DIREKT: carrera por la pared" "$PARKOUR_LOG" || true)"
      if ((_muro > 0)); then
        ok "la carrera por la pared se engancha ($_muro)"
      else
        ko "la carrera por la pared no se engancha nunca"
        tail -10 "$BUILD/parkour-muro.out" >&2
      fi
    else
      ko "el motor no arranco con Shift junto al muro"
      tail -10 "$BUILD/parkour-muro.out" >&2
    fi
  fi

  # El deslizamiento: hay que ir rapido (por eso la espera antes de pulsar) y
  # agachado, y el deslizamiento se agacha solo. Lo que se comprueba es que
  # entra, que sale por el tramo alto (o sea que se libra del recorte de
  # velocidad del agachado, que lo dejaria todo en 100) y que se acaba al soltar.
  #
  # Se mide en el mapa del dash (dash.map), que es una explanada de 2048 por 2048,
  # y no en el grande. Dos razones, y las dos son que el jugador tiene que llegar a
  # 300 antes de que le de tiempo a chocar con nada:
  #
  #   - En el mapa grande se estrella contra un muro a las 500-1000 unidades y se
  #     queda alli contra el happening. En la CI se quedaba con velocidad cero y el
  #     deslizamiento no llegaba a entrar nunca; en local llegaba a entrar por
  #     casualidad, antes de chocar.
  #   - La aceleracion del motor es por frame (PM_Accelerate mete una cantidad fija
  #     en cada frame), no por segundo. En una maquina con pocos frames por segundo
  #     el jugador tarda muchisimo mas en llegar a 300. En la CI, con 2 nucleos y
  #     dibujo por software, eso son varios segundos. Por eso la espera sale de
  #     SETTLE, que es el parametro que la CI sube ya para esas maquinas.
  #
  # Y la direccion no se controla, porque "+forward" va hacia donde mire la camara,
  # y la camara al entrar esta en el origen. En una explanada cuadrada da igual
  # hacia donde mire: hay sitio para acelerar en las cuatro direcciones.
  _espera_ctrl=5
  if [[ "${SETTLE:-0}" -ge 20 ]]; then
    _espera_ctrl=25
  fi
  if "$REPO_ROOT/scripts/run-headless.sh" --map dash --settle 6 --min-lit 0 \
       --walk --tecla "ctrl:8:$_espera_ctrl" >"$BUILD/parkour-slide.out" 2>&1; then
    LOG="$LOGS/run-dash.log"
    # El log se sobrescribe en cada prueba que use este mapa, asi que la del
    # deslizamiento se aparta. Sin esto, cuando falla no hay forma de mirar que
    # vio el juego: el log que queda es el de la ultima prueba del mapa.
    cp "$LOG" "$LOGS/slide.log" 2>/dev/null || :
    _entradas="$(grep -c "DIREKT: deslizando" "$LOG" || true)"
    _salidas="$(grep -c "se acaba el deslizamiento" "$LOG" || true)"
    _rapido="$(grep -cE "el deslizamiento sale (muy )?rapido" "$LOG" || true)"

    if ((_entradas > 0)); then
      ok "el deslizamiento entra ($_entradas)"
    else
      ko "el deslizamiento nunca entra"
      echo "        log: $LOGS/slide.log" >&2
      echo "        velocidad del jugador en esa partida:" >&2
      grep -oE "DIREKT: (velocidad[^e]*|apoyado en el suelo|en el aire)" \
        "$LOGS/slide.log" 2>/dev/null | sort | uniq -c >&2 || :
      echo "        espera antes de pulsar Ctrl = ${_espera_ctrl}s" >&2
      tail -10 "$BUILD/parkour-slide.out" >&2
    fi

    if ((_rapido > 0)); then
      ok "el deslizamiento sale por encima del tope de agachado"
    else
      ko "el deslizamiento sale por debajo del tope de agachado"
      echo "        log: $LOG" >&2
    fi

    if ((_salidas > 0)); then
      ok "el deslizamiento se acaba al soltar la tecla"
    else
      ko "el deslizamiento no se acaba nunca"
    fi

    # Cuantas veces puede entrar el deslizamiento con la tecla seguida. Lo ideal es
    # una, y lo normal es una: con la tecla mantenida solo se entra al pulsar.
    #
    # Pero el banco de pruebas no siempre ve la tecla continua. X11 manda
    # Una pulsacion de Ctrl tiene que dar exactamente un deslizamiento. Antes se
    # permitian hasta 4 porque se creia que el teclado de X hacia esto solo, y en
    # realidad era un bloque del arnes de pruebas repetido cuatro veces.
    if ((_entradas == 1)); then
      ok "el deslizamiento entra y se acaba ($_entradas veces)"
    else
      ko "el deslizamiento no se repite, $_entradas veces"
      echo "        log: $LOG" >&2
    fi
  else
    ko "el motor no arranco con Ctrl pulsada"
    tail -10 "$BUILD/parkour-slide.out" >&2
  fi
fi

head_ "9. La musica se pide por nombre"

# La musica se puede pedir de dos maneras y las dos tienen que funcionar:
#
#   "music" "pista.ogg"   Direkt. Busca ese fichero en music/ por su nombre.
#   "sounds" "5"          de toda la vida. El 5 es un numero de pista.
#
# Aqui se prueban las dos, y tambien el fallo honesto: si el mapa pide una pista
# que no existe, el motor lo dice y no se queda mudo sin avisar.
MUSICA_MAP="musica"
MUSICA_NUMERO_MAP="musica-numero"
MUSICA_FALTA_MAP="musica-falta"

for _m in "$MUSICA_MAP" "$MUSICA_NUMERO_MAP" "$MUSICA_FALTA_MAP"; do
  if "$BUILD/bin/direkt-bsp" "$REPO_ROOT/src/test/$_m.map" \
       "$BUILD/datos/id1/maps/$_m.bsp" >"$BUILD/bsp-$_m.out" 2>&1; then
    ok "el mapa $_m compila"
  else
    ko "el mapa $_m no compila"
    tail -5 "$BUILD/bsp-$_m.out" >&2
  fi
done

# El comando bgm_catalogo dice que pistas hay y en que numero. Si no lista
# ninguna, la clave "music" no puede funcionar.
if "$REPO_ROOT/scripts/run-headless.sh" --map "$MUSICA_MAP" --settle 4 \
     --min-lit 0 --cfg-line 'bgm_catalogo' >"$BUILD/musica-catalogo.out" 2>&1; then
  _lineas="$(grep -cE '^ +[0-9]+ +music/' "$LOGS/run-$MUSICA_MAP.log" || true)"
  if ((_lineas > 0)); then
    ok "bgm_catalogo lista las pistas ($_lineas)"
  else
    ko "bgm_catalogo no lista ninguna pista"
    echo "        log: $LOGS/run-$MUSICA_MAP.log" >&2
  fi

  # Los ficheros tienen que llamarse por el escenario, no trackNN. Quedarse con
  # los nombres viejos seria volver al orden que se queria quitar.
  _viejos="$(grep -cE '^ +[0-9]+ +music/track[0-9]+' \
             "$LOGS/run-$MUSICA_MAP.log" || true)"
  if ((_viejos == 0)); then
    ok "las pistas se llaman por el escenario y no trackNN"
  else
    ko "quedan $_viejos pistas con el nombre viejo trackNN"
  fi

  # Y la tabla que traduce el numero viejo al nombre tiene que estar puesta.
  if [[ -f "$BUILD/datos/id1/music/pistas.txt" ]] \
     && grep -q "feudal_anomaly.ogg" "$BUILD/datos/id1/music/pistas.txt"; then
    ok "music/pistas.txt relaciona el numero viejo con el nombre nuevo"
  else
    ko "music/pistas.txt falta o no relaciona los nombres"
  fi

  # El mapa pide gloomliths.ogg. El motor tiene que acabar intentando abrir ese
  # fichero concreto, no "music/trackNN" inventado ni el numero.
  if grep -q "music/gloomliths.ogg" "$LOGS/run-$MUSICA_MAP.log"; then
    ok "el mundospawn \"music\" se resuelve al fichero pedido"
  else
    ko "el mundospawn \"music\" no llega al fichero pedido"
    grep -iE "musica|track" "$LOGS/run-$MUSICA_MAP.log" | head -5 >&2
  fi
else
  ko "el motor no arranco con bgm_catalogo"
  tail -10 "$BUILD/musica-catalogo.out" >&2
fi

# El numero viejo: el mapa con "sounds" no debe entrar por el camino nuevo ni
# quejarse. Que no avise es la prueba.
if "$REPO_ROOT/scripts/run-headless.sh" --map "$MUSICA_NUMERO_MAP" --settle 4 \
     --min-lit 0 >"$BUILD/musica-numero.out" 2>&1; then
  if ! grep -qiE "no esta en music|Musica del mapa" "$LOGS/run-$MUSICA_NUMERO_MAP.log"; then
    ok "\"sounds\" sigue funcionando por su cuenta"
  else
    ko "\"sounds\" se ha colado en el camino de la musica por nombre"
  fi
else
  ko "el motor no arranco con el mapa de musica por numero"
  tail -10 "$BUILD/musica-numero.out" >&2
fi

# Los ficheros se llaman por el escenario, pero los mapas de LibreQuake ponen un
# numero. La tabla music/pistas.txt traduce uno por otro, asi que "sounds" 5 tiene
# que acabar abriendo feudal_anomaly.ogg (la pista 5 de LibreQuake).
#
# No se puede comprobar oyendolo con el sonido apagado: BGM_PlayCDtrack se sale
# antes de llegar al puente cuando no hay CD ni decodificador. Lo que se comprueba
# es que el motor lea la tabla y sepa que el 5 es feudal_anomaly, que es
# exactamente lo que consulta el puente.
if "$REPO_ROOT/scripts/run-headless.sh" --map "$MUSICA_NUMERO_MAP" --settle 4 \
     --min-lit 0 --cfg-line 'bgm_catalogo tabla' \
     >"$BUILD/musica-puente.out" 2>&1; then
  if grep -qE '^ +5 +feudal_anomaly\.ogg' "$LOGS/run-$MUSICA_NUMERO_MAP.log"; then
    ok "el motor lee music/pistas.txt y relaciona el 5 con feudal_anomaly"
  else
    ko "el motor no leo bien music/pistas.txt"
    grep -A12 "Tabla de pistas" "$LOGS/run-$MUSICA_NUMERO_MAP.log" | head -12 >&2
  fi
else
  ko "el motor no arranco al probar la tabla de pistas"
  tail -10 "$BUILD/musica-puente.out" >&2
fi

# Pista que no existe: el motor lo dice y ademas sigue por el numero, con lo
# cual el mapa no se queda mudo.
if "$REPO_ROOT/scripts/run-headless.sh" --map "$MUSICA_FALTA_MAP" --settle 4 \
     --min-lit 0 >"$BUILD/musica-falta.out" 2>&1; then
  if grep -q "no-existe.ogg" "$LOGS/run-$MUSICA_FALTA_MAP.log"; then
    ok "una pista inexistente se avisa en vez de callarse"
  else
    ko "una pista inexistente no avisa nada"
    grep -iE "musica|track" "$LOGS/run-$MUSICA_FALTA_MAP.log" | head -5 >&2
  fi
else
  ko "el motor no arranco con el mapa de musica inexistente"
  tail -10 "$BUILD/musica-falta.out" >&2
fi

# Los tres mapas de esta seccion se compilan dentro de build/datos para que el
# motor los encuentre, y ahi se acabarian en el paquete portable. Se borran
# despues de probarlos, que es lo que se lleva uno.
for _m in "$MUSICA_MAP" "$MUSICA_NUMERO_MAP" "$MUSICA_FALTA_MAP" parkour; do
  rm -f "$BUILD/datos/id1/maps/$_m.bsp"
done

head_ "10. La version del paquete se lee y no se pierde"

# El menu (tools/menu.py) lee la version del paquete de una linea "version = ..." en
# direkt.conf para avisar si hay una release mas nueva. Esa linea la escribe
# scripts/portable.sh al empaquetar, y "direkt.sh motor X" la reescribe sin perderla.
#
# Antes de esto nada la escribia: la funcion estaba ahi desde el principio pero no
# tenia nada que leer, y la version vivia escrita a mano en varios sitios.
if [[ -f "$REPO_ROOT/VERSION" ]]; then
  _version="$(tr -d ' \t\r\n' < "$REPO_ROOT/VERSION")"
  if [[ "$_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    ok "el VERSION tiene un numero de version ($_version)"
  else
    ko "el VERSION no es un numero de version: '$_version'"
  fi

  if grep -qE "<dt>Version</dt><dd>v?$_version<" "$REPO_ROOT/index.html"; then
    ok "index.html dice la misma version que VERSION"
  else
    ko "index.html no dice la version del VERSION (puede ser v$_version)"
    grep -oE "<dt>Version</dt><dd>[^<]*" "$REPO_ROOT/index.html" >&2 || true
  fi

  # El menu tiene que entender el formato que escribe portable.sh. Se comprueba
  # sobre un conf de mentira con ese formato, y no sobre el paquete entero, porque
  # "make test" no empaqueta.
  _tmp="$(mktemp -d)"
  printf 'version = %s\n' "$_version" > "$_tmp/direkt.conf"
  _leida="$(python3 -c '
import sys
sys.path.insert(0, sys.argv[1] + "/tools")
import menu
from pathlib import Path
print(menu.version_local(Path(sys.argv[2])) or "")
' "$REPO_ROOT" "$_tmp")"
  rm -rf "$_tmp"

  if [[ "$_leida" == "$_version" ]]; then
    ok "el menu lee la version del paquete ($_leida)"
  else
    ko "el menu no lee la version del paquete: leyo '$_leida'"
  fi

  # Y que portable.sh sea quien la escribe, leyendo el VERSION. Sin esto, el conf
  # podria dejar de llevar la version sin que nada se entere.
  if grep -q 'PAQUETE_VERSION="$(tr -d' scripts/portable.sh \
     && grep -q "printf 'version = %s" scripts/portable.sh; then
    ok "portable.sh escribe la version en el conf del paquete"
  else
    ko "portable.sh no escribe la version en el conf del paquete"
  fi
else
  ko "no existe el fichero VERSION"
fi

head_ "Resultado"
printf '  %d pasan, %d fallan\n\n' "$pass" "$fail"
((fail == 0)) || exit 1
printf '\033[32mSMOKE TEST CORRECTO\033[0m\n'
