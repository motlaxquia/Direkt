/* tex.c -- biblioteca de texturas: PAK, WAD2 y lump TEXTURES de un .bsp.
 *
 * GPL-2.0, ver LICENSE en la raiz del repositorio.
 */

#define _GNU_SOURCE
#include "tex.h"

#include <ctype.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

/* Los .bsp de los que se cosecha el lump TEXTURES, en orden. Se para cuando ya
 * hay suficientes, para no tardarse en leer el pak entero. */
static const char *semillas[] = {"maps/lq_e1m1.bsp", "maps/lq_e0m1.bsp",
                                 "maps/lq_e1m4.bsp", "maps/lq_e1m7.bsp",
                                 "maps/lq_e1m2.bsp", "maps/lq_e1m5.bsp", NULL};
#define SEMILLAS_MINIMAS 260

typedef struct {
	miptex_t mt;
	unsigned char *duenio; /* el .bsp (o el wad) donde viven los pixeles */
} entrada_t;

struct texlib_s {
	entrada_t *v;
	int n, cap;
	unsigned char **bloques; /* bloques que hay que soltar al cerrar */
	int nbloques;
	unsigned char paleta[768];
	int tiene_paleta;
	char origen[256];
};

static int lee_i32(const unsigned char *p)
{
	return (int)((uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) |
	             ((uint32_t)p[3] << 24));
}

/* ------------------------------------------------------------------- PAK */

typedef struct {
	char nombre[57];
	int ofs, len;
} pak_entrada_t;

static pak_entrada_t *pak_tabla(const char *ruta, int *n)
{
	FILE *f = fopen(ruta, "rb");
	unsigned char cab[12];
	pak_entrada_t *v;
	int dirofs, dirlen, i, total;

	if (!f)
		return NULL;
	if (fread(cab, 1, 12, f) != 12 || memcmp(cab, "PACK", 4) != 0) {
		fclose(f);
		return NULL;
	}
	dirofs = lee_i32(cab + 4);
	dirlen = lee_i32(cab + 8);
	if (dirofs <= 0 || dirlen < 64) {
		fclose(f);
		return NULL;
	}
	total = dirlen / 64;
	v = calloc((size_t)total, sizeof(pak_entrada_t));
	if (!v) {
		fclose(f);
		return NULL;
	}
	for (i = 0; i < total; i++) {
		long off = (long)dirofs + (long)i * 64;
		char *p;
		if (fseek(f, off, SEEK_SET) != 0)
			break;
		if (fread(v[i].nombre, 1, 56, f) != 56)
			break;
		v[i].nombre[56] = '\0';
		for (p = v[i].nombre; *p; p++)
			if (*p == '\\')
				*p = '/';
		if (fseek(f, off + 56, SEEK_SET) != 0)
			break;
		{
			unsigned char b[8];
			if (fread(b, 1, 8, f) != 8)
				break;
			v[i].ofs = lee_i32(b);
			v[i].len = lee_i32(b + 4);
		}
	}
	fclose(f);
	*n = i;
	return v;
}

static int pak_lee(const char *ruta, const char *buscado, unsigned char **datos,
                   size_t *tam)
{
	int n = 0, i, ok = 0;
	pak_entrada_t *t = pak_tabla(ruta, &n);

	if (!t)
		return 0;
	for (i = 0; i < n; i++) {
		if (strcmp(t[i].nombre, buscado) != 0)
			continue;
		if (t[i].len <= 0 || t[i].ofs <= 0)
			break;
		{
			FILE *f = fopen(ruta, "rb");
			if (!f)
				break;
			if (fseek(f, t[i].ofs, SEEK_SET) == 0) {
				*datos = malloc((size_t)t[i].len);
				if (*datos &&
				    fread(*datos, 1, (size_t)t[i].len, f) == (size_t)t[i].len) {
					*tam = (size_t)t[i].len;
					ok = 1;
				} else {
					free(*datos);
					*datos = NULL;
				}
			}
			fclose(f);
		}
		break;
	}
	free(t);
	return ok;
}

/* ------------------------------------------------------------------- WAD2 */

