/* direkt-bsp -- escritura del .bsp y su validacion.
 *
 * GPL-2.0, ver LICENSE en la raiz del repositorio.
 *
 * Escribe la version 29. Los layouts estan en el bspfile.h del motor y son
 * TODOS little-endian:
 *
 *   dheader_t   124 B  int32 version + 15 lumps de {int32 fileofs, int32 filelen}
 *   dplane_t     20 B  float32 normal[3], float32 dist, int32 type
 *   dvertex_t    12 B  float32 point[3]
 *   dsedge_t      4 B  uint16 v[2]
 *   surfedge      4 B  int32 (>=0 indice de edge, <0 vertice en -v-1)
 *   texinfo_t    40 B  float32 vecs[2][4], int32 miptex, int32 flags
 *   dsface_t     20 B  int16 planenum, int16 side, int32 firstedge,
 *                       int16 numedges, int16 texinfo, byte styles[4], int32 lightofs
 *   dsnode_t     24 B  int32 planenum, int16 children[2], int16 mins[3], int16 maxs[3],
 *                       uint16 firstface, uint16 numfaces
 *   dsclipnode_t  8 B  int32 planenum, int16 children[2]
 *   dsleaf_t     28 B  int32 contents, int32 visofs, int16 mins[3], int16 maxs[3],
 *                       uint16 firstmarksurface, uint16 nummarksurfaces, byte ambient[4]
 *   dmodel_t     64 B  float32 mins[3], maxs[3], origin[3], int32 headnode[4],
 *                       int32 visleafs, firstface, numfaces
 *
 * Ojo con dos cosas:
 *
 *  - dsface_t.planenum es int16, asi que una cara solo puede referenciar planos
 *    0..32766. Con mas planos hay que partir la lista.
 *  - El motor no comprueba fileofs+filelen. Por eso check_bsp() relee lo escrito
 *    y verifica que todo lump cae dentro del fichero: es la unica red entre un
 *    bug aqui y una lectura arbitraria de memoria en el motor.
 */

#define _GNU_SOURCE
#include "direktbsp.h"

#include "tex.h"

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define BSPVERSION 29

#define LUMP_ENTITIES 0
#define LUMP_PLANES 1
#define LUMP_TEXTURES 2
#define LUMP_VERTEXES 3
#define LUMP_VISIBILITY 4
#define LUMP_NODES 5
#define LUMP_TEXINFO 6
#define LUMP_FACES 7
#define LUMP_LIGHTING 8
#define LUMP_CLIPNODES 9
#define LUMP_LEAFS 10
#define LUMP_MARKSURFACES 11
#define LUMP_EDGES 12
#define LUMP_SURFEDGES 13
#define LUMP_MODELS 14
#define HEADER_LUMPS 15

/* Limites del motor. Pasarse de alguno es un error o un aviso suyo, y mejor que
 * lo diga el compilador con un mensaje util. */
#define MAX_PLANES 32766 /* dsface_t.planenum es int16 */
#define MAX_FACES 32767
#define MAX_NODES 32767
#define MAX_LEAFS 32767
#define MAX_MARKSURFACES 65535 /* uint16 en dsleaf_t */
#define MAX_EXTS 2000          /* el motor aborta si un extents pasa de esto */

/* ------------------------------------------------------------------ buffer */

typedef struct {
	unsigned char *data;
	int len;
	int cap;
} buf_t;

static void buf_need(buf_t *b, int n)
{
	if (b->len + n <= b->cap)
		return;
	while (b->cap < b->len + n)
		b->cap = b->cap ? b->cap * 2 : 4096;
	b->data = xrealloc(b->data, (size_t)b->cap);
}

static void buf_byte(buf_t *b, unsigned v)
{
	buf_need(b, 1);
	b->data[b->len++] = (unsigned char)(v & 0xff);
}

static void buf_short(buf_t *b, int v)
{
	buf_need(b, 2);
	b->data[b->len++] = (unsigned char)((unsigned)v & 0xff);
	b->data[b->len++] = (unsigned char)(((unsigned)v >> 8) & 0xff);
}

static void buf_int(buf_t *b, int v)
{
	buf_need(b, 4);
	b->data[b->len++] = (unsigned char)((unsigned)v & 0xff);
	b->data[b->len++] = (unsigned char)(((unsigned)v >> 8) & 0xff);
	b->data[b->len++] = (unsigned char)(((unsigned)v >> 16) & 0xff);
	b->data[b->len++] = (unsigned char)(((unsigned)v >> 24) & 0xff);
}

/* Pone un int32 little-endian en una posicion ya reservada. Se usa para los
 * offsets del lump TEXTURES, que se escriben a cero y se rellenan cuando ya se
 * sabe donde ha quedado cada miptex. */
static void buf_pone_int(buf_t *b, int pos, int v)
{
	unsigned char *p = b->data + pos;
	p[0] = (unsigned char)(v & 0xff);
	p[1] = (unsigned char)((v >> 8) & 0xff);
	p[2] = (unsigned char)((v >> 16) & 0xff);
	p[3] = (unsigned char)((v >> 24) & 0xff);
}

static void buf_float(buf_t *b, float f)
{
	int v;
	memcpy(&v, &f, 4);
	buf_int(b, v);
}

/* Anade texto al final del lump de entidades. OJO: NO se copia el terminador
 * nulo, porque COM_Parse lo toma por fin de cadena y el motor se comeria el
 * resto de la entidad. El terminador lo pone buf_text, y solo uno. */
static void buf_str(buf_t *b, const char *s)
{
	size_t n = strlen(s);
	buf_need(b, (int)n);
	memcpy(b->data + b->len, s, n);
	b->len += (int)n;
}

/* ------------------------------------------------------------------ planos */

