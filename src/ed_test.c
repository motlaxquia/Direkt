/* ed_test.c -- prueba del documento del editor, sin pantalla.
 *
 * GPL-2.0, ver LICENSE en la raiz del repositorio.
 *
 * Se ejecuta con `direkt-edit --selftest`. Todo lo que se comprueba aqui es
 * logica pura: no hay SDL ni OpenGL, asi que esto corre en cualquier banco de
 * pruebas y en un segundo.
 *
 * Lo que se mira, en orden de importancia:
 *
 *   1. Ida y vuelta .map: parse -> edit -> save -> parse tiene que dar el mismo
 *      mapa. Es el requisito de base; si esto falla, el editor corrompe
 *      ficheros.
 *   2. La caja que construye el editor es una brush valida: mismo volumen,
 *      normales hacia fuera, seis caras.
 *   3. Origen explicito en las brush-entities, que es el fallo que hacia que
 *      las plataformas de LibreQuake aparecieran en el centro del mapa.
 *   4. Deshacer y rehacer.
 *   5. El picking por rayo acierta lo que tiene que acertar.
 */

#define _GNU_SOURCE
#include "editor.h"

#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int ok, ko;

static void pass(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	printf("  \033[32mPASA\033[0m  ");
	vprintf(fmt, ap);
	printf("\n");
	va_end(ap);
	ok++;
}

static void fail(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	printf("  \033[31mFALLA\033[0m ");
	vprintf(fmt, ap);
	printf("\n");
	va_end(ap);
	ko++;
}

static void check(int cond, const char *fmt, ...)
{
	va_list ap;
	char msg[512];

	va_start(ap, fmt);
	vsnprintf(msg, sizeof(msg), fmt, ap);
	va_end(ap);
	if (cond)
		pass("%s", msg);
	else
		fail("%s", msg);
}

/* ------------------------------------------------------------------ volumen */

static float brush_volume(brush_t *b)
{
	/* Volumen por el teorema del divergente: sumar el producto mixto de cada
	 * triangulo de las caras, /6. */
	double vol = 0.0;
	int i, j, k;
	for (i = 0; i < b->numsides; i++) {
		winding_t *w = b->sides[i].winding;
		if (!w)
			continue;
		for (j = 1; j + 1 < w->numpoints; j++)
			vol += (double)w->points[0][0] * (w->points[j][1] * w->points[j + 1][2] -
			                                 w->points[j][2] * w->points[j + 1][1]) -
			       (double)w->points[0][1] * (w->points[j][0] * w->points[j + 1][2] -
			                                 w->points[j][2] * w->points[j + 1][0]) +
			       (double)w->points[0][2] * (w->points[j][0] * w->points[j + 1][1] -
			                                 w->points[j][1] * w->points[j + 1][0]);
	}
	(void)k;
	return (float)(vol < 0 ? -vol / 6.0 : vol / 6.0);
}

/* Comprueba que cada cara mira hacia fuera: si su normal tiene la misma
 * direccion que la del centro de la brush a la cara, esta hacia dentro. */
static int brush_normals_out(brush_t *b)
{
	vec3_t mins, maxs, centro;
	int i, k, malas = 0;

	brush_bounds(b, mins, maxs);
	for (k = 0; k < 3; k++)
		centro[k] = (mins[k] + maxs[k]) * 0.5f;

	for (i = 0; i < b->numsides; i++) {
		plane_t pl;
		winding_t *w = b->sides[i].winding;
		float d;
		if (!w)
			continue;
		plane_from_winding(w, &pl);
		d = pl.dist - (pl.normal[0] * centro[0] + pl.normal[1] * centro[1] +
		               pl.normal[2] * centro[2]);
		/* El interior de la brush es dot(n,x) <= dist, asi que el centro
		 * (que esta dentro) tiene que cumplir dot(n,centro) <= dist, o sea
		 * d >= 0. Si d < 0, la normal apunta hacia el interior. */
		if (d < -0.001f)
			malas++;
	}
	return malas;
}

/* ------------------------------------------------------------------ prueba 1 */

