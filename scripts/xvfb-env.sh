#!/usr/bin/env bash
# Arranca un servidor X virtual y escribe el numero de display en un fichero,
# para poder reutilizar la misma sesion entre varias ejecuciones.
#
#   source scripts/xvfb-env.sh
#   echo $DISPLAY   ->  :99
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="$REPO_ROOT/build/run"
LOCKFILE="$STATE_DIR/xvfb.display"
XVFB_PIDFILE="$STATE_DIR/xvfb.pid"

WIDTH="${DIREKT_WIDTH:-1280}"
HEIGHT="${DIREKT_HEIGHT:-720}"

mkdir -p "$STATE_DIR"

if [[ -f "$LOCKFILE" ]]; then
  existing="$(cat "$LOCKFILE")"
  if kill -0 "$(cat "$XVFB_PIDFILE" 2>/dev/null || echo 0)" 2>/dev/null; then
    export DISPLAY="$existing"
    echo "Xvfb ya activo en $DISPLAY (pid $(cat "$XVFB_PIDFILE"))" >&2
    return 0 2>/dev/null || exit 0
  fi
  rm -f "$LOCKFILE" "$XVFB_PIDFILE"
fi

# Buscar un numero de display libre a partir del 99
display=99
while [[ -e "/tmp/.X${display}-lock" ]]; do
  display=$((display + 1))
  [[ $display -gt 120 ]] && { echo "ERROR: no hay displays X libres" >&2; exit 1; }
done

Xvfb ":$display" -screen 0 "${WIDTH}x${HEIGHT}x24" -nolisten tcp -noreset \
  >"$STATE_DIR/xvfb.log" 2>&1 </dev/null &
xvfb_pid=$!
# Desligar del grupo de procesos del shell: si el script muere, Xvfb sobrevive y
# no se queda colgando del pipe de salida de quien lo lanzo.
disown "$xvfb_pid" 2>/dev/null || true

# Esperar a que el socket exista
for _ in $(seq 1 100); do
  [[ -e "/tmp/.X11-unix/X$display" ]] && break
  kill -0 "$xvfb_pid" 2>/dev/null || { echo "ERROR: Xvfb murio. Log:" >&2; cat "$STATE_DIR/xvfb.log" >&2; exit 1; }
  sleep 0.1
done

echo ":$display" >"$LOCKFILE"
echo "$xvfb_pid" >"$XVFB_PIDFILE"

export DISPLAY=":$display"
# Render por software: llvmpipe da OpenGL 4.5, que es lo que Ironwail necesita
# para sus compute shaders. En un codespace sin GPU esto es lo unico viable.
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe
# Silenciar el spam de MESA sobre rendimiento
export MESA_DEBUG=silent
export LP_NUM_THREADS="${DIREKT_THREADS:-4}"

echo "Xvfb arrancado en $DISPLAY (pid $xvfb_pid, ${WIDTH}x${HEIGHT})" >&2
