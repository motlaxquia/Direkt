/* edtex.h -- atlas de texturas para la vista del editor.
 *
 * GPL-2.0, ver LICENSE en la raiz del repositorio.
 *
 * El editor no puede darle a OpenGL 1.2 un bunch de texturas: solo tiene una
 * textura por unidad. Lo que hace es juntarlas todas en una sola imagen, cada
 * textura en su casilla, y，然后把 cada cara se pinta con la casilla que le
 * toca.
 *
 * Se juntan SOLO las texturas que usa el documento, no las 300 y pico de la
 * biblioteca: un mapa normal usa unas pocas, y una atlas de 1024x256 se
 * descarga en nada mientras que una de 2048x2048 no.
 *
 * Lo importante es que las coordenadas salen de los MISMOS ejes que usa el
 * compilador (brush_side_axes), porque si el editor se calculara los suyos el
 * mapa se veria de una manera aqui y de otra en el juego, y el editor estaria
 * mintiendo sobre lo que se va a ver.
 */

#ifndef DIREKT_EDTEX_H
#define DIREKT_EDTEX_H

#include "direktbsp.h"
#include "tex.h"

typedef struct edtex_s edtex_t;

/* Construye la atlas con las texturas que usa `map`. Si no hay biblioteca de
 * texturas, o no se encuentra ninguna, devuelve NULL y el editor sigue con los
 * colores planos de siempre: no es un fallo, es el modo de ALWAYS funcionar. */
edtex_t *edtex_new(texlib_t *lib, map_t *map);
void edtex_free(edtex_t *e);

/* Devuelve la textura GL de la atlas, o 0 si no hay atlas. */
unsigned int edtex_gl(edtex_t *e);

/* Celda de un nombre de textura, o -1 si no esta en la atlas. */
int edtex_celda(edtex_t *e, const char *nombre);

/* Pasa unas coordenadas de textura del mundo a la atlas. `s` y `t` son las
 * coordenadas ya escaladas del cara (ver brush_side_axes); se envuelven a la
 * casilla con la parte fraccionaria, que es lo que hace el juego al repetir.
 * Devuelve 0 si el nombre no esta, para que el llamante pueda pintar la cara
 * con un color plano. */
int edtex_uv(edtex_t *e, const char *nombre, float s, float t, float *u, float *v);

#endif /* DIREKT_EDTEX_H */
