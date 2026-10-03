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
// fteqcc, tal como esta configurado aqui, NO deja indexar un vector:
//
//     trace_plane_normal[2]    NO: se lee como un vector y sale un vector
//     self.origin[2]           NO: por lo mismo
//
// Lo que si funciona son los sufijos, pero solo en dos sitios:
//
//     self.velocity_z          si, es un campo de entidad
//     local vector v; v_z      si, es una variable local
//
// Y los vectores globales (trace_plane_normal, trace_endpos, v_forward) no tienen
// sufijo, porque no son campos de nadie. Para leerles un componente se copia el
// vector a una variable local y se lee el sufijo de la local:
//
//     local vector normal;
//     normal = trace_plane_normal;
//     if (normal_z > 0.9) ...
//
// No es una mania del compilador sin mas: sin esto la comprobacion de "el suelo
// es plano" salia siempre falsa y el parkour no arrancaba. La prueba del impulso
// 23 tenia el mismo fallo, comparando self.origin[2] consigo misma, y por eso
// decia siempre que el jugador estaba apoyado.

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

// ------------------------------------------------------------------ componentes
//
// Los sufijos que dan un componente (v_x, v_y, v_z) solo funcionan en dos sitios:
// en un campo de entidad (self.velocity_z) y en una variable local. En un vector
// global hay que copiarlo a una local, que es justo lo que hacen estas tres.
//
// Con un vector global no se puede ni por lo mas (ver la nota de mas arriba): al
// indexar (v[2]) sale un vector y las comparaciones dan siempre falsa.
float(vector v) direkt_vx = { return v_x; };
float(vector v) direkt_vy = { return v_y; };
float(vector v) direkt_vz = { return v_z; };

// ------------------------------------------------------------------ suelo
//
// El motor SI dice si el jugador esta en el suelo: SV_WalkMove pone
// FL_ONGROUND en los flags de la entidad (sv_phys.c) cuando el punto de abajo
// acaba en un plano con la normal hacia arriba. defs.qc lo declara, asi que desde
// el juego es un simple "self.flags & FL_ONGROUND".
//
// Y es mejor que deducirlo con un traceline por dos razones: es la verdad del
// motor (no una aproximacion) y no se equivoca en rampas, escalones ni cajas, que
// son justo donde una sonda corta falla.
//
// OJO con el momento: los flags se actualizan DESPUES de mover al jugador, asi que
//   - en el postthink son los de este frame (lo nuevo)
//   - en el prethink son los del frame anterior (un frame de retraso)
//
// Para decidir saltos da igual: un frame de retraso no se nota. Para medir cosas
// hay que saber en cual de los dos se esta mirando.
// OJO: devuelve 1 o 0, no el valor del flag (512). Con 512 cualquier
// comparacion con "==" contra un 1 da falsa y parece que el motor y la sonda no
// coinciden cuando si. Con "if (direkt_piso())" da igual, pero el cruce del banco
// de pruebas compara con "==".
float() direkt_piso =
{
	if (self.flags & FL_ONGROUND)
		return 1;
	return 0;
};

// Sonda de suelo por traceline. Ya no manda en el juego: se usa para COMPROBAR que
// el FL_ONGROUND del motor y esta sonda dicen lo mismo, que es la unica manera de
// saber que el motor esta aplicando la gravedad donde debe. Si un dia dejaran de
// coincidir, el banco de pruebas lo dira en vez de que el parkour falle raro.
#define DIREKT_SUELO_DISTANCIA 32
#define DIREKT_SUELO_NORMAL_MINIMA 0.5

float() direkt_piso_sonda =
{
	local vector normal;

	traceline(self.origin, self.origin - ('0 0 1' * DIREKT_SUELO_DISTANCIA), 1, self);
	if (trace_fraction >= 1)
		return 0;

	normal = trace_plane_normal;
	return normal_z >= DIREKT_SUELO_NORMAL_MINIMA;
};

// ------------------------------------------------------------------ pared
//
// Lo que hay al lado del jugador. A diferencia del suelo, aqui si hace falta la
// normal: el salto contra la pared tiene que empujar en la direccion contraria a
// la cara que se ha tocado, no en la direccion a la que mira el jugador.
//
// La normal se deja en una variable global, porque las funciones de QuakeC no
// devuelven vectores. Quien la lea, la lee antes de volver a llamar aqui.
vector	direkt_pared_normal;

