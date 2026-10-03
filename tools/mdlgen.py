#!/usr/bin/env python3
"""Genera un modelo .mdl v6, el formato alias de Quake.

    tools/mdlgen.py --paleta build/lq/full/id1/pak0.pak --salida g/gibhead.mdl

Existe porque falta un modelo en LibreQuake y hace falta uno propio. Los modelos
del Quake original son propietarios de id Software, y esa decision esta escrita
en THIRD_PARTY.md. Cambiarle la textura a un modelo suyo no lo vuelve libre: lo
que esta protegido es la geometria. Asi que el modelo se escribe aqui.

TRAMPAS DEL FORMATO

Estan todas en el cargador del motor (Quake/gl_model.c y Quake/modelgen.h), que
es el unico sitio donde hay que mirar. Ninguna es intuitiva:

1. La firma no es "IDALIAS". Mod_LoadModel decide con

       mod_type = buf[0] | buf[1]<<8 | buf[2]<<16 | buf[3]<<24

   y lo compara con IDPOLYHEADER, que vale ('O'<<24)+('P'<<16)+('D'<<8)+'I'.
   Leido byte a byte en orden, eso son los caracteres I, D, P, O: el fichero
   tiene que empezar LITERALMENTE con "IDPO". Si se escribe "IDALIAS", el
   motor no encuentra ningun cargador para ese numero y se niega a abrirlo.

2. Lo unico que el motor comprueba del alias es la version, que tiene que ser
   6 (ALIAS_VERSION). El ident no se mira para nada, pero se escribe bien.

3. La piel no son colores. Son indices de 8 bits contra la paleta del juego, la
   de gfx/palette.lmp, y el motor los pasa por d_8to24table. Un .mdl no lleva
   paleta dentro, con lo que no hay forma de escribir un color absoluto. Por eso
   los indices se buscan en la paleta por parecido y no se fijan a mano: la
   paleta de LibreQuake no tiene por que ser la que uno espera, y con un indice
   fijo el modelo saldria de un color raro sin que se supiera de donde.

4. El indice 0 es transparente: Mod_FloodFillSkin lo inunda desde el borde y
   hace un recorte. Por eso la cara va sobre fondo opaco y no transparente.

5. La luz sale de colormap.lmp. El lightnormalindex de cada vertice va de 0 a
   255, y con 0 el modelo sale completamente negro; con 255 sale plano y sin
   volumen. Por defecto se usa LUZ.

6. Cada vertice lleva su s y su t, y el motor triangula la piel con eso. Una
   caja con las coordenadas bien puestas se ve con su textura; con las
   coordenadas mal puestas sale toda del mismo color.
"""

import argparse
import math
import struct
import sys
from pathlib import Path

# --- constantes del formato (modelgen.h) -----------------------------------
# IDPOLYHEADER leido como los cuatro primeros bytes en orden de fichero.
FIRMA = b"IDPO"
VERSION = 6
FRAME_SINGLE = 0
SKIN_SINGLE = 0

# Los flags del .mdl.
#
# OJO CON ESTE 4. Son dos cosas DISTINTAS que casan en el mismo bit:
#
#   * En la cabecera del modelo, MF_ROTATE (4) le dice al motor que gire el
#     modelo con su avelocity. Es lo que hace que la cabeza deforme al volar.
#   * En la lista de modelos, EF_GIB (4) le dice al motor que ESA ENTIDAD
#     suelta un rastro de SANGRE. Esta es en cl_main.c:
#
#         if (ent->model->flags & EF_GIB)
#             CL_RocketTrail (ent, 2);      // 2 = sangre
#
#     El rastro sale SOLO, sin que el juego mande nada: el motor lo hace cada
#     frame mientras la entidad se mueve.
#
# Por lo tanto, quitar el MF_ROTATE de la cabeza le quita la sangre sin que
# ningun aviso. Se deja escrito en el sitio de los flags, no solo aqui.
MF_ROTATE = 0x0004
EF_GIB = 0x0004        # el mismo bit, otra cosa: el rastro de sangre

