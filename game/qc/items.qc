// Objetos que se recogen por el camino: salud, armadura, municion, armas,
// llaves y reliquias.
//
// El motor valida con un CRC la lista de campos de defs.qc, asi que aqui no se
// pueden anadir campos a las entidades. Cada objeto reaprovecha los campos que
// el resto del juego no usa:
//
//	self.health      tipo de objeto (DIRECTO_ITEM_*)
//	self.currentammo cantidad de salud o de municion que aporta
//	self.armorvalue  cantidad de armadura que aporta
//	self.sounds      que municion es: 0 perdigones, 1 clavos, 2 cohetes, 3 celdas
//	self.spawnflags  variante (1 pequeño o podrido, 2 grande o caja)
//	self.target      modelo guardado para reaparecer
//	self.weapon      bit de arma que enseña (IT_*), para las armas

float	DIREKT_ITEM_REAPARICION = 30;	// segundos hasta reaparecer

#define DIRECTO_ITEM_SALUD		1
#define DIRECTO_ITEM_ARMADURA	2
#define DIRECTO_ITEM_MUNICION	3
#define DIRECTO_ITEM_ARMA		4
#define DIRECTO_ITEM_LLAVE		5
#define DIRECTO_ITEM_RELIQUIA	6
#define DIRECTO_ITEM_MOCHILA	7

// El tamano de contacto es el mismo para todos los objetos: es lo que decide
// cuando se recogen, no lo que se ve.
// Tope de municion de cada tipo, como en el Quake original.
#define DIREKT_MUNICION_MAX_SHELLS	100
#define DIREKT_MUNICION_MAX_NAILS	200
#define DIREKT_MUNICION_MAX_ROCKETS	100
#define DIREKT_MUNICION_MAX_CELLS	100

// Caja de contacto: la misma que la de un jugador, centrada en el origen.
#define OBJETO_MIN '-16 -16 -24'
#define OBJETO_MAX '16 16 32'

void()		direkt_item_tocar;
void()		direkt_item_reaparecer;
void()		direkt_item_tomar;
void()		direkt_salud_coger;
void()		direkt_armadura_coger;
void()		direkt_municion_coger;
float(float bit)	direkt_arma_necesita;
void(entity jugador)	direkt_arma_coger_ammo;
void()		direkt_arma_coger;
void()		direkt_llave_coger;
void()		direkt_reliquia_coger;
void()		direkt_mochila_coger;
void(string modelo, float tipo, float cantidad) direkt_item_preparar;
void(entity jugador, float bit) direkt_arma_anadir;
void(entity jugador) direkt_reliquia_temporizadores;

//============================================================================
// BASE
//============================================================================

// Deja el objeto listo para cogerse: lo dibuja, lo hace sensible al contacto y
// programa su reaparicion.
void(string modelo, float tipo, float cantidad) direkt_item_preparar =
{
	// OJO: el motor solo mete una entidad en la lista de triggers cuando la
	// enlaza, y al enlazar se sale pronto si el solid sigue siendo SOLID_NOT.
	// Por eso el solid, el touch y el think se ponen ANTES de mover el origen;
	// si se hace al reves el objeto se ve pero no se puede recoger nunca.
	self.solid = SOLID_TRIGGER;
	self.movetype = MOVETYPE_NONE;
	self.touch = direkt_item_tocar;
	self.think = direkt_item_reaparecer;
	self.nextthink = time + DIREKT_ITEM_REAPARICION;

	// El modelo se guarda aparte porque al ocultarlo no se puede leer de
	// self.model.
	self.target = modelo;
	setmodel(self, modelo);

	self.health = tipo;
	self.currentammo = cantidad;

	setsize(self, OBJETO_MIN, OBJETO_MAX);
	setorigin(self, self.origin);
};

// Avisa al jugador de lo que se ha llevado. Cada objeto tiene su propio texto
// porque el motor no permite unir cadenas.
void() direkt_item_annadir =
{
	sound(other, CHAN_ITEM, "items/r_item1.wav", 1, ATTN_IDLE);
	if (self.sounds != 0)
		stuffcmd(other, "print \"Coges municion\\n\"\n");
	else
		stuffcmd(other, "print \"Lo recoges\\n\"\n");
};

