#!/usr/bin/env bash
# Comprueba que el render por software da el OpenGL que Ironwail necesita.
# Ironwail usa compute shaders, asi que hace falta >= 4.3.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./xvfb-env.sh
source "$REPO_ROOT/scripts/xvfb-env.sh"

# glxinfo -B no imprime "OpenGL renderer string:" ni "OpenGL version string:",
# asi que usamos la salida completa y solo caemos a -B si algo falla.
if ! info="$(glxinfo 2>/dev/null)"; then
  info="$(glxinfo -B 2>/dev/null)" || {
    echo "ERROR: glxinfo fallo en $DISPLAY" >&2; exit 1; }
fi

pick() { printf '%s\n' "$info" | sed -n "s/^$1//p" | head -1; }

renderer="$(pick 'OpenGL renderer string: *' | sed 's/ *$//')"
[[ -n "$renderer" ]] || renderer="$(pick 'Device: *' | sed 's/ *$//')"

# Ironwail crea un contexto core, asi que vale la version "core profile".
version="$(pick 'OpenGL core profile version string: *' | cut -d' ' -f1)"
[[ -n "$version" ]] || version="$(pick 'OpenGL version string: *' | cut -d' ' -f1)"

echo "  renderer : ${renderer:-desconocido}"
echo "  version  : ${version:-desconocida}"

if ! printf '%s\n' "$info" | grep -q 'GL_ARB_compute_shader'; then
  echo "AVISO: no aparece GL_ARB_compute_shader en la lista de extensiones." >&2
fi

major="${version%%.*}"
minor="${version##*.}"

if [[ -z "$version" || ! "$major" =~ ^[0-9]+$ || ! "$minor" =~ ^[0-9]+$ ]]; then
  echo "ERROR: no se pudo deducir la version de OpenGL (leido: '${version:-?}')." >&2
  exit 1
fi

if ((major < 4 || (major == 4 && minor < 3))); then
  echo "ERROR: se necesita OpenGL >= 4.3 y este entorno da ${version}." >&2
  echo "       Instala 'libgl1-mesa-dri' y no pongas LIBGL_ALWAYS_SOFTWARE=0" >&2
  exit 1
fi

echo "  OK: hay compute shaders, Ironwail puede arrancar."