static int plane_type(vec3_t n)
{
	if (n[0] == 1.0f || n[0] == -1.0f)
		return 0; /* PLANE_X */
	if (n[1] == 1.0f || n[1] == -1.0f)
		return 1; /* PLANE_Y */
	if (n[2] == 1.0f || n[2] == -1.0f)
		return 2; /* PLANE_Z */
	if (n[0] == 0.0f)
		return 3; /* PLANE_ANYX */
	if (n[1] == 0.0f)
		return 4; /* PLANE_ANYZ */
	return 5;     /* PLANE_ANYY */
}

/* Los extents de la cara: cuanto abarca en u y en v. El motor aborta si pasan
 * de 2000, asi que se calculan de verdad en vez de poner un numero. */
static void face_extents(texinfo_t *ti, winding_t *w, int *extents)
{
	int i, us, ue, vs, ve;
	extents[0] = extents[1] = 0;

	for (i = 0; i < w->numpoints; i++) {
		us = (int)(VectorDot(w->points[i], ti->vecs[0]));
		ue = (int)(VectorDot(w->points[i], ti->vecs[0]));
		vs = (int)(VectorDot(w->points[i], ti->vecs[1]));
		ve = (int)(VectorDot(w->points[i], ti->vecs[1]));
		if (i == 0) {
			extents[0] = us;
			extents[1] = vs;
		} else {
			if (us < extents[0]) extents[0] = us;
			if (ue > extents[0]) extents[0] = ue;
			if (vs < extents[1]) extents[1] = vs;
			if (ve > extents[1]) extents[1] = ve;
		}
	}
	extents[0] = (extents[0] + 1) / 2;
	extents[1] = (extents[1] + 1) / 2;
	if (extents[0] < 1) extents[0] = 1;
	if (extents[1] < 1) extents[1] = 1;
}

/* ------------------------------------------------------------------ geometria */

typedef struct {
	float v[3];
} vtx_t;

static vtx_t *vertexes;
static int numvertexes;
static int *faceverts; /* numvertexes por cara, seguidos de sus indices */
static int *facevert_off;

typedef struct {
	unsigned short v[2];
} edge_t;

static edge_t *edges;
static int numedges; /* el indice 0 no se usa: los negativos son vertices sueltos */

static int *surfedges;
static int numsurfedges;

static int find_or_add_vertex(vec3_t p)
{
	int i;
	for (i = 0; i < numvertexes; i++) {
		if (fabsf(vertexes[i].v[0] - p[0]) < 0.01f &&
		    fabsf(vertexes[i].v[1] - p[1]) < 0.01f &&
		    fabsf(vertexes[i].v[2] - p[2]) < 0.01f)
			return i;
	}
	vertexes = xrealloc(vertexes, sizeof(vtx_t) * (size_t)(numvertexes + 1));
	VectorCopy(p, vertexes[numvertexes].v);
	return numvertexes++;
}

/* Devuelve el valor de surfedge para la arista que empieza en el vertice v0 y
 * acaba en v1.
 *
 * El motor lee un surfedge e asi: si e >= 0, el vertice inicial de la arista es
 * edges[e].v[0]; si e < 0, es edges[-e].v[1]. O sea, el surfedge dice de donde
 * arranca la arista, no en que sentido se recorre.
 *
 * Por eso al reves hay que devolver -i y no el complemento a bits: ~i es -i-1
 * y el motor iria a buscar la edge i+1. */
static int find_or_add_edge(int v0, int v1)
{
	int i;
	for (i = 1; i < numedges; i++) {
		if (edges[i].v[0] == v0 && edges[i].v[1] == v1)
			return i;
		if (edges[i].v[0] == v1 && edges[i].v[1] == v0)
			return -i;
	}
	edges = xrealloc(edges, sizeof(edge_t) * (size_t)(numedges + 1));
	edges[numedges].v[0] = (unsigned short)v0;
	edges[numedges].v[1] = (unsigned short)v1;
	return numedges++;
}

static void build_geometry(bsp_t *bsp)
{
	int f, i;

	vertexes = NULL;
	numvertexes = 0;
	/* El indice 0 de edges se reserva. El motor no lo necesita, pero es la
	 * convencion de Quake y evita el caso raro de un surfedge 0. */
	edges = xcalloc(1, sizeof(edge_t));
	numedges = 1;
	surfedges = NULL;
	numsurfedges = 0;

	facevert_off = xmalloc(sizeof(int) * (size_t)(bsp->numsurfs + 1));
	faceverts = NULL;
	{
		int total = 0;
		for (f = 0; f < bsp->numsurfs; f++)
			total += bsp->surfs[f].winding->numpoints;
		faceverts = xmalloc(sizeof(int) * (size_t)(total ? total : 1));
	}

	/* Los indices de vertice de todas las caras van en un solo bloque, con
	 * facevert_off[f] diciendo donde empieza el de la cara f. */
	{
		int base = 0;
		for (f = 0; f < bsp->numsurfs; f++) {
			winding_t *w = bsp->surfs[f].winding;
			facevert_off[f] = base;
			for (i = 0; i < w->numpoints; i++)
				faceverts[base + i] = find_or_add_vertex(w->points[i]);
			base += w->numpoints;
		}
	}

	for (f = 0; f < bsp->numsurfs; f++) {
		winding_t *w = bsp->surfs[f].winding;
		int n = w->numpoints;
		/* El bobinado va AL REVES, y no es un detalle: es lo que espera el
		 * motor.
		 *
		 * En un .bsp de verdad, las caras que se ven tienen el bobinado en
		 * espejo respecto a su plano. Medido sobre start.bsp de LibreQuake: las
		 * 529 caras que miran al espectador tienen todas el bobinado opuesto
		 * al plano efectivo (el motor voltea el plano de las caras con side=1,
		 * y el sentido se sigue manteniendo). Y con el bobinado en el mismo
		 * sentido que el plano, como se hacia antes, el motor descarta
		 * exactamente esas caras: el test de cara trasera las aprueba, se
		 * escriben sus indices al buffer, y al rasterizar salen del lado
		 * equivocado y no se ve NADA del mundo.
		 *
		 * Por eso se recorren los vertices al reves. */
		for (i = 0; i < n; i++) {
			int v0 = faceverts[facevert_off[f] + ((n - i) % n)];
			int v1 = faceverts[facevert_off[f] + ((n - 1 - i + n) % n)];
			int e = find_or_add_edge(v0, v1);
			surfedges = xrealloc(surfedges, sizeof(int) * (size_t)(numsurfedges + 1));
			surfedges[numsurfedges++] = e;
		}
	}
}

