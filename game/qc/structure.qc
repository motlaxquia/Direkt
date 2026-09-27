// Direkt -- puertas, botones y plataformas.
//
// GPL-2.0, ver LICENSE en la raiz del repositorio.
//
// Port de la mecanica de LibreQuake (doors.qc, buttons.qc y plats.qc) a las
// convenciones de este proyecto: las funciones internas van en espanol con
// prefijo direkt_ y solo los nombres de spawn conservan el classname del mapa.
//
// Los 13 mapas de LibreQuake usan 58 func_door, 3 func_button y 8 func_plat, y
// no usan ni una puerta giratoria ni una func_door2. Con ese conjunto esta:
//
//   - velocidad, espera, lip, altura y dano leidos del mapa (speed, wait, lip,
//     height y dmg estan declarados en defs.qc despues de end_sys_fields, que
//     es donde el motor deja de mirar y el juego puede escribir),
//   - puertas de llave (IT_KEY1), que no vuelven a cerrarse solas,
//   - puertas que se abren al rozarlas, con el mensaje del mapa, y puertas
//     emparejadas que se mueven a la vez (las de gate1, gate2 y gate3),
//   - START_OPEN y DONT_LINK,
//   - aplastar a quien se pone en medio.
//
// Lo que no se arrastra: localizacion (centerprint3 es una extension de FTE que
// bajo este motor leeria mal los argumentos) y los objerror, que abortan la
// partida entera. Donde el codigo original abortaba, aqui se sale con
// silencio: un mapa raro no puede tumbar el juego.

// ------------------------------------------------------------------ avisos
float DIREKT_PUERTA_ABIERTA      = 1;
float DIREKT_PUERTA_NO_LINKEA    = 4;
float DIREKT_PUERTA_LLAVE_ORO    = 8;
float DIREKT_PUERTA_LLAVE_PLATA  = 16;
float DIREKT_PUERTA_ALTERNAR    = 32;

float DIREKT_PLAT_GATILLO_BAJO   = 1;

entity direkt_plat_uno;
vector direkt_plat_origen1;
entity direkt_plat_dos;
vector direkt_plat_origen2;
float direkt_plat_spawns;

// ------------------------------------------------------------------ diagnostico
// structure.qc se compila antes que player.qc, donde vive el dano: sin esto el
// compilador no sabe que la funcion existe.
void(entity objetivo, entity agresor, float dano) direkt_danio;

// Solo para el diagnostico de la prueba de estructura.

void() direkt_puerta_sube;
void() direkt_puerta_baja;
void() direkt_puerta_arriba;
void() direkt_puerta_abajo;
void() direkt_puerta_dispara;
void() direkt_puerta_uso;
void() direkt_puerta_muerta;
void() direkt_puertas_enlaza;
float(entity a, entity b) direkt_entes_tocan;

// ------------------------------------------------------------------ puertas
// Cuando algo se cruza en el camino: se aplasta y la puerta se da la vuelta,
// salvo que este abierta para siempre (wait -1), en cuyo caso el crushed se
// queda muerto.
void() direkt_puerta_bloqueada =
{
	other.deathtype = "squish";
	direkt_danio(other, self, self.dmg);

	// Con wait negativo la puerta ya no volveria nunca y dejaria al crushed
	// atrapado: se conforma con aplastarlo y seguir.
	if (self.wait < 0)
		return;

	if (self.state == STATE_DOWN)
		direkt_puerta_sube();
	else
		direkt_puerta_baja();
};

void() direkt_puerta_arriba =
{
	sound(self, CHAN_NO_PHS_ADD + CHAN_VOICE, self.noise1, 1, ATTN_NORM);
	self.state = STATE_TOP;

	if (self.spawnflags & DIREKT_PUERTA_ALTERNAR)
		return;

	// Espera negativa o cero: la puerta se queda abierta el resto del mapa.
	if (self.wait <= 0)
		return;

	self.think = direkt_puerta_baja;
	self.nextthink = self.ltime + self.wait;
};

void() direkt_puerta_abajo =
{
	sound(self, CHAN_NO_PHS_ADD + CHAN_VOICE, self.noise1, 1, ATTN_NORM);
	self.state = STATE_BOTTOM;
};

void() direkt_puerta_baja =
{
	sound(self, CHAN_VOICE, self.noise2, 1, ATTN_NORM);

	// Las puertas disparables recuperan la vida mientras vuelven a bajar: si
	// no, el primer tiro las deja abiertas el resto de la partida.
	if (self.max_health)
	{
		self.takedamage = DAMAGE_YES;
		self.health = self.max_health;
	}

	self.state = STATE_DOWN;
	SUB_CalcMove(self.pos1, self.speed, direkt_puerta_abajo);
};

void() direkt_puerta_sube =
{
	if (self.state == STATE_UP)
		return;

	if (self.state == STATE_TOP)
	{
		// Ya estaba abierta: solo hay que reiniciar la cuenta atras.
		if (self.wait > 0)
			self.nextthink = self.ltime + self.wait;
		return;
	}

	sound(self, CHAN_VOICE, self.noise2, 1, ATTN_NORM);
	self.state = STATE_UP;
	SUB_CalcMove(self.pos2, self.speed, direkt_puerta_arriba);

	SUB_UseTargets();
};