// La distancia, o 0 si no hay nada.
#define DIREKT_PARED_DISTANCIA 24

float(vector hacia) direkt_pared =
{
	local float d;

	if (!hacia)
		return 0;

	traceline(self.origin, self.origin + hacia * DIREKT_PARED_DISTANCIA, 1, self);
	if (trace_fraction >= 1)
		return 0;

	direkt_pared_normal = trace_plane_normal;
	d = trace_fraction * DIREKT_PARED_DISTANCIA;
	return d;
};

// Componentes de la ultima normal, en coordenadas locales de la pared: no
// interested el punto exacto, solo hacia donde empuja.
float() direkt_pared_x = { return direkt_vx(direkt_pared_normal); };
float() direkt_pared_y = { return direkt_vy(direkt_pared_normal); };
float() direkt_pared_z = { return direkt_vz(direkt_pared_normal); };

// ------------------------------------------------------------------ velocidad
//
// El tope. Todo lo que de el parkour pasa por aqui.
//
// Sin tope, el momentum se acumula: el jugador salta, conserva la velocidad, salta
// otra vez mas rapido, y en un minuto va a mil por segundo y el mapa deja de
// tener sentido. Con el tope se mantiene el juego dentro de unos numeros que el
// motor se puede manejar.
//
// 640 es el doble de lo que se anda (sv_maxspeed = 320), que es el salto de
// velocidad tipico del genero. Ni tan rapido que se rompe el mapa, ni tan lento
// que el bunny hop no compense.
#define DIREKT_VELOCIDAD_MAXIMA 640

// Recorta la velocidad horizontal al tope. La vertical no se toca: caer mas rapido
// no es lo mismo que correr mas rapido, y el planeo ya controla esa parte.
void() direkt_limita_velocidad =
{
	local vector suelo;
	local float rapidez;

	suelo = self.velocity;
	suelo_z = 0;
	rapidez = vlen(suelo);

	if (rapidez <= DIREKT_VELOCIDAD_MAXIMA)
		return;

	self.velocity_x = suelo_x * DIREKT_VELOCIDAD_MAXIMA / rapidez;
	self.velocity_y = suelo_y * DIREKT_VELOCIDAD_MAXIMA / rapidez;
};

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
// Estado de la medicion del salto.
float	direkt_debug_en_aire;
float	direkt_debug_suelo;
float	direkt_debug_techo;

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
	// Cuanto alto ha sido el salto, dicho al aterrizar.
	//
	// El salto lo pone el juego (el motor no tiene ninguno, ver direkt_salta en
	// player.qc) y estos numeros se ajustan a ojo, asi que hace falta poder verlos
	// desde fuera. QuakeC no imprime numeros con decimales en un "echo", asi que
	// va en tramos: medidos, sin el empuje extra el salto llega a unos 45 y con el
	// a unos 75 (un salto del Quake de siempre son unos 56).
	//
	// El banco comprueba que sale el tramo "alto", que es la prueba de que el
	// empuje del salto hace algo y de cuanto.
	if (direkt_piso())
	{
		if (direkt_debug_en_aire)
		{
			local float altura;

			altura = direkt_debug_techo - direkt_debug_suelo;

			// Los tramos estan medidos, no puestos a ojo: sin el empuje extra el
			// salto llega a unos 45 y con el a unos 75. Un salto del Quake de
			// siempre son unos 56, asi que el empuje lo deja mas alto que el
			// original, que es lo que se buscaba.
			if (altura < 40)
				localcmd(" echo DIREKT: el salto es corto");
			else if (altura < 65)
				localcmd(" echo DIREKT: el salto es normal");
			else if (altura < 95)
				localcmd(" echo DIREKT: el salto es alto");
			else
				localcmd(" echo DIREKT: el salto es gigante");

			direkt_debug_en_aire = 0;
			direkt_debug_suelo = self.origin_z;
			direkt_debug_techo = self.origin_z;
		}

		direkt_piso_filas = direkt_piso_filas + 1;
	}
	else
	{
		if (self.origin_z > direkt_debug_techo)
			direkt_debug_techo = self.origin_z;
		direkt_debug_en_aire = 1;
		direkt_piso_filas = 0;
	}

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

