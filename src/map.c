/* direkt-bsp -- lector de .map.
 *
 * GPL-2.0, ver LICENSE en la raiz del repositorio.
 *
 * Se entiende el subconjunto clasico de Quake: entidades con pares clave/valor
 * y dentro brushes con caras de 3 o mas puntos en antihorario visto desde fuera.
 * No se entiende el formato de "brush primitives" con [ ... ], y se avisa con un
 * mensaje claro en vez de devolver una geometria rara.
 */

#define _GNU_SOURCE
#include "direktbsp.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------------ lectura */

static char *read_whole_file(const char *filename)
{
	FILE *f = fopen(filename, "rb");
	long size;
	char *buf;
	size_t got;

	if (!f)
		error("no se puede abrir %s", filename);
	if (fseek(f, 0, SEEK_END) != 0)
		error("no se puede medir %s", filename);
	size = ftell(f);
	if (size < 0)
		error("no se puede medir %s", filename);
	rewind(f);

	buf = xmalloc((size_t)size + 1);
	got = fread(buf, 1, (size_t)size, f);
	buf[got] = '\0';
	fclose(f);
	return buf;
}

static int is_space(char c)
{
	return c == ' ' || c == '\t' || c == '\r' || c == '\n';
}

/* Pasa espacios y comentarios. Los comentarios son los de Quake: // hasta el fin
 * de linea, yslash-asterisco ... asterisco-slash. */
static char *skip_blanks(char *p)
{
	for (;;) {
		while (is_space(*p))
			p++;
		if (p[0] == '/' && p[1] == '/') {
			while (*p && *p != '\n')
				p++;
			continue;
		}
		if (p[0] == '/' && p[1] == '*') {
			p += 2;
			while (*p && !(p[0] == '*' && p[1] == '/'))
				p++;
			if (*p)
				p += 2;
			continue;
		}
		return p;
	}
}

/* Lee un token: con comillas, lo que haya entre ellas; si no, hasta blanco. */
static char *scan_token(char *p, char *out, size_t outsz)
{
	size_t n = 0;

	p = skip_blanks(p);
	if (*p == '"') {
		p++;
		while (*p && *p != '"') {
			if (n + 1 < outsz)
				out[n++] = *p;
			p++;
		}
		if (*p == '"')
			p++;
	} else {
		/* El token sin comillas termina en un espacio o en cualquiera de
		 * estos cinco.
		 *
		 * El parentesis de cierre importa de verdad: sin el, "(0 0 0)" se
		 * leia como el token "0)" y el parser se comia el cierre del punto,
		 * con lo que habia que escribir los puntos como "( 0 0 0 )". Los
		 * .map de Radiant y de medio mundo/networked usan las dos formas, y
		 * un editor que solo acepte una no es un editor: no puede abrir el
		 * mapa que ha generado otra herramienta. */
		while (*p && !is_space(*p) && *p != '"' && *p != '{' && *p != '}' &&
		       *p != ')' && *p != ',') {
			if (n + 1 < outsz)
				out[n++] = *p;
			p++;
		}
	}
	out[n] = '\0';
	return p;
}

static char *scan_float(char *p, float *out)
{
	char tok[64];
	char *end;
	double v;

	p = scan_token(p, tok, sizeof(tok));
	if (tok[0] == '\0')
		return NULL;
	v = strtod(tok, &end);
	if (end == tok)
		error("se esperaba un numero y hay \"%s\"", tok);
	*out = (float)v;
	return p;
}

static int looks_like_number(char *p)
{
	p = skip_blanks(p);
	return isdigit((unsigned char)p[0]) || p[0] == '-' || p[0] == '+' || p[0] == '.';
}

/* ------------------------------------------------------------------ clases */

/* Las entidades que el juego mueve con setorigin tienen que ser submodelos: si
 * entran en el arbol del mundo, al moverlas arrastran la geometria fija. La
 * lista sale de las clases que el QC implementa de verdad, no de suposiciones. */
static const char *moving_classes[] = {
    "func_door",           "func_door2",           "func_door_rotating",
    "func_door2_rotating", "func_door_secret",     "func_button",
    "func_plat",           "func_train",           "func_rotating",
    "func_wall",           "func_wall_toggle",     "func_breakable",
    "func_illusionary",    "func_conveyor",        NULL};

static int is_moving(const char *classname)
{
	int i;
	for (i = 0; moving_classes[i]; i++)
		if (strcmp(moving_classes[i], classname) == 0)
			return 1;
	return 0;
}

static int is_trigger(const char *classname)
{
	return strncmp(classname, "trigger_", 8) == 0;
}

/* ------------------------------------------------------------------ brushes */

