#!/usr/bin/env bash
# Descarga y prepara las dependencias externas de Direkt en build/:
#   - el codigo fuente del motor (Ironwail, fijado a un commit)
#   - los datos del juego (LibreQuake full.zip, fijado a una release)
#
# Todo queda en build/ (ignorado por git) y se verifica por SHA-256, de modo que
# el build es reproducible y nadie tiene que versionar 80 MB de binarios.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"
CACHE_DIR="$BUILD_DIR/cache"
SRC_DIR="$BUILD_DIR/src"
DATA_DIR="$BUILD_DIR/lq"

# Fijados. Cambiar aqui obliga a actualizar THIRD_PARTY.md.
IRONWAIL_REPO="https://github.com/andrei-drexler/ironwail"
IRONWAIL_COMMIT="08d578136ff43d7d1ef38e636dfbfd3e844be7cd"
IRONWAIL_TARBALL_URL="$IRONWAIL_REPO/archive/$IRONWAIL_COMMIT.tar.gz"

LIBRQUAKE_URL="https://github.com/lavenderdotpet/LibreQuake/releases/download/v0.09-beta/full.zip"


# Generados con 'scripts/fetch-deps.sh lock' contra las descargas de la v0.09-beta.
IRONWAIL_SHA256="c7601696e6a135ce4aa5d98b60fd3e2b8b69572c40ceafe34a11023ecec28963"
LIBRQUAKE_SHA256="623e463b35811216244f9ba15e0c45abc1765288650b5e3d36a899b35e4bcf3d"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

# SHA-256 de un fichero, con la herramienta que haya.
#
# sha256sum es de coreutils y no viene en macOS, que trae shasum. Sin esto el
# script entero no arranca alli, que es justo donde hace falta para compilar.
sha256_de() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    die "no hay ni sha256sum ni shasum. En macOS: brew install coreutils"
  fi
}

verify_sha256() {
  local file="$1" expected="$2" what="$3"
  [[ -z "$expected" ]] && die "SHA-256 fijado vacio para $what. Ejecuta 'make lock' para generarlo."
  local actual
  actual="$(sha256_de "$file")"
  if [[ "$actual" != "$expected" ]]; then
    die "SHA-256 incorrecto para $what
  esperado: $expected
  obtenido: $actual
  El fichero descargado esta corrupto o el upstream ha cambiado.
  Si el cambio es legitimo, revisa la licencia en THIRD_PARTY.md y ejecuta 'make lock'."
  fi
  info "SHA-256 verificado: $what"
}

fetch() {
  local url="$1" dest="$2"
  if [[ -s "$dest" ]]; then
    info "ya en cache: $(basename "$dest")"
    return
  fi
  info "descargando $(basename "$dest")"
  mkdir -p "$(dirname "$dest")"
  curl -sL --fail --retry 3 --retry-delay 2 -o "$dest.part" "$url" \
    || die "no se pudo descargar $url"
  mv "$dest.part" "$dest"
}

# ---------------------------------------------------------------- motor
fetch_engine() {
  mkdir -p "$SRC_DIR"
  local tarball="$CACHE_DIR/ironwail-src.tar.gz"
  fetch "$IRONWAIL_TARBALL_URL" "$tarball"
  verify_sha256 "$tarball" "$IRONWAIL_SHA256" "ironwail"

  local dir="$SRC_DIR/ironwail"
  if [[ ! -d "$dir/.direkt-stamped" ]]; then
    info "extrayendo el motor"
    rm -rf "$dir"
    mkdir -p "$dir"
    tar -xzf "$tarball" -C "$dir" --strip-components=1
    touch "$dir/.direkt-stamped"
  else
    info "el motor ya esta extraido (usa 'make engine-clean' para rehacerlo)"
  fi

  # Aplicar nuestros parches encima del upstream, en orden.
  local applied_marker="$dir/.patches-applied"
  touch "$applied_marker"
  local p
  for p in "$REPO_ROOT"/patches/*.patch; do
    [[ -e "$p" ]] || break
    if ! grep -qxF "$(basename "$p")" "$applied_marker" 2>/dev/null; then
      info "aplicando parche $(basename "$p")"
      patch -d "$dir" -p1 --forward --reject-file=- <"$p" \
        || die "fallo al aplicar $(basename "$p")"
      grep -qxF "$(basename "$p")" "$applied_marker" 2>/dev/null || \
        echo "$(basename "$p")" >>"$applied_marker"
    fi
  done
  echo "$dir"
}

# ---------------------------------------------------------------- datos
fetch_data() {
  mkdir -p "$DATA_DIR"
  local zip="$CACHE_DIR/librequake-full.zip"
  fetch "$LIBRQUAKE_URL" "$zip"
  verify_sha256 "$zip" "$LIBRQUAKE_SHA256" "librequake-full"

  if [[ ! -f "$DATA_DIR/full/id1/pak0.pak" ]]; then
    info "extrayendo los datos de LibreQuake"
    rm -rf "$DATA_DIR/full"
    # -q y sin -j: la estructura interna debe quedar identica
    unzip -q -o "$zip" -d "$DATA_DIR"
  else
    info "los datos de LibreQuake ya estan extraidos"
  fi

  [[ -f "$DATA_DIR/full/id1/pak0.pak" ]] || die "no se encontro id1/pak0.pak tras extraer"
  [[ -f "$DATA_DIR/full/id1/pak1.pak" ]] || die "no se encontro id1/pak1.pak tras extraer"

}

# ---------------------------------------------------------------- comandos
cmd_lock() {
  mkdir -p "$CACHE_DIR"
  fetch "$IRONWAIL_TARBALL_URL" "$CACHE_DIR/ironwail-src.tar.gz"
  fetch "$LIBRQUAKE_URL" "$CACHE_DIR/librequake-full.zip"
  echo "--- Genera esto y pegalo en scripts/fetch-deps.sh ---"
  echo "IRONWAIL_SHA256=\"$(sha256_de "$CACHE_DIR/ironwail-src.tar.gz")\""
  echo "LIBRQUAKE_SHA256=\"$(sha256_de "$CACHE_DIR/librequake-full.zip")\""
}

cmd_verify() {
  verify_sha256 "$CACHE_DIR/ironwail-src.tar.gz" "$IRONWAIL_SHA256" "ironwail"
  verify_sha256 "$CACHE_DIR/librequake-full.zip" "$LIBRQUAKE_SHA256" "librequake-full"
  echo "Ambas dependencias coinciden con el lock."
}

case "${1:-all}" in
  all)      fetch_engine >/dev/null; fetch_data; info "Dependencias listas en build/" ;;
  engine)   fetch_engine >/dev/null ;;
  data)     fetch_data ;;
  lock)     cmd_lock ;;
  verify)   cmd_verify ;;
  *)        die "uso: $0 [all|engine|data|lock|verify]" ;;
esac
