/* ed_doc.c -- documento del editor de niveles.
 *
 * GPL-2.0, ver LICENSE en la raiz del repositorio.
 *
 * El documento es un map_t tal cual, sin representacion paralela. Ver la nota
 * de editor.h: dos representaciones del mismo mapa siempre se desfasan.
 *
 * El guardado a .map es lo que hace que esto sea un editor y no un visor, asi
 * que va con especial cuidado: el fichero que sale tiene que volver a entrar
 * identico. De ahi el formato de numeros y la regla de "origin" explicita de
 * las brush-entities.
 */

#define _GNU_SOURCE
#include "editor.h"

#include <ctype.h>
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* ------------------------------------------------------------------ numeros */

const char *ed_fmt_num(float v, char *buf, size_t n)
{
	/* Las coordenadas de un mapa son casi siempre enteras. Escribirlas como
	 * "288" en vez de "288.000000" hace el fichero legible y, sobre todo,
	 * estable: si se escribiera "287.99999" por error de coma flotante, al
	 * releer daria otra brush y el mapa se moveria solo. Si el valor es
	 * entero de verdad, se escribe entero. */
	float r = (float)(int)v;
	if (fabsf(v - r) < 0.0005f) {
		snprintf(buf, n, "%d", (int)r);
		return buf;
	}
	/* Con 3 decimales basta de sobra para Quake: el motor trabaja con
	 * enteros de 1/16 de unidad. */
	snprintf(buf, n, "%.3f", (double)v);
	/* Quita los ceros de la derecha y el punto si queda entero. */
	{
		char *p = strchr(buf, '.');
		if (p) {
			char *q = p + strlen(p) - 1;
			while (q > p && *q == '0')
				*q-- = '\0';
			if (q == p)
				*q = '\0';
		}
	}
	return buf;
}

int ed_snapped(float v, int grid)
{
	if (grid < 1)
		grid = 1;
	return (int)(floorf(v / (float)grid + 0.5f) * (float)grid);
}

void ed_snap_vec(vec3_t v, int grid, vec3_t out)
{
	out[0] = (float)ed_snapped(v[0], grid);
	out[1] = (float)ed_snapped(v[1], grid);
	out[2] = (float)ed_snapped(v[2], grid);
}

/* -------------------------------------------------------------- growable buf */

typedef struct {
	char *s;
	size_t len, cap;
} buf_t;

static void buf_init(buf_t *b)
{
	b->cap = 4096;
	b->len = 0;
	b->s = xmalloc(b->cap);
	b->s[0] = '\0';
}

static void buf_add(buf_t *b, const char *fmt, ...)
{
	va_list ap;
	int n;

	for (;;) {
		size_t room = b->cap - b->len;
		va_start(ap, fmt);
		n = vsnprintf(b->s + b->len, room, fmt, ap);
		va_end(ap);
		if (n < 0)
			error("fallo al formatear el .map");
		if ((size_t)n < room) {
			b->len += (size_t)n;
			return;
		}
		b->cap = b->cap * 2;
		b->s = xrealloc(b->s, b->cap);
	}
}

/* --------------------------------------------------------------- .map writer */

static void write_brush(buf_t *out, brush_t *b)
{
	int i, j;

	buf_add(out, "{\n");
	for (i = 0; i < b->numsides; i++) {
		side_t *s = &b->sides[i];
		winding_t *w = s->winding;
		char n0[32], n1[32], n2[32];

		if (!w || w->numpoints < 3)
			continue;
		for (j = 0; j < w->numpoints; j++) {
			buf_add(out, "(%s %s %s) ",
			        ed_fmt_num(w->points[j][0], n0, sizeof(n0)),
			        ed_fmt_num(w->points[j][1], n1, sizeof(n1)),
			        ed_fmt_num(w->points[j][2], n2, sizeof(n2)));
		}
		buf_add(out, "%s", s->texname ? s->texname : "notexture");
		/* Los cinco parametros solo si no son los de por defecto: asi el
		 * fichero se lee igual que el de un mapa de Quake, donde solo se
		 * escriben cuando la textura va girada o desplazada. */
		if (s->texscale[0] != 1.0f || s->texscale[1] != 1.0f ||
		    s->texshift[0] != 0.0f || s->texshift[1] != 0.0f || s->texrotate != 0.0f) {
			buf_add(out, " %s %s %s %s %s",
			        ed_fmt_num(s->texscale[0], n0, sizeof(n0)),
			        ed_fmt_num(s->texscale[1], n1, sizeof(n1)),
			        ed_fmt_num(s->texshift[0], n0, sizeof(n0)),
			        ed_fmt_num(s->texshift[1], n1, sizeof(n1)),
			        ed_fmt_num(s->texrotate, n2, sizeof(n2)));
		}
		buf_add(out, "\n");
	}
	buf_add(out, "}\n");
}

