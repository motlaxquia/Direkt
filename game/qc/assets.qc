// Direkt -- inventario de assets de LibreQuake.
//
// GPL-2.0, ver LICENSE en la raiz del repositorio.
//
// Los sprites de LibreQuake (empaquetados como progs/*.spr) y los modelos se
// entregan precargados desde el pak; no hay ficheros sueltos en el repositorio.
//
// IMPORTANTE: el motor aborta con "model not precached" si una entidad pide un
// modelo que no esta en la lista, asi que aqui van TODOS los que el juego puede
// necesitar, no solo los que se usan hoy. Los nombres salen del propio pak de
// LibreQuake: v_axe/v_shot/v_nail/v_rock en vez de los vax/vshot clasicos, y
// solo hay gib1, gib2 y zom_gib.
//
// scripts/smoke-test.sh comprueba contra el pak que cada nombre de
// direkt_assets() existe de verdad, para que un renombrado en LibreQuake no
// rompa el juego en silencio.

// Devuelve 0 si el nombre se ha podido precargar.
float(string name) direkt_precache =
{
	local float ok;
	ok = 1;
	if (!precache_model(name))
		ok = 0;
	return ok;
};

// El motor exige que el jugador, sus gibs y el arma equipada esten precargados
// antes de que se cree la entidad, asi que esta lista se ejecuta en worldspawn.
void() direkt_precache_assets =
{
	// --- jugador ---
	direkt_precache("progs/player.mdl");
	direkt_precache("progs/eyes.mdl");
	direkt_precache("progs/h_player.mdl");
	direkt_precache("progs/gib1.mdl");
	direkt_precache("progs/gib2.mdl");
	direkt_precache("progs/gib3.mdl");
	direkt_precache("progs/zom_gib.mdl");

	// --- sonidos de muerte ---
	// gib.wav es el de los pedazos. Sin precargarlo el motor avisa por consola
	// y lo deja sin sonido.
	precache_sound("player/udeath.wav");
	precache_sound("player/gib.wav");

	// --- sprites (VERA sin paleta, 1 byte por pixel) ---
	// Los tres que trae el pak. s_bubble y s_light no los usa el juego de
	// LibreQuake, pero son los sprites clasicos de burbuja, luz y explosion.
	direkt_precache("progs/s_bubble.spr");
	direkt_precache("progs/s_light.spr");
	direkt_precache("progs/s_explod.spr");

	// --- armas: modelo en la mano y modelo de vista ---
	direkt_precache("progs/v_axe.mdl");
	direkt_precache("progs/v_shot.mdl");
	direkt_precache("progs/v_nail.mdl");
	direkt_precache("progs/v_rock.mdl");
	direkt_precache("progs/v_shot2.mdl");
	direkt_precache("progs/v_nail2.mdl");
	direkt_precache("progs/v_rock2.mdl");
	direkt_precache("progs/v_light.mdl");

	// --- proyectiles y efectos ---
	direkt_precache("progs/spike.mdl");
	direkt_precache("progs/s_spike.mdl");
	direkt_precache("progs/grenade.mdl");
	direkt_precache("progs/missile.mdl");
	direkt_precache("progs/bolt.mdl");
	direkt_precache("progs/bolt2.mdl");
	direkt_precache("progs/bolt3.mdl");
	direkt_precache("progs/lavaball.mdl");
	direkt_precache("progs/flame.mdl");
	direkt_precache("progs/flame0.mdl");
	direkt_precache("progs/flame2.mdl");

	// --- armadura, mochila y poderes ---
	direkt_precache("progs/armor.mdl");
	direkt_precache("progs/quaddama.mdl");
	direkt_precache("progs/suit.mdl");
	direkt_precache("progs/backpack.mdl");
	direkt_precache("progs/invisibl.mdl");
	direkt_precache("progs/invulner.mdl");

	// --- objetos que se recogen: ammo, llaves y botiquines ---
	// Los objetos tambien los precargan sus propias funciones de spawn, pero
	// se listan aqui para que se vea el monton completo y para que el
	// comprobador de assets los cuente.
	direkt_precache("progs/g_shot.mdl");
	direkt_precache("progs/g_shot1.mdl");
	direkt_precache("progs/g_nail.mdl");
	direkt_precache("progs/g_nail2.mdl");
	direkt_precache("progs/g_rock.mdl");
	direkt_precache("progs/g_rock2.mdl");
	direkt_precache("progs/g_light.mdl");
	direkt_precache("progs/m_s_key.mdl");
	direkt_precache("progs/m_g_key.mdl");
	direkt_precache("progs/w_s_key.mdl");
	direkt_precache("progs/w_g_key.mdl");
	direkt_precache("maps/b_bh10.bsp");
	direkt_precache("maps/b_bh25.bsp");
	direkt_precache("maps/b_bh100.bsp");
	direkt_precache("maps/b_shell0.bsp");
	direkt_precache("maps/b_shell1.bsp");
	direkt_precache("maps/b_nail0.bsp");
	direkt_precache("maps/b_nail1.bsp");
	direkt_precache("maps/b_rock0.bsp");
	direkt_precache("maps/b_rock1.bsp");
	direkt_precache("maps/b_batt0.bsp");
	direkt_precache("maps/b_batt1.bsp");
};
