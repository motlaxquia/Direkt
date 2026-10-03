#!/usr/bin/env bash
# Regenera los parches del motor desde el codigo que hay en build/src/.
#
#   scripts/gen-patches.sh            # regenera los dos
#   scripts/gen-patches.sh ironwail   # solo uno
#
# POR QUE EXISTE
#
# Los parches se han escrito a mano tres veces y las tres se ha terminado
# editando el motor en build/src y olvidando actualizar el parche. Un parche
# desfasado es un fallo silencioso: el arbol de build funciona, las pruebas
# pasan, y el build limpio de CI no tiene el cambio. Ha pasado dos veces con el
# banco de pruebas entero en verde.
#
# El parche se genera comparando el codigo ORIGINAL (el tarball del que sale
# build/src) con el codigo ACTUAL. Asi no hay nada que mantener a mano y no
# existe la posibilidad de que se queden descuadrados.
#
# Se guardan como un solo parche por motor, y no varios por tema. Con varios,
# tocar un fichero que toca dos temas obliga a repartirlos a mano, que es
# justamente donde se cuelan. Los temas se cuentan en el comentario del parche,
# que se regenera con la lista de ficheros de verdad.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$REPO_ROOT/build"
CACHE="$BUILD/cache"
TRABAJO="$(mktemp -d)"
trap 'rm -rf "$TRABAJO"' EXIT

info() { printf '==> %s\n' "$1"; }
die()  { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

[[ -f "$CACHE/ironwail-src.tar.gz" ]]    || die "falta el tarball de Ironwail; ejecuta 'make deps'"
[[ -f "$CACHE/quakespasm-src.tar.gz" ]] || die "falta el tarball de Quakespasm; ejecuta 'make deps'"

generar() {
  local motor="$1" tarball="$2" original="$3"
  local dir="$TRABAJO/$motor"
  local salida="$REPO_ROOT/patches/$motor-001-direkt.patch"

  [[ -d "$BUILD/src/$motor" ]] || die "no hay build/src/$motor; ejecuta 'make deps' y compila"

  mkdir -p "$dir"
  tar xzf "$CACHE/$tarball" -C "$dir"
  local base
  base="$(find "$dir" -mindepth 1 -maxdepth 1 -type d | head -1)"
  [[ -n "$base" ]] || die "el tarball de $motor esta vacio"

  # Que ficheros cambian de verdad. Se comparan los dos arboles entero y se
  # cogen los ficheros que existen en los dos y son distintos. Asi no hay lista
  # de ficheros mantenida a mano, que es lo que se desactualiza.
  #
  # Se excluyen los ficheros que el propio motor genera al compilar y los
  # marcadores de fetch-deps.sh, que no son codigo nuestro.
  local lista
  # El "|| true" del final es por pipefail: diff devuelve 1 cuando hay
  # diferencias, que es justo lo que se esta buscando, y con pipefail eso
  # tumba el script entero.
  lista="$( (diff -rq "$base" "$BUILD/src/$motor" 2>/dev/null \
    | sed -n 's|^Files \([^ ]*\) and .* differ$|\1|p' \
    | sed "s|^$base/||" \
    | grep -vE '\.patches-applied$|Makefile\.orig$|config\.h$' \
    | sort) || true )"
  [[ -n "$lista" ]] || die "no hay diferencias: el motor esta igual que el original"

  local parche="$TRABAJO/$motor.patch"
  : > "$parche"
  {
    cat <<FIN
--- /dev/null
+++ b/DIREKT-$motor.patch
@@ Este parche lo genera scripts/gen-patches.sh. NO se edita a mano. @@
#
# Los cambios de Direkt al motor $motor, todos juntos. Para que se vea lo que
# hay dentro sin abrir el fichero:
#
FIN
    local f
    while read -r f; do
      [[ -n "$f" ]] || continue
      printf '#   %s\n' "$f"
    done <<< "$lista"
    cat <<'FIN'
#
# Son tres cosas, mas un cuarto punto:
#
#   1. La barra de estado se apaga con "+set scr_drawsb 0", y con ella se
#      apaga el hueco que dejaba (sb_lines), para que la vista 3D ocupe la
#      pantalla entera en vez de dejar una franja.
#   2. El aviso de una linea de scr_msgline, que el juego pinta en el motor.
#   3. Al morir, la camara se queda recta (cl_deadnoroll). El alabeo se
#      desactiva con la vida a cero, y el juego es el que avisa, porque desde
#      el cliente no se puede saber si el jugador esta muerto.
#   4. Portabilidad (macOS, MSYS2, ficheros sueltos) que ya estaba antes.
#
# Y las trampas del formato de parche, que han costado un rato:
#
#   * La cabecera lleva prefijos a/ y b/. Sin ellos, "patch -p1" se come el
#     directorio y no encuentra el fichero.
#   * El parche se genera contra el ORIGINAL, no contra el arbol ya parcheado.
#     Si no, el diff incluye los cambios del parche anterior dos veces.
FIN
  } > "$parche"

  local f
  while read -r f; do
    [[ -n "$f" ]] || continue
    diff -u --label "a/$f	origen" --label "b/$f	$(date '+%Y-%m-%d %H:%M:%S.000000000 +0000')" \
      "$base/$f" "$BUILD/src/$motor/$f" >> "$parche" || true
  done <<< "$lista"

  # El fichero anterior con el mismo numero se va: si no, patch intentaria
  # aplicar los dos encima.
  rm -f "$REPO_ROOT/patches/$motor"-0[0-9][0-9]-*.patch
  mkdir -p "$REPO_ROOT/patches"
  cp "$parche" "$salida"

  info "$motor: $(wc -l < "$salida") lineas, $(wc -l <<< "$lista") ficheros"
  printf '    %s\n' "$salida"
}

case "${1:-todos}" in
  ironwail)    generar ironwail ironwail-src.tar.gz "" ;;
  quakespasm)  generar quakespasm quakespasm-src.tar.gz "" ;;
  todos|"")    generar ironwail ironwail-src.tar.gz ""
               generar quakespasm quakespasm-src.tar.gz "" ;;
  *) die "motor desconocido: $1 (usa ironwail, quakespasm o ninguno)" ;;
esac