char *save_map_to_string(map_t *map)
{
	buf_t out;
	entity_t *e;
	brush_t *b;
	char n0[32], n1[32], n2[32];

	buf_init(&out);
	buf_add(&out, "// Mapa generado por el editor de Direkt.\n");

	for (e = map->entities; e; e = e->next) {
		buf_add(&out, "\n{\n");

		for (int i = 0; i < e->numpairs; i++) {
			/* "origin" se escribe al final y desde los limites reales de
			 * las brushes, no desde el valor guardado. Ver mas abajo. */
			if (strcmp(e->pairs[i].key, "origin") == 0)
				continue;
			buf_add(&out, "\"%s\" \"%s\"\n", e->pairs[i].key, e->pairs[i].value);
		}

		/* Una brush-entity sin "origin" es un mapa roto.
		 *
		 * Las brushes de LibreQuake llegan al BSP con "model" "*N" y sin
		 * "origin", y el motor NO lo deduce: lo que hace es usar el origen
		 * de la entidad, que es (0,0,0). Una plataforma o una puerta salia
		 * en el centro del mapa. Por eso el editor escribe siempre "origin"
		 * explicito, y lo calcula desde la caja de las brushes, que es lo
		 * unico que no depende de donde este el cursor.
		 *
		 * Si la entidad NO tiene brushes, su origin es el que tenga
		 * guardado (el punto de aparicion, una luz) y se respeta tal cual:
		 * solo se descarta para rehacerlo cuando hay brushes de donde
		 * calcularlo. */
		if (!e->is_world && !e->brushes) {
			const char *o = entity_key(e, "origin");
			if (o)
				buf_add(&out, "\"origin\" \"%s\"\n", o);
		}
		if (!e->is_world && e->brushes) {
			vec3_t mins, maxs;
			brush_t *first = e->brushes;
			brush_bounds(first, mins, maxs);
			for (b = first->next; b; b = b->next) {
				vec3_t bm, bM;
				brush_bounds(b, bm, bM);
				for (int k = 0; k < 3; k++) {
					if (bm[k] < mins[k])
						mins[k] = bm[k];
					if (bM[k] > maxs[k])
						maxs[k] = bM[k];
				}
			}
			buf_add(&out, "\"origin\" \"%s %s %s\"\n",
			        ed_fmt_num(mins[0], n0, sizeof(n0)),
			        ed_fmt_num(mins[1], n1, sizeof(n1)),
			        ed_fmt_num(mins[2], n2, sizeof(n2)));
		}

		for (b = e->brushes; b; b = b->next)
			write_brush(&out, b);

		buf_add(&out, "}\n");
	}

	return out.s;
}

int save_map(const char *filename, map_t *map)
{
	char *text = save_map_to_string(map);
	FILE *f = fopen(filename, "wb");
	size_t len = strlen(text);
	int ok;

	if (!f) {
		error("no se puede escribir %s", filename);
	}
	ok = fwrite(text, 1, len, f) == len;
	if (fclose(f) != 0 || !ok)
		error("escritura incompleta de %s", filename);
	free(text);
	return 0;
}

int ed_doc_save(ed_doc_t *doc, const char *filename)
{
	if (save_map(filename, doc->map) != 0)
		return 1;
	free(doc->filename);
	doc->filename = xstrdup(filename);
	{
		const char *slash = strrchr(filename, '/');
		free(doc->title);
		doc->title = xstrdup(slash ? slash + 1 : filename);
	}
	doc->dirty = 0;
	return 0;
}

/* ------------------------------------------------------------------ brushes */

