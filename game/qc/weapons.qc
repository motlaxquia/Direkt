// Las armas del jugador: cambiar de arma, disparar, y los proyectiles que
// deja en el aire.
//
// El motor no deja anadir campos a las entidades, asi que el estado de cada
// jugador vive en los campos estandar:
//
//	self.weapon          bit IT_* del arma en la mano
//	self.weaponframe     fotograma del modelo en mano (lo dibuja el motor)
//	self.attack_finished momento en que se puede volver a disparar
//	self.think/nextthink animacion del arma y avisos de reliquias
//
// En los proyectiles se reaprovechan campos que no usan para nada:
//	self.dmg_take    dano directo
//	self.dmg_save    radio de la explosion
//	self.attack_state que tipo de proyectil es

void()	direkt_arma_disparar;
void()	direkt_arma_animar;
void()	direkt_arma_al_disparar;
void(entity jugador)	direkt_arma_coger_ammo;
void(entity jugador)	direkt_arma_poner;
void()	direkt_arma_restar;
void(entity jugador) direkt_reliquia_temporizadores;
void(vector fin, entity golpeado, float dano) direkt_rayo_impacto;
void()	direkt_clavo_tocar;
void()	direkt_proyectil_tocar;
void()	direkt_proyectil_desaparecer;
void(entity jugador, float bit) direkt_arma_anadir;
void()	direkt_arma_hacha;
void()	direkt_arma_granada;
void()	direkt_arma_cohete;
void()	direkt_arma_rayo;

void()	direkt_chispa_desaparecer;
void()	direkt_clavo_desaparecer;
void()	direkt_clavo_tocar;
void(vector pos, vector dir, entity dueno, float velocidad) direkt_clavo_lanzar;
void(vector pos, float dano, float radio, entity agresor) direkt_explotar;
void(entity objetivo, entity agresor, float dano) direkt_danio;
float()	direkt_apuntar;
void(float bit, entity jugador) direkt_arma_cambiar;
void(float perdigones) direkt_arma_escopeta;
void(float clavos, float velocidad) direkt_arma_clavos;
void(vector pos, vector dir, float velocidad, string mdl, float dano,
	float radio, entity dueno) direkt_proyectil;
void(vector pos, float dano, float radio, entity agresor) direkt_explotar;
void(float dano, float radio, entity agresor) direkt_dano_radio;

//============================================================================
// TABLAS DE LAS ARMAS
//============================================================================

// Numero de fotogramas con los que animate cada arma. El motor recorta el
// fotograma si el modelo tiene menos, asi que van holgados a proposito.
float(float arma) direkt_arma_fotogramas =
{
	if (arma == IT_AXE)				return 6;
	if (arma == IT_SHOTGUN)			return 5;
	if (arma == IT_SUPER_SHOTGUN)	return 7;
	if (arma == IT_NAILGUN)			return 4;
	if (arma == IT_SUPER_NAILGUN)	return 6;
	if (arma == IT_GRENADE_LAUNCHER)	return 5;
	if (arma == IT_ROCKET_LAUNCHER)	return 7;
	if (arma == IT_LIGHTNING)		return 4;
	return 1;
};

// Tiempo que se tarda en volver a disparar con cada arma.
float(float arma) direkt_arma_cadencia =
{
	if (arma == IT_AXE)				return 0.8;
	if (arma == IT_SHOTGUN)			return 0.6;
	if (arma == IT_SUPER_SHOTGUN)	return 0.6;
	if (arma == IT_NAILGUN)			return 0.15;
	if (arma == IT_SUPER_NAILGUN)	return 0.1;
	if (arma == IT_GRENADE_LAUNCHER)	return 0.6;
	if (arma == IT_ROCKET_LAUNCHER)	return 0.8;
	if (arma == IT_LIGHTNING)		return 0.05;
	return 0.3;
};