// Recorre la cadena de puertas emparejadas y las manda todas a la vez.
// self.owner es la puerta maestra y self.enemy el eslabon siguiente; cuando hay
// una sola puerta, los dos apuntan a si misma y el bucle da una vuelta.
void() direkt_puerta_dispara =
{
	local entity guardado, inicio;

	// Todavia sin maestro (no llego a pasar el emparejado): se comporta como
	// una puerta sola, sube y vuelve a bajar por su cuenta.
	if (self.owner != self)
	{
		if (self.state == STATE_UP || self.state == STATE_TOP)
			direkt_puerta_baja();
		else
			direkt_puerta_sube();
		return;
	}

	if (self.items)
		sound(self, CHAN_ITEM, self.noise4, 1, ATTN_NORM);

	self.message = string_null;
	guardado = self;

	// ALTERNAR: si esta arriba, se cierra y se sale, en vez de abrirla.
	if (self.spawnflags & DIREKT_PUERTA_ALTERNAR)
	{
		if (self.state == STATE_UP || self.state == STATE_TOP)
		{
			inicio = self;
			do
			{
				direkt_puerta_baja();
				self = self.enemy;
			} while (self != inicio && self != world);

			self = guardado;
			return;
		}
	}

	inicio = self;
	do
	{
		// Quien toco el gatillo, por si algo mas lo consulta.
		self.goalentity = activator;
		direkt_puerta_sube();
		self = self.enemy;
	} while (self != inicio && self != world);

	self = guardado;
};

void() direkt_puerta_uso =
{
	local entity guardado;

	// El mensaje del mapa es solo para el rozado: si se abre por target, calla.
	self.message = string_null;
	if (self.owner)
		self.owner.message = string_null;
	if (self.enemy)
		self.enemy.message = string_null;

	guardado = self;
	if (self.owner)
		self = self.owner;
	direkt_puerta_dispara();
	self = guardado;
};

void() direkt_puerta_gatillo_toque =
{
	if (other.health <= 0)
		return;

	if (time < self.attack_finished)
		return;

	self.attack_finished = time + 1;
	activator = other;

	self = self.owner;
	direkt_puerta_uso();
};

void() direkt_puerta_muerta =
{
	local entity guardado;

	guardado = self;
	self = self.owner;
	self.health = self.max_health;
	self.takedamage = DAMAGE_NO;
	direkt_puerta_uso();
	self = guardado;
};

// Muestra el mensaje del mapa y, si es puerta de llave, la abre.
void() direkt_puerta_toque =
{
	if (other.classname != "player")
		return;

	if (self.owner.attack_finished > time)
		return;

	self.owner.attack_finished = time + 2;

	if (self.owner.message != string_null)
	{
		centerprint(other, self.owner.message);
		sound(other, CHAN_VOICE, "misc/talk.wav", 1, ATTN_NORM);
	}

	if (!self.items)
		return;

	if ((self.items & other.items) != self.items)
	{
		// Al jugador le falta la llave: se dice cual y no se gasta.
		if (self.owner.items == IT_KEY1)
			centerprint(other, "You need the silver key");
		else
			centerprint(other, "You need the gold key");

		sound(self, CHAN_VOICE, self.noise3, 1, ATTN_NORM);
		return;
	}

	// La llave se consume y la puerta ya no vuelve a pedirla.
	other.items = other.items - self.items;
	self.touch = direkt_nada;

	if (self.enemy)
		self.enemy.touch = direkt_nada;

	direkt_puerta_uso();
};

// Caja de gatillo que rodea a una puerta sin targetname para abrirla al
// rozarla. Se agranda 60 unidades en horizontal: el jugador tiene que acercarse
// lo bastante, pero no tiene que tocar el marco.
entity(vector fmins, vector fmaxs) direkt_campo_gatillo =
{
	local entity gatillo;

	gatillo = spawn();
	gatillo.movetype = MOVETYPE_NONE;
	gatillo.solid = SOLID_TRIGGER;
	gatillo.owner = self;
	gatillo.touch = direkt_puerta_gatillo_toque;

	setsize(gatillo, fmins - '60 60 8', fmaxs + '60 60 8');

	return gatillo;
};

float(entity a, entity b) direkt_entes_tocan =
{
	if (a.mins_x > b.maxs_x)
		return FALSE;
	if (a.mins_y > b.maxs_y)
		return FALSE;
	if (a.mins_z > b.maxs_z)
		return FALSE;
	if (a.maxs_x < b.mins_x)
		return FALSE;
	if (a.maxs_y < b.mins_y)
		return FALSE;
	if (a.maxs_z < b.mins_z)
		return FALSE;

	return TRUE;
};

