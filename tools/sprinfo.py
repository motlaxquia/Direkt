#!/usr/bin/env python3
"""Audita los sprites de LibreQuake (formato VERA, sin paleta por frame).

El formato que lee ESTE motor es el de QuakeSpasm/Ironwail, que no es el de id.
Lo de aqui sale de spritegn.h y de Mod_LoadSpriteModel/Mod_LoadSpriteFrame del
motor, no de memoria. Si se cambia el motor hay que volver a mirar ahi.

Cabecera: 36 bytes, todos los campos de 4 bytes.

    offset  tipo      contenido
    0x00    int32     firma "IDSP"
    0x04    int32     version, tiene que ser 1
    0x08    int32     type, 0..4 (ver SPR_* en spritegn.h)
    0x0c    float32   boundingradius
    0x10    int32     width  (maximo de los frames)
    0x14    int32     height (maximo de los frames)
    0x18    int32     numframes
    0x1c    float32   beamlength
    0x20    int32     synctype, 0=ST_SYNC 1=ST_RAND

Detras de la cabecera van numframes entradas. Cada una empieza por un int32 con
el tipo de frame, y segun lo que sea:

    SPR_SINGLE (0)   dspriteframe_t {origin[2], width, height} = 16 bytes,
                     y despues width*height bytes de indice.
    SPR_GROUP  (1)   int32 numframes, numframes float32 de intervalo, y
    SPR_ANGLED (2)   numframes veces la estructura de SPR_SINGLE.

Ojo con dos cosas que se confunden facil:

- El numero de frames esta en 0x18, NO en 0x04. En 0x04 esta la version, que
  siempre vale 1, asi que leer frames de ahi da 1 siempre y parece funcionar.
- NO hay nombre de 64 bytes ni paleta de 256 bytes por frame. Los quitaron del
  formato. La paleta la saca el motor de gfx/palette.lmp y el fullbright de
  gfx/colormap.lmp, fuera del .spr. Por eso el --preview usa el indice como si
  fuera luminancia: es una aproximacion, no el color real.

    tools/sprinfo.py build/lq/full/id1/pak0.pak
    tools/sprinfo.py --preview s_explod.spr
    tools/sprinfo.py --json pak1.pak
"""

from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

# dsprite_t: ident, version, type | boundingradius | width, height, numframes
#            | beamlength | synctype. 9 campos de 4 bytes = 36.
HEADER_SIZE = 36
HEADER_FMT = "<3if3ifi"
HEADER_SIZE_CHECK = struct.calcsize(HEADER_FMT)

SPRITE_VERSION = 1
TRANSPARENT = 0xFF
RAMP = " .:-=+*#%@"

# spriteframetype_t
SPR_SINGLE, SPR_GROUP, SPR_ANGLED = 0, 1, 2
FRAME_TYPE_NAMES = {SPR_SINGLE: "single", SPR_GROUP: "grupo", SPR_ANGLED: "angulado"}

SYNCTYPE_NAMES = {0: "ST_SYNC", 1: "ST_RAND"}

# synctype_t
TYPE_NAMES = {
    0: "SPR_VP_PARALLEL_UPRIGHT",
    1: "SPR_FACING_UPRIGHT",
    2: "SPR_VP_PARALLEL",
    3: "SPR_ORIENTED",
    4: "SPR_VP_PARALLEL_ORIENTED",
}

# El motor aborta con Sys_Error si no cabe en esto (MAX_* de gl_model.h no
# aplican a sprites, pero un ancho absurdo es un fichero corrupto de fijo).
MAX_DIM = 4096


class SpriteError(Exception):
    pass


def _need(data: bytes, pos: int, count: int, what: str) -> None:
    """Falla con un mensaje util si no quedan bytes."""
    if pos + count > len(data):
        raise SpriteError(
            f"el fichero se acaba antes de {what}: "
            f"piden {count} bytes en {pos} y solo hay {len(data) - pos}"
        )


