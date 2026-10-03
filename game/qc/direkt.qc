// Direkt -- arranque del mundo y escaparate de sprites.
//
// GPL-2.0, ver LICENSE en la raiz del repositorio.
//
// El escaparate existe para demostrar la cadena completa: QuakeC propio
// compilado con fteqcc, ejecutado por Ironwail por encima de los datos de
// LibreQuake, y sprites de LibreQuake dibujandose de verdad en pantalla.
//
// NOTA sobre los mensajes: localcmd mete texto en la cola del servidor SIN
// separador, asi que dos llamadas seguidas se pegan ("echo Acoge B"). Por eso
// todos los literales empiezan por un espacio: la cola queda "echo A echo B" y
// el motor los imprime separados en la misma linea.
void() direkt_nothing =
{
};

// ------------------------------------------------------------------ sprites
// Los tres sprites que trae LibreQuake tienen un unico frame, asi que no hay
// animacion que avanzar y la entidad no necesita think. OJO: antes llevaba un
// think que la borraba a los 3 segundos "para confirmar que vivia", y como la
// captura del smoke test llega a los 6 segundos, la foto salia sin sprites y
// parecia que no se dibujaban. Ahora son permanentes.

// Coloca un sprite delante de un jugador. right/up desplazan en la pantalla y
// dist es la distancia al ojo, que es la unica palanca de tamaño disponible:
// .scale y .alpha viven en la zona extra de edicts que el motor reserva con un
// orden fijo, y declararlos mal en QuakeC no da error, solo corrompe en
// silencio otros campos.
void(entity p, string sprname, float right, float up, float dist) direkt_spawn_sprite =
{
	local entity s;
	local vector eye;

	makevectors(p.v_angle);
	eye = p.origin + '0 0 24';

	s = spawn();
	s.classname = "direkt_sprite";
	s.model = sprname;
	s.solid = SOLID_NOT;
	s.movetype = MOVETYPE_NONE;
	s.origin = eye + (v_forward * dist) + (v_right * right) + (v_up * up);
	s.angles = p.v_angle;
	s.frame = 0;
	setmodel(s, sprname);
};

// Distancia a la que colocar algo delante del jugador. Se lanza un rayo y se
// usan tres cuartos de lo que haya hasta el primer obstaculo, acotado para que
// nunca quede pegado a la camara ni en la lejania.
float(entity p) direkt_distancia_frente =
{
	local vector eye;
	local float d;

	makevectors(p.v_angle);
	eye = p.origin + '0 0 24';

	traceline(eye, eye + v_forward * 512, 1, p);
	d = trace_fraction * 512;

	// Topes: 120 como maximo para que el sprite de 32 pix no quede diminuto,
	// 40 como minimo para que no nazca dentro de la cara del jugador.
	if (d > 120)
		d = 120;
	if (d < 40)
		d = 40;
	return d * 0.75;
};

// ------------------------------------------------------------------ espera
// worldspawn corre antes de que se conecte el cliente, asi que aun no hay
// jugador. Esta entidad espera a que aparezcan el jugador y el impulso.
void() direkt_hosted_think =
{
	local entity p;
	local entity s;

	p = find(world, classname, "player");
	if (!p)
	{
		self.nextthink = time + 0.1;
		return;
	}

	// Cuantos puntos de aparicion ha encontrado el mapa, por si uno falta y hay
	// que saber cual.
	s = find(world, classname, "info_player_start");
	if (s)
		localcmd(" echo DIREKT: hay info_player_start");
	else
		s = find(world, classname, "info_player_deathmatch");

	if (s)
		localcmd(" echo DIREKT: hay punto de aparicion");
	else
		localcmd(" echo DIREKT: SIN punto de aparicion en el mapa");

#ifndef DIREKT_NOSHOWCASE
	// Que se vean depende del mapa: a 110 unidades los sprites acababan
	// dentro de una pared y no se veia ninguno. Se lanza un rayo hacia delante
	// y se colocan a tres cuartos de lo que haya hasta el primer obstaculo, con
	// topes para que no se peguen a la camara ni queden en la lejania.
	direkt_spawn_sprite(p, "progs/s_light.spr", 0, 0, direkt_distancia_frente(p));
	direkt_spawn_sprite(p, "progs/s_bubble.spr", -48, 14, direkt_distancia_frente(p));
	direkt_spawn_sprite(p, "progs/s_explod.spr", 48, -14, direkt_distancia_frente(p));

	localcmd(" echo DIREKT: 3 sprites de LibreQuake en escena");
#else
	localcmd(" echo DIREKT: escaparate apagado");
#endif

	self.think = direkt_nothing;
};

void() worldspawn =
{
	local entity w;

	// Todo lo que el juego pueda pedir tiene que estar precargado ya.
	direkt_precache_assets();

	localcmd(" echo DIREKT: progs.dat propio cargado");

	// La sonda del parkour: una entidad invisible que solo guarda el vector del
	// traceline para poderle leer un componente. Ver direkt_piso() en parkour.qc.
	direkt_sonda = spawn();
	direkt_sonda.classname = "direkt_sonda";
	direkt_sonda.solid = SOLID_NOT;
	direkt_sonda.movetype = MOVETYPE_NONE;
	direkt_sonda.angles = '0 0 0';

	// OJO: en worldspawn, self ES la entidad world, y QuakeC aborta con
	// "assignment to world entity" si le tocas un campo. El think tiene que
	// vivir en una entidad normal.
	w = spawn();
	w.classname = "direkt_waiter";
	w.solid = SOLID_NOT;
	w.movetype = MOVETYPE_NONE;
	w.think = direkt_hosted_think;
	w.nextthink = time + 0.1;
};

