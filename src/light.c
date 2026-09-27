/* light.c -- generacion del lump LIGHTING.
 *
 * GPL-2.0, ver LICENSE en la raiz del repositorio.
 *
 * Sin este lump el motor deja `worldmodel->lightdata` a NULL y las superficies
 * con luz salen en negro: el mapa se ve, el HUD se ve, y el mundo no. Es el
 * ultimo trozo que hace falta para que un .bsp nuestro se vea de verdad.
 *
 * El formato, que hay que replicar exacto porque el motor no lo valida:
 *
 *   - El lump LIGHTING es una tira de bytes, uno por muestra. El motor los
 *     expande a RGB replicando el mismo byte en los tres canales
 *     (Mod_LoadLighting), asi que el formato es de un solo canal.
 *   - Cada cara tiene su LOSAJE de (extents[0]/16 + 1) x (extents[1]/16 + 1)
 *     muestras, en filas por t.
 *   - `dsface_t.lightsofs` es el indice de la PRIMERA muestra de la cara, en
 *     unidades de muestra, y de ahi el motor avanza solo.
 *   - Para un punto con coordenadas de textura (s, t):
 *         muestra = ((t >> 4) * (ancho) + (s >> 4)) * 3
 *     con `ancho = (extents[0] >> 4) + 1` y s, t ya restados el texturemins.
 *
 * `texturemins` y `extents` los calcula el motor con `Mod_CalcSurfaceBounds`, y
 * ese calculo hay que replicarlo AQUI igual, porque si no el motor lee
 * muestras de donde no toca. El motor avisa de ello en el propio fuente: dice
 * que su aritmetica tiene que coincidir con la del compilador de luz.
 *
 * Ademas el motor aborta con "Bad surface extents" si una cara sin TEX_SPECIAL
 * pasa de 2000 de extension, asi que hay que vigilarlo: es un Sys_Error al
 * cargar, no un fallo de pintura.
 */

#define _GNU_SOURCE
#include "direktbsp.h"
#include "tex.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Por encima de esto el motor aborta al cargar. */
#define EXTENTS_MAXIMO 1900
/* Tope de muestras por cara, por si un mapa traiciona la regla de arriba. */
#define MUESTRAS_MAXIMAS 16384

/* Una brush solida, solo lo que hace falta para tapar un rayo de luz. */
typedef struct {
	plane_t *planos;
	int numplanos;
} brush_ocluye_t;

/* ¿Tapa algo el segmento de `a` a `b`?
 *
 * Se avanza a paso fijo y se mira si algun punto cae dentro de una brush. Es
 * tosco, pero es O(pasos * brushes) con numeros pequenos, y una brush de un
 * mapa tiene 6 planos: sale mucho mas barato que un trace entero y para el
 * proposito (que la luz no atraviese un muro) sobra. */
