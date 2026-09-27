// Direkt -- disparo de targets y utilidades.
//
// GPL-2.0, ver LICENSE en la raiz del repositorio.
//
// El motor lee las claves "target" y "targetname" del BSP y las guarda en
// strings de la entidad. Un trigger enciende una entidad -> se ejecuta su
// funcion .use. Sin esto, los 244 trigger_relay de los mapas de LibreQuake se
// limitarian a no hacer nada.
//
// defs.qc ya declara SUB_UseTargets y SUB_Remove como void(), asi que aqui se
// respetan esas firmas en vez de inventar otras.



// target_name = target1 -> enciende el .use de quien tenga ese targetname.
void() direkt_nada =
{
};

// ------------------------------------------------------------------ llamadas
// fteqcc NO cambia "self" al invocar una funcion guardada en un campo de
// entidad: "t.use()" sigue ejecutandose con el self que hubiera antes, que en
// un trigger es el propio trigger. Por eso toda llamada de entidad a entidad
// pasa por estos ayudantes, que fijan self, llaman y lo restauran.
void(entity ent) direkt_llama_use =
{
	local entity anterior;

	if (!ent || !ent.use)
		return;

	anterior = self;
	self = ent;
	ent.use();
	self = anterior;
};

void(entity ent, entity otro) direkt_llama_touch =
{
	local entity anterior;

	if (!ent || !ent.touch)
		return;

	anterior = self;
	self = ent;
	other = otro;
	ent.touch();
	self = anterior;
};

void(entity ent) direkt_llama_think =
{
	local entity anterior;

	if (!ent || !ent.think)
		return;

	anterior = self;
	self = ent;
	ent.think();
	self = anterior;
};

void(entity ent) direkt_llama_muerte =
{
	local entity anterior;

	if (!ent || !ent.th_die)
		return;

	anterior = self;
	self = ent;
	ent.th_die();
	self = anterior;
};

void() target_use =
{
	local entity t;

	activator = other;
	self = self.owner;

	if (!self.target)
		return;

	t = find(world, targetname, self.target);
	while (t)
	{
		direkt_llama_use(t);
		t = find(t, targetname, self.target);
	}
};

// Igual que target_use pero dispara tambien los targets guardados en
// .killstring, que es como id los usaba para "apunta a mi y al encadenado".
void() SUB_UseTargets =
{
	local entity t;

	if (self.killstring)
	{
		t = find(world, targetname, self.killstring);
		while (t)
		{
			direkt_llama_use(t);
			t = find(t, targetname, self.killstring);
		}
	}

	if (self.target)
	{
		t = find(world, targetname, self.target);
		while (t)
		{
			direkt_llama_use(t);
			t = find(t, targetname, self.target);
		}
	}
};

// Borra la entidad el proximo frame, no en medio del frame actual: quitar
// entidades mientras se recorre la lista de colisiones rompe el frame.
void() SUB_Remove =
{
	remove(self);
};

// ------------------------------------------------------------------ direccion
// El mapa escribe "angle" como un numero suelto y el motor lo convierte a
// "angles" (ver el anglehack de ED_ParseEdict). "0 -1 0" y "0 -2 0" no son
// angulos validos: Quake los usaba como "arriba" y "abajo" para las placas y
// las barras del ascensor, asi que hay que traducirlos a mano.
void() direkt_movedir =
{
	if (self.angles == '0 -1 0')
		self.movedir = '0 0 1';
	else if (self.angles == '0 -2 0')
		self.movedir = '0 0 -1';
	else
	{
		makevectors(self.angles);
		self.movedir = v_forward;
	}

	// Los angulos ya se gastaron: dejarlos puesta causa que el motor los
	// everytime gire al hacer trace.
	self.angles = '0 0 0';
};

// Los gatillos necesitan un tamano para tener caja de colision. setmodel con
// el propio model (normalmente "starfield" o "") se lo da, y despues se
// borra el model para que no se dibuje.
void() InitTrigger =
{
	// Un angulo de 0 significa "sin restriccion", no "solo en un sentido": se
	// usa 360 porque movedir no distingue el 0.
	if (self.angles != '0 0 0')
		direkt_movedir();

	self.solid = SOLID_TRIGGER;
	setmodel(self, self.model);
	self.movetype = MOVETYPE_NONE;
	self.modelindex = 0;
	self.model = string_null;
};

// ------------------------------------------------------------------ movimiento
// Convierte "llegar a tdest a tspeed unidades por segundo" en una velocidad y
// un nextthink. defs.qc declara las tres; el cuerpo va aqui porque las usan
// puertas, botones y plataformas.
void() SUB_CalcMoveDone =
{
	setorigin(self, self.finaldest);
	self.velocity = '0 0 0';
	self.nextthink = -1;

	if (self.think1)
		self.think1();
};

void(vector tdest, float tspeed, void() func) SUB_CalcMove =
{
	local vector delta;
	local float distancia, tiempo;

	// Sin velocidad el calculo daria division por cero y la entidad se
	// quedaria clavada para siempre. Los mapas de LibreQuake siempre la
	// dan, pero si faltara se avisa y se cancela en vez de abortar.
	if (!tspeed)
	{
		dprint("DIREKT: SUB_CalcMove sin speed\n");
		return;
	}

	// ltime es la referencia que usan los retardos que se programan al final
	// del recorrido (cerrar la puerta, bajar la plataforma...). Sin fijarla
	// aqui, "self.ltime + espera" cae en el pasado y todo ocurre de golpe.
	self.ltime = time;

	self.think1 = func;
	self.finaldest = tdest;
	self.think = SUB_CalcMoveDone;

	// Ya esta en su sitio: se avisa igualmente en 0.1 s en vez de al instante
	// para no disparar think dentro del frame que se esta calculando.
	if (tdest == self.origin)
	{
		self.velocity = '0 0 0';
		self.nextthink = self.ltime + 0.1;
		return;
	}

	delta = tdest - self.origin;
	distancia = vlen(delta);
	tiempo = distancia / tspeed;

	if (tiempo < 0.1)
	{
		self.velocity = '0 0 0';
		self.nextthink = self.ltime + 0.1;
		return;
	}

	self.nextthink = self.ltime + tiempo;
	// El 1/tiempo es la velocidad: el motor mueve la pusher con velocity.
	self.velocity = delta * (1 / tiempo);
};

// Igual que la de arriba pero opera sobre otra entidad. La logica original de
// doors.qc y buttons.qc cambia "self" a mano por el mismo motivo; esto lo deja
// escrito.
void(entity ent, vector tdest, float tspeed, void() func) SUB_CalcMoveEnt =
{
	local entity antes;

	antes = self;
	self = ent;
	SUB_CalcMove(tdest, tspeed, func);
	self = antes;
};
