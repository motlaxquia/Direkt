# Direkt

Motor de nivel tipo Quake, sobre
[Ironwail](https://github.com/andrei-drexler/ironwail/tree/08d578136ff43d7d1ef38e636dfbfd3e844be7cd)
y con los recursos de [LibreQuake](https://github.com/lavenderdotpet/LibreQuake/releases/tag/v0.09-beta).
Trae un generador de `.bsp` propio, un editor de niveles, la lógica de juego
en QuakeC y una batería de pruebas que mide el render de verdad.

Licencia: **GPL-2.0**. Ver [`LICENSE`](LICENSE) y
[`THIRD_PARTY.md`](THIRD_PARTY.md).

## Descarga

| Sistema | Paquete | Lanzador |
|---|---|---|
| Linux | [⬇ direkt-portable-linux.tar.gz](https://github.com/motlaxquia/Direkt/releases/latest/download/direkt-portable-linux.tar.gz) — 127 MB | `./direkt.sh` |
| macOS | [⬇ direkt-portable-macos.tar.gz](https://github.com/motlaxquia/Direkt/releases/latest/download/direkt-portable-macos.tar.gz) — 127 MB | doble clic en `direkt.command` |
| Windows | [⬇ direkt-portable-windows.zip](https://github.com/motlaxquia/Direkt/releases/latest/download/direkt-portable-windows.zip) — 127 MB | doble clic en `direkt.bat` |

Paquete portable con los binarios ya compilados, los datos y el fuente entero,
que es lo que obliga la GPL. Los tres se compilan solos en
[`.github/workflows/build.yml`](.github/workflows/build.yml).

```sh
tar xzf direkt-portable-linux.tar.gz
cd direkt-portable-linux
./direkt.sh            # jugar
```

`./direkt.sh` es el lanzador: `jugar` por defecto, y también `test`, `editor`,
`bsp <mapa> <salida>` y `shell`.

SHA-256 del paquete:

```
3531959d65a632ea473c99fad98b8f4b52b87be63a4d75fb53860c120269896c  direkt-portable-linux.tar.gz
0fb4ea0965f2c24eb69dbe34f039c0db2e653aa52700ec3a52d52d20229d1b1b  direkt-portable-macos.tar.gz
3d72816d3dbfde1f047ee279958c041a5e202547a93fec9c0aa31da0a5b6e12e  direkt-portable-windows.zip
```

**El motor pide OpenGL 4.3**, porque dibuja el mundo con *compute shaders*. En
Linux el lanzador lo comprueba antes de arrancar y, si el OpenGL de la máquina
no llega, cae solo al rasterizador por software de Mesa (`llvmpipe`). Se puede
forzar en los dos sentidos:

El motor se elige solo según lo que anuncie la máquina, y se puede forzar:

Para dejarlo fijo, sin variables de entorno, hay un comando. Se escribe en
`direkt.conf`, dentro del paquete, y manda sobre la detección:

```sh
./direkt.sh motor                  # ver cuál se está usando
./direkt.sh motor quakespasm       # usar siempre el ligero
./direkt.sh motor ironwail         # usar siempre el principal
./direkt.sh motor auto             # volver a decidir solo
```

Para una sola partida, la variable de entorno, que va por delante del fichero:

```sh
DIREKT_SOFTWARE_GL=1 ./direkt.sh      # ir siempre por software
DIREKT_MOTOR=ironwail ./direkt.sh     # el motor principal (OpenGL 4.3)
DIREKT_MOTOR=quakespasm ./direkt.sh   # el motor ligero (OpenGL 1.5)
```

Si un motor peta al arrancar con un error de OpenGL o de shaders, prueba con el
otro: es el mismo juego con otro dibujado.

### Equipos sin OpenGL 4.3

El paquete trae **dos motores** con el mismo juego, los mismos `.bsp` y el mismo
`progs.dat`. Solo cambia el dibujado:

| Motor | Pide | Para qué |
|---|---|---|
| **Ironwail** | OpenGL 4.3 | El mejor dibujado, con *compute shaders*. |
| **Quakespasm** | OpenGL 1.5 | Equipos viejos, gráficos integrados, máquinas virtuales. |

Donde el OpenGL no llega a 4.3, el lanzador arranca con Quakespasm sin preguntar.
Y va más rápido que el otro con el rasterizador por software, porque sus shaders
son mucho más baratos.

En una máquina sin tarjeta gráfica hace falta Mesa, que va por software:

```sh
sudo apt install libsdl2-2.0-0 libgl1 libgl1-mesa-dri xvfb
```

**En macOS el motor probablemente no arrancará**: el OpenGL del sistema llega
como mucho a 4.1 y no hay forma de subirlo. El generador de mapas y el editor sí
que funcionan. Cada paquete lleva un `LEE-ME-ENTORNO.md` con los detalles.

## Qué hay aquí

| Ruta | Qué es |
| --- | --- |
| `game/qc/` | **Lo que se cambia.** La lógica de juego en QuakeC. `defs.qc` son las definiciones canónicas de id/LibreQuake; el resto es andamiaje mínimo. |
| `src/` | El generador de `.bsp` y el editor de niveles, en C. |
| `scripts/` | Dependencias, build, ejecución sin pantalla, pruebas y empaquetado. |
| `tools/` | Utilidades de auditoría de los PAK y de los sprites. |
| `docs/ARCHITECTURA.md` | Qué formatos acepta el motor de verdad, con el `fichero:línea` de cada dato. |
| `Makefile` | Todo lo que se puede hacer. `make help` las lista. |
| `build/` | Todo lo descargado o generado. Ignorado por git. |

## Puesta en marcha

```sh
make setup      # dependencias del sistema (sudo)
make deps       # descarga motor + datos, verifica SHA-256, y comprueba el GL
make engine     # compila Ironwail
make game       # compila el QuakeC -> direkt/progs.dat
make run        # con ventana
make test       # batería completa, sin pantalla
```

`make deps` deja todo en `build/`: el motor se extrae y compila ahí, y los datos
de LibreQuake se unpackean en `build/lq/full/`, que es el *basedir* que el motor
exige (`<basedir>/id1/pak0.pak`). Las versiones están fijadas por commit y por
SHA-256 en `scripts/fetch-deps.sh`.

Tres cosas de la estructura que conviene tener a mano:

- **La lógica de juego va en `game/qc/`** y se compila con `fteqcc` a
  `direkt/progs.dat`, que es lo que el motor ejecuta. `game/progs.src` dice qué
  ficheros entran y en qué orden. `defs.qc` son las definiciones canónicas de
  id/LibreQuake y no se tocan.
- **El motor se parchea, no se edita.** Los cambios van en `patches/*.patch` y se
  aplican solos en `make deps` y `make engine`, en orden alfabético, con
  `patch -p1 --forward`. Así el motor siempre se puede volver a extraer del
  tarball y el diff queda legible.
- **La prueba es parte del contrato.** `make test` mide el render comparando
  capturas, así que un cambio que rompe el mundo sale con un fallo y no con un
  "ahora se ve raro".

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

Ni Ironwail ni LibreQuake traen compilador de mapas, y LibreQuake no distribuye
los `.map` originales. Para tener niveles propios hay que escribir el `.bsp` desde
cero, y eso es lo que hace `direkt-bsp`:

```sh
make bsp                                    # compila el generador
build/bin/direkt-bsp src/test/habitacion.map build/lq/full/id1/maps/nuevo.bsp
build/bin/direkt-bsp --check build/lq/full/id1/maps/nuevo.bsp
make bsp-test                               # la prueba completa
```

Cubre el subconjunto clásico de `.map` (caras planas, el de los mapas de
LibreQuake); los *brush primitives* (`[ ... ]`) se rechazan con un error claro.
Escribe los 15 lumps de un BSP29, **incluidas las tres dilataciones de colisión**:
el jugador no se cae al suelo.

Las texturas salen de los propios `.bsp` de LibreQuake, que es donde están
embebidas (`gfx.wad` solo trae la interfaz). La biblioteca las cosecha al abrir
los PAK y el generador decide, por cada nombre del `.map`, cuál encaja
(`wall1` → `t_wall1ba` y compañía). El lump `LIGHTING` también se calcula.

`--check` no es opcional. El motor **no valida ni un `fileofs`**: un error ahí no
da un fallo, da una lectura arbitraria de memoria a mitad de una partida. El
validador revisa el fichero ya escrito en disco (offsets, tamaños, índices,
ciclos y nodos inalcanzables), no la estructura en memoria.

Todavía **no** hace: visibilidad (`VISIBILITY` sale vacío), ni brush-entities que
se mueven, ni submodelos. Las brushes móviles del `.map` se descartan al
compilar, así que un mapa con puertas móviles no funcionará hasta que eso esté
hecho.

## El editor: `direkt-edit`

Un mapa propio se coloca mucho mejor con un editor que editando el `.map` a mano,
así que el editor abre, dibuja, modifica y guarda:

```sh
make edit                              # compila (necesita libsdl2-dev)
make run-edit MAPFILE=src/test/habitacion.map
build/bin/direkt-edit --new            # mapa en blanco
build/bin/direkt-edit --selftest       # 40 pruebas, sin ventana
make editor-test                       # prueba completa, con captura
```

Ironwail ya usaba SDL2, así que el editor **no añade ninguna dependencia nueva**
al tarball. El dibujo es OpenGL 1.2 en modo inmediato, que es lo que hay en
cualquier Linux y lo que ya usa el motor. La vista pinta las texturas de verdad
con una atlas, y con los mismos ejes de textura que el compilador, para que lo que
se ve aquí sea lo que se verá en el juego.

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
| `src/edtex.c` | la atlas de texturas de la vista |
| `src/ed_test.c` | 40 pruebas de la lógica, sin pantalla |

`ed_doc` y `ed_view` no saben nada de SDL ni de OpenGL, así que casi todo se
puede comprobar en un banco de pruebas sin ventana. Solo `ed_gui` toca la
biblioteca gráfica, y aun así tiene un modo `--shot` que dibuja un fotograma a
un PPM, que es como se prueba el dibujo.

## El banco de pruebas

`make test` no se limita a que el motor arranque: mide que el render funciona.

1. **Datos.** `tools/sprinfo.py` valida el formato de los sprites de LibreQuake
   (cabecera de 36 bytes, `numframes` en el offset `0x18`, un byte de índice de
   paleta por píxel con `0xff` transparente) y **comprueba el número real de
   frames** de cada uno. Ese último detalle es el que importa: `numframes` está
   en `0x18`, no en `0x04`, que es donde está la versión. Leyéndolo del sitio
   equivocado sale `1` siempre y el sprite parece válido mientras se pierde toda
   la animación.
2. **Assets.** Los ficheros que el juego precacha tienen que existir en el PAK.
3. **Arranque.** El motor carga nuestro `progs.dat`, encuentra el punto de
   aparición y ninguna entidad del mapa se queda sin función de spawn.
4. **Render.** Se comparan dos capturas, una con el escaparate y otra sin, y la
   zona central de la pantalla tiene que encenderse por encima de un umbral.

Después viene lo propio: 13 pruebas del generador (colisión contra el hull del
motor, validador del `.bsp`, planos, cerró de los brushes) y 48 del editor
(40 de lógica más 8 de ida y vuelta, con captura).

El interruptor del escaparate es **de compilación**, no un cvar: `-DDIREKT_NOSHOWCASE`
(target `game-noshowcase`). El motivo es que Ironwail no tiene ningún comando
para crear un cvar, así que `direkt_showcase 1` en un `.cfg` responde
`Unknown command` y el valor nunca llega a existir.

## Detalles que ya han costado tiempo

Esta es la parte del repositorio que más vale la pena leer antes de tocar nada.

- **Las caras de un `.bsp` llevan el bobinado en espejo respecto a su plano, no
  alineado.** Medido sobre `start.bsp` de LibreQuake: las 529 caras que miran al
  espectador tienen el bobinado opuesto a su plano. Con el bobinado "bien", según
  uno, el motor **aprueba** las caras correctas, escribe sus índices, y al
  rasterizar caen del lado equivocado: no se ve nada del mundo, sin un solo error
  ni un aviso. Solo el HUD.
- **El plano de un nodo y el de sus hijos tienen que ser coherentes.** Si al
  partir un lado queda vacío y hay que voltear el plano, hay que voltear la
  variable de la que salen el plano guardado *y* el recorte de las regiones de
  los dos hijos. Voltear solo el índice deja el nodo diciendo una cosa y sus hijos
  siendo la otra, y como el motor recorre el árbol con los planos de los nodos,
  cualquier punto cae en la hoja equivocada.
- **La región de una hoja es un poliedro, no una caja.** Llevarla como caja
  envolvente (que es más grande) hace que el contenido de las hojas se decida mal
  y que el verificador del invariante avise siempre, gane o pierda.
- **Los cinco parámetros de cara de un `.map` son `xoff yoff rot xscale yscale`.**
  No `xscale yscale xoff yoff rot`, que es el orden que parece natural. Como
  casi todos los mapas traen `textura 0 0 0 1 1`, leído en el orden equivocado la
  escala sale 0, los ejes de textura quedan nulos, los `texinfo` se deduplican
  entre sí y el mapa entero se queda con dos o tres.
- **Una brush partida necesita más de 6 caras.** La de la sección, y la cara que
  estaba justo en el plano de corte se queda en las dos mitades. Un array de 6
  fijo aborta, y si la cara coplanar se descarta los muros se quedan sin la cara
  de dentro.
- **Los formatos de Quake están mal documentados, y las variantes de
  QuakeSpasm/Ironwail no son las de id.** El motor solo admite `.mdl` versión 6
  y `.spr` VERA 1, y aborta con `Sys_Error` ante cualquier otra versión. La
  referencia verificada, con el `fichero:línea` de cada campo, está en
  [`docs/ARCHITECTURA.md`](docs/ARCHITECTURA.md); si algo no cuadra con lo que
  leas, gana ese documento.
- **El motor no deriva el `origin` de las brush-entities.** Usa `ent->origin` tal
  cual. Quien lo deduce es el QC, a mano. Por eso las brush-entities de
  LibreQuake no llevan `"origin"` en el `.bsp`: si un mapa nuestro lo olvida, la
  geometría aparece en `(0,0,0)`.
- **El motor no valida `fileofs + filelen` al cargar un `.bsp`.** Un offset mal
  calculado es lectura arbitraria de memoria, sin ningún error que lo delate.
- **La línea de comandos se trunca a 255 caracteres.** Ironwail la arma en
  `com_cmdline` (`CMDLINE_LENGTH`) y `Cmd_StuffCmds_f` la vuelve a leer del cvar
  `cmdline`. Todo `+comando` del final se corta en silencio, así que las rutas
  van relativas y lo que no quepa se mueve al `.cfg` del directorio del juego con
  `--cfg-line`.
- **`exec` no acepta rutas absolutas.** Solo nombres desnudos buscados en la ruta
  del juego, de ahí `+exec direkt-test.cfg`.
- **`localcmd` concatena sin separador.** Varias llamadas seguidas producen
  `echo Acoge B`; por eso los literales del QC empiezan por un espacio.
- **No hay botón de agacharse, y no se puede añadir desde el juego.** Ironwail
  quitó `in_duck` de la lista de botones: al servidor solo llegan el de disparo y
  el de salto. Tampoco reenvía al juego los comandos que teclea el cliente, así
  que un `+duck` no llega a ninguna parte, y un cvar nuevo tampoco sirve: en
  Ironwail los cvars los declara el motor en C y desde la consola no se crea uno.
  Agacharse va entonces con dos impulsos, que es lo único que el cliente manda de
  forma fiable y que el juego ya usaba para todo:

  ```sh
  bind F4 "impulse 20"   # agacharse
  bind F5 "impulse 21"   # levantarse
  ```

  Son dos impulsos y no uno de «alterna» porque una tecla manda su comando al
  pulsar *y* al soltar, así que un «alterna» se des-haría solo. Además la
  velocidad se recorta en el QC, no en el motor: el tope de verdad es el cvar
  `sv_maxspeed`, que es global del servidor.
- **El salto tampoco llega como botón de un modo utilizable**, y en Quake lo hace
  el juego (`+270` en la componente vertical, y `FL_JUMPRELEASED` para no poder
  encadenar saltos). Está sin escribir.
- **En `worldspawn`, `self` es la entidad `world`** y asignarle un campo aborta con
  `assignment to world entity`. El `think` que espera al jugador tiene que vivir
  en una entidad normal.
- **Ironwail y Quakespasm darkened igual `lq_e1m1`**, así que su spawn oscuro no
  es un fallo del motor. Para las pruebas se usa `lqdm1`.
- **`gfx/pop.lmp` está en `pak1.pak`**, no en `pak0.pak`.
