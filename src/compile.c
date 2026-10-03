/* direkt-bsp -- construccion del arbol BSP y de las caras.
 *
 * GPL-2.0, ver LICENSE en la raiz del repositorio.
 *
 * Lo que decide el resultado, y que conviene no perder de vista:
 *
 *  - El indice de plano de un nodo NO lleva bit de signo. Cuando el arbol
 *    necesita la cara negativa de un plano, ese plano se registra aparte con la
 *    normal y la distancia negadas. Es la convencion de Darkplaces/ericw; el
 *    motor aborta si encuentra un planenum negativo (Mod_LoadClipnodes).
 *  - children[0] es el lado d > 0. El motor no lo comprueba: si el plano esta
 *    invertido, el mapa dibuja del reves y colisiona del reves.
 *  - La hoja 0 es la solida y el nodo 0 es la raiz, porque Mod_PointInLeaf
 *    arranca en el nodo 0 y SV_TruePointContents pasa un 0 fijo.
 */

#define _GNU_SOURCE
#include "direktbsp.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define ON_EPSILON 0.1f
#define MAX_DEPTH 512

/* ------------------------------------------------------------------ planos */

static plane_t *planes;
static int numplanes;

static int find_or_add_plane(plane_t *p)
{
	int i;
	for (i = 0; i < numplanes; i++) {
		if (fabsf(planes[i].dist - p->dist) > 0.01f)
			continue;
		if (fabsf(planes[i].normal[0] - p->normal[0]) > 0.001f)
			continue;
		if (fabsf(planes[i].normal[1] - p->normal[1]) > 0.001f)
			continue;
		if (fabsf(planes[i].normal[2] - p->normal[2]) > 0.001f)
			continue;
		return i;
	}
	planes = xrealloc(planes, sizeof(plane_t) * (size_t)(numplanes + 1));
	planes[numplanes] = *p;
	return numplanes++;
}

int find_or_add_plane_public(plane_t *p)
{
	return find_or_add_plane(p);
}

static plane_t opposite_plane(plane_t *p)
{
	plane_t o;
	o.normal[0] = -p->normal[0];
	o.normal[1] = -p->normal[1];
	o.normal[2] = -p->normal[2];
	o.dist = -p->dist;
	return o;
}

/* ------------------------------------------------------------------ texturas */

static char **texnames;
static int numtexnames;

static int find_or_add_texname(const char *name)
{
	int i;
	for (i = 0; i < numtexnames; i++)
		if (strcmp(texnames[i], name) == 0)
			return i;
	texnames = xrealloc(texnames, sizeof(char *) * (size_t)(numtexnames + 1));
	texnames[numtexnames] = xstrdup(name);
	return numtexnames++;
}

/* Ejes base de la textura segun la normal de la cara: se toma el eje dominante
 * y se usan los otros dos, con el signo del plano para que el techo no salga
 * espejado respecto al suelo. */
void brush_side_axes(const side_t *side, const plane_t *p, vec3_t xv, vec3_t yv)
{
	int best = 0, i, k;
	float bestval = 0.0f, val;

	for (i = 0; i < 3; i++) {
		val = fabsf(p->normal[i]);
		if (val > bestval) {
			bestval = val;
			best = i;
		}
	}

	memset(xv, 0, sizeof(vec3_t));
	memset(yv, 0, sizeof(vec3_t));

	if (best == 0) {
		xv[1] = -1.0f;
		yv[2] = -1.0f;
	} else if (best == 1) {
		xv[2] = 1.0f;
		yv[0] = -1.0f;
	} else {
		xv[0] = 1.0f;
		yv[1] = 1.0f;
	}

	if (p->normal[best] < 0.0f)
		for (k = 0; k < 3; k++) {
			xv[k] = -xv[k];
			yv[k] = -yv[k];
		}

	{
		float rot = side->texrotate * (float)M_PI / 180.0f;
		float c = cosf(rot), s = sinf(rot);
		vec3_t rx, ry;
		int k;
		for (k = 0; k < 3; k++) {
			rx[k] = xv[k] * c - yv[k] * s;
			ry[k] = xv[k] * s + yv[k] * c;
		}
		for (k = 0; k < 3; k++) {
			xv[k] = rx[k] * side->texscale[0] + side->texshift[0];
			yv[k] = ry[k] * side->texscale[1] + side->texshift[1];
		}
	}
}

static texinfo_t *texinfos;
static int numtexinfos;

static int add_texinfo(side_t *side, plane_t *p)
{
	texinfo_t ti;
	int i, miptex;
	vec3_t xv, yv;

	ti.flags = 0;
	ti.miptex = miptex = find_or_add_texname(side->texname ? side->texname : "notex");

	brush_side_axes(side, p, xv, yv);

	ti.vecs[0][0] = xv[0]; ti.vecs[0][1] = xv[1]; ti.vecs[0][2] = xv[2]; ti.vecs[0][3] = 0.0f;
	ti.vecs[1][0] = yv[0]; ti.vecs[1][1] = yv[1]; ti.vecs[1][2] = yv[2]; ti.vecs[1][3] = 0.0f;
	for (i = 0; i < numtexinfos; i++) {
		texinfo_t *o = &texinfos[i];
		if (o->miptex != ti.miptex)
			continue;
		if (fabsf(o->vecs[0][0] - ti.vecs[0][0]) > 0.001f ||
		    fabsf(o->vecs[0][1] - ti.vecs[0][1]) > 0.001f ||
		    fabsf(o->vecs[0][2] - ti.vecs[0][2]) > 0.001f)
			continue;
		if (fabsf(o->vecs[1][0] - ti.vecs[1][0]) > 0.001f ||
		    fabsf(o->vecs[1][1] - ti.vecs[1][1]) > 0.001f ||
		    fabsf(o->vecs[1][2] - ti.vecs[1][2]) > 0.001f)
			continue;
		return i;
	}

	texinfos = xrealloc(texinfos, sizeof(texinfo_t) * (size_t)(numtexinfos + 1));
	texinfos[numtexinfos] = ti;
	return numtexinfos++;
}

/* ------------------------------------------------------------------ estado */