/* La entrada de lumpinfo_t mide 32 bytes y el nombre va en el offset 16, no en
 * el 0. Con 16 bytes y nombre al principio los nombres salen desplazados: el
 * WAD se abre limpio y no se encuentra ni una textura. */
static int wad_tabla(const unsigned char *d, size_t tam, char ***nombres)
{
	int n, tof, i;
	char **v;

	if (tam < 12 || memcmp(d, "WAD2", 4) != 0)
		return 0;
	n = lee_i32(d + 4);
	tof = lee_i32(d + 8);
	if (n <= 0 || tof < 12 || (size_t)tof + (size_t)n * 32 > tam)
		return 0;
	v = calloc((size_t)n, sizeof(unsigned char *));
	if (!v)
		return 0;
	for (i = 0; i < n; i++) {
		const unsigned char *e = d + tof + (size_t)i * 32;
		char nm[17];
		char *p;
		memcpy(nm, e + 16, 16);
		nm[16] = '\0';
		/* W_CleanupName: minusculas, como hace el motor. */
		for (p = nm; *p; p++)
			if (*p >= 'A' && *p <= 'Z')
				*p = (char)(*p + ('a' - 'A'));
		v[i] = strdup(nm);
	}
	*nombres = v;
	return n;
}

/* ------------------------------------------------- cosecha de un .bsp */

static void lib_annade(texlib_t *lib, unsigned char *duenio, const char *nombre,
                       int w, int h, const unsigned char *px)
{
	if (lib->n >= lib->cap) {
		lib->cap = lib->cap ? lib->cap * 2 : 256;
		lib->v = realloc(lib->v, sizeof(entrada_t) * (size_t)lib->cap);
		if (!lib->v)
			return;
	}
	memcpy((char *)lib->v[lib->n].mt.name, nombre, 17);
	lib->v[lib->n].mt.width = w;
	lib->v[lib->n].mt.height = h;
	lib->v[lib->n].mt.pixels = px;
	lib->v[lib->n].duenio = duenio;
	lib->n++;
}

static int cosecha_bsp(texlib_t *lib, unsigned char *bsp, size_t tam)
{
	int ofs, len, ntex, i, anadidas = 0;

	if (tam < 144)
		return 0;
	/* LUMP_TEXTURES es el indice 2, y la cabecera son 12 bytes + 15 lumps de
	 * 8: el offset esta en 4 + 8*2 y el tamano en 4 + 8*2 + 4. */
	ofs = lee_i32(bsp + 4 + 16);
	len = lee_i32(bsp + 4 + 16 + 4);
	if (len < 8 || ofs < 0 || (size_t)ofs + (size_t)len > tam)
		return 0;
	if (ofs + 144 > (int)tam)
		return 0;
	/* La version va al PRINCIPIO del fichero, no en el lump. Mirarla en el
	 * offset del lump TEXTURES compara el numero de texturas con 29, falla
	 * siempre, y la biblioteca sale vacia sin decir por que. */
	if (bsp[0] != 29 && memcmp(bsp, "IBSP", 4) != 0)
		return 0;

	ntex = lee_i32(bsp + ofs);
	if (ntex <= 0 || ntex > 8192)
		return 0;
	if ((size_t)ofs + 4 + (size_t)ntex * 4 > (size_t)ofs + (size_t)len)
		return 0;

	for (i = 0; i < ntex; i++) {
		int dofs = lee_i32(bsp + ofs + 4 + i * 4);
		int mo, w, h, pix;
		char nombre[17];
		char *p;

		if (dofs <= 0)
			continue;
		mo = ofs + dofs;
		if (mo < 0 || mo + 40 > (int)tam)
			continue;
		if ((size_t)mo + 40 > (size_t)ofs + (size_t)len)
			continue;
		w = lee_i32(bsp + mo + 16);
		h = lee_i32(bsp + mo + 20);
		/* Las texturas de Quake son multiplos de 16; el motor avisa y se
		 * queda sin pintar si no lo son, asi que aqui se descartan. */
		if (w <= 0 || h <= 0 || (w & 15) || (h & 15))
			continue;
		pix = w * h;
		if ((size_t)mo + 40 + (size_t)pix > (size_t)ofs + (size_t)len)
			continue;
		memcpy(nombre, bsp + mo, 16);
		nombre[16] = '\0';
		if (!nombre[0])
			continue;
		for (p = nombre; *p; p++)
			if (*p >= 'A' && *p <= 'Z')
				*p = (char)(*p + ('a' - 'A'));
		if (texlib_find(lib, nombre))
			continue;
		lib_annade(lib, bsp, nombre, w, h, bsp + mo + 40);
		anadidas++;
	}
	return anadidas;
}

