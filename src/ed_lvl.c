/* ed_lvl.c -- el formato .drklvl: un nivel de Direkt.
 *
 * GPL-2.0, ver LICENSE en la raiz del repositorio.
 *
 * Un .drklvl es un fichero de TEXTO con una cabecera y dentro el .map. Nada
 * mas. Se eligio texto y no un binario por dos motivos:
 *
 *   - Se abre con cualquier editor de texto, y se puede mirar, copiar, comparar
 *     y arreglar a mano. Un .drklvl binario habria que buscarlo con una
 *     herramienta.
 *   - El .map es un formato de texto con tres decadas de historia. Envolverlo en
 *     algo binario solo gana bytes que no costaban nada.
 *
 * El juego no lee .drklvl: lee .bsp. O sea que un .drklvl se compila antes de
 * jugar, y para eso esta el guion de scripts/nivel.sh. Esa separacion es
 * intentionada: el editor guarda el nivel en un formato con nombres y
 * descripcion, y el compilador produce el .bsp que el motor sabe cargar.
 *
 * La cabecera va comentada con "//", que es lo que ya usa Quake en sus
 * ficheros, con una linea de convenciones que separa la cabecera del mapa:
 *
 *   // direkt-level v1
 *   // nombre: El bosque
 *   // autor: alguien
 *   // descripcion: una linea de texto
 *   // niveles/directo.drklvl
 *   ///
 *   // --- MAP ---
 *   {
 *   ...
 */

#include "editor.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define DIREKT_LVL_MAGIC "// direkt-level v1"

/* Las claves que se leen de la cabecera. Cualquier otra linea "// algo: valor" se
 * guarda tal cual, para que se puedan anadir cosas sin tocar este fichero. */
static const char *const claves[] = {
    "nombre", "autor", "descripcion", "niveles", NULL
};

/* Un buffer de texto que crece. buf_t es de ed_doc.c y no se puede usar desde
 * aqui, y para esto tampoco hace falta traerse el resto de su maquinaria. */
typedef struct {
    char *s;
    size_t len, cap;
} lvlbuf_t;

static void badd(lvlbuf_t *b, const char *texto)
{
    size_t n = strlen(texto);
    if (b->len + n + 1 > b->cap) {
        b->cap = (b->cap ? b->cap * 2 : 4096);
        while (b->cap < b->len + n + 1)
            b->cap *= 2;
        b->s = xrealloc(b->s, b->cap);
    }
    memcpy(b->s + b->len, texto, n + 1);
    b->len += n;
}

static void bprintf(lvlbuf_t *b, const char *fmt, const char *a)
{
    char tmp[4096];
    snprintf(tmp, sizeof(tmp), fmt, a);
    badd(b, tmp);
}

/* Comparar sin distinguir mayusculas, pero sin strcasecmp: eso no es de C, y en
 * MSVC no esta. Se hace a mano para que el mismo codigo compile en los tres. */
static int igual_ci(const char *a, const char *b)
{
    while (*a && *b) {
        int ca = (*a >= 'A' && *a <= 'Z') ? *a + 32 : *a;
        int cb = (*b >= 'A' && *b <= 'Z') ? *b + 32 : *b;
        if (ca != cb)
            return 0;
        a++;
        b++;
    }
    return *a == *b;
}

/* xstrndup no es de C ni de POSIX de forma fiable. */
static char *copiar_n(const char *s, size_t n)
{
    char *r = xmalloc(n + 1);
    memcpy(r, s, n);
    r[n] = 0;
    return r;
}

static char *trim(char *s)
{
    char *e;
    while (*s == ' ' || *s == '\t')
        s++;
    e = s + strlen(s);
    while (e > s && (e[-1] == ' ' || e[-1] == '\t' || e[-1] == '\r' || e[-1] == '\n'))
        *--e = 0;
    return s;
}

static int tiene_extension(const char *filename, const char *ext)
{
    const char *p, *q;

    /* Con filename NULL (un documento nuevo que todavia no se ha guardado donde)
     * esto reventaba. No es una paranoia: el editor llama a guardar con el
     * nombre vacio en cuanto se toca algo, y ahi todavia no hay fichero. */
    if (!filename)
        return 0;
    p = strrchr(filename, '.');
    if (!p)
        return 0;
    q = strrchr(filename, '/');
    if (q && p < q)
        return 0;
    return strcmp(p, ext) == 0;
}

int ed_lvl_es_drklvl(const char *filename)
{
    return tiene_extension(filename, ".drklvl");
}

/* ------------------------------------------------------------------ escribir */