// Modelo que se dibuja en la mano con cada arma.
string(float arma) direkt_arma_modelo =
{
	if (arma == IT_AXE)				return "progs/v_axe.mdl";
	if (arma == IT_SHOTGUN)			return "progs/v_shot.mdl";
	if (arma == IT_SUPER_SHOTGUN)	return "progs/v_shot2.mdl";
	if (arma == IT_NAILGUN)			return "progs/v_nail.mdl";
	if (arma == IT_SUPER_NAILGUN)	return "progs/v_nail2.mdl";
	if (arma == IT_GRENADE_LAUNCHER)	return "progs/v_rock.mdl";
	if (arma == IT_ROCKET_LAUNCHER)	return "progs/v_rock2.mdl";
	if (arma == IT_LIGHTNING)		return "progs/v_light.mdl";
	return "progs/v_axe.mdl";
};

// Que bit de municion gasta cada arma.
// Que armas pueden usar un tipo de municion. Se usa para no darle al jugador
// municion de un arma que no tiene: la caja se queda en el suelo.
float(float bit) direkt_arma_necesita =
{
	if (bit == IT_SHELLS)
		return IT_SHOTGUN | IT_SUPER_SHOTGUN;
	if (bit == IT_NAILS)
		return IT_NAILGUN | IT_SUPER_NAILGUN;
	if (bit == IT_ROCKETS)
		return IT_GRENADE_LAUNCHER | IT_ROCKET_LAUNCHER;
	if (bit == IT_CELLS)
		return IT_LIGHTNING;
	return 0;
};

float(float arma) direkt_arma_municion =
{
	if (arma == IT_SHOTGUN)			return IT_SHELLS;
	if (arma == IT_SUPER_SHOTGUN)	return IT_SHELLS;
	if (arma == IT_NAILGUN)			return IT_NAILS;
	if (arma == IT_SUPER_NAILGUN)	return IT_NAILS;
	if (arma == IT_GRENADE_LAUNCHER)	return IT_ROCKETS;
	if (arma == IT_ROCKET_LAUNCHER)	return IT_ROCKETS;
	if (arma == IT_LIGHTNING)		return IT_CELLS;
	return 0;
};

//============================================================================
// ELEGIR Y CAMBIAR DE ARMA
//============================================================================

// Cambia el modelo en mano y programa la subida del arma. self = jugador.
void(entity jugador) direkt_arma_poner =
{
	// OJO: precache_model solo funciona dentro de una funcion de spawn, y aqui
	// no se puede llamar. Los modelos se precargan en direkt_precache_assets,
	// que corre desde worldspawn.
	jugador.weaponmodel = direkt_arma_modelo(jugador.weapon);
	jugador.weaponframe = 0;
	jugador.attack_finished = time + 0.3;
	jugador.punchangle_y = -0.5;

	// El arma en la mano cambia, asi que el contador del HUD y el disparador
	// tienen que pasar al cubo de ESTE arma. Sin esto, cambiar a un arma sin
	// municion dejaba el numero de la anterior: el HUD mentia y, peor, la
	// comprobacion de "queda municion" daba por bueno un disparo vacio.
	direkt_arma_coger_ammo(jugador);
};

// El jugador ha cogido un arma: se anade a su inventario y se equipa si no
// llevaba arma en la mano.
void(entity jugador, float bit) direkt_arma_anadir =
{
	// El hacha no se recoge, se empieza con ella.
	if (bit == IT_AXE)
		return;

	// Que el arma ya este en el inventario NO es motivo para dejar el objeto
	// en el mapa: la municion se entrega igual y el objeto se recoge. Solo
	// cambia que no se vuelve a sacar el arma en la mano.
	local float nueva;
	nueva = !(jugador.items & bit);

	// Cada arma viene con un poco de municion para poder usarla al instante.
	// OJO: esto va al cubo del arma, no a currentammo, que es el del arma que
	// esta en la mano. Meterlo en currentammo hacia que dos armas distintas
	// compartieran la misma municion.
	if (bit == IT_SHOTGUN)			jugador.ammo_shells = jugador.ammo_shells + 8;
	if (bit == IT_SUPER_SHOTGUN)	jugador.ammo_shells = jugador.ammo_shells + 8;
	if (bit == IT_NAILGUN)			jugador.ammo_nails = jugador.ammo_nails + 30;
	if (bit == IT_SUPER_NAILGUN)	jugador.ammo_nails = jugador.ammo_nails + 30;
	if (bit == IT_GRENADE_LAUNCHER)	jugador.ammo_rockets = jugador.ammo_rockets + 5;
	if (bit == IT_ROCKET_LAUNCHER)	jugador.ammo_rockets = jugador.ammo_rockets + 5;
	if (bit == IT_LIGHTNING)		jugador.ammo_cells = jugador.ammo_cells + 15;

	jugador.items = jugador.items | bit | direkt_arma_municion(bit);

	// Con el hacha en la mano se cambia al arma nueva; con otra ya no.
	if (nueva && (jugador.weapon == IT_AXE || jugador.weapon == 0))
		direkt_arma_cambiar(bit, jugador);
};