static void check_brush(brush_t *b, int entityindex)
{
	int i, j;

	if (b->numsides < 4)
		error("entidad %d: una brush con %d caras no cierra un volumen", entityindex,
		      b->numsides);

	for (i = 0; i < b->numsides; i++) {
		winding_t *w = b->sides[i].winding;
		if (!w || w->numpoints < 3)
			error("entidad %d: cara %d con menos de 3 puntos", entityindex, i);
		if (winding_area(w) < 0.1f)
			error("entidad %d: cara %d degenerada, area casi 0", entityindex, i);
	}

	/* Convexa: cada cara tiene que dejar a las demas en su lado interior. Sin
	 * esta comprobacion una brush mal escrita se lleva el arbol entero y el
	 * fallo aparece mucho despues, como geometria imposible. */
	for (i = 0; i < b->numsides; i++) {
		for (j = 0; j < b->numsides; j++) {
			winding_t *w;
			int k;
			if (i == j)
				continue;
			w = b->sides[j].winding;
			for (k = 0; k < w->numpoints; k++) {
				float d = plane_distance(&b->sides[i].plane, w->points[k]);
				if (d > 0.1f)
					error("entidad %d: brush no convexa, un punto "
					      "(%.1f %.1f %.1f) de la cara %d cae fuera de la "
					      "cara %d",
					      entityindex, w->points[k][0], w->points[k][1],
					      w->points[k][2], j, i);
			}
		}
	}
}

static void link_brush(map_t *map, entity_t *e, brush_t *b)
{
	b->next = NULL;
	if (e) {
		if (e->brushes_tail)
			e->brushes_tail->next = b;
		else
			e->brushes = b;
		e->brushes_tail = b;
	}
	if (map->brushes_tail) {
		map->brushes_tail->next = b;
	} else {
		map->brushes = b;
	}
	map->brushes_tail = b;
	map->numbrushes++;
}

/* Lee un bloque de brush ya haber consumido la llave de apertura. */
static char *parse_brush(char *p, map_t *map, entity_t *e, int entityindex,
			 int contents, int moving)
{
	brush_t *b = brush_new();
	vec3_t pts[16];
	int numpts = 0;
	int nface = 0;
	char tok[256];
	side_t *side;
	winding_t *w;
	plane_t pl;
	int i;

	for (;;) {
		p = skip_blanks(p);

		if (*p == '}') {
			p++;
			break;
		}
		if (*p == '\0')
			error("entidad %d: se acabo el fichero dentro de una brush",
			      entityindex);
		if (*p == '[')
			error("entidad %d: formato de brush primitives sin soportar; "
			      "las caras tienen que ser planas y en formato clasico",
			      entityindex);

		if (*p == '(') {
			float v[3];
			if (numpts >= 16)
				error("entidad %d: cara con mas de 16 puntos", entityindex);
			p++;
			for (i = 0; i < 3; i++) {
				p = scan_float(p, &v[i]);
				if (!p)
					error("entidad %d: punto incompleto", entityindex);
			}
			p = skip_blanks(p);
			if (*p != ')')
				error("entidad %d: falta el cierre del punto", entityindex);
			p++;
			VectorCopy(v, pts[numpts++]);
			continue;
		}

		/* Lo que no es un punto cierra la cara: el nombre de textura y sus
		 * cinco parametros de ejes, que son opcionales. El token se lee
		 * siempre, y el numero de puntos se comprueba despues. */
		p = scan_token(p, tok, sizeof(tok));
		if (numpts < 3)
			error("entidad %d: cara %d con %d puntos, minimo 3", entityindex,
			      nface, numpts);
		/* Una brush del .map tiene 6 caras, ni una mas ni una menos. El
		 * array de lados crece porque al partirlas hacen falta mas, pero
		 * aqui el tope sigue siendo 6: es el formato. */
		if (nface >= 6)
			error("entidad %d: una brush no puede tener mas de 6 caras",
			      entityindex);
		brush_sides_reserve(b, nface + 1);

		side = &b->sides[nface];
		side->texname = xstrdup(tok[0] ? tok : "notexture");
		side->texscale[0] = 1.0f;
		side->texscale[1] = 1.0f;
		side->texshift[0] = 0.0f;
		side->texshift[1] = 0.0f;
		side->texrotate = 0.0f;

		/* Los cinco parametros de ejes, que son opcionales. El orden es el
		 * de Quake: desplazamiento en X, desplazamiento en Y, rotacion,
		 * escala en X y escala en Y. O sea
		 *
		 *     textura  xoff  yoff  rot  xscale  yscale
		 *
		 * Leerlos como xscale,yscale,xoff,yoff,rot es sutil y muy grave: una
		 * cara escrita con "0 0 0 1 1" (que es lo que escriben las herramientas
		 * y lo que hay en casi todos los mapas) se queda con escala 0, los
		 * ejes de textura salen nulos, y de ahi sale todo lo demas: el texinfo
		 * se deduplica con el resto de caras, los extents del lightmap salen
		 * de miles de unidades, y la superficie se dibuja negra o no se
		 * dibuja. */
		if (looks_like_number(p)) {
			float v;
			if ((p = scan_float(p, &v)))
				side->texshift[0] = v;
			if ((p = scan_float(p, &v)))
				side->texshift[1] = v;
			if ((p = scan_float(p, &v)))
				side->texrotate = v;
			if ((p = scan_float(p, &v)))
				side->texscale[0] = v;
			if ((p = scan_float(p, &v)))
				side->texscale[1] = v;
		}

		/* Una escala de 0 aplana la textura en un punto: no hay forma de
		 * recuperar la escala real, y el .map no la guarda en ningun sitio, asi
		 * que se trata como 1, que es lo que hacen las herramientas. */
		if (side->texscale[0] == 0.0f)
			side->texscale[0] = 1.0f;
		if (side->texscale[1] == 0.0f)
			side->texscale[1] = 1.0f;

		/* El winding ya viene en antihorario desde fuera, que es como se
		 * dibuja, asi que no hay que darle la vuelta. */
		w = winding_new(numpts);
		for (i = 0; i < numpts; i++)
			VectorCopy(pts[i], w->points[i]);
		side->winding = w;

		pl = plane_from_points(w->points[0], w->points[1], w->points[2]);
		if (pl.normal[0] == 0.0f && pl.normal[1] == 0.0f && pl.normal[2] == 0.0f)
			error("entidad %d: cara %d con normal nula, puntos colineales",
			      entityindex, nface);
		for (i = 3; i < numpts; i++) {
			float d = plane_distance(&pl, w->points[i]);
			if (d > 0.1f || d < -0.1f)
				error("entidad %d: cara %d no es plana, el punto %d se sale "
				      "%.2f del plano de los tres primeros",
				      entityindex, nface, i, d);
		}
		side->plane = pl;

		nface++;
		numpts = 0;
	}

	b->numsides = nface;
	b->contents = contents;
	b->original = 1;
	b->modelindex = -1;
	b->moving = moving;

	check_brush(b, entityindex);
	link_brush(map, e, b);
	return p;
}