static void cabecera_a_buf(lvlbuf_t *b, ed_lvl_meta_t *meta)
{
    badd(b, DIREKT_LVL_MAGIC "\n");
    if (meta->nombre && meta->nombre[0])
        bprintf(b, "// nombre: %s\n", meta->nombre);
    if (meta->autor && meta->autor[0])
        bprintf(b, "// autor: %s\n", meta->autor);
    if (meta->descripcion && meta->descripcion[0])
        bprintf(b, "// descripcion: %s\n", meta->descripcion);
    if (meta->niveles && meta->niveles[0])
        bprintf(b, "// niveles: %s\n", meta->niveles);
    /* Lo que no sea una clave conocida se copia tal cual, para que un .drklvl
     * que alguien edita a mano no pierda sus comentarios al volver a guardarlo. */
    {
        int i;
        for (i = 0; i < meta->n_extra; i++) {
            if (meta->extra[i][0] == '/' && meta->extra[i][1] == '/')
                bprintf(b, "%s\n", meta->extra[i]);
            else
                bprintf(b, "// %s\n", meta->extra[i]);
        }
    }
    badd(b, "//\n// --- MAP ---\n");
}

int ed_lvl_write(ed_doc_t *doc, const char *filename, ed_lvl_meta_t *meta)
{
    lvlbuf_t out;
    char *map;
    FILE *f;
    size_t escritos;
    int rc = 0;

    map = save_map_to_string(doc->map);
    if (!map)
        return 1;

    memset(&out, 0, sizeof(out));
    badd(&out, "");
    cabecera_a_buf(&out, meta);
    badd(&out, map);
    free(map);

    f = fopen(filename, "wb");
    if (!f) {
        free(out.s);
        return 1;
    }
    escritos = out.len ? fwrite(out.s, 1, out.len, f) : 0;
    if (escritos != out.len)
        rc = 1;
    if (fclose(f) != 0)
        rc = 1;
    free(out.s);
    return rc;
}

/* ------------------------------------------------------------------- leer */

/* Parte un .drklvl en cabecera y mapa. Devuelve 0 si va bien. La cabecera se
 * mete en meta y el texto del .map en *mapa (que hay que soltar con free). */
static int partir(const char *texto, ed_lvl_meta_t *meta, char **mapa)
{
    const char *p = texto;
    int pasada_cabecera = 0;

    memset(meta, 0, sizeof(*meta));
    meta->n_extra = 0;

    while (*p) {
        const char *fin = strchr(p, '\n');
        size_t len = fin ? (size_t)(fin - p) : strlen(p);
        char *linea = copiar_n(p, len);
        char *t = trim(linea);
        int i, conocida = 0;

        if (!pasada_cabecera && strncmp(t, "// --- MAP ---", 13) == 0) {
            pasada_cabecera = 1;
            free(linea);
            p = fin ? fin + 1 : p + len;
            continue;
        }

        if (!pasada_cabecera) {
            for (i = 0; claves[i]; i++) {
                size_t kl = strlen(claves[i]);
                if (strncmp(t, "// ", 3) == 0 &&
                    igual_ci(t + 3, claves[i]) &&
                    t[3 + kl] == ':') {
                    char **campo = NULL;
                    if (strcmp(claves[i], "nombre") == 0) campo = &meta->nombre;
                    else if (strcmp(claves[i], "autor") == 0) campo = &meta->autor;
                    else if (strcmp(claves[i], "descripcion") == 0) campo = &meta->descripcion;
                    else campo = &meta->niveles;
                    free(*campo);
                    *campo = xstrdup(trim(t + 3 + kl + 1));
                    conocida = 1;
                    break;
                }
            }
            if (!conocida && meta->n_extra < ED_LVL_EXTRA_MAX)
                meta->extra[meta->n_extra++] = xstrdup(t);
        }

        free(linea);
        p = fin ? fin + 1 : p + len;
    }

    if (!pasada_cabecera) {
        /* Sin la linea separadora: el fichero no es nuestro. Que lo decida el
         * que llama, y no partir un .map normal como si fuera un nivel. */
        return 1;
    }

    *mapa = xstrdup(p);
    return 0;
}

int ed_lvl_read(const char *filename, ed_lvl_meta_t *meta, char **mapa)
{
    char *texto;
    FILE *f = fopen(filename, "rb");
    long tam;
    int rc;

    if (!f)
        return 1;
    if (fseek(f, 0, SEEK_END) != 0) {
        fclose(f);
        return 1;
    }
    tam = ftell(f);
    if (tam < 0) {
        fclose(f);
        return 1;
    }
    rewind(f);
    texto = xmalloc((size_t)tam + 1);
    if (tam > 0 && fread(texto, 1, (size_t)tam, f) != (size_t)tam) {
        free(texto);
        fclose(f);
        return 1;
    }
    texto[tam] = 0;
    fclose(f);

    rc = partir(texto, meta, mapa);
    free(texto);
    return rc;
}

void ed_lvl_meta_free(ed_lvl_meta_t *meta)
{
    int i;
    free(meta->nombre);
    free(meta->autor);
    free(meta->descripcion);
    free(meta->niveles);
    {
        for (i = 0; i < meta->n_extra; i++)
            free(meta->extra[i]);
    }
    memset(meta, 0, sizeof(*meta));
}