// Cambia el arma en la mano. No se puede si el arma esta ocupada.
void(float bit, entity jugador) direkt_arma_cambiar =
{
	if (jugador.items & bit == 0)
		return;
	if (time < jugador.attack_finished)
		return;

	// La escopeta normal no se vuelve si ya se coge la superescopeta.
	if (bit == IT_SHOTGUN && jugador.items & IT_SUPER_SHOTGUN)
		return;
	if (bit == IT_NAILGUN && jugador.items & IT_SUPER_NAILGUN)
		return;

	jugador.weapon = bit;
	direkt_arma_poner(jugador);
	sound(jugador, CHAN_WEAPON, "weapons/lock4.wav", 0.5, ATTN_IDLE);
};

// Los numeros del 1 al 4 eligen arma, el 8 es el hacha.
void() direkt_impulso =
{
	local float numero;

	numero = self.impulse;

	if (numero == 1)
	{
		if (self.items & IT_SUPER_SHOTGUN)
			direkt_arma_cambiar(IT_SUPER_SHOTGUN, self);
		else if (self.items & IT_SHOTGUN)
			direkt_arma_cambiar(IT_SHOTGUN, self);
	}
	else if (numero == 2)
	{
		if (self.items & IT_GRENADE_LAUNCHER)
			direkt_arma_cambiar(IT_GRENADE_LAUNCHER, self);
		else if (self.items & IT_ROCKET_LAUNCHER)
			direkt_arma_cambiar(IT_ROCKET_LAUNCHER, self);
	}
	else if (numero == 3)
	{
		if (self.items & IT_SUPER_NAILGUN)
			direkt_arma_cambiar(IT_SUPER_NAILGUN, self);
		else if (self.items & IT_NAILGUN)
			direkt_arma_cambiar(IT_NAILGUN, self);
	}
	else if (numero == 4)
	{
		if (self.items & IT_LIGHTNING)
			direkt_arma_cambiar(IT_LIGHTNING, self);
	}
	else if (numero == 8)
	{
		direkt_arma_cambiar(IT_AXE, self);
	}

	self.impulse = 0;
};

// Rellena la municion cuando el jugador se queda sin ella. Cada arma tiene su
// recarga minima, como en Quake.
// Pasa el cubo del arma que esta en la mano a currentammo, que es lo que
// gastan los disparos y lo que enseña el HUD.
void(entity jugador) direkt_arma_coger_ammo =
{
	if (jugador.weapon == IT_SHOTGUN || jugador.weapon == IT_SUPER_SHOTGUN)
		jugador.currentammo = jugador.ammo_shells;
	else if (jugador.weapon == IT_NAILGUN || jugador.weapon == IT_SUPER_NAILGUN)
		jugador.currentammo = jugador.ammo_nails;
	else if (jugador.weapon == IT_GRENADE_LAUNCHER || jugador.weapon == IT_ROCKET_LAUNCHER)
		jugador.currentammo = jugador.ammo_rockets;
	else if (jugador.weapon == IT_LIGHTNING)
		jugador.currentammo = jugador.ammo_cells;
	else
		jugador.currentammo = 0;
};