static void cosecha_wad(texlib_t *lib, unsigned char *wad, size_t tam)
{
	char **nombres = NULL;
	int n = wad_tabla(wad, tam, &nombres), i;

	if (n <= 0)
		return;
	for (i = 0; i < n; i++) {
		int tof = lee_i32(wad + 8);
		const unsigned char *e = wad + tof + (size_t)i * 32;
		int ofs = lee_i32(e), sz = lee_i32(e + 8);
		const unsigned char *mt;
		int w, h;

		if (!nombres[i] || !nombres[i][0])
			continue;
		if (ofs <= 0 || sz < 40 || (size_t)ofs + (size_t)sz > tam)
			continue;
		mt = wad + ofs;
		w = lee_i32(mt + 16);
		h = lee_i32(mt + 20);
		if (w <= 0 || h <= 0 || (w & 15) || (h & 15))
			continue;
		if ((size_t)sz < (size_t)40 + (size_t)w * (size_t)h)
			continue;
		if (texlib_find(lib, nombres[i]))
			continue;
		lib_annade(lib, wad, nombres[i], w, h, mt + 40);
	}
	for (i = 0; i < n; i++)
		free(nombres[i]);
	free(nombres);
}

/* ------------------------------------------------------------ biblioteca */

int texlib_count(texlib_t *t)
{
	return t ? t->n : 0;
}

const miptex_t *texlib_find(texlib_t *t, const char *nombre)
{
	char busqueda[17];
	size_t i;
	int j;

	if (!t || !nombre || !nombre[0])
		return NULL;
	snprintf(busqueda, sizeof(busqueda), "%s", nombre);
	for (j = 0; busqueda[j]; j++)
		busqueda[j] = (char)tolower((unsigned char)busqueda[j]);
	for (i = 0; i < (size_t)t->n; i++)
		if (strncmp(t->v[i].mt.name, busqueda, 16) == 0)
			return &t->v[i].mt;
	return NULL;
}

const miptex_t *texlib_find_prefix(texlib_t *t, const char *prefijo)
{
	size_t lt, i;

	if (!t || !prefijo || !prefijo[0])
		return NULL;
	lt = strlen(prefijo);
	for (i = 0; i < (size_t)t->n; i++)
		if (strncasecmp(t->v[i].mt.name, prefijo, lt) == 0)
			return &t->v[i].mt;
	return NULL;
}

/* Los nombres clasicos de Quake y su equivalente en la biblioteca. El orden
 * importa: primero el nombre entero, luego el prefijo generico. */
static const char *equivalentes[][2] = {
    {"wall1", "t_wall1"}, {"wall2", "t_wall2"}, {"wall3", "t_wall3"},
    {"wall4", "t_wall2"}, {"wall5", "t_wall3"}, {"wall6", "t_wall1"},
    {"wall7", "t_wall2"}, {"wall8", "t_wall3"},
    {"floor1", "t_flat01"}, {"floor2", "t_flat02"}, {"floor3", "t_flor1a"},
    {"ceil1", "t_flat02"}, {"ceil2", "t_flat01"}, {"ceil3", "t_flat02"},
    {"metal1", "t_metalsheet"}, {"metal2", "t_metalsheet"},
    {"metal3", "t_metalsheet"}, {"metal4", "t_metalsheet"},
    {"wood1", "woodbark64"}, {"wood2", "woodbark64"}, {"wood3", "woodbark64"},
    {"rock1", "t_wall3"}, {"rock2", "t_wall3"}, {"rock3", "t_wall3"},
    {"rock4", "t_wall3"}, {"rock2b", "t_wall3"},
    {"brick", "wbrick1"}, {"tile", "t_trim1"}, {"trim", "t_trim1"},
    {"slate", "t_trim2"}, {"concrete", "compbase"}, {"comp", "compbase"},
    {"computer", "compbase"}, {"grate", "t_metalsheet"},
    {"panel", "t_trim1"}, {"door", "doortrak"}, {"step", "t_flat01"},
    {"stone", "t_wall2"}, {"sky", "sky5"}, {"sky1", "sky5"},
    {"sky2", "sky5"}, {NULL, NULL}};

