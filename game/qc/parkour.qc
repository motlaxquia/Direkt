// ===================================================================
// parkour.qc --arse por el mapa
// ===================================================================
//
// Que hay aqui
//
// Las cinco cosas que no estan en el Quake de siempre: deslizarse, el salto
// automatico, el dash con planeo, el salto contra la pared y la carrera por la
// pared.
//
// Donde van las teclas
//
// El juego no recibe teclas: recibe "mover, disparar, usar, saltar" y un
// impulso. Las demas no llegan. Shift y Ctrl tampoco llegaban, asi que los
// motores han montado un 模块 pequeno: cada frame que estan pulsadas, el cliente
// manda su numero como impulso (Key_ImpulsoTeclas, en keys.c de cada motor, con
// el cvar cl_teclas_juego). Aqui solo se mira que impulso llega.
//
// O sea que da igual como se llame al reparto: si llega el 27, Shift esta
// pulsado. Y se cambia sin tocar el juego:
//
//     set cl_teclas_juego "SHIFT=27 CTRL=28"
//
// ------------------------------------------------------------------
// OJO: como se lee un componente de un vector en este compilador
// ------------------------------------------------------------------
//
// fteqcc, tal como esta configurado aqui, NO deja leer v[2] de un vector: lo
// lee como un vector y las comparaciones salen siempre falsas. Silence.
//
// Lo que si funciona son los sufijos de los campos de una entidad:
//
//     self.velocity_z          si
//     self.origin_z            si
//     self.origin[2]           NO: se lee mal
//
// Y los vectores globales (trace_plane_normal, trace_endpos, v_forward) no tienen
// sufijos, asi que tampoco se pueden leer componente a componente.
//
// El rodeo es la sonda: una entidad invisible que no colisiona, en la que se
// copia el vector y de la que se lee el componente con el sufijo. Asi:
//
//     direkt_sonda.origin = trace_plane_normal;
//     if (direkt_sonda.origin_z > 0.9) ...
//
// Toda funcion de este fichero que necesite un componente de un vector global
// pasa por ahi. Y por eso la sonda se crea en worldspawn (direkt.qc).

// ------------------------------------------------------------------ la sonda
//
// No se ve, no colisiona y no se mueve. Solo guarda un vector.
entity	direkt_sonda;

// Pone un vector en la sonda para poderle leer un componente.
void(vector v) direkt_sonda_poner = { direkt_sonda.origin = v; };

// ------------------------------------------------------------------ teclas
//
// El motor vacia self.impulse en cuanto el juego lo mira, y el cliente lo
// vuelve a mandar cada frame mientras la tecla este pulsada. Asi que no hace
// falta guardar si se pulso: basta con leer el impulso de este frame.
//
// Con una salvedad: si se pierde un paquete, llega un frame sin impulso y la
// tecla parece soltada. Por eso no se decide "pulsada o no" sino "pulsada hace
// poco": se guarda el instante y se da una gracia. Un frame perdido no corta el
// dash a la mitad.
#define DIREKT_IMPULSO_MOD      27	// Shift: dash, planeo y carrera por la pared
#define DIREKT_IMPULSO_DESLIZAR 28	// Ctrl: deslizarse

#define DIREKT_TECLA_GRACIA 0.15

float	direkt_mod_hasta;			// hasta que momento vale Shift
float	direkt_deslizar_hasta;	// hasta que momento vale Ctrl

// Se leen al principio del prethink, antes de que nadie mire self.impulse.
void() direkt_teclas =
{
	if (self.impulse == DIREKT_IMPULSO_MOD)
	{
		direkt_mod_hasta = time + DIREKT_TECLA_GRACIA;
		self.impulse = 0;
	}
	else if (self.impulse == DIREKT_IMPULSO_DESLIZAR)
	{
		direkt_deslizar_hasta = time + DIREKT_TECLA_GRACIA;
		self.impulse = 0;
	}
};

float() direkt_pulsada_mod = { return time < direkt_mod_hasta; };
float() direkt_pulsada_deslizar = { return time < direkt_deslizar_hasta; };