// Saca la municion que se acaba de gastar.
void() direkt_arma_restar =
{
	if (self.weapon == IT_SHOTGUN || self.weapon == IT_SUPER_SHOTGUN)
		self.ammo_shells = self.ammo_shells - 1;
	else if (self.weapon == IT_NAILGUN || self.weapon == IT_SUPER_NAILGUN)
		self.ammo_nails = self.ammo_nails - 1;
	else if (self.weapon == IT_GRENADE_LAUNCHER || self.weapon == IT_ROCKET_LAUNCHER)
		self.ammo_rockets = self.ammo_rockets - 1;
	else if (self.weapon == IT_LIGHTNING)
		self.ammo_cells = self.ammo_cells - 1;

	direkt_arma_coger_ammo(self);
};

//============================================================================
// DISPARO
//============================================================================

// Unico sitio desde el que se dispara. self = jugador.
void() direkt_arma_disparar =
{
	if (self.weaponframe)
		return;						// el arma sigue en animacion
	if (time < self.attack_finished)
		return;

	// El hacha no gasta municion.
	if (direkt_arma_municion(self.weapon) && self.currentammo < 1)
		return;

	self.weaponframe = 1;
	self.think = direkt_arma_animar;
	self.nextthink = time + 0.02;
	self.attack_finished = time + direkt_arma_cadencia(self.weapon);

	if (self.weapon == IT_AXE)
		direkt_arma_hacha();
	else if (self.weapon == IT_SHOTGUN)
		direkt_arma_escopeta(10);
	else if (self.weapon == IT_SUPER_SHOTGUN)
		direkt_arma_escopeta(20);
	else if (self.weapon == IT_NAILGUN)
		direkt_arma_clavos(8, 1000);
	else if (self.weapon == IT_SUPER_NAILGUN)
		direkt_arma_clavos(12, 1000);
	else if (self.weapon == IT_GRENADE_LAUNCHER)
		direkt_arma_granada();
	else if (self.weapon == IT_ROCKET_LAUNCHER)
		direkt_arma_cohete();
	else if (self.weapon == IT_LIGHTNING)
		direkt_arma_rayo();
};

// Vuelve el modelo en mano a la postura de reposo.
void() direkt_arma_animar =
{
	local float total;

	total = direkt_arma_fotogramas(self.weapon);

	if (self.weaponframe + 1 >= total)
		self.weaponframe = 0;
	else
	{
		self.weaponframe = self.weaponframe + 1;
		self.nextthink = time + 0.05;
		return;
	}

	self.think = direkt_nada;
	self.nextthink = 0;
};

// La escopeta y el lanzaclavos bajan el arma un momento antes de volver a
// disparar, por eso usan esta en vez de la animacion normal.
void() direkt_arma_al_disparar =
{
	self.attack_finished = time + direkt_arma_cadencia(self.weapon);
	self.weaponframe = direkt_arma_fotogramas(self.weapon) - 1;
	self.think = direkt_arma_animar;
	self.nextthink = time + 0.3;
};

// Apunta al enemigo que este delante, como en Quake.
float() direkt_apuntar =
{
	traceline(self.origin, self.origin + v_forward * 8192, 0, self);
	if (trace_ent && trace_ent.takedamage)
	{
		self.angles = aim(trace_ent, 1);
		v_forward = normalize(self.origin + v_forward * 8192 - self.origin);
		return 1;
	}
	return 0;
};

//============================================================================
// HACHA
//============================================================================

void() direkt_arma_hacha =
{
	local vector dir;
	local vector p;
	local vector fin;
	local float golpe;

	sound(self, CHAN_WEAPON, "weapons/ax1.wav", 1, ATTN_NORM);
	self.punchangle_x = -20;

	// Un arco por el lado derecho y otro por el izquierdo.
	for (golpe = 0; golpe < 2; golpe++)
	{
		fin = self.origin + v_forward * 64;
		if (golpe == 0)
			fin = fin - v_right * 16;
		else
			fin = fin + v_right * 16;
		fin = fin + v_up * 16;
		traceline(self.origin, fin, 0, self);

		p = trace_endpos;
		dir = normalize(p - self.origin);
		dir = dir + v_forward;
		dir = normalize(dir);

		traceline(self.origin, self.origin + dir * 4, 0, self);
		if (trace_ent && trace_ent.takedamage)
		{
			trace_ent.velocity = trace_ent.velocity + dir * 100;
			direkt_danio(trace_ent, self, 15);
			return;
		}
	}
};

