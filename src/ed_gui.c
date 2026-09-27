/* ed_gui.c -- ventana del editor con SDL2 y OpenGL 1.2.
 *
 * GPL-2.0, ver LICENSE en la raiz del repositorio.
 *
 * Esta es la unica capa que toca la biblioteca grafica. Todo lo que se puede
 * decidir sin ventana (que brush hay bajo el raton, como se guarda, que hace
 * el deshacer) esta en ed_doc.c y se prueba sin pantalla.
 *
 * Se dibuja con OpenGL 1.2 en modo inmediato, sin shaders: es lo que hay
 * disponible en cualquier Linux y lo que ya usa el propio motor. La vista
 * distinction entre alambre y solido es util: con alambre se ve que hay
 * dentro de un muro, que es lo que importa al colocar cosas, y el solido
 * ayuda a leer la forma.
 */

#define _GNU_SOURCE
#include "ed_gui.h"
#include "ed_view.h"
#include "tex.h"
#include "edtex.h"

#include <math.h>
#include <stdarg.h>
#include <SDL.h>
/* SDL_opengl.h trae las extensiones de SDL; las funciones base de GL 1.2 y sus
 * constantes estan en GL/gl.h, que es lo unico que se usa aqui. */
#include <SDL_opengl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* --------------------------------------------------------------- estado GUI */

typedef struct {
	SDL_Window *win;
	SDL_GLContext ctx;
	ed_doc_t *doc;
	ed_cam_t cam;
	int ancho, alto;
	int quit;
	int boton_izq;              /* se mantiene pulsado: se esta arrastrando */
	int boton_der_mirando;      /* el boton derecho mira, con raton escondido */
	int ultimo_mx, ultimo_my;
	int atrapado_a;             /* distancia del centro de la brush al rayo */
	float arrastre_dz;          /* quanto se ha arrastrado en vertical */
	int modo_arrastre;          /* 0 = nada, 1 = arrastrando */
	int renderer;               /* 0 = alambre, 1 = solido */
	/* Atlas de texturas de la vista. NULL si no hay biblioteca, y entonces se
	 * dibuja con colores planos como antes. */
	edtex_t *atlas;
	int mostrar_ayuda;
	char mensaje[256];
	float msg_hasta;
	char textura_actual[64];
} ed_gui_t;

static void avisar(ed_gui_t *g, const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(g->mensaje, sizeof(g->mensaje), fmt, ap);
	va_end(ap);
	/* El mensaje dura 4 segundos de reloj de pared. */
	g->msg_hasta = (float)SDL_GetTicks() / 1000.0f + 4.0f;
}

/* ------------------------------------------------------------------ dibujado */

static void dibuja_brush(ed_gui_t *gui, brush_t *b, int sel, int sel_side, int trigger,
                        int renderer)
{
	int i;
	float r, g, bl;
	int con_texturas = gui->atlas != NULL;

	if (trigger) {
		/* Los triggers se dibujan en un color distinto porque si no se
		 * confunden con los muros y el jugador acaba andando a traves de
		 * ellos sin querer. */
		r = 0.35f; g = 0.85f; bl = 0.95f;
	} else if (sel) {
		r = 1.0f; g = 0.55f; bl = 0.1f;
	} else {
		r = 0.85f; g = 0.85f; bl = 0.9f;
	}

	if (renderer == 1) {
		/* Sin texturas ni iluminacion real, la unica pista de que direccion
		 * mira cada cara es lo clara u oscura que se pinta. Se usa la normal
		 * de verdad contra una luz fija: con un factor por indice de cara,
		 * dos caras opuestas salian igual de claras y no se distinguia un
		 * muro del suelo. */
		static const vec3_t luz = {-0.42f, -0.57f, 0.71f};
		glDisable(GL_CULL_FACE);
		for (i = 0; i < b->numsides; i++) {
			winding_t *w = b->sides[i].winding;
			plane_t n;
			vec3_t xv, yv;
			float d, k;
			int con_uv = 0;
			if (!w || w->numpoints < 3)
				continue;
			plane_from_winding(w, &n);
			d = n.normal[0] * luz[0] + n.normal[1] * luz[1] + n.normal[2] * luz[2];
			/* 0.30 de suelo para que ninguna cara se blackeree del todo y
			 * llegue a 1.0 justo en la que mira a la luz. */
			k = 0.30f + 0.70f * (d > 0.0f ? d : 0.0f);
			glColor3f(r * k, g * k, bl * k);
			/* Con la atlas, la cara se pinta con su textura de verdad. Las
			 * coordenadas salen de los MISMOS ejes que usa el compilador, con
			 * brush_side_axes, para que lo que se ve aqui sea exactamente lo
			 * que se vera en el juego. */
			if (con_texturas) {
				if (edtex_celda(gui->atlas, b->sides[i].texname) >= 0) {
					glEnable(GL_TEXTURE_2D);
					glBindTexture(GL_TEXTURE_2D, edtex_gl(gui->atlas));
					brush_side_axes(&b->sides[i], &n, xv, yv);
					con_uv = 1;
				} else {
					glDisable(GL_TEXTURE_2D);
				}
			}
			glBegin(GL_POLYGON);
			for (int q = 0; q < w->numpoints; q++) {
				/* La coordenada de textura va ANTES del vertice: en el modo
				 * inmediato de OpenGL cada glTexCoord se aplica al glVertex
				 * siguiente, no al anterior. Ponerla despues deja cada
				 * vertice con la del anterior y la cara sale de un color
				 * plano. */
				if (con_uv) {
					float s, t, u, vv;
					s = w->points[q][0] * xv[0] + w->points[q][1] * xv[1] +
					    w->points[q][2] * xv[2];
					t = w->points[q][0] * yv[0] + w->points[q][1] * yv[1] +
					    w->points[q][2] * yv[2];
					if (edtex_uv(gui->atlas, b->sides[i].texname, s, t, &u, &vv))
						glTexCoord2f(u, vv);
				}
				glVertex3f(w->points[q][0], w->points[q][1], w->points[q][2]);
			}
			glEnd();
		}
		glEnable(GL_CULL_FACE);
		glDisable(GL_TEXTURE_2D);
	}

	/* El contorno siempre se dibuja, incluso en modo solido: es lo que
	 * permite ver donde acaba una brush y donde empieza la de al lado. */
	for (i = 0; i < b->numsides; i++) {
		winding_t *w = b->sides[i].winding;
		if (!w || w->numpoints < 3)
			continue;
		if (sel && i == sel_side)
			glColor3f(1.0f, 0.1f, 0.1f);
		else
			glColor3f(r, g, bl);
		glBegin(GL_LINE_LOOP);
		for (int q = 0; q < w->numpoints; q++)
			glVertex3f(w->points[q][0], w->points[q][1], w->points[q][2]);
		glEnd();
	}
}

