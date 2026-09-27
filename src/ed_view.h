/* ed_view.h -- matematicas de la vista del editor.
 *
 * GPL-2.0, ver LICENSE en la raiz del repositorio.
 *
 * Camara, proyeccion y conversion de raton a rayo. No sabe nada de SDL ni de
 * OpenGL: son las formulas del motor, para que la misma vista serve tanto si
 * se dibuja con GL como si se comprueba en un test sin pantalla.
 *
 * El motor solo tiene GL 1.2, y es lo que se usa. Con eso alcanza: matrices
 * de modelo y proyeccion, vertices y color por vertice. No hace falta ni GLEW
 * ni shaders.
 */

#ifndef DIREKT_ED_VIEW_H
#define DIREKT_ED_VIEW_H

#include "editor.h"

typedef struct {
	vec3_t org;    /* donde esta el ojo */
	vec3_t ang;    /* yaw (0 = +x), pitch, en grados */
	float fov;     /* vertical, en grados */
	int width, height;
	float znear;   /* plano cercano; muy pequena para que no se recorte */
} ed_cam_t;

void ed_cam_init(ed_cam_t *cam, vec3_t target);
/* Gira la camara. yaw en grados, 0 mira a +x. */
void ed_cam_turn(ed_cam_t *cam, float yaw, float pitch);
/* Mueve la camara en el plano (strafe) y hacia donde mira (avance). */
void ed_cam_move(ed_cam_t *cam, float forward, float strafe, float up);
/* Direccion unitaria hacia donde mira. */
void ed_cam_forward(const ed_cam_t *cam, vec3_t out);
/* Direccion de la derecha, para el strafe. */
void ed_cam_right(const ed_cam_t *cam, vec3_t out);
void ed_cam_up(const ed_cam_t *cam, vec3_t out);

/* Convierte un pixel en un rayo que sale de la camara. sx y sy en pixeles con
 * (0,0) arriba a la izquierda. */
void ed_cam_ray(const ed_cam_t *cam, float sx, float sy, vec3_t org, vec3_t dir);

/* Distancia de un punto al rayo, o -1 si no lo va a alcanzar. La usa el modo
 * de arrastrar caras: hay que saber a que distancia esta la brush. */
float ed_ray_point_dist(vec3_t org, vec3_t dir, vec3_t p);

/* ---- matrices en columna-mayor, como las que espera glLoadMatrixf ---- */
void ed_matrix_identity(float *m);
void ed_matrix_perspective(float *m, float fovy, float aspect, float znear, float zfar);
void ed_matrix_look_at(float *m, vec3_t eye, vec3_t fwd, vec3_t up);
void ed_matrix_multiply(float *out, const float *a, const float *b);

#endif /* DIREKT_ED_VIEW_H */
