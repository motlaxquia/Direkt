/* ed_gui.h -- ventana del editor.
 *
 * GPL-2.0, ver LICENSE en la raiz del repositorio.
 */

#ifndef DIREKT_ED_GUI_H
#define DIREKT_ED_GUI_H

#include "editor.h"

/* Abre la ventana y entra en el bucle hasta que se cierre.
 *
 * Hay un modo sin ventana (`--shot`), que hace exactamente el mismo trabajo de
 * dibujo pero en un bucle finito y vuelca un PPM. Es lo que permite probar el
 * editor en un banco de pruebas, igual que se hace con el motor.
 */
int ed_gui_run(ed_doc_t *doc);

/* Solo para las pruebas: dibuja un fotograma en un PPM y sale. Devuelve 0 si
 * todo bien. shot_renderer 0 = alambre, 1 = solido. */
int ed_gui_snapshot(ed_doc_t *doc, const char *salida_ppm, int shot_renderer,
                    int w, int h);

#endif /* DIREKT_ED_GUI_H */
