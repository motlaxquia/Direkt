// Direkt -- lo que el jugador necesita por encima de la fisica del motor.
//
// GPL-2.0, ver LICENSE en la raiz del repositorio.
//
// client.qc explica por que aqui no hay fisica. Este fichero contiene lo que
// si es codigo de juego: el control de disparo, el dano, la muerte, la
// reaparicion y el informe de movimiento que usa el smoke test.

void(entity victima)	direkt_muerte_jugador;
void()	direkt_jugador_cae;
void()	direkt_jugador_reaparece;
void()	direkt_informa_movimiento;
void()	direkt_muerte_ente;
void()	direkt_test_arranca;
void()	direkt_test_comprueba;
void(entity e) direkt_test_volar;
void()	direkt_selftest_paso;
void()	direkt_test_arma;
void()	direkt_reliquia_pasar;
void()	direkt_arma_disparar;
void()	direkt_impulso;
void()	direkt_estructura_test;
void(entity jugador)	direkt_arma_coger_ammo;
void(entity objetivo, entity agresor, float dano) direkt_danio;
void(entity jugador, float bit) direkt_arma_anadir;
void()	direkt_agacha;
void()	direkt_agacha_anda_lento;
void()	direkt_test_agacha;
void()	direkt_test_suelo;
void()	direkt_test_muerte;
void(entity victima)	direkt_gibs;
void()	direkt_gib_quita;
void()	direkt_jugador_reintentar;
void()	direkt_teclas;
void()	direkt_avisa_teclas;
void()	direkt_avisa_piso;
// Impulso extra por frame mientras se mantiene el salto subiendo. Con 16 el salto
// queda claramente mas alto; con 40 el motor se atasca.
#define DIREKT_SALTO_EXTRA 16
#define DIREKT_SALTO_TOPE  640

void()	direkt_salto_alto;

// El empuje se corta en cuanto el jugador deja de subir, para que al caer no se
// note.
void() direkt_salto_alto =
{
	if (!self.button2 || self.velocity_z <= 0)
		return;

	self.velocity_z = self.velocity_z + DIREKT_SALTO_EXTRA;
	if (self.velocity_z > DIREKT_SALTO_TOPE)
		self.velocity_z = DIREKT_SALTO_TOPE;
};
void()	direkt_test_muerte_pelea;

// Cuantos objetos se comprueban cuando se pide el selftest con el impulso 9.
#define DIREKT_TEST_OBJETOS 50

// ------------------------------------------------------------------ agacharse
// El motor no tiene boton de agacharse: quito in_duck de la lista de botones y
// solo manda el de disparo y el de salto. Tampoco reenvia al juego los comandos
// que teclea el cliente, asi que un "+duck" no llega a ningun sitio, y un cvar
// nuevo tampoco sirve: en Ironwail los cvars los declara el motor en C y desde
// la consola no se puede crear uno, de modo que cvar() solo lee los del motor.
//
// Lo que queda es el impulso, que es lo unico que el cliente envia de forma
// fiable y que el juego ya usa para todo. Se eligieron numeros altos para no
// chocar con los del selector de armas. Son dos impulsos y no uno de alternar
// porque una tecla manda su comando al pulsar Y al soltar, asi que un "alterna"
// se des-haria solo; en cambio "ponte agachado" dicho dos veces es lo mismo.
//
//   bind F4 "impulse 20"     agacharse
//   bind F5 "impulse 21"     levantarse
#define DIREKT_IMPULSO_AGACHAR   20
#define DIREKT_IMPULSO_LEVANTAR  21

// Las dos cajas son la de pie y la agachada. Los pies se quedan en el mismo
// sitio en las dos (mins_z = -24) para no hundirse ni flotar al cambiar. La
// proporcion es la de siempre: agachado el cuerpo ocupa la mitad de alto.
vector	DIREKT_ALTO_MINS	= '-16 -16 -24';
vector	DIREKT_ALTO_MAXS	= '16 16 32';
vector	DIREKT_ALTO_OJO	= '0 0 24';
vector	DIREKT_BAJO_MINS	= '-16 -16 -24';
vector	DIREKT_BAJO_MAXS	= '16 16 4';
vector	DIREKT_BAJO_OJO	= '0 0 4';

// Agachado se camina despacio. OJO: el motor limita la velocidad con el cvar
// sv_maxspeed y no con self.maxspeed, asi que desde aqui no se puede cambiar
// la aceleracion. Lo que se hace es recortar la velocidad en el postthink.
#define DIREKT_AGACHADO_VELOCIDAD 100

// Lo que el jugador ha pedido. Va en global y no en un campo de la entidad
// porque los campos libres se acabaron al llenar los de las puertas y las
// plataformas, y porque el motor pone a cero los que usa el.
float	direkt_agachado;

vector	direkt_origen_inicial;
float	direkt_tiempo_informe;
// Momento en que se llama ClientKill, para no reaparecer dos veces.
float	direkt_tiempo_muerte;
// Contador del selftest de objetos: cuantas comprobaciones le quedan, y que
// clase de objeto se esta probando ahora (las cadenas si pueden ser globales).
float	direkt_test_pendientes;
string	direkt_test_clase;

// Instantanea del jugador para el selftest. Van en globales y no en campos de
// la entidad porque el motor usa dmg_take y dmg_save para el dano real, y los
// pone a cero en cuanto el jugador recibe cualquier cosa.
float	direkt_test_vida;
float	direkt_test_armadura;
float	direkt_test_inventario;
float	direkt_test_municion;

// Paso de la prueba de agachado.
float	direkt_test_agacha_paso;

// ------------------------------------------------------------------ suelo
// Sonda de apoyo: el motor no expone FL_ONGROUND a QuakeC, asi que la unica
// forma de saber si el jugador se sostiene es mirar si su origen deja de bajar.
// Se guarda la altura al arrancar y se compara un instante despues.
float	direkt_test_suelo_paso;
float	direkt_test_suelo_z0;
float	direkt_test_suelo_dz;
float	direkt_test_suelo_z;

