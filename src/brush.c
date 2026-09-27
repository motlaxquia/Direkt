/* direkt-bsp -- partir brushes.
 *
 * GPL-2.0, ver LICENSE en la raiz del repositorio.
 *
 * Cuando una brush cruza el plano de corte hay que partirla en dos mitades. Cada
 * mitad se queda con las caras que le tocan, recortadas, y gana una cara nueva
 * que es la seccion de la brush con el plano de corte.
 *
 * Dibujo de la cara nueva, que es lo unico aqui que no es trivial: se recogen
 * los puntos de la brush que caen en el plano, se proyectan a las coordenadas
 * del plano, se saca la envolvente convexa, y se vuelve a proyectar. Hacerlo con
 * los puntos sueltos y sin envolvente daria una cara con forma de estrella, que
 * dibuja mal y ademas rompe la construccion de edges.
 */

#define _GNU_SOURCE
#include "direktbsp.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#define SPLIT_EPSILON 0.001f
#define ON_EPSILON 0.1f

/* ------------------------------------------------------------------ winding */

/*parte un winding por un plano.
 *
 * Devuelve por wf y wb las dos mitades, que pueden ser NULL. Los flags dicen si
 * el winding entero cae de un solo lado (f_entero/b_entero) o si lo cruza; si
 * cae entero, la mitad devuelta es una copia. Un winding pegado al plano
 * devuelve los dos flags a 0 y no devuelve nada: esa cara desaparece. */
static void split_winding(winding_t *w, plane_t *p, winding_t **wf, winding_t **wb,
                          int *f_entero, int *b_entero)
{
	int n = w->numpoints;
	int i, countf = 0, countb = 0, ontoplane = 0;
	int *fwd, *bwd;
	vec3_t mids[64];
	winding_t *nf = NULL, *nb = NULL;

	*wf = NULL;
	*wb = NULL;
	*f_entero = 0;
	*b_entero = 0;

	if (n > 64)
		error("winding con %d puntos, el buffer de corte es de 64", n);

	fwd = xmalloc(sizeof(int) * (size_t)n);
	bwd = xmalloc(sizeof(int) * (size_t)n);
	for (i = 0; i < n; i++) {
		float d = plane_distance(p, w->points[i]);
		if (d > ON_EPSILON) {
			fwd[i] = 1;
			bwd[i] = 0;
			countf++;
		} else if (d < -ON_EPSILON) {
			fwd[i] = 0;
			bwd[i] = 1;
			countb++;
		} else {
			fwd[i] = 0;
			bwd[i] = 0;
			ontoplane++;
		}
	}

	/* Entero de un lado, o entero pegado al plano: no hay nada que cortar. */
	if (countf == 0 || countb == 0) {
		if (ontoplane == n) {
			/* Pegada al plano de corte: la cara es real y hay que
			 * conservarla. Si se descarta, la brush se queda sin una de sus
			 * caras, y como el plano que elige el arbol para partir una
			 * habitacion de cajas alineadas a ejes es justo el plano de una
			 * cara, el resultado es que los muros se quedan sin la cara de
			 * dentro y la habitacion no dibuja nada.
			 *
			 * La cara pertenece a las dos mitades: es el plano que las
			 * separa, y cada mitad la tiene en su frontera. Con un plano
			 * mas de los 6 del .map, y por eso el array de lados crece. */
			*wf = winding_copy(w);
			*wb = winding_copy(w);
			free(fwd);
			free(bwd);
			return;
		}
		if (countb == 0) {
			*wf = winding_copy(w);
			*f_entero = 1;
		} else {
			*wb = winding_copy(w);
			*b_entero = 1;
		}
		free(fwd);
		free(bwd);
		return;
	}

	/* Recorrido de los lados: por cada arista que cambia de lado, se mete el
	 * punto medio del corte en las dos mitades. */
	{
		int numf = 0, numb = 0;
		int nummid = 0;
		int *midmap = xmalloc(sizeof(int) * (size_t)n);

		for (i = 0; i < n; i++) {
			int j = (i + 1) % n;
			if (fwd[i] == fwd[j] && bwd[i] == bwd[j]) {
				if (fwd[i])
					numf++;
				else if (bwd[i])
					numb++;
			} else {
				/* Cruza: calcular el punto medio. */
				float d1 = plane_distance(p, w->points[i]);
				float d2 = plane_distance(p, w->points[j]);
				float frac = d1 / (d1 - d2);
				mids[nummid][0] = w->points[i][0] + frac * (w->points[j][0] - w->points[i][0]);
				mids[nummid][1] = w->points[i][1] + frac * (w->points[j][1] - w->points[i][1]);
				mids[nummid][2] = w->points[i][2] + frac * (w->points[j][2] - w->points[i][2]);
				midmap[i] = nummid;
				nummid++;
			}
		}

		nf = winding_new(numf + nummid);
		nb = winding_new(numb + nummid);
		numf = numb = 0;

		for (i = 0; i < n; i++) {
			int j = (i + 1) % n;
			if (fwd[i] == fwd[j] && bwd[i] == bwd[j]) {
				if (fwd[i])
					VectorCopy(w->points[i], nf->points[numf++]);
				else if (bwd[i])
					VectorCopy(w->points[i], nb->points[numb++]);
			} else {
				VectorCopy(mids[midmap[i]], nf->points[numf++]);
				VectorCopy(mids[midmap[i]], nb->points[numb++]);
			}
		}

		nf->numpoints = numf;
		nb->numpoints = numb;
		free(midmap);
	}

	free(fwd);
	free(bwd);

	/* Una mitad puede quedarse con 2 puntos si el corte es degenerado, o con
	 * menos de 3, que no describe un poligono. */
	if (nf && nf->numpoints < 3) {
		winding_free(nf);
		nf = NULL;
	}
	if (nb && nb->numpoints < 3) {
		winding_free(nb);
		nb = NULL;
	}
	if (!nf && !nb) {
		/* Corte imposible: se devuelve la brush entera por el lado negativo,
		 * que es lo que haria el clasico "si no puedes partirlo, no lo partas". */
		*wb = winding_copy(w);
		*b_entero = 1;
		return;
	}

	*wf = nf;
	*wb = nb;
}

