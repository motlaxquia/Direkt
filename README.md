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
d9e91c91ef4069c4b8837729cac115e55d56ad1f9da1e355239849d4e54f56b1  direkt-portable-linux.tar.gz
86523fc0526efdc10a55300ba4f245b9e63e7224c4e349573115b541f41caea4  direkt-portable-macos.tar.gz
d9d9e414c1af913af03008ded0174473583c663f3b850906e8ce9d295f99176b  direkt-portable-windows.zip
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

### Si un motor no arranca

El lanzador lo mira. Si el motor elegido se muere durante el arranque con un
error de OpenGL, arranca con el otro sin preguntar. Es el mismo juego con otro
dibujado.

Pasa con GPUs que anuncian OpenGL 4.3 o más y luego no cumplen: hay
controladoras que dan cero storage buffers en el vertex shader, que es lo que
el motor necesita para el shader del mundo, y el programa de siempre es un
volcado del error del compilador de GLSL. Para dejar el otro motor siempre:

```sh
./direkt.sh motor quakespasm
```

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

## Reglas del jugador

- **Una vida.** Un toque y se muere. La constante `DIREKT_MAX_HEALTH` está al
  principio de `game/qc/defs.qc`, como `#define` y no como variable global: es lo
  primero que se incluye, así que la ven `client.qc` y `player.qc`, y al no
  ocupar sitio en la tabla de globales no desplaza los del sistema, que es lo
  que hace que el motor abortaría al cargar el `progs.dat`.
- **Sin armadura.** Con armadura, el primer toque se lo comería la armadura antes
  de hacer daño, y "un toque y muere" dejaría de ser cierto.
- **La barra de estado no se dibuja.** `scr_drawsb` vale 0 por defecto en los
  dos motores, y con una sola vida el HUD solo ocuparía sitio. Se puede volver a
  encender con `+set scr_drawsb 1`. El inventario no aparece por la misma razón:
  solo se ve el arma.

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

Los dos motores llevan el mismo `progs.dat` y los mismos mapas, así que las
pruebas tienen que dar lo mismo en los dos. `scripts/run-headless.sh` acepta
`DIREKT_TEST_ENGINE=quakespasm` para probar el ligero.

## El menu

El paquete portable se abre con un menu de ventana: `tools/menu.py`, que va al
paquete como `direkt-menu.py`.

```sh
python3 tools/menu.py             # ventana
python3 tools/menu.py --probar    # pruebas, sin pantalla
python3 tools/menu.py --comprobar # solo consulta la release y sale
```

El lateral tiene cuatro entradas: **Jugar**, **Minijuego**, **Descargas** y
**Salir**.

Tres cosas que conviene tener claras sobre el diseño:

*   **El menu no arranca el juego.** Llama a `direkt.sh`, que es quien ya sabe
    lanzar el motor, reintentar con el otro y todo lo demás. La lógica de
    arranque vive en un solo sitio.
*   **La consulta de la release va en un hilo aparte**, y ese hilo no toca Tk:
    deja el resultado en una `queue` y es el hilo principal, con su `after`, quien
    lo pinta. Tk no se puede llamar desde fuera de su hilo, y si el usuario
    cierra la ventana mientras se consulta, reventaba el proceso entero.
*   **No es obligatorio.** Sin Python, sin `tkinter` o sin display, el lanzador
    avisa y entra al juego igualmente. Para eso `direkt.sh jugar` existe.

El minijuego son botones que aparecen en un sitio al azar y duran de 1 a 5
segundos, con una barra que se encoge para ver cuánto queda. Dura 30 segundos.
Las reglas están en la clase `Minijuego`, separada de la ventana, para que se
puedan probar sin pantalla.

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

## La música se pide por nombre

La música de un mapa se puede pedir de dos maneras. La de siempre, con un número:

```
"sounds" "5"                // el motor monta music/track05.ogg
```

El 5 no dice nada. No se sabe qué pista es cuál sin abrir los ficheros, y no se
puede elegir una pista que no se llame `trackNN`. Con varias pistas de LibreQuake
el orden acaba siendo el del número, que es un orden arbitrario.

Direkt admite además el nombre del fichero:

```
"music" "bosque.ogg"        // el motor busca ese fichero en music/
```

Da igual dónde esté el fichero. Los de LibreQuake se llaman por su escenario
(`gloomliths.ogg`), y los tuyos como quieras: `bosque`, `nivel1_marcha`... También vale sin extensión (`"music" "bosque"`), y entonces
suena la primera que encaje.