// Empareja las puertas que se tocan entre si para que se muevan como una sola.
// No se puede hacer durante el spawn: el motor todavia no ha calculdo el
// tamano de los brushes, asi que se retrasa 0.1 s.
void() direkt_puertas_enlaza =
{
	local entity t, inicio;
	local vector cmins, cmaxs;

	if (self.enemy)
		return;

	if (self.spawnflags & DIREKT_PUERTA_NO_LINKEA)
	{
		self.owner = self.enemy = self;
		return;
	}

	cmins = self.mins;
	cmaxs = self.maxs;

	inicio = self;
	t = self;

	do
	{
		self.owner = inicio;

		// La maestra hereda lo que sus pareja no tengan: si una de las dos es
		// disparable, lo son las dos.
		if (self.health)
			inicio.health = self.health;

		if (self.targetname != string_null)
			inicio.targetname = self.targetname;

		if (self.message != string_null)
			inicio.message = self.message;

		t = find(t, classname, self.classname);
		if (!t)
		{
			// Cerrar la cadena en un bucle.
			self.enemy = inicio;
			self = self.owner;

			// Disparable, con nombre o de llave: con los enlaces ya no hace
			// falta caja de gatillo.
			if (self.health)
				return;
			if (self.targetname != string_null)
				return;
			if (self.items)
				return;

			self.owner.trigger_field = direkt_campo_gatillo(cmins, cmaxs);
			return;
		}

		if (direkt_entes_tocan(self, t))
		{
			// Cruzadas: la segunda ya esta en otra cadena. Es un caso raro
			// que solo aparece en mapas hechos a mano, asi que se avisa y se
			// deja la cadena como estaba en vez de abortar la partida.
			if (t.enemy)
			{
				dprint("DIREKT: dos puertas cruzadas en la misma cadena\n");
				continue;
			}

			self.enemy = t;
			self = t;

			if (t.mins_x < cmins_x)
				cmins_x = t.mins_x;
			if (t.mins_y < cmins_y)
				cmins_y = t.mins_y;
			if (t.mins_z < cmins_z)
				cmins_z = t.mins_z;
			if (t.maxs_x > cmaxs_x)
				cmaxs_x = t.maxs_x;
			if (t.maxs_y > cmaxs_y)
				cmaxs_y = t.maxs_y;
			if (t.maxs_z > cmaxs_z)
				cmaxs_z = t.maxs_z;
		}
	} while (1);
};

// Los sonidos de llave dependen del estilo del mundo (medieval, rune o metal).
// Los 13 mapas son medievales, pero el codigo se deja completo por si
// aparece un mapa de otro estilo.
void() direkt_puerta_sonidos_llave =
{
	if (world.worldtype == 1)
	{
		self.noise3 = "doors/runetry.wav";
		self.noise4 = "doors/runeuse.wav";
		return;
	}

	if (world.worldtype == 2)
	{
		self.noise3 = "doors/basetry.wav";
		self.noise4 = "doors/baseuse.wav";
		return;
	}

	self.noise3 = "doors/medtry.wav";
	self.noise4 = "doors/meduse.wav";
};

void() direkt_puerta_sonidos =
{
	if (self.sounds == 1)
	{
		self.noise1 = "doors/drclos4.wav";
		self.noise2 = "doors/doormv1.wav";
		return;
	}

	if (self.sounds == 2)
	{
		self.noise2 = "doors/hydro1.wav";
		self.noise1 = "doors/hydro2.wav";
		return;
	}

	if (self.sounds == 3)
	{
		self.noise2 = "doors/stndr1.wav";
		self.noise1 = "doors/stndr2.wav";
		return;
	}

	if (self.sounds == 4)
	{
		self.noise1 = "doors/ddoor2.wav";
		self.noise2 = "doors/ddoor1.wav";
		return;
	}

	// sounds 0 o lo que venga: silencio, pero con los nombres puestos para que
	// suene algo en vez de un error de sonido vacio.
	self.noise1 = "misc/null.wav";
	self.noise2 = "misc/null.wav";
};