def _read_frame(data: bytes, pos: int, label: str) -> tuple[dict, int]:
    """Lee una dspriteframe_t y sus pixeles. Devuelve el frame y la posicion."""
    _need(data, pos, 16, f"el frame {label}")
    (ox, oy, w, h) = struct.unpack_from("<4i", data, pos)
    pos += 16

    if not (0 < w <= MAX_DIM and 0 < h <= MAX_DIM):
        raise SpriteError(f"dimensiones absurdas en {label}: {w}x{h}")

    npix = w * h
    _need(data, pos, npix, f"los pixeles de {label}")
    pixels = data[pos : pos + npix]
    pos += npix

    opaque = sum(1 for b in pixels if b != TRANSPARENT)
    return (
        {
            "label": label,
            "origin": (ox, oy),
            "width": w,
            "height": h,
            "interval": None,
            "opaque": opaque,
            "coverage": 100.0 * opaque / npix,
            "pixels": pixels,
        },
        pos,
    )


def read_sprite(data: bytes) -> dict:
    if len(data) < HEADER_SIZE:
        raise SpriteError(f"fichero demasiado corto ({len(data)} bytes)")
    if data[:4] != b"IDSP":
        raise SpriteError(f"firma {data[:4]!r} en vez de b'IDSP'")

    ident, version, sprtype, radius, w, h, numframes, beamlength, synctype = (
        struct.unpack_from(HEADER_FMT, data, 0)
    )

    if version != SPRITE_VERSION:
        raise SpriteError(f"version {version}, el motor solo admite {SPRITE_VERSION}")
    if not (0 < w <= MAX_DIM and 0 < h <= MAX_DIM):
        raise SpriteError(f"dimensiones absurdas en la cabecera: {w}x{h}")
    if numframes < 1:
        raise SpriteError(f"numframes invalido: {numframes}")

    pos = HEADER_SIZE
    frames: list[dict] = []
    for i in range(numframes):
        _need(data, pos, 4, f"el tipo del frame {i}")
        (frametype,) = struct.unpack_from("<i", data, pos)
        pos += 4

        if frametype == SPR_SINGLE:
            frame, pos = _read_frame(data, pos, f"{i}")
            frames.append(frame)
        elif frametype in (SPR_GROUP, SPR_ANGLED):
            _need(data, pos, 4, f"el grupo del frame {i}")
            (grouped,) = struct.unpack_from("<i", data, pos)
            pos += 4
            # El motor exige 8 miembros exactos en un frame inclinado.
            if frametype == SPR_ANGLED and grouped != 8:
                raise SpriteError(
                    f"el frame {i} es SPR_ANGLED con {grouped} miembros, "
                    f"y el motor exige 8"
                )
            if not 0 < grouped <= 64:
                raise SpriteError(f"el grupo del frame {i} declara {grouped} miembros")

            members: list[dict] = []
            for j in range(grouped):
                _need(data, pos, 4, f"el intervalo {i}.{j}")
                (interval,) = struct.unpack_from("<f", data, pos)
                pos += 4
                frame, pos = _read_frame(data, pos, f"{i}.{j}")
                frame["interval"] = interval
                members.append(frame)
            frames.append(
                {
                    "label": str(i),
                    "kind": "grupo",
                    "interval": None,
                    "members": members,
                }
            )
        else:
            raise SpriteError(f"el frame {i} declara un tipo desconocido: {frametype}")

    if pos > len(data):
        raise SpriteError("el recorrido de frames se pasa del final del fichero")

    # Lo que se dibuja: los members de un grupo, o el frame suelto.
    def drawables(frame: dict) -> list[dict]:
        return frame["members"] if frame.get("kind") == "grupo" else [frame]

    drawn = [f for frame in frames for f in drawables(frame)]
    total_opaque = sum(f["opaque"] for f in drawn)
    total_pix = sum(f["width"] * f["height"] for f in drawn)

    return {
        "type": sprtype,
        "type_name": TYPE_NAMES.get(sprtype, f"desconocido({sprtype})"),
        "radius": radius,
        "beamlength": beamlength,
        "width": w,
        "height": h,
        "numframes": numframes,
        "synctype": synctype,
        "synctype_name": SYNCTYPE_NAMES.get(synctype, f"desconocido({synctype})"),
        "frames": frames,
        "drawables": len(drawn),
        "opaque": total_opaque,
        "coverage": 100.0 * total_opaque / total_pix if total_pix else 0.0,
        "trailing": len(data) - pos,
    }