FRAME_NAME_LEN = 16

SKIN_ANCHO = 64
SKIN_ALTO = 64

# Ver el punto 5 de la cabecera.
LUZ = 200


# ------------------------------------------------------------------- paleta
def _entradas_pak(ruta: Path):
    """Las entradas de un .pak, reutilizando pakinfo.py.

    No se copia la tabla entera: se devuelve el generador y se va buscando lo
    que hace falta, que son tres ficheros sueltos como mucho.
    """
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import pakinfo

    fh = open(ruta, "rb")
    dirofs, dirlen = pakinfo.read_pak_header(fh)
    entradas = pakinfo.read_entries(fh, dirofs, dirlen)
    return fh, entradas


def extraer_de_pak(ruta: Path, nombre: str) -> bytes:
    fh, entradas = _entradas_pak(ruta)
    try:
        for n, pos, tam in entradas:
            if n.replace("\\", "/").lower() == nombre.lower():
                fh.seek(pos)
                return fh.read(tam)
    finally:
        fh.close()
    raise SystemExit(f"ERROR: {ruta} no contiene {nombre}")


def leer_paleta(ruta_pak: Path) -> bytes:
    """gfx/palette.lmp: 256 colores RGB, 768 bytes."""
    datos = extraer_de_pak(ruta_pak, "gfx/palette.lmp")
    if len(datos) != 768:
        raise SystemExit(
            f"ERROR: la paleta deberia tener 768 bytes (256 RGB) y tiene {len(datos)}")
    return datos


def indice_mas_parecido(paleta: bytes, r: int, g: int, b: int) -> int:
    """El indice de la paleta mas cercano a un color RGB."""
    mejor, mejor_dist = 0, None
    for i in range(256):
        pr = paleta[i * 3]
        pg = paleta[i * 3 + 1]
        pb = paleta[i * 3 + 2]
        d = (pr - r) ** 2 + (pg - g) ** 2 + (pb - b) ** 2
        if mejor_dist is None or d < mejor_dist:
            mejor, mejor_dist = i, d
    return mejor


# ------------------------------------------------------------------ geometria
class Malla:
    """Vertices y triangulos. Cada vertice lleva su s y su t de piel."""

    def __init__(self):
        self.verts = []   # (x, y, z, s, t)
        self.tris = []    # (a, b, c, facesfront)

    def vertice(self, x, y, z, s, t) -> int:
        self.verts.append((x, y, z, s, t))
        return len(self.verts) - 1

    def triangulo(self, a, b, c, front=1) -> None:
        self.tris.append((a, b, c, front))

    def quad(self, a, b, c, d, front=1) -> None:
        self.triangulo(a, b, c, front)
        self.triangulo(a, c, d, front)

    def radio(self) -> float:
        if not self.verts:
            return 1.0
        return max(math.sqrt(v[0] ** 2 + v[1] ** 2 + v[2] ** 2) for v in self.verts)


def caja(malla: Malla, mins, maxs, rect_piel) -> None:
    """Las seis caras de una caja, con el rectangulo de piel que se le pase.

    rect_piel es (s0, t0, s1, t1). La cara +z, que es la que mira al jugador,
    recibe el rectangulo entero; las demas reciben el mismo, y el motor las
    pliega con los s,t de cada vertice.
    """
    s0, t0, s1, t1 = rect_piel
    (x0, y0, z0) = mins
    (x1, y1, z1) = maxs
    sm, tm = (s0 + s1) // 2, (t0 + t1) // 2

    esquinas = {
        "000": (x0, y0, z0, s0, tm),
        "100": (x1, y0, z0, sm, tm),
        "110": (x1, y1, z0, s1, tm),
        "010": (x0, y1, z0, sm, tm),
        "001": (x0, y0, z1, sm, t0),
        "101": (x1, y0, z1, s1, tm),
        "111": (x1, y1, z1, sm, t1),
        "011": (x0, y1, z1, s0, tm),
    }
    v = {k: malla.vertice(*p) for k, p in esquinas.items()}

    malla.quad(v["100"], v["101"], v["111"], v["110"], 0)   # -y
    malla.quad(v["000"], v["010"], v["011"], v["001"], 0)   # +y
    malla.quad(v["101"], v["100"], v["110"], v["111"], 1)   # +x
    malla.quad(v["000"], v["001"], v["011"], v["010"], 0)   # -x
    malla.quad(v["011"], v["111"], v["110"], v["010"], 1)   # +z  (la cara)
    malla.quad(v["000"], v["100"], v["101"], v["001"], 0)   # -z