/* Coloca una brush caja axis-alineada. */
brush_t *brush_make_box(vec3_t mins, vec3_t maxs, const char *texname)
{
	brush_t *b = brush_new();
	int i, e, k1, k2, hi, q;
	vec3_t n;
	plane_t pl;

	/* El array de caras es dinamico (una brush partida puede pasar de 6), asi
	 * que hay que reservarlo antes de escribir en el. */
	brush_sides_reserve(b, 6);

	for (i = 0; i < 6; i++) {
		side_t *s = &b->sides[i];
		vec3_t p[4];
		winding_t *w;

		e = i >> 1;   /* 0 = x, 1 = y, 2 = z */
		hi = i & 1;   /* 0 = cara baja, 1 = cara alta */
		k1 = (e + 1) % 3;
		k2 = (e + 2) % 3;

		memset(&n, 0, sizeof(n));
		n[e] = hi ? 1.0f : -1.0f;

		p[0][e] = hi ? maxs[e] : mins[e];
		for (q = 1; q < 4; q++)
			p[q][e] = p[0][e];
		p[0][k1] = mins[k1]; p[0][k2] = mins[k2];
		p[1][k1] = maxs[k1]; p[1][k2] = mins[k2];
		p[2][k1] = maxs[k1]; p[2][k2] = maxs[k2];
		p[3][k1] = mins[k1]; p[3][k2] = maxs[k2];

		w = winding_new(4);
		for (q = 0; q < 4; q++)
			VectorCopy(p[q], w->points[q]);

		/* El sentido del cuadrado depende de cual sea el eje y de si la
		 * cara es la de arriba o la de abajo, y equivocarse aqui produce
		 * una brush con la normal invertida: el motor la dibuja del reves y
		 * el brush se comporta al reves. En vez de=fiarse de una tabla de
		 * casos, se calcula la normal del winding y, si no coincide con la
		 * que deberia tener, se le da la vuelta. Que se compruebe solo. */
		plane_from_winding(w, &pl);
		if (pl.normal[0] * n[0] + pl.normal[1] * n[1] + pl.normal[2] * n[2] < 0.0f) {
			/* winding_reverse DEVUELVE una winding nueva, no da la vuelta la
			 * de dentro: hay que coger el resultado y soltar la vieja. */
			winding_t *r = winding_reverse(w);
			winding_free(w);
			w = r;
			plane_from_winding(w, &pl);
		}

		s->plane.normal[0] = n[0];
		s->plane.normal[1] = n[1];
		s->plane.normal[2] = n[2];
		s->plane.dist = hi ? maxs[e] : -mins[e];
		s->winding = w;
		s->texname = xstrdup(texname && texname[0] ? texname : "notexture");
		s->texscale[0] = 1.0f;
		s->texscale[1] = 1.0f;
		s->texshift[0] = 0.0f;
		s->texshift[1] = 0.0f;
		s->texrotate = 0.0f;
	}
	b->numsides = 6;
	b->contents = CONTENTS_SOLID;
	b->original = 1;
	b->modelindex = -1;
	return b;
}

/* --------------------------------------------------------------- entidades */

static void link_brush_to_map(map_t *map, entity_t *e, brush_t *b)
{
	b->next = NULL;
	if (e->brushes_tail)
		e->brushes_tail->next = b;
	else
		e->brushes = b;
	e->brushes_tail = b;

	if (map->brushes_tail)
		map->brushes_tail->next = b;
	else
		map->brushes = b;
	map->brushes_tail = b;
	map->numbrushes++;
}

/* Quita una brush de las dos listas en las que vive. */
static void unlink_brush(map_t *map, entity_t *e, brush_t *b)
{
	brush_t **pp;
	int encontrado = 0;

	for (pp = &e->brushes; *pp; pp = &(*pp)->next) {
		if (*pp == b) {
			*pp = b->next;
			encontrado = 1;
			break;
		}
	}
	if (encontrado && e->brushes_tail == b) {
		/* Hay que recalcular la cola: puede que b fuera la ultima. */
		brush_t *q = e->brushes;
		e->brushes_tail = NULL;
		while (q) {
			e->brushes_tail = q;
			q = q->next;
		}
	}
	b->next = NULL;

	for (pp = &map->brushes; *pp; pp = &(*pp)->next) {
		if (*pp == b) {
			*pp = b->next;
			break;
		}
	}
	if (map->brushes_tail == b) {
		brush_t *q = map->brushes;
		map->brushes_tail = NULL;
		while (q) {
			map->brushes_tail = q;
			q = q->next;
		}
	}
	map->numbrushes--;
}

static void pair_set(entity_t *e, const char *key, const char *value)
{
	int i;
	for (i = 0; i < e->numpairs; i++)
		if (strcmp(e->pairs[i].key, key) == 0) {
			free(e->pairs[i].value);
			e->pairs[i].value = xstrdup(value);
			return;
		}
	e->pairs = xrealloc(e->pairs, sizeof(pair_t) * (size_t)(e->numpairs + 1));
	e->pairs[e->numpairs].key = xstrdup(key);
	e->pairs[e->numpairs].value = xstrdup(value);
	e->numpairs++;
}

const char *ed_get_key(entity_t *e, const char *key)
{
	return entity_key(e, key);
}

void ed_set_key(ed_doc_t *doc, entity_t *e, const char *key, const char *value)
{
	ed_mark(doc);
	pair_set(e, key, value);
	ed_doc_touch(doc);
}