// Guarda el objeto y programa su reaparicion. En cooperativo no reaparece:
// quien lo cogio se lo queda.
void() direkt_item_tomar =
{
	if (!deathmatch)
	{
		remove(self);
		return;
	}

	self.solid = SOLID_NOT;
	self.touch = direkt_nada;
	self.think = direkt_item_reaparecer;
	self.model = "";
	setsize(self, VEC_ORIGIN, VEC_ORIGIN);
	setorigin(self, self.origin);
	self.nextthink = time + DIREKT_ITEM_REAPARICION;
};

void() direkt_item_reaparecer =
{
	// Solo tiene que trabajar cuando el objeto esta escondido; si esta
	// visible no hay nada que reponer.
	if (self.model != "")
		return;

	self.solid = SOLID_TRIGGER;
	setmodel(self, self.target);
	setsize(self, OBJETO_MIN, OBJETO_MAX);
	self.touch = direkt_item_tocar;
	// El enlace final es lo que devuelve el objeto a la lista de triggers.
	setorigin(self, self.origin);
	self.nextthink = time + DIREKT_ITEM_REAPARICION;
};

// Unico punto de entrada: el motor llama aqui al cruzar el jugador con el
// objeto y esta funcion reparte segun el tipo.
void() direkt_item_tocar =
{
	if (other.classname != "player")
		return;
	if (other.health <= 0)
		return;

	if (self.health == DIRECTO_ITEM_SALUD)
		direkt_salud_coger();
	else if (self.health == DIRECTO_ITEM_ARMADURA)
		direkt_armadura_coger();
	else if (self.health == DIRECTO_ITEM_MUNICION)
		direkt_municion_coger();
	else if (self.health == DIRECTO_ITEM_ARMA)
		direkt_arma_coger();
	else if (self.health == DIRECTO_ITEM_LLAVE)
		direkt_llave_coger();
	else if (self.health == DIRECTO_ITEM_RELIQUIA)
		direkt_reliquia_coger();
	else if (self.health == DIRECTO_ITEM_MOCHILA)
		direkt_mochila_coger();
	else
		remove(self);
};

// Recorre todos los objetos del mapa y los prepara. Se llama desde el mundo.
void() direkt_items_iniciar =
{
	local entity e;

	e = find(world, classname, "direkt_item_pendiente");
	while (e)
	{
		e.nextthink = time + DIREKT_ITEM_REAPARICION;
		e = find(e, classname, "direkt_item_pendiente");
	}
};

//============================================================================
// SALUD
//============================================================================

// Se llama desde direkt_item_tocar con self = el botiquin y other = el jugador.
void() direkt_salud_coger =
{
	local float cure;

	// spawnflags: 1 = pequeño y podrido, 2 = el grande
	if (self.spawnflags & 1)
		cure = 15;
	else if (self.spawnflags & 2)
		cure = 100;
	else
		cure = 25;

	// Sanar de mas se desperdicia, asi que no se coge.
	if (other.health >= other.max_health)
	{
		if (cure < 100)
			return;
		if (other.health >= 100)
			return;
	}

	other.health = other.health + cure;
	if (other.health > other.max_health)
		other.health = other.max_health;

	sound(other, CHAN_ITEM, "items/health1.wav", 1, ATTN_NORM);
	stuffcmd(other, "print \"Coges un botiquin\\n\"\n");

	direkt_item_tomar();
};

// Los tres tamaños de botiquin, con su modelo y su sonido.
void() item_health =
{
	precache_model("maps/b_bh10.bsp");
	precache_model("maps/b_bh25.bsp");
	precache_model("maps/b_bh100.bsp");
	precache_sound("items/r_item1.wav");
	precache_sound("items/r_item2.wav");
	precache_sound("items/health1.wav");

	if (self.spawnflags & 1)
		direkt_item_preparar("maps/b_bh10.bsp", DIRECTO_ITEM_SALUD, 15);
	else if (self.spawnflags & 2)
		direkt_item_preparar("maps/b_bh100.bsp", DIRECTO_ITEM_SALUD, 100);
	else
		direkt_item_preparar("maps/b_bh25.bsp", DIRECTO_ITEM_SALUD, 25);

	self.noise = "items/health1.wav";
};

//(item_health_mega y item_health_rotten se.acceptan por comodidad del editor)
void() item_health_mega = { item_health(); };
void() item_health_rotten = { item_health(); };
void() item_health_big = { item_health(); };
void() item_health_small = { item_health(); };

//============================================================================
// ARMADURA
//============================================================================