static bsp_t bsp;
static brush_t **leafbrushes; /* brushes que han caido en cada hoja */

/* ------------------------------------------------------------------ caras */

/* Crea una cara y la deja apuntada a la hoja. La cara hereda la orientacion del
 * winding, que ya mira hacia fuera de la brush, asi que va de frente (side 0). */
static int add_surface(plane_t *plane, winding_t *winding, int texinfo, int leaf)
{
	surf_t *s;
	bsp.surfs = xrealloc(bsp.surfs, sizeof(surf_t) * (size_t)(bsp.numsurfs + 1));
	s = &bsp.surfs[bsp.numsurfs];
	memset(s, 0, sizeof(surf_t));
	s->plane = *plane;
	s->winding = winding_copy(winding);
	s->texinfo = texinfo;
	s->leaf = leaf;
	s->side = 0;
	/* El indice de plano se resuelve aqui, que es donde esta el registro. El
	 * motor lo lee como indice directo: no admite bit de signo, asi que el
	 * plano opuesto se registra por separado cuando hace falta. */
	s->planenum = find_or_add_plane(&s->plane);
	return bsp.numsurfs++;
}

/* ------------------------------------------------------------------ arbol */

/* Crea una hoja con un contents dado y la devuelve como indice. */
static int make_leaf(int contents, brush_t *brushes)
{
	leaf_t *l;
	int i;

	bsp.leafs = xrealloc(bsp.leafs, sizeof(leaf_t) * (size_t)(bsp.numleafs + 1));
	l = &bsp.leafs[bsp.numleafs];
	memset(l, 0, sizeof(leaf_t));
	l->contents = contents;
	/* El lump VIS va vacio, que el motor lee como "todo visible". Entonces
	 * TODAS las hojas tienen que llevar -1: con visdata nulo, cualquier visofs
	 * >= 0 seria NULL+algo. */
	l->visofs = -1;

	leafbrushes = xrealloc(leafbrushes, sizeof(brush_t *) * (size_t)(bsp.numleafs + 1));
	leafbrushes[bsp.numleafs] = brushes;

	/* Los limites de la hoja: la caja de las brushes que la llenan. Si esta
	 * vacia, un punto neutro. */
	for (i = 0; i < 3; i++) {
		l->mins[i] = 0;
		l->maxs[i] = 0;
	}
	if (brushes) {
		vec3_t mins, maxs;
		brush_bounds(brushes, mins, maxs);
		for (i = 0; i < 3; i++) {
			l->mins[i] = (int)floorf(mins[i]);
			l->maxs[i] = (int)ceilf(maxs[i]);
		}
	}

	return bsp.numleafs++;
}

static int make_node(int planenum)
{
	bsp.nodes = xrealloc(bsp.nodes, sizeof(node_t) * (size_t)(bsp.numnodes + 1));
	memset(&bsp.nodes[bsp.numnodes], 0, sizeof(node_t));
	bsp.nodes[bsp.numnodes].planenum = planenum;
	return bsp.numnodes++;
}

/* La brush cae entera en el lado negativo (d < 0) del plano. */
static int brush_inside(brush_t *b, plane_t *p)
{
	int i, k;
	for (i = 0; i < b->numsides; i++) {
		winding_t *w = b->sides[i].winding;
		if (!w)
			continue;
		for (k = 0; k < w->numpoints; k++)
			if (plane_distance(p, w->points[k]) > ON_EPSILON)
				return 0;
	}
	return 1;
}

/* Elige un plano que separe de verdad. Se descartan los que dejan todas las
 * brushes de un mismo lado, porque con esos el arbol no progresa. Los planos ya
 * usados en el camino se descartan tambien, que es lo que garantiza que la
 * recursion termine. */
static int choose_split_plane(brush_t *brushes, const int *used, int numused,
                              plane_t *out)
{
	brush_t *b;
	int i, u;

	for (b = brushes; b; b = b->next) {
		for (i = 0; i < b->numsides; i++) {
			plane_t p = b->sides[i].plane;
			plane_t neg = opposite_plane(&p);
			brush_t *it;
			int sep = 0;
			int yausado = 0;

			for (u = 0; u < numused; u++) {
				if (fabsf(planes[used[u]].normal[0] - p.normal[0]) < 0.001f &&
				    fabsf(planes[used[u]].normal[1] - p.normal[1]) < 0.001f &&
				    fabsf(planes[used[u]].normal[2] - p.normal[2]) < 0.001f &&
				    fabsf(planes[used[u]].dist - p.dist) < 0.01f)
					yausado = 1;
			}
			if (yausado)
				continue;

			for (it = brushes; it; it = it->next) {
				if (brush_inside(it, &p))
					sep |= 1;
				if (brush_inside(it, &neg))
					sep |= 2;
			}
			if (sep == 3) {
				*out = p;
				return 1;
			}
		}
	}
	return 0;
}

/* ------------------------------------------------------------------ region
 *
 * La region de una hoja es el POLIEDRO convexo que sale de intersectar los planos
 * del camino desde la raiz. Antes se llevaba solo su caja envolvente, y eso era
 * la raiz de dos cosas malas a la vez:
 *
 *   - El contenido de la hoja se decidia con la caja, que es mas grande que la
 *     region, asi que una hoja dentro de un muro salia EMPTY.
 *   - El verificador comparaba la region con las brushes usando la caja, y como
 *     la caja siempre es mayor que la region, nunca cuadraba.
 *
 * Con el poliedro de verdad las dos cosas son exactas.
 *
 * IMPORTANTE: la region se guarda como una lista de CARAS, cada una con su
 * ciclo de vertices, y no como un simple grupo de vertices. Recortar un grupo
 * de vertices dando por hecho que estan en ciclo no funciona: la caja inicial
 * se puede escribir en cualquier orden, y si se recorre como si fuera un ciclo
 * se inventan aristas (diagonales) y se pierden las de verdad. Con las caras
 * cada arista existe una vez, y el recorte es el de Sutherland-Hodgoman, que
 * es exacto para poliedros convexos.
 */

