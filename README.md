# Direkt

Direkt es un juego de acción en primera persona (FPS) 3D construido sobre
[Ironwail](https://github.com/andrei-drexler/ironwail), el motor de Quake, y con
los recursos de [LibreQuake](https://librequake.org/). La lógica de juego está
escrita desde cero en QuakeC y se compila con `fteqcc`.

Licencia: **GPL-2.0**. Ver [`LICENSE`](LICENSE) y [`THIRD_PARTY.md`](THIRD_PARTY.md).

## Qué hay aquí

| Ruta | Qué es |
| --- | --- |
| `game/qc/` | La lógica de juego en QuakeC. `defs.qc` son las definiciones canónicas de id/LibreQuake; el resto es original. |
| `game/progs.src` | El punto de entrada de `fteqcc`: qué ficheros se compilan y en qué orden. |
| `scripts/` | Descarga de dependencias, build, ejecución sin pantalla y smoke test. |
| `tools/` | Utilidades de auditoría de los PAK y de los sprites de LibreQuake. |
| `docs/ARCHITECTURA.md` | Qué formatos binarios acepta el motor de verdad, con el `fichero:línea` de cada dato. |
| `Makefile` | Todo lo que se puede hacer. `make help` las lista. |
| `build/` | Todo lo descargado o generado. Ignorado por git. |

## Puesta en marcha

```sh
make setup      # dependencias del sistema (sudo)
make deps       # descarga motor + datos, verifica SHA-256, y comprueba el GL
make engine     # compila Ironwail
make game       # compila el QuakeC -> direkt/progs.dat
make run        # juego con ventana
make test       # smoke test headless completo
```

`make deps` deja todo en `build/`: el motor se extrae y compila ahí, y los datos
de LibreQuake se unpackean en `build/lq/full/`, que es el *basedir* que el motor
exige (`<basedir>/id1/pak0.pak`). Las versiones están fijadas por commit y por
SHA-256 en `scripts/fetch-deps.sh`.

### Sin tarjeta gráfica

`scripts/xvfb-env.sh` levanta un Xvfb y fuerza Mesa/llvmpipe. El render por
software aguanta, pero hay que exportar `MESA_GL_VERSION_OVERRIDE=4.5COMPAT`
para que el motor no pida compute shaders. `scripts/check-gl.sh` verifica que el
contexto OpenGL tiene los requisitos antes de perder tiempo con un build entero.

```sh
source scripts/xvfb-env.sh
make run-headless              # arranca, captura y se apaga
make shot MAP=lq_e1m1          # captura de otro mapa
```

## Mapas propios: `direkt-bsp`

Ni Ironwail ni LibreQuake traen compilador de mapas, y LibreQuake no
distribuye los `.map` originales. Para tener niveles propios hay que escribir
el `.bsp` desde cero, y eso es lo que hace `direkt-bsp`:

```sh
make bsp                                    # compila el generador
build/bin/direkt-bsp src/test/habitacion.map build/lq/full/id1/maps/nuevo.bsp
build/bin/direkt-bsp --check build/lq/full/id1/maps/nuevo.bsp
make bsp-test                               # la prueba completa
```

Cubre el subconjunto clásico de `.map` (caras planas, el de los mapas de
LibreQuake); los *brush primitives* (`[ ... ]`) se rechazan con un error
claro. Escribe los 15 lumps de un BSP29, incluidas las **tres dilataciones de
colisión**: el jugador no se cae al suelo.

`--check` no es opcional. El motor **no valida ni un `fileofs`**: un error ahí
no da un fallo, da una lectura arbitraria de memoria a mitad de una partida. El
validador revisa el fichero ya escrito en disco (offsets, tamaños, índices,
ciclos y nodos inalcanzables), no la estructura en memoria.

Todavía **no** hace: texturas, iluminación, visibilidad, entidades
brush que se mueven ni submodelos. Los lumps `TEXTURES`, `VISIBILITY` y
`LIGHTING` salen vacíos, así que se ve la geometría pero sin material ni luz.

## El editor: `direkt-edit`

Un mapa propio se coloca mucho mejor con un editor que editando el `.map` a
mano, así que el editor abre, dibuja, modifica y guarda:

```sh
make edit                              # compila (necesita libsdl2-dev)
make run-edit MAPFILE=src/test/habitacion.map
build/bin/direkt-edit --new            # mapa en blanco
build/bin/direkt-edit --selftest       # 40 pruebas, sin ventana
make editor-test                       # prueba completa, con captura
```

Ironwail ya usaba SDL2, así que el editor **no añade ninguna dependencia
nueva** al tarball. El dibujo es OpenGL 1.2 en modo inmediato, que es lo que
hay en cualquier Linux y lo que ya usa el motor.

### Atajos

| Tecla | Qué hace |
|---|---|
| ratón izquierdo | selecciona la brush que se ve debajo |
| ratón izquierdo + arrastrar | mueve la brush, o estira la cara pulsada |
| ratón derecho | mira (el cursor se esconde) |
| `W` `A` `S` `D`, flechas | mueve la cámara; `C` centra en lo seleccionado |
| `B` | caja nueva delante de la cámara, en la rejilla |
| `D` | duplica la brush |
| `Supr` / `Retroceso` | borra la brush |
| flechas | mueven la brush seleccionada un paso de rejilla |
| `Ctrl+Z` / `Ctrl+Y` | deshacer / rehacer |
| `G` | dobla la rejilla (hasta 128) |
| `1`-`9` | elige textura |
| `F2` | guarda |
| `F5` | compila a `.bsp` y lo valida |
| `Tab` | alterna alambre y sólido |
| `F1` | muestra u oculta la ayuda |

### Cómo está repartido

| Fichero | De qué se ocupa |
|---|---|
| `src/ed_doc.c` | el documento: selección, edición, historial, guardado a `.map` |
| `src/ed_view.c` | cámara, matrices y rayo de ratón |
| `src/ed_gui.c` | ventana de SDL2 y dibujado con OpenGL |
| `src/ed_test.c` | 40 pruebas de la lógica, sin pantalla |

`ed_doc` y `ed_view` no saben nada de SDL ni de OpenGL, así que casi todo se
puede comprobar en un banco de pruebas sin ventana. Solo `ed_gui` toca la
biblioteca gráfica, y aun así tiene un modo `--shot` que dibuja un fotograma a
un PPM, que es como se prueba el dibujo.

### Decisiones que no son obvias

**El documento ES un `map_t`.** No hay una representación paralela: lo que se
ve es lo que se compila, y `save_map` escribe exactamente lo que hay. Un editor
con dos representaciones del mapa siempre acaba con una de las dos desfasada.

**El historial son instantáneas del `.map` en texto.** Un editor de niveles hace
tan pocas operaciones por minuto que serializar el documento entero para cada
cambio sale más barato que cualquier estructura de deshacer incremental, y
sobre todo no se puede desincronizar: lo que se deshace es literalmente lo que
había.

**El parser acepta los puntos con y sin espacios dentro del paréntesis.**
`( 0 0 0 )` y `(0 0 0)` valen los dos, porque las dos formas se ven en el
mundo. Con solo una, el editor no puede abrir mapas que haya hecho otra
herramienta, y tampoco leer los suyos propios.

**Una brush-entity se guarda siempre con `"origin"`.** Las brushes de
LibreQuake llegan al BSP con `"model" "*N"` y sin `"origin"`, y el motor **no lo
deduce**: usa el origen de la entidad, que es (0,0,0). Por eso el origen se
reescribe siempre desde la caja de las brushes, que es lo único que no depende
de dónde esté el cursor. Es el fallo que hacía que las plataformas apareciesen
en el centro del mapa.

**Arrastrar la cara de una caja la estira; la de otra brush, la deforma.**
En una caja los cuatro vértices de una cara los comparten con las cuatro
lateral, así que hay que mover **todos los puntos que están en ese plano**. Si
se mueven solo los de la cara, las laterales siguen apuntando a la coordenada
antigua y el resultado no es una caja más pequeña: es un tronco de pirámide con
las juntas abiertas. En una brush que ya no es caja, arrastrar una cara sí la
deforma, que es lo único que se puede hacer sin romper la convexidad.

**`winding_reverse` devuelve una winding nueva.** No da la vuelta la de dentro.
Ignorar el valor de retorno deja las caras con la normal invertida y el brush se
comporta al revés, sin ningún aviso.

**El HUD dibuja el texto desde arriba hacia abajo en un eje y que crece hacia
arriba.** El panel y las barras se colocan a partir de la altura de la ventana.
Con blending: sin `glEnable(GL_BLEND)`, el `glColor4f` con alfa se dibuja negro
opaco y tapa la escena.

## Estado actual

El juego todavía **no es jugable**. Es un arranque verificado de punta a punta:

- `progs.dat` propio compilado con `fteqcc` y cargado por Ironwail sobre los
  datos de LibreQuake.
- Cycle of vida del cliente (`client.qc`), suficiente para entrar al mundo.
- Generador de `.bsp` propio (`direkt-bsp`): compila `.map` a BSP29 con las tres
  dilataciones de colisión, y el motor carga el resultado y se juega: el
  jugador se apoya en el suelo, anda y lo paran los muros.
- `entities.qc` da función de spawn a las entidades de los mapas, de modo que
  ningún mapa se rompe con `No spawn function`. Las que aún no están
  implementadas (monstruos, ...) avisan una vez y se retiran.
- `structure.qc` trae puertas, botones, plataformas y gatillos, con las
  cadenas de puertas y la plataforma de subida de por medio.
- `items.qc` y `weapons.qc` cubren los objetos, las armas y los proyectiles: se
  recogen del mapa, se equipan, se dispara y se gastan munición.
- El agacharse encoge la caja de colisión y baja el ojo, y avisa al levantarse
  si no cabe.
- El escaparate de `direkt.qc` coloca los tres sprites de LibreQuake
  (`s_bubble`, `s_light`, `s_explod`) delante del jugador y se ve que se dibujan.
- **Falta el salto.** El motor manda el botón, pero en Quake el salto lo hace el
  juego (`+270` en la componente vertical de la velocidad y `FL_JUMPRELEASED`
  para no poder saltar encadenados), y aquí no está escrito. Tampoco hay
  enemigos, así que el juego aún no es jugable de principio a fin.

## El smoke test

`make test` no se limita a que el motor arranque: mide que el render funciona.

1. **Datos.** `tools/sprinfo.py` valida el formato de los sprites de LibreQuake
   (cabecera de 36 bytes, `numframes` en el offset `0x18`, un byte de índice de
   paleta por píxel con `0xff` transparente) y **comprueba el número real de
   frames** de cada uno. Ese último detalle es el que importa: `numframes` está
   en `0x18`, no en `0x04`, que es donde está la versión. Leyéndolo del sitio
   equivocado sale `1` siempre y el sprite parece válido mientras se pierde toda
   la    animación.
2. **Assets.** Los 35 ficheros que el juego precacha tienen que existir en el PAK.
3. **Arranque.** El motor carga nuestro `progs.dat`, encuentra el punto de
   aparición y ninguna entidad del mapa se queda sin función de spawn.
4. **Render.** Se comparan dos capturas, una con el escaparate y otra sin, y la
   zona central de la pantalla tiene que encenderse por encima de un umbral
   (≈21 niveles de 255 contra un ruido de animación del orden de 1).

El interruptor del escaparate es **de compilación**, no un cvar: `-DDIREKT_NOSHOWCASE`
(target `game-noshowcase`). El motivo es que Ironwail no tiene ningún comando
para crear un cvar, así que `direkt_showcase 1` en un `.cfg` responde
`Unknown command` y el valor nunca llega a existir.

## Detalles que ya han costado tiempo

- **Los formatos de Quake están mal documentados, y las variantes de
  QuakeSpasm/Ironwail no son las de id.** El motor solo admite `.mdl` versión 6
  y `.spr` VERA 1, y aborta con `Sys_Error` ante cualquier otra versión. Un
  ejemplo concreto de lo que cuesta: en el `.spr`, `numframes` está en el offset
  `0x18` y en `0x04` está la versión, que siempre vale 1. Leyéndolo del sitio
  equivocado el sprite parece válido y se pierde la animación entera. Pasó aquí,
  y el smoke test daba el visto bueno. La referencia verificada, con el
  `fichero:línea` de cada campo, está en [`docs/ARCHITECTURA.md`](docs/ARCHITECTURA.md);
  si algo no cuadra con lo que leas, gana ese documento.
- **El motor no deriva el `origin` de las brush-entities.** Usa `ent->origin`
  tal cual. Quien lo deduce es el QC, a mano. Por eso las brush-entities de
  LibreQuake no llevan `"origin"` en el `.bsp`: si un mapa nuestro lo olvida, la
  geometría aparece en `(0,0,0)`.
- **El motor no valida `fileofs + filelen` al cargar un `.bsp`.** Un offset mal
  calculado es lectura arbitraria de memoria, sin ningún error que lo delate.

- **La línea de comandos se trunca a 255 caracteres.** Ironwail la arma en
  `com_cmdline` (`CMDLINE_LENGTH`) y `Cmd_StuffCmds_f` la vuelve a leer del cvar
  `cmdline`. Todo `+comando` del final se corta en silencio, así que las rutas
  van relativas y lo que no quepa se mueve al `.cfg` del directorio del juego
  con `--cfg-line`.
- **`exec` no acepta rutas absolutas.** Solo nombres desnudos buscados en la ruta
  del juego, de ahí `+exec direkt-test.cfg`.
- **`localcmd` concatena sin separador.** Varias llamadas seguidas producen
  `echo Acoge B`; por eso los literales de `direkt.qc` empiezan por un espacio.
- **No hay botón de agacharse, y no se puede añadir desde el juego.** Ironwail
  quitó `in_duck` de la lista de botones: al servidor solo llegan el de disparo
  y el de salto. Tampoco reenvía al juego los comandos que teclea el cliente, así
  que un `+duck` no llega a ninguna parte, y un cvar nuevo tampoco sirve: en
  Ironwail los cvars los declara el motor en C y desde la consola no se crea
  uno, de modo que el builtin `cvar()` solo lee los del motor. Agacharse va
  entonces con dos impulsos, que es lo único que el cliente manda de forma
  fiable y que el juego ya usaba para todo:

  ```sh
  bind F4 "impulse 20"   # agacharse
  bind F5 "impulse 21"   # levantarse
  ```

  Son dos impulsos y no uno de «alterna» porque una tecla manda su comando al
  pulsar *y* al soltar, así que un «alterna» se des-haría solo. Además la
  velocidad se recorta en el QC, no en el motor: el tope de verdad es el cvar
  `sv_maxspeed`, que es global del servidor y no se puede bajar para un solo
  jugador.
- **En `worldspawn`, `self` es la entidad `world`** y asignarle un campo aborta
  con `assignment to world entity`. El `think` que espera al jugador tiene que
  vivir en una entidad normal.
- **Ironwail y Quakespasm darkened igual `lq_e1m1`**, así que su spawn oscuro no
  es un fallo del motor. Para las pruebas se usa `lqdm1`.
- **`gfx/pop.lmp` está en `pak1.pak`**, no en `pak0.pak`.