static void dibuja_rejilla(ed_gui_t *g)
{
	vec3_t mins, maxs;
	float x, y;
	int gsz = g->doc->grid_size;

	ed_doc_bounds(g->doc, mins, maxs);
	/* Se acota el numero de lineas: una rejilla de 800 lineas a 1 unidad
	 * haria el dibujo mas lento que el resto de la escena junta. */
	if (maxs[0] - mins[0] > 2048.0f)
		mins[0] = maxs[0] - 2048.0f;
	if (maxs[1] - mins[1] > 2048.0f)
		mins[1] = maxs[1] - 2048.0f;

	glColor3f(0.22f, 0.24f, 0.28f);
	glBegin(GL_LINES);
	for (x = floorf(mins[0] / gsz) * gsz; x <= maxs[0]; x += gsz) {
		glVertex3f(x, mins[1], mins[2]);
		glVertex3f(x, maxs[1], mins[2]);
	}
	for (y = floorf(mins[1] / gsz) * gsz; y <= maxs[1]; y += gsz) {
		glVertex3f(mins[0], y, mins[2]);
		glVertex3f(maxs[0], y, mins[2]);
	}
	glEnd();
}

static void dibuja_entidades(ed_gui_t *g)
{
	entity_t *e;
	vec3_t mins, maxs;
	brush_t *b;
	entity_t *w = g->doc->map->entities;

	glDisable(GL_CULL_FACE);
	for (e = w ? w->next : NULL; e; e = e->next) {
		const char *cn = entity_key(e, "classname");
		const char *o = entity_key(e, "origin");
		float org[3] = {0, 0, 0};
		float tam;
		int sel = (e == g->doc->sel_entity);

		if (cn && strcmp(cn, "info_player_start") == 0) {
			if (o)
				sscanf(o, "%f %f %f", &org[0], &org[1], &org[2]);
			/* El punto de aparicion se dibuja como una flecha vertical con
			 * su angulo, que es justo lo que hay que colocar bien. */
			glColor3f(0.2f, 1.0f, 0.3f);
			glBegin(GL_LINES);
			glVertex3f(org[0], org[1], org[2] - 24.0f);
			glVertex3f(org[0], org[1], org[2] + 48.0f);
			glVertex3f(org[0], org[1], org[2]);
			glVertex3f(org[0] + 40.0f, org[1], org[2]);
			glEnd();
			glPointSize(5.0f);
			glBegin(GL_POINTS);
			glVertex3f(org[0], org[1], org[2] + 48.0f);
			glEnd();
			continue;
		}
		if (!e->brushes)
			continue;
		/* El centro de una entidad con brushes es el punto de partida de
		 * la primera: es lo que el motor va a usar como origen. */
		brush_bounds(e->brushes, mins, maxs);
		tam = 0.0f;
		for (b = e->brushes; b; b = b->next) {
			vec3_t bm, bM;
			brush_bounds(b, bm, bM);
			if (bm[0] < mins[0]) { mins[0] = bm[0]; maxs[0] = bM[0]; }
			if (bm[1] < mins[1]) { mins[1] = bm[1]; maxs[1] = bM[1]; }
			if (bm[2] < mins[2]) { mins[2] = bm[2]; maxs[2] = bM[2]; }
		}
		org[0] = (mins[0] + maxs[0]) * 0.5f;
		org[1] = (mins[1] + maxs[1]) * 0.5f;
		org[2] = mins[2];
		tam = 8.0f;
		glColor3f(sel ? 1.0f : 0.95f, sel ? 0.5f : 0.85f, 1.0f);
		glBegin(GL_LINE_LOOP);
		glVertex3f(org[0] - tam, org[1] - tam, org[2]);
		glVertex3f(org[0] + tam, org[1] - tam, org[2]);
		glVertex3f(org[0] + tam, org[1] + tam, org[2]);
		glVertex3f(org[0] - tam, org[1] + tam, org[2]);
		glEnd();
		glBegin(GL_LINES);
		glVertex3f(org[0], org[1], org[2]);
		glVertex3f(org[0], org[1], org[2] + 24.0f);
		glEnd();
	}
	glEnable(GL_CULL_FACE);
}

static void dibuja_escena(ed_gui_t *g)
{
	brush_t *b;
	vec3_t fwd, up;
	float proj[16], view[16], mv[16];

	ed_cam_forward(&g->cam, fwd);
	ed_cam_up(&g->cam, up);
	ed_matrix_perspective(proj, g->cam.fov, (float)g->ancho / (float)g->alto,
	                      g->cam.znear, 65536.0f);
	ed_matrix_look_at(view, g->cam.org, fwd, up);
	ed_matrix_multiply(mv, proj, view);
	/* dibuja_hud deja el modo en GL_PROJECTION para el HUD. Si aqui no se
	 * vuelve a MODELVIEW, la matriz de vista se carga en la de proyeccion y
	 * desde el primer fotograma no se ve nada. */
	glMatrixMode(GL_MODELVIEW);
	glLoadMatrixf(mv);

	if (g->doc->show_grid)
		dibuja_rejilla(g);

	for (b = g->doc->map->brushes; b; b = b->next) {
		int sel = (b == g->doc->sel_brush);
		int trig = (b->contents == CONTENTS_EMPTY);
		if (trig && !g->doc->show_triggers)
			continue;
		dibuja_brush(g, b, sel, (sel ? g->doc->sel_side : -1), trig, g->renderer);
	}
	dibuja_entidades(g);
}

/* -------------------------------------------------------------- HUD con GL */

/* Texto 5x7 dibujado con quads: sin fuentes ni texturas, y a 1 pixel por
 * celda se lee de sobra a 1280x960.
 *
 * La tabla va indexada POR CARACTER ASCII con inicializadores designados, no
 * con bloques seguidos. Con una tabla de 96 filas seguidas es facil equivocar la
 * cuenta y que cada letra salga con el dibujo de otra: el texto se vuelve
 * ilegible sin que nada falle. Con [65] = ... no hay forma de que el glifo de
 * la A acabe en el sitio del 5.
 *
 * Lo que no este en la tabla se dibuja como un cuadrito, que es mejor que un
 * hueco y delata el caracter que falta. */