// Contador de la prueba de "un golpe mata", del impulso 24. Va aqui con las
// demas porque QuakeC no admite usar una variable global antes de declararla.
// El jugador, el proyectil y el testigo de la prueba del golpe mortal. El
// testigo se pone desde el proyectil y lo lee el manejador de muerte.
entity	direkt_test_muerte_jugador;
entity	direkt_test_muerte_arma;
float	direkt_test_muerte_armado;

// Cuantos pedazos y heads se han soltado en la ultima muerte. Los cuentan
// direkt_gibs y direkt_cabeza, y los lee el manejador de muerte, que si es
// codigo del cliente y por eso puede escribir en el log (desde un proyectil no:
// ni dprint ni localcmd se ven de ahi).
float	direkt_gibs_soltados;
float	direkt_cabezas_soltadas;

// Cursor para no volver a mirar el mismo objeto. Sin esto, find() siempre
// devuelve el primer objeto de cada clase y la prueba se queda enganchada
// en el mismo arma una y otra vez.
entity	direkt_test_cursor;
float	direkt_test_indice;
string()	direkt_test_siguiente_clase;

// Odometro: distancia TOTAL recorrida, no distancia recta al origen. Con
// --turn el jugador anda en circulo y el desplazamiento neto se queda corto
// aunque se haya movido todo el rato.
float	direkt_recorrido;

// ------------------------------------------------------------------ entrada
void() direkt_jugador_entra =
{
	direkt_origen_inicial = self.origin;
	direkt_tiempo_informe = time + 2;
	direkt_recorrido = 0;
	direkt_tiempo_muerte = 0;
	localcmd(" echo DIREKT: jugador en el mundo");

	direkt_arma_coger_ammo(self);
	localcmd(" echo DIREKT: empieza con el hacha");
};

// ------------------------------------------------------------------ por frame
// El motor ya ha resuelto la fisica del frame cuando esto corre. Aqui solo se
// toca lo que es de juego.
void() direkt_prethink_jugador =
{
	// La caja de colision tiene que estar puesta ANTES de que el motor mueva
	// al jugador, asi que el agachado va aqui y no en el postthink.
	direkt_agacha();

	// Las teclas del parkour llegan como impulso, y el impulso se vacia en
	// cuanto se mira, asi que se leen primero de todo.
	direkt_teclas();
	direkt_avisa_teclas();
	direkt_avisa_piso();

	// Si esta muerto no se hace nada hasta que le toque reaparecer.
	if (self.deadflag)
		return;

	// El impulso 9 no cambia de arma: pide la comprobacion de objetos. Llega
	// aqui porque el motor vacia el impulso en cada frame.
	if (self.impulse == 9)
	{
		direkt_test_pendientes = DIREKT_TEST_OBJETOS;
	direkt_test_indice = 0;
	direkt_test_cursor = world;
		self.impulse = 0;
		self.think = direkt_test_arranca;
		self.nextthink = time + 0.3;
	}
	// El 10 pide la comprobacion de puertas, botones y plataformas.
	else if (self.impulse == 10)
	{
		self.impulse = 0;
		direkt_estructura_test();
	}
	// El 20 y el 21 son el agachado. Se resuelven aqui y no en direkt_impulso
	// para que todo lo del agachado viva en este fichero.
	else if (self.impulse == DIREKT_IMPULSO_AGACHAR)
	{
		direkt_agachado = 1;
		self.impulse = 0;
	}
	else if (self.impulse == DIREKT_IMPULSO_LEVANTAR)
	{
		direkt_agachado = 0;
		self.impulse = 0;
	}
	// El 22 es la prueba de que el agachado se pone y se quita.
	else if (self.impulse == 22)
	{
		self.impulse = 0;
		direkt_test_agacha_paso = 0;
		self.think = direkt_test_agacha;
		self.nextthink = time + 0.1;
	}
	// El 23 pregunta si el jugador se apoya en algo. Es la sonda que usa el
	// banco de pruebas del compilador de mapas: si el .bsp trae los clipnodes
	// mal, el jugador atraviesa el suelo y aqui se ve caer.
	else if (self.impulse == 23)
	{
		self.impulse = 0;
		direkt_test_suelo_paso = 0;
		direkt_test_suelo_z0 = self.origin_z;
		self.think = direkt_test_suelo;
		self.nextthink = time + 0.5;
	}
	// El 26 es el Enter que se enlaza al morir: lleva a reintentar. Se mira
	// antes que el resto porque solo tiene sentido muerto, y no vale nada en
	// vida normal.
	else if (self.impulse == 26)
	{
		self.impulse = 0;
		if (self.deadflag)
			direkt_jugador_reintentar();
	}
	// El 24 pregunta si un solo golpe mata al jugador, que es la regla del
	// juego. Se comprueba de verdad, con el camino de dano de verdad, y no
	// mirando el numero: si un dia algo empieza a dejar vivo al jugador con
	// vida 1, esta linea avisa.
	else if (self.impulse == 24)
	{
		self.impulse = 0;
		self.think = direkt_test_muerte;
		self.nextthink = time + 0.1;
	}
	else if (self.impulse)
	{
		direkt_impulso();
	}

	// El salto alto, solo en vida normal: muerto no se salta.
	if (!self.deadflag)
		direkt_salto_alto();

	// Disparar.
	if (self.button0)
		direkt_arma_disparar();

	// Las reliquias caducan solas. El think es el mismo que usa la animacion
	// del arma, asi que solo se comprueba cuando el arma esta quieta; si el
	// arma se dispara, su animacion pisa el think y la comprobacion se vuelve
	// a armar en el frame siguiente.
	if (self.items & (IT_INVISIBILITY | IT_INVULNERABILITY | IT_SUIT | IT_QUAD))
	{
		if (self.weaponframe == 0 && time >= self.attack_finished)
		{
			self.think = direkt_reliquia_pasar;
			self.nextthink = time + 1;
			direkt_reliquia_pasar();
		}
	}
};

void() direkt_postthink_jugador =
{
	direkt_agacha_anda_lento();
	direkt_recorrido = direkt_recorrido + vlen(self.velocity) * frametime;
	direkt_informa_movimiento();
};

