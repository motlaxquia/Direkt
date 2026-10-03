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
	/* Modo isometrico. Con iso a 0 todo esto da igual y la vista es la de
	 * siempre, en perspectiva. Con iso a 1 la proyeccion es ortogonal y la
	 * camara mira en diagonal, que es lo que hace que se vea como un plano
	 * elevado de una vez. */
	int   iso;     /* 1 = isometrica */
	float iso_yaw; /* giro alrededor del eje vertical, en grados */
	float iso_scale;/* unidades de mundo por pixel, que fija el zoom */
	vec3_t iso_target; /* punto que se queda quieto al girar y al hacer zoom */
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
/* Ortogonal, que es la que usa la vista isometrica. left/right/bottom/top van
 * en unidades de mundo, ya que en esta proyeccion no hay profundidad. */
void ed_matrix_ortho(float *m, float l, float r, float b, float t, float znear, float zfar);
/* La matriz de proyeccion que le toca a la camara, segun sea perspectiva o
 * isometrica. Lo llama el dibujo y lo llama tambien ed_cam_ray, para que el
 * raton y lo que se ve no puedan separarse. */
void ed_cam_projection(const ed_cam_t *cam, float *m);
/* Pone la camara en modo isometrico mirando a target desde una diagonal. */
void ed_cam_iso(ed_cam_t *cam, vec3_t target);
/* Ajustes de zoom y giro en modo isometrico. */
void ed_cam_iso_zoom(ed_cam_t *cam, float factor);
void ed_cam_iso_turn(ed_cam_t *cam, float yaw);
void ed_matrix_look_at(float *m, vec3_t eye, vec3_t fwd, vec3_t up);
void ed_matrix_multiply(float *out, const float *a, const float *b);

#endif /* DIREKT_ED_VIEW_H */