#define REGION_MAXF 40
#define REGION_MAXP 20

typedef struct {
	vec3_t p[REGION_MAXP];
	int n;
} region_face_t;

typedef struct {
	region_face_t f[REGION_MAXF];
	int nf;
} region_t;

static void region_de_caja(region_t *r, const vec3_t mins, const vec3_t maxs)
{
	vec3_t *c;
	int i;
	r->nf = 0;
	/* Las 6 caras de la caja, cada una en antihorario visto desde fuera. */
	for (i = 0; i < 6; i++) {
		region_face_t *f = &r->f[r->nf++];
		int a0, a1, a2, a3, k;
		switch (i) {
		case 0: a0 = 0; a1 = 1; a2 = 2; a3 = 3; break; /* -z */
		case 1: a0 = 4; a1 = 7; a2 = 6; a3 = 5; break; /* +z */
		case 2: a0 = 0; a1 = 4; a2 = 5; a3 = 1; break; /* -y */
		case 3: a0 = 2; a1 = 6; a2 = 7; a3 = 3; break; /* +y */
		case 4: a0 = 0; a1 = 3; a2 = 7; a3 = 4; break; /* -x */
		default: a0 = 1; a1 = 5; a2 = 6; a3 = 2; break; /* +x */
		}
		f->n = 4;
		f->p[0][0] = (a0 & 1) ? maxs[0] : mins[0];
		f->p[0][1] = (a0 & 2) ? maxs[1] : mins[1];
		f->p[0][2] = (a0 & 4) ? maxs[2] : mins[2];
		f->p[1][0] = (a1 & 1) ? maxs[0] : mins[0];
		f->p[1][1] = (a1 & 2) ? maxs[1] : mins[1];
		f->p[1][2] = (a1 & 4) ? maxs[2] : mins[2];
		f->p[2][0] = (a2 & 1) ? maxs[0] : mins[0];
		f->p[2][1] = (a2 & 2) ? maxs[1] : mins[1];
		f->p[2][2] = (a2 & 4) ? maxs[2] : mins[2];
		f->p[3][0] = (a3 & 1) ? maxs[0] : mins[0];
		f->p[3][1] = (a3 & 2) ? maxs[1] : mins[1];
		f->p[3][2] = (a3 & 4) ? maxs[2] : mins[2];
		(void)c;
		(void)k;
	}
}

static float pd(const plane_t *p, const vec3_t v)
{
	return p->normal[0] * v[0] + p->normal[1] * v[1] + p->normal[2] * v[2] -
	       p->dist;
}

/* Recorta por el semiplano n.p <= dist. Devuelve 0 si la region se queda vacia.
 *
 * El recorte de cada cara es Sutherland-Hodgoman. Los puntos donde una arista
 * cruza el plano se guardan aparte y con ellos se monta la cara nueva (el
 * "tapón"), ordenandolos por angulo alrededor del centro: como el poliedro es
 * convexo, eso sale bien. */
static int region_recorta(region_t *r, const plane_t *pl)
{
	region_t out;
	vec3_t corte[REGION_MAXP * 2];
	int ncorte = 0, i, k, tapon = 0;

	memset(&out, 0, sizeof(out));
	for (i = 0; i < r->nf; i++) {
		region_face_t nf;
		const region_face_t *f = &r->f[i];
		nf.n = 0;
		for (k = 0; k < f->n; k++) {
			int k2 = (k + 1) % f->n;
			float d1 = pd(pl, f->p[k]);
			float d2 = pd(pl, f->p[k2]);
			if (d1 <= 0.0f) {
				if (nf.n < REGION_MAXP)
					VectorCopy(f->p[k], nf.p[nf.n++]);
			}
			if ((d1 > 0.0f && d2 < 0.0f) || (d1 < 0.0f && d2 > 0.0f)) {
				float t = d1 / (d1 - d2);
				vec3_t q;
				int j;
				for (j = 0; j < 3; j++)
					q[j] = f->p[k][j] + t * (f->p[k2][j] - f->p[k][j]);
				if (nf.n < REGION_MAXP)
					VectorCopy(q, nf.p[nf.n++]);
				if (ncorte < REGION_MAXP * 2)
					VectorCopy(q, corte[ncorte++]);
			}
		}
		if (nf.n >= 3 && out.nf < REGION_MAXF) {
			out.f[out.nf++] = nf;
			tapon = 1;
		}
	}
	if (ncorte >= 3 && out.nf < REGION_MAXF) {
		/* El tapón: puntos sobre el plano, ordenados por angulo. */
		region_face_t cap;
		vec3_t centro;
		int j;
		cap.n = 0;
		for (j = 0; j < 3; j++)
			centro[j] = 0.0f;
		for (j = 0; j < ncorte; j++)
			for (k = 0; k < 3; k++)
				centro[k] += corte[j][k];
		for (j = 0; j < ncorte; j++)
			for (k = 0; k < 3; k++)
				centro[k] /= (float)ncorte;
		/* Elegir dos ejes perpendiculares a la normal del plano. */
		{
			vec3_t e1, e2;
			if (fabsf(pl->normal[0]) > fabsf(pl->normal[2])) {
				e1[0] = -pl->normal[1]; e1[1] = pl->normal[0]; e1[2] = 0.0f;
			} else {
				e1[0] = 0.0f; e1[1] = -pl->normal[2]; e1[2] = pl->normal[1];
			}
			e1[0] += pl->normal[0] * 0.0f;
			{
				float l = (float)sqrt(e1[0]*e1[0] + e1[1]*e1[1] + e1[2]*e1[2]);
				if (l < 1e-6f)
					l = 1.0f;
				e1[0] /= l; e1[1] /= l; e1[2] /= l;
			}
			e2[0] = pl->normal[1] * e1[2] - pl->normal[2] * e1[1];
			e2[1] = pl->normal[2] * e1[0] - pl->normal[0] * e1[2];
			e2[2] = pl->normal[0] * e1[1] - pl->normal[1] * e1[0];
			/* Ordenar por angulo con una insercion simple: son pocos. */
			for (j = 1; j < ncorte; j++) {
				vec3_t pv;
				/* vec3_t es un array: no se puede inicializar desde otro
				 * array, hay que copiar elemento a elemento. */
				float aj, bj;
				for (k = 0; k < 3; k++)
					pv[k] = corte[j][k];
				aj = pv[0]*e1[0] + pv[1]*e1[1] + pv[2]*e1[2];
				bj = pv[0]*e2[0] + pv[1]*e2[1] + pv[2]*e2[2];
				int q = j - 1;
				float an, bn;
				while (q >= 0) {
					an = cap.p[q][0]*e1[0] + cap.p[q][1]*e1[1] + cap.p[q][2]*e1[2];
					bn = cap.p[q][0]*e2[0] + cap.p[q][1]*e2[1] + cap.p[q][2]*e2[2];
					if (an * bj - bn * aj >= 0.0f)
						break;
					VectorCopy(cap.p[q], cap.p[q + 1]);
					q--;
				}
				for (k = 0; k < 3; k++)
					cap.p[q + 1][k] = pv[k];
			}
			cap.n = ncorte;
			if (cap.n > REGION_MAXP)
				cap.n = REGION_MAXP;
			out.f[out.nf++] = cap;
		}
	}
	if (!tapon || out.nf == 0) {
		/* La region se queda VACIA, no como estaba. Si se deja como estaba, el
		 * que llama cree que el recorte ha ido bien y le pasa una region que en
		 * realidad no es de este lado del plano, con las brushes de este lado
		 * dentro. De ahi salen hojas con la region a medias, que es justo lo
		 * que el verificador buscaba. */
		r->nf = 0;
		return 0;
	}
	*r = out;
	return 1;
}