// ------------------------------------------------------------------ agacharse
// Pone la caja y el ojo segun toque. Va en el prethink porque la caja se usa en
// el moviento del frame, y porque al levantarse hay que comprobar que hay
// sitio antes de ocupar el sitio.
void() direkt_agacha =
{
	local vector ojos;

	// El jugador pide agacharse con el impulso, no con un cvar.
	if (!direkt_agachado)
	{
		// Antes de levantarse se comprueba que la cabeza no.topa. Es el caso
		// util de agacharse: meterse en un hueco y no poder salir andando. Si
		// no cabe, se sigue agachado y no se avisa, como en el original.
		//
		// traceline solo comprueba un punto, no la caja entera, asi que se
		// lanza en el centro y en los dos lados: con el centro libre y un lado
		// tapado, levantarse meteria al jugador en el techo.
		ojos = self.origin + '0 0 24';
		traceline(ojos, ojos + '0 0 32', TRUE, self);
		if (trace_fraction < 1)
			return;
		ojos = self.origin + '16 0 24';
		traceline(ojos, ojos + '0 0 32', TRUE, self);
		if (trace_fraction < 1)
			return;
		ojos = self.origin + '-16 0 24';
		traceline(ojos, ojos + '0 0 32', TRUE, self);
		if (trace_fraction < 1)
			return;

		// Ya estaba de pie: no se toca nada, que setsize enlaza la entidad.
		if (self.maxs == DIREKT_ALTO_MAXS)
			return;

		setsize(self, DIREKT_ALTO_MINS, DIREKT_ALTO_MAXS);
		self.view_ofs = DIREKT_ALTO_OJO;
		return;
	}

	// Ya estaba agachado.
	if (self.maxs == DIREKT_BAJO_MAXS)
		return;

	// Encoger la caja nunca mete al jugador dentro de un muro, asi que aqui no
	// hace falta comprobar nada.
	setsize(self, DIREKT_BAJO_MINS, DIREKT_BAJO_MAXS);
	self.view_ofs = DIREKT_BAJO_OJO;

	// Agachado no se sube escalones: si no, el motor usa el borde del pie mas
	// bajo y el jugador trepa por las paredes agachado.
	self.flags = self.flags - (self.flags & FL_ONGROUND);
};

// Recorta la velocidad en horizontal mientras se este agachado.
//
// El motor calcula la velocidad a partir de forwardmove y la limita con el cvar
// sv_maxspeed, que es global del servidor: no se puede bajar solo para este
// jugador. Como el postthink corre el ultimo, recortar aqui manda. No sale un
// frenazo porque el motor vuelve a acelerar desde forwardmove en cada frame:
// entre frame y frame el jugador se queda a la velocidad de agachado, pero le
// cuesta mas volver a correr.
void() direkt_agacha_anda_lento =
{
	local vector suelo;
	local float rapidez;

	if (self.deadflag)
		return;
	if (self.maxs != DIREKT_BAJO_MAXS)
		return;

	// La componente vertical no se toca: caer y saltar van igual.
	suelo = self.velocity;
	suelo_z = 0;
	rapidez = vlen(suelo);

	if (rapidez <= DIREKT_AGACHADO_VELOCIDAD)
		return;

	self.velocity_x = suelo_x * DIREKT_AGACHADO_VELOCIDAD / rapidez;
	self.velocity_y = suelo_y * DIREKT_AGACHADO_VELOCIDAD / rapidez;
};

// ------------------------------------------------------------------ correr y saltar
//
// Shift es "+speed", que es una tecla que YA traen los dos motores: en
// cl_input.c esta IN_SpeedDown y IN_SpeedUp. O sea que no hay que tocar el motor,
// solo enlazar el Shift a "+speed" una vez.
//
// El salto es mas dificil, porque la velocidad del salto la pone el motor y no
// hay ningun cvar para ella. Lo que se hace es empujar hacia arriba mientras la
// tecla de salto siga pulsada y el jugador vaya subiendo: el motor da el impulso
// del salto y nosotros lo vamos alargando. Se parece a como se siente saltar mas
// alto en los juegos de parkour, y no toca nada del motor.
//
// El empuje se corta en cuanto el jugador deja de subir, para que al caer no se
// note. Y se limita a un tope: si se dejara sin limite, Keeping presionado el
// salto acabaria hurtando el motor entero.


// ------------------------------------------------------------------ salud
// Aplica dano. Se llama desde las armas, de los proyectiles y de los gatillos.
void(entity objetivo, entity agresor, float dano) direkt_danio =
{
	local float guardado;

	if (!objetivo)
		return;
	if (!objetivo.takedamage)
		return;
	if (objetivo.health <= 0)
		return;
	if (objetivo == self)
		return;
	if (objetivo == world)
		return;

	// Con la reliquia de invulnerabilidad no entra nada de dano.
	if (objetivo.classname == "player")
	{
		if (objetivo.items & IT_INVULNERABILITY)
			return;
		if (objetivo.flags & FL_GODMODE)
			return;
	}

	// El dano cuadruplo de la reliquia multiplica lo que entra.
	if (objetivo.classname == "player" && objetivo.items & IT_QUAD)
		dano = dano * 4;

	// La armadura se come una parte y se gasta por el camino.
	guardado = objetivo.armorvalue * objetivo.armortype;
	if (guardado > dano)
	{
		guardado = dano;
		dano = 0;
	}
	else
	{
		objetivo.armorvalue = objetivo.armorvalue - guardado / objetivo.armortype;
		dano = dano - guardado;
	}

	objetivo.health = objetivo.health - dano;
	objetivo.dmg_inflictor = agresor;
	objetivo.enemy = agresor;
	// th_die (puertas y botones disparables) lo lee para saber quien los tiro.
	damage_attacker = agresor;

	if (objetivo.health <= 0)
	{
		if (objetivo.classname == "player")
			direkt_muerte_jugador(objetivo);
		else if (objetivo.th_die)
		{
			// Las puertas y los botones no mueren: se abren. Por eso van antes
			// que el borrado generico.
			direkt_llama_muerte(objetivo);
		}
		else
		{
			objetivo.takedamage = DAMAGE_NO;
			objetivo.think = direkt_muerte_ente;
			objetivo.nextthink = time + 0.1;
		}
		return;
	}

	// Un golpe recibido, aunque no matase.
	if (objetivo.classname == "player")
		sound(objetivo, CHAN_BODY, "player/pain1.wav", 1, ATTN_NORM);
	else
		sound(objetivo, CHAN_BODY, "player/hit2.wav", 1, ATTN_NORM);
};

