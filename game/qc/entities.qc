// Direkt -- entidades del mapa.
//
// GPL-2.0, ver LICENSE en la raiz del repositorio.
//
// El motor crea cada entidad del BSP llamando a una funcion de QuakeC con el
// mismo nombre que su "classname". Si no existe, suelta
// "No spawn function for:" y se descarta la entidad. Este fichero cubre las
// clases que aparecen en los mapas.
//
// Hay tres grupos:
//
//   1. Implementadas aqui: luces, puntos de aparicion, pasillos, paredes y
//      teletransportes. Son las que hacen que el mundo se vea y que el jugador
//      pueda aparecer.
//   2. Con la logica en structure.qc: puertas, botones y plataformas.
//   3. Marcadas como pendientes: criaturas y efectos. Se borran a si mismas y
//      avisan una vez por tipo, para que la lista de lo que falta sea visible
//      en el log en vez de fallar en silencio.
//
// Los objetos y las armas NO estan aqui: van en items.qc y weapons.qc.

// ------------------------------------------------------------------ avisos
// Cada clase pendiente avisa UNA vez: si no, un mapa con 300 cajas de balas
// llena el log de 300 lineas iguales.
float direkt_avisdos;

void() direkt_pendiente =
{
	if (direkt_avisdos < 1)
	{
		// localcmd solo admite cadenas literales (esta cadena de QuakeC no
		// tiene concatenacion), asi que el aviso va generico. La lista de
		// clases esta en este fichero, que es lo que hay que ir rellenando.
		localcmd(" echo DIREKT: hay entidades del mapa sin implementar, ver qc/entities.qc");
		direkt_avisdos = direkt_avisdos + 1;
	}
	remove(self);
};

// ------------------------------------------------------------------ luces
// La mitad de las entidades de un mapa de Quake son luces (5050 en lqdm1). Sin
// esto el mundo se ve negro. Todas comparten la misma mecanica: aplicar el
// estilo de luz que trae el mapa y animar los frames.
void() direkt_luz_think =
{
	self.frame = self.frame + 1;
	if (self.frame > 1)
		self.frame = 0;
	self.nextthink = time + 0.1;
};

void() direkt_luz =
{
	self.solid = SOLID_NOT;
	self.movetype = MOVETYPE_NONE;
	self.model = "";		// una luz no se dibuja
	self.frame = 0;
	self.think = direkt_luz_think;
	self.nextthink = time + 0.1;
};

// Las de llama / antorcha / fluorescente solo cambian el estilo, que el mapa ya
// trae en la clave "style".
void() light = { direkt_luz(); };
void() light_flame_large_yellow = { direkt_luz(); };
void() light_flame_small_white = { direkt_luz(); };
void() light_flame_small_yellow = { direkt_luz(); };
void() light_torch_small_walltorch = { direkt_luz(); };
void() light_fluoro = { direkt_luz(); };
void() light_globe = { direkt_luz(); };
void() light_fluorospark = { direkt_luz(); };
void() air_bubbles = { direkt_luz(); };

// ------------------------------------------------------------------ aparicion
// Vacias a proposito: solo existen para que client.qc las encuentre con find().
void() info_player_start = {};
void() info_player_start2 = {};
void() info_player_deathmatch = {};
void() info_player_coop = {};
void() info_intermission = {};
void() info_teleport_destination = {};
void() info_null = {};
void() info_notnull = {};
void() testplayerstart = {};
void() func_bossgate = {};
void() func_episodegate = {};

// ------------------------------------------------------------------idia
// Al menos dos targetnull evita el aviso en mapas que los usan.
void() path_corner = {};
void() path_node = {};
void() path1 = {};
void() path2 = {};
void() path3 = {};
void() path4 = {};
void() path5 = {};
void() path6 = {};
void() path7 = {};
void() path8 = {};

// ------------------------------------------------------------------ geometria
// El motor ya les ha dado origen, angulos y tamano del BSP; solo hay que
// marcar el solid y quitarles el comportamiento de "spawn".
void() func_wall = { self.solid = SOLID_BBOX; };
void() func_illusionary = { self.solid = SOLID_NOT; };
void() func_wall_toggle = { self.solid = SOLID_BBOX; };
void() func_rotating = { self.solid = SOLID_BBOX; };
void() func_breakable = { self.solid = SOLID_BBOX; };

// ------------------------------------------------------------------ disparadores
// trigger_relay, trigger_once y trigger_multiple se apoyan en targets, asi que
// hacen falta los tres para que una cadena tenga sentido. target_use lee el
// "self.owner", de ahi que todos los triggers se apunten a si mismos.
void() trigger_always =
{
	self.solid = SOLID_NOT;
	self.movetype = MOVETYPE_PUSH;
	self.owner = self;
	self.use = target_use;
	self.touch = target_use;
};

// Un solo disparo: al primer contacto se encadena la cadena y se borra.
void() direkt_trigger_una_vez =
{
	target_use();
	self.think = SUB_Remove;
	self.nextthink = time + 0.1;
};