const miptex_t *texlib_sugerir(texlib_t *t, const char *nombre)
{
	int i;
	const miptex_t *m;

	if (!t || !nombre)
		return NULL;
	m = texlib_find(t, nombre);
	if (m)
		return m;

	for (i = 0; equivalentes[i][0]; i++)
		if (strcasecmp(equivalentes[i][0], nombre) == 0)
			return texlib_find_prefix(t, equivalentes[i][1]);

	/* Sin equivalencia directa, se busca por el prefijo del tipo: "wall5x"
	 * acaba pareciendose a "wall". */
	{
		static const char *tipos[] = {"wall",  "floor", "ceil", "metal", "wood",
		                              "rock",  "brick", "trim", "comp",  "sky",
		                              "door",  "step",  "stone", "panel", "grate",
		                              NULL};
		char base[17];
		size_t j;
		snprintf(base, sizeof(base), "%s", nombre);
		for (j = 0; tipos[j]; j++) {
			size_t lt = strlen(tipos[j]);
			if (strncasecmp(base, tipos[j], lt) == 0)
				return texlib_find_prefix(t, tipos[j]);
		}
	}
	return NULL;
}

const char *texlib_origen(texlib_t *t)
{
	return t ? t->origen : "(ninguna)";
}

const unsigned char *texlib_paleta(texlib_t *t)
{
	return (t && t->tiene_paleta) ? t->paleta : NULL;
}

int tex_es_especial(const char *nombre)
{
	if (!nombre || !nombre[0])
		return 0;
	/* '*' es el cielo y '+'/'-' los liquidos. El motor los carga como imagen
	 * suelta, no desde el lump TEXTURES, asi que meterlos ahi no hace nada y
	 * ademas le deja una textura vacia que pinta de gris. */
	return nombre[0] == '*' || nombre[0] == '+' || nombre[0] == '-';
}

/* Lee un fichero entero. */
static int leer_fichero(const char *ruta, unsigned char **datos, size_t *tam)
{
	FILE *f = fopen(ruta, "rb");
	long sz;

	if (!f)
		return 0;
	fseek(f, 0, SEEK_END);
	sz = ftell(f);
	rewind(f);
	if (sz <= 0) {
		fclose(f);
		return 0;
	}
	*datos = malloc((size_t)sz);
	if (!*datos) {
		fclose(f);
		return 0;
	}
	if (fread(*datos, 1, (size_t)sz, f) != (size_t)sz) {
		free(*datos);
		*datos = NULL;
		fclose(f);
		return 0;
	}
	*tam = (size_t)sz;
	fclose(f);
	return 1;
}

static void lib_toma_bloque(texlib_t *t, unsigned char *b)
{
	t->bloques = realloc(t->bloques, sizeof(unsigned char *) * (size_t)(t->nbloques + 1));
	if (t->bloques)
		t->bloques[t->nbloques++] = b;
}

