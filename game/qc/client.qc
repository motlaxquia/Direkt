// Direkt -- ciclo de vida del cliente.
//
// GPL-2.0, ver LICENSE en la raiz del repositorio.
//
// defs.qc declara estos nombres como "required prog functions". FTEQCC los
// reconoce y los engancha a las llamadas del motor, asi que tienen que existir
// TODOS: uno declarado y sin cuerpo se convierte en un puntero NULL y el motor
// aborta con "PR_ExecuteProgram: NULL function".
//
// IMPORTANTE -- quien hace la fisica es el MOTOR, no este codigo. Por frame de
// jugador, SV_Physics_Client (sv_phys.c) hace:
//
//     PlayerPreThink();            <- nosotros
//     SV_CheckVelocity();
//     switch (movetype) {
//       case MOVETYPE_WALK:       <- el motor, en este orden
//           SV_RunThink();
//           SV_CheckWater();      waterlevel y watertype
//           SV_AddGravity();      usa el campo .gravity como multiplicador
//           SV_CheckStuck();
//           SV_WalkMove();        friccion, aceleracion, colision, escalones
//     }
//     PlayerPostThink();           <- nosotros
//
// Y la intencion de movimiento (WASD) llega por SV_ReadClientMessage ->
// host_client->cmd, que es una estructura de C: QuakeC no la ve ni la puede
// escribir. Por eso este fichero NO toca velocity, ni origin, ni flags: si lo
// hace, pelea con el motor y el jugador se queda clavado, que es exactamente lo
// que hacia la primera version, que ponia velocity a cero y FL_ONGROUND en
// cada PostThink.

// La vida del jugador (DIREKT_MAX_HEALTH) esta definida al principio de
// defs.qc, como #define, para que la puedan usar client.qc y player.qc. Alli esta
// el motivo de que sea un #define y no una variable.

// El peso de la gravedad del jugador (DIREKT_GRAVITY_SCALE) esta en parkour.qc,
// que es el primer fichero de progs.src y el que lo usa para el planeo.

// ---------------------------------------------------------------- baggage
void() main =
{
	// FTEQCC la marca "only for testing". Se deja definida y vacia.
};

void() StartFrame =
{
	// Gancho por frame del motor, para armas y monsterios.
};

// Los parm son globales, no campos de entidad: asi los escribe el motor entre
// niveles.
void() SetNewParms =
{
	parm1 = DIREKT_MAX_HEALTH;	// health
	parm2 = 0;					// armor
	parm3 = 0;					// ammo1 (shells)
	parm4 = 0;					// ammo2 (nails)
	parm5 = 0;					// ammo3 (rockets)
	parm6 = 0;					// ammo4 (cells)
	parm7 = IT_AXE;				// weapon
	parm8 = 0;					// currentammo
	parm9 = IT_AXE;				// items
};

void() SetChangeParms =
{
	setspawnparms(self);
};

// ---------------------------------------------------------------- conexion
void() ClientConnect =
{
	// El motor llama a PutClientInServer; no hay nada que preparar antes.
};

void() ClientDisconnect =
{
};

void() ClientKill =
{
	// Suicidio: reaparicion inmediata.
	PutClientInServer();
};

// Busca punto de aparicion. En un mapa de campana hay uno; en los de muerte
// suelta hay varios info_player_deathmatch.
entity() direkt_busca_spawn =
{
	local entity spot;

	spot = find(world, classname, "info_player_start");
	if (spot)
		return spot;
	spot = find(world, classname, "info_player_deathmatch");
	if (spot)
		return spot;
	return find(world, classname, "info_player_start1");
};

void() PutClientInServer =
{
	local entity spot;
	local vector org;

	spot = direkt_busca_spawn();
	if (!spot)
		error("PutClientInServer: el mapa no tiene ningun punto de aparicion");

	self.classname = "player";
	self.health = DIREKT_MAX_HEALTH;
	self.max_health = DIREKT_MAX_HEALTH;
	// Sin armadura: si no, el primer toque se lo come la armadura antes de
	// que haga dano, y "un toque y muere" dejaria de ser cierto.
	self.armorvalue = 0;
	self.ammo_shells = 0;
	self.ammo_nails = 0;
	self.ammo_rockets = 0;
	self.ammo_cells = 0;
	self.takedamage = DAMAGE_AIM;
	self.deadflag = DEAD_NO;
	self.solid = SOLID_SLIDEBOX;
	self.movetype = MOVETYPE_WALK;
	self.flags = FL_CLIENT | FL_ONGROUND;
	self.waterlevel = 0;
	self.watertype = 0;	// defs.qc no trae los CONTENTS_*; el motor los pone al validar
	self.velocity = '0 0 0';
	self.effects = 0;
	self.punchangle = '0 0 0';
	self.fixangle = 1;
	self.frame = 0;

	// Sin esto SV_AddGravity lee gravity = 0 y el jugador flota. El motor lo
	// busca por nombre en tiempo de ejecucion, asi que basta con ponerlo.
	self.gravity = DIREKT_GRAVITY_SCALE;

	// Caja de colision estandar de Quake: 32 de ancho, 24 por debajo del
	// origen y 32 por encima. view_ofs situa el ojo 24 por encima del origen.
	setsize(self, '-16 -16 -24', '16 16 32');
	self.view_ofs = '0 0 24';

	// El punto de aparicion del mapa marca el origen del jugador. El motor
	// resuelve solo cualquier solapamiento (SV_CheckStuck), asi que basta con
	// subir un pelo para no empezar pegado al suelo.
	org = spot.origin + '0 0 1';
	setorigin(self, org);

	self.angles = spot.angles;
	self.v_angle = spot.angles;

	// Se empieza con el hacha. Las demas armas hay que recogerlas por el mapa,
	// que es lo que hacen los objetos de items.qc.
	self.items = IT_AXE;
	self.weapon = IT_AXE;
	self.currentammo = 0;
	self.ammo_shells = 0;
	self.ammo_nails = 0;
	self.ammo_rockets = 0;
	self.ammo_cells = 0;
	self.armortype = 0;
	self.attack_finished = 0;
	self.weaponframe = 0;

	// El modelo en mano y el tiempo de subida del arma. El motor dibuja
	// weaponmodel con weaponframe, asi que los dos hacen falta para que se vea
	// el arma en la pantalla.
	direkt_arma_poner(self);
	self.attack_finished = 0;

	direkt_jugador_entra();

	SetNewParms();
};

// ---------------------------------------------------------------- per frame
// Ver la nota de la cabecera: el motor ya ha hecho toda la fisica cuando
// PlayerPreThink se ejecuta en el frame siguiente. Aqui solo va lo que es
// codigo de juego y no fisica.
void() PlayerPreThink =
{
	direkt_prethink_jugador();
};

void() PlayerPostThink =
{
	direkt_postthink_jugador();
};
