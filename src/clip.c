/* direkt-bsp -- arboles de colision (clipnodes).
 *
 * GPL-2.0, ver LICENSE en la raiz del repositorio.
 *
 * Sin CLIPNODES el mapa se carga pero no se puede jugar: en cuanto una entidad
 * se mueve, el motor aborta con "SV_RecursiveHullCheck: bad node number". Esta
 * parte no es opcional aunque el mapa se vea bien.
 *
 * Hay cuatro hulls. El 0 es el arbol de dibujo (LUMP_NODES) y no lleva
 * clipnode. El 1 es el del jugador, y el 2 y el 3 los de las entidades grandes;
 * SV_HullForEntity elige por el tamano de la caja.
 *
 * Cada hull es el mismo arbol del mundo con las brushes solidas dilatadas por
 * la caja del hull: una cara a distancia d pasa a d + lo que ocupa la caja en esa
 * direccion. Asi un punto solo choca cuando el cuerpo entero solaparia.
 *
 * DECISION: el reparto de la region usa SOLO planos alineados a ejes. Son los
 * que salen de las brushes, y partir una caja por uno de ellos da dos cajas
 * exactas. Partirla por un plano oblicuo daria algo que ya no es una caja y
 * complica el reparto sin ganancia, porque el mapa lo construye nuestro editor
 * con cajas y con el .map clasico.
 *
 * Una hoja devuelve SOLID solo si la region ENTERA cabe dentro de una brush
 * solida. Marcar SOLID una hoja que solo contiene una brush haria chocar al
 * jugador con el aire de alrededor, que es el error clasico de estos arboles.
 */

#define _GNU_SOURCE
#include "direktbsp.h"

#include <math.h>
#include <stdlib.h>

#include <stdio.h>
#include <string.h>

#define MAX_CLIP_DEPTH 512

/* Las tres cajas de colision de Quake. */
static const vec3_t hull_mins[4] = {{0, 0, 0},
                                    {-16, -16, -24},
                                    {-32, -32, -24},
                                    {-64, -64, -24}};
static const vec3_t hull_maxs[4] = {{0, 0, 0},
                                    {16, 16, 32},
                                    {32, 32, 64},
                                    {64, 64, 96}};

typedef struct {
	plane_t planes[6];
	int numplanes;
} cbrush_t;

static cbrush_t *cbrushes;
static int numcbrushes;

/* Un plano alineado a ejes, guardado como (eje, coordenada). El plano es
 * x[e] = coord, con la normal mirando a +e. */
typedef struct {
	int e;
	float coord;
} axisplane_t;

static axisplane_t *aplane;
static int numaplane;

/* Cuanto ocupa una caja en la direccion de una normal: el punto mas alejado es
 * el que mas se acerca a la normal. */
static float box_max(vec3_t mins, vec3_t maxs, vec3_t n)
{
	float e = 0.0f;
	int i;
	for (i = 0; i < 3; i++)
		e += (n[i] > 0.0f ? maxs[i] : mins[i]) * n[i];
	return e;
}

/* Prepara las brushes dilatadas por la caja del hull, y la lista de planos
 * alineados a ejes que se usaran para repartir. */
