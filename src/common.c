/* direkt-bsp -- utilidades, vectores, planos y windings.
 *
 * GPL-2.0, ver LICENSE en la raiz del repositorio.
 */

#define _GNU_SOURCE
#include "direktbsp.h"

#include <errno.h>
#include <math.h>
#include <stdint.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* getpid: en Unix esta en unistd.h y en Windows en process.h. MinGW trae las dos
 * cosas, asi que se incluyen las dos y el que no exista no molesta porque se
 *Compila esto en los tres sistemas. */
#ifdef _WIN32
#include <process.h>
#else
#include <unistd.h>
#endif

/* ------------------------------------------------------------------ memoria */

void error(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	fputs("direkt-bsp: ", stderr);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc('\n', stderr);
	exit(1);
}

void *xmalloc(size_t n)
{
	void *p = malloc(n ? n : 1);
	if (!p)
		error("sin memoria (%zu bytes)", n);
	return p;
}

void *xcalloc(size_t n, size_t size)
{
	void *p = calloc(n ? n : 1, size ? size : 1);
	if (!p)
		error("sin memoria (%zu x %zu bytes)", n, size);
	return p;
}

void *xrealloc(void *p, size_t n)
{
	void *q = realloc(p, n ? n : 1);
	if (!q)
		error("sin memoria (%zu bytes)", n);
	return q;
}

char *xstrdup(const char *s)
{
	size_t n = strlen(s) + 1;
	char *p = xmalloc(n);
	memcpy(p, s, n);
	return p;
}

/* ------------------------------------------------------------------ vectores */