static int region_vacia(const region_t *r)
{
	return r->nf == 0;
}

/* Recorre todos los vertices de la region. Devuelve cuantos hay. */
static int region_vert(const region_t *r, vec3_t *v, int max)
{
	int n = 0, i, k;
	for (i = 0; i < r->nf; i++)
		for (k = 0; k < r->f[i].n && n < max; k++)
			VectorCopy(r->f[i].p[k], v[n++]);
	return n;
}

static void region_caja(const region_t *r, vec3_t mins, vec3_t maxs)
{
	vec3_t v[REGION_MAXF * REGION_MAXP];
	int n = region_vert(r, v, (int)(sizeof(v) / sizeof(v[0]))), i, k;
	for (k = 0; k < 3; k++) {
		mins[k] = 1e30f;
		maxs[k] = -1e30f;
	}
	for (i = 0; i < n; i++)
		for (k = 0; k < 3; k++) {
			if (v[i][k] < mins[k]) mins[k] = v[i][k];
			if (v[i][k] > maxs[k]) maxs[k] = v[i][k];
		}
}

/* Elige el plano con el que partir, o devuelve 0 si ya no hay ninguno que
 * recorte la region.
 *
 * Un plano solo sirve si deja region a los dos lados. Se mide con los vertices
 * de la region, no con su caja envolvente: la caja puede cruzar el plano
 * aunque la region no lo haga, y entonces se partiria por un plano que no
 * divide nada, y el arbol se descontrola. */
static int elegir_plano(brush_t *brushes, int *used, int numused,
                       const region_t *region, plane_t *out)
{
	brush_t *b;
	vec3_t v[REGION_MAXF * REGION_MAXP];
	int i, k, nv;

	if (choose_split_plane(brushes, used, numused, out))
		return 1;

	nv = region_vert(region, v, (int)(sizeof(v) / sizeof(v[0])));

	for (b = brushes; b; b = b->next) {
		for (i = 0; i < b->numsides; i++) {
			plane_t p = b->sides[i].plane;
			int tiene_pos = 0, tiene_neg = 0;
			for (k = 0; k < nv; k++) {
				float d = pd(&p, v[k]);
				if (d > 0.01f)
					tiene_pos = 1;
				else if (d < -0.01f)
					tiene_neg = 1;
			}
			if (tiene_pos && tiene_neg) {
				*out = p;
				return 1;
			}
		}
	}
	return 0;
}

/* ¿Esta la region entera dentro de esta brush?
 *
 * Esto es lo que decide si una hoja es solida, y no "tiene alguna brush
 * solida". La diferencia es enorme: el arbol parte por planos de brush, asi
 * que la region de la habitacion abierta llega a la hoja junto con los
 * fragmentos de los muros que la rodean. Marcandola solida por tener brushes
 * al lado, la camara caia en una hoja CONTENTS_SOLID y el motor no dibuja
 * NADA del mundo: se ve el HUD y el mapa no. */
/* La region entera esta FUERA de la brush.
 *
 * Tambien es exacto con los vertices: la region es convexa, asi que si un
 * semiplano deja todos sus vertices fuera, la region entera esta fuera. Y
 * esto es lo que hacia falta para el verificador: una region puede tocar una
 * brush sin estar dentro de ella, y eso no es ningun fallo (la hoja es de aire
 * y la brush esta al lado). Lo que es un fallo es la region partida: ni
 * entera dentro ni entera fuera. */
static int region_fuera_de(const brush_t *b, const region_t *r)
{
	vec3_t v[REGION_MAXF * REGION_MAXP];
	int nv = region_vert(r, v, (int)(sizeof(v) / sizeof(v[0]))), i, k;
	for (i = 0; i < b->numsides; i++) {
		plane_t pl = b->sides[i].plane;
		int todos_fuera = 1;
		for (k = 0; k < nv && todos_fuera; k++)
			if (pd(&pl, v[k]) < 0.0f)
				todos_fuera = 0;
		if (todos_fuera)
			return 1;
	}
	return 0;
}

/* La region entera esta dentro de la brush.
 *
 * Con los vertices de la region esto es exacto: region y brush son convexas, y
 * si todos los vertices de la region cumplen un semiplano, la region entera lo
 * cumple. Con la caja envolvente no lo era, y por eso las hojas dentro de un
 * muro salian vacias. */