// Muere un ente del mapa al recibir el golpe.
void() direkt_muerte_ente =
{
	// Sin criaturas en estos mapas, pero un golpe de exploracion puede dar
	// con un mueble dinamico: se sube y desaparece.
	self.solid = SOLID_NOT;
	self.takedamage = DAMAGE_NO;
	self.movetype = MOVETYPE_TOSS;
	self.velocity_z = 100;
	self.frame = 0;
	remove(self);
};

// ------------------------------------------------------------------ muerte
//
// Cuando el jugador muere:
//
//   * Explota en pedazos, como los enemigos cuando mueren de un golpe.
//   * Se apagan el cuerpo y el arma.
//   * El cadaver cae y se queda. La camara lo sigue por la cabeza, sola.
//   * Abajo sale un aviso para reintentar con Enter.
//
// Y hay un detalle del motor que encaja con esto: SV_ClientThink (FTE) y su
// equivalente en Quakespasm hacen "if (health <= 0) return", o sea que un
// jugador con la vida a cero no se mueve por si mismo. Por eso el cadaver se
// limita a caer: es el motor quien lleva la camara detras de la cabeza.

void(entity victima) direkt_gibs =
{
	local entity g;
	local float i;
	local float ang;

	i = 0;
	direkt_gibs_soltados = 0;
	direkt_cabezas_soltadas = 0;
	while (i < 7)
	{
		direkt_gibs_soltados = direkt_gibs_soltados + 1;
		g = spawn();
		g.classname = "direkt_gib";
		g.solid = SOLID_NOT;
		g.movetype = MOVETYPE_TOSS;
		g.model = "progs/gib1.mdl";
		if (i & 1)
			g.model = "progs/gib2.mdl";
		if (i > 4)
			g.model = "progs/gib3.mdl";
		setmodel(g, g.model);
		setsize(g, VEC_ORIGIN, VEC_ORIGIN);

		// Cada pedazo sale para un lado. Las direcciones van escritas una a una
		// porque en QuakeC no hay seno ni coseno, ni forma de tener un array
		// global con valores de partida.
		ang = 150 + i * 22;
		if (i == 0) { g.velocity_x = ang; g.velocity_y = 0; }
		else if (i == 1) { g.velocity_x = ang * 0.7; g.velocity_y = ang * 0.7; }
		else if (i == 2) { g.velocity_x = -ang * 0.7; g.velocity_y = ang * 0.7; }
		else if (i == 3) { g.velocity_x = -ang; g.velocity_y = 0; }
		else if (i == 4) { g.velocity_x = -ang * 0.7; g.velocity_y = -ang * 0.7; }
		else if (i == 5) { g.velocity_x = ang * 0.7; g.velocity_y = -ang * 0.7; }
		else { g.velocity_x = 0; g.velocity_y = 0; }
		g.velocity_z = 120 + i * 26;

		g.angles = victima.angles;
		g.avelocity_x = 300 - i * 20;
		g.avelocity_y = 240 - i * 15;
		g.think = direkt_gib_quita;
		g.nextthink = time + 4 + i * 0.2;
		i = i + 1;
	}

	sound(victima, CHAN_BODY, "player/udeath.wav", 1, ATTN_NORM);
	sound(victima, CHAN_VOICE, "player/gib.wav", 1, ATTN_NORM);
}

// Un pedazo se va a los cuatro segundos. Los enemigos kbudget tienen thought, y
// los nuestros igual.
void() direkt_gib_quita = { remove(self); };

// La cabeza, que es nuestro modelo propio. Se lanza mas lejos y mas alta que
// los pedazos, que es como se nota que es la cabeza y no un trozo mas.
void(entity victima) direkt_cabeza =
{
	local entity c;

	direkt_cabezas_soltadas = direkt_cabezas_soltadas + 1;
	c = spawn();
	c.classname = "direkt_cabeza";
	c.solid = SOLID_NOT;
	c.movetype = MOVETYPE_TOSS;
	c.model = "progs/gibhead.mdl";
	setmodel(c, c.model);
	setsize(c, VEC_ORIGIN, VEC_ORIGIN);

	c.origin = victima.origin;
	c.origin_z = victima.origin_z + 8;
	c.velocity_x = victima.velocity_x + 90;
	c.velocity_y = victima.velocity_y - 90;
	c.velocity_z = 190;
	c.angles = victima.angles;
	c.avelocity_x = 260;
	c.avelocity_y = 190;

	// La cabeza lleva su sonido propio, que es el que hace "plaf".
	sound(c, CHAN_BODY, "player/gib.wav", 0.7, ATTN_NORM);

	c.think = direkt_gib_quita;
	c.nextthink = time + 6;
}