/*
QUAKED func_door (0 .5 .8) ? START_OPEN x DOOR_DONT_LINK GOLD_KEY SILVER_KEY TOGGLE
"angle"		direccion de apertura
"targetname"	si esta, no se crea caja de gatillo: la abre un boton
"health"	si esta, hay que dispararla
"speed"		100 por defecto
"wait"		3 por defecto, -1 = no vuelve nunca
"lip"		8 por defecto
"dmg"		2 por defecto
"sounds"	0 ninguna, 1 piedra, 2 base, 3 cadena, 4 metal chirriante
*/
void() func_door =
{
	precache_sound("misc/null.wav");
	precache_sound("misc/talk.wav");
	precache_sound("doors/drclos4.wav");
	precache_sound("doors/doormv1.wav");
	precache_sound("doors/hydro1.wav");
	precache_sound("doors/hydro2.wav");
	precache_sound("doors/stndr1.wav");
	precache_sound("doors/stndr2.wav");
	precache_sound("doors/ddoor1.wav");
	precache_sound("doors/ddoor2.wav");
	precache_sound("doors/medtry.wav");
	precache_sound("doors/meduse.wav");
	precache_sound("doors/runetry.wav");
	precache_sound("doors/runeuse.wav");
	precache_sound("doors/basetry.wav");
	precache_sound("doors/baseuse.wav");

	direkt_puerta_sonidos();
	direkt_puerta_sonidos_llave();
	direkt_movedir();

	self.max_health = self.health;
	self.solid = SOLID_BSP;
	self.movetype = MOVETYPE_PUSH;
	setorigin(self, self.origin);
	setmodel(self, self.model);
	// Renombrarla es lo que permite que el emparejado de mas abajo busque
	// "door" y no la confunda con los brushes de pared.
	self.classname = "door";

	self.blocked = direkt_puerta_bloqueada;
	self.use = direkt_puerta_uso;

	if (self.spawnflags & DIREKT_PUERTA_LLAVE_PLATA)
		self.items = IT_KEY1;

	if (self.spawnflags & DIREKT_PUERTA_LLAVE_ORO)
		self.items = IT_KEY2;

	if (!self.speed)
		self.speed = 100;
	if (!self.wait)
		self.wait = 3;
	if (!self.lip)
		self.lip = 8;
	if (!self.dmg)
		self.dmg = 2;

	self.pos1 = self.origin;
	// La puerta recorre su propio grosor menos el labio que se deja al
	// cerrar, en la direccion que dicta "angle".
	self.pos2 = self.pos1 + self.movedir * (fabs(self.movedir * self.size) - self.lip);

	// START_OPEN: se dibuja cerrada para que la luz cuadre, pero arranca
	// abierta, y a partir de ahi los dos extremos estan cambiados.
	if (self.spawnflags & DIREKT_PUERTA_ABIERTA)
	{
		setorigin(self, self.pos2);
		self.pos2 = self.pos1;
		self.pos1 = self.origin;
	}

	self.state = STATE_BOTTOM;

	if (self.health)
	{
		self.takedamage = DAMAGE_YES;
		self.th_die = direkt_puerta_muerta;
	}

	if (self.items)
		self.wait = -1;

	self.touch = direkt_puerta_toque;

	self.think = direkt_puertas_enlaza;
	self.nextthink = time + 0.1;
};

// ------------------------------------------------------------------ botones
void() direkt_boton_espera;
void() direkt_boton_vuelve;
void() direkt_boton_fin;
void() direkt_boton_dispara;
void() direkt_boton_muerta;

void() direkt_boton_espera =
{
	self.state = STATE_TOP;
	self.nextthink = self.ltime + self.wait;
	self.think = direkt_boton_vuelve;
	activator = self.enemy;
	SUB_UseTargets();
	self.frame = 1;
};

void() direkt_boton_fin =
{
	self.state = STATE_BOTTOM;
};

void() direkt_boton_vuelve =
{
	self.state = STATE_DOWN;
	SUB_CalcMove(self.pos1, self.speed, direkt_boton_fin);
	self.frame = 0;

	// Vuelve a ser disparable, que si no solo aguantaba un tiro.
	if (self.health)
		self.takedamage = DAMAGE_YES;
};

// Un boton que se topa con algo no se queda a medias: el movetype PUSH lo
// bloquea y aqui no hay nada que hacer.
void() direkt_boton_bloqueado =
{
};

void() direkt_boton_dispara =
{
	if (self.state == STATE_UP || self.state == STATE_TOP)
		return;

	sound(self, CHAN_VOICE, self.noise, 1, ATTN_NORM);

	self.state = STATE_UP;
	SUB_CalcMove(self.pos2, self.speed, direkt_boton_espera);
};

void() direkt_boton_uso =
{
	self.enemy = activator;
	direkt_boton_dispara();
};

void() direkt_boton_toque =
{
	if (other.classname != "player")
		return;

	self.enemy = other;
	direkt_boton_dispara();
};

void() direkt_boton_muerta =
{
	self.enemy = damage_attacker;
	self.health = self.max_health;
	self.takedamage = DAMAGE_NO;
	direkt_boton_dispara();
};

void() direkt_boton_sonidos =
{
	if (self.sounds == 1)
	{
		self.noise = "buttons/switch21.wav";
		return;
	}

	if (self.sounds == 2)
	{
		self.noise = "buttons/switch02.wav";
		return;
	}

	if (self.sounds == 3)
	{
		self.noise = "buttons/switch04.wav";
		return;
	}

	self.noise = "buttons/airbut1.wav";
};

