# Componentes de terceros y licencias

Direkt es un juego 3D derivado del motor de Quake. Este documento declara, componente
por componente, el origen y la licencia de todo lo que se distribuye con el proyecto.

## Resumen

| Componente | Uso | Licencia | Dónde se obtiene |
|---|---|---|---|
| Ironwail (y su ancestro QuakeSpasm/GLQuake) | Motor del juego | GPL-2.0 | `scripts/fetch-deps.sh` |
| Quake engine, original de id Software | Base histórica del motor | GPL-2.0 | `id-Software/Quake` |
| LibreQuake | Modelos, texturas, sonidos, música, niveles | BSD-3-Clause **y** GPL-2.0 | `scripts/fetch-deps.sh` |
| `gfx/pop.lmp` (dentro de LibreQuake) | Desbloquea el modo registrado en Ironwail | GPL-2.0 | dentro de `pak1.pak` de LibreQuake |
| `fteqcc` | Compilador QuakeC (usado solo en build) | GPL-2.0 | distribución del sistema |

## Licencia de Direkt

**GPL-2.0** (ver `LICENSE`). Es obligatoria y no negociable:

- El motor es descendiente directo del código de Quake, publicado por id Software bajo GPL-2.0.
  La GPL se transmite a cualquier obra derivada: si se distribuye el binario, hay que
  distribuir también el código fuente completo.
- El código de juego en QuakeC de este repo es obra derivada, así que también es GPL-2.0.

## Qué NO usamos (y por qué)

- **Datos originales de Quake (id1/pak0.pak, pak1.pak), manual y música (Soundtrak).**
  Son propietarios de id Software y su licencia no permite redistribuirlos. Por eso
  usamos LibreQuake, que es un reemplazo libre con licencia permisiva.
- **Quake II / Quake III.** El motor de Q2 (id-Software/Quake-2, GPL-2.0) sí es código
  abierto y su fuente es alcanzable, pero **todos** sus datos son propietarios y no
  existe un reemplazo libre completo. Q3/ioquake3 ni siquiera es alcanzable desde
  nuestra red. Ninguna de las dos se usa como base.

## Detalle de las licencias de LibreQuake

LibreQuake es un proyecto con doble licencia. Según su
`docs/README-IMPORTANT-LICENCE-INFO`:

- **BSD-3-Clause (permisiva)** — todo el arte: modelos 3D, texturas, sonidos, música,
  niveles, y los archivos `.spr`. *Modelos, texturas, sonidos y música* son la parte
  mayoritaria y se pueden usar en cualquier proyecto, incluso comercial, indicando la
  autoría.
- **GPL-2.0 (restrictiva)** — únicamente el código QuakeC (`qcsrc/`), el `progs.dat`
  compilado y `pop.lmp`.

Consecuencia práctica: los **recursos gráficos y sonoros** de LibreQuake que usa Direkt
(`.mdl`, texturas, `.spr`, sonidos) son BSD-3-Clause. Los **mapas** son BSD-3-Clause pero
están empaquetados dentro de `pak0.pak`/`pak1.pak` junto a `pop.lmp` (GPL-2.0), así que
en la práctica el directorio de datos completo de LibreQuake se considera GPL-2.0. Por
eso Direkt es GPL-2.0 entera y es lo correcto.

Nota sobre sprites: LibreQuake sustituyó casi todos los sprites de Quake por **modelos
3D `.mdl`**. Solo conserva 4 sprites (`.spr` VERA 2D): `s_explod.spr`, `s_bubbles.spr`,
`s_bubble.spr` y `s_light.spr`. Todos BSD-3-Clause.

## Aviso de atribución

- Quake es © id Software. La publicación del código fuente fue un acto deliberado de
  id Software bajo GPL-2.0; ver `readme.txt` del release original.
- Ironwail es © los autores de QuakeSpasm / Ironwail, GPL-2.0.
- LibreQuake es © 2019-2023 los colaboradores del proyecto LibreQuake, BSD-3-Clause.
  Créditos completos en el archivo `CREDITS` que acompaña a sus datos.

## Procedimiento para cambiar un componente

1. Actualizar la URL/commit fijado en `scripts/fetch-deps.sh`.
2. Recalcular el SHA-256 y actualizarlo en el mismo script (el script falla si no
   coincide).
3. Releer la licencia del componente nuevo y actualizar esta tabla.