//============================================================================
// ESCOPETAS
//============================================================================

void(float perdigones) direkt_arma_escopeta =
{
	local vector dir;
	local vector fin;
	local float i;
	local float d;

	sound(self, CHAN_WEAPON, "weapons/shotgn2.wav", 1, ATTN_NORM);
	self.punchangle_x = -4;

	direkt_arma_restar();
	direkt_apuntar();

	for (i = 0; i < perdigones; i++)
	{
		// Cada perdigon sale un poco mas abierto que el anterior.
		dir = v_forward;
		dir = dir + v_right * (random() * 2 - 1) * 0.7;
		dir = dir + v_up * (random() * 2 - 1) * 0.7;
		dir = normalize(dir);

		fin = self.origin + dir * 8192;
		traceline(self.origin, fin, 0, self);

		if (trace_fraction < 1 && trace_ent && trace_ent.takedamage)
		{
			// Los primeros perdigones hacen mas dano que los ultimos.
			if (i < perdigones * 0.5)
				d = 11;
			else if (i < perdigones * 0.8)
				d = 10;
			else
				d = 6;

			direkt_danio(trace_ent, self, d);
		}
	}

	particle(self.origin + v_forward * 16, v_forward, 20, 1);
	direkt_arma_al_disparar();
};

//============================================================================
// LANZACLAVOS
//============================================================================

void(float clavos, float velocidad) direkt_arma_clavos =
{
	local vector dir;
	local vector fin;
	local float i;

	sound(self, CHAN_WEAPON, "weapons/spike2.wav", 1, ATTN_NORM);
	self.punchangle_x = -2;
	direkt_apuntar();

	for (i = 0; i < clavos; i++)
	{
		if (self.currentammo < 1)
			break;
		direkt_arma_restar();

		// Sale un pelin desviado, como en Quake.
		dir = normalize(v_forward + '0 0 1');
		dir = dir + v_right * (random() * 2 - 1) * 0.02;
		dir = dir + v_up * (random() * 2 - 1) * 0.02;
		dir = normalize(dir);

		fin = self.origin + v_forward * 16;
		fin = fin + dir * 8192;
		traceline(self.origin, fin, 0, self);

		// Si no ha tocado nada, el clavo sigue recto hasta el final.
		if (trace_fraction < 1)
			fin = trace_endpos;
		else
			fin = self.origin + dir * 8192;

		direkt_clavo_lanzar(fin, dir, self, velocidad);
	}

	direkt_arma_al_disparar();
};

// Un clavo por el aire.
void(vector pos, vector dir, entity dueno, float velocidad) direkt_clavo_lanzar =
{
	local entity clavo;

	precache_model("progs/spike.mdl");
	precache_sound("weapons/bounce.wav");

	clavo = spawn();
	clavo.classname = "direkt_clavo";
	clavo.owner = dueno;
	clavo.movetype = MOVETYPE_FLYMISSILE;
	clavo.solid = SOLID_BBOX;
	clavo.takedamage = DAMAGE_NO;
	clavo.model = "progs/spike.mdl";
	setmodel(clavo, "progs/spike.mdl");
	setorigin(clavo, pos);
	setsize(clavo, VEC_ORIGIN, VEC_ORIGIN);

	clavo.velocity = dir * velocidad;
	clavo.angles = vectoangles(dir);
	clavo.touch = direkt_clavo_tocar;
	clavo.think = direkt_clavo_desaparecer;
	clavo.nextthink = time + 5;
};

void() direkt_clavo_tocar =
{
	if (other == self.owner)
		return;

	if (other.takedamage)
		direkt_danio(other, self.owner, 10);

	remove(self);
};

void() direkt_clavo_desaparecer =
{
	sound(self, CHAN_BODY, "weapons/bounce.wav", 1, ATTN_NORM);
	remove(self);
};

//============================================================================
// LANZAGRANADAS Y LANZACOHETES
//============================================================================

