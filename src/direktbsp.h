/* direkt-bsp -- compilador de mapas de Quake.
 *
 * GPL-2.0, ver LICENSE en la raiz del repositorio.
 *
 * El motor (Ironwail) solo carga .bsp y no compila ninguno, asi que el
 * compilador es nuestro. El formato de salida y sus trampas estan en
 * docs/ARCHITECTURA.md, con el fichero:linea del motor detras de cada dato.
 *
 * Dos cosas que hay que tener presentes al escribir esto, porque el motor no las
 * avisa de ninguna manera:
 *
 *  - No valida fileofs+filelen al cargar. Un offset mal calculado es lectura
 *    arbitraria de memoria, sin error. De ahi check_bsp() al final.
 *  - El indice de plano de un nodo NO lleva bit de signo: es un indice
 *    directo, y el plano opuesto tiene que existir como entrada propia. Es la
 *    convencion de Darkplaces/ericw, no la de qbsp original.
 */

#ifndef DIREKTBSP_H
#define DIREKTBSP_H

#include <stddef.h>

#define DIREKTBSP_VERSION "0.1"

/* ------------------------------------------------------------------ utiles */

typedef float vec3_t[3];
typedef float vec2_t[2];

void error(const char *fmt, ...);
void *xmalloc(size_t n);
void *xcalloc(size_t n, size_t size);
void *xrealloc(void *p, size_t n);
char *xstrdup(const char *s);

/* ------------------------------------------------------------------ contents
 *
 * Estos numeros los lee el juego con esta significacion (SV_PointContents y el
 * agua del jugador), asi que no son libres. Solo se usan los de arriba del cero
 * y SOLID; SKY no hace falta para un BSP de juego.
 */
#define CONTENTS_EMPTY (-1)
#define CONTENTS_SOLID (-2)
#define CONTENTS_WATER (-3)
#define CONTENTS_SLIME (-4)
#define CONTENTS_LAVA  (-5)

/* ------------------------------------------------------------------ vectores */

typedef float vec3_t[3];
typedef float vec2_t[2];

float VectorDot(const vec3_t a, const vec3_t b);
void VectorSubtract(const vec3_t a, const vec3_t b, vec3_t out);
void VectorAdd(const vec3_t a, const vec3_t b, vec3_t out);
void VectorScale(const vec3_t a, float s, vec3_t out);
void VectorCopy(const vec3_t a, vec3_t out);
void VectorMA(const vec3_t a, float s, const vec3_t b, vec3_t out);
void CrossProduct(const vec3_t a, const vec3_t b, vec3_t out);
float VectorLength(const vec3_t a);
void VectorNormalize(vec3_t a);

/* ------------------------------------------------------------------ winding
 *
 * Los puntos van en antihorario visto desde FUERA de la brush, que es la
 * orientacion en la que se dibuja. Un lado con winding == NULL significa que esa
 * cara desaparecio al partir la brush.
 */
typedef struct winding_s {
	struct winding_s *next;
	int numpoints;
	/* Array flexible de verdad (C99): points[] no ocupa sitio en la estructura
	 * y winding_new reserva numpoints elementos.
	 *
	 * Antes era points[1], el "array flexible" de facto de Quake, que en
	 * realidad es un tipo incompleto: sizeof no cuenta el hueco y el
	 * compilador no puede indexar
	 * con seguridad, asi que avisaba de cada acceso. Con [] el indice es
	 * responsabilidad de quien lo usa, que es el contrato de numpoints.
	 *
	 * OJO: leer points[0..2] sin comprobar numpoints >= 3 sigue siendo
	 * invalido. Ver plane_from_winding, que lo comprueba. */
	vec3_t points[];
} winding_t;

winding_t *winding_new(int numpoints);
winding_t *winding_copy(winding_t *w);
winding_t *winding_reverse(winding_t *w);
void winding_free(winding_t *w);
float winding_area(winding_t *w);
void winding_bounds(winding_t *w, vec3_t mins, vec3_t maxs);

/* ------------------------------------------------------------------ plano */

typedef struct {
	vec3_t normal; /* unitaria */
	float dist;    /* dist = Dot(normal, p) para cualquier p del plano */
} plane_t;

plane_t plane_from_points(vec3_t a, vec3_t b, vec3_t c);
void plane_from_winding(winding_t *w, plane_t *p);
float plane_distance(plane_t *p, vec3_t point);