/*
QUAKED func_button (0 .5 .8) ?
"angle"		direccion de pulsacion
"target"	lo que enciende
"speed"		40 por defecto
"wait"		1 por defecto
"lip"		4 por defecto
"health"	si esta, hay que dispararlo en vez de rozarlo
"sounds"	0 vapor, 1 madera, 2 metal, 3 dentro-fuera
*/
void() func_button =
{
	precache_sound("buttons/airbut1.wav");
	precache_sound("buttons/switch21.wav");
	precache_sound("buttons/switch02.wav");
	precache_sound("buttons/switch04.wav");

	direkt_boton_sonidos();
	direkt_movedir();

	self.movetype = MOVETYPE_PUSH;
	self.solid = SOLID_BSP;
	setorigin(self, self.origin);
	setmodel(self, self.model);

	self.blocked = direkt_boton_bloqueado;
	self.use = direkt_boton_uso;

	if (self.health)
	{
		self.max_health = self.health;
		self.th_die = direkt_boton_muerta;
		self.takedamage = DAMAGE_YES;
	}
	else
		self.touch = direkt_boton_toque;

	if (!self.speed)
		self.speed = 40;
	if (!self.wait)
		self.wait = 1;
	if (!self.lip)
		self.lip = 4;

	self.state = STATE_BOTTOM;

	self.pos1 = self.origin;
	self.pos2 = self.pos1 + self.movedir * (fabs(self.movedir * self.size) - self.lip);
};

// ------------------------------------------------------------------ plataformas
void() direkt_plataforma_sube;
void() direkt_plataforma_baja;
void() direkt_plataforma_arriba;
void() direkt_plataforma_abajo;
void() direkt_plataforma_uso;
void() direkt_plataforma_exterior_toque;
void() direkt_plataforma_centro_toque;
void() direkt_plataforma_gatillo_uso;
void() direkt_plataforma_gatillo_crea;
void() direkt_plataforma_aplasta;

// Caja interior que dispara la plataforma. Va pegada a la cara de arriba, con
// 25 unidades de margen lateral; si la plataforma es estrecha (50 o menos) el
// lateral se reduce a una franja de una unidad, porque si no el jugador que va
// de pie en el borde no la moveria nunca.
void() direkt_plataforma_gatillo_crea =
{
	local entity gatillo;
	local vector tmin, tmax;

	gatillo = spawn();
	gatillo.touch = direkt_plataforma_centro_toque;
	gatillo.movetype = MOVETYPE_NONE;
	gatillo.solid = SOLID_TRIGGER;
	gatillo.enemy = self;

	tmin = self.mins + '25 25 0';
	tmax = self.maxs - '25 25 -8';
	tmin_z = tmax_z - (self.pos1_z - self.pos2_z + 8);

	if (self.spawnflags & DIREKT_PLAT_GATILLO_BAJO)
		tmax_z = tmin_z + 8;

	if (self.size_x <= 50)
	{
		tmin_x = (self.mins_x + self.maxs_x) / 2;
		tmax_x = tmin_x + 1;
	}

	if (self.size_y <= 50)
	{
		tmin_y = (self.mins_y + self.maxs_y) / 2;
		tmax_y = tmin_y + 1;
	}

	setsize(gatillo, tmin, tmax);
};

void() direkt_plataforma_vigia;

// Devuelve 0 si todo cuadra, o un codigo de por que no.
float() direkt_plat_estado =
{
	local vector esperado;

	if (direkt_plat_spawns > 2)
		return 5;

	if (self == direkt_plat_uno)
		esperado = direkt_plat_origen1;
	else if (self == direkt_plat_dos)
		esperado = direkt_plat_origen2;
	else
		return 1;

	if (self.pos1 == esperado)
	{
		if (self.pos2 == '0 0 0')
			return 6;
		return 0;
	}
	if (self.pos1 == '0 0 0')
		return 2;
	if (self.origin == '0 0 0')
		return 3;
	return 4;
};

// Se queda mirando cada frame y avisa en el instante en que algo se rompe.
void() direkt_plataforma_vigia =
{
	local float e;
	e = direkt_plat_estado();
	if (e == 0)
	{
		self.think = direkt_plataforma_vigia;
		self.nextthink = time + 0.1;
		return;
	}

	if (e == 1)
		localcmd(" echo DIREKT: VIGIA entidad rara");
	else if (e == 2)
		localcmd(" echo DIREKT: VIGIA pos1 a 0");
	else if (e == 3)
		localcmd(" echo DIREKT: VIGIA origin a 0");
	else if (e == 4)
		localcmd(" echo DIREKT: VIGIA pos1 otro valor");
	else if (e == 6)
		localcmd(" echo DIREKT: VIGIA pos2 a 0");
	else
		localcmd(" echo DIREKT: VIGIA hubo respawn");
	self.think = direkt_nada;
};

void() direkt_plataforma_arriba =
{
	sound(self, CHAN_NO_PHS_ADD + CHAN_VOICE, self.noise1, 1, ATTN_NORM);
	self.state = STATE_TOP;
	self.think = direkt_plataforma_baja;
	self.nextthink = self.ltime + 3;
};

void() direkt_plataforma_abajo =
{
	sound(self, CHAN_NO_PHS_ADD + CHAN_VOICE, self.noise1, 1, ATTN_NORM);
	self.state = STATE_BOTTOM;
};

void() direkt_plataforma_baja =
{
	sound(self, CHAN_VOICE, self.noise, 1, ATTN_NORM);
	self.state = STATE_DOWN;
	SUB_CalcMove(self.pos2, self.speed, direkt_plataforma_abajo);
};

void() direkt_plataforma_sube =
{
	sound(self, CHAN_VOICE, self.noise, 1, ATTN_NORM);
	self.state = STATE_UP;
	SUB_CalcMove(self.pos1, self.speed, direkt_plataforma_arriba);
};