void() direkt_armadura_coger =
{
	local float valor;

	// self.skin: 0 verde, 1 amarilla, 2 roja
	if (self.skin == 0)
		valor = 100;
	else if (self.skin == 1)
		valor = 150;
	else
		valor = 200;

	// La armadura verde solo se coge si mejora la que llevas.
	if (self.skin == 0)
	{
		if (other.armorvalue >= 100)
			return;
		other.armorvalue = 100;
		other.armortype = 0.3;
	}
	else if (self.skin == 1)
	{
		other.armorvalue = 150;
		other.armortype = 0.6;
	}
	else
	{
		other.armorvalue = 200;
		other.armortype = 0.8;
	}

	sound(other, CHAN_ITEM, "items/armor1.wav", 1, ATTN_NORM);
	stuffcmd(other, "print \"Coges una armadura\\n\"\n");

	direkt_item_tomar();
};

void() item_armor1 =
{
	precache_model("progs/armor.mdl");
	precache_sound("items/armor1.wav");

	direkt_item_preparar("progs/armor.mdl", DIRECTO_ITEM_ARMADURA, 100);
	self.skin = 0;
	self.noise = "items/armor1.wav";
};

void() item_armor2 =
{
	precache_model("progs/armor.mdl");
	precache_sound("items/armor1.wav");

	direkt_item_preparar("progs/armor.mdl", DIRECTO_ITEM_ARMADURA, 150);
	self.skin = 1;
	self.noise = "items/armor1.wav";
};

void() item_armorInv =
{
	precache_model("progs/armor.mdl");
	precache_sound("items/armor1.wav");

	direkt_item_preparar("progs/armor.mdl", DIRECTO_ITEM_ARMADURA, 200);
	self.skin = 2;
	self.noise = "items/armor1.wav";
};

void() item_armor =
{
	if (self.spawnflags == 1)
		item_armor2();
	else if (self.spawnflags == 2)
		item_armorInv();
	else
		item_armor1();
};

//============================================================================
// MUNICION
//============================================================================

void() direkt_municion_coger =
{
	// self.sounds dice que municion es: 0 perdigones, 1 clavos, 2 cohetes,
	// 3 celdas. self.currentammo lleva la cantidad.
	if (self.sounds == 0)
	{
		if (other.currentammo >= 100)
			return;
		other.currentammo = other.currentammo + self.currentammo;
		other.items = other.items | IT_SHELLS;
	}
	else if (self.sounds == 1)
	{
		if (other.currentammo >= 200)
			return;
		other.currentammo = other.currentammo + self.currentammo;
		other.items = other.items | IT_NAILS;
	}
	else if (self.sounds == 2)
	{
		if (other.currentammo >= 100)
			return;
		other.currentammo = other.currentammo + self.currentammo;
		other.items = other.items | IT_ROCKETS;
	}
	else
	{
		if (other.currentammo >= 100)
			return;
		other.currentammo = other.currentammo + self.currentammo;
		other.items = other.items | IT_CELLS;
	}

	sound(other, CHAN_ITEM, "weapons/lock4.wav", 1, ATTN_NORM);
	stuffcmd(other, "print \"Coges municion\\n\"\n");

	direkt_item_tomar();
};

void() item_shells =
{
	precache_model("maps/b_shell0.bsp");
	precache_model("maps/b_shell1.bsp");
	precache_sound("weapons/lock4.wav");

	// spawnflags 1 = la caja grande
	if (self.spawnflags & 1)
		direkt_item_preparar("maps/b_shell0.bsp", DIRECTO_ITEM_MUNICION, 20);
	else
		direkt_item_preparar("maps/b_shell1.bsp", DIRECTO_ITEM_MUNICION, 5);

	self.sounds = 0;
	self.noise = "weapons/lock4.wav";
};

void() item_spikes =
{
	precache_model("maps/b_nail0.bsp");
	precache_model("maps/b_nail1.bsp");
	precache_sound("weapons/lock4.wav");

	if (self.spawnflags & 1)
		direkt_item_preparar("maps/b_nail0.bsp", DIRECTO_ITEM_MUNICION, 25);
	else
		direkt_item_preparar("maps/b_nail1.bsp", DIRECTO_ITEM_MUNICION, 5);

	self.sounds = 1;
	self.noise = "weapons/lock4.wav";
};