static void test_roundtrip(const char *origen)
{
	ed_doc_t *a, *b;
	char *t1, *t2;
	int na, nb;

	printf("\n\033[1m1. Ida y vuelta del .map\033[0m\n");

	a = ed_doc_load(origen);
	na = ed_num_brushes(a);
	t1 = save_map_to_string(a->map);

	b = ed_doc_new();
	/* Se escribe a disco porque ed_doc_load lee de fichero. */
	{
		char tmp[TMP_PATH_MAX];
		FILE *f;
		if (!temp_file(tmp, sizeof tmp, "rt"))
			error("no se puede crear el temporal de la ida y vuelta");
		f = fopen(tmp, "wb");
		if (!f)
			error("no se puede escribir el temporal de la ida y vuelta");
		fwrite(t1, 1, strlen(t1), f);
		fclose(f);
		ed_doc_free(b);
		b = ed_doc_load(tmp);
		remove(tmp);
	}
	nb = ed_num_brushes(b);
	t2 = save_map_to_string(b->map);

	check(na == nb && na > 0, "el numero de brushes se conserva al releer (%d -> %d)",
	      na, nb);
	check(strcmp(t1, t2) == 0, "el texto del .map es identico tras la ida y vuelta");
	check(ed_num_entities(a) == ed_num_entities(b),
	      "el numero de entidades se conserva (%d -> %d)", ed_num_entities(a),
	      ed_num_entities(b));

	free(t1);
	free(t2);
	ed_doc_free(a);
	ed_doc_free(b);
}

/* ------------------------------------------------------------------ prueba 2 */

static void test_box(void)
{
	vec3_t mins = {-64.0f, -64.0f, 0.0f};
	vec3_t maxs = {64.0f, 64.0f, 32.0f};
	brush_t *b;
	float v;
	vec3_t bm, bM;

	printf("\n\033[1m2. La brush caja que crea el editor es valida\033[0m\n");

	b = brush_make_box(mins, maxs, "notexture");
	if (!b) {
		fail("brush_make_box devolvio NULL");
		return;
	}
	check(b->numsides == 6, "la caja tiene 6 caras (%d)", b->numsides);
	brush_bounds(b, bm, bM);
	check(fabsf(bm[0] + 64.0f) < 0.01f && fabsf(bM[0] - 64.0f) < 0.01f &&
	          fabsf(bm[2]) < 0.01f && fabsf(bM[2] - 32.0f) < 0.01f,
	      "los limites son los pedidos");
	v = brush_volume(b);
	/* 128 x 128 x 32 */
	check(fabsf(v - 128.0f * 128.0f * 32.0f) < 1.0f,
	      "el volumen es el correcto (%.1f, esperado %.1f)", (double)v,
	      (double)(128.0f * 128.0f * 32.0f));
	check(brush_normals_out(b) == 0,
	      "las 6 caras miran hacia fuera (%d invertidas)", brush_normals_out(b));
	brush_free(b);
}

/* ------------------------------------------------------------------ prueba 3 */

static void test_origin(void)
{
	ed_doc_t *d = ed_doc_new();
	entity_t *puerta;
	vec3_t mins = {100.0f, 100.0f, 0.0f};
	vec3_t maxs = {132.0f, 116.0f, 96.0f};
	char *texto;
	const char *o;

	printf("\n\033[1m3. Las brush-entities se guardan con origin explicito\033[0m\n");

	puerta = ed_add_entity(d, "func_door", mins);
	ed_add_box(d, puerta, mins, maxs, "notexture");

	texto = save_map_to_string(d->map);
	o = strstr(texto, "\"func_door\"");
	check(o != NULL, "la entidad se escribe");
	/* El origin tiene que estar en la misma entidad que el classname. */
	if (o) {
		const char *org = strstr(o, "\"origin\"");
		const char *fin = strchr(o, '}');
		check(org != NULL && fin != NULL && org < fin,
		      "la entidad tiene origin dentro de su propio bloque");
		/* Tras la clave y su separador empieza el valor. */
		check(org && strstr(org, "\"100 100 0\"") != NULL,
		      "el origin son los limites de la brush");
	}
	/* Y tiene que sobrevivir a la ida y vuelta. */
	check(strstr(texto, "\"origin\"") != NULL, "el .map lleva origin");
	free(texto);
	ed_doc_free(d);
}

/* ------------------------------------------------------------------ prueba 4 */

static void test_undo(void)
{
	ed_doc_t *d = ed_doc_new();
	int n0, n1, n2;

	printf("\n\033[1m4. Deshacer y rehacer\033[0m\n");

	n0 = ed_num_brushes(d);
	ed_add_box(d, NULL, (float[]){0, 0, 0}, (float[]){64, 64, 64}, "notexture");
	n1 = ed_num_brushes(d);
	ed_add_box(d, NULL, (float[]){96, 96, 0}, (float[]){160, 160, 64}, "notexture");
	n2 = ed_num_brushes(d);

	check(n1 == n0 + 1 && n2 == n0 + 2, "las cajas anadidas cuentan (%d, %d, %d)", n0, n1,
	      n2);

	check(ed_undo(d) && ed_num_brushes(d) == n1, "deshacer quita la ultima caja");
	check(ed_undo(d) && ed_num_brushes(d) == n0, "deshacer quita la primera");
	check(ed_undo(d) == 0, "no se puede deshacer mas alla del principio");
	check(ed_redo(d) && ed_num_brushes(d) == n1, "rehacer devuelve la primera");
	check(ed_redo(d) && ed_num_brushes(d) == n2, "rehacer devuelve la segunda");
	check(ed_redo(d) == 0, "no se puede rehacer mas");

	/* Un cambio nuevo descarta lo rehecho. */
	ed_add_box(d, NULL, (float[]){0, 200, 0}, (float[]){64, 264, 64}, "notexture");
	check(ed_redo(d) == 0, "un cambio nuevo borra la pila de rehacer");

	ed_doc_free(d);
}