// ------------------------------------------------------------------ deslizarse
//
// Que es
//
// Agacharse y correr, pero sin frenarse: en vez de recortarse la velocidad a la
// de andar agachado, se suelta un empujon y luego se va perdiendo poco a poco. Es
// la regla nueva, y cambia la anterior.
//
// La regla de agacharse sigue igual para cuando NO se desliza: agachado se anda a
// 100. Lo que cambia es que deslizarse ya no es "agacharse rapido", es una cosa
// aparte con su propio empujon y su propia friccion.
//
// Por que hay que librarlo del recorte
//
// El recorte de velocidad de agachado esta en direkt_agacha_anda_lento
// (player.qc) y se aplica en el postthink, o sea al final. Si el deslizamiento no
// se librara de el, cada frame le devolverian la velocidad al jugador y nunca
// pasaria de 100: la sensacion seria la de correr agachado sin mas. Por eso
// mientras se desliza el recorte se salta, y mientras se desliza no cuenta como
// "agachado que anda despacio" en las pruebas del banco.
//
// Las reglas
//
//   - Se empieza deslizando si se pide Ctrl, se va rapido y hay suelo. Con poca
//     velocidad no se entra: si no, cada paso rapido daria un empujon y el
//     jugador no se detendria nunca.
//   - Se agacha SOLO. No hace falta llevar pulsado F4 a la vez: el deslizamiento
//     encoge la caja por su cuenta y al acabar la vuelve a levantar. Pedir dos
     // teclas a la vez para una sola cosa es pedir que no se use.
//   - Al entrar se suelta un empujon, UNA vez. No cada frame, que seria infinito.
//   - Luego se frena con una friccion propia, mas suave que la del motor, para
//     que se deslice una cantidad de rato y no de un tirón.
//   - Se acaba cuando se suelta Ctrl, cuando se acaba el suelo, o cuando ya no
//     queda velocidad. Tambien si el jugador se levanta.
//
// Los numeros
//
// El empujon de entrada es una cantidad fija. La friccion son 12 por frame, con
// lo que desde 400 por segundo se tarda algo mas de un segundo en pararse.
#define DIREKT_DESLIZA_EMPUJE           200
#define DIREKT_DESLIZA_VELOCIDAD_MINIMA 300
#define DIREKT_DESLIZA_FRICCION         12

float	direkt_deslizando;		// 1 mientras dura el deslizamiento
// El deslizamiento solo puede empezar de una pulse en la tecla. Sin esto, al
// acabarse uno el motor vuelve a acelerar al jugador hasta la velocidad de
// andar, que ya llega al minimo, y entra otro: el jugador se pegaba y se
// despegaba del suelo cada dos frames.
float	direkt_desliza_cargado;

void()	direkt_desliza_fin;

// Cambia la velocidad horizontal a la magnitud que se le pase, dejando la
// vertical como esta. Es el nucleo del deslizamiento y del empuje.
void(vector suelo, float magnitud) direkt_agacha_a =
{
	local float largo;

	largo = vlen(suelo);
	if (largo <= 0)
		return;

	self.velocity_x = suelo_x * magnitud / largo;
	self.velocity_y = suelo_y * magnitud / largo;
};

void() direkt_desliza_fin =
{
	if (!direkt_deslizando)
		return;

	direkt_deslizando = 0;
	localcmd(" echo DIREKT: se acaba el deslizamiento");

	// Se vuelve a la caja de pie. Si no cabe (un hueco bajo), el agachado normal
	// de player.qc lo comprueba y no se levanta, que es lo que se quiere: antes
	// esto se llamaba ahi y por eso el deslizamiento se acababa al primer frame.
	direkt_agachado = 0;
};