/* Texto 5x7 dibujado con quads: sin fuentes ni texturas, y a un pixel por
 * celda se lee de sobra a 1280x960.
 *
 * La tabla va indexada POR CARACTER ASCII con inicializadores designados, no
 * con bloques de filas seguidas. Con una tabla de 96 filas seguidas es facil
 * equivocar la cuenta y que cada letra salga con el dibujo de otra: el texto se
 * vuelve ilegible sin que nada falle ni avise. Con [65] = ... no hay forma de
 * que el glifo de la A acabe en el sitio del 5.
 *
 * Cada glifo son 7 filas de 5 caracteres. Entre una fila y la siguiente hay un
 * hueco en la cadena, asi que el indice es fila * 6 + columna y el ancho esta
 * a la vista en vez de escondido en un numero.
 */
static const char *const glifo5x7[128][7] = {
    /*  32   */ [32] = {"     ","     ","     ","     ","     ","     ","     "},
    /*  33 ! */ [33] = {"  X  ","  X  ","  X  ","  X  ","  X  ","     ","  X  "},
    /*  34 " */ [34] = {" X X "," X X ","     ","     ","     ","     ","     "},
    /*  35 # */ [35] = {" X X "," X X ","XXXXX"," X X ","XXXXX"," X X "," X X "},
    /*  36 $ */ [36] = {"  XX "," X   "," XXX ","X   X"," XXX ","   X "," XX  "},
    /*  37 % */ [37] = {"XX  X","XX  X","   X ","  X  "," X   ","X  XX","X  XX"},
    /*  38 & */ [38] = {" XX  "," X  X","  X  ","  X  "," X   "," X  X","  XX "},
    /*  39 ' */ [39] = {"  X  ","  X  ","     ","     ","     ","     ","     "},
    /*  40 ( */ [40] = {"   X ","  X  "," X   "," X   "," X   ","  X  ","   X "},
    /*  41 ) */ [41] = {" X   ","  X  ","   X ","   X ","   X ","  X  "," X   "},
    /*  42 * */ [42] = {"     "," X X ","  X  ","XXXXX","  X  "," X X ","     "},
    /*  43 + */ [43] = {"     ","  X  ","  X  ","XXXXX","  X  ","  X  ","     "},
    /*  44 , */ [44] = {"     ","     ","     ","     ","     "," XX  ","  X  "},
    /*  45 - */ [45] = {"     ","     ","     ","XXXXX","     ","     ","     "},
    /*  46 . */ [46] = {"     ","     ","     ","     ","     "," XX  "," XX  "},
    /*  47 / */ [47] = {"    X","    X","   X ","  X  "," X   ","X    ","X    "},
    /*  48 0 */ [48] = {" XXX ","X   X","X  XX","X X X","XX  X","X   X"," XXX "},
    /*  49 1 */ [49] = {"  X  "," XX  ","  X  ","  X  ","  X  ","  X  "," XXX "},
    /*  50 2 */ [50] = {" XXX ","X   X","    X","   X ","  X  "," X   ","XXXXX"},
    /*  51 3 */ [51] = {"XXXXX","   X ","  X  ","   X ","    X","X   X"," XXX "},
    /*  52 4 */ [52] = {"   X ","  XX "," X  X","X   X","XXXXX","    X","    X"},
    /*  53 5 */ [53] = {"XXXXX","X    ","XXXX ","    X","    X","X   X"," XXX "},
    /*  54 6 */ [54] = {"  XX "," X   ","X    ","XXXX ","X   X","X   X"," XXX "},
    /*  55 7 */ [55] = {"XXXXX","    X","   X ","  X  "," X   "," S   "," S   "},
    /*  56 8 */ [56] = {" XXX ","X   X","X   X"," XXX ","X   X","X   X"," XXX "},
    /*  57 9 */ [57] = {" XXX ","X   X","X   X"," XXX ","    X","   X "," XX  "},
    /*  58 : */ [58] = {"     "," XX  "," XX  ","     "," XX  "," XX  ","     "},
    /*  59 ; */ [59] = {"     "," XX  "," XX  ","     "," XX  ","  X  "," X   "},
    /*  60 < */ [60] = {"   X ","  X  "," X   ","X    "," X   ","  X  ","   X "},
    /*  61 = */ [61] = {"     ","     ","XXXXX","     ","XXXXX","     ","     "},
    /*  62 > */ [62] = {" X   ","  X  ","   X ","    X","   X ","  X  "," X   "},
    /*  63 ? */ [63] = {"  X  ","   X ","   X ","   X ","     ","  X  ","  X  "},
    /*  64 @ */ [64] = {"  X  "," X   ","X  X ","X   X","     ","     ","  X  "},
    /*  65 A */ [65] = {" XXX ","X   X","X   X","XXXXX","X   X","X   X","X   X"},
    /*  66 B */ [66] = {"XXXX ","X   X","X   X","XXXX ","X   X","X   X","XXXX "},
    /*  67 C */ [67] = {" XXX ","X   X","X    ","X    ","X    ","X   X"," XXX "},
    /*  68 D */ [68] = {"XXXX ","X   X","X   X","X   X","X   X","X   X","XXXX "},
    /*  69 E */ [69] = {"XXXXX","X    ","X    ","XXXX ","X    ","X    ","XXXXX"},
    /*  70 F */ [70] = {"XXXXX","X    ","X    ","XXXX ","X    ","X    ","X    "},
    /*  71 G */ [71] = {" XXX ","X   X","X    ","X    ","X  X ","X   X"," XXX "},
    /*  72 H */ [72] = {"X   X","X   X","X   X","XXXXX","X   X","X   X","X   X"},
    /*  73 I */ [73] = {" XXX ","  X  ","  X  ","  X  ","  X  ","  X  "," XXX "},
    /*  74 J */ [74] = {"  XXX","   X ","   X ","   X ","   X ","X  X "," XX  "},
    /*  75 K */ [75] = {"X   X","X   X","X  X ","X X  ","XX   ","X   X","X   X"},
    /*  76 L */ [76] = {"X    ","X    ","X    ","X    ","X    ","X    ","XXXXX"},
    /*  77 M */ [77] = {"X   X","X   X","XX XX","X X X","X   X","X   X","X   X"},
    /*  78 N */ [78] = {"X   X","X   X","XX  X","X X X","X  XX","X   X","X   X"},
    /*  79 O */ [79] = {" XXX ","X   X","X   X","X   X","X   X","X   X"," XXX "},
    /*  80 P */ [80] = {"XXXX ","X   X","X   X","XXXX ","X    ","X    ","X    "},
    /*  81 Q */ [81] = {" XXX ","X   X","X   X","X   X","X X X","X  X "," XX X"},
    /*  82 R */ [82] = {"XXXX ","X   X","X   X","XXXX ","X X  ","X  X ","X   X"},
    /*  83 S */ [83] = {" XXX ","X   X","X    "," XX  ","   X ","X   X"," XXX "},
    /*  84 T */ [84] = {"XXXXX","  X  ","  X  ","  X  ","  X  ","  X  ","  X  "},
    /*  85 U */ [85] = {"X   X","X   X","X   X","X   X","X   X","X   X"," XXX "},
    /*  86 V */ [86] = {"X   X","X   X","X   X","X   X","X   X"," X X ","  X  "},
    /*  87 W */ [87] = {"X   X","X   X","X   X","X   X","X X X","X X X"," X X "},
    /*  88 X */ [88] = {"X   X","X   X"," X X ","  X  "," X X ","X   X","X   X"},
    /*  89 Y */ [89] = {"X   X","X   X"," X X ","  X  ","  X  ","  X  ","  X  "},
    /*  90 Z */ [90] = {"XXXXX","    X","   X ","  X  "," X   "," X   ","X    "},
    /*  91 [ */ [91] = {" X   ","  X  ","   X ","   X ","   X ","  X  "," X   "},
    /*  92 \\ */ [92] = {"X    "," X   ","  X  ","   X ","  X  "," X   ","X    "},
    /*  93 ] */ [93] = {"   X ","  X  "," X   "," X   "," X   ","  X  ","   X "},
    /*  94 ^ */ [94] = {"  X  "," X   ","X  X ","X   X","     ","     ","     "},
    /*  95 _ */ [95] = {"     ","     ","     ","     ","     ","    X","    X"},
    /*  96 ` */ [96] = {"XXXXX","XXXXX","XXXXX","XXXXX","XXXXX","XXXXX","XXXXX"},
    /*  97 a */ [97] = {" XXX ","X   X","X   X","XXXXX","X   X","X   X","X   X"},
    /*  98 b */ [98] = {"XXXX ","X   X","X   X","XXXX ","X   X","X   X","XXXX "},
    /*  99 c */ [99] = {" XXX ","X   X","X    ","X    ","X    ","X   X"," XXX "},
    /* 100 d */ [100] = {"XXXX ","X   X","X   X","X   X","X   X","X   X","XXXX "},
    /* 101 e */ [101] = {"XXXXX","X    ","X    ","XXXX ","X    ","X    ","XXXXX"},
    /* 102 f */ [102] = {"XXXXX","X    ","X    ","XXXX ","X    ","X    ","X    "},
    /* 103 g */ [103] = {" XXX ","X   X","X    ","X    ","X  X ","X   X"," XXX "},
    /* 104 h */ [104] = {"X   X","X   X","X   X","XXXXX","X   X","X   X","X   X"},
    /* 105 i */ [105] = {" XXX ","  X  ","  X  ","  X  ","  X  ","  X  "," XXX "},
    /* 106 j */ [106] = {"  XXX","   X ","   X ","   X ","   X ","X  X "," XX  "},
    /* 107 k */ [107] = {"X   X","X   X","X  X ","X X  ","XX   ","X   X","X   X"},
    /* 108 l */ [108] = {"X    ","X    ","X    ","X    ","X    ","X    ","XXXXX"},
    /* 109 m */ [109] = {"X   X","X   X","XX XX","X X X","X   X","X   X","X   X"},
    /* 110 n */ [110] = {"X   X","X   X","XX  X","X X X","X  XX","X   X","X   X"},
    /* 111 o */ [111] = {" XXX ","X   X","X   X","X   X","X   X","X   X"," XXX "},
    /* 112 p */ [112] = {"XXXX ","X   X","X   X","XXXX ","X    ","X    ","X    "},
    /* 113 q */ [113] = {" XXX ","X   X","X   X","X   X","X X X","X  X "," XX X"},
    /* 114 r */ [114] = {"XXXX ","X   X","X   X","XXXX ","X X  ","X  X ","X   X"},
    /* 115 s */ [115] = {" XXX ","X   X","X    "," XX  ","   X ","X   X"," XXX "},
    /* 116 t */ [116] = {"XXXXX","  X  ","  X  ","  X  ","  X  ","  X  ","  X  "},
    /* 117 u */ [117] = {"X   X","X   X","X   X","X   X","X   X","X   X"," XXX "},
    /* 118 v */ [118] = {"X   X","X   X","X   X","X   X","X   X"," X X ","  X  "},
    /* 119 w */ [119] = {"X   X","X   X","X   X","X   X","X X X","X X X"," X X "},
    /* 120 x */ [120] = {"X   X","X   X"," X X ","  X  "," X X ","X   X","X   X"},
    /* 121 y */ [121] = {"X   X","X   X"," X X ","  X  ","  X  ","  X  ","  X  "},
    /* 122 z */ [122] = {"XXXXX","    X","   X ","  X  "," X   "," X   ","X    "},
    /* 123 { */ [123] = {"  XX "," X   "," X   ","X    "," X   "," X   ","  XX "},
    /* 124 | */ [124] = {"  X  ","  X  ","  X  ","  X  ","  X  ","  X  ","  X  "},
    /* 125 } */ [125] = {" XX  ","   X ","   X ","    X","   X ","   X "," XX  "},
    /* 126 ~ */ [126] = {"     "," X   ","X X X","   X ","     ","     ","     "},
    /* 127  */ [127] = {"XXXXX","XXXXX","XXXXX","XXXXX","XXXXX","XXXXX","XXXXX"},
};