entity_t *ed_add_entity(ed_doc_t *doc, const char *classname, vec3_t org)
{
	map_t *map = doc->map;
	entity_t *e = xcalloc(1, sizeof(entity_t));
	char b0[32], b1[32], b2[32], v[128];

	ed_mark(doc);

	if (map->entities_tail)
		map->entities_tail->next = e;
	else
		map->entities = e;
	map->entities_tail = e;
	map->numentities++;

	pair_set(e, "classname", classname && classname[0] ? classname : "info_player_start");
	snprintf(v, sizeof(v), "%s %s %s", ed_fmt_num(org[0], b0, sizeof(b0)),
	         ed_fmt_num(org[1], b1, sizeof(b1)), ed_fmt_num(org[2], b2, sizeof(b2)));
	pair_set(e, "origin", v);
	e->is_world = 0;
	ed_doc_touch(doc);
	return e;
}

void ed_delete_entity(ed_doc_t *doc, entity_t *e)
{
	map_t *map = doc->map;
	entity_t **pp, *prev = NULL;
	brush_t *b;

	if (!e || e->is_world)
		return; /* worldspawn no se borra jams */
	ed_mark(doc);

	while (e->brushes) {
		b = e->brushes;
		unlink_brush(map, e, b);
		brush_free(b);
	}

	for (pp = &map->entities; *pp; pp = &(*pp)->next) {
		if (*pp == e) {
			*pp = e->next;
			break;
		}
		prev = *pp;
	}
	if (map->entities_tail == e)
		map->entities_tail = prev;
	e->next = NULL;
	map->numentities--;

	for (int i = 0; i < e->numpairs; i++) {
		free(e->pairs[i].key);
		free(e->pairs[i].value);
	}
	free(e->pairs);
	free(e);

	if (doc->sel_entity == e)
		doc->sel_entity = NULL;
	if (doc->sel_brush)
		doc->sel_brush = NULL;
	ed_doc_touch(doc);
}

/* ----------------------------------------------------------------- historial */

static void hist_push(char ***arr, int *n, int *cap, const char *text)
{
	if (*n >= *cap) {
		*cap = *cap ? *cap * 2 : 32;
		*arr = xrealloc(*arr, sizeof(char *) * (size_t)*cap);
	}
	(*arr)[(*n)++] = xstrdup(text);
}

/* Suelta SOLO las instantaneas, no el arreglo. El arreglo lo libera quien lo
 * posee, y si esta funcion lo liberara tambien, el free de Array del
 * propietario seria un doble free. */
static void hist_clear(char **arr, int n)
{
	int i;
	for (i = 0; i < n; i++) {
		free(arr[i]);
		arr[i] = NULL;
	}
}

void ed_mark(ed_doc_t *doc)
{
	/* La instantanea es del estado ANTERIOR, que es justo a lo que hay que
	 * volver al deshacer. hist_push copia el texto, asi que el temporal que
	 * devuelve save_map_to_string hay que soltarlo aqui. */
	{
		char *texto = save_map_to_string(doc->map);
		hist_push(&doc->undo, &doc->numundo, &doc->undocap, texto);
		free(texto);
	}
	if (doc->numundo > 200) {
		/* El mas antiguo se cae: deshacer 200 pasos llega de sobra y la
		 * memoria tiene que estar acotada. */
		free(doc->undo[0]);
		memmove(doc->undo, doc->undo + 1, sizeof(char *) * (size_t)(doc->numundo - 1));
		doc->numundo--;
	}
	/* Al hacer un cambio se descarta lo que se habia deshecho. */
	hist_clear(doc->redo, doc->numredo);
	doc->numredo = 0;
	doc->redocap = 0;
	free(doc->redo);
	doc->redo = NULL;
}

/* Recarga el documento desde un texto .map. La seleccion se pierde porque
 * apunta a punteros que acaban de dejar de existir. */
static void reload_from(ed_doc_t *doc, const char *text)
{
	map_t *m;
	FILE *f;
	char tmp[] = "/tmp/direkt-ed-XXXXXX";
	int fd = mkstemp(tmp);

	if (fd < 0)
		error("no se puede crear el temporal para recargar el documento");
	f = fdopen(fd, "wb");
	if (!f)
		error("no se puede escribir el temporal del documento");
	fwrite(text, 1, strlen(text), f);
	fclose(f);

	m = parse_map(tmp);
	remove(tmp);

	free_map(doc->map);
	doc->map = m;
	doc->sel_brush = NULL;
	doc->sel_entity = NULL;
	doc->sel_side = -1;
}