/* ------------------------------------------------------------------ prueba 5 */

static void test_pick(void)
{
	ed_doc_t *d = ed_doc_new();
	vec3_t org, dir, mins = {0, 0, 0}, maxs = {64, 64, 64};
	brush_t *b1;
	vec3_t org2 = {200, 0, 0}, maxs2 = {264, 64, 64};
	brush_t *b2;
	vec3_t a, b;

	printf("\n\033[1m5. El raton acierta la brush que se ve\033[0m\n");

	b1 = ed_add_box(d, NULL, mins, maxs, "notexture");
	b2 = ed_add_box(d, NULL, org2, maxs2, "notexture");

	/* Rayo desde (32,32,200) hacia abajo: tiene que caer en la primera. */
	org[0] = 32.0f; org[1] = 32.0f; org[2] = 200.0f;
	dir[0] = 0.0f; dir[1] = 0.0f; dir[2] = -1.0f;
	check(ed_pick(d, org, dir) == b1, "el rayo vertical acierta la caja de abajo");

	org[0] = 232.0f;
	check(ed_pick(d, org, dir) == b2, "el rayo shifted acierta la otra caja");

	/* Entre las dos, en el aire: no hay brush. */
	org[0] = 120.0f;
	check(ed_pick(d, org, dir) == NULL, "un rayo al vacio no selecciona nada");

	/* De lado, contra la cara de +x de la primera caja. */
	a[0] = -100.0f; a[1] = 32.0f; a[2] = 32.0f;
	b[0] = 1.0f; b[1] = 0.0f; b[2] = 0.0f;
	check(ed_pick(d, a, b) == b1, "un rayo horizontal acierta la cara lateral");

	/* Desde dentro hacia arriba sale por la cara de arriba. */
	a[0] = 32.0f; a[1] = 32.0f; a[2] = 32.0f;
	b[0] = 0.0f; b[1] = 0.0f; b[2] = 1.0f;
	check(ed_pick(d, a, b) == b1, "un rayo desde dentro sale por la cara correcta");

	ed_doc_free(d);
}

/* ------------------------------------------------------------------ prueba 6 */

static void test_edit(void)
{
	ed_doc_t *d = ed_doc_new();
	brush_t *b;
	vec3_t mins = {0, 0, 0}, maxs = {64, 64, 64};
	vec3_t bm, bM;

	printf("\n\033[1m6. Mover y arrastrar caras\033[0m\n");

	b = ed_add_box(d, NULL, mins, maxs, "notexture");
	brush_bounds(b, bm, bM);

	ed_translate_brush(d, b, (float[]){32.0f, 0.0f, 0.0f});
	brush_bounds(b, bm, bM);
	check(fabsf(bm[0] - 32.0f) < 0.01f && fabsf(bM[0] - 96.0f) < 0.01f,
	      "trasladar mueve la brush entera");

	/* La brush tiene que seguir siendo valida despues de moverla: si el
	 * plano se queda atras, al recompilar se parte sola. */
	check(brush_normals_out(b) == 0, "las normales siguen mirando hacia fuera");
	check(fabsf(brush_volume(b) - 64.0f * 64.0f * 64.0f) < 1.0f,
	      "el volumen no cambia al.translate (%.1f)", (double)brush_volume(b));

	/* Arrastrar la cara de +x 16 unidades hacia dentro. Como la brush es una
	 * caja perfecta, esto tiene que estirar la caja, no deformarla. */
	{
		int lado = -1, i;
		for (i = 0; i < b->numsides; i++)
			if (b->sides[i].plane.normal[0] > 0.9f)
				lado = i;
		check(lado >= 0, "se encuentra la cara de +x");
		ed_drag_side(d, b, lado, -16.0f);
		brush_bounds(b, bm, bM);
		check(fabsf(bM[0] - 80.0f) < 0.01f && fabsf(bm[0] - 32.0f) < 0.01f,
		      "arrastrar la cara de una caja encoge la caja");
		check(fabsf(brush_volume(b) - 48.0f * 64.0f * 64.0f) < 1.0f,
		      "el volumen baja lo justo (%.1f)", (double)brush_volume(b));
		check(brush_normals_out(b) == 0, "sigue siendo una caja valida");
	}

	/* Rejilla. */
	check(ed_snapped(7.0f, 16) == 0, "la rejilla de 16 redondea 7 a 0 (mas cerca de 0)");
	check(ed_snapped(9.0f, 16) == 16, "la rejilla de 16 redondea 9 a 16");
	check(ed_snapped(-7.0f, 16) == 0, "la rejilla redondea -7 a 0 (simetrica)");
	check(ed_snapped(23.0f, 16) == 16, "la rejilla redondea 23 a 16");

	/* Formato de numeros. */
	{
		char b1[32];
		check(strcmp(ed_fmt_num(288.0f, b1, sizeof(b1)), "288") == 0,
		      "los enteros se escriben sin decimales (%s)", b1);
		ed_fmt_num(0.5f, b1, sizeof(b1));
		check(strcmp(b1, "0.5") == 0, "los decimales se escriben sin ceros (%s)", b1);
		ed_fmt_num(-16.0f, b1, sizeof(b1));
		check(strcmp(b1, "-16") == 0, "los negativos (%s)", b1);
	}

	ed_doc_free(d);
}