/* ------------------------------------------------------------------ brush
 *
 * Una brush convexa es la interseccion de los medios espacios de sus caras.
 * contents decide su papel: SOLID y los liquidos entran en el arbol del mundo,
 * y el resto se convierte en submodelo (puerta, plataforma, boton...).
 */
typedef struct {
	plane_t plane;
	winding_t *winding; /* NULL si la cara se podo del todo */
	/* Textura de la cara. Va en el lado y no aparte porque la cara y su
	 * textura se separan y se unen juntas al partir la brush. */
	char *texname;
	float texshift[2];
	float texscale[2];
	float texrotate;
} side_t;

/* Una brush del .map tiene 6 caras, pero al partirla por un plano gana la cara
 * de la seccion, y si el plano de corte coincide con una cara suya esa cara se
 * queda en las DOS mitades. O sea que una mitad puede llevar 7 planos y mas.
 *
 * Por eso "sides" es un array que crece y no uno de 6. Con 6 fijo, add_side
 * abortaba en cuanto una brush se partia, y como el plano que elige el arbol
 * para una habitacion de cajas alineadas a ejes es justamente el plano de una
 * cara, esa cara se perdia: los muros se quedan sin la cara de dentro y la
 * habitacion no tiene nada que dibujar. */
typedef struct brush_s {
	struct brush_s *next;
	side_t *sides;
	int numsides;
	int sides_cap;
	int contents;
	int original;   /* vino del .map en vez de de una division */
	int moving;     /* el juego la mueve: tiene que ser submodelo */
	int modelindex; /* submodelo al que pertenece, o -1 si es del mundo */
} brush_t;

/* Tope de planos por brush. Es un CrazyMape de seguridad, no un limite del
 * formato: una brush partida puede pasar de 6 sin problema. */
#define BRUSH_MAX_SIDES 64

/* Garantiza hueco para n caras y devuelve el array. */
side_t *brush_sides_reserve(brush_t *b, int n);

/* Ejes de textura de una cara: la base del plano, girada y escalada con los
 * parametros del lado. Es lo que rellena texinfo_t.vecs, y lo que necesita el
 * editor para pintar la cara con la misma textura y el mismo desplazamiento que
 * va a ver el juego. Si el editor calculara los suyos por su cuenta, el mapa se
 * veria de una manera en el editor y de otra en el juego. */
void brush_side_axes(const side_t *s, const plane_t *p, vec3_t xv, vec3_t yv);

#define BRUSH_MOVING 1

brush_t *brush_new(void);
void brush_free(brush_t *b);
brush_t *brush_copy(brush_t *b);
void brush_add_winding(brush_t *b, vec3_t normal, float dist, winding_t *w);
int brush_is_inside(brush_t *b, plane_t *p, float epsilon);
void brush_bounds(brush_t *b, vec3_t mins, vec3_t maxs);
/* Parte la brush por split. Devuelve 1 si se ha partido en dos, 0 si cae
 * entera de un lado (y entonces solo se rellena *front o *back), y -1 si se
 * toca el caso degenerado de estar justo en el plano. */
int brush_split(brush_t *b, plane_t *split, brush_t **front, brush_t **back);

/* ------------------------------------------------------------------ .map */

typedef struct {
	char *key;
	char *value;
} pair_t;

typedef struct entity_s {
	struct entity_s *next;
	pair_t *pairs;
	int numpairs;
	int is_world;
	brush_t *brushes;      /* primera de la entidad */
	brush_t *brushes_tail; /* ultima, para anadir en O(1) */
} entity_t;

typedef struct {
	entity_t *entities;
	entity_t *entities_tail;
	int numentities;
	brush_t *brushes;     /* todas, encadenadas */
	brush_t *brushes_tail;
	int numbrushes;
} map_t;

map_t *parse_map(const char *filename);
map_t *parse_map_text(const char *text);
void free_map(map_t *map);
const char *entity_key(entity_t *e, const char *key);

/* ------------------------------------------------------------------ texture */

/* El motor calcula la superficie como v·vecs[j][0..2] + vecs[j][3], o sea que
 * el cuarto componente es un desplazamiento aparte. Aqui el desplazamiento va
 * ya sumado en los tres primeros, asi que el cuarto se queda a 0: da igual. */
typedef struct {
	float vecs[2][4];
	int miptex; /* indice en LUMP_TEXTURES */
	int flags;
} texinfo_t;

/* TEX_SPECIAL: superficie sin iluminacion precalculada (agua, cielo, skyshafts).
 * El motor exige extents <= 2000 en las que no la tienen. */
#define TEX_SPECIAL 1

/* ------------------------------------------------------------------ BSP */

