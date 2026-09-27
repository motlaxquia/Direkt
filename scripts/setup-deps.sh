#!/usr/bin/env bash
# Instala las dependencias de sistema para construir y ejecutar Direkt.
# Idempotente: se puede repetir sin efecto.
set -euo pipefail

# Paquetes de compilacion del motor
BUILD_PKGS=(
  build-essential
  cmake
  pkg-config
  libsdl2-dev
  libgl1-mesa-dev
  libglu1-mesa-dev
  libcurl4-openssl-dev
)

# Codecs de audio opcionales (el motor degrada solo si no estan)
CODEC_PKGS=(
  libmad0-dev
  libmpg123-dev
  libvorbis-dev
  libogg-dev
)

# Ejecucion sin pantalla + herramientas de captura
RUNTIME_PKGS=(
  xvfb
  x11-utils
  mesa-utils
  libgl1-mesa-dri
  imagemagick
  python3-numpy
  unzip
  ca-certificates
)

# Compilador de QuakeC
QCC_PKG=fteqcc

APT_OPTS=(-y --no-install-recommends)

if [[ "${1:-}" == "--check" ]]; then
  missing=()
  for p in "${BUILD_PKGS[@]}" "${RUNTIME_PKGS[@]}" "$QCC_PKG"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "ok installed" || missing+=("$p")
  done
  if ((${#missing[@]} == 0)); then
    echo "OK: todas las dependencias estan instaladas"
    exit 0
  fi
  echo "FALTAN: ${missing[*]}"
  exit 1
fi

# ------------------------------------------------------------------ solo Linux
#
# Todo lo de aqui es apt, y apt es de Debian. En macOS y en Windows esto no
# tiene sentido: las dependencias se instalan con brew y con pacman/MSYS2
# respectivamente, y lo hace el workflow de GitHub Actions. Asi que en cualquier
# otro sitio esto no hace nada y lo dice, en vez de fallar con un "apt not
# found" a mitad de un script que el usuario no puede arreglar.
if ! command -v apt-get >/dev/null 2>&1; then
  echo "==> Este script instala con apt, que es de Debian."
  echo "    En Linux sin problema. En macOS: brew install sdl2 fteqcc cmake pkg-config"
  echo "    En Windows, desde MSYS2: pacman -S mingw-w64-x86_64-{gcc,make,cmake,pkg-config,sdl2} mingw-w64-x86_64-fteqcc"
  exit 0
fi

SUDO=""
if [[ "$(id -u)" != "0" ]]; then
  if ! sudo -n true 2>/dev/null; then
    echo "ERROR: hace falta root (o sudo sin password) para instalar paquetes." >&2
    exit 1
  fi
  SUDO="sudo -n"
fi

echo "==> Actualizando indices de apt"
$SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -qq

echo "==> Instalando toolchain de compilacion"
$SUDO env DEBIAN_FRONTEND=noninteractive apt-get install "${APT_OPTS[@]}" "${BUILD_PKGS[@]}"

echo "==> Instalando codecs de audio (opcionales)"
$SUDO env DEBIAN_FRONTEND=noninteractive apt-get install "${APT_OPTS[@]}" "${CODEC_PKGS[@]}" || \
  echo "AVISO: faltan codecs, el motor compilara sin ellos"

echo "==> Instalando runtime headless (Xvfb + Mesa software) y herramientas"
$SUDO env DEBIAN_FRONTEND=noninteractive apt-get install "${APT_OPTS[@]}" "${RUNTIME_PKGS[@]}"

echo "==> Instalando el compilador de QuakeC ($QCC_PKG)"
$SUDO env DEBIAN_FRONTEND=noninteractive apt-get install "${APT_OPTS[@]}" "$QCC_PKG"

echo
echo "Comprobando el render por software..."
if command -v glxinfo >/dev/null; then
  echo "  glxinfo presente. Para ver la version GL usa: scripts/check-gl.sh"
fi

echo
echo "Listo. Siguiente paso: scripts/fetch-deps.sh"