void() direkt_plataforma_centro_toque =
{
	if (other.classname != "player")
		return;
	if (other.health <= 0)
		return;

	self = self.enemy;

	if (self.state == STATE_BOTTOM)
		direkt_plataforma_sube();
	else if (self.state == STATE_TOP)
	{
		// El jugador sigue arriba: se retrasa la bajada.
		self.ltime = time;
		self.nextthink = self.ltime + 1;
	}
};

// Bajarse por el borde la para al instante, sin esperar a que llegue abajo.
void() direkt_plataforma_exterior_toque =
{
	if (other.classname != "player")
		return;
	if (other.health <= 0)
		return;

	self = self.enemy;

	if (self.state == STATE_TOP)
		direkt_plataforma_baja();
};

// Cuando algo se queda debajo.
void() direkt_plataforma_aplasta =
{
	direkt_danio(other, self, 1);

	if (self.state == STATE_UP)
		direkt_plataforma_baja();
	else if (self.state == STATE_DOWN)
		direkt_plataforma_sube();
	// En TOP o BOTTOM no hay nada que hacer: el codigo original abortaba aqui
	// y abortar la partida por un jugador mal colocado es peor que ignorar.
};

// Activada por un boton o un trigger: baja y se queda como plataforma normal.
void() direkt_plataforma_gatillo_uso =
{
	if (self.think)
		return;

	direkt_plataforma_baja();
};

// Cuando la plataforma es el objetivo de otro gatillo, arranca arriba y
// desactivada. Al usarla se queda sin .use para no bajar dos veces.
void() direkt_plataforma_uso =
{
	self.use = direkt_nada;

	if (self.state != STATE_UP)
		return;

	direkt_plataforma_baja();
};

void() direkt_plataforma_sonidos =
{
	if (self.sounds == 1)
	{
		self.noise = "plats/plat1.wav";
		self.noise1 = "plats/plat2.wav";
		return;
	}

	self.noise = "plats/medplat1.wav";
	self.noise1 = "plats/medplat2.wav";
};

/*
QUAKED func_plat (0 .5 .8) ? PLAT_LOW_TRIGGER
Las plataformas se dibujan en la posicion extendida para que la luz cuadre.
Con "height" se indica cuanto sube; si no, sube lo que mida el modelo.
"sounds" 1 base rapida, 2 cadena lenta
*/
void() func_plat =
{
	precache_sound("plats/plat1.wav");
	precache_sound("plats/plat2.wav");
	precache_sound("plats/medplat1.wav");
	precache_sound("plats/medplat2.wav");

	direkt_plataforma_sonidos();

	self.mangle = self.angles;
	self.angles = '0 0 0';

	self.classname = "plat";
	direkt_plat_spawns = direkt_plat_spawns + 1;
	if (direkt_plat_spawns == 1)
	{
		direkt_plat_uno = self;
		direkt_plat_origen1 = self.origin;
	}
	else if (direkt_plat_spawns == 2)
	{
		direkt_plat_dos = self;
		direkt_plat_origen2 = self.origin;
	}
	self.solid = SOLID_BSP;
	self.movetype = MOVETYPE_PUSH;
	setorigin(self, self.origin);
	setmodel(self, self.model);
	setsize(self, self.mins, self.maxs);

	self.blocked = direkt_plataforma_aplasta;

	if (!self.speed)
		self.speed = 150;

	// pos1 es arriba y pos2 abajo.
	self.pos1 = self.origin;
	self.pos2 = self.origin;

	if (self.pos1 == self.origin)
		localcmd(" echo DIREKT: PLAT pos1 copiada");
	else
		localcmd(" echo DIREKT: PLAT pos1 no copiada");

	if (self.height)
		self.pos2_z = self.origin_z - self.height;
	else
		self.pos2_z = self.origin_z - self.size_z + 8;

	self.use = direkt_plataforma_gatillo_uso;

	direkt_plataforma_gatillo_crea();

	self.think = direkt_plataforma_vigia;
	self.nextthink = time;

	// Con targetname arranca arriba y sin uso hasta que la activen.
	if (self.targetname != string_null)
	{
		self.state = STATE_UP;
		self.use = direkt_plataforma_uso;
	}
	else
	{
		setorigin(self, self.pos2);
		self.state = STATE_BOTTOM;
	}

};


// ------------------------------------------------------------------ prueba
// Impulso 10. Igual que el selftest de objetos pero sobre la estructura del
// mapa: cuenta lo que hay, comprueba que cada puerta tiene destino y esta
// enlazada, y despues mueve de verdad una puerta, un boton y una plataforma.
//
// Cada comprobacion saca su propia linea porque QuakeC no puede juntar
// cadenas: el smoke test las cuenta con grep. Y cada fase empieza poniendo la
// entidad global a cero, porque si el mapa no tiene puertas, botones ni
// plataformas (en lqdm1 solo hay puertas) un valor viejo haria que la fase
// siguiente creyera que ha encontrado algo.
entity	direkt_estructura_entidad;
vector	direkt_estructura_origen;
vector	direkt_estructura_destino;

