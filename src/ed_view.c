/* ed_view.c -- matematicas de la vista.
 *
 * GPL-2.0, ver LICENSE en la raiz del repositorio.
 *
 * Convencion de ejes, la misma de Quake: x al este, y al norte, z arriba. El
 * yaw 0 mira a +x y sube hacia -y, que es como esta en el motor; asi una
 * camara y un `info_player_start` mirando a 0 grados miran al mismo sitio.
 */

#define _GNU_SOURCE
#include "ed_view.h"

#include <math.h>
#include <string.h>

#define DEG2RAD (3.14159265358979323846f / 180.0f)

/* Convencion, la misma que Quake para que un "angle" de un mapa y el yaw de la
 * camara signifiquen lo mismo:
 *
 *   yaw 0   = mirando a +x (este)
 *   yaw 90  = mirando a +y (norte)
 *   pitch   = positivo hacia arriba
 */
void ed_cam_forward(const ed_cam_t *cam, vec3_t out)
{
	float cy = cosf(cam->ang[1] * DEG2RAD);
	float sy = sinf(cam->ang[1] * DEG2RAD);
	float sp = sinf(cam->ang[0] * DEG2RAD);
	float cp = cosf(cam->ang[0] * DEG2RAD);

	out[0] = cy * cp;
	out[1] = sy * cp;
	out[2] = sp;
}

void ed_cam_right(const ed_cam_t *cam, vec3_t out)
{
	vec3_t f;
	float l;

	ed_cam_forward(cam, f);
	/* derecha = fwd x (0,0,1), que para un mapa en el plano xy no tiene
	 * componente z: (fwd.y, -fwd.x, 0). */
	out[0] = f[1];
	out[1] = -f[0];
	out[2] = 0.0f;
	l = sqrtf(out[0] * out[0] + out[1] * out[1] + out[2] * out[2]);
	if (l > 1e-6f) {
		out[0] /= l;
		out[1] /= l;
		out[2] /= l;
	} else {
		out[0] = 1.0f;
		out[1] = 0.0f;
		out[2] = 0.0f;
	}
}

void ed_cam_up(const ed_cam_t *cam, vec3_t out)
{
	vec3_t f, r;
	float l;

	ed_cam_forward(cam, f);
	ed_cam_right(cam, r);
	/* arriba = derecha x adelante */
	out[0] = r[1] * f[2] - r[2] * f[1];
	out[1] = r[2] * f[0] - r[0] * f[2];
	out[2] = r[0] * f[1] - r[1] * f[0];
	l = sqrtf(out[0] * out[0] + out[1] * out[1] + out[2] * out[2]);
	if (l > 1e-6f) {
		out[0] /= l;
		out[1] /= l;
		out[2] /= l;
	}
}

void ed_cam_init(ed_cam_t *cam, vec3_t target)
{
	memset(cam, 0, sizeof(*cam));
	cam->ang[0] = 0.0f;   /* mira a +x */
	cam->ang[1] = 90.0f;  /* horizontal */
	cam->fov = 90.0f;
	cam->znear = 1.0f;
	cam->width = 640;
	cam->height = 480;
	cam->org[0] = target[0] - 160.0f;
	cam->org[1] = target[1] - 160.0f;
	cam->org[2] = target[2] + 96.0f;
}

static float wrap180(float a)
{
	while (a > 180.0f)
		a -= 360.0f;
	while (a < -180.0f)
		a += 360.0f;
	return a;
}

void ed_cam_turn(ed_cam_t *cam, float yaw, float pitch)
{
	cam->ang[1] = wrap180(cam->ang[1] + yaw);
	cam->ang[0] += pitch;
	/* El pitch se limita a +/-90: mas alla, la camara mire al techo y el
	 * mapa se ve del reves, que no ayuda a colocar nada. */
	if (cam->ang[0] > 90.0f)
		cam->ang[0] = 90.0f;
	if (cam->ang[0] < -90.0f)
		cam->ang[0] = -90.0f;
}

void ed_cam_move(ed_cam_t *cam, float forward, float strafe, float up)
{
	vec3_t f, r;
	int i;

	ed_cam_forward(cam, f);
	ed_cam_right(cam, r);
	for (i = 0; i < 3; i++)
		cam->org[i] += f[i] * forward + r[i] * strafe + (i == 2 ? up : 0.0f);
}