// de por si. La alternativa era poner el modelo del jugador a media
// transparencia, pero el campo alpha no existe en el lado de QuakeC: es una
// extension del motor que no se puede tocar desde el juego, y anadirla obliga a
// cambiar la tabla de campos que comparten los dos motores. Con sprites se ve
// translucido de verdad y sin tocar nada del motor.
void(entity victima) direkt_muerte_jugador =
{
	if (victima.deadflag)
		return;

	if (direkt_test_muerte_armado)
	{
		localcmd(" echo DIREKT: un golpe mata al jugador\n");
		direkt_test_muerte_armado = 0;
	}

	// Los pedazos y la cabeza salen antes de tocar nada del jugador, que si no
	// se los lleva el cambio de estado de despues.
	direkt_gibs(victima);
	direkt_cabeza(victima);

	// Que se haya soltado de verdad. La sangre no la pone el juego: sale sola,
	// porque los modelos de pedazo y el nuestro llevan EF_GIB y el motor suelta
	// el rastro por su cuenta (cl_main.c). Lo que si depende de nosotros es que
	// las entidades existan y se muevan, y eso es lo que se comprueba.
	if (direkt_gibs_soltados != 7 || direkt_cabezas_soltadas != 1)
		localcmd(" echo DIREKT: la muerte no ha soltado 7 pedazos y 1 cabeza\n");

	victima.deadflag = DEAD_DYING;
	victima.takedamage = DAMAGE_NO;
	victima.frame = 0;

	// El arma se apaga, pero el cuerpo se queda: lo que se ve al morir es el
	// cadaver cayendo, que es justo lo que sigue la camara.
	victima.weaponmodel = "";
	victima.weaponframe = 0;

	// El balanceo a cero. Esta es la razon de que la pantalla se viera ladeada al
	// morir, y no es cosa del motor ni de un cvar:
	//
	// SV_ClientThink (sv_user.c) calcula angles[ROLL] con la velocidad lateral
	// del jugador, pero hace "if (health <= 0) return" ANTES de calcularlo. O
	// sea que al morir no vuelve a tocar ese angulo y se queda con el valor que
	// tenia en el ultimo frame en vida. Y en juego local la camara ES la entidad
	// del jugador, con lo que ese balanceo congelado se ve en la pantalla tal
	// cual, para siempre.
	//
	// Ponerlo a cero aqui lo deja en el motor, sin tocarlo: el motor lo deja
	// como esta en cuanto se pone a cero.
	// No se puede hacer "angles[2] = 0": fteqcc lo lee como asignacion a un
	// array entero. Se pone el vector entero a cero, que es lo mismo aqui
	// porque el balanceo es el eje Z y al morir el cuerpo no tiene por que mirar
	// a ningun sitio en concreto.
	victima.angles = '0 0 0';

	victima.health = 0;
	victima.max_health = DIREKT_MAX_HEALTH;
	victima.armorvalue = 0;
	victima.items = 0;
	victima.currentammo = 0;

	// El cuerpo cae y se queda tirado. Con la vida a cero el motor no lo mueve
	// (SV_ClientThink: "if (health <= 0) return"), con lo que basta con dejar que
	// caiga por gravedad y se quede quieto. La camara lo sigue sola, porque la
	// vista va enganchada a la cabeza del jugador.
	victima.movetype = MOVETYPE_TOSS;
	victima.gravity = 1;
	victima.velocity_z = 100;
	victima.think = direkt_jugador_cae;
	victima.nextthink = time + 0.5;

	// El ENTER para reintentar se enlaza aqui. Esto SI funciona: "bind" es un
	// comando normal y el motor lo ejecuta tal cual.
	stuffcmd(victima, "bind KP_ENTER \"impulse 26\"");
	stuffcmd(victima, "bind RETURN \"impulse 26\"");

	// OJO, PENDIENTE: el aviso de "moriste" abajo todavia no se pone. La parte de
	// dibujarlo esta HECHA y comprobada (cvar scr_msgline en el motor, con la
	// vista ya sin la franja gris), pero el Camino para ponerlo desde aqui no
	// funciona:
	//
	//   * stuffcmd(victima, "scr_msgline \"texto con espacios\"") llega al
	//     motor sin las comillas, con lo que el cvar se queda con la primera
	//     palabra y el resto se va como comandos sueltos. Se vio en el log.
	//   * Con comillas tampoco: el cvar se queda sin cambiar.
	//
	// Ni en Ironwail ni en Quakespasm hay forma de pasar un texto con espacios
	// desde QuakeC. Lo que queda por probar es mandar el texto partido en
	// varios "scr_msgline" con un separador, o un comando del motor que lo lea de
	// otro sitio. Hasta entonces el motor lo dibuja pero el juego no lo llama.

	localcmd(" echo DIREKT: el jugador muere");
}

// El cadaver toca el suelo y se queda. No hay respawn automatico: el jugador
// reintenta con Enter, que es el impulso 26.
void() direkt_jugador_cae =
{
	self.deadflag = DEAD_DEAD;
	self.movetype = MOVETYPE_NONE;
	self.velocity = VEC_ORIGIN;
	self.think = direkt_nada;
	self.nextthink = 0;
}

// Reintentar: lo mismo que reaparecer, pero porque el jugador ha pedido.
void() direkt_jugador_reintentar =
{
	if (!self.deadflag)
		return;

	self.think = direkt_nada;
	self.nextthink = 0;
	PutClientInServer();
}

// La prueba del golpe mortal.
//
// Va en un proyectil y no en el jugador por dos razones:
//
//   * direkt_danio rechaza que una entidad se hiera a si misma, asi que desde el
//     propio jugador el golpe se saldria antes de tocar la vida y la prueba no
//     mediria nada. Con un proyectil se recorre el camino de verdad, el mismo que
//     usan las armas y las trampas.
//   * La comprobacion se hace en el MISMO frame que el golpe, dentro del
//     proyectil. Si se mirara despues, al jugador muerto lo habria cambiado la
//     animacion de caida, que pisa el think.
//
// Que un golpe mate es una de las cosas que mas se tocan, asi que tiene su
// linea en el log y su comprobacion en el banco de pruebas.
void() direkt_test_muerte_pelea =
{
	direkt_test_muerte_armado = 1;
	direkt_danio(direkt_test_muerte_jugador, self, 15);
	remove(self);
};

// Paso 1: que el punto de partida sea el del juego. Una vida, sin armadura y sin
// reliquia que esquive el dano. Si algo de esto se cumpliera, el jugador seria
// inmortal y de nada serviria mirar como se aplica el golpe.
void() direkt_test_muerte =
{
	direkt_test_muerte_armado = 0;

	if (self.max_health != DIREKT_MAX_HEALTH)
		localcmd(" echo DIREKT: el jugador no nace con una vida\n");
	if (self.armorvalue > 0)
		localcmd(" echo DIREKT: el jugador nace con armadura\n");
	if (self.items & IT_INVULNERABILITY)
		localcmd(" echo DIREKT: el jugador nace invulnerable\n");

	direkt_test_muerte_jugador = self;
	direkt_test_muerte_arma = spawn();
	direkt_test_muerte_arma.classname = "direkt_test_punio";
	direkt_test_muerte_arma.solid = SOLID_NOT;
	direkt_test_muerte_arma.movetype = MOVETYPE_NONE;

	// spawn() deja la entidad en el origen de coordenadas, y en un mapa eso
	// cae fuera del mundo. El motor solo mete en su lista de think las entidades
	// que estan dentro, con lo que sin esto el proyectil se queda sin ejecutar
	// y la prueba no dice nada. Se pone donde esta el jugador, que si que esta.
	setorigin(direkt_test_muerte_arma, self.origin);
	direkt_test_muerte_arma.think = direkt_test_muerte_pelea;
	direkt_test_muerte_arma.nextthink = time + 0.05;
};