/* ------------------------------------------------------------------ entidades */

static char *build_entities(map_t *map, int *outlen)
{
	buf_t b;
	entity_t *e;
	int i;

	memset(&b, 0, sizeof(b));

	for (e = map->entities; e; e = e->next) {
		buf_str(&b, "{\n");
		for (i = 0; i < e->numpairs; i++) {
			if (strcmp(e->pairs[i].key, "model") == 0)
				continue; /* el numero de submodelo lo pone el compilador */
			buf_str(&b, "\"");
			buf_str(&b, e->pairs[i].key);
			buf_str(&b, "\" \"");
			buf_str(&b, e->pairs[i].value);
			buf_str(&b, "\"\n");
		}
		buf_str(&b, "}\n");
	}

	/* Un unico terminador nulo, que es como el motor espera encontrar el fin. */
	buf_need(&b, 1);
	b.data[b.len] = 0;
	b.len++;

	*outlen = b.len;
	return (char *)b.data;
}

/* ------------------------------------------------------------------ escritura */

/* Las texturas del lump TEXTURES, ya elegidas y deduplicadas.
 *
 * Se calcula ANTES de escribir nada porque hay que reindexar los texinfo, y el
 * lump TEXINFO se escribe antes que el TEXTURES. Con una sola ranura por
 * nombre, seis caras con la misma textura no son seis copias de 16 KB, y el
 * motor ademas cuenta texturas DISTINTAS para agrupar el dibujado. */
static const miptex_t **tex_lista;
static int tex_cuantas;

static void preparar_texturas(bsp_t *bsp)
{
	int i, k, ntex;
	int *slot;

	free(tex_lista);
	tex_lista = NULL;
	tex_cuantas = 0;
	if (!bsp->tex) {
		/* Sin biblioteca, todos los texinfo se quedan sin textura y el motor
		 * usara su notexture de reserva. */
		for (i = 0; i < bsp->numtexinfos; i++)
			bsp->texinfos[i].miptex = 0;
		return;
	}

	ntex = bsp->numtexnames;
	tex_lista = xmalloc(sizeof(miptex_t *) * (size_t)(ntex + 1));
	slot = xmalloc(sizeof(int) * (size_t)(ntex + 1));
	for (i = 0; i <= ntex; i++)
		slot[i] = -1;

	for (i = 0; i < bsp->numtexinfos; i++) {
		int mi = bsp->texinfos[i].miptex;
		const char *nombre = (mi >= 0 && mi < ntex) ? bsp->texnames[mi] : NULL;
		const miptex_t *m;

		if (!nombre || tex_es_especial(nombre))
			continue;
		if (slot[mi] >= 0)
			continue;
		m = texlib_sugerir(bsp->tex, nombre);
		if (!m)
			continue;
		for (k = 0; k < tex_cuantas; k++)
			if (tex_lista[k] == m) {
				slot[mi] = k;
				break;
			}
		if (k == tex_cuantas) {
			slot[mi] = tex_cuantas;
			tex_lista[tex_cuantas++] = m;
		}
	}
	for (i = 0; i < bsp->numtexinfos; i++) {
		int mi = bsp->texinfos[i].miptex;
		bsp->texinfos[i].miptex = (mi >= 0 && mi < ntex) ? slot[mi] : 0;
	}
	free(slot);
}

static int num_texturas(bsp_t *bsp)
{
	(void)bsp;
	return tex_cuantas;
}

static const miptex_t *textura_de(bsp_t *bsp, int i)
{
	(void)bsp;
	return (i >= 0 && i < tex_cuantas) ? tex_lista[i] : NULL;
}