// Se llama en el prethink, antes de que el motor mueva al jugador.
void() direkt_desliza =
{
	local vector suelo;
	local float rapidez;

	// Muerto no se desliza.
	if (self.deadflag)
	{
		direkt_desliza_fin();
		return;
	}

	suelo = self.velocity;
	suelo_z = 0;
	rapidez = vlen(suelo);

	if (direkt_deslizando)
	{
		// Lo que lo corta: soltar la tecla, quedarse sin suelo, quedarse sin
		// velocidad, o que otro proceso (el agachado de F4/F5) encoge o levante
		// la caja mientras deslizandose.
		if (!direkt_pulsada_deslizar() || !direkt_piso()
		    || self.maxs != DIREKT_BAJO_MAXS
		    || rapidez < DIREKT_DESLIZA_VELOCIDAD_MINIMA)
		{
			direkt_desliza_fin();
			return;
		}

		// La friccion del motor ya frena; esta se aplica encima y es lo que hace
		// que el desliz dure lo que tiene que durar.
		if (rapidez - DIREKT_DESLIZA_FRICCION < DIREKT_DESLIZA_VELOCIDAD_MINIMA)
			rapidez = DIREKT_DESLIZA_VELOCIDAD_MINIMA;
		else
			rapidez = rapidez - DIREKT_DESLIZA_FRICCION;

		direkt_agacha_a(suelo, rapidez);
		return;
	}

	// Todavia no se desliza: se mira si se puede empezar.
	if (!direkt_pulsada_deslizar())
	{
		// Suelta la tecla y se vuelve a poder deslizar.
		direkt_desliza_cargado = 0;
		return;
	}

	if (direkt_desliza_cargado)
		return;
	if (!direkt_piso())
		return;

	// Con poca velocidad no hay deslizamiento: si no, cada paso rapido daria un
	// empujon y el jugador no se detendria nunca.
	if (rapidez < DIREKT_DESLIZA_VELOCIDAD_MINIMA)
		return;

	direkt_deslizando = 1;
	direkt_desliza_cargado = 1;
	localcmd(" echo DIREKT: deslizando");

	// A que velocidad entra, en tres tramos. El banco de pruebas comprueba que
	// sale el tramo alto, que es la prueba de que el deslizamiento se libra de
	// verdad del recorte de velocidad del agachado (que dejaria todo en 100).
	if (rapidez + DIREKT_DESLIZA_EMPUJE >= 600)
		localcmd(" echo DIREKT: el deslizamiento sale muy rapido");
	else if (rapidez + DIREKT_DESLIZA_EMPUJE >= 450)
		localcmd(" echo DIREKT: el deslizamiento sale rapido");
	else
		localcmd(" echo DIREKT: el deslizamiento sale lento");

	// Se agacha aqui mismo. Encoger la caja nunca mete al jugador dentro de un
	// muro, asi que no hay nada que comprobar antes (al contrario que al
	// levantarse, que si puede quedarse con la cabeza en el techo).
	setsize(self, DIREKT_BAJO_MINS, DIREKT_BAJO_MAXS);
	self.view_ofs = DIREKT_BAJO_OJO;

	direkt_agacha_a(suelo, rapidez + DIREKT_DESLIZA_EMPUJE);
};

// ------------------------------------------------------------------ bunny hop
//
// Que es
//
// Mantener Shift y saltar sin soltar el espacio. Cada vez que se toca el suelo se
// salta otra vez, pero sobre todo se conserva la velocidad del vuelo anterior: sin
// eso no es bunny hop, es saltar很多 veces y perderlo todo en cada suelo.
//
// Que no se activa solo con el espacio
//
// A proposito. El salto normal se queda como estaba, y el encadenado es cosa que
// se pide a proposito corriendo (Shift ya es "correr"). Si el rebote fuera solo con
// el espacio no habria forma de dar un salto normal y corto sin soltarlo, que es lo
// que se necesita el 90 por ciento de las veces.
//
// Como se conserva la velocidad
//
// El motor come la velocidad horizontal en el suelo: SV_ClientThink (que es donde
// esta la friccion) va ANTES del prethink del juego. O sea que para devolver la que
// se tenia en el aire hay que acordarse de ella y reponerla despues de la
// friccion, que es justo lo que hace el prethink.
//
// El instante del salto se decide en el prethink con FL_ONGROUND, que ahi lleva un
// frame de retraso (los flags se actualizan despues de mover). Un frame no se nota.
//
// El tope de 640 esta en direkt_limita_velocidad: sin tope el jugador va sumando
// velocidad en cada salto y en un rato el mapa deja de tener sentido.
void()	direkt_bunny_hop;

float	direkt_bhop_velocidad;	// la horizontal maxima del vuelo actual
float	direkt_bhop_aviso;