// ================================================================= selftest
// Comprobacion de que los objetos hacen algo. Se pide con el impulso 9 desde el
// cfg del smoke test: el jugador se teletransporta encima de un objeto, y al
// frame siguiente se comprueba que ha cambiado algo. El motor se encarga del
// contacto, asi que lo que se prueba es el camino real del juego.
void() direkt_test_arranca =
{
	if (direkt_test_pendientes < 1)
		return;
	self.think = direkt_nada;
	self.nextthink = 0;
	direkt_selftest_paso();
};

// Los objetos del mapa, por orden. Se prueban los que existan.
float() direkt_test_siguiente =
{
	local entity e;
	local string clase;

	// Recorre todos los objetos del mapa, clase por clase, sin repetir ninguno.
	// El cursor va encadenando find: al terminar con una clase pasa a la
	// siguiente. Si ya se han probado todos, devuelve 0.
	//
	// Las armas van primero a proposito: la municion que no se puede usar se
	// queda en el suelo, y si se probara antes el mismo find devolveria la
	// misma caja una y otra vez.
	clase = direkt_test_siguiente_clase();

	while (clase != "")
	{
		if (direkt_test_cursor)
			e = find(direkt_test_cursor, classname, clase);
		else
			e = find(world, classname, clase);

		if (e)
		{
			direkt_test_cursor = e;
			direkt_test_volar(e);
			return 1;
		}

		// Clase agotada: se pasa a la siguiente.
		direkt_test_cursor = world;
		direkt_test_indice = direkt_test_indice + 1;
		clase = direkt_test_siguiente_clase();
	}

	direkt_test_cursor = world;
	return 0;
};

// Devuelve la siguiente clase en la lista de clases a probar. La lista esta
// en la cadena "clase1 clase2 clase3" separada por espacios.
string() direkt_test_siguiente_clase =
{
	// Se recorre una lista fija de clases en orden, avanzando con un indice
	// global. Se usa un array simulado con constantes.
	if (direkt_test_indice == 0) return "weapon_supershotgun";
	if (direkt_test_indice == 1) return "weapon_rocketlauncher";
	if (direkt_test_indice == 2) return "weapon_supernailgun";
	if (direkt_test_indice == 3) return "weapon_grenadelauncher";
	if (direkt_test_indice == 4) return "weapon_lightning";
	if (direkt_test_indice == 5) return "item_shells";
	if (direkt_test_indice == 6) return "item_spikes";
	if (direkt_test_indice == 7) return "item_rockets";
	if (direkt_test_indice == 8) return "item_cells";
	if (direkt_test_indice == 9) return "item_health";
	if (direkt_test_indice == 10) return "item_armor1";
	if (direkt_test_indice == 11) return "item_armorInv";
	if (direkt_test_indice == 12) return "item_armor2";
	if (direkt_test_indice == 13) return "item_key1";
	if (direkt_test_indice == 14) return "item_artifact_super_damage";
	return "";
};

// Se anota de que clase era el objeto y se coloca el objeto encima del
// jugador, no al revés.
//
// Mover al jugador encima del objeto no vale: los objetos de estos mapas estan
// metidos en huecos y repuestos, el jugador aparece dentro del muro, el motor
// lo saca de un empujon y para cuando hay que mirar los contactos ya no esta
// sobre el objeto. Trayendo el objeto al jugador el contacto llega seguro.
void(entity e) direkt_test_volar =
{
	direkt_test_clase = e.classname;
	e.velocity = '0 0 0';
	setorigin(e, self.origin + '0 0 8');
};

// Dice que clase de objeto se acaba de probar.
void() direkt_test_tipo =
{
	if (direkt_test_clase == "item_health")
		localcmd(" echo DIREKT: prueba botiquin");
	else if (direkt_test_clase == "item_armor1")
		localcmd(" echo DIREKT: prueba armadura verde");
	else if (direkt_test_clase == "item_armor2")
		localcmd(" echo DIREKT: prueba armadura amarilla");
	else if (direkt_test_clase == "item_armorInv")
		localcmd(" echo DIREKT: prueba armadura roja");
	else if (direkt_test_clase == "item_shells")
		localcmd(" echo DIREKT: prueba perdigones");
	else if (direkt_test_clase == "item_spikes")
		localcmd(" echo DIREKT: prueba clavos");
	else if (direkt_test_clase == "item_rockets")
		localcmd(" echo DIREKT: prueba cohetes");
	else if (direkt_test_clase == "item_cells")
		localcmd(" echo DIREKT: prueba celdas");
	else if (direkt_test_clase == "weapon_supershotgun")
		localcmd(" echo DIREKT: prueba superescopeta");
	else if (direkt_test_clase == "weapon_rocketlauncher")
		localcmd(" echo DIREKT: prueba lanzacohetes");
	else if (direkt_test_clase == "weapon_supernailgun")
		localcmd(" echo DIREKT: prueba superlanzaclavos");
	else if (direkt_test_clase == "weapon_grenadelauncher")
		localcmd(" echo DIREKT: prueba lanzagranadas");
	else if (direkt_test_clase == "weapon_lightning")
		localcmd(" echo DIREKT: prueba rayo");
	else if (direkt_test_clase == "item_key1")
		localcmd(" echo DIREKT: prueba llave");
	else if (direkt_test_clase == "item_artifact_super_damage")
		localcmd(" echo DIREKT: prueba relicario");
	else
		localcmd(" echo DIREKT: prueba objeto");
};

