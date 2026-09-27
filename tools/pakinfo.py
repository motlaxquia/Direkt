#!/usr/bin/env python3
"""Inspecciona los ficheros PAK de Quake (el formato que usan los .pak de LibreQuake).

    tools/pakinfo.py build/lq/full/id1/pak0.pak            # resumen
    tools/pakinfo.py build/lq/full/id1/pak0.pak --list     # todo el contenido
    tools/pakinfo.py ... --grep '\\.spr$'                   # filtra por nombre
    tools/pakinfo.py ... --extract s_light.spr --out /tmp  # saca un fichero

Solo lectura: no modifica nada. Util para auditar que assets hay y con que
licencia llegaron, sin tener que descomprimir 200 MB de paks.
"""

import argparse
import struct
import sys
from collections import Counter
from pathlib import Path

PAK_MAGIC = b"PACK"
DIR_ENTRY_SIZE = 64
NAME_SIZE = 56

# Extensions que nos interesan para auditar el pipeline de render
EXT_RENDER = {".spr", ".mdl", ".bsp", ".lit", ".lmp", ".wad", ".tga", ".png"}
EXT_SOUND = {".wav", ".ogg", ".mp3"}
EXT_CODE = {".c", ".h", ".qc", ".dat", ".cfg"}


def read_pak_header(fh) -> tuple[int, int]:
    magic = fh.read(4)
    if magic != PAK_MAGIC:
        raise ValueError(f"no es un PAK (identificador {magic!r})")
    dirofs, dirlen = struct.unpack("<ii", fh.read(8))
    if dirofs < 0 or dirlen < 0:
        raise ValueError(f"cabecera invalida: dirofs={dirofs} dirlen={dirlen}")
    if dirlen % DIR_ENTRY_SIZE:
        raise ValueError(f"dirlen={dirlen} no es multiplo de {DIR_ENTRY_SIZE}")
    return dirofs, dirlen


def read_entries(fh, dirofs: int, dirlen: int):
    fh.seek(dirofs)
    data = fh.read(dirlen)
    for off in range(0, dirlen, DIR_ENTRY_SIZE):
        raw_name, filepos, filelen = struct.unpack(f"<{NAME_SIZE}sii", data[off:off + DIR_ENTRY_SIZE])
        name = raw_name.split(b"\0", 1)[0].decode("latin-1")
        yield name, filepos, filelen


def summarise(path: Path, entries) -> None:
    by_ext: Counter = Counter()
    by_dir: Counter = Counter()
    total = 0
    count = 0
    for name, _pos, size in entries:
        p = Path(name.replace("\\", "/"))
        by_ext[p.suffix.lower()] += 1
        by_dir[p.parts[0] if len(p.parts) > 1 else "."] += 1
        total += size
        count += 1

    print(f"{path}")
    print(f"  ficheros      : {count}")
    print(f"  tamano (bytes): {total:,}")
    print("  por extension :")
    for ext, n in by_ext.most_common():
        print(f"    {ext or '(sin extension)':<12} {n}")
    print("  por directorio:")
    for d, n in by_dir.most_common(12):
        print(f"    {d:<12} {n}")


def classify(name: str) -> str:
    ext = Path(name.replace("\\", "/")).suffix.lower()
    if ext in EXT_RENDER:
        return "render"
    if ext in EXT_SOUND:
        return "sonido"
    if ext in EXT_CODE:
        return "codigo"
    return "otro"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("pak", type=Path)
    ap.add_argument("--list", action="store_true", help="lista todo el contenido")
    ap.add_argument("--grep", metavar="RE", help="filtra los nombres con esta expresion")
    ap.add_argument("--category", choices=["render", "sonido", "codigo", "otro"],
                    help="filtra por tipo de asset")
    ap.add_argument("--extract", metavar="NAME", help="extrae un fichero del pak")
    ap.add_argument("--out", type=Path, default=Path("."), help="destino de --extract")
    args = ap.parse_args()

    if not args.pak.is_file():
        print(f"error: no existe {args.pak}", file=sys.stderr)
        return 1

    with args.pak.open("rb") as fh:
        dirofs, dirlen = read_pak_header(fh)
        entries = list(read_entries(fh, dirofs, dirlen))

        if args.extract:
            name = args.extract.replace("\\", "/")
            for n, pos, size in entries:
                if n.replace("\\", "/") == name:
                    fh.seek(pos)
                    data = fh.read(size)
                    out = args.out / Path(name).name
                    out.parent.mkdir(parents=True, exist_ok=True)
                    out.write_bytes(data)
                    print(f"extraido {name} -> {out} ({size} bytes)")
                    return 0
            print(f"error: '{name}' no esta en el pak", file=sys.stderr)
            return 1

        if args.grep or args.category:
            import re
            rx = re.compile(args.grep, re.IGNORECASE) if args.grep else None
            shown = 0
            for name, _pos, size in entries:
                norm = name.replace("\\", "/")
                if rx and not rx.search(norm):
                    continue
                if args.category and classify(norm) != args.category:
                    continue
                print(f"{size:>10}  {norm}")
                shown += 1
            print(f"--- {shown} ficheros ---", file=sys.stderr)
            return 0

        if args.list:
            for name, _pos, size in entries:
                print(f"{size:>10}  {name}")
            return 0

        summarise(args.pak, entries)
    return 0


if __name__ == "__main__":
    sys.exit(main())