static int region_dentro(const brush_t *b, const region_t *r)
{
	vec3_t v[REGION_MAXF * REGION_MAXP];
	int nv = region_vert(r, v, (int)(sizeof(v) / sizeof(v[0]))), i, k;
	for (i = 0; i < b->numsides; i++) {
		plane_t pl = b->sides[i].plane;
		for (k = 0; k < nv; k++)
			if (pd(&pl, v[k]) > 0.0f)
				return 0;
	}
	return 1;
}

/* Un punto esta dentro de una brush convexa si satisface todos sus planos.
 *
 * Hace falta porque la region de una hoja NO es una caja: es el poliedro
 * convexo que sale de intersectar los planos del camino, y aquí solo se
 * lleva su caja envolvente. Esa caja es mas grande que la region, asi que
 * un test de caja puede decir "la region no cabe dentro de la brush" cuando
 * en realidad si cabe. */
/* Un punto de dentro de la region. El centro de la caja envolvente cae
 * dentro de la region en todos los casos de un arbol de planos, que es lo que
 * se construye aqui: en cada nodo se recorta la caja por un eje y el centro
 * solo se sale de la region si la region es degenerada. */
/* El contenido de una hoja: SOLID si la region esta dentro de alguna brush
 * solida, EMPTY si no. Lo decide la REGION y no la lista de brushes. */
static int contents_hoja(brush_t *brushes, const region_t *r)
{
	brush_t *it;
	if (!brushes)
		return CONTENTS_EMPTY;
	for (it = brushes; it; it = it->next)
		if (it->contents == CONTENTS_SOLID && region_dentro(it, r))
			return CONTENTS_SOLID;
	return CONTENTS_EMPTY;
}

static int build_tree(brush_t *brushes, int *used, int numused, int depth,
                      const region_t *region)
{
	plane_t split;
	int planenum, front, back, c0;
	brush_t *fl = NULL, *bt = NULL, *tf = NULL, *tb = NULL;
	brush_t *b, *next;

	if (depth > MAX_DEPTH) {
		fprintf(stderr, "direkt-bsp: aviso, profundidad maxima de nodo "
		                "alcanzada; la hoja se queda con brushes sin cortar\n");
		return -(make_leaf(CONTENTS_EMPTY, brushes) + 1);
	}

	/* Hoja si no queda ningun plano que parta la region. El contenido lo decide
	 * la region, no la lista de brushes. */
	if (brushes == NULL || !elegir_plano(brushes, used, numused, region, &split))
		return -(make_leaf(contents_hoja(brushes, region), brushes) + 1);

	planenum = find_or_add_plane(&split);

	for (b = brushes; b; b = next) {
		plane_t neg = opposite_plane(&split);
		next = b->next;
		b->next = NULL;

		if (brush_inside(b, &split)) {
			if (tb)
				tb->next = b;
			else
				bt = b;
			tb = b;
		} else if (brush_inside(b, &neg)) {
			if (tf)
				tf->next = b;
			else
				fl = b;
			tf = b;
		} else {
			brush_t *bf = NULL, *bb = NULL;
			if (brush_split(b, &split, &bf, &bb)) {
				if (bf) {
					if (tf)
						tf->next = bf;
					else
						fl = bf;
					tf = bf;
				}
				if (bb) {
					if (tb)
						tb->next = bb;
					else
						bt = bb;
					tb = bb;
				}
			}
			if (!bf && !bb) {
				/* No se ha podido partir: se queda entera del lado
				 * negativo, que es la eleccion conservadora. */
				if (tb)
					tb->next = b;
				else
					bt = b;
				tb = b;
			}
		}
	}

	/* Si un lado quedo vacio, se le da la vuelta al plano en vez de dejar un nodo
	 * que se apunta a si mismo. Negar el plano intercambia los lados porque
	 * children[0] es d > 0.
	 *
	 * OJO: al voltear hay que voltear `split` Y NO SOLO el indice. El nodo se
	 * guarda con el plano, y las regiones de los dos hijos se recortan con el
	 * plano; si el nodo lleva el opuesto y las regiones están recortadas con el
	 * original, el nodo dice una cosa y sus hijos son la otra. El motor recorre
	 * el arbol con los planos de los nodos, asi que a partir de ahi cualquier
	 * punto caeria en la hoja equivocada: el jugador dentro de una habitacion
	 * en la hoja de un muro, y el mundo sin dibujar.
	 *
	 * Por eso se voltea la variable de la que salen las dos cosas. */
	if (fl == NULL && bt != NULL) {
		plane_t t = split;
		brush_t *tb2;
		split = opposite_plane(&split);
		planenum = find_or_add_plane(&split);
		tb2 = fl;
		fl = bt;
		bt = tb2;
		(void)t;
	}

	used[numused] = planenum;

	c0 = make_node(planenum);
	{
		/* children[0] es el lado POSITIVO del plano (n.p > dist) y
		 * children[1] el negativo, que es por donde el motor baja con t < 0. */
		region_t freg = *region, nreg;
		plane_t neg = opposite_plane(&split);
		int fv, nv;
		region_recorta(&freg, &neg);
		nreg = *region;
		region_recorta(&nreg, &split);
		/* Una region vacia no puede llevar brushes: si las hubiera, el plano
		 * habria demostrado que recortan. Por si acaso, no se las cuelga, para
		 * que una hoja solida no nazca sin region que la sostenga. */
		fv = region_vacia(&freg);
		nv = region_vacia(&nreg);
		front = build_tree(fv ? NULL : fl, used, numused + 1, depth + 1, &freg);
		back = build_tree(nv ? NULL : bt, used, numused + 1, depth + 1, &nreg);
	}
	bsp.nodes[c0].children[0] = front;
	bsp.nodes[c0].children[1] = back;
	return c0;
}