def _from_pak(pak_path: Path) -> list[tuple[str, bytes]]:
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from pakinfo import read_entries, read_pak_header  # type: ignore

    out: list[tuple[str, bytes]] = []
    with pak_path.open("rb") as fh:
        dirofs, dirlen = read_pak_header(fh)
        for name, filepos, filelen in read_entries(fh, dirofs, dirlen):
            if not name.lower().endswith(".spr"):
                continue
            fh.seek(filepos)
            out.append((name, fh.read(filelen)))
    return out


def _flatten(frames: list[dict]) -> list[dict]:
    out: list[dict] = []
    for frame in frames:
        if frame.get("kind") == "grupo":
            out.extend(frame["members"])
        else:
            out.append(frame)
    return out


def preview(frames: list[dict], which: int = 0) -> str:
    flat = _flatten(frames)
    if not flat:
        return "    (sin frames)"
    if not 0 <= which < len(flat):
        raise SpriteError(
            f"frame {which} fuera de rango: el sprite tiene {len(flat)}"
        )

    frame = flat[which]
    w, h, px = frame["width"], frame["height"], frame["pixels"]
    step = max(1, w // 60)
    lines = [f"  frame {which} ({frame['label']}), {w}x{h}, origen {frame['origin']}"]
    for y in range(0, h, max(1, h // 24)):
        row = "".join(
            " " if px[y * w + x] == TRANSPARENT
            else RAMP[min(len(RAMP) - 1, px[y * w + x] * len(RAMP) // 256)]
            for x in range(0, w, step)
        )
        lines.append(f"    |{row}|")
    return "\n".join(lines)


def _strip_bytes(obj):
    """Quita los bloques de pixeles para que el JSON no pese un kilo por sprite."""
    if isinstance(obj, dict):
        return {k: _strip_bytes(v) for k, v in obj.items() if k != "pixels"}
    if isinstance(obj, list):
        return [_strip_bytes(v) for v in obj]
    return obj


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("path", help="un .spr suelto o un .pak de Quake")
    ap.add_argument("--preview", action="store_true", help="dibuja los pixeles")
    ap.add_argument(
        "--frame", type=int, default=0, help="que frame dibujar (0 por defecto)"
    )
    ap.add_argument("--json", action="store_true", help="salida machine-readable")
    args = ap.parse_args()

    path = Path(args.path)
    if path.suffix.lower() == ".pak":
        sprites = _from_pak(path)
    elif path.is_file():
        sprites = [(path.name, path.read_bytes())]
    else:
        print(f"ERROR: no existe {path}", file=sys.stderr)
        return 2

    if not sprites:
        print("ERROR: no hay sprites", file=sys.stderr)
        return 1

    failures = 0
    rows = []
    for name, data in sprites:
        try:
            info = read_sprite(data)
        except SpriteError as exc:
            print(f"{name}: MAL — {exc}", file=sys.stderr)
            failures += 1
            continue

        info["name"] = name
        info["bytes"] = len(data)
        rows.append(info)

    if args.json:
        import json

        print(json.dumps(_strip_bytes(rows), indent=2))
    else:
        for info in rows:
            print(
                f"{info['name']}: OK — {info['numframes']} frame(s) "
                f"({info['drawables']} dibujables), {info['width']}x{info['height']}, "
                f"{info['type_name']}, {info['synctype_name']}, "
                f"radio={info['radius']:.1f}, "
                f"opaco={info['coverage']:.0f}%, {info['bytes']} bytes"
            )
            for frame in info["frames"]:
                if frame.get("kind") == "grupo":
                    ints = ", ".join(
                        f"{m['interval']:.3f}" for m in frame["members"]
                    )
                    print(
                        f"    frame {frame['label']}: grupo de "
                        f"{len(frame['members'])} (intervalos {ints})"
                    )
                else:
                    print(
                        f"    frame {frame['label']}: {frame['width']}x{frame['height']}, "
                        f"origen {frame['origin']}, "
                        f"opaco={frame['coverage']:.0f}%"
                    )
            if info["trailing"]:
                print(f"    {info['trailing']} bytes tras los frames (sin usar)")
            if args.preview:
                print(preview(info["frames"], args.frame))

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