void() direkt_estructura_puerta;
void() direkt_estructura_puerta_dispara;
void() direkt_estructura_puerta_mueve;
void() direkt_estructura_boton;
void() direkt_estructura_boton_mueve;
void() direkt_estructura_plataforma;
void() direkt_estructura_plataforma_mueve;
void() direkt_estructura_fin;

void() direkt_estructura_cuenta =
{
	local entity d, b, p;

	d = world;
	do
	{
		d = find(d, classname, "door");
		if (!d)
			break;

		localcmd(" echo DIREKT: PUERTA lista");

		// Sin destino la puerta no se moveria nunca: el movedir salio nulo.
		if (d.pos2 == d.pos1)
			localcmd(" echo DIREKT: PUERTA sin destino");

		if (d.solid != SOLID_BSP)
			localcmd(" echo DIREKT: PUERTA no solida");

		if (d.items)
			localcmd(" echo DIREKT: PUERTA con llave");

		if (!d.use)
			localcmd(" echo DIREKT: PUERTA sin uso");
	} while (1);

	b = world;
	do
	{
		b = find(b, classname, "func_button");
		if (!b)
			break;

		localcmd(" echo DIREKT: BOTON lista");

		if (b.origin == '0 0 0')
			localcmd(" echo DIREKT: BOTON en el origen");

		if (b.pos2 == b.pos1)
			localcmd(" echo DIREKT: BOTON sin destino");

		if (!b.use)
			localcmd(" echo DIREKT: BOTON sin uso");
	} while (1);

	p = world;
	do
	{
		p = find(p, classname, "plat");
		if (!p)
			break;

		if (p == direkt_plat_uno)
		{
			if (p.pos1 == direkt_plat_origen1)
				localcmd(" echo DIREKT: PLAT1 es la mia, pos1 bien");
			else if (p.pos1 == '0 0 0')
				localcmd(" echo DIREKT: PLAT1 es la mia, pos1 a 0");
			else
				localcmd(" echo DIREKT: PLAT1 es la mia, pos1 otro valor");
		}
		else if (p == direkt_plat_dos)
		{
			if (p.pos1 == direkt_plat_origen2)
				localcmd(" echo DIREKT: PLAT2 es la mia, pos1 bien");
			else if (p.pos1 == '0 0 0')
				localcmd(" echo DIREKT: PLAT2 es la mia, pos1 a 0");
			else
				localcmd(" echo DIREKT: PLAT2 es la mia, pos1 otro valor");
		}
		else if (p.pos1 == '0 0 0')
			localcmd(" echo DIREKT: PLAT3 extrana con pos1 a 0");
		else
			localcmd(" echo DIREKT: PLAT3 extrana con pos1 buena");
	} while (1);

	self.think = direkt_estructura_puerta;
	self.nextthink = time + 0.2;
};

// Fase 1: busca una puerta que tenga un destino de verdad y este enlazada con
// otra, que es la comprobacion mas fuerte que se puede hacer sin tocarla.
void() direkt_estructura_puerta =
{
	local entity t, elegido;

	direkt_estructura_entidad = world;
	elegido = world;

	// Se busca primero una puerta con recorrido de verdad y, entre ellas, una
	// emparejada: si hay cadena, al disparar una tienen que moverse las dos.
	t = world;
	do
	{
		t = find(t, classname, "door");
		if (!t)
			break;

		if (t.pos2 == t.pos1)
			continue;

		if (!elegido)
			elegido = t;

		if (t.enemy && t.enemy != t)
		{
			elegido = t;
			break;
		}
	} while (1);

	direkt_estructura_entidad = elegido;
	direkt_estructura_origen = elegido.origin;
	direkt_estructura_destino = elegido.pos2;

	if (!elegido)
	{
		localcmd(" echo DIREKT: PUERTA ausente");
		self.think = direkt_estructura_boton;
		self.nextthink = time + 0.2;
		return;
	}

	if (elegido.enemy && elegido.enemy != elegido)
		localcmd(" echo DIREKT: PUERTA emparejada");
	else
		localcmd(" echo DIREKT: PUERTA suelta");
	self.think = direkt_estructura_puerta_dispara;
	self.nextthink = time + 0.4;
};

// Fase 1b: ahora si, se enciende. Va en un frame aparte para que los mensajes
// del diagnostico de arriba lleguen a vaciarse antes.
void() direkt_estructura_puerta_dispara =
{
	local entity t, o;
	o = self;

	// fteqcc no cambia self al llamar a una funcion de entidad, asi que hay
	// que fijarlo a mano. Ver direkt_llama_use en subs.qc.
	t = direkt_estructura_entidad;
	self = t;
	if (t.use)
		t.use();
	self = o;

	self.think = direkt_estructura_puerta_mueve;
	self.nextthink = time + 1;
};