texlib_t *texlib_open(char *const *rutas)
{
	texlib_t *t = calloc(1, sizeof(texlib_t));
	int i, de_bsp = 0, de_wad = 0;

	if (!t)
		return NULL;

	for (i = 0; rutas[i]; i++) {
		char ruta[512];

		/* 1. La paleta, que es un .lmp suelto o va dentro del pak. */
		if (!t->tiene_paleta) {
			FILE *f;
			snprintf(ruta, sizeof(ruta), "%s/gfx/palette.lmp", rutas[i]);
			f = fopen(ruta, "rb");
			if (f) {
				if (fread(t->paleta, 1, 768, f) == 768)
					t->tiene_paleta = 1;
				fclose(f);
			} else {
				/* En el pak. OJO: pak_lee() quiere la ruta del PAK, no la
				 * del .lmp que se acaba de intentar abrir. */
				int pak;
				for (pak = 0; pak < 2 && !t->tiene_paleta; pak++) {
					unsigned char *pd = NULL;
					size_t pt = 0;
					snprintf(ruta, sizeof(ruta), "%s/pak%d.pak", rutas[i], pak);
					if (pak_lee(ruta, "gfx/palette.lmp", &pd, &pt) && pt >= 768) {
						memcpy(t->paleta, pd, 768);
						t->tiene_paleta = 1;
						free(pd);
					}
				}
			}
		}

		/* 2. Un WAD suelto o dentro del pak, por si el juego lo trae. */
		{
			unsigned char *wad = NULL;
			size_t wt = 0;
			int wad_encontrado = 0;
			snprintf(ruta, sizeof(ruta), "%s/gfx.wad", rutas[i]);
			{
				FILE *f = fopen(ruta, "rb");
				if (f) {
					fclose(f);
					wad_encontrado = pak_lee(ruta, "gfx.wad", &wad, &wt) ||
					                 leer_fichero(ruta, &wad, &wt);
				}
			}
			if (wad_encontrado) {
				int antes = t->n;
				cosecha_wad(t, wad, wt);
				de_wad += t->n - antes;
				lib_toma_bloque(t, wad);
			} else {
				int pak;
				for (pak = 0; pak < 2 && !wad_encontrado; pak++) {
					snprintf(ruta, sizeof(ruta), "%s/pak%d.pak", rutas[i], pak);
					if (pak_lee(ruta, "gfx.wad", &wad, &wt)) {
						cosecha_wad(t, wad, wt);
						de_wad += t->n;
						lib_toma_bloque(t, wad);
						wad_encontrado = 1;
					}
				}
			}
		}

		/* 3. Y las texturas de mundo, que en LibreQuake van embebidas en los
		 * .bsp. Es la unica fuente de texturas de verdad del juego.
		 *
		 * OJO: pak_lee() espera la ruta del PAK, no un directorio ni la ruta
		 * de otro fichero. Pasarle el "ruta" que dejaba el paso anterior (que
		 * acababa siendo ".../gfx.wad") hacia que no existiera ningun PAK y la
		 * biblioteca salia vacia sin decir nada. */
		if (t->n < SEMILLAS_MINIMAS) {
			int pak;
			for (pak = 0; pak < 2; pak++) {
				int s;
				snprintf(ruta, sizeof(ruta), "%s/pak%d.pak", rutas[i], pak);
				for (s = 0; semillas[s]; s++) {
					unsigned char *bsp = NULL;
					size_t bt = 0;
					if (!pak_lee(ruta, semillas[s], &bsp, &bt))
						continue;
					de_bsp += cosecha_bsp(t, bsp, bt);
					lib_toma_bloque(t, bsp);
					if (t->n >= SEMILLAS_MINIMAS)
						break;
				}
				if (t->n >= SEMILLAS_MINIMAS)
					break;
			}
		}
	}

	snprintf(t->origen, sizeof(t->origen), "%d del wad, %d de los .bsp", de_wad,
	         de_bsp);
	return t;
}

texlib_t *texlib_open_juego(void)
{
	/* DIREKT_GAMEDIR va primero para poder probar contra otro juego sin tocar
	 * el codigo. */
	const char *gd = getenv("DIREKT_GAMEDIR");
	char *rutas[4];
	int n = 0;

	if (gd)
		rutas[n++] = (char *)gd;
	rutas[n++] = (char *)"build/lq/full/id1";
	rutas[n++] = (char *)".";
	rutas[n] = NULL;
	return texlib_open(rutas);
}

void texlib_close(texlib_t *t)
{
	int i;
	if (!t)
		return;
	/* Los pixeles de cada textura apuntan dentro de uno de estos bloques, asi
	 * que se sueltan aqui y no uno por uno. */
	for (i = 0; i < t->nbloques; i++)
		free(t->bloques[i]);
	free(t->bloques);
	free(t->v);
	free(t);
}