// La DIRECCION del vuelo, aparte de la velocidad.
//
// Hace falta por esto: al aterrizar, la friccion del motor deja la velocidad
// horizontal a cero ANTES de que llegue el prethink (SV_ClientThink va antes), asi
// que en el frame del salto no hay ninguna direccion de la que tirar. Si se
// repusiese la velocidad en la de ese momento, no se repone nada y el jugador se
// queda saltando derecho. La direccion se guarda aqui, en el aire, que es cuando
// todavia la hay.
vector	direkt_bhop_direccion;

// La maxima del vuelo, que va al informe de movimiento: es como se comprueba desde
// fuera que el bunny hop conserva la velocidad y no solo lo parece.
float	direkt_bhop_maxima;

// Se mide en el aire, tanto en el prethink como en el postthink. En el postthink la
// velocidad ya es la buena, que es la de despues de moverse.
void()	direkt_bhop_mide =
{
	local vector suelo;
	local float rapidez;

	suelo = self.velocity;
	suelo_z = 0;
	rapidez = vlen(suelo);

	// Sin velocidad horizontal no hay nada que guardar, y la direccion se divide
	// por la rapidez mas abajo.
	if (rapidez < 1)
		return;

	if (rapidez > direkt_bhop_velocidad)
	{
		direkt_bhop_velocidad = rapidez;
		direkt_bhop_direccion = suelo * (1 / rapidez);
	}

	if (rapidez > direkt_bhop_maxima)
		direkt_bhop_maxima = rapidez;
};

// El salto encadenado, en el prethink.
void() direkt_bunny_hop =
{
	local vector suelo;
	local float rapidez;

	// Sin Shift no hay bunny hop: el salto de espacio es el de siempre.
	if (!direkt_pulsada_mod())
	{
		direkt_bhop_velocidad = 0;
		direkt_bhop_aviso = 0;
		return;
	}

	// En el aire solo se mide.
	if (!direkt_piso())
	{
		direkt_bhop_mide();
		return;
	}

	// En el suelo, sin saltar, no pasa nada.
	if (!self.button2)
	{
		direkt_bhop_velocidad = 0;
		return;
	}

	// Toca saltar. OJO: aqui NO se llama a direkt_salta, porque esa mira el flanco
	// del boton para no saltar dos veces con el mismo pulsacion. En bunny hop el
	// boton esta pulsado SIEMPRE, asi que con el flanco solo saltaria una vez y
	// luego no mas: el salto se pone a mano.
	rapidez = direkt_bhop_velocidad;

	if (rapidez > DIREKT_VELOCIDAD_MAXIMA)
		rapidez = DIREKT_VELOCIDAD_MAXIMA;

	// Y se repone sobre la direccion del vuelo, no sobre la velocidad de ahora,
	// que al aterrizar es cero.
	if (rapidez > 1)
	{
		self.velocity_x = direkt_vx(direkt_bhop_direccion) * rapidez;
		self.velocity_y = direkt_vy(direkt_bhop_direccion) * rapidez;
	}

	self.velocity_z = DIREKT_SALTO_VELOCIDAD;
	direkt_salto_alto();

	// Para que el salto normal no lo repita en el mismo frame.
	direkt_salto_boton = 1;

	// A que velocidad se encadena cada salto, en tramos. El banco de pruebas
	// comprueba que hay saltos "encadenado rapido": si no los hay, el bunny hop
	// esta perdiendo la velocidad en cada suelo y en realidad no lo es.
	//
	// Los tramos estan medidos: se anda a 320 (sv_maxspeed) y con Shift se llega a
	// unos 450, asi que por encima de 400 hay momentum de verdad.
	if (rapidez > 400)
		localcmd(" echo DIREKT: bunny hop encadenado rapido");
	else if (rapidez > 250)
		localcmd(" echo DIREKT: bunny hop encadenado normal");
	else if (rapidez > 1)
		localcmd(" echo DIREKT: bunny hop encadenado lento");
	else
		localcmd(" echo DIREKT: bunny hop sin momentum");

	if (!direkt_bhop_aviso)
	{
		direkt_bhop_aviso = 1;
		localcmd(" echo DIREKT: bunny hop");
	}
};