void ed_cam_ray(const ed_cam_t *cam, float sx, float sy, vec3_t org, vec3_t dir)
{
	vec3_t f, r, up;
	float half, aspect, nx, ny, l;

	ed_cam_forward(cam, f);
	ed_cam_right(cam, r);
	ed_cam_up(cam, up);

	if (cam->iso) {
		/* En isometrico no hay perspectiva: un pixel son iso_scale unidades de
		 * mundo en las dos direcciones, y el rayo sale en diagonal. Sin esto,
		 * pinchar en un sitio y pinchar en el brushes de ahi dejarian de
		 * cuadrar justo en la vista nueva. */
		nx = (sx - (float)cam->width * 0.5f) * cam->iso_scale;
		ny = ((float)cam->height * 0.5f - sy) * cam->iso_scale;
	} else {
		half = tanf(cam->fov * 0.5f * DEG2RAD);
		aspect = (cam->height > 0) ? (float)cam->width / (float)cam->height : 1.0f;

		/* El pixel va de -1 a 1, con y hacia arriba (la ventana crece hacia
		 * abajo, la vista hacia arriba). */
		nx = ((sx / (float)cam->width) * 2.0f - 1.0f) * half * aspect;
		ny = (1.0f - (sy / (float)cam->height) * 2.0f) * half;
	}

	for (int i = 0; i < 3; i++)
		dir[i] = f[i] + r[i] * nx + up[i] * ny;
	l = sqrtf(dir[0] * dir[0] + dir[1] * dir[1] + dir[2] * dir[2]);
	if (l > 1e-6f) {
		dir[0] /= l;
		dir[1] /= l;
		dir[2] /= l;
	}
	VectorCopy(cam->org, org);
}

float ed_ray_point_dist(vec3_t org, vec3_t dir, vec3_t p)
{
	vec3_t v;
	float t;

	v[0] = p[0] - org[0];
	v[1] = p[1] - org[1];
	v[2] = p[2] - org[2];
	t = v[0] * dir[0] + v[1] * dir[1] + v[2] * dir[2];
	if (t < 0.0f)
		return -1.0f;
	/* Distancia perpendicular: se proyecta el punto sobre el rayo y se mide
	 * lo que sobra. */
	{
		vec3_t perp;
		for (int i = 0; i < 3; i++)
			perp[i] = v[i] - dir[i] * t;
		return sqrtf(perp[0] * perp[0] + perp[1] * perp[1] + perp[2] * perp[2]);
	}
}

/* ------------------------------------------------------------------ matrices */

void ed_matrix_identity(float *m)
{
	memset(m, 0, 16 * sizeof(float));
	m[0] = m[5] = m[10] = m[15] = 1.0f;
}

/* m = a * b, las dos en orden columna-mayor (como las de OpenGL). */
void ed_matrix_multiply(float *out, const float *a, const float *b)
{
	float tmp[16];
	int c, r, k;

	for (c = 0; c < 4; c++)
		for (r = 0; r < 4; r++) {
			float s = 0.0f;
			for (k = 0; k < 4; k++)
				s += a[k * 4 + r] * b[c * 4 + k];
			tmp[c * 4 + r] = s;
		}
	memcpy(out, tmp, sizeof(tmp));
}

void ed_matrix_perspective(float *m, float fovy, float aspect, float znear, float zfar)
{
	float f, rn;

	memset(m, 0, 16 * sizeof(float));
	f = 1.0f / tanf(fovy * 0.5f * DEG2RAD);
	rn = 1.0f / (znear - zfar);
	m[0] = f / (aspect > 0.0f ? aspect : 1.0f);
	m[5] = f;
	m[10] = (zfar + znear) * rn;
	m[11] = -1.0f;
	m[14] = 2.0f * zfar * znear * rn;
}

void ed_matrix_ortho(float *m, float l, float r, float b, float t, float znear, float zfar)
{
	memset(m, 0, 16 * sizeof(float));
	m[0] = 2.0f / (r - l);
	m[5] = 2.0f / (t - b);
	m[10] = -2.0f / (zfar - znear);
	m[12] = -(r + l) / (r - l);
	m[13] = -(t + b) / (t - b);
	m[14] = -(zfar + znear) / (zfar - znear);
	m[15] = 1.0f;
}

void ed_cam_projection(const ed_cam_t *cam, float *m)
{
	float aspect;

	if (cam->iso) {
		aspect = (cam->height > 0) ? (float)cam->width / (float)cam->height : 1.0f;
		ed_matrix_ortho(m, -aspect * 0.5f, aspect * 0.5f,
		                -0.5f, 0.5f, -16.0f, 16.0f);
		return;
	}
	aspect = (cam->height > 0) ? (float)cam->width / (float)cam->height : 1.0f;
	ed_matrix_perspective(m, cam->fov, aspect, cam->znear, 65536.0f);
}

/* La diagonal clasica del isometrico: 45 grados de giro y unos 35 grados de
 * caida. No son los 30 exactos del manual, porque con 30 el suelo se ve tan
 * escorzo que las paredes de atras se confunden con las de delante. */
#define DIREKT_ISO_PITCH 35.264f

