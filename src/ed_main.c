/* ed_main.c -- programa principal del editor de niveles.
 *
 * GPL-2.0, ver LICENSE en la raiz del repositorio.
 *
 *   direkt-edit <mapa.map>     abre el editor
 *   direkt-edit --new           abre un mapa en blanco
 *   direkt-edit --selftest [m]  prueba la logica sin abrir ninguna ventana
 */

#define _GNU_SOURCE
#include "editor.h"
#include "ed_gui.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void usage(void)
{
	fprintf(stderr,
	        "direkt-edit " DIREKTBSP_VERSION " -- editor de niveles de Quake\n"
	        "\n"
	        "  direkt-edit <mapa.map>     abre el editor\n"
	        "  direkt-edit --new           abre un mapa en blanco\n"
	        "  direkt-edit --selftest [m]  prueba la logica sin ventana\n"
	        "  direkt-edit --shot <salida.ppm>  dibuja un fotograma y sale\n"
	        "  direkt-edit --solido        el fotograma va en modo solido\n"
	        "\n"
	        "Atajos dentro del editor (F1 los lista):\n"
	        "  F2 guardar   F5 compilar .bsp   B caja   D duplicar\n"
	        "  Supr borrar  Ctrl+Z deshacer     flechas mueven la brush\n");
	exit(2);
}

int main(int argc, char **argv)
{
	ed_doc_t *doc;
	int selftest = 0;
	int nuevo = 0;
	const char *archivo = NULL;
	const char *shot = NULL;
	int renderer = 0;
	int i;

	for (i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--selftest") == 0)
			selftest = 1;
		else if (strcmp(argv[i], "--new") == 0)
			nuevo = 1;
		else if (strcmp(argv[i], "--shot") == 0 && i + 1 < argc) {
			shot = argv[++i];
		} else if (strcmp(argv[i], "--solido") == 0) {
			renderer = 1;
		}
		else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0)
			usage();
		else if (argv[i][0] == '-')
			usage();
		else
			archivo = argv[i];
	}

	if (selftest)
		return ed_selftest(archivo);

	if (nuevo && archivo) {
		fprintf(stderr, "ERROR: --new y un mapa a la vez no tiene sentido\n");
		return 2;
	}
	if (archivo)
		doc = ed_doc_load(archivo);
	else
		doc = ed_doc_new();

	if (shot) {
		/* Con la ventana no se puede comprobar nada en un banco de
		 * pruebas. El snapshot dibuja el mismo fotograma y escribe un PPM,
		 * que es lo que allowe testear el dibujo sin pantalla. */
		int w = 1024, h = 768;
		const char *a;
		for (a = shot + strlen(shot) - 1; a > shot && *a != '/'; a--)
			if (*a == '.') {
				w = 1280;
				h = 960;
				break;
			}
		return ed_gui_snapshot(doc, shot, renderer, w, h);
	}

	return ed_gui_run(doc);
}