static void texto_gl(const char *s, int x, int y, float escala)
{
	float ox = (float)x, oy = (float)y;

	glBegin(GL_QUADS);
	for (; *s; s++) {
		const char *const *gl;
		int r, col;
		unsigned char c = (unsigned char)*s;

		/* La tabla esta indexada por ASCII, con las mayusculas y las
		 * minusculas ya dentro, asi que no hay que normalizar nada.
		 *
		 * glifo5x7[c] es "const char *const [6]" y glifo_faltante es
		 * "const char *const [7]": los dos son punteros a puntero, asi que
		 * se pueden ternar sin conversion. */
		/* 127 (DEL) esta reservado con el cuadrito de "no hay glifo", de
		 * forma que el que falta se ve en vez de desaparecer en silencio. */
		gl = glifo5x7[(c < 128 && glifo5x7[c][0]) ? c : 127];
		for (r = 0; r < 7; r++)
			for (col = 0; col < 5; col++)
				if (gl[r][col] == 'X') {
					float px = ox + (float)col * escala;
					float py = oy - (float)r * escala;
					glVertex2f(px, py);
					glVertex2f(px + escala, py);
					glVertex2f(px + escala, py - escala);
					glVertex2f(px, py - escala);
				}
		ox += 6.0f * escala;
	}
	glEnd();
}

/* OJO con el eje y: en OpenGL la y crece hacia ARRIBA y el origen (0,0) es la
 * esquina inferior izquierda, al reves que en una ventana. texto_gl dibuja las
 * filas hacia abajo desde la y que se le pase, asi que para un bloque de texto
 * que baja desde arriba hay que empezar cerca de la altura de la ventana. */