void() direkt_arma_granada =
{
	precache_model("progs/grenade.mdl");
	precache_sound("weapons/grenade.wav");

	direkt_arma_restar();
	sound(self, CHAN_WEAPON, "weapons/grenade.wav", 1, ATTN_NORM);
	self.punchangle_x = -4;

	direkt_proyectil(
		self.origin + v_forward * 16,
		v_forward,
		600,
		"progs/grenade.mdl",
		100,
		150,
		self);
};

void() direkt_arma_cohete =
{
	precache_model("progs/missile.mdl");
	precache_sound("weapons/rocket1i.wav");

	direkt_arma_restar();
	sound(self, CHAN_WEAPON, "weapons/rocket1i.wav", 1, ATTN_NORM);
	self.punchangle_x = -4;

	direkt_proyectil(
		self.origin + v_forward * 16,
		v_forward,
		800,
		"progs/missile.mdl",
		100,
		200,
		self);
};

// Crea un proyectil que vuela solo y detona al tocar algo.
void(vector pos, vector dir, float velocidad, string modelo,
	float dano, float radio, entity dueno) direkt_proyectil =
{
	local entity p;

	precache_model(modelo);
	precache_sound("weapons/rocket1i.wav");
	precache_sound("weapons/r_exp3.wav");

	p = spawn();
	p.classname = "direkt_proyectil";
	p.owner = dueno;
	p.movetype = MOVETYPE_FLYMISSILE;
	p.solid = SOLID_BBOX;
	p.takedamage = DAMAGE_NO;
	p.model = modelo;
	setmodel(p, modelo);
	setorigin(p, pos);
	setsize(p, VEC_ORIGIN, VEC_ORIGIN);

	p.velocity = dir * velocidad;
	p.angles = vectoangles(dir);

	p.dmg_take = dano;			// dano directo
	p.dmg_save = radio;			// radio de la explosion
	p.touch = direkt_proyectil_tocar;
	p.think = direkt_proyectil_desaparecer;
	p.nextthink = time + 5;
};

void() direkt_proyectil_tocar =
{
	if (other == self.owner)
		return;

	// Si toca a alguien sin armadura que le llegue el dano de golpe.
	if (other.takedamage)
		direkt_danio(other, self.owner, self.dmg_take * 0.5);

	direkt_explotar(self.origin, self.dmg_take, self.dmg_save, self.owner);
};

void() direkt_proyectil_desaparecer =
{
	direkt_explotar(self.origin, self.dmg_take, self.dmg_save, self.owner);
};

// Radio de dano: lo que pilla dentro del radio se lleva la parte que le
// toque, y mas lejos se lleva menos.
void(float dano, float radio, entity agresor) direkt_dano_radio =
{
	local float puntos;
	local float d;
	local entity t;

	puntos = -1;

	t = findradius(self.origin, radio);
	while (t)
	{
		if (t != self && t.takedamage)
		{
			d = vlen(t.origin - self.origin);
			if (d < radio)
			{
				// Cuanto mas cerca, mas dano; el valor va de 0 a 1.
				puntos = 0.5 * (1 - d / radio);
				if (puntos < 0)
					puntos = 0;
				puntos = puntos * dano;
				if (puntos < 1)
					puntos = 1;
				direkt_danio(t, agresor, puntos);
			}
		}
		t = t.chain;
	}
};

// Una explosion en un punto: el self de la funcion es el proyectil.
void(vector pos, float dano, float radio, entity agresor) direkt_explotar =
{
	sound(self, CHAN_BODY, "weapons/r_exp3.wav", 1, ATTN_NORM);
	direkt_dano_radio(dano, radio, agresor);
	remove(self);
};

//============================================================================
// RAYO
//============================================================================