int ed_undo(ed_doc_t *doc)
{
	if (doc->numundo == 0)
		return 0;
	/* Se aparta el estado actual para poder rehacerlo, y se vuelve al
	 * anterior. */
	{
		char *texto = save_map_to_string(doc->map);
		hist_push(&doc->redo, &doc->numredo, &doc->redocap, texto);
		free(texto);
	}
	doc->numundo--;
	reload_from(doc, doc->undo[doc->numundo]);
	free(doc->undo[doc->numundo]);
	doc->undo[doc->numundo] = NULL;
	ed_doc_touch(doc);
	return 1;
}

int ed_redo(ed_doc_t *doc)
{
	if (doc->numredo == 0)
		return 0;
	{
		char *texto = save_map_to_string(doc->map);
		hist_push(&doc->undo, &doc->numundo, &doc->undocap, texto);
		free(texto);
	}
	doc->numredo--;
	reload_from(doc, doc->redo[doc->numredo]);
	free(doc->redo[doc->numredo]);
	doc->redo[doc->numredo] = NULL;
	ed_doc_touch(doc);
	return 1;
}

/* --------------------------------------------------------------- ciclo de vida */

ed_doc_t *ed_doc_new(void)
{
	ed_doc_t *doc = xcalloc(1, sizeof(ed_doc_t));
	map_t *map = xcalloc(1, sizeof(map_t));
	entity_t *w = xcalloc(1, sizeof(entity_t));

	/* Un documento nuevo nace con un worldspawn y un punto de aparicion,
	 * porque un mapa sin ellos no se puede ni abrir ni probar. */
	w->is_world = 1;
	pair_set(w, "classname", "worldspawn");
	map->entities = w;
	map->entities_tail = w;
	map->numentities = 1;

	{
		entity_t *st = xcalloc(1, sizeof(entity_t));
		map->entities_tail->next = st;
		map->entities_tail = st;
		map->numentities++;
		pair_set(st, "classname", "info_player_start");
		pair_set(st, "origin", "0 0 24");
	}

	doc->map = map;
	doc->show_grid = 1;
	doc->grid_size = 16;
	doc->show_triggers = 1;
	doc->sel_side = -1;
	doc->undocap = 0;
	doc->redocap = 0;
	ed_doc_touch(doc);
	return doc;
}

ed_doc_t *ed_doc_load(const char *filename)
{
	ed_doc_t *doc = xcalloc(1, sizeof(ed_doc_t));
	const char *slash;

	doc->map = parse_map(filename);
	doc->filename = xstrdup(filename);
	slash = strrchr(filename, '/');
	doc->title = xstrdup(slash ? slash + 1 : filename);
	doc->show_grid = 1;
	doc->grid_size = 16;
	doc->show_triggers = 1;
	doc->sel_side = -1;
	ed_doc_touch(doc);
	doc->dirty = 0;
	return doc;
}

void ed_doc_free(ed_doc_t *doc)
{
	if (!doc)
		return;
	free_map(doc->map);
	free(doc->filename);
	free(doc->title);
	hist_clear(doc->undo, doc->numundo);
	hist_clear(doc->redo, doc->numredo);
	free(doc->undo);
	free(doc->redo);
	free(doc);
}

void ed_doc_touch(ed_doc_t *doc)
{
	doc->dirty = 1;
}

int ed_num_brushes(ed_doc_t *doc)
{
	return doc->map->numbrushes;
}

int ed_num_entities(ed_doc_t *doc)
{
	return doc->map->numentities;
}

void ed_doc_bounds(ed_doc_t *doc, vec3_t mins, vec3_t maxs)
{
	brush_t *b;
	int primero = 1;

	for (b = doc->map->brushes; b; b = b->next) {
		vec3_t bm, bM;
		brush_bounds(b, bm, bM);
		if (primero) {
			VectorCopy(bm, mins);
			VectorCopy(bM, maxs);
			primero = 0;
		} else {
			int k;
			for (k = 0; k < 3; k++) {
				if (bm[k] < mins[k])
					mins[k] = bm[k];
				if (bM[k] > maxs[k])
					maxs[k] = bM[k];
			}
		}
	}
	if (primero) {
		mins[0] = mins[1] = mins[2] = -64.0f;
		maxs[0] = maxs[1] = maxs[2] = 64.0f;
	}
}

entity_t *ed_brush_entity(ed_doc_t *doc, brush_t *b)
{
	entity_t *e;
	for (e = doc->map->entities; e; e = e->next) {
		brush_t *q;
		for (q = e->brushes; q; q = q->next)
			if (q == b)
				return e;
	}
	return NULL;
}

/* ------------------------------------------------------------------ seleccion */