/* ------------------------------------------------------------------ prueba 7 */

/* Lo que mas se ha roto al compilar: un mapa que el editor guarda tiene que
 * volver a entrar en el compilador y dar un .bsp valido. */
static void test_compile(void)
{
	ed_doc_t *d = ed_doc_new();
	entity_t *e;
	char tmp[TMP_PATH_MAX];
	FILE *f;
	map_t *m;
	bsp_t *bsp;
	char bspf[TMP_PATH_MAX];

	printf("\n\033[1m7. Un mapa hecho en el editor compila\033[0m\n");

	/* Una habitacion: suelo, techo y cuatro muros, como los mapas a mano. */
	ed_add_box(d, NULL, (float[]){-16, -16, -16}, (float[]){272, 272, 0}, "notexture");
	ed_add_box(d, NULL, (float[]){-16, -16, 128}, (float[]){272, 272, 144}, "notexture");
	ed_add_box(d, NULL, (float[]){-16, -16, 0}, (float[]){0, 272, 128}, "notexture");
	ed_add_box(d, NULL, (float[]){256, -16, 0}, (float[]){272, 272, 128}, "notexture");
	ed_add_box(d, NULL, (float[]){-16, -16, 0}, (float[]){256, 0, 128}, "notexture");
	ed_add_box(d, NULL, (float[]){-16, 256, 0}, (float[]){256, 272, 128}, "notexture");
	e = ed_add_entity(d, "info_player_start", (float[]){32, 32, 32});

	if (!temp_file(tmp, sizeof tmp, "ed") || !temp_file(bspf, sizeof bspf, "bsp"))
		error("no se puede crear el temporal del mapa de prueba");
	f = fopen(tmp, "wb");
	if (!f)
		error("no se puede escribir el temporal del mapa de prueba");
	{
		char *texto = save_map_to_string(d->map);
		fputs(texto, f);
		free(texto);
	}
	fclose(f);

	m = parse_map(tmp);
	check(m->numbrushes == 6, "el parser ve las 6 brushes (%d)", m->numbrushes);
	check(entity_key(m->entities->next, "classname") != NULL,
	      "la entidad del punto de aparicion se lee");
	(void)e;

	bsp = compile_map(m);
	check(bsp != NULL && bsp->numnodes > 0, "el .map se compila (%d nodos)",
	      bsp ? bsp->numnodes : 0);

	check(write_bsp(bspf, bsp, m) == 0, "el .bsp se escribe");
	check(check_bsp(bspf) == 0, "el .bsp pasa el validador");

	remove(tmp);
	remove(bspf);
	free_bsp(bsp);
	free_map(m);
	ed_doc_free(d);
}

/* -------------------------------------------------------------------- main */

int ed_selftest(const char *mapa)
{
	printf("\033[1mPrueba del documento del editor\033[0m\n");
	test_box();
	test_origin();
	test_undo();
	test_pick();
	test_edit();
	test_compile();
	if (mapa)
		test_roundtrip(mapa);

	printf("\n\033[1mResultado\033[0m\n  %d pasan, %d fallan\n", ok, ko);
	if (ko == 0)
		printf("\033[32mSELFTEST DEL EDITOR CORRECTO\033[0m\n");
	else
		printf("\033[31mSELFTEST DEL EDITOR CON FALLOS\033[0m\n");
	return ko ? 1 : 0;
}
