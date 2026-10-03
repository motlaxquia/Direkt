#!/usr/bin/env python3
"""Construye y escribe un .pak de Quake.

    tools/mpak.py --salida salida.pak progs/head.mdl:head.mdl
    tools/mpak.py --listar salida.pak

El motor busca pak*.pak dentro de <basedir>/id1, y los recorre en orden: pak0,
pak1, y asi. El formato es el de 1996 y es tonto a proposito:

  cabecera   4 bytes "PACK", int32 dirofs, int32 dirlen
  tabla      dirofs/dirlen bytes, de 64 en 64
  datos      los ficheros, en cualquier sitio

Cada entrada son 56 bytes de nombre (terminado en \\0), int32 posicion, int32
longitud. El motor no comprueba los nombres: se leen y se comparan tal cual, asi
que van en minusculas y con "/" delante de progs/.

Solo escribe. Para leer, tools/pakinfo.py, que comparte las constantes de aqui.
"""

import argparse
import struct
import sys
from pathlib import Path

PAK_MAGIC = b"PACK"
DIR_ENTRY_SIZE = 64
NAME_SIZE = 56
# La cabecera va antes que los datos, y las posiciones del directorio son
# ABSOLUTAS: cuentan desde el principio del fichero. O sea que hay que sumarle
# estos 12 bytes a cada posicion, o el motor leeria la cabecera del pak donde
# deberia estar el modelo. Es el error clasico al escribir un pak.
CABECERA_LEN = 12

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pakinfo  # noqa: E402  (despues de insertar el path a proposito)


def Normalizar(nombre: str) -> str:
    """El nombre tal y como lo guarda el motor: minusculas y con barras."""
    n = nombre.replace("\\", "/").lstrip("/")
    if len(n) >= NAME_SIZE:
        raise ValueError(
            f"el nombre no cabe en {NAME_SIZE} bytes: {n} ({len(n)})")
    return n.lower()


def construir(salida: Path, entradas: list) -> tuple:
    """Escribe un .pak.

    entradas es una lista de (nombre_en_el_pak, fichero_local).

    Los ficheros van primero y la tabla despues. El motor no exige que la tabla
    este delante ni nada: lee dirofs de la cabecera y salta ahi. Se pone al final
    porque asi se puede reescribir la cabecera sin mover los datos.
    """
    cuerpo = bytearray()
    posicion = {}
    for nombre_pak, fichero in entradas:
        norm = Normalizar(nombre_pak)
        datos = fichero.read_bytes()
        # Alineacion a 4: no hace falta para el motor, pero algunos lectores
        # asumen que no cruzan las palabras.
        while (CABECERA_LEN + len(cuerpo)) % 4:
            cuerpo.append(0)
        # La posicion es desde el principio del fichero, con la cabecera puesta.
        posicion[norm] = (CABECERA_LEN + len(cuerpo), len(datos))
        cuerpo += datos

    dirofs = CABECERA_LEN + len(cuerpo)
    tabla = bytearray()
    for nombre_pak, _fichero in entradas:
        norm = Normalizar(nombre_pak)
        pos, tam = posicion[norm]
        tabla += norm.encode("ascii").ljust(NAME_SIZE, b"\0")
        tabla += struct.pack("<ii", pos, tam)
    dirlen = len(tabla)

    salida.parent.mkdir(parents=True, exist_ok=True)
    with open(salida, "wb") as fh:
        fh.write(PAK_MAGIC)
        fh.write(struct.pack("<ii", dirofs, dirlen))
        fh.write(cuerpo)
        fh.write(tabla)
    return CABECERA_LEN + len(cuerpo) + dirlen, len(entradas)


def listar(ruta: Path) -> int:
    with open(ruta, "rb") as fh:
        dirofs, dirlen = pakinfo.read_pak_header(fh)
        for nombre, pos, tam in pakinfo.read_entries(fh, dirofs, dirlen):
            print(f"{tam:>10}  {nombre}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Construye .pak de Quake")
    ap.add_argument("--salida", type=Path, help="pak a escribir")
    ap.add_argument("--origen", type=Path,
                    help="carpeta donde se buscan los ficheros por su nombre")
    ap.add_argument("--listar", type=Path, help="lista un pak y sale")
    ap.add_argument("entradas", nargs="*",
                    help="nombre:fichero. El nombre es dentro del pak; el "
                         "fichero es de donde se lee, relativo a --origen")
    args = ap.parse_args()

    if args.listar:
        return listar(args.listar)

    if not args.salida:
        ap.error("hace falta --salida (o --listar)")

    pares = []
    for item in args.entradas:
        if ":" not in item:
            print(f"ERROR: '{item}' no es nombre:fichero", file=sys.stderr)
            return 1
        nombre, fichero = item.split(":", 1)
        # El fichero se busca tal cual y, si no esta, bajo --origen. Asi se
        # pueden poner rutas sueltas sin repetir el directorio en cada una.
        ruta = Path(fichero)
        if not ruta.is_file() and args.origen:
            ruta = args.origen / fichero
        if not ruta.is_file():
            print(f"ERROR: no existe {fichero}", file=sys.stderr)
            return 1
        pares.append((nombre, ruta))

    if not pares:
        print("ERROR: no hay nada que empaquetar", file=sys.stderr)
        return 1

    tam, n = construir(args.salida, pares)
    print(f"    {args.salida}: {n} ficheros, {tam} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