/* ------------------------------------------------------------------ parser */

static void add_pair(entity_t *e, const char *key, const char *value)
{
	e->pairs = xrealloc(e->pairs, sizeof(pair_t) * (size_t)(e->numpairs + 1));
	e->pairs[e->numpairs].key = xstrdup(key);
	e->pairs[e->numpairs].value = xstrdup(value);
	e->numpairs++;
}

const char *entity_key(entity_t *e, const char *key)
{
	int i;
	if (!e)
		return NULL;
	for (i = 0; i < e->numpairs; i++)
		if (strcmp(e->pairs[i].key, key) == 0)
			return e->pairs[i].value;
	return NULL;
}

map_t *parse_map(const char *filename)
{
	char *buf = read_whole_file(filename);
	char *p = buf;
	map_t *map = xcalloc(1, sizeof(map_t));

	for (;;) {
		entity_t *e;
		brush_t *b;
		const char *cn;
		int contents = CONTENTS_SOLID;
		int moving = 0;

		p = skip_blanks(p);
		if (*p == '\0')
			break;
		if (*p != '{')
			error("se esperaba una llave de entidad y hay '%c'", *p);
		p++;

		e = xcalloc(1, sizeof(entity_t));
		if (map->entities_tail)
			map->entities_tail->next = e;
		else
			map->entities = e;
		map->entities_tail = e;
		map->numentities++;

		for (;;) {
			char key[256], value[256];
			p = skip_blanks(p);
			if (*p == '}') {
				p++;
				break;
			}
			if (*p == '\0')
				error("se acabo el fichero dentro de una entidad");
			if (*p == '{') {
				/* Un brush dentro de la entidad. La clase todavia no se
				 * conoce, asi que se lee con valores neutros y se
				 * reclasifica al final, cuando esten todas las claves. */
				p++;
				p = parse_brush(p, map, e, map->numentities, CONTENTS_SOLID,
				                0);
				continue;
			}
			p = scan_token(p, key, sizeof(key));
			p = scan_token(p, value, sizeof(value));
			if (key[0] == '\0')
				error("se esperaba una clave y no hay nada");
			add_pair(e, key, value);
		}

		/* Ya se sabe la clase: se reclasifican las brushes de la entidad. */
		cn = entity_key(e, "classname");
		e->is_world = (cn && strcmp(cn, "worldspawn") == 0);
		if (cn && is_trigger(cn))
			contents = CONTENTS_EMPTY;
		else if (cn && is_moving(cn))
			moving = 1;

		for (b = e->brushes; b; b = b->next) {
			b->contents = contents;
			b->moving = moving;
		}
	}

	free(buf);
	return map;
}

void free_map(map_t *map)
{
	entity_t *e, *enext;
	brush_t *b, *bnext;
	int j;

	if (!map)
		return;
	for (b = map->brushes; b; b = bnext) {
		bnext = b->next;
		brush_free(b);
	}
	for (e = map->entities; e; e = enext) {
		enext = e->next;
		for (j = 0; j < e->numpairs; j++) {
			free(e->pairs[j].key);
			free(e->pairs[j].value);
		}
		free(e->pairs);
		free(e);
	}
	free(map);
}
