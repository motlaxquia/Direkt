#!/usr/bin/env bash
# Ejecuta Direkt sin pantalla fisica.
#
#   scripts/run-headless.sh --map lqdm1 [--settle 4] [--min-lit 15] [--extra arg]
#
# Estrategia: en vez de confiar en que el motor termine solo (no lo hace de forma
# fiable con render por software), se arranca en segundo plano, se espera a que
# el mundo este listo, se captura la ventana X y se le manda SIGTERM. Asi el
# test depende solo de "arranca, dibuja y produce imagen", no del apagado.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# El interprete de Python no siempre se llama igual. En MSYS2 y en Windows es
# "python", en Linux y en macOS "python3". Se busca una vez aqui y se usa la
# variable en el resto del script, en vez de suponer que existe python3 y que
# el que tester vaya a recordarlo.
PY_CMD="$(command -v python3 || command -v python || true)"
[[ -n "$PY_CMD" ]] || { echo "ERROR: hace falta python3 o python" >&2; exit 1; }
BUILD="$REPO_ROOT/build"
# Se puede probar el otro motor con DIREKT_TEST_ENGINE=quakespasm. Los dos
# llevan el mismo progs.dat y los mismos mapas, asi que las pruebas tienen que
# dar lo mismo en los dos.
# Se puede probar el otro motor con DIREKT_TEST_ENGINE=quakespasm. Los dos
# llevan el mismo progs.dat y los mismos mapas, asi que las pruebas tienen que
# dar lo mismo en los dos.
if [[ -n "${DIREKT_TEST_ENGINE:-}" ]]; then
	ENGINE_BIN="$BUILD/bin/$DIREKT_TEST_ENGINE"
else
	ENGINE_BIN="$BUILD/bin/ironwail"
fi
LQ="$BUILD/lq/full"          # basedir: el motor exige <basedir>/id1/pak0.pak
GAMEDIR_NAME="direkt"
LOGS="$BUILD/logs"
SHOTS="$BUILD/shots"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*" >&2; }

MAP="lqdm1"
WANT_SHOT=1
SETTLE=4
# Fraccion minima de pixeles con luz en los 2/3 superiores (es decir, por encima
# de la barra de estado). lqdm1 ronda el 77%; lq_e1m1 se queda en el 5% porque
# su spawn mira a un pasillo sin iluminar. Sirve para distinguir "renderizo la
# escena" de "solo draw de HUD".
MIN_LIT=15
WIDTH="${DIREKT_WIDTH:-640}"
HEIGHT="${DIREKT_HEIGHT:-480}"
BOOT_TIMEOUT=180
EXTRA=()
CFG_LINE=()
# Entrada de juego real. "+forward" es un comando de CLIENTE que deja el estado
# de la tecla pulsado hasta el "-forward" correspondiente, asi que el cliente
# manda forwardmove = cl_forwardspeed en cada frame y el jugador anda de verdad:
# es la cadena completa teclado -> usercmd -> red -> SV_ReadClientMove ->
# host_client->cmd -> SV_ClientThink -> SV_WalkMove. No hay forma de inyectar
# esto desde QuakeC porque host_client->cmd es una estructura de C.
#
# "+messagemode 2" pone key_dest = key_game. En monojugador el motor solo
# SV_ClientThink si key_dest == key_game, asi que sin esto el jugador no se
# mueve aunque tenga las teclas pulsadas.
WALK=0
TURN=0
JUMP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --map)     MAP="$2"; shift 2 ;;
    --shot)    WANT_SHOT=1; shift ;;
    --no-shot) WANT_SHOT=0; shift ;;
    --settle)  SETTLE="$2"; shift 2 ;;
    --min-lit) MIN_LIT="$2"; shift 2 ;;
    --width)   WIDTH="$2"; shift 2 ;;
    --height)  HEIGHT="$2"; shift 2 ;;
    --gamedir) GAMEDIR_NAME="$2"; shift 2 ;;
    # --extra se parte en palabras: el motor reconstruye la linea de comandos
    # uniendo argv, y Quake corta cada bloque "+comando" en el siguiente "+",
    # asi que "+direkt_debug 1" tiene que llegar como DOS argumentos.
    --extra)   read -r -a _extra_words <<<"$2"; EXTRA+=("${_extra_words[@]}"); shift 2 ;;
    # --cfg-line mete una linea tal cual en direkt/direkt-test.cfg. Preferible
    # a --extra para cvars y comandos largos (ver el limite de 255 caracteres).
    --cfg-line) CFG_LINE+=("$2"); shift 2 ;;
    --walk)     WALK=1; shift ;;
    --turn)     TURN=1; shift ;;
    --jump)     JUMP=1; shift ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) die "opcion desconocida: $1" ;;
  esac
done

[[ -x "$ENGINE_BIN" ]] || die "no existe el motor en $ENGINE_BIN. Ejecuta 'make engine'."
[[ -f "$LQ/id1/pak0.pak" ]] || die "faltan los datos. Ejecuta 'make deps'."
[[ -d "$REPO_ROOT/$GAMEDIR_NAME" ]] || die "no existe $GAMEDIR_NAME/. Ejecuta 'make game'."