int write_bsp(const char *filename, bsp_t *bsp, map_t *map)
{
	buf_t lumps[HEADER_LUMPS];
	int lumpofs[HEADER_LUMPS], lumplen[HEADER_LUMPS];
	buf_t out;
	int i, f, l;
	int entlen;
	char *enttext;
	int *markbuf;
	int nmarks = 0;
	FILE *fp;

	memset(lumps, 0, sizeof(lumps));

	/* Primero las texturas, porque reindexan los texinfo y el lump TEXINFO se
	 * escribe antes que el TEXTURES. */
	preparar_texturas(bsp);

	if (bsp->numplanes > MAX_PLANES)
		error("el mapa tiene %d planos y dsface_t.planenum es int16; el motor "
		      "solo admite %d. Habria que partir la lista de planos.",
		      bsp->numplanes, MAX_PLANES);
	if (bsp->numsurfs > MAX_FACES)
		error("el mapa tiene %d caras y el motor avisa a partir de %d",
		      bsp->numsurfs, MAX_FACES);
	if (bsp->numnodes > MAX_NODES)
		error("el mapa tiene %d nodos y el motor avisa a partir de %d",
		      bsp->numnodes, MAX_NODES);
	if (bsp->numleafs > MAX_LEAFS)
		error("el mapa tiene %d hojas y el motor aborta a partir de %d",
		      bsp->numleafs, MAX_LEAFS);

	build_geometry(bsp);

	/* --- planos --- */
	for (i = 0; i < bsp->numplanes; i++) {
		buf_float(&lumps[LUMP_PLANES], bsp->planes[i].normal[0]);
		buf_float(&lumps[LUMP_PLANES], bsp->planes[i].normal[1]);
		buf_float(&lumps[LUMP_PLANES], bsp->planes[i].normal[2]);
		buf_float(&lumps[LUMP_PLANES], bsp->planes[i].dist);
		buf_int(&lumps[LUMP_PLANES], plane_type(bsp->planes[i].normal));
	}

	/* --- vertices --- */
	for (i = 0; i < numvertexes; i++) {
		buf_float(&lumps[LUMP_VERTEXES], vertexes[i].v[0]);
		buf_float(&lumps[LUMP_VERTEXES], vertexes[i].v[1]);
		buf_float(&lumps[LUMP_VERTEXES], vertexes[i].v[2]);
	}

	/* --- nodos --- */
	for (i = 0; i < bsp->numnodes; i++) {
		node_t *nd = &bsp->nodes[i];

		int j;
		buf_int(&lumps[LUMP_NODES], nd->planenum);
		for (j = 0; j < 2; j++) {
			int c = nd->children[j];
			if (c >= 0) {
				buf_short(&lumps[LUMP_NODES], c);
			} else {
				/* El motor lee el hijo como unsigned short y calcula
				 * 65535 - p para sacar el indice de hoja. Hay que
				 * escribir 65535 - hoja entonces, no -(hoja+1): con la
				 * hoja 0 eso da 65535, que el motor reconoce como la
				 * solida. */
				int leaf = -(c + 1);
				buf_short(&lumps[LUMP_NODES], 65535 - leaf);
			}
		}
		for (j = 0; j < 3; j++)
			buf_short(&lumps[LUMP_NODES], 0);
		for (j = 0; j < 3; j++)
			buf_short(&lumps[LUMP_NODES], 0);
		/* El render dibuja por hojas, asi que el nodo no lleva rango de caras.
		 * firstface/numfaces a 0 es lo que hacen los compiladores que no
		 * reordenan las caras por subarbol. */
		buf_short(&lumps[LUMP_NODES], 0);
		buf_short(&lumps[LUMP_NODES], 0);
	}

	/* --- texinfos --- */
	for (i = 0; i < bsp->numtexinfos; i++) {
		texinfo_t *ti = &bsp->texinfos[i];
		int j;
		for (j = 0; j < 4; j++)
			buf_float(&lumps[LUMP_TEXINFO], ti->vecs[0][j]);
		for (j = 0; j < 4; j++)
			buf_float(&lumps[LUMP_TEXINFO], ti->vecs[1][j]);
		/* Indice de la textura DENTRO del lump TEXTURES.
		 *
		 * OJO: esto no puede ser 0. El motor cuenta cuantas texturas
		 * DISTINTAS usa el mapa para agrupar el dibujado por textura
		 * (Mod_FindUsedTextures cuenta bits de "en uso", no superficies), y con
		 * todos los texinfo apuntando a la 0 el mapa entero se dibujaba con
		 * una sola textura. Ademas el motor aborta al cargar si el indice se
		 * sale de rango, asi que tiene que ser de verdad el miptex. */
		buf_int(&lumps[LUMP_TEXINFO], ti->miptex);
		buf_int(&lumps[LUMP_TEXINFO], ti->flags);
	}

	/* --- lump LIGHTING ---
	 *
	 * Los oclusores y los limites los saca generar_luces del propio bsp, de
	 * las brushes partidas que cuelgan de las hojas.
	 *
	 * Antes se le pasaba la lista de brushes del mapa, y eso ya no existe
	 * aqui: compile_map la suelta al construir el arbol (a partir de ahi el
	 * dueno del mapa son las hojas), asi que el calculo de luz se quedaba
	 * sin ningun oclusor y con unos limites de repuesto de 0..64. */
	{
		unsigned char *luces = NULL;
		int nluces = 0;

		nluces = generar_luces(bsp, &luces, &nluces);
		if (luces && nluces > 0) {
			buf_need(&lumps[LUMP_LIGHTING], nluces);
			memcpy(lumps[LUMP_LIGHTING].data, luces, (size_t)nluces);
			lumps[LUMP_LIGHTING].len = nluces;
		} else {
			fprintf(stderr, "direkt-bsp: aviso, el mapa se queda sin luz; "
			                "el motor lo dibujara con la textura a pleno\n");
		}
		free(luces);
	}

	/* --- caras --- */
	{
		int se = 0;
		for (f = 0; f < bsp->numsurfs; f++) {
			texinfo_t *ti = &bsp->texinfos[bsp->surfs[f].texinfo];
			int extents[2];
			int n = bsp->surfs[f].winding->numpoints;

			face_extents(ti, bsp->surfs[f].winding, extents);
			if (extents[0] > MAX_EXTS || extents[1] > MAX_EXTS)
				error("cara %d: extents %dx%d y el motor aborta a partir "
				      "de %d", f, extents[0], extents[1], MAX_EXTS);

			buf_short(&lumps[LUMP_FACES], bsp->surfs[f].planenum);
			buf_short(&lumps[LUMP_FACES], bsp->surfs[f].side);
			buf_int(&lumps[LUMP_FACES], se);
			buf_short(&lumps[LUMP_FACES], n);
			buf_short(&lumps[LUMP_FACES], bsp->surfs[f].texinfo);
			/* dsface_t.styles[4]: el primero es el estilo de luz de la cara
			 * (0 = la normal) y los demas son 255 = "esta capa no se usa".
			 *
			 * OJO: 255 no es decorativo. El motor cuenta las capas mirando
			 * styles[1] y styles[2] (GL_NumLightmapTaps):
			 *
			 *     if (styles[1] == 255) return 1;
			 *     if (styles[2] == 255) return 2;
			 *     return 3;
			 *
			 * Con styles = {0,0,0,255} ninguna de las dos comparaciones
			 * acierta y el motor se cree que la cara tiene TRES capas de luz.
			 * Reserva thrice el sitio en el atlas y el fragmento suma las
			 * capas 1 y 2, que estan vacias: la superficie sale negra y, con
			 * el fondo tambien negro, no se ve nada. */
			buf_byte(&lumps[LUMP_FACES], 0);
			buf_byte(&lumps[LUMP_FACES], 255);
			buf_byte(&lumps[LUMP_FACES], 255);
			buf_byte(&lumps[LUMP_FACES], 255);
			/* lightsofs: indice de la primera muestra de esta cara en el lump
			 * LIGHTING. El motor lo usa tal cual (`samples = lightdata +
			 * lightsofs * 3`) y no lo comprueba, asi que si se queda a 0
			 * todas las caras leerian las muestras de la primera. */
			buf_int(&lumps[LUMP_FACES], bsp->surfs[f].lightsofs);
			se += n;
		}
	}

	/* --- edges y surfedges --- */
	for (i = 0; i < numedges; i++) {
		buf_short(&lumps[LUMP_EDGES], edges[i].v[0]);
		buf_short(&lumps[LUMP_EDGES], edges[i].v[1]);
	}
	for (i = 0; i < numsurfedges; i++)
		buf_int(&lumps[LUMP_SURFEDGES], surfedges[i]);

	/* --- clipnodes ---
	 * dsclipnode_t son 8 bytes: int32 planenum y dos int16. El motor comprueba
	 * "num < 0" para saber que es una hoja, y entonces el valor es el contents
	 * DIRECTO: CONTENTS_SOLID (-2) es solido y CONTENTS_EMPTY (-1) vacio.
	 * children[0] es el lado positivo del plano (t1 >= 0) y children[1] el
	 * negativo. Al reves el mapa colisiona espejado, y como el motor no lo
	 * comprueba, el unico sintoma es que el jugador atraviesa el suelo. */
	for (i = 0; i < bsp->numclipnodes; i++) {
		int j;
		buf_int(&lumps[LUMP_CLIPNODES], bsp->clipnodes[i].planenum);
		for (j = 0; j < 2; j++) {
			int c = bsp->clipnodes[i].children[j];
			if (c < 0) {
				/* Hoja: el contents tal cual, que ya es negativo. */
				if (c != CONTENTS_SOLID && c != CONTENTS_EMPTY)
					error("clipnode %d hijo %d: hoja con contents %d, que no es "
					      "ni SOLID ni EMPTY", i, j, c);
				buf_short(&lumps[LUMP_CLIPNODES], c);
			} else {
				if (c >= bsp->numclipnodes)
					error("clipnode %d hijo %d: indice %d fuera de [0,%d)", i, j, c,
					      bsp->numclipnodes);
				buf_short(&lumps[LUMP_CLIPNODES], c);
			}
		}
	}

	/* --- marcas de superficie, por hoja --- */
	markbuf = xmalloc(sizeof(int) * (size_t)(bsp->numsurfs + 1));
	for (l = 0; l < bsp->numleafs; l++) {
		bsp->leafs[l].firstmarksurface = nmarks;
		bsp->leafs[l].nummarksurfaces = 0;
		for (f = 0; f < bsp->numsurfs; f++) {
			if (bsp->surfs[f].leaf != l)
				continue;
			markbuf[nmarks++] = f;
			bsp->leafs[l].nummarksurfaces++;
		}
	}
	if (nmarks > MAX_MARKSURFACES)
		error("el mapa tiene %d marcas de superficie y dsleaf_t las guarda en "
		      "un uint16; el tope es %d", nmarks, MAX_MARKSURFACES);
	for (i = 0; i < nmarks; i++)
		buf_short(&lumps[LUMP_MARKSURFACES], markbuf[i]);
	free(markbuf);

	/* --- hojas --- */
	for (l = 0; l < bsp->numleafs; l++) {
		leaf_t *lf = &bsp->leafs[l];
		int j;
		buf_int(&lumps[LUMP_LEAFS], lf->contents);
		/* -1 en todas: el lump VIS va vacio y el motor lo lee como "todo
		 * visible". Con visdata nulo, un visofs >= 0 seria NULL+algo. */
		buf_int(&lumps[LUMP_LEAFS], -1);
		for (j = 0; j < 3; j++)
			buf_short(&lumps[LUMP_LEAFS], lf->mins[j]);
		for (j = 0; j < 3; j++)
			buf_short(&lumps[LUMP_LEAFS], lf->maxs[j]);
		buf_short(&lumps[LUMP_LEAFS], lf->firstmarksurface);
		buf_short(&lumps[LUMP_LEAFS], lf->nummarksurfaces);
		for (j = 0; j < 4; j++)
			buf_byte(&lumps[LUMP_LEAFS], 0);
	}

	/* Una hoja de sobra, vacia.
	 *
	 * El motor arma el PVS recorriendo `leaf = leafs[i + 1]` con
	 * `i < numleafs`, y `numleafs` sale de dmodel.visleafs. O sea que lee las
	 * hojas 1..visleafs, y hace falta que la hoja visleafs exista. Con
	 * visleafs igual al numero de hojas, el bucle se sale una del final del
	 * arreglo: lee una mleaf_t de la memoria de al lado y usa su
	 * nummarksurfaces para recorrer marcas de superficie, con lo que puede
	 * escribir fuera del buffer de marcas y dejar el marcado sin sentido.
	 *
	 * Por eso los compiladores de verdad ponen visleafs = numleafs - 1 y
	 * ademas dejan hojas de sobra. Aqui se deja visleafs = numleafs y se anade esta
	 * hoja de relleno, que es lo mismo y no obliga a contar quantas hojas
	 * estan realmente referenciadas. */
	{
		int j;
		buf_int(&lumps[LUMP_LEAFS], CONTENTS_SOLID);
		buf_int(&lumps[LUMP_LEAFS], -1);
		for (j = 0; j < 3; j++)
			buf_short(&lumps[LUMP_LEAFS], 0);
		for (j = 0; j < 3; j++)
			buf_short(&lumps[LUMP_LEAFS], 0);
		buf_short(&lumps[LUMP_LEAFS], 0);
		buf_short(&lumps[LUMP_LEAFS], 0);
		for (j = 0; j < 4; j++)
			buf_byte(&lumps[LUMP_LEAFS], 0);
	}

	/* --- submodelos --- */
	for (i = 0; i < bsp->numsubmodels; i++) {
		submodel_t *sm = &bsp->submodels[i];
		int j;
		for (j = 0; j < 3; j++)
			buf_float(&lumps[LUMP_MODELS], sm->mins[j]);
		for (j = 0; j < 3; j++)
			buf_float(&lumps[LUMP_MODELS], sm->maxs[j]);
		/* dmodel_t.origin no lo lee nadie. Se escribe 0, que es lo que hacen
		 * los compiladores, y la colocacion va en el origin de la entidad. */
		for (j = 0; j < 3; j++)
			buf_float(&lumps[LUMP_MODELS], 0.0f);
		for (j = 0; j < 4; j++)
			buf_int(&lumps[LUMP_MODELS], sm->headnode[j]);
		buf_int(&lumps[LUMP_MODELS], sm->visleafs);
		buf_int(&lumps[LUMP_MODELS], sm->firstface);
		buf_int(&lumps[LUMP_MODELS], sm->numfaces);
	}

	/* --- entidades --- */
	enttext = build_entities(map, &entlen);
	buf_need(&lumps[LUMP_ENTITIES], entlen);
	memcpy(lumps[LUMP_ENTITIES].data, enttext, (size_t)entlen);
	lumps[LUMP_ENTITIES].len = entlen;

	/* --- lump TEXTURES -------------------------------------------------
	 *
	 * Es `int nummiptex; int dataofs[nummiptex];` seguido de los miptex, y el
	 * offset de cada uno es RELATIVO al principio del lump: el motor hace
	 * `m = mod_base + l->fileofs` y luego `m + m->dataofs[i]`.
	 *
	 * De cada miptex solo hace falta el primer mip. El motor copia w*h bytes y
	 * se genera el resto de la cadena el solo (gl_model.c: "only copy the first
	 * mip, the rest are auto-generated").
	 */
	{
		int i, cab, num = num_texturas(bsp);
		/* Se reserva la cabecera con los offsets a cero y se van rellenando
		 * segun se va escribiendo cada miptex, porque el valor depende de lo
		 * que haya quedado antes. */
		buf_need(&lumps[LUMP_TEXTURES], 4 + num * 4);
		cab = lumps[LUMP_TEXTURES].len;
		buf_int(&lumps[LUMP_TEXTURES], num);
		for (i = 0; i < num; i++)
			buf_int(&lumps[LUMP_TEXTURES], 0);

		for (i = 0; i < num; i++) {
			const miptex_t *m = textura_de(bsp, i);
			char nombre[17];
			int j, pix;
			if (!m)
				continue;
			pix = m->width * m->height;
			memset(nombre, 0, sizeof(nombre));
			snprintf(nombre, sizeof(nombre), "%s", m->name);
			buf_pone_int(&lumps[LUMP_TEXTURES], cab + 4 + i * 4,
			             lumps[LUMP_TEXTURES].len - cab);
			for (j = 0; j < 16; j++)
				buf_byte(&lumps[LUMP_TEXTURES], (unsigned char)nombre[j]);
			buf_int(&lumps[LUMP_TEXTURES], m->width);
			buf_int(&lumps[LUMP_TEXTURES], m->height);
			for (j = 0; j < 4; j++)
				buf_int(&lumps[LUMP_TEXTURES], 0);
			buf_need(&lumps[LUMP_TEXTURES], pix);
			memcpy(lumps[LUMP_TEXTURES].data + lumps[LUMP_TEXTURES].len,
			       m->pixels, (size_t)pix);
			lumps[LUMP_TEXTURES].len += pix;
		}
	}

	/* --- cabecera: primero se calculan los desplazamientos, luego se escribe
	 * todo. El primer lump arranca en 124, que es el tamaño de la cabecera. --- */
	memset(&out, 0, sizeof(out));
	{
		int pos = 124;
		for (l = 0; l < HEADER_LUMPS; l++) {
			lumpofs[l] = lumps[l].len ? pos : 0;
			lumplen[l] = lumps[l].len;
			pos += lumps[l].len;
		}
		buf_int(&out, BSPVERSION);
		for (l = 0; l < HEADER_LUMPS; l++) {
			buf_int(&out, lumpofs[l]);
			buf_int(&out, lumplen[l]);
		}
		for (l = 0; l < HEADER_LUMPS; l++) {
			if (!lumps[l].len)
				continue;
			buf_need(&out, lumps[l].len);
			memcpy(out.data + out.len, lumps[l].data, (size_t)lumps[l].len);
			out.len += lumps[l].len;
		}
	}

	fp = fopen(filename, "wb");
	if (!fp)
		error("no se puede escribir %s", filename);
	if (fwrite(out.data, 1, (size_t)out.len, fp) != (size_t)out.len) {
		fclose(fp);
		error("escritura incompleta de %s", filename);
	}
	fclose(fp);

	for (l = 0; l < HEADER_LUMPS; l++)
		free(lumps[l].data);
	free(out.data);
	free(vertexes);
	free(edges);
	free(surfedges);
	free(faceverts);
	free(facevert_off);
	free(enttext);
	return 0;
}