/* ------------------------------------------------------------------ seccion */

/* Envolvente convexa 2D por cadena monotona de Andrew. Los indices son sobre
 * los puntos de entrada; escribe los indices ordenados en out. */
static int hull_2d(const vec2_t *pts, int n, int *out)
{
	int *idx = xmalloc(sizeof(int) * (size_t)n);
	int *stack = xmalloc(sizeof(int) * (size_t)n);
	int i, k = 0, m = 0;

	for (i = 0; i < n; i++)
		idx[i] = i;

	/* Ordenar por x y luego por y. Insertion sort: n es pequeno. */
	for (i = 1; i < n; i++) {
		int v = idx[i];
		int j = i - 1;
		while (j >= 0 && (pts[idx[j]][0] > pts[v][0] ||
		                  (pts[idx[j]][0] == pts[v][0] &&
		                   pts[idx[j]][1] > pts[v][1]))) {
			idx[j + 1] = idx[j];
			j--;
		}
		idx[j + 1] = v;
	}

#define CR(o, a, b)                                                              \
	((pts[a][0] - pts[o][0]) * (pts[b][1] - pts[o][1]) -                        \
	 (pts[a][1] - pts[o][1]) * (pts[b][0] - pts[o][0]))

	for (i = 0; i < n; i++) {
		while (k >= 2 && CR(out[k - 2], out[k - 1], idx[i]) <= 0)
			k--;
		stack[k++] = idx[i];
	}
	for (i = n - 2, m = k + 1; i >= 0; i--) {
		while (k >= m && CR(out[k - 2], out[k - 1], idx[i]) <= 0)
			k--;
		stack[k++] = idx[i];
	}
	k--; /* el ultimo punto es el primero */

	for (i = 0; i <= k; i++)
		out[i] = stack[i];

#undef CR

	free(idx);
	free(stack);
	return k + 1;
}

/* Construye el winding de la seccion de la brush con el plano. Son todos los
 * puntos de la brush que caen en el plano, su envolvente convexa, y devuelto con
 * la normal mirando hacia el lado positivo del plano. */