void() direkt_arma_rayo =
{
	local vector fin;
	local entity golpeado;
	local float d;

	// El rayo no gasta municion si no toca a nadie.
	traceline(self.origin, self.origin + v_forward * 8192, 0, self);
	fin = trace_endpos;
	golpeado = trace_ent;

	if (golpeado && golpeado.takedamage)
		d = 25;
	else
		d = 0;

	direkt_rayo_impacto(fin, golpeado, d);

	self.punchangle_x = -1;
	self.attack_finished = time + 0.05;
	self.weaponframe = 1;
	self.think = direkt_arma_animar;
	self.nextthink = time + 0.05;

	if (self.currentammo > 0)
		direkt_arma_restar();
	else
		direkt_arma_coger_ammo(self);
};

// Dibuja el rayo desde la boca del arma hasta donde paro.
void(vector fin, entity golpeado, float dano) direkt_rayo_impacto =
{
	local entity chispa;
	local float partes;
	local float i;
	local vector p;
	local float distancia;

	precache_model("progs/bolt.mdl");
	precache_sound("weapons/lhit.wav");
	precache_sound("weapons/ric1.wav");
	precache_sound("weapons/ric3.wav");

	distancia = vlen(fin - self.origin);
	partes = distancia / 10;
	if (partes < 3)
		partes = 3;
	if (partes > 20)
		partes = 20;

	p = self.origin + v_forward * 10;
	for (i = 1; i <= partes; i++)
	{
		chispa = spawn();
		chispa.classname = "direkt_chispa";
		chispa.movetype = MOVETYPE_NONE;
		chispa.solid = SOLID_NOT;
		chispa.model = "progs/bolt.mdl";
		setmodel(chispa, "progs/bolt.mdl");
		setorigin(chispa, p);
		setsize(chispa, VEC_ORIGIN, VEC_ORIGIN);
		chispa.angles = self.angles;
		chispa.think = direkt_chispa_desaparecer;
		chispa.nextthink = time + 0.06;

		p = p + v_forward * 10;
	}

	if (golpeado && golpeado.takedamage)
	{
		direkt_danio(golpeado, self, dano);
		sound(self, CHAN_WEAPON, "weapons/lhit.wav", 1, ATTN_NORM);
	}
	else
	{
		sound(self, CHAN_WEAPON, "weapons/ric1.wav", 0.6, ATTN_NORM);
	}
};

void() direkt_chispa_desaparecer =
{
	remove(self);
};

//============================================================================
// RELIQUIAS
//============================================================================

// Las reliquias duran un rato. Como no hay campos propios, los relojes viven
// como globales del jugador al que se le han dado.
float	direkt_reliquia_invisibilidad;
float	direkt_reliquia_invulnerable;
float	direkt_reliquia_traje;
float	direkt_reliquia_cuadruplo;

void(entity jugador) direkt_reliquia_temporizadores =
{
	if (jugador.items & IT_INVISIBILITY)
		direkt_reliquia_invisibilidad = time + 30;
	if (jugador.items & IT_INVULNERABILITY)
		direkt_reliquia_invulnerable = time + 30;
	if (jugador.items & IT_SUIT)
		direkt_reliquia_traje = time + 30;
	if (jugador.items & IT_QUAD)
		direkt_reliquia_cuadruplo = time + 30;
};

// Mira de vez en cuando si al jugador se le ha acabado alguna reliquia.
void() direkt_reliquia_pasar =
{
	if (self.items & IT_INVISIBILITY && time > direkt_reliquia_invisibilidad)
	{
		self.items = self.items - IT_INVISIBILITY;
		stuffcmd(self, "print \"Se te acaba la invisibilidad\\n\"\n");
	}
	if (self.items & IT_INVULNERABILITY && time > direkt_reliquia_invulnerable)
	{
		self.items = self.items - IT_INVULNERABILITY;
		stuffcmd(self, "print \"Se te acaba la invulnerabilidad\\n\"\n");
	}
	if (self.items & IT_SUIT && time > direkt_reliquia_traje)
	{
		self.items = self.items - IT_SUIT;
		stuffcmd(self, "print \"Se te acaba el traje\\n\"\n");
	}
	if (self.items & IT_QUAD && time > direkt_reliquia_cuadruplo)
	{
		self.items = self.items - IT_QUAD;
		stuffcmd(self, "print \"Se te acaba el dano cuadruplo\\n\"\n");
	}

	self.nextthink = time + 1;
};