static void prepare(brush_t *brushes, const vec3_t hmin, const vec3_t hmax)
{
	brush_t *b;
	int i, k;

	/* prepare se llama una vez por hull, o sea tres. Sin soltar aqui lo que
	 * dejo la vuelta anterior, las dos primeras se quedan en la memoria
	 * para siempre. */
	free(cbrushes);
	cbrushes = NULL;
	numcbrushes = 0;
	free(aplane);
	aplane = NULL;
	numaplane = 0;

	for (b = brushes; b; b = b->next) {
		cbrush_t *cb;
		if (b->contents != CONTENTS_SOLID)
			continue; /* triggers y liquidos no colisionan */

		cbrushes = xrealloc(cbrushes, sizeof(cbrush_t) * (size_t)(numcbrushes + 1));
		cb = &cbrushes[numcbrushes++];
		cb->numplanes = 0;

		for (i = 0; i < b->numsides; i++) {
			plane_t p = b->sides[i].plane;
			float ext = 0.0f;
			int e;

			/* Dilatacion para consulta de PUNTO (el motor llama a
			 * SV_HullPointContents con el origen del jugador, no con la caja
			 * entera).
			 *
			 * La caja del hull es p + [hmin, hmax]. Se solapa con el
			 * semiplano dot(n,x) <= d si existe h con dot(n,p+h) <= d, o
			 * sea, si dot(n,p) + minH <= d, con
			 *
			 *     minH = sum_k (n_k > 0 ? hmin_k : hmax_k) * n_k
			 *
			 * El semiplano dilatado es por tanto dot(n,p) <= d - minH.
			 *
			 * OJO: es minH y se RESTA. Con maxH y sumando (que es lo
			 * intuitivo) la brush crece hacia el lado equivocado: el suelo
			 * se dilataba hasta z=32 en vez de z=24, el jugador quedaba
			 * medio metro dentro del suelo al andar y el techo le cortaba la
			 * cabeza de mas. */
			for (k = 0; k < 3; k++)
				ext += (p.normal[k] > 0.0f ? hmin[k] : hmax[k]) * p.normal[k];
			p.dist -= ext;

			cb->planes[cb->numplanes++] = p;

			/* Si la cara es alineada a ejes, su coordenada es un plano de
			 * reparto candidato.
			 *
			 * OJO: la coordenada es dist * normal[e], no dist. Un plano con
			 * normal (0,0,-1) y dist 40 esta en z = -40, porque -z = 40.
			 * Guardando dist tal cual se registraban los planos "hacia abajo"
			 * en su coordenada reflejada, el arbol no partia nunca donde hacia
			 * falta y las regiones no llegaban a caber dentro de una brush:
			 * todo lo solido salia "vacio" y el jugador se caia al vacio. */
			for (e = 0; e < 3; e++) {
				if ((p.normal[e] == 1.0f || p.normal[e] == -1.0f) &&
				    p.normal[(e + 1) % 3] == 0.0f && p.normal[(e + 2) % 3] == 0.0f) {
					float coord = p.dist * p.normal[e];
					int existe = 0, j;
					for (j = 0; j < numaplane; j++)
						if (aplane[j].e == e && fabsf(aplane[j].coord - coord) < 0.01f)
							existe = 1;
					if (!existe) {
						aplane = xrealloc(aplane,
						                  sizeof(axisplane_t) * (size_t)(numaplane + 1));
						aplane[numaplane].e = e;
						aplane[numaplane].coord = coord;
						numaplane++;
					}
				}
			}
		}
	}
}

/* El punto de la region mas CERCA al plano, es decir, el minimo de dot(n, x).
 * Sirve para lo contrario que box_max: una region esta enteramente en la parte
 * de FUERA de un plano cuando este minimo sigue por encima del plano. */
static float box_min(vec3_t mins, vec3_t maxs, vec3_t n)
{
	float e = 0.0f;
	int i;
	for (i = 0; i < 3; i++)
		e += (n[i] > 0.0f ? mins[i] : maxs[i]) * n[i];
	return e;
}

/* La region entera cabe dentro de alguna brush solida dilated. */
static int region_solid(vec3_t mins, vec3_t maxs)
{
	int i, j;
	for (i = 0; i < numcbrushes; i++) {
		int dentro = 1;
		for (j = 0; j < cbrushes[i].numplanes; j++) {
			if (box_max(mins, maxs, cbrushes[i].planes[j].normal) >
			    cbrushes[i].planes[j].dist) {
				dentro = 0;
				break;
			}
		}
		if (dentro)
			return 1;
	}
	return 0;
}

/* Queda alguna brush que solape la region.
 *
 * La region esta ENTERA fuera de la brush si hay algun plano de la brush que
 * deja la region entera de su lado de fuera. O sea: si para algun plano, el
 * punto de la region mas cercano al plano sigue sin llegar. Si todos los planos
 * dejan algo de la region dentro, entonces la region toca la brush. */
static int region_touches(vec3_t mins, vec3_t maxs)
{
	int i, j;
	for (i = 0; i < numcbrushes; i++) {
		int toca = 1;
		for (j = 0; j < cbrushes[i].numplanes; j++) {
			/* Interior de la brush es dot(n,x) <= d. La region esta ENTERA
			 * fuera de la brush si para algun plano TODO el interior posible
			 * de la region queda por encima del plano, o sea, si el punto MAS
			 * CERCANO al plano (box_min) sigue sin tocarlo.
			 *
			 * Ojo: aqui va box_min y no box_max. Con box_max se estaba
			 * comprobando si la region entera queda DENTRO del semiplano de
			 * la brush, que no dice nada, y por eso las regiones que estaban
			 * dentro de una brush salian "vacias" y el jugador caia al
			 * vacio. */
			if (box_min(mins, maxs, cbrushes[i].planes[j].normal) >=
			    cbrushes[i].planes[j].dist - 0.01f) {
				toca = 0;
				break;
			}
		}
		if (toca)
			return 1;
	}
	return 0;
}

/* Elige el plano con el que partir la region: la MEDIANA de las coordenadas
 * que la cortan de verdad.
 *
 * Se coge la mediana y no "el primero que valga" porque asi el arbol se
 * equilibra solo y, sobre todo, porque cada corte deja la region encogida de
 * verdad. Con un libro de planos "usados" habia que acertar con el estado de ese
 * libro en cada recursion, y un solo despiste ahi (por ejemplo un flag que se
 * quedaba pegado a 1) descartaba todos los planos y dejaba medio mapa sin
 * colision. */