static winding_t *brush_section(brush_t *b, plane_t *p)
{
	vec3_t pts[256];
	vec2_t flat[256];
	int n = 0, i, j, k;
	vec3_t base, right, up;
	int *order;
	winding_t *w;

	(void)j;
	(void)k;

	for (i = 0; i < b->numsides; i++) {
		winding_t *s = b->sides[i].winding;
		if (!s)
			continue;
		for (j = 0; j < s->numpoints; j++) {
			if (fabsf(plane_distance(p, s->points[j])) > ON_EPSILON)
				continue;
			if (n >= 256)
				break;
			VectorCopy(s->points[j], pts[n]);
			n++;
		}
	}
	if (n < 3)
		return NULL;

	/* Base ortonormal en el plano. */
	{
		vec3_t nrm;
		VectorCopy(p->normal, nrm);
		if (fabsf(nrm[0]) > 0.9f) {
			base[0] = 0; base[1] = 1; base[2] = 0;
		} else {
			base[0] = 1; base[1] = 0; base[2] = 0;
		}
		/* right = normal x base, para que (right, up) sea mano derecha con
		 * la normal, y la envolvente salga antihoraria vista desde el frente. */
		CrossProduct(nrm, base, right);
		VectorNormalize(right);
		CrossProduct(nrm, right, up);
	}

	for (i = 0; i < n; i++) {
		flat[i][0] = VectorDot(pts[i], right);
		flat[i][1] = VectorDot(pts[i], up);
	}

	order = xmalloc(sizeof(int) * (size_t)n);
	k = hull_2d(flat, n, order);
	if (k < 3) {
		free(order);
		return NULL;
	}

	w = winding_new(k);
	for (i = 0; i < k; i++) {
		VectorCopy(pts[order[i]], w->points[i]);
	}
	free(order);
	return w;
}

/* ------------------------------------------------------------------ split */

/* Anade un lado a una brush, copiando el winding. Devuelve el indice del lado. */
static int add_side(brush_t *b, plane_t *p, winding_t *w)
{
	brush_sides_reserve(b, b->numsides + 1);
	memcpy(&b->sides[b->numsides].plane, p, sizeof(plane_t));
	b->sides[b->numsides].winding = w;
	memset(&b->sides[b->numsides].texname, 0, sizeof(b->sides[b->numsides].texname));
	/* La cara que nace del corte no trae textura: el mapa no la define. Se le
	 * pone la del plano, que es la primera de la brush, y ya se vera. */
	b->sides[b->numsides].texname = NULL;
	b->sides[b->numsides].texscale[0] = 1.0f;
	b->sides[b->numsides].texscale[1] = 1.0f;
	b->sides[b->numsides].texshift[0] = 0.0f;
	b->sides[b->numsides].texshift[1] = 0.0f;
	b->sides[b->numsides].texrotate = 0.0f;
	return b->numsides++;
}

int brush_split(brush_t *b, plane_t *split, brush_t **outf, brush_t **outb)
{
	brush_t *f = brush_new();
	brush_t *k = brush_new();
	winding_t *section;
	plane_t neg;
	int i;

	f->contents = k->contents = b->contents;
	f->moving = k->moving = b->moving;
	f->modelindex = k->modelindex = b->modelindex;

	neg.normal[0] = -split->normal[0];
	neg.normal[1] = -split->normal[1];
	neg.normal[2] = -split->normal[2];
	neg.dist = -split->dist;

	for (i = 0; i < b->numsides; i++) {
		winding_t *w = b->sides[i].winding;
		winding_t *wf = NULL, *wb = NULL;
		int f_entero = 0, b_entero = 0;
		plane_t pl = b->sides[i].plane;

		if (!w)
			continue;

		split_winding(w, split, &wf, &wb, &f_entero, &b_entero);

		if (f_entero)
			add_side(f, &pl, wf);
		else if (b_entero)
			add_side(k, &pl, wb);
		else if (wf && wb) {
			add_side(f, &pl, wf);
			add_side(k, &pl, wb);
		} else if (wf) {
			add_side(f, &pl, wf);
		} else if (wb) {
			add_side(k, &pl, wb);
		}
		/* Si no sale ninguna mitad, la cara estaba en el plano y se pierde. */
	}

	/* Las dos caras nuevas del corte. */
	section = brush_section(b, split);
	if (section) {
		add_side(f, split, section);
		add_side(k, &neg, winding_reverse(section));
	}

	if (f->numsides < 4 || k->numsides < 4) {
		/* Una de las mitades ha quedado degenerada. Se descarta y la brush se
		 * queda entera del lado que si ha salido bien, que siempre es valido. */
		if (f->numsides >= 4) {
			brush_free(k);
			*outf = f;
			*outb = NULL;
			return 1;
		}
		brush_free(f);
		brush_free(k);
		*outf = NULL;
		*outb = NULL;
		return 0;
	}

	brush_free(b);
	*outf = f;
	*outb = k;
	return 1;
}