/* ------------------------------------------------------------------ check_bsp
 *
 * Revisa el .bsp YA ESCRITO en disco, no la estructura en memoria. El motor no
 * valida ni un solo offset: si aqui hay un error, lo que sale es una lectura
 * arbitraria de memoria o un "bad node number" a mitad de una partida. Es la
 * unica red entre un bug del compilador y eso.
 */

typedef struct {
	unsigned char *d;
	size_t n;
} archivo_t;

static int leer_corto(archivo_t *f, size_t off, int *out)
{
	int16_t v;
	if (off + 2 > f->n)
		return 0;
	memcpy(&v, f->d + off, 2);
	*out = (int16_t)v;
	return 1;
}

/* firstface y numfaces de dsnode_t son uint16, no int32: leerlos como enteros
 * de 4 bytes se come el campo siguiente y da numeros absurdos. */
static int leer_corto_sin_signo(archivo_t *f, size_t off, int *out)
{
	uint16_t v;
	if (off + 2 > f->n)
		return 0;
	memcpy(&v, f->d + off, 2);
	*out = (int)v;
	return 1;
}

static int leer_entero(archivo_t *f, size_t off, int *out)
{
	int32_t v;
	if (off + 4 > f->n)
		return 0;
	memcpy(&v, f->d + off, 4);
	*out = (int32_t)v;
	return 1;
}