void() direkt_selftest_paso =
{
	direkt_test_pendientes = direkt_test_pendientes - 1;
	if (direkt_test_pendientes < 1)
	{
		localcmd(" echo DIREKT: fin del selftest");
		self.think = direkt_nada;
		self.nextthink = 0;
		// Se devuelve al jugador a la vida que tiene en el juego, que es una.
		self.max_health = DIREKT_MAX_HEALTH;
		self.health = DIREKT_MAX_HEALTH;
		return;
	}

	// Se deja al jugador con sitio de vida y sin armadura para que cualquier
	// objeto tenga donde entrar. Con la vida llena los botiquines se rechazan
	// solos y la prueba no diria nada.
	//
	// El maximo se sube TAMBIEN, y no solo la vida. El jugador del juego tiene
	// una sola vida, y con max_health a 1 el motor recorta la vida al maximo en
	// cuanto recibe dano: el jugador se quedaba a 1, cualquier objeto que
	// hiciera dano lo mataba y el recorrido se cortaba en el primero. Aqui solo
	// se toca durante la prueba; al terminar se devuelve el valor del juego.
	self.max_health = 100;
	self.health = 30;
	self.armorvalue = 0;

	// Se anota como estaba el jugador para poder compararlo.
	direkt_test_vida = self.health;
	direkt_test_armadura = self.armorvalue;
	direkt_test_inventario = self.items;
	direkt_test_municion = self.currentammo;

	if (!direkt_test_siguiente())
	{
		localcmd(" echo DIREKT: el mapa no tiene mas objetos");
		direkt_test_arma();
		return;
	}

	// Al siguiente frame el motor ya ha avisado del contacto.
	self.think = direkt_test_comprueba;
	self.nextthink = time + 0.2;
};

void() direkt_test_comprueba =
{
	local float antes;
	local float despues;

	antes = direkt_test_vida;

	direkt_test_tipo();

	despues = self.health;

	if (despues > antes)
		localcmd(" echo DIREKT: objeto cura al jugador");
	else if (despues < antes)
		localcmd(" echo DIREKT: objeto hace dano al jugador");
	else
		localcmd(" echo DIREKT: objeto sin efecto en la salud");

	if (self.armorvalue > direkt_test_armadura)
		localcmd(" echo DIREKT: objeto da armadura");
	else if (self.items != direkt_test_inventario)
		localcmd(" echo DIREKT: objeto da inventario");
	else if (self.currentammo > direkt_test_municion)
		localcmd(" echo DIREKT: objeto da municion");
	else
		localcmd(" echo DIREKT: objeto sin efecto en el inventario");

	// Se devuelve el jugador a donde estaba para que la prueba no lo deje
	// en el otro extremo del mapa.
	self.velocity = '0 0 0';
	setorigin(self, direkt_origen_inicial);
	self.nextthink = time + 0.3;
	self.think = direkt_selftest_paso;
};

// ------------------------------------------------------------------ armas
// Al agotarse la lista de objetos se comprueba que cambiar de arma pase el
// contador de municion al cubo del arma nueva. currentammo es lo que enseña el
// HUD y lo que consulta el disparante para saber si queda municion, asi que si
// no se refresca al cambiar el HUD miente y se deja disparar un arma vacia.
void() direkt_test_arma =
{
	local float esperado;

	// El cambio de arma esta bloqueado mientras el arma sube. En una prueba no
	// hay nada que esperar.
	self.attack_finished = 0;

	// Se elige un arma de fuego cualquiera del inventario.
	if (self.items & IT_SUPER_SHOTGUN)
		direkt_arma_cambiar(IT_SUPER_SHOTGUN, self);
	else if (self.items & IT_SHOTGUN)
		direkt_arma_cambiar(IT_SHOTGUN, self);
	else if (self.items & IT_NAILGUN)
		direkt_arma_cambiar(IT_NAILGUN, self);
	else if (self.items & IT_LIGHTNING)
		direkt_arma_cambiar(IT_LIGHTNING, self);
	else
	{
		localcmd(" echo DIREKT: no hay arma de fuego para probar el cambio");
		self.think = direkt_nada;
		self.nextthink = 0;
		return;
	}

	if (self.weapon == IT_LIGHTNING)
		esperado = self.ammo_cells;
	else if (self.weapon == IT_NAILGUN)
		esperado = self.ammo_nails;
	else
		esperado = self.ammo_shells;

	// currentammo tiene que ser el del arma que ahora esta en la mano. Antes de
	// arreglarlo se quedaba con la cifra del arma anterior, que ademas podia
	// ser mayor que cero y dar por bueno un disparo sin balas.
	if (self.currentammo == esperado)
		localcmd(" echo DIREKT: el cambio de arma pasa la municion");
	else
		localcmd(" echo DIREKT: el cambio de arma deja la municion vieja");

	self.think = direkt_nada;
	self.nextthink = 0;
};

// ------------------------------------------------------------------ prueba de
// agachado. Impulso 22.
//
// Va con una cadena de thinks porque la caja se cambia en el prethink del frame
// siguiente, y desde fuera no hay forma de sincronizarse con eso: mandando un
// impulso y mirando a los dos segundos solo se veria el estado final.
void() direkt_test_suelo =
{
	if (direkt_test_suelo_paso == 0)
	{
		direkt_test_suelo_paso = 1;
		self.think = direkt_test_suelo;
		self.nextthink = time + 0.5;
		return;
	}

	direkt_test_suelo_dz = self.origin_z - direkt_test_suelo_z0;
	if (direkt_piso())
		localcmd(" echo DIREKT: el jugador esta apoyado en el suelo");
	else if (direkt_test_suelo_dz > 4)
		localcmd(" echo DIREKT: el jugador esta en el aire, cayendo");
	else if (direkt_test_suelo_dz < -4)
		localcmd(" echo DIREKT: el jugador esta subiendo");
	else
		localcmd(" echo DIREKT: el jugador esta en el aire");

	// dprint va a la consola del motor, que es justo donde se mira el log.
	direkt_test_suelo_z = self.origin_z;
	dprint("DIREKT: altura z = ");
	dprint(ftos(direkt_test_suelo_z));
	dprint("\n");
	self.think = SUB_Null;
};

