/* direkt-bsp -- programa principal.
 *
 * GPL-2.0, ver LICENSE en la raiz del repositorio.
 */

#define _GNU_SOURCE
#include "direktbsp.h"
#include "tex.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void usage(void)
{
	fprintf(stderr,
	        "direkt-bsp " DIREKTBSP_VERSION " -- compilador de mapas de Quake\n"
	        "\n"
	        "  direkt-bsp <entrada.map> <salida.bsp>   compila\n"
	        "  direkt-bsp --info <entrada.map>         solo analiza el .map\n"
	        "  direkt-bsp --check <fichero.bsp>        valida un .bsp escrito\n"
	        "\n"
	        "El .map va en el subconjunto clasico: caras planas con puntos.\n");
	exit(2);
}

static void dump_map(const char *filename)
{
	map_t *map = parse_map(filename);
	entity_t *e;
	brush_t *b;
	int nb = 0, nsol = 0, ntrig = 0, nmov = 0;

	printf("entidades: %d\n", map->numentities);
	printf("brushes:   %d\n", map->numbrushes);

	for (b = map->brushes; b; b = b->next) {
		nb++;
		if (b->contents == CONTENTS_EMPTY)
			ntrig++;
		else
			nsol++;
		if (b->moving)
			nmov++;
	}

	for (e = map->entities; e; e = e->next) {
		const char *cn = entity_key(e, "classname");
		int nb = 0;
		for (b = e->brushes; b; b = b->next)
			nb++;
		printf("  %-22s brushes=%d%s\n", cn ? cn : "(sin classname)", nb,
		       e->is_world ? "  [worldspawn]" : "");
	}

	printf("solidas: %d  triggers: %d  moviles: %d\n", nsol, ntrig, nmov);
	free_map(map);
}

int main(int argc, char **argv)
{
	if (argc == 3 && strcmp(argv[1], "--info") == 0) {
		dump_map(argv[2]);
		return 0;
	}

	if (argc == 3 && strcmp(argv[1], "--check") == 0) {
		int rc = check_bsp(argv[2]);
		printf("check_bsp: %s\n", rc == 0 ? "correcto" : "FALLO");
		return rc == 0 ? 0 : 1;
	}

	if (argc == 3) {
		map_t *map = parse_map(argv[1]);
		bsp_t *bsp = compile_map(map);
		texlib_t *tex;
		int rc;

		/* Las texturas se sacan de los .bsp que ya trae el juego (ver tex.h:
		 * LibreQuake las lleva embebidas y no en gfx.wad). Si no se
		 * encuentran, el lump sale vacio y el motor pinta con la textura por
		 * defecto, que es mejor que no compilar. */
		tex = texlib_open_juego();
		if (tex) {
			bsp->tex = tex;
			if (texlib_count(tex) == 0)
				fprintf(stderr,
				        "direkt-bsp: aviso, no se han encontrado texturas; el "
				        ".bsp saldra sin lump TEXTURES\n");
		} else {
			fprintf(stderr,
			        "direkt-bsp: aviso, no se ha podido abrir la biblioteca de "
			        "texturas; el .bsp saldra sin lump TEXTURES\n");
		}

		rc = write_bsp(argv[2], bsp, map);
		free_bsp(bsp);
		free_map(map);
		texlib_close(tex);
		return rc;
	}

	usage();
	return 2;
}
