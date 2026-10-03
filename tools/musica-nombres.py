#!/usr/bin/env python3
"""Renombra las pistas de musica de LibreQuake por su escenario.

Por que

La musica de un mapa se pedia con un numero: la clave "sounds" del worldspawn, un
entero, y el motor montaba "music/trackNN.ogg". El numero no decia nada. No se
sabia que pista era cual sin abrir los ficheros, y la carpeta se leia como una
tanda de track02, track03, track04... que no es un orden de nada.

Ahora la musica se pide por nombre (clave "music" del worldspawn, implemented en
bgmusic.c), asi que los ficheros pueden llamarse por el sitio donde suenan.

El nombre de cada una

Cada pista se usa en varios mapas, asi que no hay un unico sitio suyo. El nombre
es el del PRIMER mapa que la usa en el orden de la campana:

    e1, e2, e3, e4, e0  y despues los mapas lqdm

Los mapas lqdm son de muerte, asi que van los ultimos. Las pistas 2 y 3 no las
usa ningun mapa: se llaman reservada_02 y reservada_03, que es exactamente lo que
son.

Los mapas que las usan estan todos en la tabla de abajo, tambien los que se
quedan sin nombre propio. Nada se pierde por renombrar.

Lo que NO se toca

Los mapas de LibreQuake viven dentro de los PAK y ponen "sounds" con un numero.
Reescribirlos exigiria desempaquetar 95 MB de mapas y volver a empaquetarlos en
cada compilacion, y ademas cambiar los datos de otra gente. No merece la pena.

Lo que hace este script ademas es escribir music/pistas.txt: una tabla con el
numero viejo de cada pista y el fichero nuevo. El motor la consulta cuando un mapa
pide un numero y no encuentra ningun trackNN, de modo que los mapas de LibreQuake
siguen sonando lo mismo de siempre, con el numero que siempre pusieron.

Idempotente: se puede ejecutar las veces que haga falta.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

# numero de pista -> (fichero nuevo, escenario del nombre, mapas que la usan)
PISTAS: dict[int, tuple[str, str, list[str]]] = {
    2: ("reservada_02.ogg", "sin mapa", []),
    3: ("reservada_03.ogg", "sin mapa", []),
    4: ("calibur.ogg", "e1m8 That's my Ex, Calibur!",
        ["e1m8", "e2m2", "e2m5", "e3m3"]),
    5: ("feudal_anomaly.ogg", "e1m2 The Feudal Anomaly",
        ["e1m2", "e1m3", "e0m3", "e0m8", "lqdm2"]),
    6: ("rats_behind_bars.ogg", "e1m1 Rats Behind Bars",
        ["e1m1", "e0m1", "e3m1", "e4m1"]),
    7: ("dismal_shores.ogg", "e1m4 Dismal Shores",
        ["e1m4", "e1m7", "e0m7", "e4m4", "lqdm7", "lqdm10"]),
    8: ("corpse_army.ogg", "e2m3 Corpse army",
        ["e2m3", "e3m2", "e3m4", "lqdm1", "lqdm3", "lqdm9", "lqdm12"]),
    9: ("gloomliths.ogg", "e1m5 Gloomliths",
        ["e1m5", "e0m2", "lqdm4"]),
    10: ("holy_bloated_corpse.ogg", "e3m6 Holy Bloated Corpse",
         ["e3m6", "e4m3", "e4m5", "e0m4", "e0m6", "lqdm6"]),
    11: ("feint_free_funtime.ogg", "e0m4 Feint-free funtime",
         ["e0m4", "lqdm5", "lqdm8"]),
}

CABECERA = """\
# Pistas de musica: numero viejo y fichero actual.
#
# Los mapas de LibreQuake ponen "sounds" con un entero, y sus .bsp viven dentro
# de los PAK. Esta tabla es lo que hace que ese numero siga sonando el fichero
# nuevo: el motor la mira cuando el numero no corresponde a ningun trackNN.
#
# Para cambiar el reparto, edita este fichero. Para poner musica nueva, deja el
# .ogg suelto en music/ con el nombre que quieras y pidelo por nombre con la
# clave "music" del worldspawn.
#
# numero  fichero                  escenario              mapas que la usan
"""


def renombrar(musica: Path, dry_run: bool) -> int:
    if not musica.is_dir():
        print(f"error: no existe {musica}", file=sys.stderr)
        return 1

    lineas: list[str] = []
    movidos = 0
    faltan: list[str] = []

    for numero in sorted(PISTAS):
        nombre, escenario, mapas = PISTAS[numero]
        viejo = musica / f"track{numero:02d}.ogg"
        nuevo = musica / nombre

        # Ya esta renombrada, o el numero no existe en esta copia.
        if not viejo.exists():
            if not nuevo.exists():
                faltan.append(viejo.name)
            else:
                movidos += 0  # ya estaba
        elif nuevo.exists():
            # Raro: estan los dos. No se pisa el nombre nuevo.
            faltan.append(f"{viejo.name} (ya existe {nombre})")
        elif dry_run:
            movidos += 1
        else:
            viejo.rename(nuevo)
            movidos += 1

        usos = ", ".join(mapas) if mapas else "ninguno"
        lineas.append(f"{numero:<8} {nombre:<24} {escenario:<22} {usos}\n")

    if faltan:
        for f in faltan:
            print(f"  aviso: no se pudo renombrar {f}", file=sys.stderr)
        return 1

    if dry_run:
        print(f"==> (simulacion) {movidos} pistas")
        return 0

    (musica / "pistas.txt").write_text(CABECERA + "".join(lineas),
                                       encoding="utf-8")
    print(f"==> {movidos} pistas renombradas y pistas.txt escrito en {musica}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("musica", type=Path, help="carpeta music/")
    ap.add_argument("--simular", action="store_true",
                    help="no toca nada, solo dice lo que haria")
    args = ap.parse_args()
    return renombrar(args.musica, args.simular)


if __name__ == "__main__":
    raise SystemExit(main())