int check_bsp(const char *filename)
{
	archivo_t f;
	int problems = 0;
	int lumpofs[HEADER_LUMPS], lumplen[HEADER_LUMPS];
	int ver = 0, l, i, j;
	int nplanes, nclip, nmodels, nfaces, nleafs, nnodes, nsurf, nedges, nsegs;
	size_t total = 0;
	FILE *fp;
	long sz;

	#define MAL(...) do { fprintf(stderr, "check_bsp: " __VA_ARGS__); \
	                     fprintf(stderr, "\n"); problems++; } while (0)

	fp = fopen(filename, "rb");
	if (!fp) {
		fprintf(stderr, "check_bsp: no se puede abrir %s\n", filename);
		return 1;
	}
	fseek(fp, 0, SEEK_END);
	sz = ftell(fp);
	fseek(fp, 0, SEEK_SET);
	if (sz < 124) {
		fclose(fp);
		fprintf(stderr, "check_bsp: %s son solo %ld bytes, menos que la "
		                "cabecera\n", filename, sz);
		return 1;
	}
	f.d = xmalloc((size_t)sz);
	f.n = (size_t)sz;
	if (fread(f.d, 1, f.n, fp) != f.n) {
		fclose(fp);
		free(f.d);
		fprintf(stderr, "check_bsp: lectura incompleta de %s\n", filename);
		return 1;
	}
	fclose(fp);

	leer_entero(&f, 0, &ver);
	if (ver != BSPVERSION)
		MAL("la version es %d y deberia ser %d", ver, BSPVERSION);

	for (l = 0; l < HEADER_LUMPS; l++) {
		leer_entero(&f, (size_t)4 + 8 * (size_t)l, &lumpofs[l]);
		leer_entero(&f, (size_t)8 + 8 * (size_t)l, &lumplen[l]);
		if (lumplen[l] < 0) {
			MAL("el lump %d tiene tamano negativo (%d)", l, lumplen[l]);
			lumpofs[l] = 0;
			lumplen[l] = 0;
			continue;
		}
		if (lumplen[l] == 0)
			continue;
		if (lumpofs[l] < (int)sizeof(int32_t) + 8 * HEADER_LUMPS) {
			MAL("el lump %d empieza en %d, dentro de la cabecera", l, lumpofs[l]);
			continue;
		}
		if ((size_t)lumpofs[l] + (size_t)lumplen[l] > f.n) {
			MAL("el lump %d se sale del fichero (%d + %d > %lu)", l, lumpofs[l],
			    lumplen[l], (unsigned long)f.n);
			continue;
		}
		total += (size_t)lumplen[l];
	}

	/* Los lumps tendrian que ir seguidos desde el final de la cabecera, sin
	 * huecos ni solapes: es lo que leen a ciegas el resto de herramientas. */
	{
		int esperado = (int)sizeof(int32_t) + 8 * HEADER_LUMPS;
		for (l = 0; l < HEADER_LUMPS; l++) {
			if (!lumplen[l])
				continue;
			if (lumpofs[l] != esperado)
				MAL("el lump %d deberia empezar en %d y empieza en %d", l,
				    esperado, lumpofs[l]);
			esperado += lumplen[l];
		}
	}

	/* Tamano de cada lump multiplo del de su estructura. */
	if (lumplen[LUMP_PLANES] % 20)
		MAL("el lump de planos no es multiplo de 20 (%d)", lumplen[LUMP_PLANES]);
	if (lumplen[LUMP_CLIPNODES] % 8)
		MAL("el lump de clipnodes no es multiplo de 8 (%d)", lumplen[LUMP_CLIPNODES]);
	if (lumplen[LUMP_MODELS] % 64)
		MAL("el lump de modelos no es multiplo de 64 (%d)", lumplen[LUMP_MODELS]);
	if (lumplen[LUMP_FACES] % 20)
		MAL("el lump de caras no es multiplo de 20 (%d)", lumplen[LUMP_FACES]);

	nplanes = lumplen[LUMP_PLANES] / 20;
	nclip = lumplen[LUMP_CLIPNODES] / 8;
	nmodels = lumplen[LUMP_MODELS] / 64;
	nfaces = lumplen[LUMP_FACES] / 20;
	nleafs = lumplen[LUMP_LEAFS] / 28;
	nnodes = lumplen[LUMP_NODES] / 24;
	nsurf = lumplen[LUMP_TEXINFO] / 40;
	nedges = lumplen[LUMP_EDGES] / 4;
	nsegs = lumplen[LUMP_SURFEDGES] / 4;

	/* Planos: normal unitaria y tipo coherente con la normal. */
	for (i = 0; i < nplanes; i++) {
		float n[3], dist;
		int tipo = 0;
		size_t o = (size_t)lumpofs[LUMP_PLANES] + (size_t)i * 20;
		memcpy(n, f.d + o, 12);
		memcpy(&dist, f.d + o + 12, 4);
		leer_entero(&f, o + 16, &tipo);
		{
			float l2 = n[0] * n[0] + n[1] * n[1] + n[2] * n[2];
			if (l2 < 0.5f || l2 > 1.5f)
				MAL("el plano %d tiene una normal de modulo %.3f", i,
				    (double)sqrt(l2));
		}
		if (tipo < 0 || tipo > 5)
			MAL("el plano %d tiene tipo %d", i, tipo);
		(void)dist;
	}

	/* Clipnodes: planenum dentro, y los hijos nodos por debajo de numclipnodes
	 * o hojas en -1..-3. */
	for (i = 0; i < nclip; i++) {
		size_t o = (size_t)lumpofs[LUMP_CLIPNODES] + (size_t)i * 8;
		int pe = 0, c[2];
		c[0] = c[1] = 0;
		leer_entero(&f, o, &pe);
		leer_corto(&f, o + 4, &c[0]);
		leer_corto(&f, o + 6, &c[1]);
		if (pe < 0 || pe >= nplanes)
			MAL("el clipnode %d apunta al plano %d de %d", i, pe, nplanes);
		for (j = 0; j < 2; j++) {
			if (c[j] >= nclip)
				MAL("el clipnode %d, hijo %d, es %d y hay %d clipnodes", i, j,
				    c[j], nclip);
			else if (c[j] < -3)
				MAL("el clipnode %d, hijo %d, es una hoja rara: %d", i, j, c[j]);
		}
	}

	/* dmodel: headnode[0] debe existir y los otros cuatro tambien. */
	if (nmodels < 1) {
		MAL("no hay ningun dmodel");
	} else {
		int hn[4];
		memset(hn, 0, sizeof(hn));
		for (j = 0; j < 4; j++) {
			int o = (int)lumpofs[LUMP_MODELS] + 36 + 4 * j;
			leer_entero(&f, (size_t)o, &hn[j]);
			if (nclip > 0 && (hn[j] < 0 || hn[j] >= nclip))
				MAL("el dmodel headnode[%d] es %d y hay %d clipnodes", j, hn[j],
				    nclip);
		}
	}

	/* Nodos: planenum y caras dentro de rango. El motor no valida esto. */
	for (i = 0; i < nnodes; i++) {
		/* dsnode_t: planenum int32 en 0, children int16 en 4 y 6, mins int16
		 * en 8, maxs int16 en 14, firstface uint16 en 20, numfaces uint16
		 * en 22. */
		size_t o = (size_t)lumpofs[LUMP_NODES] + (size_t)i * 24;
		int pe = 0, first, num;
		first = num = 0;
		leer_entero(&f, o, &pe);
		leer_corto_sin_signo(&f, o + 20, &first);
		leer_corto_sin_signo(&f, o + 22, &num);
		if (pe < 0 || pe >= nplanes)
			MAL("el nodo %d apunta al plano %d de %d", i, pe, nplanes);
		if (first < 0 || num < 0 || first + num > nfaces)
			MAL("el nodo %d usa las caras %d..%d y hay %d", i, first,
			    first + num - 1, nfaces);
	}

	/* Alcanzabilidad de los nodos: si un nodo no se llega desde la raiz, sus
	 * caras se dibujan dos veces o nunca. */
	if (nnodes > 0) {
		unsigned char *visto = xmalloc((size_t)nnodes);
		int *pila = xmalloc(sizeof(int) * (size_t)nnodes);
		int np = 0, alcanzados = 0, raiz = 0;
		memset(visto, 0, (size_t)nnodes);
		pila[np++] = 0;
		visto[0] = 1;
		while (np > 0) {
			int cur = pila[--np];
				size_t o = (size_t)lumpofs[LUMP_NODES] + (size_t)cur * 24;
			alcanzados++;
			for (j = 0; j < 2; j++) {
				int hijo = -1;
				leer_corto(&f, o + 4 + 2 * (size_t)j, &hijo);
				if (hijo >= 0) {
					if (hijo >= nnodes)
						MAL("el nodo %d, hijo %d, es %d y hay %d nodos", cur,
						    j, hijo, nnodes);
					else if (visto[hijo]) {
						MAL("el nodo %d esta en un ciclo (visto otra vez "
						    "por el %d)",
						    hijo, cur);
					} else if (hijo == raiz) {
						MAL("el nodo %d se apunta a si mismo", cur);
					} else {
						visto[hijo] = 1;
						pila[np++] = hijo;
					}
				}
			}
		}
		for (i = 0; i < nnodes; i++)
			if (!visto[i]) {
				MAL("el nodo %d no se llega desde la raiz", i);
				break;
			}
		free(visto);
		free(pila);
	}

	/* Entidades: tiene que terminar en NUL y no tener NULes por dentro. */
	if (lumplen[LUMP_ENTITIES] > 0) {
		size_t o = (size_t)lumpofs[LUMP_ENTITIES];
		size_t l = (size_t)lumplen[LUMP_ENTITIES];
		size_t k;
		if (f.d[o + l - 1] != 0)
			MAL("el lump de entidades no termina en NUL");
		for (k = 0; k + 1 < l; k++)
			if (f.d[o + k] == 0)
				MAL("el lump de entidades tiene un NUL en la posicion %lu",
				    (unsigned long)k);
	}

	fprintf(stderr, "check_bsp: %s: %d planos, %d nodos, %d hojas, %d caras, "
	                "%d texinfos, %d edges, %d surfedges, %d clipnodes, "
	                "%d bytes de entidades\n",
	        filename, nplanes, nnodes, nleafs, nfaces, nsurf, nedges, nsegs, nclip,
	        lumplen[LUMP_ENTITIES]);
	if (problems)
		fprintf(stderr, "check_bsp: %d problemas\n", problems);
	else
		fprintf(stderr, "check_bsp: todo cuadra\n");

	free(f.d);
	#undef MAL
	return problems ? 1 : 0;
}