float VectorDot(const vec3_t a, const vec3_t b)
{
	return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

void VectorSubtract(const vec3_t a, const vec3_t b, vec3_t out)
{
	out[0] = a[0] - b[0];
	out[1] = a[1] - b[1];
	out[2] = a[2] - b[2];
}

void VectorAdd(const vec3_t a, const vec3_t b, vec3_t out)
{
	out[0] = a[0] + b[0];
	out[1] = a[1] + b[1];
	out[2] = a[2] + b[2];
}

void VectorScale(const vec3_t a, float s, vec3_t out)
{
	out[0] = a[0] * s;
	out[1] = a[1] * s;
	out[2] = a[2] * s;
}

void VectorCopy(const vec3_t a, vec3_t out)
{
	out[0] = a[0];
	out[1] = a[1];
	out[2] = a[2];
}

void VectorMA(const vec3_t a, float s, const vec3_t b, vec3_t out)
{
	out[0] = a[0] + b[0] * s;
	out[1] = a[1] + b[1] * s;
	out[2] = a[2] + b[2] * s;
}

void CrossProduct(const vec3_t a, const vec3_t b, vec3_t out)
{
	out[0] = a[1] * b[2] - a[2] * b[1];
	out[1] = a[2] * b[0] - a[0] * b[2];
	out[2] = a[0] * b[1] - a[1] * b[0];
}

float VectorLength(const vec3_t a)
{
	return sqrtf(a[0] * a[0] + a[1] * a[1] + a[2] * a[2]);
}

void VectorNormalize(vec3_t a)
{
	float len = VectorLength(a);
	if (len == 0.0f) {
		a[0] = a[1] = a[2] = 0.0f;
		return;
	}
	len = 1.0f / len;
	a[0] *= len;
	a[1] *= len;
	a[2] *= len;
}

/* ------------------------------------------------------------------ planos */

plane_t plane_from_points(vec3_t a, vec3_t b, vec3_t c)
{
	plane_t p;
	vec3_t v1, v2;

	VectorSubtract(b, a, v1);
	VectorSubtract(c, a, v2);
	CrossProduct(v1, v2, p.normal);
	VectorNormalize(p.normal);

	/* Si los tres puntos eran colineales la normal es 0 y el plano no vale.
	 * El llamador deberia haber comprobado que la cara tiene area. */
	p.dist = VectorDot(p.normal, a);
	return p;
}

void plane_from_winding(winding_t *w, plane_t *p)
{
	/* Tres puntos son el minimo para que haya plano. Sin esta comprobacion se
	 * leerian points[1] y points[2] de un winding mas corto, que es memoria
	 * ajena. El plano sale nulo y quien lo use lo detecta (el parser, que
	 * exige 3 puntos por cara, nunca llega aqui; el compilador de caras si
	 * puede toparse con un winding degenerado). */
	if (w->numpoints < 3) {
		p->normal[0] = p->normal[1] = p->normal[2] = 0.0f;
		p->dist = 0.0f;
		return;
	}
	*p = plane_from_points(w->points[0], w->points[1], w->points[2]);
}

float plane_distance(plane_t *p, vec3_t point)
{
	return VectorDot(p->normal, point) - p->dist;
}

/* ------------------------------------------------------------------ winding */

winding_t *winding_new(int numpoints)
{
	winding_t *w;
	/* points[] es un array flexible: se reservan exactamente numpoints. Un
	 * winding de menos de 3 puntos no tiene plano, pero se admiten (con 3) para
	 * que ningun llamante tenga que comprobarlo antes de escribir. */
	if (numpoints < 3)
		numpoints = 3;
	w = xmalloc(sizeof(winding_t) + sizeof(vec3_t) * (size_t)numpoints);
	w->next = NULL;
	w->numpoints = numpoints;
	return w;
}

winding_t *winding_copy(winding_t *w)
{
	winding_t *c;
	if (!w)
		return NULL;
	c = winding_new(w->numpoints);
	memcpy(c->points, w->points, sizeof(vec3_t) * w->numpoints);
	return c;
}

winding_t *winding_reverse(winding_t *w)
{
	winding_t *r;
	int i;
	if (!w)
		return NULL;
	r = winding_new(w->numpoints);
	for (i = 0; i < w->numpoints; i++)
		VectorCopy(w->points[w->numpoints - 1 - i], r->points[i]);
	return r;
}

void winding_free(winding_t *w)
{
	winding_t *next;
	while (w) {
		next = w->next;
		free(w);
		w = next;
	}
}

float winding_area(winding_t *w)
{
	vec3_t total = {0, 0, 0};
	vec3_t v1, v2, cross;
	int i;

	for (i = 2; i < w->numpoints; i++) {
		VectorSubtract(w->points[0], w->points[i - 2], v1);
		VectorSubtract(w->points[0], w->points[i - 1], v2);
		CrossProduct(v1, v2, cross);
		VectorAdd(total, cross, total);
	}
	return VectorLength(total) * 0.5f;
}

void winding_bounds(winding_t *w, vec3_t mins, vec3_t maxs)
{
	int i;
	if (w->numpoints < 1) {
		mins[0] = mins[1] = mins[2] = 0;
		maxs[0] = maxs[1] = maxs[2] = 0;
		return;
	}
	VectorCopy(w->points[0], mins);
	VectorCopy(w->points[0], maxs);
	for (i = 1; i < w->numpoints; i++) {
		int j;
		for (j = 0; j < 3; j++) {
			if (w->points[i][j] < mins[j])
				mins[j] = w->points[i][j];
			if (w->points[i][j] > maxs[j])
				maxs[j] = w->points[i][j];
		}
	}
}

/* ------------------------------------------------------------------ brush */

brush_t *brush_new(void)
{
	brush_t *b = xcalloc(1, sizeof(brush_t));
	b->modelindex = -1;
	return b;
}

/* El array de caras crece por duplicacion. Se llama antes de escribir en
 * b->sides[numsides], y deja a cero lo nuevo para que un winding NULL se
 * distinga de uno sin inicializar. */
side_t *brush_sides_reserve(brush_t *b, int n)
{
	if (n > b->sides_cap) {
		int cap = b->sides_cap ? b->sides_cap * 2 : 8;
		while (cap < n)
			cap *= 2;
		if (cap > BRUSH_MAX_SIDES)
			cap = BRUSH_MAX_SIDES;
		if (n > cap)
			error("una brush llega a %d planos; el tope son %d, y eso ya no es "
			      "una brush sino un agujero en el mapa",
			      n, BRUSH_MAX_SIDES);
		b->sides = xrealloc(b->sides, sizeof(side_t) * (size_t)cap);
		memset(b->sides + b->sides_cap, 0,
		       sizeof(side_t) * (size_t)(cap - b->sides_cap));
		b->sides_cap = cap;
	}
	return b->sides;
}

void brush_free(brush_t *b)
{
	int i;
	if (!b)
		return;
	for (i = 0; i < b->numsides; i++) {
		winding_free(b->sides[i].winding);
		/* El nombre de textura es un xstrdup propio de cada cara. Sin este
		 * free se pierde una cadena por cara y por brush, y el editor, que
		 * crea y destruye brushes sin parar mientras se coloca el mapa, se
		 * comeria la memoria poco a poco. */
		free(b->sides[i].texname);
		b->sides[i].texname = NULL;
	}
	free(b->sides);
	free(b);
}

brush_t *brush_copy(brush_t *b)
{
	brush_t *c;
	int i;

	if (!b)
		return NULL;
	c = brush_new();
	brush_sides_reserve(c, b->numsides);
	for (i = 0; i < b->numsides; i++) {
		c->sides[i] = b->sides[i];
		c->sides[i].winding = winding_copy(b->sides[i].winding);
	}
	c->numsides = b->numsides;
	c->contents = b->contents;
	c->modelindex = b->modelindex;
	return c;
}

void brush_add_winding(brush_t *b, vec3_t normal, float dist, winding_t *w)
{
	side_t *s;

	brush_sides_reserve(b, b->numsides + 1);
	s = &b->sides[b->numsides];
	s->plane.normal[0] = normal[0];
	s->plane.normal[1] = normal[1];
	s->plane.normal[2] = normal[2];
	s->plane.dist = dist;
	s->winding = w;
	b->numsides++;
}

int brush_is_inside(brush_t *b, plane_t *p, float epsilon)
{
	int i;
	for (i = 0; i < b->numsides; i++) {
		if (!b->sides[i].winding)
			continue;
		if (plane_distance(p, b->sides[i].winding->points[0]) > epsilon)
			return 0; /* hay un punto fuera: la brush cruza el plano */
	}
	return 1;
}

void brush_bounds(brush_t *b, vec3_t mins, vec3_t maxs)
{
	int i, j, seen = 0;
	vec3_t smins, smaxs;

	for (i = 0; i < b->numsides; i++) {
		if (!b->sides[i].winding)
			continue;
		winding_bounds(b->sides[i].winding, smins, smaxs);
		if (!seen) {
			VectorCopy(smins, mins);
			VectorCopy(smaxs, maxs);
			seen = 1;
		} else {
			for (j = 0; j < 3; j++) {
				if (smins[j] < mins[j])
					mins[j] = smins[j];
				if (smaxs[j] > maxs[j])
					maxs[j] = smaxs[j];
			}
		}
	}
	if (!seen) {
		for (j = 0; j < 3; j++)
			mins[j] = maxs[j] = 0;
	}
}

/* Crea un fichero temporal y deja la ruta en buf, que tiene que tener sitio
 * para TMP_PATH_MAX. Devuelve 1 si se pudo, 0 si no.
 *
 * Sustituye a mkstemp con "/tmp/direkt-XXXXXX", que solo funciona en Linux: en
 * macOS /tmp existe pero mkstemp puede faltar segun como se compile, y en
 * Windows no hay /tmp. Ahi las pruebas del editor fallaban al releer un
 * documento y al compilar un mapa, porque los temporales nunca se creaban.
 *
 * El nombre lleva el pid y un contador, de modo que dos procesos a la vez, o
 * dos llamadas seguidas en el mismo, no se pisan. Se abre en modo "w+b", que
 * crea o vacia, asi que aunque el nombre existiera no heredaria contenido
 * ajeno. */
int temp_file(char *buf, size_t n, const char *tag)
{
	const char *dir = NULL;
	const char *env;
	static unsigned counter;
	FILE *f;
	int intento;
	int last_errno = 0;

	/* El directorio temporal se llama distinto segun el sistema: TMPDIR en
	 * Unix, TEMP y TMP en Windows. Los tres se miran siempre, en cualquier
	 * sistema: son llamadas a getenv y no pasa nada si no existen.
	 *
	 * Se prueban en orden y se va con el primero que exista de verdad. Antes de
	 * usar el que aparezca en el entorno, se comprueba con stat que sea un
	 * directorio: en Windows la variable suele estar puesta pero en maquinas
	 * raras apunta a algo que no existe, y fopen ahi falla sin motivo claro. */
	static const char *const dirs[] = {"TMPDIR", "TEMP", "TMP"};
	struct stat st;
	size_t i;

	for (i = 0; i < sizeof(dirs) / sizeof(dirs[0]); i++) {
		env = getenv(dirs[i]);
		if (env && *env && stat(env, &st) == 0 && S_ISDIR(st.st_mode))
			dir = env;
	}
#ifdef P_tmpdir
	if (!dir && stat(P_tmpdir, &st) == 0 && S_ISDIR(st.st_mode))
		dir = P_tmpdir;
#endif
	if (!dir)
		dir = ".";
	/* Se prueban varios porque el nombre puede existir ya, aunque lo normal es
	 * que el pid bastara. */
	for (intento = 0; intento < 64; intento++) {
		unsigned n2 = (unsigned)(size_t)getpid() * 2654435761u + counter++ + (unsigned)intento;
		snprintf(buf, n, "%s/direkt-%s-%d-%u.tmp", dir, tag, (int)getpid(), n2 % 100000u);
		f = fopen(buf, "w+b");
		if (f) {
			fclose(f);
			return 1;
		}
		last_errno = errno;
	}
	/* Se deja dicho por que, que un temporal que no se puede crear sin
	 * explicación es un fallo que no se puede arreglar a ciegas. */
	fprintf(stderr, "temp_file: no se pudo crear nada en '%s': %s\n",
	        dir, strerror(last_errno));
	return 0;
}