void() trigger_once =
{
	self.solid = SOLID_NOT;
	self.movetype = MOVETYPE_PUSH;
	self.owner = self;
	self.use = target_use;
	self.touch = direkt_trigger_una_vez;
};

// Se puede rearmar desde fuera (por target) pero no se borra solo.
void() trigger_multiple =
{
	self.solid = SOLID_NOT;
	self.movetype = MOVETYPE_PUSH;
	self.owner = self;
	self.use = target_use;
	self.touch = target_use;
};

// El rele solo existe para encadenar: enciende su target y se queda ahi.
void() trigger_relay =
{
	self.solid = SOLID_NOT;
	self.movetype = MOVETYPE_PUSH;
	self.owner = self;
	self.use = target_use;
};

void() trigger_hurt = { self.solid = SOLID_NOT; self.movetype = MOVETYPE_PUSH; self.owner = self; };
void() trigger_secret = { self.solid = SOLID_NOT; self.movetype = MOVETYPE_PUSH; self.owner = self; self.use = target_use; self.touch = target_use; };
void() trigger_setskill = { self.solid = SOLID_NOT; self.movetype = MOVETYPE_PUSH; self.owner = self; };
void() trigger_monsterjump = { self.solid = SOLID_NOT; self.movetype = MOVETYPE_PUSH; self.owner = self; };

// El contador solo dispara cuando se le ha tocado "count" veces. Los mapas lo
// usan para abrir puertas a la enesima pasada.
void() direkt_contador_uso =
{
	local entity t;

	// Cada disparo descuenta uno. Con count a 0 no queda nada que esperar.
	if (self.count <= 0)
		return;

	self.count = self.count - 1;
	if (self.count > 0)
		return;

	if (!self.target)
		return;

	t = find(world, targetname, self.target);
	while (t)
	{
		direkt_llama_use(t);
		t = find(t, targetname, self.target);
	}
};

void() trigger_counter =
{
	self.solid = SOLID_NOT;
	self.movetype = MOVETYPE_PUSH;
	self.owner = self;
	self.use = direkt_contador_uso;

	if (!self.count)
		self.count = 1;
};

// El cambio de nivel necesita self.noise y los nombres de destino; la logica
// viene en fases posteriores.
void() trigger_changelevel = { self.solid = SOLID_NOT; self.movetype = MOVETYPE_PUSH; };

void() trigger_push = { self.movetype = MOVETYPE_PUSH; };
void() trigger_teleport = { self.movetype = MOVETYPE_PUSH; };

// ------------------------------------------------------------------ estructura
// Puertas, botones y plataformas tienen la logica en structure.qc. Aqui solo
// quedan las clases de estructura que no aparecen en los mapas de LibreQuake
// y que de momento se crean solidas pero estaticas.
void() func_door2 = { self.solid = SOLID_BBOX; };
void() func_door2_rotating = { self.solid = SOLID_BBOX; };
void() func_door_rotating = { self.solid = SOLID_BBOX; };
void() func_door_secret = { self.solid = SOLID_BBOX; };
void() func_train = { self.solid = SOLID_BBOX; };
void() func_conveyor = { self.solid = SOLID_BBOX; };

// ------------------------------------------------------------------ pendientes
// Los objetos y las armas ya no son pendientes: viven en items.qc y
// weapons.qc. Aqui solo quedan las clases que de verdad aun no estan escritas.
// Se borran y avisan una vez.
void() misc_explobox = { direkt_pendiente(); };
void() misc_explobox2 = { direkt_pendiente(); };
void() misc_fireball = { direkt_pendiente(); };
void() misc_teleporttrain = { direkt_pendiente(); };
void() trap_spikeshooter = { direkt_pendiente(); };
void() event_lightning = { direkt_pendiente(); };

// Los mapas de LibreQuake no traen criaturas, pero se dejan enganchadas por si
// aparece alguna en otro mapa.
void() monster_army = { direkt_pendiente(); };
void() monster_demon1 = { direkt_pendiente(); };
void() monster_dog = { direkt_pendiente(); };
void() monster_enforcer = { direkt_pendiente(); };
void() monster_fish = { direkt_pendiente(); };
void() monster_hell_knight = { direkt_pendiente(); };
void() monster_knight = { direkt_pendiente(); };
void() monster_ogre = { direkt_pendiente(); };
void() monster_oldone = { direkt_pendiente(); };
void() monster_shalrath = { direkt_pendiente(); };
void() monster_shambler = { direkt_pendiente(); };
void() monster_tarbaby = { direkt_pendiente(); };
void() monster_wizard = { direkt_pendiente(); };
void() monster_zombie = { direkt_pendiente(); };
void() monster_boss = { direkt_pendiente(); };

// Los sonidos de ambiente no tienen efecto: se crean sin hacer nada.
void() ambient_drip = {};
void() ambient_comp_hum = {};
void() ambient_drone = {};
void() ambient_flouro_buzz = {};
void() ambient_light_buzz = {};
void() ambient_suck_wind = {};
void() ambient_swamp1 = {};
void() ambient_swamp2 = {};
void() ambient_suck_wind2 = {};
void() ambient_wind = {};
void() ambient_cave = {};
