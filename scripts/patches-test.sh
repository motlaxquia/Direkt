#!/usr/bin/env bash
# Comprueba que los parches del motor reconstruyen build/src/ byte a byte.
#
#   scripts/patches-test.sh
#
# POR QUE ESTE FICHERO
#
# Es la prueba que hace falta y no existed. Los cambios del motor se han escrito
# en build/src/ (que esta ignorado por git) y se han forgetado de meterlos en
# patches/ DOS veces. El sintoma es el peor posible: el arbol de build funciona,
# el banco de pruebas entero pasa en verde, y el build limpio de CI no tiene el
# cambio. Nadie se entera hasta que algo falla en la release.
#
# Aqui se sacan los motores del tarball ORIGINAL, se les aplica lo que hay en
# patches/ y se comparan con build/src/ fichero a fichero. Si alguien toca el
# motor y no regenera el parche (scripts/gen-patches.sh), esto falla.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$REPO_ROOT/build"
CACHE="$BUILD/cache"
TRABAJO="$(mktemp -d)"
trap 'rm -rf "$TRABAJO"' EXIT

info() { printf '==> %s\n' "$1"; }
die()  { printf 'ERROR: %s\n' "$1" >&2; exit 1; }
ok()   { printf '  PASA  %s\n' "$1"; }
ko()   { printf '  FALLA %s\n' "$1"; }

PY_CMD="$(command -v python3 || command -v python || true)"
[[ -n "$PY_CMD" ]] || die "hace falta python3 o python"

fallos=0

comprobar() {
  local motor="$1" tarball="$2" dir="$BUILD/src/$1"
  local info_comprobado

  info "$motor"
  [[ -f "$CACHE/$tarball" ]] || { ko "falta el tarball; ejecuta 'make deps'"; fallos=$((fallos+1)); return; }
  [[ -d "$dir" ]]            || { ko "no hay build/src/$motor; ejecuta 'make deps' y compila"; fallos=$((fallos+1)); return; }

  rm -rf "$TRABAJO/$motor"
  mkdir -p "$TRABAJO/$motor"
  tar xzf "$CACHE/$tarball" -C "$TRABAJO/$motor"

  # El tarball saca todo DENTRO de un directorio con el nombre del commit, y
  # patch -p1 tiene que aplicarse ahi dentro, no al padre. Con el padre falla,
  # y falla sin decir nada util.
  local aplicacion
  aplicacion="$(find "$TRABAJO/$motor" -mindepth 1 -maxdepth 1 -type d | head -1)"
  [[ -n "$aplicacion" ]] || { ko "el tarball de $motor esta vacio"; fallos=$((fallos+1)); return; }

  # Se aplica lo que haya en patches/ para este motor, en orden.
  local p base
  for p in "$REPO_ROOT/patches/$motor"-*.patch; do
    [[ -e "$p" ]] || continue
    base="$(basename "$p")"
    if ! patch -d "$aplicacion" -p1 --forward --reject-file=- <"$p" >/dev/null 2>&1; then
      ko "$base no se aplica limpio sobre el original"
      fallos=$((fallos+1))
      return
    fi
  done

  # Y ahora lo importante: el resultado tiene que ser IDENTICO a lo que hay
  # construido. Es una comparacion de bytes, no de contenido.
  info_comprobado="$("$PY_CMD" - "$TRABAJO/$motor" "$dir" <<'PY'
import filecmp, os, sys

parcheado, actual = sys.argv[1], sys.argv[2]

# El tarball mete todo dentro de un directorio con el nombre del commit.
raiz = next(p for p in os.listdir(parcheado)
            if os.path.isdir(os.path.join(parcheado, p)))
parcheado = os.path.join(parcheado, raiz)

malos = []
for base, dirs, files in os.walk(parcheado):
    dirs[:] = [d for d in dirs if d not in (".git",)]
    for f in files:
        p = os.path.join(base, f)
        rel = os.path.relpath(p, parcheado)
        if rel == ".patches-applied":
            continue
        q = os.path.join(actual, rel)
        if not os.path.exists(q):
            # El motor genera ficheros que no estan en el original: eso es
            # normal (config.h, .o, Makefile generados). Solo avisa.
            continue
        if not filecmp.cmp(p, q, shallow=False):
            malos.append(rel)

if malos:
    print("DIFIEREN " + " ".join(sorted(malos)[:8]))
    sys.exit(1)
print("IGUAL")
PY
)"

  if [[ "$info_comprobado" == IGUAL ]]; then
    ok "$motor: los parches reconstruyen el codigo byte a byte"
  else
    ko "$motor: $info_comprobado"
    printf '        regenera con: scripts/gen-patches.sh %s\n' "$motor" >&2
    fallos=$((fallos+1))
  fi
}

printf 'Los parches del motor reconstruyen lo que hay construido\n'
comprobar ironwail   ironwail-src.tar.gz
comprobar quakespasm quakespasm-src.tar.gz

if (( fallos > 0 )); then
  printf '\n%d fallo(s)\n' "$fallos" >&2
  exit 1
fi
printf '\nPATCHES TEST CORRECTO\n'