void() item_rockets =
{
	precache_model("maps/b_rock0.bsp");
	precache_model("maps/b_rock1.bsp");
	precache_sound("weapons/lock4.wav");

	if (self.spawnflags & 1)
		direkt_item_preparar("maps/b_rock0.bsp", DIRECTO_ITEM_MUNICION, 5);
	else
		direkt_item_preparar("maps/b_rock1.bsp", DIRECTO_ITEM_MUNICION, 1);

	self.sounds = 2;
	self.noise = "weapons/lock4.wav";
};

void() item_cells =
{
	precache_model("maps/b_batt0.bsp");
	precache_model("maps/b_batt1.bsp");
	precache_sound("weapons/lock4.wav");

	if (self.spawnflags & 1)
		direkt_item_preparar("maps/b_batt1.bsp", DIRECTO_ITEM_MUNICION, 12);
	else
		direkt_item_preparar("maps/b_batt0.bsp", DIRECTO_ITEM_MUNICION, 6);

	self.sounds = 3;
	self.noise = "weapons/lock4.wav";
};

//============================================================================
// ARMAS
//============================================================================

void() direkt_arma_coger =
{
	// self.weapon lleva el bit IT_* del arma, ya guardado por el objeto.
	if (other.items & self.weapon)
		return;

	direkt_arma_anadir(other, self.weapon);
	stuffcmd(other, "print \"Coges un arma nueva\\n\"\n");

	direkt_item_tomar();
};

// Las seis armas del juego. El modelo en mano lo pone el jugador al cambiar a
// esa arma, no el objeto.
void() weapon_axe =
{
	precache_model("progs/axe.mdl");

	// El hacha se lleva siempre; el motor lo dibuja en la mano desde el
	// principio, asi que el objeto solo hace ruido.
	self.solid = SOLID_NOT;
	remove(self);
};

void() weapon_shotgun =
{
	precache_model("progs/g_shot1.mdl");
	precache_model("progs/v_shot.mdl");

	direkt_item_preparar("progs/g_shot1.mdl", DIRECTO_ITEM_ARMA, 0);
	self.weapon = IT_SHOTGUN;
};

void() weapon_supershotgun =
{
	precache_model("progs/g_shot.mdl");
	precache_model("progs/v_shot2.mdl");

	direkt_item_preparar("progs/g_shot.mdl", DIRECTO_ITEM_ARMA, 0);
	self.weapon = IT_SUPER_SHOTGUN;
};

void() weapon_nailgun =
{
	precache_model("progs/g_nail.mdl");
	precache_model("progs/v_nail.mdl");

	direkt_item_preparar("progs/g_nail.mdl", DIRECTO_ITEM_ARMA, 0);
	self.weapon = IT_NAILGUN;
};

void() weapon_supernailgun =
{
	precache_model("progs/g_nail2.mdl");
	precache_model("progs/v_nail2.mdl");

	direkt_item_preparar("progs/g_nail2.mdl", DIRECTO_ITEM_ARMA, 0);
	self.weapon = IT_SUPER_NAILGUN;
};

void() weapon_grenadelauncher =
{
	precache_model("progs/g_rock.mdl");
	precache_model("progs/v_rock.mdl");

	direkt_item_preparar("progs/g_rock.mdl", DIRECTO_ITEM_ARMA, 0);
	self.weapon = IT_GRENADE_LAUNCHER;
};

void() weapon_rocketlauncher =
{
	precache_model("progs/g_rock2.mdl");
	precache_model("progs/v_rock2.mdl");

	direkt_item_preparar("progs/g_rock2.mdl", DIRECTO_ITEM_ARMA, 0);
	self.weapon = IT_ROCKET_LAUNCHER;
};

void() weapon_lightning =
{
	precache_model("progs/g_light.mdl");
	precache_model("progs/v_light.mdl");

	direkt_item_preparar("progs/g_light.mdl", DIRECTO_ITEM_ARMA, 0);
	self.weapon = IT_LIGHTNING;
};

//============================================================================
// LLAVES
//============================================================================

void() direkt_llave_coger =
{
	if (self.sounds == 1)
	{
		if (other.items & IT_KEY2)
			return;
		other.items = other.items | IT_KEY2;
		stuffcmd(other, "print \"Coges la llave de oro\\n\"\n");
	}
	else
	{
		if (other.items & IT_KEY1)
			return;
		other.items = other.items | IT_KEY1;
		stuffcmd(other, "print \"Coges la llave de plata\\n\"\n");
	}

	sound(other, CHAN_ITEM, "items/key.wav", 1, ATTN_NORM);

	direkt_item_tomar();
};

