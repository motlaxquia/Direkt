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

## Estado actual

El juego todavía **no es jugable**. Es un arranque verificado de punta a punta:

- `progs.dat` propio compilado con `fteqcc` y cargado por Ironwail sobre los
  datos de LibreQuake.
- Cycle of vida del cliente (`client.qc`), suficiente para entrar al mundo.
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
