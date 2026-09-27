/* edtex.c -- atlas de texturas para la vista del editor.
 *
 * GPL-2.0, ver LICENSE en la raiz del repositorio.
 */

#include "edtex.h"

#include <SDL.h>
#include <SDL_opengl.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

#define EDTEX_CELDA 128  /* lado de una casilla, en pixeles */

struct edtex_s {
	GLuint tex;
	int cols;   /* casillas por fila */
	int n;      /* casillas usadas */
	char **nombres;
};

/* Los .map suelen traer los nombres en minusculas y con barras, y la biblioteca
 * tiene los nombres de verdad (t_wall1ba). La comparacion es sin distinciones
 * como en texlib_find. */
static int mismo_nombre(const char *a, const char *b)
{
	while (*a && *b) {
		int ca = (*a >= 'A' && *a <= 'Z') ? *a + 32 : *a;
		int cb = (*b >= 'A' && *b <= 'Z') ? *b + 32 : *b;
		if (ca != cb)
			return 0;
		a++;
		b++;
	}
	return *a == *b;
}

static int celda_de_nombre(edtex_t *e, const char *nombre)
{
	int i;
	if (!e || !nombre)
		return -1;
	for (i = 0; i < e->n; i++)
		if (mismo_nombre(e->nombres[i], nombre))
			return i;
	return -1;
}

edtex_t *edtex_new(texlib_t *lib, map_t *map)
{
	edtex_t *e;
	const unsigned char *pal;
	entity_t *ent;
	unsigned char *img = NULL;
	int w, h, cols, filas, total, x, y, i;
	GLuint tex = 0;

	if (!lib || !map)
		return NULL;
	pal = texlib_paleta(lib);
	if (!pal)
		return NULL; /* sin paleta no hay color: solo indices */

	e = xcalloc(1, sizeof(edtex_t));
	e->nombres = NULL;

	/* Celda por cada nombre DISTINTO que usa el mapa. El nombre del .map se
	 * queda como clave, no el de la textura de verdad: asi el mapa sigue
	 * pidiendo "wall1" y quien decide que se parece a t_wall1ba es la
	 * biblioteca, igual que en el lump TEXTURES del .bsp. */
	for (ent = map->entities; ent; ent = ent->next) {
		brush_t *b;
		for (b = ent->brushes; b; b = b->next) {
			for (i = 0; i < b->numsides; i++) {
				const char *no = b->sides[i].texname;
				if (!no || celda_de_nombre(e, no) >= 0)
					continue;
				e->nombres = xrealloc(e->nombres, sizeof(char *) * (size_t)(e->n + 1));
				e->nombres[e->n] = xstrdup(no);
				e->n++;
			}
		}
	}
	if (e->n == 0) {
		edtex_free(e);
		return NULL;
	}

	cols = 1;
	while (cols * cols < e->n)
		cols++;
	filas = (e->n + cols - 1) / cols;
	w = cols * EDTEX_CELDA;
	h = filas * EDTEX_CELDA;
	total = w * h;

	img = xmalloc((size_t)total * 4);
	memset(img, 0xFF, (size_t)total * 4);

	for (i = 0; i < e->n; i++) {
		const miptex_t *m = texlib_sugerir(lib, e->nombres[i]);
		int cx, cy, mx, my;
		if (!m || m->width <= 0 || m->height <= 0)
			continue;
		cx = (i % cols) * EDTEX_CELDA;
		cy = (i / cols) * EDTEX_CELDA;
		for (my = 0; my < m->height; my++) {
			int dy = cy + my;
			if (dy >= h)
				break;
			for (mx = 0; mx < m->width; mx++) {
				int dx = cx + mx;
				unsigned char idx;
				size_t o;
				if (dx >= w)
					break;
				/* La paleta son 3 bytes por color, no 1: 256*3 = 768. */
				idx = m->pixels[(size_t)my * m->width + mx] & 0xFF;
				o = ((size_t)dy * w + dx) * 4;
				img[o + 0] = pal[idx * 3 + 0];
				img[o + 1] = pal[idx * 3 + 1];
				img[o + 2] = pal[idx * 3 + 2];
				img[o + 3] = 255;
			}
		}
	}
	(void)x;
	(void)y;
	if (getenv("DIREKT_EDTEX_DEBUG"))
		fprintf(stderr, "direkt-edit: atlas de %d casillas, %dx%d, de %s\n", e->n,
		        w, h, texlib_origen(lib));

	glGenTextures(1, &tex);
	glBindTexture(GL_TEXTURE_2D, tex);
	/* LINEAR sin mipmaps: en el atlas no se pueden generar mipmaps (se
	 * mezclarian casillas vecinas) y la vista del editor se acerca muy poco
	 * como para que se note. */
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
	/* REPEAT, y no CLAMP: el juego repite la textura cada unidad de mundo, y lo
	 * hace dejando que la coordenada crezca y la repita la tarjeta, no
	 * quedandose con la parte fraccionaria. Con CLAMP un muro largo se
	 * aplana entero. */
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_REPEAT);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_REPEAT);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE,
	             img);
	e->tex = tex;
	e->cols = cols;
	free(img);
	return e;
}

void edtex_free(edtex_t *e)
{
	int i;
	if (!e)
		return;
	for (i = 0; i < e->n; i++)
		free(e->nombres[i]);
	free(e->nombres);
	if (e->tex)
		glDeleteTextures(1, &e->tex);
	free(e);
}

unsigned int edtex_gl(edtex_t *e)
{
	return e ? (unsigned int)e->tex : 0u;
}

int edtex_celda(edtex_t *e, const char *nombre)
{
	return celda_de_nombre(e, nombre);
}

int edtex_uv(edtex_t *e, const char *nombre, float s, float t, float *u, float *v)
{
	int c = celda_de_nombre(e, nombre);
	if (c < 0)
		return 0;
	/* La casilla se consigue desplazando, no con la parte fraccionaria.
	 *
	 * Un mapa tiene las coordenadas enteras (un muro de 0 a 64 son 0 y 64), y
	 * con los ejes unitarios que da brush_side_axes las coordenadas de
	 * textura tambien son enteras: su parte fraccionaria es SIEMPRE 0, y con
	 * ella todas las caras salian de un solo texel de color plano.
	 *
	 * Lo que hace el juego es repetir la textura cada unidad de mundo, y eso lo
	 * lleva la repeticion de la tarjeta con la coordenada creciendo. Aqui se
	 * traduce al ancho de la casilla: una unidad de textura son 1/cols de la
	 * atlas, que es justo una casilla. */
	*u = ((float)(c % e->cols) + s) / (float)e->cols;
	*v = ((float)(c / e->cols) + t) / (float)e->cols;
	return 1;
}