/* Recorre el arbol carrying la region y comprueba el invariante. */
static void verifica_hojas(int ref, const region_t *region, int *malas, int prof)
{
	int hoja = (0xffffffff - ref) & 0xffffffff;
	brush_t *b;

	/* Esto es un diagnostico: si encuentra algo raro, lo dice y sigue en vez de
	 * quedarse parado. Que se pare por un Segmento fuera de rango seria peor
	 * que no comprobar nada. Ojo: el rango se mira DESPUES de distinguir nodo
	 * de hoja, que si no un indice de nodo falso siempre parece fuera de
	 * rango de hoja y la comprobacion no bajaria nunca. */
	/* Un ciclo en el arbol haria que esto no termine. Como es un
	 * diagnostico, se corta al llegar a un tope y se avisa. */
	if (prof > 400) {
		fprintf(stderr, "direkt-bsp:   el arbol es mas profundo de 400: hay un "
		                "ciclo\n");
		(*malas)++;
		return;
	}

	if (ref >= 0) {
		node_t *n;
		if (ref >= bsp.numnodes) {
			fprintf(stderr, "direkt-bsp:   hijo %d fuera de rango (%d nodos)\n",
			        ref, bsp.numnodes);
			(*malas)++;
			return;
		}
		n = &bsp.nodes[ref];
		/* Se usa el array estatico y no bsp.planes: ese puntero solo se
		 * asigna al final de compile_map, y esta comprobacion va antes, asi
		 * que leeria desde NULL. */
		plane_t *p = &planes[n->planenum];
		plane_t neg = opposite_plane(p);
		region_t freg = *region, nreg = *region;

		region_recorta(&freg, &neg);
		region_recorta(&nreg, p);
		verifica_hojas(n->children[0], &freg, malas, prof + 1);
		verifica_hojas(n->children[1], &nreg, malas, prof + 1);
		return;
	}

	if (hoja >= bsp.numleafs) {
		fprintf(stderr, "direkt-bsp:   hoja %d fuera de rango (%d hojas)\n",
		        hoja, bsp.numleafs);
		(*malas)++;
		return;
	}

	/* Hoja: el contenido tiene que ser coherente con la geometria.
	 *
	 * Antes se comparaba la region con las brushes con la caja envolvente, y
	 * como la caja es mas grande que la region, para cualquier brush habia
	 * siempre un plano del que la region no cabia entera ni quedaba entera
	 * fuera: el aviso salia en practicamente todos los mapas, fueran
	 * correctos o no. Con los vertices de la region la comparacion es
	 * exacta y aqui solo se avisa de algo que este mal de verdad. */
	{
		int contenido = contents_hoja(leafbrushes[hoja], region);
		for (b = leafbrushes[hoja]; b; b = b->next) {
			if (b->contents != CONTENTS_SOLID)
				continue;
			if (region_dentro(b, region))
				continue; /* la region cabe dentro: coherente */
			if (region_fuera_de(b, region))
				continue; /* la region no toca la brush: coherente */
			/* Ni dentro ni fuera: la region esta partida por la brush. Eso si
			 * es un fallo, porque el motor no sabe que pintar en una hoja a
			 * medias. Salvo que la hoja haya salido solida, que entonces es
			 * la brush la que manda. */
			if (contenido == CONTENTS_SOLID)
				continue;
			(*malas)++;
			if (*malas <= 3) {
				vec3_t mins, maxs;
				region_caja(region, mins, maxs);
				fprintf(stderr, "direkt-bsp:   hoja %d a medio cortar: la region "
				                "(%.0f %.0f %.0f)-(%.0f %.0f %.0f) pica un solido\n",
				        hoja, mins[0], mins[1], mins[2], maxs[0], maxs[1], maxs[2]);
			}
		}
	}
}

/* ------------------------------------------------------------------ caras por hoja */

/* Una cara por cada lado visible de las brushes que han caido en la hoja. El
 * winding de un lado mira hacia fuera de la brush, o sea hacia el vacio, que es
 * justo desde donde se mira la cara: se emite tal cual.
 *
 * Las marcas de superficie de cada hoja las pone write.c, porque hasta que las
 * caras no tienen edges y surfedges no se puede saber el orden. Aqui solo se
 * generan. */
static void make_faces(void)
{
	int l, i;

	/* No se salta ninguna hoja por su contents. La hoja 0 es el vacio exterior
	 * y no tiene brushes, asi que aqui no produce nada sola. Las hojas con
	 * brushes solidos SI generan caras: sus caras apuntan hacia fuera de la
	 * brush, o sea hacia el hueco de al lado, que es desde donde se ven. Que
	 * se dibujen depende de que esa hoja entre en el PVS, que es cosa del
	 * render, no del compilador. */
	for (l = 0; l < bsp.numleafs; l++) {
		brush_t *b;

		for (b = leafbrushes[l]; b; b = b->next) {
			/* Los triggers se detectan al tocarlos, no se ven. */
			if (b->contents == CONTENTS_EMPTY)
				continue;
			for (i = 0; i < b->numsides; i++) {
				winding_t *w = b->sides[i].winding;
				plane_t p;
				int ti;

				if (!w || w->numpoints < 3)
					continue;
				if (winding_area(w) < 0.01f)
					continue;

				plane_from_winding(w, &p);
				ti = add_texinfo(&b->sides[i], &p);
				add_surface(&p, w, ti, l);
			}
		}
	}
}

/* ------------------------------------------------------------------ entrada */

