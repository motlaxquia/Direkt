/* tex.h -- biblioteca de texturas de Quake.
 *
 * GPL-2.0, ver LICENSE en la raiz del repositorio.
 *
 * De donde salen las texturas, con LibreQuake:
 *
 *   - `gfx.wad` esta dentro de pak0.pak y solo tiene la interfaz (ANUM, FACE,
 *     BACKTILE...). Las texturas de mundo NO estan ahi.
 *   - Las texturas de mundo van EMBEBIDAS en el lump TEXTURES de cada .bsp.
 *     `maps/lq_e1m1.bsp` trae 180, y juntando cuatro mapas salen unas 390
 *     distintas: t_wall1ba, t_flat01, wbrick1_5, t_metalsheeta...
 *
 * O sea que la unica fuente de texturas de verdad que hay en el disco son los
 * .bsp que ya vienen. Esta biblioteca las cosecha de ahi, y ademas mira en
 * `gfx.wad` por si aparece un WAD de verdad.
 *
 * PAK y WAD2 estan documentados en common.h y wad.h del motor. Lo que NO
 * conviene inventarse es el layout del lump TEXTURES: es
 * `int nummiptex; int dataofs[nummiptex];` seguido de los miptex, y el motor
 * copia solo el primer mip (gl_model.c: "only copy the first mip, the rest are
 * auto-generated").
 */

#ifndef DIREKT_TEX_H
#define DIREKT_TEX_H

/* Un miptex: nombre, tamano y el primer mip. Los bytes apuntan dentro del
 * bloque que lo contiene, asi que hay que soltar ese bloque antes de soltarlo
 * a el. */
typedef struct {
	const char name[17];
	int width, height;
	const unsigned char *pixels; /* width*height, indices de la paleta */
} miptex_t;

typedef struct texlib_s texlib_t;

/* Abre la biblioteca. `rutas` es una lista terminada en NULL de directorios de
 * juego: se mira primero un `gfx.wad` suelto y luego dentro de los .pak, y se
 * cosecha el lump TEXTURES de los .bsp que haya en el pak.
 *
 * Devuelve NULL si no encuentra nada; eso no es un error grave, solo significa
 * que no habra texturas. */
texlib_t *texlib_open(char *const *rutas);
/* Abre la biblioteca de texturas del juego que esta montado, sin tener que
 * saber donde esta. Mira DIREKT_GAMEDIR y luego los sitios de siempre.
 *
 * Vive aqui y no en main.c porque el editor tambien compila (F5) y su .bsp
 * tambien tiene que salir con texturas: si no, lo que se ve en el juego no es
 * lo que se ha visto en el editor. Devuelve NULL si no hay ninguna, y eso no es
 * un fallo: el .bsp sale sin lump TEXTURES y el motor usa su textura por
 * defecto. */
texlib_t *texlib_open_juego(void);
void texlib_close(texlib_t *t);

int texlib_count(texlib_t *t);
/* Busca por nombre exacto, sin distinguir mayusculas. */
const miptex_t *texlib_find(texlib_t *t, const char *nombre);
/* Busca por prefijo, para cuando el .map pide un nombre que no esta. Devuelve
 * la primera que empiece por `prefijo`, o NULL. */
const miptex_t *texlib_find_prefix(texlib_t *t, const char *prefijo);
/* Elige una textura para un nombre pedido que no existe: reconoce los nombres
 * clasicos de Quake (wall, floor, ceil, metal, wood, rock, sky) y devuelve
 * algo razonable de la biblioteca. Devuelve NULL si no hay nada parecido. */
const miptex_t *texlib_sugerir(texlib_t *t, const char *nombre);
/* Por donde se han sacado las texturas, para los mensajes. */
const char *texlib_origen(texlib_t *t);
/* La paleta de 256 colores (gfx/palette.lmp), o NULL si no se encuentra. */
const unsigned char *texlib_paleta(texlib_t *t);
/* True si el nombre es de las que el motor trata aparte (cielo '*' y liquidos
 * '+' y '-'), y que por tanto no hay que meter en el lump TEXTURES: el motor
 * las busca como imagen suelta y no como miptex. */
int tex_es_especial(const char *nombre);

#endif /* DIREKT_TEX_H */