void ed_select_none(ed_doc_t *doc)
{
	doc->sel_brush = NULL;
	doc->sel_entity = NULL;
	doc->sel_side = -1;
}

void ed_select_brush(ed_doc_t *doc, brush_t *b)
{
	doc->sel_brush = b;
	doc->sel_side = -1;
	doc->sel_entity = b ? ed_brush_entity(doc, b) : NULL;
}

void ed_select_entity(ed_doc_t *doc, entity_t *e)
{
	doc->sel_entity = e;
	doc->sel_brush = NULL;
	doc->sel_side = -1;
}

/* -------------------------------------------------------------- rayo y picking */

/* Intersecta un rayo con un plano. Devuelve la distancia t >= 0, o -1. */
static float ray_plane(vec3_t org, vec3_t dir, plane_t *pl)
{
	float den = dir[0] * pl->normal[0] + dir[1] * pl->normal[1] +
	            dir[2] * pl->normal[2];
	float num, t;

	if (fabsf(den) < 1e-6f)
		return -1.0f; /* paralelo */
	num = pl->dist - (org[0] * pl->normal[0] + org[1] * pl->normal[1] +
	                  org[2] * pl->normal[2]);
	t = num / den;
	if (t < 0.0f)
		return -1.0f;
	return t;
}

/* Distancia al winding por el teorema del baricentro, o -1 si no lo corta.
 *
 * No se usa el winding de la cara: se proyecta el punto de impacto sobre el
 * plano y se mira si cae dentro del poligono. Asi una cara de 4 o mas lados
 * (un brush partido, o una cara inclinedada) se pincha igual de bien que una
 * triangular. */
static float ray_winding(vec3_t org, vec3_t dir, winding_t *w)
{
	plane_t pl;
	float t, d;
	vec3_t hit;
	int i, j, ej1 = 0, ej2 = 0;
	float angsum = 0.0f;

	plane_from_winding(w, &pl);
	t = ray_plane(org, dir, &pl);
	if (t < 0.0f)
		return -1.0f;

	d = sqrtf(dir[0] * dir[0] + dir[1] * dir[1] + dir[2] * dir[2]);
	if (d < 1e-6f)
		return -1.0f;

	for (j = 0; j < 3; j++)
		hit[j] = org[j] + dir[j] * (t / d);

	/* Suma de los angulos alrededor del punto: 2*pi si esta dentro, 0 si
	 * esta fuera. Es el test clasico y no necesita triangular. */
	for (i = 0; i < w->numpoints; i++) {
		vec3_t a, b;
		float v1[2], v2[2];
		float cross, ang;

		for (j = 0; j < 3; j++) {
			a[j] = w->points[i][j] - hit[j];
			b[j] = w->points[(i + 1) % w->numpoints][j] - hit[j];
		}
		/* Proyeccion a los dos ejes que NO son la normal del plano. Si se
		 * escoge mal, todos los vectores salen con una componente a cero, los
		 * angulos suman 0 y el punto parece estar fuera de un poligono que
		 * lo contiene: el raton deja de seleccionar nada. */
		{
			int e = 0;
			if (fabsf(pl.normal[1]) > fabsf(pl.normal[e]))
				e = 1;
			if (fabsf(pl.normal[2]) > fabsf(pl.normal[e]))
				e = 2;
			ej1 = (e + 1) % 3;
			ej2 = (e + 2) % 3;
			v1[0] = a[ej1]; v1[1] = a[ej2];
			v2[0] = b[ej1]; v2[1] = b[ej2];
		}
		cross = v1[0] * v2[1] - v1[1] * v2[0];
		ang = atan2f(cross, v1[0] * v2[0] + v1[1] * v2[1]);
		angsum += ang;
	}
	if (fabsf(angsum) < 3.0f) /* ~2*pi con margen, o ~0 si fuera */
		return -1.0f;
	return t / d;
}

brush_t *ed_pick(ed_doc_t *doc, vec3_t org, vec3_t dir)
{
	brush_t *b;
	brush_t *mejor = NULL;
	float mejor_t = 1e30f;
	int mejor_side = -1;

	for (b = doc->map->brushes; b; b = b->next) {
		int i;
		for (i = 0; i < b->numsides; i++) {
			float t;
			if (!b->sides[i].winding)
				continue;
			t = ray_winding(org, dir, b->sides[i].winding);
			if (t >= 0.0f && t < mejor_t) {
				mejor_t = t;
				mejor = b;
				mejor_side = i;
			}
		}
	}
	if (mejor)
		doc->sel_side = mejor_side;
	return mejor;
}

/* ------------------------------------------------------------------- edicion */