bsp_t *compile_map(map_t *map)
{
	brush_t *world = NULL, *b;
	entity_t *e;
	int *used;
	int root;
	vec3_t mundo_mins, mundo_maxs;

	memset(&bsp, 0, sizeof(bsp));
	planes = NULL;
	numplanes = 0;
	texnames = NULL;
	numtexnames = 0;
	texinfos = NULL;
	numtexinfos = 0;
	leafbrushes = NULL;

	/* Se reunen las brushes del mundo y de los triggers. Las de los triggers
	 * van con contents EMPTY: estan en el arbol para que se puedan tocar, pero
	 * no se dibujan. Las moviles se dejan fuera: de momento no se compilan.
	 *
	 * Antes se colgaba cada brush de la lista del mundo con ->next, pero eso
	 * rompe las listas del mapa: una brush de una entidad quedaba enlazada a la
	 * siguiente de otra entidad, y al final ni free_map ni el editor podian
	 * recorrerlas sin duplicar o saltar alguna. Aqui se apuntan primero a un
	 * arreglo y la lista del mundo se monta despues desde el arreglo, con lo
	 * cual la pertenencia de cada brush queda clara antes de tocar nada. */
	{
		int cap = 16, n = 0, i;
		brush_t **arr = xmalloc(sizeof(brush_t *) * (size_t)cap);
		brush_t **mov = xmalloc(sizeof(brush_t *) * (size_t)cap);
		int nmov = 0;

		for (e = map->entities; e; e = e->next) {
			for (b = e->brushes; b; b = b->next) {
				if (n >= cap) {
					cap *= 2;
					arr = xrealloc(arr, sizeof(brush_t *) * (size_t)cap);
					mov = xrealloc(mov, sizeof(brush_t *) * (size_t)cap);
				}
				if (b->moving) {
					mov[nmov++] = b;
					continue;
				}
				arr[n++] = b;
			}
		}

		for (i = 0; i < n; i++) {
			arr[i]->next = (i + 1 < n) ? arr[i + 1] : NULL;
			if (i == 0)
				world = arr[i];
		}

		/* Los limites de todo el mundo, que son la region de partida del
		 * arbol. Van un poco abiertos por fuera para que ningun brush quede
		 * justo en el borde, que es donde el reparto por planos se vuelve
		 * delicate. */
		for (i = 0; i < 3; i++) {
			mundo_mins[i] = 1e30f;
			mundo_maxs[i] = -1e30f;
		}
		for (i = 0; i < n; i++) {
			vec3_t bm, bM;
			int k;
			brush_bounds(arr[i], bm, bM);
			for (k = 0; k < 3; k++) {
				if (bm[k] < mundo_mins[k])
					mundo_mins[k] = bm[k];
				if (bM[k] > mundo_maxs[k])
					mundo_maxs[k] = bM[k];
			}
		}
		if (n == 0) {
			for (i = 0; i < 3; i++) {
				mundo_mins[i] = -64.0f;
				mundo_maxs[i] = 64.0f;
			}
		} else {
			for (i = 0; i < 3; i++) {
				mundo_mins[i] -= 16.0f;
				mundo_maxs[i] += 16.0f;
			}
		}

		/* A partir de aqui el compilador es dueno de las brushes del mundo:
		 * build_tree las parte, cuelga las que quedan de las hojas y las
		 * suelta free_bsp. El mapa deja de tenerlas, y asi free_map no las
		 * toca y no hay doble free. Las moviles, que el compilador no usa,
		 * se sueltan aqui porque son suyas todavia. */
		for (i = 0; i < n; i++)
			arr[i] = NULL;
		for (i = 0; i < nmov; i++)
			brush_free(mov[i]);
		for (e = map->entities; e; e = e->next) {
			e->brushes = NULL;
			e->brushes_tail = NULL;
		}
		map->brushes = NULL;
		map->brushes_tail = NULL;
		map->numbrushes = 0;
		free(arr);
		free(mov);
	}

	/* Hoja 0, la solida. El motor la espera ahi. */
	make_leaf(CONTENTS_SOLID, NULL);
	root = make_node(-1);

	/* Submodelo 0: el mundo. Se crea ya porque los clipnodes rellenan su
	 * headnode. */
	bsp.submodels = xcalloc(1, sizeof(submodel_t));
	bsp.numsubmodels = 1;
	memset(bsp.submodels[0].headnode, 0, sizeof(bsp.submodels[0].headnode));
	/* Los limites del submodelo. El motor los usa para el recorte por
	 * frustum: con todos a cero el modelo entero cae fuera de la piramide y
	 * no se dibuja nada. */
	for (int e = 0; e < 3; e++) {
		bsp.submodels[0].mins[e] = mundo_mins[e];
		bsp.submodels[0].maxs[e] = mundo_maxs[e];
	}

	/* Los clipnodes ANTES del arbol del mundo: build_tree parte las brushes y
	 * libera los originales, asi que despues la lista ya no existe y el arbol
	 * de colision se construiria con memoria liberada. */
	build_clipnodes(&bsp, world, map);

	used = xmalloc(sizeof(int) * (size_t)(MAX_DEPTH + 4));
	{
		/* El nodo 0 tiene que ser un nodo de verdad con dos hijos reales: el
		 * motor arranca Mod_PointInLeaf en el nodo 0, y un hijo que se
		 * apuntara al propio nodo 0 seria un ciclo. Se parte por una cara de
		 * la caja del mundo, que siempre existe, y el lado que sobra se deja
		 * como hoja vacia. */
		vec3_t mins, maxs;
		plane_t rp;
		int e;
		float tam;

		brush_bounds(world, mins, maxs);
		memset(&rp.normal, 0, sizeof(vec3_t));
		tam = 0.0f;
		for (e = 0; e < 3; e++) {
			float t = maxs[e] - mins[e];
			if (t > tam) {
				tam = t;
				rp.normal[e] = 1.0f;
			}
		}
		if (rp.normal[0] == 0.0f && rp.normal[1] == 0.0f && rp.normal[2] == 0.0f)
			rp.normal[2] = 1.0f;
		rp.dist = VectorDot(rp.normal, mins);

		/* OJO con el orden: NO se puede escribir
		 *     bsp.nodes[root].children[0] = build_tree(...);
		 * porque el orden de evaluacion entre la direccion del lado izquierdo y
		 * la llamada de la derecha no esta definido en C. build_tree hace realloc
		 * de bsp.nodes, asi que si la direccion se calcula antes, la escritura
		 * cae en el array viejo ya liberado y el nodo se queda con los hijos a
		 * cero. Entre la version con variable intermedia y esta hay diferencia,
		 * y la version rota cuelga el motor con un ciclo en el nodo 0. Por eso
		 * el resultado va a una variable y se guarda despues. */
		{
			region_t raiz;
			int contenido, vacia, planenum;
			region_de_caja(&raiz, mundo_mins, mundo_maxs);
			contenido = build_tree(world, used, 0, 0, &raiz);
			vacia = -(make_leaf(CONTENTS_EMPTY, NULL) + 1);
			planenum = find_or_add_plane(&rp);

			bsp.nodes[root].planenum = planenum;
			bsp.nodes[root].children[0] = contenido;
			bsp.nodes[root].children[1] = vacia;
		}
	}

	/* Comprobacion del invariante del BSP: al bajar por el arbol, cada hoja
	 * tiene que estar ENTERA dentro o ENTERA fuera de cada una de sus brushes.
	 *
	 * Si no se cumple, la hoja no es ni solida ni de aire, y el motor no sabe
	 * que pintar. Es el fallo que hacia que la habitacion abierta saliera
	 * solida y el mundo entero no se dibujara. */
	{
		int malas = 0, hojas = bsp.numleafs;
		{
			region_t raiz;
			region_de_caja(&raiz, mundo_mins, mundo_maxs);
			verifica_hojas(bsp.nodes[0].children[0], &raiz, &malas, 0);
		}
		if (malas)
			fprintf(stderr,
			        "direkt-bsp: aviso, %d de %d hojas se quedan a medio "
			        "cortar\n", malas, hojas);
		else
			fprintf(stderr, "direkt-bsp: %d hojas, todas dentro o fuera de "
			                "sus brushes\n", hojas);

		/*
		 * Aviso de musica. Un mapa se puede pedir de dos maneras:
		 *
		 *   "music" "bosque.ogg"   Direkt. Se busca ese fichero en music/.
		 *   "sounds" "5"          toda la vida. El 5 es el numero de pista.
		 *
		 * El numero no dice nada de cual es cual, asi que lo primero es
otrejar que la forma larga este a mano. Si no hay ninguna de las dos,
		 * el mapa se queda sin musica y no hay forma de saber si fue eso o si
		 * el motor no la encuentra, asi que se avisa.
		 *
		 * No se comprueba que el fichero exista: este compilador no sabe donde
		 * esta la carpeta music/, y aun asi lo falso seria peor que callarse.
		 */
		{
			entity_t *e;
			const char *nombre = NULL;
			const char *numero = NULL;

			for (e = map->entities; e; e = e->next) {
				if (!e->is_world)
					continue;
				nombre = entity_key(e, "music");
				numero = entity_key(e, "sounds");
				break;
			}

			if (nombre && nombre[0])
				fprintf(stderr, "direkt-bsp: musica del mapa: %s\n", nombre);
			else if (numero && numero[0])
				fprintf(stderr, "direkt-bsp: musica del mapa: pista %s "
				                "(numero; usa \"music\" para ponerla por "
				                "nombre)\n", numero);
			else
				fprintf(stderr, "direkt-bsp: aviso, este mapa no pide musica: "
				                "pon \"music\" \"nombre.ogg\" en el "
				                "worldspawn\n");
		}
	}

	make_faces();

	/* Cuantas hojas tiene el PVS de este submodelo.
	 *
	 * OJO: esto NO es cosmetico. El motor saca de aqui su `numleafs`, y al
	 * cargar los nodos descarta cualquier hoja cuyo indice no sea menor que
	 * `numleafs`:
	 *
	 *     p = 65535 - p;                       // el indice de la hoja
	 *     if (p < loadmodel->numleafs)          // numleafs == visleafs
	 *         ...hoja buena...
	 *     else
	 *         ...se cae a la hoja 0, que es la solida...
	 *
	 * Con visleafs a 0, TODAS las hojas del arbol se caian a la hoja solida, que
	 * no tiene ninguna superficie marcada, y el mundo entero no se dibujaba:
	 * se veia el HUD y el mapa no. Ademas se ponia a 0 aqui, antes de que
	 * build_tree creara las hojas, o sea que tampoco podia tener el valor
	 * correcto por casualidad. */
	bsp.submodels[0].visleafs = bsp.numleafs;

	/* Cuantas superficies tiene este submodelo.
	 *
	 * El motor saca de aqui cuantas caras tiene el modelo: `nummodelsurfaces =
	 * bm->numfaces`. Con 0, el renderer no dibuja NADA del mundo y solo se ve
	 * el HUD. Es el mismo sintoma que un mapa sin texturas, pero la causa es
	 * que aqui solo faltaba este numero. */
	bsp.submodels[0].firstface = 0;
	bsp.submodels[0].numfaces = bsp.numsurfs;

	/* Las listas crecidas aparte se cuelgan del bsp, que es quien las suelta.
	 * El recuento de planos se fija al final porque los clipnodes anaden planos
	 * nuevos: si se fija antes, el lump PLANES sale corto y los clipnodes
	 * apuntan a planos que no estan en el fichero. */
	bsp.planes = planes;
	bsp.numplanes = numplanes;
	bsp.texinfos = texinfos;
	bsp.numtexinfos = numtexinfos;
	bsp.leafbrushes = leafbrushes;
	bsp.texnames = texnames;
	bsp.numtexnames = numtexnames;

	/* used solo vive durante la construccion del arbol. */
	free(used);

	return &bsp;
}