typedef struct {
	int planenum;    /* indice directo en bsp->planes, sin bit de signo */
	int children[2]; /* >=0 nodo, <0 hoja: -(leaf+1) */
	int mins[3];     /* del nodo, en enteros, para el hull */
	int maxs[3];
	int firstface, numfaces;
} node_t;

typedef struct {
	int contents;
	int visofs; /* -1 cuando el lump VIS esta vacio */
	int mins[3], maxs[3];
	int firstmarksurface, nummarksurfaces;
} leaf_t;

typedef struct {
	int planenum; /* indice en bsp->planes, o -1 para la hoja solida */
	int children[2];
} clipnode_t;

typedef struct {
	plane_t plane;
	winding_t *winding; /* sigue vivo hasta sacar los surfedges */
	int leaf;           /* hoja en la que cae la brush de esta cara */
	int side;           /* 0 = el winding mira hacia el plano, 1 = al reves */
	int planenum;
	int texinfo;
	int lightsofs; /* indice de la primera muestra en el lump LIGHTING, o -1 */
} surf_t;

typedef struct {
	vec3_t mins, maxs;
	int headnode[4];
	int visleafs;
	int firstface, numfaces;
} submodel_t;

struct texlib_s;

typedef struct {
	/* geometria intermedia */
	plane_t *planes;
	int numplanes;
	/* Biblioteca de texturas de la que se saca el lump TEXTURES. La pone el
	 * llamante antes de write_bsp; si es NULL, el lump sale vacio y el motor
	 * pinta todo con la textura por defecto. */
	struct texlib_s *tex;
	/* Los nombres de textura que usan las caras, en el mismo orden que
	 * texinfo.miptex. El escritor los necesita para saber que meter en el lump
	 * TEXTURES, y texinfo_t solo guarda el indice. */
	char **texnames;
	int numtexnames;
	node_t *nodes;
	int numnodes;
	leaf_t *leafs;
	int numleafs;
	/* Las brushes partidas que han caido en cada hoja. Es la lista de solidos
	 * real del arbol (la del mapa ya no existe para entonces) y la que usan
	 * tanto el calculo de luz como cualquier comprobacion de oclusion. Lo
	 * suelta free_bsp. */
	brush_t **leafbrushes;
	clipnode_t *clipnodes;
	int numclipnodes;
	surf_t *surfs;
	int numsurfs;
	texinfo_t *texinfos;
	int numtexinfos;
	submodel_t *submodels;
	int numsubmodels;

	/* salida */
	int *marksurfaces;
	int nummarksurfaces;
} bsp_t;

bsp_t *compile_map(map_t *map);
/* Calcula el lump LIGHTING y reparte el offset a cada cara. Sin esto el motor
 * deja lightdata a NULL y el mundo sale en negro.
 *
 * Los oclusores y los limites se sacan del propio bsp: son las brushes
 * partidas que cuelgan de bsp->leafbrushes. NO se le pasa la lista del mapa,
 * porque cuando esto corre compile_map ya la ha soltado (ver el comentario de
 * propiedad en compile_map) y la lista estaria vacia, que es justo lo que
 * hacia que la luz no tapase nada.
 *
 * Devuelve el numero de muestras y rellena *out con el buffer (el llamante lo
 * suelta). */
int generar_luces(bsp_t *bsp, unsigned char **out, int *outlen);
void free_bsp(bsp_t *bsp);
/* Registra un plano en el COMMON de todo el .bsp, que es donde lo buscan tanto
 * los nodos de dibujo como los de colision. clip.c lo necesita. */
int find_or_add_plane_public(plane_t *p);
/* Construye los tres arboles de colision (hulls 1 a 3) y rellena headnode del
 * submodelo 0. Sin esto el mapa carga pero no se puede jugar.
 *
 * OJO: hay que llamarla ANTES de construir el arbol del mundo, porque
 * build_tree CONSUME la lista de brushes: las parte y libera los originales. Si
 * se llama despues, la lista de la que lee ya no existe.
 *
 * world es la lista de brushes del mundo ya montada, sin modificar. */
void build_clipnodes(bsp_t *bsp, brush_t *world, map_t *map);
int write_bsp(const char *filename, bsp_t *bsp, map_t *map);
/* Revisa el fichero ya escrito. El motor no valida los offsets, asi que esto
 * no es opcional: es la unica red entre un bug del compilador y una lectura
 * arbitraria de memoria. Devuelve 0 si todo cuadra. */
int check_bsp(const char *filename);

#endif /* DIREKTBSP_H */