/* Coloca el ojo a "dist" del objetivo, en la diagonal que marque el yaw. La
 * caida de 35 grados es la del isometrico de manual; con 30 el suelo se ve tan
 * escorzo que las paredes de atras se confunden con las de delante. */
static void ed_cam_iso_colocar(ed_cam_t *cam, float dist)
{
	float yaw = cam->iso_yaw * DEG2RAD;
	float pitch = DIREKT_ISO_PITCH * DEG2RAD;

	/* El ojo va por la direccion opuesta a la que mira, hacia atras y arriba. */
	cam->ang[0] = -DIREKT_ISO_PITCH;
	cam->ang[1] = cam->iso_yaw;
	cam->org[0] = cam->iso_target[0] - dist * cosf(yaw) * cosf(pitch);
	cam->org[1] = cam->iso_target[1] - dist * sinf(yaw) * cosf(pitch);
	cam->org[2] = cam->iso_target[2] + dist * sinf(pitch);
}

void ed_cam_iso(ed_cam_t *cam, vec3_t target)
{
	cam->iso = 1;
	cam->iso_yaw = 45.0f;
	cam->iso_scale = 0.5f;
	VectorCopy(target, cam->iso_target);
	ed_cam_iso_colocar(cam, 2048.0f);
}

void ed_cam_iso_zoom(ed_cam_t *cam, float factor)
{
	float dist;

	/* Menos unidades por pixel es mas zoom. Sin limites, con la rueda del raton
	 * se acaba en un numero tan pequeno que el flotante se come el mundo
	 * entero. */
	cam->iso_scale *= factor;
	if (cam->iso_scale < 0.001f)
		cam->iso_scale = 0.001f;
	if (cam->iso_scale > 40.0f)
		cam->iso_scale = 40.0f;

	/* El zoom tambien mueve el ojo, y si no se queda mirando al mismo sitio y
	 * el nivel se ve mas grande sin que se note hacia donde. */
	dist = 2048.0f * cam->iso_scale / 0.5f;
	ed_cam_iso_colocar(cam, dist);
}

void ed_cam_iso_turn(ed_cam_t *cam, float yaw)
{
	cam->iso_yaw += yaw;
	/* El objetivo se queda quieto, que es lo que hace util girar: el mapa no se
	 * va de sitio mientras se busca el otro lado. */
	if (cam->iso_yaw > 3600.0f || cam->iso_yaw < -3600.0f)
		cam->iso_yaw = (cam->iso_yaw > 0.0f) ? 0.0f : 0.0f;
	ed_cam_iso_colocar(cam, 2048.0f * cam->iso_scale / 0.5f);
}

void ed_matrix_look_at(float *m, vec3_t eye, vec3_t fwd, vec3_t up)
{
	vec3_t s, u, f, neye;
	float l;

	VectorCopy(eye, neye);
	VectorCopy(fwd, f);
	l = sqrtf(f[0] * f[0] + f[1] * f[1] + f[2] * f[2]);
	if (l > 1e-6f) {
		f[0] /= l;
		f[1] /= l;
		f[2] /= l;
	}
	/* s = f x up */
	s[0] = f[1] * up[2] - f[2] * up[1];
	s[1] = f[2] * up[0] - f[0] * up[2];
	s[2] = f[0] * up[1] - f[1] * up[0];
	l = sqrtf(s[0] * s[0] + s[1] * s[1] + s[2] * s[2]);
	if (l < 1e-6f) {
		/* Mirando droitamente arriba o abajo: la derecha no existe. Se
		 * elige cualquier perpendicular para que la matriz siga siendo
		 * valida, en vez de dividir por cero. */
		s[0] = 1.0f;
		s[1] = 0.0f;
		s[2] = 0.0f;
		l = 1.0f;
	}
	s[0] /= l;
	s[1] /= l;
	s[2] /= l;

	/* u = s x f */
	u[0] = s[1] * f[2] - s[2] * f[1];
	u[1] = s[2] * f[0] - s[0] * f[2];
	u[2] = s[0] * f[1] - s[1] * f[0];

	/* gluLookAt, en columna-mayor. */
	m[0] = s[0];  m[4] = s[1];  m[8]  = s[2];  m[12] = -(s[0] * neye[0] + s[1] * neye[1] + s[2] * neye[2]);
	m[1] = u[0];  m[5] = u[1];  m[9]  = u[2];  m[13] = -(u[0] * neye[0] + u[1] * neye[1] + u[2] * neye[2]);
	m[2] = -f[0]; m[6] = -f[1]; m[10] = -f[2]; m[14] = (f[0] * neye[0] + f[1] * neye[1] + f[2] * neye[2]);
	m[3] = 0.0f;  m[7] = 0.0f;  m[11] = 0.0f;  m[15] = 1.0f;
}