mkdir -p "$LOGS" "$SHOTS" "$BUILD/run"

# shellcheck source=./xvfb-env.sh
DIREKT_WIDTH="$WIDTH" DIREKT_HEIGHT="$HEIGHT" source "$REPO_ROOT/scripts/xvfb-env.sh"

LOG="$LOGS/run-$MAP.log"
rm -f "$LOG" "$SHOTS/$MAP.png"

# Un cfg dentro del directorio del juego. Dos motivos:
#   * el comando exec de Quake solo acepta un nombre de fichero y lo busca en la
#     ruta de busqueda, nunca una ruta absoluta;
#   * el motor trunca la linea de comandos a 255 caracteres, asi que todo lo
#     que no quepa tiene que ir aqui y no en los argumentos.
TESTCFG="direkt-test.cfg"
CFG_TMP="$LOGS/$TESTCFG.creando"
{
  echo "// generado por scripts/run-headless.sh, no editar a mano"
  echo 'echo "DIREKT:cfg-executed"'
  # Ver la nota de WALK: los "+comando" de tecla van aqui, no en los args.
  [[ $WALK -eq 1 ]] && echo '+forward'
  [[ $TURN -eq 1 ]] && echo '+right'
  [[ $JUMP -eq 1 ]] && echo '+jump'
  printf '%s\n' "${CFG_LINE[@]}"
} >"$CFG_TMP"

# Ironwail busca en el segundo -basedir, pero Quakespasm solo mira el primero, con
# lo que la cfg hay que dejarla en los dos. Si solo se escribe en uno, el otro
# motor avisa "couldn't exec <cfg>" y las pruebas que dependen de ella fallan.
CFG_DESTINOS=(
  "$REPO_ROOT/$GAMEDIR_NAME"
  "$REPO_ROOT/build/lq/full/$GAMEDIR_NAME"
)
for _dir in "${CFG_DESTINOS[@]}"; do
  mkdir -p "$_dir"
  cp "$CFG_TMP" "$_dir/$TESTCFG"
done
rm -f "$CFG_TMP"