// ------------------------------------------------------------------ suelo
//
// El motor no expone FL_ONGROUND a QuakeC, asi que no se puede preguntar "estoy
// en el suelo" directamente. Se deduce con un traceline corto hacia abajo: si el
// rayo para antes de llegar al final hay algo debajo, y si ademas la normal es
// plana es suelo y no una pared.
//
// El rayo sale del centro del cuerpo y llega 32 unidades. Los pies estan 24 por
// debajo del origen, asi que 16 se quedaban cortos y nunca llegaban. Con 32
// pasa unos 8 por debajo de los pies, que es lo justo para que andando por un
// escalon no se pierda el suelo a ratos.
//
// La normal tiene que ser de suelo (arriba) y no de pared (lateral): un rayo que
// pega en la pared de al lado no cuenta. Por eso se mira el eje z, que es lo
// unico que se puede mirar (ver la nota de la sonda).
#define DIREKT_SUELO_DISTANCIA 32
// Por debajo de este valor la normal ya no es "plana" sino una rampa empinada, y
// ahi no se hace bunny hop: en una rampa casi vertical el jugador esta cayendo,
// no andando.
#define DIREKT_SUELO_NORMAL_MINIMA 0.5

float() direkt_piso =
{
	traceline(self.origin, self.origin - ('0 0 1' * DIREKT_SUELO_DISTANCIA), 1, self);
	if (trace_fraction >= 1)
		return 0;

	direkt_sonda_poner(trace_plane_normal);
	return direkt_sonda.origin_z >= DIREKT_SUELO_NORMAL_MINIMA;
};

// ------------------------------------------------------------------ pared
//
// Lo mismo que el suelo pero de lado. Se pasa la direccion en la que se mira
// (normalmente v_forward o v_right) y se devuelve elocuantia pared hay.
//
// Devolver el dato y no un si/no, porque el dash pegado a la pared necesita saber
// a quantas unidades esta.
#define DIREKT_PARED_DISTANCIA 20

// Distancia a la pared que hay en la direccion dada, o 0 si no hay ninguna.
float(vector hacia) direkt_pared =
{
	local float d;

	if (!hacia)
		return 0;

	traceline(self.origin, self.origin + hacia * DIREKT_PARED_DISTANCIA, 1, self);
	if (trace_fraction >= 1)
		return 0;

	d = trace_fraction * DIREKT_PARED_DISTANCIA;
	return d;
};

// Normal de la ultima llamada a direkt_pared, puesta en la sonda.
float() direkt_pared_normal_z = { return direkt_sonda.origin_z; };
float() direkt_pared_normal_x = { return direkt_sonda.origin_x; };
float() direkt_pared_normal_y = { return direkt_sonda.origin_y; };

// ------------------------------------------------------------------ avisos
//
// Cada cambio de estado se escribe en el log con un "echo". Es lo que permite
// comprobarlo de verdad desde el banco de pruebas (pulsar la tecla de verdad y
// mirar lo que dijo el juego) y ademas sirve para diagnosticar sin herramientas.
//
// Los cambios, no el estado: si se escribiera el estado cada frame, un simple
// "grep" no distinguiria "se pulso y se solto" de "no se pulso nunca".
// Estado de la ultima vez que se aviso, para no repetir.
float	direkt_aviso_mod;
float	direkt_aviso_desl;
float	direkt_aviso_piso;

// El suelo necesita dos frames seguidos para darlo por bueno. En un escalon el
// rayo entra y sale durante un frame y sin esto el log seria un lio de
// "en el suelo, en el aire, en el suelo" y no diria nada.
#define DIREKT_PISO_CONFIRMACION 2

float	direkt_piso_filas;

void()	direkt_avisa_teclas;
void()	direkt_avisa_piso;

// Se llama desde el prethink, en cuanto se han leido las teclas.
void() direkt_avisa_teclas =
{
	local float mod;
	local float desl;

	mod = direkt_pulsada_mod();
	desl = direkt_pulsada_deslizar();

	if (mod != direkt_aviso_mod)
	{
		direkt_aviso_mod = mod;
		if (mod)
			localcmd(" echo DIREKT: modificador pulsado");
		else
			localcmd(" echo DIREKT: modificador soltado");
	}

	if (desl != direkt_aviso_desl)
	{
		direkt_aviso_desl = desl;
		if (desl)
			localcmd(" echo DIREKT: deslizar pulsado");
		else
			localcmd(" echo DIREKT: deslizar soltado");
	}
};

void() direkt_avisa_piso =
{
	// Dos frames seguidos en el suelo, o dos fuera, antes de decir nada.
	if (direkt_piso())
		direkt_piso_filas = direkt_piso_filas + 1;
	else
		direkt_piso_filas = 0;

	if (direkt_aviso_piso)
	{
		if (direkt_piso_filas <= 0)
		{
			direkt_aviso_piso = 0;
			localcmd(" echo DIREKT: en el aire");
		}
		return;
	}

	if (direkt_piso_filas >= DIREKT_PISO_CONFIRMACION)
	{
		direkt_aviso_piso = 1;
		localcmd(" echo DIREKT: en el suelo");
	}
};