void() direkt_test_agacha =
{
	if (direkt_test_agacha_paso == 0)
	{
		direkt_agachado = 1;
		direkt_test_agacha_paso = 1;
		self.think = direkt_test_agacha;
		self.nextthink = time + 0.2;
		return;
	}

	if (direkt_test_agacha_paso == 1)
	{
		// Lo que de verdad deja pasar por un hueco es la caja encogida; el ojo
		// bajo es lo que se ve. Se comprueban los dos.
		if (self.maxs == DIREKT_BAJO_MAXS && self.view_ofs == DIREKT_BAJO_OJO)
			localcmd(" echo DIREKT: el agachado encoge la caja y baja el ojo");
		else
			localcmd(" echo DIREKT: el agachado no encoge la caja");

		direkt_agachado = 0;
		direkt_test_agacha_paso = 2;
		self.think = direkt_test_agacha;
		self.nextthink = time + 0.2;
		return;
	}

	// Al levantarse la caja tiene que volver a ser la de pie. Si no, el jugador
	// se quedaria agachado para siempre despues de pasar por un hueco.
	if (self.maxs == DIREKT_ALTO_MAXS && self.view_ofs == DIREKT_ALTO_OJO)
		localcmd(" echo DIREKT: al levantarse vuelve la caja de pie");
	else
		localcmd(" echo DIREKT: al levantarse la caja no vuelve");

	direkt_test_agacha_paso = 0;
	self.think = direkt_nada;
	self.nextthink = 0;
};

// ------------------------------------------------------------------ informe
// Esta cadena de QuakeC no tiene sprintf ni ftos, asi que no se puede imprimir
// una cifra. Lo que se hace es una escalera de umbrales: se imprime el texto
// del primer escalon superado. El smoke test lee esos textos para comprobar
// que el jugador se ha movido de verdad y no solo "que el motor arranco".
//
// OJO con los mensajes: localcmd mete texto en la cola del servidor SIN
// separador, asi que dos llamadas seguidas se pegan. Todos los literales
// empiezan por un espacio a proposito.
void() direkt_informa_movimiento =
{
	local float d;
	local float v;

	// El motor llama a PlayerPostThink tambien con el hueco del cliente sin
	// poner en el mapa todavia: se reconoce porque no tiene vida maxima. Sin
	// esta comprobacion se informaria de un jugador que aun no existe.
	if (self.max_health <= 0)
		return;

	if (time < direkt_tiempo_informe)
		return;
	direkt_tiempo_informe = time + 2;

	d = direkt_recorrido;
	v = vlen(self.velocity);

	if (d > 1000)
		localcmd(" echo DIREKT: recorre mas de 1000 unidades");
	else if (d > 500)
		localcmd(" echo DIREKT: recorre de 500 a 1000 unidades");
	else if (d > 200)
		localcmd(" echo DIREKT: recorre de 200 a 500 unidades");
	else if (d > 50)
		localcmd(" echo DIREKT: recorre de 50 a 200 unidades");
	else if (d > 5)
		localcmd(" echo DIREKT: recorre menos de 50 unidades");
	else
		localcmd(" echo DIREKT: no se ha movido");

	if (v > 200)
		localcmd(" echo DIREKT: velocidad por encima de 200");
	else if (v > 50)
		localcmd(" echo DIREKT: velocidad de 50 a 200");
	else
		localcmd(" echo DIREKT: velocidad casi nula");

	if (self.flags & FL_ONGROUND)
		localcmd(" echo DIREKT: apoyado en el suelo");
	else
		localcmd(" echo DIREKT: en el aire");

	// Estado del agachado. La caja encogida y el ojo bajo son lo que de verdad
	// impiden pasar por un hueco, asi que se informa de los dos.
	if (self.maxs == DIREKT_BAJO_MAXS)
	{
		localcmd(" echo DIREKT: agachado, caja encogida");
		if (self.view_ofs == DIREKT_BAJO_OJO)
			localcmd(" echo DIREKT: agachado, ojo bajo");
		else
			localcmd(" echo DIREKT: agachado, ojo sin bajar");
	}
	else
		localcmd(" echo DIREKT: de pie");

	// Como el motor dibuja el HUD con estos campos, informar de ellos deja
	// ver que el juego esta vivo y no solo el render.
	if (self.weapon == IT_AXE)
		localcmd(" echo DIREKT: arma en mano el hacha");
	else if (self.weapon == IT_SHOTGUN)
		localcmd(" echo DIREKT: arma en mano la escopeta");
	else if (self.weapon == IT_SUPER_SHOTGUN)
		localcmd(" echo DIREKT: arma en mano la superescopeta");
	else if (self.weapon == IT_NAILGUN)
		localcmd(" echo DIREKT: arma en mano el lanzaclavos");
	else if (self.weapon == IT_SUPER_NAILGUN)
		localcmd(" echo DIREKT: arma en mano el superlanzaclavos");
	else if (self.weapon == IT_GRENADE_LAUNCHER)
		localcmd(" echo DIREKT: arma en mano el lanzagranadas");
	else if (self.weapon == IT_ROCKET_LAUNCHER)
		localcmd(" echo DIREKT: arma en mano el lanzacohetes");
	else if (self.weapon == IT_LIGHTNING)
		localcmd(" echo DIREKT: arma en mano el rayo");
	else
		localcmd(" echo DIREKT: sin arma en la mano");

	if (self.health > 75)
		localcmd(" echo DIREKT: salud por encima de 75");
	else if (self.health > 25)
		localcmd(" echo DIREKT: salud de 25 a 75");
	else if (self.health > 0)
		localcmd(" echo DIREKT: salud casi a cero");
	else
		localcmd(" echo DIREKT: jugador sin vida");

	if (self.armorvalue > 75)
		localcmd(" echo DIREKT: armadura por encima de 75");
	else if (self.armorvalue > 0)
		localcmd(" echo DIREKT: armadura de 0 a 75");
	else
		localcmd(" echo DIREKT: sin armadura");

	if (self.currentammo > 30)
		localcmd(" echo DIREKT: municion por encima de 30");
	else if (self.currentammo > 5)
		localcmd(" echo DIREKT: municion de 5 a 30");
	else if (self.currentammo > 0)
		localcmd(" echo DIREKT: municion de 1 a 5");
	else
		localcmd(" echo DIREKT: sin municion");
};