static int elegir_plano(vec3_t mins, vec3_t maxs, axisplane_t *out)
{
	int e, mejor = 0, n = 0, total = 0, i;
	axisplane_t *cand;

	/* Cuantas coordenadas cortan la region en cada eje. */
	int por_eje[3];
	for (e = 0; e < 3; e++) {
		por_eje[e] = 0;
		for (i = 0; i < numaplane; i++)
			if (aplane[i].e == e && aplane[i].coord > mins[e] + 0.01f &&
			    aplane[i].coord < maxs[e] - 0.01f)
				por_eje[e]++;
		total += por_eje[e];
	}
	if (total == 0)
		return 0;

	/* Se parte por el eje con mas cortes, que es el que mas reduce.
	 * OJO: mejor arranca en 0, no en -1. Con -1 la comparacion
	 * por_eje[e] > por_eje[mejor] lee por_eje[-1], fuera del arreglo, y segun
	 * lo que hubiera ahi el eje se elegia de mas o de menos: el eje X llegaba
	 * a no partirse nunca, ninguna region se metia dentro de una brush y
	 * TODAS las hojas salian "vacias". */
	for (e = 1; e < 3; e++)
		if (por_eje[e] > por_eje[mejor])
			mejor = e;
	if (por_eje[mejor] == 0)
		return 0;

	/* Mediana de las coordenadas de ese eje. */
	cand = xmalloc(sizeof(axisplane_t) * (size_t)por_eje[mejor]);
	for (i = 0; i < numaplane; i++)
		if (aplane[i].e == mejor && aplane[i].coord > mins[mejor] + 0.01f &&
		    aplane[i].coord < maxs[mejor] - 0.01f)
			cand[n++] = aplane[i];

	/* Insercion: n es pequeno y sale ordenado por utilizacion. */
	for (i = 1; i < n; i++) {
		axisplane_t v = cand[i];
		int j = i - 1;
		while (j >= 0 && cand[j].coord > v.coord) {
			cand[j + 1] = cand[j];
			j--;
		}
		cand[j + 1] = v;
	}
	*out = cand[n / 2];
	free(cand);
	return 1;
}

/* Devuelve el indice del clipnode creado, o el contents negativo de la hoja. */
static int clip_build(bsp_t *bsp, vec3_t mins, vec3_t maxs, int depth)
{
	axisplane_t elegido;
	plane_t p;
	int planenum, neg, pos, me;
	vec3_t fmins, fmaxs, nmins, nmaxs;
	int e;

	if (depth > MAX_CLIP_DEPTH) {
		fprintf(stderr, "direkt-bsp: aviso, profundidad maxima en el arbol de "
		                "colision\n");
		return CONTENTS_SOLID;
	}

	/* La region entera dentro de una brush solida: hoja solida. */
	if (region_solid(mins, maxs))
		return CONTENTS_SOLID;
	/* Nada la toca: hoja vacia. Se comprueba antes de partir, que es lo que
	 * hace que el arbol no crezca con el mapa entero. */
	if (!region_touches(mins, maxs))
		return CONTENTS_EMPTY;

	/* Quedan brushes solapando pero la region no cabe en ninguna y no hay mas
	 * planos con los que partirla. Se declara vacia: es la eleccion permisiva,
	 * y la contraria dejaria al jugador atascado dentro de su propio brush. */
	if (!elegir_plano(mins, maxs, &elegido))
		return CONTENTS_EMPTY;

	/* El plano de reparto es x[e] == coord. Hay que montar los cuatro
	 * componentes: sin esto se guardaba un plane_t sin inicializar y el lump
	 * PLANES salia con normales a cero, o sea, planos degenerados. */
	memset(&p.normal, 0, sizeof(vec3_t));
	p.normal[elegido.e] = 1.0f;
	p.dist = elegido.coord;
	planenum = find_or_add_plane_public(&p);

	for (e = 0; e < 3; e++) {
		fmins[e] = mins[e];
		fmaxs[e] = maxs[e];
		nmins[e] = mins[e];
		nmaxs[e] = maxs[e];
	}
	/* La mitad positiva es x >= coord, y el motor va a children[0] cuando
	 * t1 >= 0, o sea en la positiva. children[1] es la negativa. */
	nmins[elegido.e] = mins[elegido.e];
	nmaxs[elegido.e] = elegido.coord;
	fmins[elegido.e] = elegido.coord;
	fmaxs[elegido.e] = maxs[elegido.e];

	/* El nodo se reserva ANTES de recursionar: el arbol va en preorden.
	 *
	 * El motor usa headnode[j] como firstclipnode y aborta con "bad node
	 * number" en cuanto un hijo tiene indice menor que el (world.c). O sea,
	 * que el padre TIENE que ir antes que sus hijos. Con postorden el padre
	 * salia el ultimo del bloque, sus hijos quedaban por debajo y la primera
	 * comprobacion reventaba. */
	bsp->clipnodes = xrealloc(
	    bsp->clipnodes, sizeof(clipnode_t) * (size_t)(bsp->numclipnodes + 1));
	me = bsp->numclipnodes++;
	bsp->clipnodes[me].planenum = planenum;

	pos = clip_build(bsp, fmins, fmaxs, depth + 1);
	neg = clip_build(bsp, nmins, nmaxs, depth + 1);

	bsp->clipnodes[me].children[0] = pos;
	bsp->clipnodes[me].children[1] = neg;
	return me;
}