static void dibuja_hud(ed_gui_t *g)
{
	int y;
	char buf[256];
	float W = (float)g->ancho, H = (float)g->alto;

	glMatrixMode(GL_PROJECTION);
	glLoadIdentity();
	glOrtho(0.0, W, 0.0, H, -1.0, 1.0);
	glMatrixMode(GL_MODELVIEW);
	glLoadIdentity();
	glDisable(GL_DEPTH_TEST);
	glDisable(GL_CULL_FACE);

	if (g->mostrar_ayuda) {
		static const char *lineas[] = {
		    "DIREKT EDITOR",
		    "RATON IZQ          SELECCIONA",
		    "RATON IZQ + ARRASTRA  MUEVE",
		    "RATON DERECHO       MIRA",
		    "WASD FLECHAS       MOVER CAMARA",
		    "ESPACIO C          SUBIR / CENTRAR",
		    "B                  CAJA NUEVA",
		    "D                  DUPLICAR",
		    "SUP R              BORRA",
		    "CTRL+Z / CTRL+Y    DESHACER / REHACER",
		    "FLECHAS            MUEVEN LA BRUSH",
		    "F2 GUARDAR   F5 COMPILAR   TAB SOLIDO",
		    "F1                OCULTA ESTO"};
		int n = (int)(sizeof(lineas) / sizeof(lineas[0]));
		int panel_h = 16 + n * 15;
		int i;

		/* Fondo del panel para que el texto se lea sobre el mapa.
		 *
		 * glColor4f con alfa NECESITA blending: sin glEnable(GL_BLEND) el
		 * cuarto componente se ignora y el panel sale en negro opaco, tapando
		 * la escena entera en vez de suavizarse sobre ella. */
		glEnable(GL_BLEND);
		glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
		glColor4f(0.0f, 0.0f, 0.0f, 0.6f);
		glBegin(GL_QUADS);
		glVertex2f(0.0f, H - (float)panel_h);
		glVertex2f(430.0f, H - (float)panel_h);
		glVertex2f(430.0f, H);
		glVertex2f(0.0f, H);
		glEnd();
		glDisable(GL_BLEND);

		glColor3f(0.85f, 0.9f, 1.0f);
		y = (int)H - 6;
		for (i = 0; i < n; i++) {
			texto_gl(lineas[i], 10, y, 1.5f);
			y -= 15;
		}
	}

	/* Barra de abajo: estado del documento y de la seleccion. */
	glColor3f(0.0f, 0.0f, 0.0f);
	{
		float alto_barra = 44.0f;
		glEnable(GL_BLEND);
		glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
		glColor4f(0.0f, 0.0f, 0.0f, 0.6f);
		glBegin(GL_QUADS);
		glVertex2f(0.0f, 0.0f);
		glVertex2f(W, 0.0f);
		glVertex2f(W, alto_barra);
		glVertex2f(0.0f, alto_barra);
		glEnd();
		glDisable(GL_BLEND);
	}

	glColor3f(0.92f, 0.92f, 0.95f);
	snprintf(buf, sizeof(buf), "%s%s   %d brushes   %d entidades   rejilla %d",
	         g->doc->title, g->doc->dirty ? " [modificado]" : "",
	         ed_num_brushes(g->doc), ed_num_entities(g->doc), g->doc->grid_size);
	texto_gl(buf, 8, 30, 1.6f);

	if (g->doc->sel_brush) {
		vec3_t mins, maxs;
		const char *tex;
		brush_bounds(g->doc->sel_brush, mins, maxs);
		tex = g->doc->sel_brush->sides[0].texname;
		snprintf(buf, sizeof(buf), "seleccion  %d %d %d  ->  %d %d %d   cara %d   %s",
		         (int)mins[0], (int)mins[1], (int)mins[2], (int)maxs[0], (int)maxs[1],
		         (int)maxs[2], g->doc->sel_side, tex ? tex : "-");
		glColor3f(1.0f, 0.7f, 0.3f);
		texto_gl(buf, 8, 13, 1.6f);
	} else if (g->doc->sel_entity) {
		const char *cn = ed_get_key(g->doc->sel_entity, "classname");
		snprintf(buf, sizeof(buf), "entidad  %s", cn ? cn : "(sin classname)");
		glColor3f(0.6f, 0.9f, 1.0f);
		texto_gl(buf, 8, 13, 1.6f);
	} else {
		glColor3f(0.6f, 0.65f, 0.7f);
		snprintf(buf, sizeof(buf), "camara  %d %d %d   yaw %d pitch %d",
		         (int)g->cam.org[0], (int)g->cam.org[1], (int)g->cam.org[2],
		         (int)g->cam.ang[1], (int)g->cam.ang[0]);
		texto_gl(buf, 8, 13, 1.6f);
	}

	/* Posicion del raton en el mapa, que es lo que ayuda a colocar cosas. */
	{
		vec3_t org, dir;
		ed_cam_ray(&g->cam, (float)g->ultimo_mx, (float)g->ultimo_my, org, dir);
		glColor3f(0.55f, 0.6f, 0.65f);
		snprintf(buf, sizeof(buf), "raton  %d %d", g->ultimo_mx, g->ultimo_my);
		texto_gl(buf, W - 150.0f, 13, 1.6f);
		(void)dir;
	}

	if (g->mensaje[0] && (float)SDL_GetTicks() / 1000.0f < g->msg_hasta) {
		glEnable(GL_BLEND);
		glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
		glColor4f(0.0f, 0.0f, 0.0f, 0.6f);
		glBegin(GL_QUADS);
		glVertex2f(0.0f, 50.0f);
		glVertex2f(W, 50.0f);
		glVertex2f(W, 70.0f);
		glVertex2f(0.0f, 70.0f);
		glEnd();
		glDisable(GL_BLEND);
		glColor3f(1.0f, 0.95f, 0.4f);
		texto_gl(g->mensaje, 8, 68, 1.7f);
	}

	glEnable(GL_DEPTH_TEST);
	glEnable(GL_CULL_FACE);
	glMatrixMode(GL_MODELVIEW);
}

/* Monta la atlas de texturas de la vista. Se puede llamar con o sin contexto
 * GL: si no hay biblioteca de texturas deja el atlas a NULL y se dibuja con
 * colores planos, que es como se ha dibujado siempre. */