# Rutas relativas a proposito: argv[0] entra tambien en la linea de comandos que
# el motor trunca, y las rutas absolutas de este repo se comen ~40 caracteres.
# El primer -basedir es el nuestro: lo que hay en el gana a los paks de
# LibreQuake, que van en el segundo. Ver el comentario de DATOS en el Makefile.
args=(
  -basedir build/datos
  -basedir build/lq/full
  -basedir .
  -game "$GAMEDIR_NAME"
  -noaddons
  -nomapchecks
  -nosound
  -window
  -width "$WIDTH"
  -height "$HEIGHT"
  +exec "$TESTCFG"
  +map "$MAP"
  +echo "DIREKT:map-command-issued"
)
[[ ${#EXTRA[@]} -gt 0 ]] && args+=( "${EXTRA[@]}" )

# El motor limita la linea de comandos (CMDLINE_LENGTH, 255 en FTE) y lo que
# pase de ahi NO LLEGA. Es un fallo silencioso: el motor arranca igual, pero se
# come el ultimo "+impulse 26" o el "+extra" que se le haya puesto, y el banco
# de pruebas se queda sin su prueba sin decir por que. Ya ha pasado dos veces.
if (( ${#args[@]} > 0 )); then
  largo="${args[0]}"
  for a in "${args[@]:1}"; do largo="$largo $a"; done
  if (( ${#largo} > 250 )); then
    die "la linea de comandos se pasa de 250 caracteres (${#largo})." \
        "El motor la trunca en 255 y lo que se pase no llega. Mete menos" \
        "--extra, o mueve el argumento a un cfg con --cfg-line."
  fi
fi

# Cmd_StuffCmds_f lee el cvar "cmdline", y ese cvar sale de com_cmdline, que
# Ironwail limita a CMDLINE_LENGTH-1 = 255 caracteres. Si nos pasamos, los
# ultimos "+comando" se cortan a media palabra y el motor se quejara de un
# comando que no existe (tipo "Unknown command \"direk\"").
cmdline_len=$(( ${#REPO_ROOT} + 40 + ${#args[*]} ))
info "longitud estimada de la linea de comandos: $cmdline_len"
if ((cmdline_len > 250)); then
  die "la linea de comandos mide ~${cmdline_len} caracteres y el motor la trunca a 255; los +comando del final no llegaran. Mueve lo que sobre al cfg con --cfg-line."
fi

info "map=$MAP  ${WIDTH}x${HEIGHT}  shot=$WANT_SHOT  display=$DISPLAY"
info "log: $LOG"

# stdbuf fuerza la salida linea a linea; si no, el log llega a 4 KB de golpe y
# no sirve para detectar progreso. Se arranca desde la raiz del repo porque los
# -basedir son relativos.
( cd "$REPO_ROOT" && exec stdbuf -oL -eL "$ENGINE_BIN" "${args[@]}" ) >"$LOG" 2>&1 &
ENGINE_PID=$!

cleanup() {
  if kill -0 "$ENGINE_PID" 2>/dev/null; then
    kill -TERM "$ENGINE_PID" 2>/dev/null || true
    for _ in $(seq 1 20); do
      kill -0 "$ENGINE_PID" 2>/dev/null || break
      sleep 0.1
    done
    kill -KILL "$ENGINE_PID" 2>/dev/null || true
  fi
  wait "$ENGINE_PID" 2>/dev/null || true
}
trap cleanup EXIT

# --------------------------------------------------------------- esperar arranque
ready=0
for ((i = 0; i < BOOT_TIMEOUT; i++)); do
  if ! kill -0 "$ENGINE_PID" 2>/dev/null; then
    break
  fi
  if grep -q "Quake Initialized" "$LOG" 2>/dev/null; then
    ready=1
    break
  fi
  sleep 1
done

if ((ready == 0)); then
  echo "FALLO: el motor no llego a inicializar en ${BOOT_TIMEOUT}s." >&2
  tail -40 "$LOG" >&2
  exit 1
fi
info "motor inicializado en ${i}s"

# El mundo tarda en cargar el BSP yirable con llvmpipe; esperamos a que el
# servidor haya publicado el mapa.
loaded=0
for ((j = 0; j < 120; j++)); do
  if grep -qE "LQ Player entered the game|entered the game|sv\.name" "$LOG" 2>/dev/null; then
    loaded=1
    break
  fi
  kill -0 "$ENGINE_PID" 2>/dev/null || break
  sleep 1
done
((loaded)) && info "mundo cargado en ${j}s (mas ${SETTLE}s de asentar)" || info "aviso: no se confirmo la entrada al mundo"
sleep "$SETTLE"

# --------------------------------------------------------------- captura
failed=0
if grep -qE "Host_Error|Segmentation fault|Fatal error" "$LOG"; then
  echo "FALLO: el motor reporto un error grave:" >&2
  grep -nE "Host_Error|Segmentation fault|Fatal error" "$LOG" | head -20 >&2
  failed=1
fi

# Ironwail avisa en minusculas de los cfg opcionales que no encuentra
# ("couldn't exec autoexec.cfg"); eso es normal. Solo es fatal el nuestro.
if grep -qi "couldn't exec $TESTCFG" "$LOG"; then
  echo "FALLO: el motor no pudo ejecutar $TESTCFG" >&2
  failed=1
fi

if ! grep -q "DIREKT:cfg-executed" "$LOG"; then
  echo "AVISO: $TESTCFG no llego a ejecutarse." >&2
fi

if ! grep -q "Playing registered version" "$LOG"; then
  echo "AVISO: no se confirmo el modo registrado (gfx/pop.lmp). Si aparece" >&2
  echo "       'Playing shareware version' + un abort, revisa los datos." >&2
fi

if ((WANT_SHOT)); then
  shot="$SHOTS/$MAP.png"
  rm -f "$shot"
  # -window normal: la SDL crea una ventana dentro de la raiz de Xvfb.
  if ! import -display "$DISPLAY" -window root "$shot" 2>/dev/null; then
    echo "FALLO: no se pudo capturar la pantalla de $DISPLAY" >&2
    failed=1
  else
    read -r mean sd lit <<<"$($PY_CMD - "$shot" "$MIN_LIT" "$WIDTH" "$HEIGHT" <<'PY'
import subprocess, sys
p, min_lit = sys.argv[1], float(sys.argv[2])
W, H = int(sys.argv[3]), int(sys.argv[4])
raw = subprocess.run(["convert", p, "-colorspace", "Gray", "-depth", "8", "gray:-"],
                     capture_output=True).stdout
if len(raw) < W * H:
    print("0 0 0"); raise SystemExit
view = raw[:H * 2 // 3 * W]          # por encima de la barra de estado
lit = sum(1 for b in view if b > 12) / len(view) * 100
mean = sum(raw) / len(raw) / 256
var = sum((b / 256 - mean) ** 2 for b in raw) / len(raw)
print(f"{mean:.7f} {var ** 0.5:.7f} {lit:.2f}")
PY
)"
    size="$(identify -format '%wx%h' "$shot" 2>/dev/null || echo '?')"
    info "captura $shot ($size) media=$mean desviacion=$sd iluminada=$lit%"
    # Una imagen plana significa que no se dibujo nada: el fallo tipico cuando el
    # render va por software. Y un frame con solo HUD significa que el mundo no
    # se dibujo aunque el motor "este bien".
    if awk "BEGIN{exit !($sd < 0.004)}"; then
      echo "FALLO: la captura es practicamente plana (desviacion=$sd). No se renderizo." >&2
      failed=1
    elif awk "BEGIN{exit !($lit < $MIN_LIT)}"; then
      echo "FALLO: solo se dibujo la interfaz (iluminada=$lit% < $MIN_LIT% en la vista)." >&2
      echo "       El mundo no llego a renderizarse. Revisa el log: $LOG" >&2
      failed=1
    fi
  fi
fi

if ((failed)); then
  echo "RESULTADO: FALLIDO  (log en $LOG)" >&2
  exit 1
fi

echo "RESULTADO: OK"
