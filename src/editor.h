/* editor.h -- API del editor de niveles de Direkt.
 *
 * GPL-2.0, ver LICENSE en la raiz del repositorio.
 *
 * El editor se parte en tres capas que no se mezclan:
 *
 *   ed_doc    el documento: entidades, brushes, seleccion, historial y el
 *             guardado a .map. NO sabe nada de SDL ni de OpenGL, asi que se
 *             puede probar entero sin pantalla (scripts/editor-test.sh).
 *   ed_view   matematicas de la vista: camara, proyeccion y rayos de raton.
 *             Tampoco sabe nada de SDL.
 *   ed_gui    la ventana de SDL2 y el dibujado con OpenGL. Solo esta capa
 *             toca la biblioteca grafica.
 *
 * Esa separacion no es purismo: es lo que permite que `direkt-edit --selftest`
 * compruebe toda la logica de edicion en un banco de pruebas, igual que ya se
 * hace con el juego y con el compilador de .bsp.
 */

#ifndef DIREKT_EDITOR_H
#define DIREKT_EDITOR_H

#include "direktbsp.h"

/* ------------------------------------------------------------------ documento
 *
 * El documento ES un map_t. No hay una copia paralela: lo que se ve es lo que
 * se compila, y save_map escribe exactamente lo que hay. Un editor con dos
 * representaciones del mapa siempre acaba con una de las dos desfasada.
 */
typedef struct ed_doc_s {
	map_t *map;
	char *filename;    /* de donde se cargo, o NULL si es nuevo */
	char *title;       /* nombre corto para el titulo de la ventana */
	int dirty;         /* hay cambios sin guardar */
	int show_grid;
	int grid_size;
	int show_triggers; /* los triggers se dibujan aparte, mas claro */
	/* --- seleccion --- */
	entity_t *sel_entity; /* entidad seleccionada, o NULL */
	brush_t *sel_brush;   /* brush seleccionada, o NULL */
	int sel_side;         /* cara seleccionada, o -1 */
	/* --- historial --- */
	/* Instantaneas en texto .map. Un editor de niveles hace tan pocas
	 * operaciones por minuto que serializar el documento entero para cada
	 * cambio es mas barato que cualquier estructura de deshacer incremental,
	 * y sobre todo no se puede desincronizar del documento: lo que se
	 * deshace es literalmente lo que habia. */
	char **undo;
	int numundo;
	int undocap;
	char **redo;
	int numredo;
	int redocap;
} ed_doc_t;

ed_doc_t *ed_doc_new(void);
ed_doc_t *ed_doc_load(const char *filename);
void ed_doc_free(ed_doc_t *doc);
/* Guarda a disco. Devuelve 0 si todo bien. */
int ed_doc_save(ed_doc_t *doc, const char *filename);
/* Recalcula el titulo y dirty. Se llama tras cada operacion. */
void ed_doc_touch(ed_doc_t *doc);

/* --- historial --- */
void ed_mark(ed_doc_t *doc);   /* llama ANTES de modificar */
int ed_undo(ed_doc_t *doc);    /* 1 si se pudo deshacer */
int ed_redo(ed_doc_t *doc);

/* --- consulta --- */
int ed_num_brushes(ed_doc_t *doc);
int ed_num_entities(ed_doc_t *doc);
/* Devuelve la brush que se ha pulsado, o NULL. */
brush_t *ed_pick(ed_doc_t *doc, vec3_t org, vec3_t dir);
/* Entidad a la que pertenece una brush, o NULL. */
entity_t *ed_brush_entity(ed_doc_t *doc, brush_t *b);
/* Los limites de todo el documento, brushes de triggers incluidas. */
void ed_doc_bounds(ed_doc_t *doc, vec3_t mins, vec3_t maxs);

/* --- edicion --- */
void ed_select_none(ed_doc_t *doc);
void ed_select_brush(ed_doc_t *doc, brush_t *b);
void ed_select_entity(ed_doc_t *doc, entity_t *e);

/* Crea una brush caja desde mins a maxs en la entidad dada (NULL = worldspawn)
 * y la deja seleccionada. Los parametros se redondean a la rejilla. */
/* Brush caja axis-alineada ya construida, sin enlazar a ninguna entidad. */
brush_t *brush_make_box(vec3_t mins, vec3_t maxs, const char *texname);

brush_t *ed_add_box(ed_doc_t *doc, entity_t *e, vec3_t mins, vec3_t maxs,
                    const char *texname);
brush_t *ed_duplicate_brush(ed_doc_t *doc, brush_t *b);
void ed_delete_brush(ed_doc_t *doc, brush_t *b);
void ed_translate_brush(ed_doc_t *doc, brush_t *b, vec3_t delta);
void ed_brush_to_origin(ed_doc_t *doc, entity_t *e, vec3_t org);

/* Amplia o encoge la brush seleccionada sobre la cara `side`, moviendola
 * `dist` unidades a lo largo de su normal. Es la operacion basica de colocar
 * un muro: no hace falta maths, se arrastra la cara. */
int ed_drag_side(ed_doc_t *doc, brush_t *b, int side, float dist);

/* --- entidades --- */
entity_t *ed_add_entity(ed_doc_t *doc, const char *classname, vec3_t org);
void ed_delete_entity(ed_doc_t *doc, entity_t *e);
void ed_set_key(ed_doc_t *doc, entity_t *e, const char *key, const char *value);
const char *ed_get_key(entity_t *e, const char *key);

/* ------------------------------------------------------------------ pruebas
 *
 * Toda la logica de edicion se comprueba sin pantalla. Devuelve 0 si todo va
 * bien. Es lo que corre en scripts/editor-test.sh.
 */
int ed_selftest(const char *mapa_opcional);

/* ------------------------------------------------------------------ .map
 *
 * Escritor. Vive aparte del parser para que se puedan probar por separado: la
 * ida y vuelta parse -> save -> parse tiene que dar el mismo documento.
 */
char *save_map_to_string(map_t *map);
int save_map(const char *filename, map_t *map);

/* ------------------------------------------------------------------ utilidades */
int ed_snapped(float v, int grid);
/* Los vectores se devuelven por puntero: en C no se puede devolver un array. */
void ed_snap_vec(vec3_t v, int grid, vec3_t out);
/* Formatea un numero como hace Quake: entero si se puede, si no con decimales
 * y sin ceros de mas. Devuelve un buffer del llamante. */
const char *ed_fmt_num(float v, char *buf, size_t n);

#endif /* DIREKT_EDITOR_H */