void() item_key1 =
{
	precache_model("progs/m_s_key.mdl");
	precache_model("progs/w_s_key.mdl");
	precache_sound("items/key.wav");

	direkt_item_preparar("progs/m_s_key.mdl", DIRECTO_ITEM_LLAVE, 0);
	self.sounds = 0;
	self.noise = "items/key.wav";
};

void() item_key2 =
{
	precache_model("progs/m_g_key.mdl");
	precache_model("progs/w_g_key.mdl");
	precache_sound("items/key.wav");

	direkt_item_preparar("progs/m_g_key.mdl", DIRECTO_ITEM_LLAVE, 0);
	self.sounds = 1;
	self.noise = "items/key.wav";
};

// Las puertas de llave en LibreQuake usan la funcion generica.
void() key = { item_key1(); };

//============================================================================
// RELIQUIAS
//============================================================================

void() direkt_reliquia_coger =
{
	// self.sounds dice cual es: 0 invisible, 1 invulnerable, 2 traje, 3 cuadruplo
	if (self.sounds == 0)
	{
		other.items = other.items | IT_INVISIBILITY;
		stuffcmd(other, "print \"Coges la reliquia de invisibilidad\\n\"\n");
	}
	else if (self.sounds == 1)
	{
		other.items = other.items | IT_INVULNERABILITY;
		stuffcmd(other, "print \"Coges la reliquia de invulnerabilidad\\n\"\n");
	}
	else if (self.sounds == 2)
	{
		other.items = other.items | IT_SUIT;
		stuffcmd(other, "print \"Coges el traje sumergible\\n\"\n");
	}
	else
	{
		other.items = other.items | IT_QUAD;
		stuffcmd(other, "print \"Coges la reliquia de dano cuadruplo\\n\"\n");
	}

	sound(other, CHAN_ITEM, "items/suit.wav", 1, ATTN_NORM);
	direkt_reliquia_temporizadores(other);

	direkt_item_tomar();
};

void() item_artifact_invisibility =
{
	precache_model("progs/invisibl.mdl");
	precache_sound("items/suit.wav");

	direkt_item_preparar("progs/invisibl.mdl", DIRECTO_ITEM_RELIQUIA, 0);
	self.sounds = 0;
	self.noise = "items/suit.wav";
};

void() item_artifact_invulnerability =
{
	precache_model("progs/invulner.mdl");
	precache_sound("items/suit.wav");

	direkt_item_preparar("progs/invulner.mdl", DIRECTO_ITEM_RELIQUIA, 0);
	self.sounds = 1;
	self.noise = "items/suit.wav";
};

void() item_artifact_envirosuit =
{
	precache_model("progs/suit.mdl");
	precache_sound("items/suit.wav");

	direkt_item_preparar("progs/suit.mdl", DIRECTO_ITEM_RELIQUIA, 0);
	self.sounds = 2;
	self.noise = "items/suit.wav";
};

void() item_artifact_super_damage =
{
	precache_model("progs/quaddama.mdl");
	precache_sound("items/suit.wav");

	direkt_item_preparar("progs/quaddama.mdl", DIRECTO_ITEM_RELIQUIA, 0);
	self.sounds = 3;
	self.noise = "items/suit.wav";
};

void() item_artifact = { item_artifact_super_damage(); };

//============================================================================
// MOCHILA
//============================================================================

void() direkt_mochila_coger =
{
	// La mochila sube el maximo de cada tipo de municion.
	if (other.max_health < 200)
		other.max_health = 200;

	if (other.currentammo < 100)
		other.currentammo = 100;

	other.items = other.items | IT_SHELLS | IT_NAILS | IT_ROCKETS | IT_CELLS;

	sound(other, CHAN_ITEM, "weapons/lock4.wav", 1, ATTN_NORM);
	stuffcmd(other, "print \"Coges la mochila\\n\"\n");

	direkt_item_tomar();
};

void() item_backpack =
{
	precache_model("progs/backpack.mdl");
	precache_sound("weapons/lock4.wav");

	direkt_item_preparar("progs/backpack.mdl", DIRECTO_ITEM_MOCHILA, 0);
	self.noise = "weapons/lock4.wav";
};