brush_t *ed_add_box(ed_doc_t *doc, entity_t *e, vec3_t mins, vec3_t maxs,
                    const char *texname)
{
	brush_t *b;
	int k;

	if (!e)
		e = doc->map->entities; /* worldspawn */
	ed_mark(doc);

	for (k = 0; k < 3; k++) {
		if (mins[k] > maxs[k]) {
			float t = mins[k];
			mins[k] = maxs[k];
			maxs[k] = t;
		}
	}
	/* Una brush de lado cero no es un volumen: el motor se quejaria y el
	 * brush no existiria de verdad. */
	for (k = 0; k < 3; k++)
		if (maxs[k] - mins[k] < 1.0f)
			return NULL;

	b = brush_make_box(mins, maxs, texname);
	b->contents = (e && e->is_world) ? CONTENTS_SOLID : b->contents;
	link_brush_to_map(doc->map, e, b);
	ed_select_brush(doc, b);
	ed_doc_touch(doc);
	return b;
}

brush_t *ed_duplicate_brush(ed_doc_t *doc, brush_t *b)
{
	brush_t *c;
	entity_t *e;
	vec3_t delta;

	if (!b)
		return NULL;
	e = ed_brush_entity(doc, b);
	ed_mark(doc);

	c = brush_copy(b);
	/* Se separa un poco para que la copia se vea al instante y no quede
	 * exactamente encima de la original. */
	delta[0] = delta[1] = 0.0f;
	delta[2] = (float)doc->grid_size;
	{
		int i, j;
		for (i = 0; i < c->numsides; i++) {
			winding_t *w = c->sides[i].winding;
			if (!w)
				continue;
			for (j = 0; j < w->numpoints; j++) {
				w->points[j][0] += delta[0];
				w->points[j][1] += delta[1];
				w->points[j][2] += delta[2];
			}
		}
	}
	link_brush_to_map(doc->map, e, c);
	ed_select_brush(doc, c);
	ed_doc_touch(doc);
	return c;
}

void ed_delete_brush(ed_doc_t *doc, brush_t *b)
{
	entity_t *e;

	if (!b)
		return;
	e = ed_brush_entity(doc, b);
	ed_mark(doc);
	unlink_brush(doc->map, e, b);
	brush_free(b);
	if (doc->sel_brush == b)
		doc->sel_brush = NULL;
	ed_doc_touch(doc);
}

void ed_translate_brush(ed_doc_t *doc, brush_t *b, vec3_t delta)
{
	int i, j;

	if (!b)
		return;
	ed_mark(doc);
	for (i = 0; i < b->numsides; i++) {
		winding_t *w = b->sides[i].winding;
		if (!w)
			continue;
		for (j = 0; j < w->numpoints; j++) {
			w->points[j][0] += delta[0];
			w->points[j][1] += delta[1];
			w->points[j][2] += delta[2];
		}
		/* El plano se mueve con la brush; si no, al recompilar la brush
		 * se parte contra un plano que ya no esta donde estaba. */
		b->sides[i].plane.dist += delta[0] * b->sides[i].plane.normal[0] +
		                          delta[1] * b->sides[i].plane.normal[1] +
		                          delta[2] * b->sides[i].plane.normal[2];
	}
	if (doc->sel_entity && !doc->sel_entity->is_world) {
		/* Las entidades con brushes dependen de "origin". Si se mueve la
		 * brush y no se mueve el origin, la entidad se queda donde estaba
		 * y en el juego aparece desplazada. */
		const char *o = entity_key(doc->sel_entity, "origin");
		if (o) {
			float v[3];
			if (sscanf(o, "%f %f %f", &v[0], &v[1], &v[2]) == 3) {
				char b0[32], b1[32], b2[32], s[128];
				snprintf(s, sizeof(s), "%s %s %s",
				         ed_fmt_num(v[0] + delta[0], b0, sizeof(b0)),
				         ed_fmt_num(v[1] + delta[1], b1, sizeof(b1)),
				         ed_fmt_num(v[2] + delta[2], b2, sizeof(b2)));
				pair_set(doc->sel_entity, "origin", s);
			}
		}
	}
	ed_doc_touch(doc);
}

void ed_brush_to_origin(ed_doc_t *doc, entity_t *e, vec3_t org)
{
	char b0[32], b1[32], b2[32], s[128];

	if (!e || e->is_world)
		return;
	snprintf(s, sizeof(s), "%s %s %s", ed_fmt_num(org[0], b0, sizeof(b0)),
	         ed_fmt_num(org[1], b1, sizeof(b1)), ed_fmt_num(org[2], b2, sizeof(b2)));
	pair_set(e, "origin", s);
}

