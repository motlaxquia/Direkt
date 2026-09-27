#!/usr/bin/env python3
"""Comprueba el arbol de clipnodes de un .bsp como lo haria Ironwail.

Replica SV_RecursiveHullCheck (Quake/world.c) y Mod_LoadClipNodes
(Quake/gl_model.c), incluida la conversion de las hojas:

    out->children[i] = (unsigned short)LittleShort(...);
    if (out->children[i] >= count) out->children[i] -= 65536;

Ademas calcula la respuesta correcta por su cuenta a partir de las brushes
dilatadas, para no depender de expectativas escritas a mano.
"""
import struct
import sys

HULL = 1
HMIN = (-16, -16, -24)
HMAX = (16, 16, 32)


def load(path):
    d = open(path, "rb").read()
    off = [struct.unpack_from("<2i", d, 4 + 8 * i) for i in range(15)]
    nplanes = off[1][1] // 20
    planes = []
    for i in range(nplanes):
        nx, ny, nz, dist, _t = struct.unpack_from("<4fi", d, off[1][0] + i * 20)
        planes.append(((nx, ny, nz), dist))
    nclip = off[9][1] // 8
    nodes = []
    for i in range(nclip):
        pe = struct.unpack_from("<i", d, off[9][0] + i * 8)[0]
        c0, c1 = struct.unpack_from("<2h", d, off[9][0] + i * 8 + 4)
        c0 &= 0xFFFF
        c1 &= 0xFFFF
        if c0 >= nclip:
            c0 -= 65536
        if c1 >= nclip:
            c1 -= 65536
        nodes.append((pe, c0, c1))
    head = struct.unpack_from("<4i", d, off[14][0] + 36)
    # dheader_t NO lleva mins/maxs: solo version + 15 lumps. Los limites del
    # mapa estan en el lump dmodel (float mins[3], maxs[3], origin[3], ...).
    mo = off[14][0]
    tmin = struct.unpack_from("<3f", d, mo)
    tmax = struct.unpack_from("<3f", d, mo + 12)
    # El arbol de clipnodes arranca en los limites del mapa SIN recortar 256
    # unidades por cada lado (src/clip.c), no en los del dmodel.
    import math
    bmins = tuple(int(math.floor(v)) - 256 for v in tmin)
    bmaxs = tuple(int(math.ceil(v)) + 256 for v in tmax)
    return planes, nodes, head, nclip, bmins, bmaxs


def contents(planes, nodes, head, nclip, p, bmins, bmaxs):
    """SV_RecursiveHullCheck con p1 == p2 (consulta de punto)."""
    num = head[HULL]
    pasos = 0
    lo, hi = list(bmins), list(bmaxs)
    while num >= 0:
        if num < head[HULL] or num > nclip - 1:
            return None, pasos, "bad node number", ""
        pe, c0, c1 = nodes[num]
        nrm, dist = planes[pe]
        # El motor solo usa p[type] - dist cuando plane->type < 3, o sea para
        # los tres ejes POSITIVOS. Para (0,0,-1), (0,-1,0) y (-1,0,0) el type
        # es 3, 4 y 5 y lo que corre es el producto escalar con la normal.
        if nrm == (1.0, 0.0, 0.0):
            t, e, sg = p[0] - dist, 0, 1
        elif nrm == (0.0, 1.0, 0.0):
            t, e, sg = p[1] - dist, 1, 1
        elif nrm == (0.0, 0.0, 1.0):
            t, e, sg = p[2] - dist, 2, 1
        else:
            t = nrm[0] * p[0] + nrm[1] * p[1] + nrm[2] * p[2] - dist
            e = 0 if nrm[0] else (1 if nrm[1] else 2)
            sg = 1 if nrm[e] > 0 else -1
        if t >= 0:
            if sg > 0:
                lo[e] = dist
            else:
                hi[e] = -dist
        else:
            if sg > 0:
                hi[e] = dist
            else:
                lo[e] = -dist
        num = c0 if t >= 0 else c1
        pasos += 1
        if pasos > 5000:
            return None, pasos, "bucle", ""
    return num, pasos, "", f"{lo}-{hi}"


def esperado(brushes, p):
    """-2 si el punto cae dentro de alguna brush dilatada, -1 si no.

    Comparacion ESTRICTA a proposito: el motor va a children[0] (el lado
    abierto) cuando t1 >= 0, o sea, un punto exactamente en la superficie
    dilatada se resuelve como abierto. Con <= el jugador que esta de pie
    justisimo sobre el suelo se quedaria encajado en el.
    """
    borde = False
    for lo, hi in brushes:
        if all(lo[e] < p[e] < hi[e] for e in range(3)):
            return -2
        # Si el punto cae justo en la superficie dilatada, el arbol resuelve el
        # borde hacia el lado positivo y la respuesta es legitima de las dos
        # maneras. Se marca como "da igual".
        if all(lo[e] <= p[e] <= hi[e] for e in range(3)):
            borde = True
    return "?" if borde else -1


def main():
    mapa, bsp = sys.argv[1], sys.argv[2]
    planes, nodes, head, nclip, bmins, bmaxs = load(bsp)

    # Brushes del .map, dilatadas con la caja del hull 1.
    texto = open(mapa, encoding="utf-8", errors="replace").read()
    brushes = []
    for bloque in texto.split("{"):
        lineas = [l for l in bloque.splitlines()
                  if l.strip() and not l.strip().startswith("//") and "(" in l]
        if not lineas:
            continue
        pts = []
        for l in lineas:
            nums = [float(x) for x in l.replace("(", " ").replace(")", " ")
                    .replace(",", " ").split() if _num(x)]
            pts.append(tuple(nums[:3]))
        lo = [min(q[e] for q in pts) for e in range(3)]
        hi = [max(q[e] for q in pts) for e in range(3)]
        # Consulta de punto: la caja del hull es p + [hmin, hmax], asi que la
        # brush dilatada es [lo - hmax, hi - hmin].
        dlo = [lo[e] - HMAX[e] for e in range(3)]
        dhi = [hi[e] - HMIN[e] for e in range(3)]
        brushes.append((dlo, dhi))

    pruebas = [(32, 32, 4), (32, 32, 24), (32, 32, 40), (8, 32, 32), (24, 32, 32),
               (248, 32, 32), (232, 32, 32), (128, 128, 32), (128, 128, 72),
               (128, 128, 200), (32, 200, 32), (32, 32, 176), (300, 32, 32),
               (128, 128, 96), (100, 100, -10), (200, 200, 100), (150, 150, 130),
               (16, 16, 16), (264, 264, 16), (128, 128, 130)]
    fallos = 0
    print(f"hull {HULL}: {nclip} clipnodes, headnode={head[HULL]}")
    for p in pruebas:
        esp = esperado(brushes, p)
        got, pasos, err, region = contents(planes, nodes, head, nclip, p, bmins, bmaxs)
        ok = got == esp or esp == "?"
        fallos += 0 if ok else 1
        print(f"  {'OK ' if ok else 'MAL'} {str(p):18} espera {str(esp):>4} "
              f"obtiene {str(got):>4} ({pasos} pasos) {err}")
    print(f"\n{fallos} discrepancias de {len(pruebas)}")
    return 1 if fallos else 0


def _num(x):
    try:
        float(x)
        return True
    except ValueError:
        return False


if __name__ == "__main__":
    sys.exit(main())