Las dos formas conviven. Un mapa con `"sounds"` sigue yendo exactamente por su
camino de antes, byte a byte: el servidor manda el número y el motor lo monta
igual que siempre. Para que no se pisen, el segundo byte que ya viajaba en
`svc_cdtrack` dice cuál de las dos es.

### Los ficheros se llaman por el escenario

Las pistas no se llaman `track04.ogg`, sino por el sitio donde suenan. El nombre
es el del primer mapa que usa esa pista en el orden de la campaña (e1, e2, e3,
e4, e0, y después los `lqdm`, que son de muerte):

| numero | fichero                  | escenario                  | mapas que la usan |
|-------:|--------------------------|----------------------------|-------------------|
| 2      | `reservada_02.ogg`       | sin mapa                   | — |
| 3      | `reservada_03.ogg`       | sin mapa                   | — |
| 4      | `calibur.ogg`            | e1m8 That's my Ex, Calibur! | e1m8, e2m2, e2m5, e3m3 |
| 5      | `feudal_anomaly.ogg`     | e1m2 The Feudal Anomaly    | e1m2, e1m3, e0m3, e0m8, lqdm2 |
| 6      | `rats_behind_bars.ogg`   | e1m1 Rats Behind Bars      | e1m1, e0m1, e3m1, e4m1 |
| 7      | `dismal_shores.ogg`      | e1m4 Dismal Shores         | e1m4, e1m7, e0m7, e4m4, lqdm7, lqdm10 |
| 8      | `corpse_army.ogg`        | e2m3 Corpse army           | e2m3, e3m2, e3m4, lqdm1, lqdm3, lqdm9, lqdm12 |
| 9      | `gloomliths.ogg`         | e1m5 Gloomliths            | e1m5, e0m2, lqdm4 |
| 10     | `holy_bloated_corpse.ogg`| e3m6 Holy Bloated Corpse   | e3m6, e4m3, e4m5, e0m4, e0m6, lqdm6 |
| 11     | `feint_free_funtime.ogg` | e0m4 Feint-free funtime    | e0m4, lqdm5, lqdm8 |

Cada pista se usa en varios mapas, así que no hay un único sitio suyo: por eso el
nombre es el del primero y la tabla guarda todos. Para cambiar el reparto,
edita `music/pistas.txt`, que se puede leer a mano.

Los mapas de LibreQuake ponen `"sounds"` con un número y sus `.bsp` viven dentro
de los PAK, así que `music/pistas.txt` es lo que traduce ese número al nombre
nuevo:

```
4        calibur.ogg              e1m8 That's my Ex, Calibur! e1m8, e2m2, ...
```

Un mapa con `"sounds" 5` sigue sonando exactamente lo mismo de antes. La tabla
solo se mira si no hay ningún `trackNN`: si alguien deja los nombres viejos,
manda lo que haya.

Para ver las dos listas dentro del juego:

```
bgm_catalogo             # las pistas que hay, ordenadas por nombre
bgm_catalogo tabla       # el numero viejo de cada una y su fichero
```

Para ver qué hay y en qué orden, dentro del juego:

```
bgm_catalogo
```

```
10 pistas en music/:
    1  music/calibur.ogg
    2  music/corpse_army.ogg
    3  music/dismal_shores.ogg
    ...
```

Los índices empiezan por 1; el 0 es "ninguna", como siempre.

La lista sale de las rutas de búsqueda del motor, no de un directorio suelto: el
juego arranca con `-basedir datos` y la música está en `datos/music/`, así que un
`music/` a pelo no valdría. Por eso da igual dónde esté. Y va **ordenada por
nombre**, porque el orden en que un sistema devuelve un directorio no está
garantizado: si el índice dependiera de ahí, el número que manda el servidor no
significaría lo mismo en el cliente.

Solo se ven los ficheros sueltos de los directorios. Si alguien mete música
dentro de un PAK, la clave `"music"` no lo encontrará y seguirá mandando la pista
por número, que es lo de siempre. La música de Direkt va suelta, así que no pasa.

Si el mapa pide una pista que no está, el motor lo dice en vez de quedarse mudo:

```
El mapa pide la música "no-existe.ogg" y no está en music/
```

y sigue por el número, para que el mapa no se quede sin música ninguna.

`direkt-bsp` también avisa, al compilar:

```
direkt-bsp: música del mapa: bosque.ogg
direkt-bsp: música del mapa: pista 5 (número; usa "music" para ponerla por nombre)
direkt-bsp: aviso, este mapa no pide música: pon "music" "nombre.ogg" en el worldspawn
```

No comprueba que el fichero exista: el compilador no sabe dónde está la carpeta
`music/`, y un aviso falso es peor que callarse.

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