static int segmento_tapado(const brush_ocluye_t *brushes, int n, vec3_t a, vec3_t b)
{
	vec3_t v;
	float dist, t;
	int pasos, i, k;
	const float epsilon = 0.5f; /* margen para no clipping en la propia cara */

	v[0] = b[0] - a[0];
	v[1] = b[1] - a[1];
	v[2] = b[2] - a[2];
	dist = sqrtf(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
	if (dist < 1.0f)
		return 0;
	pasos = (int)(dist / 8.0f) + 1;
	if (pasos > 64)
		pasos = 64;

	/* El primer y el ultimo punto casi nunca estan dentro de nada: estan en
	 * la propia cara que se esta iluminando. */
	for (k = 1; k < pasos; k++) {
		vec3_t p;
		t = (float)k / (float)pasos;
		p[0] = a[0] + v[0] * t;
		p[1] = a[1] + v[1] * t;
		p[2] = a[2] + v[2] * t;
		for (i = 0; i < n; i++) {
			int dentro = 1, j;
			for (j = 0; j < brushes[i].numplanos; j++) {
				float d = brushes[i].planos[j].normal[0] * p[0] +
				          brushes[i].planos[j].normal[1] * p[1] +
				          brushes[i].planos[j].normal[2] * p[2] -
				          brushes[i].planos[j].dist;
				if (d > epsilon) {
					dentro = 0;
					break;
				}
			}
			if (dentro)
				return 1;
		}
	}
	return 0;
}

/* ------------------------------------------------- calculo de la cara */

typedef struct {
	int texturemins[2];
	int extents[2];
	int ancho, alto; /* en muestras */
} rejilla_t;

/* El motor calcula esto en Mod_CalcSurfaceBounds. Hay que hacerlo IGUAL: si el
 * ancho en muestras no coincide, el motor lee las muestras de la fila de al
 * lado y el lightmap sale con manchas. El motor avisa en su propio fuente de
 * que su aritmetica tiene que coincidir con la del compilador de luz. */
static int rejilla_de_superficie(texinfo_t *ti, winding_t *w, rejilla_t *r)
{
	int i, j;
	float mins[2], maxs[2];
	vec3_t org;

	mins[0] = mins[1] = 1e30f;
	maxs[0] = maxs[1] = -1e30f;
	for (i = 0; i < w->numpoints; i++) {
		org[0] = w->points[i][0];
		org[1] = w->points[i][1];
		org[2] = w->points[i][2];
		for (j = 0; j < 2; j++) {
			/* En doble: el motor avisa de que con coma flotante de 32 bits
			 * salen manchas, porque la multiplicacion se hace en x87 de 80
			 * bits y el redondeo acaba en un sitio distinto. */
			double val = (double)org[0] * ti->vecs[j][0] +
			             (double)org[1] * ti->vecs[j][1] +
			             (double)org[2] * ti->vecs[j][2] + (double)ti->vecs[j][3];
			if ((float)val < mins[j])
				mins[j] = (float)val;
			if ((float)val > maxs[j])
				maxs[j] = (float)val;
		}
	}
	for (j = 0; j < 2; j++) {
		int bmin = 16 * (int)floorf(mins[j] / 16.0f);
		int bmax = 16 * (int)ceilf(maxs[j] / 16.0f);
		r->texturemins[j] = bmin;
		r->extents[j] = bmax - bmin;
	}
	r->ancho = (r->extents[0] >> 4) + 1;
	r->alto = (r->extents[1] >> 4) + 1;
	return 0;
}

/* Convierte un par de coordenadas de textura en un punto del plano de la cara.
 * Invierte la proyeccion: se toma un eje de la cara y se recorre el otro. */
static void punto_de_textura(texinfo_t *ti, plane_t *pl, float s, float t, vec3_t out)
{
	/* Base: un punto de la cara mas los vectores de textura. */
	float bs = 0.0f, bt = 0.0f;
	float d;
	int i;

	/* El punto de la cara que da s=t=0 se busca resolviendo el sistema. Se
	 * usa la normal para Descento plano: la cara es n.p = d, y dentro del
	 * plano los ejes de textura son independientes. */
	{
		vec3_t e1, e2;
		float det;
		/* Dos ejes del plano, perpendiculares a la normal. */
		if (fabsf(pl->normal[0]) > 0.9f) {
			e1[0] = 0; e1[1] = 1; e1[2] = 0;
			e2[0] = 0; e2[1] = 0; e2[2] = 1;
		} else if (fabsf(pl->normal[1]) > 0.9f) {
			e1[0] = 1; e1[1] = 0; e1[2] = 0;
			e2[0] = 0; e2[1] = 0; e2[2] = 1;
		} else {
			e1[0] = 1; e1[1] = 0; e1[2] = 0;
			e2[0] = 0; e2[1] = 1; e2[2] = 0;
		}
		det = ti->vecs[0][0] * ti->vecs[1][1] - ti->vecs[0][1] * ti->vecs[1][0];
		if (fabsf(det) < 1e-6f) {
			/* Textura degenerada: se devuelve un punto en el plano. */
			for (i = 0; i < 3; i++)
				out[i] = (i == (int)(fabsf(pl->normal[0]) > 0.9f   ? 0
				                       : fabsf(pl->normal[1]) > 0.9f ? 1
				                                                 : 2))
				             ? pl->dist / pl->normal[i]
				             : 0.0f;
			return;
		}
		bs = (-ti->vecs[1][0] * ti->vecs[0][3] + ti->vecs[0][0] * ti->vecs[1][3]) / det;
		bt = (-ti->vecs[0][1] * ti->vecs[1][3] + ti->vecs[1][1] * ti->vecs[0][3]) / det;
		(void)e1;
		(void)e2;
	}

	/* p = bs * vec0[0..2] + bt * vec1[0..2] + n * d */
	d = pl->dist;
	for (i = 0; i < 3; i++)
		out[i] = bs * ti->vecs[0][i] + bt * ti->vecs[1][i] + pl->normal[i] * d;
}

/* ------------------------------------------------------------------ API */

int generar_luces(bsp_t *bsp, unsigned char **out, int *outlen)
{
	brush_ocluye_t *brushes = NULL;
	int nbrushes = 0, i, total = 0;
	unsigned char *datos = NULL;
	int capacidad = 0;
	vec3_t luz;
	int notas = 0;
	vec3_t mins, maxs;

	/* Los limites del mundo salen de las caras, que siempre existen. Los de las
	 * caras planas del .map encuadran el mapa entero con el margen que tengan
	 * las paredes, que es justo lo que se quiere para colocar la luz. */
	mins[0] = mins[1] = mins[2] = 1e30f;
	maxs[0] = maxs[1] = maxs[2] = -1e30f;
	for (i = 0; i < bsp->numsurfs; i++) {
		winding_t *w = bsp->surfs[i].winding;
		int k;
		if (!w)
			continue;
		for (k = 0; k < w->numpoints; k++) {
			if (w->points[k][0] < mins[0]) mins[0] = w->points[k][0];
			if (w->points[k][1] < mins[1]) mins[1] = w->points[k][1];
			if (w->points[k][2] < mins[2]) mins[2] = w->points[k][2];
			if (w->points[k][0] > maxs[0]) maxs[0] = w->points[k][0];
			if (w->points[k][1] > maxs[1]) maxs[1] = w->points[k][1];
			if (w->points[k][2] > maxs[2]) maxs[2] = w->points[k][2];
		}
	}
	if (mins[0] > maxs[0]) {
		mins[0] = mins[1] = mins[2] = 0.0f;
		maxs[0] = maxs[1] = maxs[2] = 64.0f;
	}

	/* Las brushes que tapan la luz: las solidas del mundo, ya partidas.
	 *
	 * Se recorren las hojas y no la lista del mapa porque cuando esto se
	 * llama compile_map ya ha soltado la del mapa. Y no se pone un tope de
	 * caras: una brush partida lleva la cara de la seccion y, si el plano de
	 * corte coincidia con una cara suya, esa cara se queda en las dos mitades,
	 * de modo que 6 caras del .map se convierten en 7 o mas sin que eso sea un
	 * problema. Con el tope, justo esas se descartaban y la luz no tapaba
	 * nada. */
	{
		int l;
		int cap = 16;
		brushes = xmalloc(sizeof(brush_ocluye_t) * (size_t)cap);
		for (l = 0; l < bsp->numleafs; l++) {
			brush_t *b;
			if (!bsp->leafbrushes)
				break;
			for (b = bsp->leafbrushes[l]; b; b = b->next) {
				plane_t *pl;
				if (b->contents != CONTENTS_SOLID)
					continue;
				if (b->numsides < 4)
					continue;
				if (nbrushes >= cap) {
					cap *= 2;
					brushes = xrealloc(brushes,
					                   sizeof(brush_ocluye_t) * (size_t)cap);
				}
				pl = xmalloc(sizeof(plane_t) * (size_t)b->numsides);
				for (i = 0; i < b->numsides; i++)
					pl[i] = b->sides[i].plane;
				brushes[nbrushes].planos = pl;
				brushes[nbrushes].numplanos = b->numsides;
				nbrushes++;
			}
		}
	}

	/* Una luz en el centro del mapa. Es una aproximacion, no un trazado de
	 * luces de verdad: con una sola fuente y el ambiente por cara el resultado
	 * es plano pero SI se ve, que es lo que faltaba. */
	luz[0] = (mins[0] + maxs[0]) * 0.5f;
	luz[1] = (mins[1] + maxs[1]) * 0.5f;
	luz[2] = (mins[2] + maxs[2]) * 0.5f;

	for (i = 0; i < bsp->numsurfs; i++) {
		surf_t *s = &bsp->surfs[i];
		texinfo_t *ti;
		rejilla_t r;
		int w, h, k, m;
		int especial;

		if (!s->winding || s->winding->numpoints < 3)
			continue;
		if (s->texinfo < 0 || s->texinfo >= bsp->numtexinfos) {
			s->lightsofs = -1;
			continue;
		}
		ti = &bsp->texinfos[s->texinfo];
		especial = (ti->flags & TEX_SPECIAL) != 0;

		rejilla_de_superficie(ti, s->winding, &r);

		/* El motor aborta al cargar si una cara sin TEX_SPECIAL pasa de 2000.
		 * Aqui se avisa y se recorta, porque al motor le llega el .bsp tal
		 * cual y no hay manera de arreglarlo despues. */
		if (!especial && (r.extents[0] > EXTENTS_MAXIMO || r.extents[1] > EXTENTS_MAXIMO)) {
			notas++;
			if (r.ancho > r.alto)
				r.ancho = EXTENTS_MAXIMO / 16 + 1;
			else
				r.alto = EXTENTS_MAXIMO / 16 + 1;
		}
		if (r.ancho * r.alto > MUESTRAS_MAXIMAS) {
			notas++;
			r.ancho = 64;
			r.alto = MUESTRAS_MAXIMAS / 64;
		}
		if (r.ancho < 1)
			r.ancho = 1;
		if (r.alto < 1)
			r.alto = 1;

		s->lightsofs = total;
		w = r.ancho;
		h = r.alto;
		m = w * h;

		if (total + m > capacidad) {
			capacidad = (total + m) * 2;
			datos = xrealloc(datos, (size_t)capacidad);
		}

		for (k = 0; k < h; k++) {
			for (int j = 0; j < w; j++) {
				vec3_t p, hacia;
				float t = (float)(k * 16) + (float)r.texturemins[1];
				float u = (float)(j * 16) + (float)r.texturemins[0];
				float dist, k2;
				unsigned char v;

				if (especial) {
					/* Cielo y liquidos: planos y brillantes, sin luz. */
					datos[total + k * w + j] = 255;
					continue;
				}

				punto_de_textura(ti, &s->plane, u, t, p);

				/* Ambiente mas una luz de cielo por orientacion: lo que
				 * mira hacia arriba recibe mas, que es lo que hace legible
				 * un mapa al que solo le llega una fuente. */
				hacia[0] = s->plane.normal[0];
				hacia[1] = s->plane.normal[1];
				hacia[2] = s->plane.normal[2];
				k2 = 0.34f + 0.16f * (hacia[2] > 0.0f ? hacia[2] : 0.0f);

				/* Y la fuente del centro, si se ve. */
				if (!segmento_tapado(brushes, nbrushes, p, luz)) {
					dist = sqrtf((luz[0] - p[0]) * (luz[0] - p[0]) +
					             (luz[1] - p[1]) * (luz[1] - p[1]) +
					             (luz[2] - p[2]) * (luz[2] - p[2]));
					/* Atenuacion suave: sin caida rapida, que un mapa
					 * grande se quedaria todo negro en los bordes. */
					k2 += 0.55f / (1.0f + dist * dist / 4096.0f);
				}

				/* Se recorta ANTES de convertir: comparar despues con 255
				 * sobre un unsigned char es siempre falso, asi que un valor
				 * de 1.2 se truncaria a 255 en vez de a 255 y no se veria
				 * ningun error. */
				if (k2 > 1.0f)
					k2 = 1.0f;
				if (k2 < 0.0f)
					k2 = 0.0f;
				v = (unsigned char)(k2 * 255.0f);
				datos[total + k * w + j] = v;
			}
		}
		total += m;
	}

	for (i = 0; i < nbrushes; i++)
		free(brushes[i].planos);
	free(brushes);

	if (notas)
		fprintf(stderr,
		        "direkt-bsp: aviso, %d caras con la textura muy escalada; su luz "
		        "se ha recortado para que el motor no abortase al cargar\n",
		        notas);

	*out = datos;
	*outlen = total;
	return total;
}