static void monta_atlas(ed_gui_t *g)
{
	texlib_t *lib = texlib_open_juego();

	g->atlas = NULL;
	if (!lib) {
		fprintf(stderr, "direkt-edit: no se ha encontrado la biblioteca de "
		                "texturas; se dibuja con colores planos\n");
		return;
	}
	g->atlas = edtex_new(lib, g->doc->map);
	if (!g->atlas)
		fprintf(stderr, "direkt-edit: este mapa no tiene texturas en la "
		                "biblioteca; se dibuja con colores planos\n");
	/* La biblioteca se puede cerrar en cuanto: la atlas ya tiene los pixeles
	 * copiados y no la vuelve a mirar. */
	texlib_close(lib);
}

/* ------------------------------------------------------------------ acciones */

static void compilar(ed_gui_t *g, const char *salida)
{
	map_t *m;
	bsp_t *bsp;
	int rc;

	/* El compilador trabaja sobre un map_t y el documento ya lo es, pero
	 * compile_map no debe tocar el documento que se esta editando: se
	 * escribe a un temporal y se vuelve a leer de ahi. Asi, compilar nunca
	 * puede dejar el documento a medias aunque el .map tenga un error. */
	{
		char tmp[] = "/tmp/direkt-edit-XXXXXX";
		int fd = mkstemp(tmp);
		FILE *f = fdopen(fd, "wb");
		char *texto = save_map_to_string(g->doc->map);
		fwrite(texto, 1, strlen(texto), f);
		fclose(f);
		free(texto);

		m = parse_map(tmp);
		remove(tmp);
	}

	bsp = compile_map(m);

	/* La biblioteca de texturas tambien aqui. Si el .bsp que compila el editor
	 * saliera sin lump TEXTURES, lo que se veria en el juego no seria lo que se
	 * ha visto aqui, y el editor estaria mintiendo. */
	{
		texlib_t *tex = texlib_open_juego();
		if (tex) {
			bsp->tex = tex;
			if (texlib_count(tex) == 0)
				avisar(g, "aviso: no se han encontrado texturas; el .bsp "
				          "saldra sin lump TEXTURES");
		} else {
			avisar(g, "aviso: no se ha podido abrir la biblioteca de "
			          "texturas; el .bsp saldra sin lump TEXTURES");
		}

		rc = write_bsp(salida, bsp, m);
		if (rc == 0)
			rc = check_bsp(salida);
		texlib_close(tex);
	}
	free_bsp(bsp);
	free_map(m);

	if (rc == 0)
		avisar(g, "compilado y validado: %s", salida);
	else
		avisar(g, "el .bsp no valida; mira la consola");
}

static void mover_brush_por_teclado(ed_gui_t *g, int dx, int dy, int dz)
{
	vec3_t d;
	if (!g->doc->sel_brush)
		return;
	d[0] = (float)dx * g->doc->grid_size;
	d[1] = (float)dy * g->doc->grid_size;
	d[2] = (float)dz * g->doc->grid_size;
	ed_translate_brush(g->doc, g->doc->sel_brush, d);
}

static void nueva_caja(ed_gui_t *g)
{
	vec3_t org, mins, maxs;
	vec3_t fwd;
	int gsz = g->doc->grid_size;

	ed_cam_forward(&g->cam, fwd);
	org[0] = g->cam.org[0] + fwd[0] * 96.0f;
	org[1] = g->cam.org[1] + fwd[1] * 96.0f;
	org[2] = g->cam.org[2] + fwd[2] * 96.0f;
	ed_snap_vec(org, gsz, org);
	mins[0] = org[0] - gsz; mins[1] = org[1] - gsz; mins[2] = org[2] - gsz;
	maxs[0] = org[0] + gsz; maxs[1] = org[1] + gsz; maxs[2] = org[2] + gsz;
	if (ed_add_box(g->doc, NULL, mins, maxs, g->textura_actual))
		avisar(g, "caja anadida en %d %d %d", (int)org[0], (int)org[1], (int)org[2]);
	else
		avisar(g, "no se pudo anadir la caja");
}

static void al_soltar_boton_izq(ed_gui_t *g)
{
	if (g->modo_arrastre == 1 && g->doc->sel_brush && g->doc->sel_side >= 0)
		ed_drag_side(g->doc, g->doc->sel_brush, g->doc->sel_side, g->arrastre_dz);
	g->modo_arrastre = 0;
}

/* ---------------------------------------------------------------- eventos */

static void al_pulsar_boton_izq(ed_gui_t *g, int mx, int my)
{
	vec3_t org, dir, mins, maxs, centro;
	brush_t *b;

	ed_cam_ray(&g->cam, (float)mx, (float)my, org, dir);
	b = ed_pick(g->doc, org, dir);
	if (!b) {
		ed_select_none(g->doc);
		g->modo_arrastre = 0;
		return;
	}
	ed_select_brush(g->doc, b);
	brush_bounds(b, mins, maxs);
	centro[0] = (mins[0] + maxs[0]) * 0.5f;
	centro[1] = (mins[1] + maxs[1]) * 0.5f;
	centro[2] = (mins[2] + maxs[2]) * 0.5f;
	/* Distancia perpendicular del centro de la brush al rayo: es la
	 * referencia para saber cuanto ha arrastrado el raton. */
	g->atrapado_a = (int)ed_ray_point_dist(org, dir, centro);
	g->arrastre_dz = 0.0f;
	g->modo_arrastre = 1;
}

static void al_mover_raton(ed_gui_t *g, int mx, int my)
{
	int dx = mx - g->ultimo_mx;
	int dy = my - g->ultimo_my;

	g->ultimo_mx = mx;
	g->ultimo_my = my;

	if (g->boton_der_mirando) {
		ed_cam_turn(&g->cam, (float)dx * -0.25f, (float)dy * 0.25f);
		return;
	}
	if (g->modo_arrastre && g->doc->sel_brush) {
		g->arrastre_dz += (float)dy * 0.5f;
	}
}