/* Construye los tres clipnodes. Debe llamarse antes de free_bsp. */
void build_clipnodes(bsp_t *bsp, brush_t *world, map_t *map)
{
	int h;
	vec3_t mins, maxs;
	vec3_t mapmins, mapmaxs;

	if (world == NULL) {
		fprintf(stderr, "direkt-bsp: build_clipnodes sin brushes del mundo\n");
		return;
	}

	/* La region inicial tiene que cubrir el mapa entero y no solo las brushes:
	 * si no, el punto donde aparece el jugador queda fuera del arbol y la
	 * colision no lo mira. Se usan las cajas de las brushes y los origins de
	 * las entidades, mas un margen. */
	{
		vec3_t bmins, bmaxs;
		int e, tiene = 0;
		entity_t *ent;

		brush_bounds(world, bmins, bmaxs);
		for (e = 0; e < 3; e++) {
			mapmins[e] = bmins[e];
			mapmaxs[e] = bmaxs[e];
		}
		tiene = 1;

		for (ent = map->entities; ent; ent = ent->next) {
			const char *o = entity_key(ent, "origin");
			float v[3];
			if (!o)
				continue;
			if (sscanf(o, "%f %f %f", &v[0], &v[1], &v[2]) != 3)
				continue;
			for (e = 0; e < 3; e++) {
				if (v[e] < mapmins[e]) mapmins[e] = v[e];
				if (v[e] > mapmaxs[e]) mapmaxs[e] = v[e];
			}
			tiene = 1;
		}
		if (!tiene)
			return;
		for (e = 0; e < 3; e++) {
			mapmins[e] = floorf(mapmins[e]) - 256.0f;
			mapmaxs[e] = ceilf(mapmaxs[e]) + 256.0f;
		}
	}

	for (h = 1; h < 4; h++) {
		int base = bsp->numclipnodes;
		int root;

		/* El arbol arranca en los limites del mapa, no en los del jugador:
		 * las brushes de colision ya van dilatadas y el hull entero tiene
		 * que caber dentro del arbol. */
		memcpy(mins, mapmins, sizeof(vec3_t));
		memcpy(maxs, mapmaxs, sizeof(vec3_t));

		prepare(world, hull_mins[h], hull_maxs[h]);
		root = clip_build(bsp, mins, maxs, 0);

		/* Si la raiz salio como hoja no hay arbol, pero el motor exige que
		 * lastclipnode sea coherente. Con un solo nodo artificial que lo lleva
		 * todo a la raiz se evita. */
		if (root < 0) {
			plane_t p;
		memset(&p.normal, 0, sizeof(vec3_t));
			p.normal[2] = 1.0f;
			p.dist = 0.0f;
			bsp->clipnodes = xrealloc(
			    bsp->clipnodes, sizeof(clipnode_t) * (size_t)(bsp->numclipnodes + 1));
			bsp->clipnodes[bsp->numclipnodes].planenum =
			    find_or_add_plane_public(&p);
			bsp->clipnodes[bsp->numclipnodes].children[0] = root;
			bsp->clipnodes[bsp->numclipnodes].children[1] = root;
			root = bsp->numclipnodes++;
		}

		/* headnode[h] es la raiz del hull, que en preorden es justo el primer
		 * indice del bloque. */
		if (root != base)
			fprintf(stderr, "direkt-bsp: aviso, la raiz del hull %d no es el "
			                "primer nodo del bloque (%d vs %d)\n", h, root, base);
		bsp->submodels[0].headnode[h] = root;
	}

	/* Los arrays de trabajo son estaticos porque prepare() los va rellenando
	 * por hull; se sueltan aqui. Sin esto, compilar N mapas en el mismo
	 * proceso (que es justo lo que hace el editor al darle a F5) acumularia
	 * memoria sin limite. */
	free(cbrushes);
	cbrushes = NULL;
	numcbrushes = 0;
	free(aplane);
	aplane = NULL;
	numaplane = 0;
}