/* Devuelve 1 si la brush es exactamente una caja alineada con los ejes, y en
 * *e_axis deja el eje de la cara `side` (si side es -1, *e_axis se queda en
 * -1). */
static int brush_is_box(brush_t *b, int side, int *e_axis)
{
	vec3_t mins, maxs;
	int caras_por_eje[3] = {0, 0, 0};
	int i, e;

	*e_axis = -1;
	brush_bounds(b, mins, maxs);
	if (b->numsides != 6)
		return 0;

	for (i = 0; i < 6; i++) {
		plane_t *n = &b->sides[i].plane;
		int k, ejes = 0, eje = -1;
		float coord;

		/* Cada cara tiene que estar alineada con un unico eje. */
		for (k = 0; k < 3; k++)
			if (fabsf(n->normal[k]) > 0.9f) {
				ejes++;
				eje = k;
			}
		if (ejes != 1)
			return 0; /* cara inclinada: no puede ser una caja */

		/* La coordenada del plano sobre su eje es dist * normal: para
		 * normal (-1,0,0) con dist 32, el plano esta en x = -32, no en
		 * x = 32. Comparar dist contra los limites sin ese signo no
		 * funciona, y la comprobacion daba que ninguna caja era caja. */
		coord = n->dist * n->normal[eje];
		if (fabsf(coord - maxs[eje]) > 0.01f && fabsf(coord - mins[eje]) > 0.01f)
			return 0;
		caras_por_eje[eje]++;
	}

	/* Y tiene que haber exactamente dos caras por eje, una en cada extremo.
	 * Con dos caras en el mismo extremo, por ejemplo, hay una cara de mas
	 * tocando el mismo lado y la brush no es una caja. */
	for (e = 0; e < 3; e++)
		if (caras_por_eje[e] != 2)
			return 0;

	if (side >= 0 && side < 6) {
		plane_t *n = &b->sides[side].plane;
		for (e = 0; e < 3; e++)
			if (fabsf(n->normal[e]) > 0.9f)
				*e_axis = e;
	}
	return 1;
}

int ed_drag_side(ed_doc_t *doc, brush_t *b, int side, float dist)
{
	side_t *s;
	winding_t *w;
	int j, e_axis = -1;

	if (!b || side < 0 || side >= b->numsides)
		return 0;
	s = &b->sides[side];
	w = s->winding;
	if (!w || w->numpoints < 3)
		return 0;

	/* Si la brush es una caja perfecta, arrastrar una cara mueve la caja
	 * entera. Mover solo la cara daria una cuña, que es lo correcto para una
	 * brush convexa en general (es lo que hace Radiant) pero al colocar un
	 * muro o un suelo lo que se quiere es estirar la pieza, no deformarla.
	 * Para una brush que ya no es caja, el arrastre de la cara se deja como
	 * esta, que es lo unico que se puede hacer sin romper la convexidad. */
	if (brush_is_box(b, side, &e_axis)) {
		/* Estirar la caja por una cara: se mueven TODOS los puntos que
		 * estan en el plano de esa cara, no solo los de la cara.
		 *
		 * En una caja, los cuatro vertices de la cara de +x los comparten
		 * con las cuatro caras laterales. Mover solo los de la cara de +x
		 * deja las laterales apuntando todavia a la coordenada antigua, y
		 * el resultado no es una caja mas pequena: es un tronco de piramide
		 * con las juntas abiertas. Por eso se busca por coordenada. */
		float eje = s->plane.normal[e_axis];
		float plano = s->plane.dist;
		int i, q;

		ed_mark(doc);
		for (i = 0; i < b->numsides; i++) {
			winding_t *v = b->sides[i].winding;
			if (!v)
				continue;
			for (q = 0; q < v->numpoints; q++)
				if (fabsf(v->points[q][e_axis] * eje - plano) < 0.01f)
					v->points[q][e_axis] += eje * dist;
		}
		s->plane.dist += dist;
		ed_doc_touch(doc);
		return 1;
	}

	ed_mark(doc);

	/* Mover la cara es mover sus puntos a lo largo de la normal y shifting
	 * el plano. El winding se dibuja con la cara, asi que esto es todo lo
	 * que hay que tocar: la brush pasa a ser otra brush valida porque sus
	 * caras siguen siendo planas y los otros planos no se han movido. */
	for (j = 0; j < w->numpoints; j++) {
		w->points[j][0] += s->plane.normal[0] * dist;
		w->points[j][1] += s->plane.normal[1] * dist;
		w->points[j][2] += s->plane.normal[2] * dist;
	}
	s->plane.dist += dist;
	ed_doc_touch(doc);
	return 1;
}