static void al_tecla(ed_gui_t *g, SDL_Keycode k, uint16_t mod)
{
	int ctrl = (mod & KMOD_CTRL) != 0;
	int mayus = (mod & KMOD_SHIFT) != 0;

	switch (k) {
	case SDLK_ESCAPE:
		if (g->doc->dirty) {
			avisar(g, "hay cambios sin guardar: vuelve a pulsar ESC para salir");
			g->doc->dirty = 0; /* la segunda pulsacion ya sale */
			return;
		}
		g->quit = 1;
		return;
	case SDLK_F1:
		g->mostrar_ayuda = !g->mostrar_ayuda;
		return;
	case SDLK_F2:
		if (g->doc->filename) {
			if (ed_doc_save(g->doc, g->doc->filename) == 0) {
				g->doc->dirty = 0;
				avisar(g, "guardado en %s", g->doc->filename);
			} else {
				avisar(g, "no se pudo guardar");
			}
		} else {
			avisar(g, "el mapa es nuevo: guardalo con F2 eligiendo nombre");
		}
		return;
	case SDLK_F5:
		compilar(g, "mapa.bsp");
		return;
	case SDLK_TAB:
		g->renderer = g->renderer ? 0 : 1;
		return;
	case SDLK_b:
		if (!ctrl)
			nueva_caja(g);
		return;
	case SDLK_d:
		if (ed_duplicate_brush(g->doc, g->doc->sel_brush))
			avisar(g, "brush duplicada");
		return;
	case SDLK_DELETE:
	case SDLK_BACKSPACE:
		if (g->doc->sel_brush) {
			ed_delete_brush(g->doc, g->doc->sel_brush);
			avisar(g, "brush borrada");
		}
		return;
	case SDLK_g:
		g->doc->grid_size *= 2;
		if (g->doc->grid_size > 128)
			g->doc->grid_size = 8;
		avisar(g, "rejilla de %d", g->doc->grid_size);
		return;
	case SDLK_LEFT:
		mover_brush_por_teclado(g, -1, 0, 0);
		return;
	case SDLK_RIGHT:
		mover_brush_por_teclado(g, 1, 0, 0);
		return;
	case SDLK_DOWN:
		mover_brush_por_teclado(g, 0, -1, 0);
		return;
	case SDLK_UP:
		mover_brush_por_teclado(g, 0, 1, 0);
		return;
	case SDLK_PAGEUP:
		mover_brush_por_teclado(g, 0, 0, 1);
		return;
	case SDLK_PAGEDOWN:
		mover_brush_por_teclado(g, 0, 0, -1);
		return;
	case SDLK_z:
		if (ctrl) {
			if (ed_undo(g->doc))
				avisar(g, "deshecho");
			else
				avisar(g, "no hay nada que deshacer");
		}
		return;
	case SDLK_y:
		if (ctrl) {
			if (ed_redo(g->doc))
				avisar(g, "rehecho");
			else
				avisar(g, "no hay nada que rehacer");
		}
		return;
	default:
		break;
	}
	/* Las flechas con mayus para el eje z es incomodo; con los numeros se
	 * elige textura, que es lo que hace Radiant. */
	if (k >= SDLK_1 && k <= SDLK_9) {
		static const char *tex[9] = {"notexture", "wall1", "wall2", "floor1",
		                              "ceil1",     "metal1", "metal2", "wood1", "rock1"};
		snprintf(g->textura_actual, sizeof(g->textura_actual), "%s",
		         tex[k - SDLK_1]);
		avisar(g, "textura: %s", g->textura_actual);
	}
	(void)mayus;
}

/* ------------------------------------------------------------------ ventana */

static int crea_contexto(ed_gui_t *g, const char *titulo, int w, int h)
{
	SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
	SDL_GL_SetAttribute(SDL_GL_RED_SIZE, 8);
	SDL_GL_SetAttribute(SDL_GL_GREEN_SIZE, 8);
	SDL_GL_SetAttribute(SDL_GL_BLUE_SIZE, 8);
	SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, 24);

	g->win = SDL_CreateWindow(titulo, SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
	                          w, h, SDL_WINDOW_OPENGL | SDL_WINDOW_RESIZABLE);
	if (!g->win) {
		fprintf(stderr, "no se pudo crear la ventana: %s\n", SDL_GetError());
		return 0;
	}
	g->ctx = SDL_GL_CreateContext(g->win);
	if (!g->ctx) {
		fprintf(stderr, "no se pudo crear el contexto GL: %s\n", SDL_GetError());
		return 0;
	}
	g->ancho = w;
	g->alto = h;
	g->cam.width = w;
	g->cam.height = h;
	return 1;
}

int ed_gui_run(ed_doc_t *doc)
{
	ed_gui_t g;
	SDL_Event ev;
	int vivo = 1;
	vec3_t centro;
	const Uint8 *teclas;

	memset(&g, 0, sizeof(g));
	g.doc = doc;
	g.renderer = 0;
	g.atlas = NULL;
	g.mostrar_ayuda = 1;
	snprintf(g.textura_actual, sizeof(g.textura_actual), "notexture");
	{
		vec3_t mins, maxs;
		ed_doc_bounds(doc, mins, maxs);
		centro[0] = (mins[0] + maxs[0]) * 0.5f;
		centro[1] = (mins[1] + maxs[1]) * 0.5f;
		centro[2] = (mins[2] + maxs[2]) * 0.5f;
	}
	ed_cam_init(&g.cam, centro);

	if (SDL_Init(SDL_INIT_VIDEO) != 0) {
		fprintf(stderr, "SDL_Init fallo: %s\n", SDL_GetError());
		return 1;
	}
	{
		char titulo[256];
		snprintf(titulo, sizeof(titulo), "Direkt Editor - %s%s", doc->title,
		         doc->dirty ? " *" : "");
		if (!crea_contexto(&g, titulo, 1024, 768)) {
			SDL_Quit();
			return 1;
		}
	}

	/* La atlas se monta DESPUES de tener contexto GL, porque sube la textura. */
	monta_atlas(&g);

	glEnable(GL_DEPTH_TEST);
	glEnable(GL_CULL_FACE);
	glCullFace(GL_BACK);

	while (vivo) {
		teclas = SDL_GetKeyboardState(NULL);

		while (SDL_PollEvent(&ev)) {
			switch (ev.type) {
			case SDL_QUIT:
				vivo = 0;
				break;
			case SDL_WINDOWEVENT:
				if (ev.window.event == SDL_WINDOWEVENT_SIZE_CHANGED) {
					g.ancho = ev.window.data1;
					g.alto = ev.window.data2;
					g.cam.width = g.ancho;
					g.cam.height = g.alto;
				}
				break;
			case SDL_MOUSEBUTTONDOWN:
				if (ev.button.button == SDL_BUTTON_LEFT) {
					g.boton_izq = 1;
					al_pulsar_boton_izq(&g, ev.button.x, ev.button.y);
				} else if (ev.button.button == SDL_BUTTON_RIGHT) {
					g.boton_der_mirando = 1;
					SDL_SetRelativeMouseMode(SDL_TRUE);
				}
				break;
			case SDL_MOUSEBUTTONUP:
				if (ev.button.button == SDL_BUTTON_LEFT) {
					g.boton_izq = 0;
					al_soltar_boton_izq(&g);
				} else if (ev.button.button == SDL_BUTTON_RIGHT) {
					g.boton_der_mirando = 0;
					SDL_SetRelativeMouseMode(SDL_FALSE);
				}
				break;
			case SDL_MOUSEMOTION:
				al_mover_raton(&g, ev.motion.x, ev.motion.y);
				break;
			case SDL_KEYDOWN:
				al_tecla(&g, ev.key.keysym.sym, ev.key.keysym.mod);
				break;
			default:
				break;
			}
			if (!vivo)
				break;
		}

		/* Movimiento continuo de la camara. */
		{
			float vel = (teclas[SDL_SCANCODE_LSHIFT] ? 512.0f : 192.0f) *
			            (1.0f / 60.0f);
			if (teclas[SDL_SCANCODE_W])
				ed_cam_move(&g.cam, vel, 0.0f, 0.0f);
			if (teclas[SDL_SCANCODE_S])
				ed_cam_move(&g.cam, -vel, 0.0f, 0.0f);
			if (teclas[SDL_SCANCODE_D] && !teclas[SDL_SCANCODE_LCTRL])
				ed_cam_move(&g.cam, 0.0f, vel, 0.0f);
			if (teclas[SDL_SCANCODE_A])
				ed_cam_move(&g.cam, 0.0f, -vel, 0.0f);
			if (teclas[SDL_SCANCODE_SPACE])
				ed_cam_move(&g.cam, 0.0f, 0.0f, vel);
			if (teclas[SDL_SCANCODE_C] && g.doc->sel_brush) {
				/* C centra la camara en la brush seleccionada, que es lo
				 * que se quiere el 90% de las veces que se selecciona. */
				vec3_t mins, maxs, c;
				brush_bounds(g.doc->sel_brush, mins, maxs);
				c[0] = (mins[0] + maxs[0]) * 0.5f;
				c[1] = (mins[1] + maxs[1]) * 0.5f;
				c[2] = (mins[2] + maxs[2]) * 0.5f;
				ed_cam_move(&g.cam, c[0] - g.cam.org[0], c[1] - g.cam.org[1],
				            c[2] - g.cam.org[2]);
			}
		}

		SDL_GL_GetDrawableSize(g.win, &g.ancho, &g.alto);
		glViewport(0, 0, g.ancho, g.alto);
		glClearColor(0.08f, 0.09f, 0.12f, 1.0f);
		glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

		dibuja_escena(&g);
		dibuja_hud(&g);

		SDL_GL_SwapWindow(g.win);
		SDL_Delay(10);
	}

	SDL_GL_DeleteContext(g.ctx);
	SDL_DestroyWindow(g.win);
	edtex_free(g.atlas);
	SDL_Quit();
	return 0;
}