def construir_cabeza(ancho: int, alto: int) -> Malla:
    """La cabeza: un cubo con la cara, y una nariz que asome.

    Es un cubo y no una esfera de ocho lados a proposito. El formato alias solo
    tiene triangulos planos, y con el mismo numero de caras un cubo con buena
    iluminacion se lee mejor de lejos que una esfera chopped: lo que identifica
    la cabeza de lejos es la cara, no la redondez.
    """
    malla = Malla()
    # El cuerpo de la cabeza, con la piel entera para la cara (+z).
    caja(malla, (-16, -16, -16), (16, 16, 16), (0, 0, ancho - 1, alto // 2 - 1))

    # La nariz: un cubito delante, con piel del color de la piel. Da la
    # sensacion de que mira hacia donde mira.
    caja(malla, (-5, -21, -5), (5, -15, 5),
         (ancho // 4, alto // 4, ancho // 4 + 6, alto // 4 + 6))
    return malla


# ---------------------------------------------------------------------- piel
def cara_feliz(paleta: bytes, ancho: int, alto: int) -> bytes:
    """La cara feliz, sobre fondo opaco.

    Los indices se buscan en la paleta (punto 3 de la cabecera) en vez de
    fijarlos. Y el fondo es opaco (punto 4) para que no haya recorte.
    """
    neg = indice_mas_parecido(paleta, 10, 10, 10)
    sombra = indice_mas_parecido(paleta, 45, 45, 45)
    claro = indice_mas_parecido(paleta, 220, 220, 220)
    brillo = indice_mas_parecido(paleta, 248, 248, 248)

    piel = bytearray([sombra]) * (ancho * alto)

    def pinta(x, y, idx):
        if 0 <= x < ancho and 0 <= y < alto:
            piel[y * ancho + x] = idx

    # La cara ocupa el rectangulo que la caja dio a la cara +z: de (0,0) a
    # (ancho-1, alto//2-1). Todo lo de abajo es la nuca y el pelo de fondo.
    cx = ancho // 2
    cy = (alto // 2) // 2
    r = min(ancho, alto // 2) // 2 - 2

    # Craneo.
    for y in range(alto // 2):
        for x in range(ancho):
            dx, dy = x - cx, y - cy
            d2 = dx * dx + dy * dy
            if d2 <= r * r:
                pinta(x, y, claro)
            elif d2 <= (r + 3) * (r + 3):
                pinta(x, y, sombra)

    # Ojos: dos elipses.
    ex_dx, ex_r = 9, 4
    for ex in (cx - ex_dx, cx + ex_dx):
        ey = cy - 5
        for y in range(ey - ex_r - 2, ey + ex_r + 3):
            for x in range(ex - ex_r - 2, ex + ex_r + 3):
                dx, dy = (x - ex) * 3, (y - ey)
                if dx * dx + dy * dy <= (ex_r * ex_r) * 3:
                    pinta(x, y, neg)

    # Cejas, para que el "feliz" se lea de lejos y no solo de cerca.
    for ex in (cx - ex_dx, cx + ex_dx):
        for x in range(ex - 8, ex + 8):
            pinta(x, ey - 7 + abs(x - ex) // 4, sombra)

    # Sonrisa: dos arcos, no una elipse entera. Con la elipse la cabeza parece
    # una mueca; con el arco, una sonrisa.
    for dx in range(-15, 16):
        y = cy + 12 - (dx * dx) // 8
        for k in (-1, 0, 1):
            pinta(cx + dx, y + k, neg)

    # Nariz y barbilla, para que no quede plana.
    for y in range(cy + 2, cy + 5):
        pinta(cx, y, brillo)
        pinta(cx + 1, y, sombra)
    for x in range(cx - 7, cx + 7):
        pinta(x, cy + 19, sombra)

    return bytes(piel)


# ----------------------------------------------------------------- escritura
def escribir_mdl(ruta: Path, malla: Malla, piel: bytes, ancho: int, alto: int,
                 escala: float = 1.0, nombre: str = "cabeza") -> int:
    ident = struct.unpack("<i", FIRMA)[0]
    out = bytearray()

    # Cabecera mdl_t. El ident se escribe para que un lector futuro lo entienda,
    # aunque este motor no lo mire.
    out += FIRMA
    out += struct.pack("<i", VERSION)
    out += struct.pack("<3f", escala, escala, escala)
    out += struct.pack("<3f", 0.0, 0.0, 0.0)
    out += struct.pack("<f", malla.radio() * escala)
    out += struct.pack("<3f", 0.0, 0.0, 0.0)
    out += struct.pack("<i", 1)            # numskins
    out += struct.pack("<i", ancho)
    out += struct.pack("<i", alto)
    out += struct.pack("<i", len(malla.verts))
    out += struct.pack("<i", len(malla.tris))
    out += struct.pack("<i", 1)            # numframes
    out += struct.pack("<i", 0)            # synctype = ST_SYNC
    # MF_ROTATE y EF_GIB son el mismo bit (4) en dos listas distintas. Con esto
    # la cabeza gira Y suelta sangre.
    flags = MF_ROTATE | EF_GIB
    out += struct.pack("<i", flags)
    out += struct.pack("<f", 0.0)          # size, sin uso en alias v6

    # Piel.
    out += struct.pack("<i", SKIN_SINGLE)
    out += piel

    # Vertices con sus coordenadas de piel (stvert_t).
    for (_x, _y, _z, s, t) in malla.verts:
        out += struct.pack("<3i", 0, int(round(s)), int(round(t)))

    # Triangulos (dtriangle_t). facesfront va a 1 en las caras que se ven de
    # frente, que es como decide el motor si las ilumina del otro lado.
    for (a, b, c, front) in malla.tris:
        out += struct.pack("<4i", 1 if front else 0, a, b, c)

    # Un unico frame (daliasframetype_t + daliasframe_t + trivertx_t).
    xs = [v[0] for v in malla.verts]
    ys = [v[1] for v in malla.verts]
    zs = [v[2] for v in malla.verts]
    out += struct.pack("<i", FRAME_SINGLE)
    # bboxmin y bboxmax son trivertx_t, y un trivertx_t son CUATRO bytes: tres
    # de coordenadas y el indice de luz. Escribir solo tres deja la caja
    # desplazada seis bytes y todo lo que viene detras, mal leido. Por eso el
    # ultimo byte es el indice de luz, no relleno.
    out += struct.pack("<4B", int(min(xs)) & 0xFF, int(min(ys)) & 0xFF,
                       int(min(zs)) & 0xFF, LUZ)
    out += struct.pack("<4B", int(max(xs)) & 0xFF, int(max(ys)) & 0xFF,
                       int(max(zs)) & 0xFF, LUZ)
    out += nombre.encode("ascii", "replace")[:FRAME_NAME_LEN - 1].ljust(
        FRAME_NAME_LEN, b"\0")
    for (x, y, z, _s, _t) in malla.verts:
        out += struct.pack("<3B", int(x) & 0xFF, int(y) & 0xFF, int(z) & 0xFF)
        out += struct.pack("<B", LUZ)

    ruta.parent.mkdir(parents=True, exist_ok=True)
    ruta.write_bytes(bytes(out))
    return len(out)


# --------------------------------------------------------------- verificacion
def verificar(ruta: Path) -> list:
    """Repite la aritmetica del cargador del motor y devuelve los fallos.

    Un .mdl mal hecho no da ningun error claro: el motor lee basura y sale con
   Vertices que no cuadran y una texturamade un lio. Lo unico que se nota es que
    la cuenta no cuadra con el tamano del fichero. Eso es justo lo que se mira
    aqui, con los mismos tamaños que usa gl_model.c.
    """
    fallos = []
    datos = ruta.read_bytes()
    ident, version = struct.unpack_from("<ii", datos, 0)
    if ident != struct.unpack("<i", FIRMA)[0]:
        fallos.append(f"la firma no es IDPOLYHEADER: {ident:#x}")
    if version != VERSION:
        fallos.append(f"la version es {version} y tiene que ser {VERSION}")

    # Se vuelve a leer desde los offsets del mdl_t, campo a campo, que es mas
    # claro que un calculo de struct con formatos raros.
    def entero(pos):
        return struct.unpack_from("<i", datos, pos)[0]

    # ident, version, scale[3], scale_origin[3]: ocho palabras.
    p = 4 * 8
    p += 4 + 4 * 3     # boundingradius, eyeposition
    numskins = entero(p); p += 4
    ancho = entero(p); p += 4
    alto = entero(p); p += 4
    nverts = entero(p); p += 4
    ntris = entero(p); p += 4
    nframes = entero(p); p += 4
    p += 4            # synctype
    p += 4            # flags
    p += 4            # size

    # Pieles.
    for _ in range(numskins):
        tipo = entero(p); p += 4
        if tipo != SKIN_SINGLE:
            fallos.append(f"tipo de piel {tipo}; solo se sabe hacer el simple")
            break
        p += ancho * alto

    # Vertices, triangulos, frames: los tres seguidos, como los lee el motor.
    p += nverts * 12
    p += ntris * 16
    p += 4             # daliasframetype_t
    p += 8             # bboxmin y bboxmax: dos trivertx_t de 4 bytes
    p += FRAME_NAME_LEN
    p += nverts * 4    # trivertx_t

    if p != len(datos):
        fallos.append(
            f"las estructuras terminan en {p} y el fichero mide {len(datos)}; "
            f"sobran o faltan {len(datos) - p} bytes")
    return fallos


def main() -> int:
    ap = argparse.ArgumentParser(description="Genera el modelo de la cabeza")
    ap.add_argument("--paleta", type=Path,
                    help="pak de LibreQuake del que sacar gfx/palette.lmp")
    ap.add_argument("--salida", type=Path)
    ap.add_argument("--ancho", type=int, default=SKIN_ANCHO)
    ap.add_argument("--alto", type=int, default=SKIN_ALTO)
    ap.add_argument("--escala", type=float, default=1.0)
    ap.add_argument("--verificar", type=Path,
                    help="comprueba un .mdl ya escrito y sale")
    args = ap.parse_args()

    if args.verificar:
        fallos = verificar(args.verificar)
        for f in fallos:
            print(f"FALLO: {f}", file=sys.stderr)
        if fallos:
            return 1
        print(f"    {args.verificar}: la cuenta cuadra con el tamaño del fichero")
        return 0

    if not args.paleta or not args.salida:
        ap.error("hacen falta --paleta y --salida (o solo --verificar)")

    paleta = leer_paleta(args.paleta)
    malla = construir_cabeza(args.ancho, args.alto)
    piel = cara_feliz(paleta, args.ancho, args.alto)
    tam = escribir_mdl(args.salida, malla, piel, args.ancho, args.alto,
                       args.escala)

    neg = indice_mas_parecido(paleta, 10, 10, 10)
    claro = indice_mas_parecido(paleta, 220, 220, 220)
    sombra = indice_mas_parecido(paleta, 45, 45, 45)
    brillo = indice_mas_parecido(paleta, 248, 248, 248)
    print(f"    {args.salida}: {tam} bytes, {len(malla.verts)} vertices, "
          f"{len(malla.tris)} triangulos, piel {args.ancho}x{args.alto}")
    print(f"    paleta de la cara: negro={neg} sombra={sombra} "
          f"claro={claro} brillo={brillo}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