/* Las brushes que han caido en las hojas son las que hizo build_tree al partir
 * el mundo. free(leafbrushes) solo suelta el arreglo de punteros: las brushes
 * se quedan colgando de ahi, y el editor, que compila con cada F5, acumularia
 * una copia del mapa entero en cada pulsacion. */
static void free_leafbrushes(int numleafs)
{
	int l;
	for (l = 0; l < numleafs; l++) {
		brush_t *b, *next;
		for (b = leafbrushes[l]; b; b = next) {
			next = b->next;
			brush_free(b);
		}
	}
	free(leafbrushes);
	leafbrushes = NULL;
}

void free_bsp(bsp_t *b)
{
	int i;
	if (!b)
		return;
	for (i = 0; i < b->numsurfs; i++)
		winding_free(b->surfs[i].winding);
	free(b->surfs);
	free_leafbrushes(b->numleafs);
	b->leafbrushes = NULL;
	/* Los nombres los tiene ya el bsp, que los suelta. */
	free(texnames);
	b->texnames = NULL;
	b->numtexnames = 0;
	free(texinfos);
	free(planes);
	free(b->nodes);
	free(b->leafs);
	free(b->clipnodes);
	free(b->submodels);
	free(b->marksurfaces);
	memset(b, 0, sizeof(*b));
}