/* ------------------------------------------------------------------ snapshot */

static int guardar_ppm(const char *ruta, const unsigned char *rgb, int w, int h)
{
	FILE *f = fopen(ruta, "wb");
	if (!f) {
		fprintf(stderr, "no se puede escribir %s\n", ruta);
		return 1;
	}
	fprintf(f, "P6\n%d %d\n255\n", w, h);
	/* OpenGL entrega las filas de abajo arriba. */
	for (int y = h - 1; y >= 0; y--)
		fwrite(rgb + (size_t)y * (size_t)w * 3, 1, (size_t)w * 3, f);
	if (fclose(f) != 0) {
		fprintf(stderr, "escritura incompleta de %s\n", ruta);
		return 1;
	}
	return 0;
}

int ed_gui_snapshot(ed_doc_t *doc, const char *salida_ppm, int renderer, int w, int h)
{
	ed_gui_t g;
	unsigned char *pix;
	int rc;

	memset(&g, 0, sizeof(g));
	g.doc = doc;
	g.renderer = renderer;
	g.mostrar_ayuda = 1;
	g.ancho = w;
	g.alto = h;
	snprintf(g.textura_actual, sizeof(g.textura_actual), "notexture");
	{
		vec3_t mins, maxs, c;
		ed_doc_bounds(doc, mins, maxs);
		c[0] = (mins[0] + maxs[0]) * 0.5f;
		c[1] = (mins[1] + maxs[1]) * 0.5f;
		c[2] = (mins[2] + maxs[2]) * 0.5f;
		ed_cam_init(&g.cam, c);
		/* Vista en alto y desde el suroeste, que es como se revisa la
		 * geometria: se ven las seis caras de una caja. Con la convencion de
		 * yaw de Quake, mirar al nordeste es yaw 45, y desde arriba el pitch
		 * va en negativo.
		 *
		 * La distancia se saca del tamano del mapa: con una distancia fija, un
		 * mapa de 3000 unidades sale del todo pequeno y uno de 50 no se ve. */
		{
			float radio = 0.0f;
			int k;
			for (k = 0; k < 3; k++) {
				float d = maxs[k] - mins[k];
				if (d > radio)
					radio = d;
			}
			radio = radio * 0.5f + 32.0f;
			g.cam.fov = 75.0f;
			g.cam.ang[1] = 45.0f;
			g.cam.ang[0] = -30.0f;
			/* Distancia necesaria para que quepa el radio con el fov dado. */
			{
				float dist = radio / tanf(35.0f * 3.14159265f / 180.0f) * 1.25f;
				g.cam.org[0] = c[0] - dist * 0.7071f;
				g.cam.org[1] = c[1] - dist * 0.7071f;
				g.cam.org[2] = c[2] + dist * 0.5f;
			}
		}
	}

	/* SDLoffscreen: la ventana real no hace falta para dibujar, y asi el
	 * snapshot funciona en un banco de pruebas sin X. */
	if (SDL_Init(SDL_INIT_VIDEO) != 0) {
		fprintf(stderr, "SDL_Init fallo: %s\n", SDL_GetError());
		return 1;
	}
	if (!crea_contexto(&g, "snapshot", w, h)) {
		SDL_Quit();
		return 1;
	}
	SDL_GL_MakeCurrent(g.win, g.ctx);

	/* La atlas necesita contexto GL para subir la textura. */
	monta_atlas(&g);

	glEnable(GL_DEPTH_TEST);
	glDisable(GL_CULL_FACE);

	/* Sin limpiar, el buffer de profundidad trae lo que hubiera de antes y el
	 * test GL_LESS puede rechazar toda la escena: la captura sale negra sin
	 * ningun error visible. */
	glViewport(0, 0, w, h);
	glClearColor(0.08f, 0.09f, 0.12f, 1.0f);
	glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

	dibuja_escena(&g);
	dibuja_hud(&g);
	glFinish();

	pix = xmalloc((size_t)w * (size_t)h * 3);
	glPixelStorei(GL_PACK_ALIGNMENT, 1);
	glReadPixels(0, 0, w, h, GL_RGB, GL_UNSIGNED_BYTE, pix);

	rc = guardar_ppm(salida_ppm, pix, w, h);
	free(pix);

	SDL_GL_DeleteContext(g.ctx);
	SDL_DestroyWindow(g.win);
	SDL_Quit();
	return rc;
}