// Fase 2: la puerta deberia haberse movido hacia pos2 y no seguir cerrada.
void() direkt_estructura_puerta_mueve =
{
	local entity p;

	p = direkt_estructura_entidad;

	if (p.origin == direkt_estructura_origen)
		localcmd(" echo DIREKT: PUERTA quieta");

	if (p.state != STATE_UP && p.state != STATE_TOP)
		localcmd(" echo DIREKT: PUERTA sin subir");

	if (p.state == STATE_UP && p.velocity == '0 0 0')
		localcmd(" echo DIREKT: PUERTA sin velocidad");

	if (p.state == STATE_TOP && p.origin != direkt_estructura_destino)
		localcmd(" echo DIREKT: PUERTA mal destino");

	if (p.state == STATE_UP || p.state == STATE_TOP)
		localcmd(" echo DIREKT: PUERTA abierta");

	self.think = direkt_estructura_boton;
	self.nextthink = time + 0.2;
};

// Fase 3: el boton. Se enciende con activator puesto, que es lo que haria el
// gatillo que lo activa.
void() direkt_estructura_boton =
{
	local entity t, o;
	o = self;

	direkt_estructura_entidad = world;
	t = world;
	do
	{
		t = find(t, classname, "func_button");
		if (!t)
			break;

		direkt_estructura_entidad = t;
		direkt_estructura_origen = t.origin;
		break;
	} while (1);

	if (!direkt_estructura_entidad)
	{
		localcmd(" echo DIREKT: BOTON ausente");
		self.think = direkt_estructura_plataforma;
		self.nextthink = time + 0.2;
		return;
	}

	activator = o;
	self = direkt_estructura_entidad;
	if (direkt_estructura_entidad.use)
		direkt_estructura_entidad.use();
	self = o;

	self.think = direkt_estructura_boton_mueve;
	self.nextthink = time + 0.5;
};

// Fase 4: el boton deberia estar saliendo hacia pos2 o ya arriba.
void() direkt_estructura_boton_mueve =
{
	local entity b;

	b = direkt_estructura_entidad;

	if (b.origin == b.pos2)
		localcmd(" echo DIREKT: BOTON en destino");
	else if (b.think == SUB_CalcMoveDone)
		localcmd(" echo DIREKT: BOTON moviendose");
	else if (b.state == STATE_BOTTOM && b.origin == direkt_estructura_origen)
		localcmd(" echo DIREKT: BOTON quieto");
	else
		localcmd(" echo DIREKT: BOTON parado");

	if (b.state != STATE_UP && b.state != STATE_TOP)
		localcmd(" echo DIREKT: BOTON sin subir");

	if (b.state != STATE_BOTTOM)
		localcmd(" echo DIREKT: BOTON pulsado");

	self.think = direkt_estructura_plataforma;
	self.nextthink = time + 0.2;
};

// Fase 5: la plataforma. No hay forma fiable de tirar de su gatillo interior en
// headless, asi que se llama al movimiento directamente: lo que importa es que
// el recorrido sale del "height" del mapa.
void() direkt_estructura_plataforma =
{
	local entity t, o;
	o = self;

	direkt_estructura_entidad = world;
	t = world;
	do
	{
		t = find(t, classname, "plat");
		if (!t)
			break;

		direkt_estructura_entidad = t;
		direkt_estructura_origen = t.origin;
		break;
	} while (1);

	if (!direkt_estructura_entidad)
	{
		localcmd(" echo DIREKT: PLAT ausente");
		self.think = direkt_estructura_fin;
		self.nextthink = time + 0.2;
		return;
	}

	self = direkt_estructura_entidad;
	direkt_plataforma_sube();
	self = o;

	self.think = direkt_estructura_plataforma_mueve;
	self.nextthink = time + 1.5;
};

// Fase 5b: la plataforma deberia estar arriba, en pos1, o haber vuelto a bajar.
void() direkt_estructura_plataforma_mueve =
{
	local entity p;

	p = direkt_estructura_entidad;

	if (p.origin == '0 0 0')
		localcmd(" echo DIREKT: PLAT en el origen");
	else if (p.enemy && p.enemy.classname == "plat")
		localcmd(" echo DIREKT: PLAT es el gatillo");
	else if (p.state == STATE_TOP && p.origin == p.pos1)
		localcmd(" echo DIREKT: PLAT correcta");
	else if (p.state == STATE_BOTTOM && p.origin == p.pos2)
		localcmd(" echo DIREKT: PLAT abajo ok");
	else if (p.state == STATE_TOP)
		localcmd(" echo DIREKT: PLAT mal destino");
	else if (p.origin == direkt_estructura_origen)
		localcmd(" echo DIREKT: PLAT sin mover");
	else
		localcmd(" echo DIREKT: PLAT a medio camino");

	self.think = direkt_estructura_fin;
	self.nextthink = time + 0.2;
};

void() direkt_estructura_fin =
{
	localcmd(" echo DIREKT: ESTRUCTURA lista");
};

// Punto de entrada: lo llama el prethink del jugador cuando llega el impulso.
void() direkt_estructura_test =
{
	direkt_estructura_entidad = world;
	self.think = direkt_estructura_cuenta;
	self.nextthink = time + 0.2;
};
