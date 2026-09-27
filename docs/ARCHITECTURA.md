# Arquitectura y formatos binarios

Referencia de lo que el motor **realmente** acepta. Todo lo de aquí está
verificado leyendo el código de `build/src/ironwail/Quake/`, y se cita el
`fichero:línea` para que se pueda volver a comprobar. Las rutas son relativas al
directorio del motor.

> **Por qué este documento existe.** Los formatos de Quake están mal
> documentados en internet, y las variantes de QuakeSpasm/Ironwail no coinciden
> con los de id. `tools/sprinfo.py` llegó a "validar" sprites con una cabecera
> inventada de 56 bytes, y el smoke test daba el visto bueno. Cuando un parser
> parece funcionar pero el dato sale siempre igual, lo que está leyendo no es el
> campo que cree. Si un formato de aquí no cuadra con lo que leas, gana este
> documento, y se arregla.

---

## 1. Formatos que admite el motor

| Formato | Versión | Firma | ¿Admitido? |
|---|---|---|---|
| Alias model `.mdl` | MDL1 versión 6 | `IDPO` | **Sí** |
| Alias model `.mdl` | MDL2 versión 7 | `IDP2` | **No**, `Sys_Error` |
| Sprite `.spr` | VERA 1 | `IDSP` | **Sí** |
| Sprite `.spr` | VERA 2 (la clásica con paleta) | `IDSP` | **No** |
| Brush model `.bsp` | 29 / `2PSB` / `BSP2` / `Q64 ` | — | **Sí** |
| `.obj`, `.gltf`, `.glb`, `.3ds`, `.fbx` | — | — | **No**, no hay soporte |
| `.iqm` | — | — | **No**, la struct existe solo en memoria |

Las versiones las fija `modelgen.h:50` (`ALIAS_VERSION 6`) y `spritegn.h:66`
(`SPRITE_VERSION 1`). El motor **no** valida por versión con *fallback*: si no
coincide, `Sys_Error` y muere el proceso (`gl_model.c:3334`, `gl_model.c:3634`).

El reparto por firma, no por extensión, está en `Mod_LoadModel`
(`gl_model.c:396-437`): lee los 4 primeros bytes y decide. Cualquier cosa
desconocida cae en `Mod_LoadBrushModel`, o sea, se trata como `.bsp`.

### 1.1 Sustitutos de modelo

Con `r_enhancedmodels` (por defecto `1`), una referencia a `progs/x.mdl` busca
también `x.md3` y `x.md5`, en el orden de `r_enhancedmodels_priority`
(`gl_model.c:42-43`). Es la vía barata para meter geometría moderna sin tocar
el QC, pero el `.mdl` tiene que existir: pedir un `.md3` directamente es
`Sys_Error` (`gl_model.c:415-429`).

---

## 2. Sprite `.spr` VERA 1

Estructuras en `spritegn.h`, carga en `Mod_LoadSpriteModel`
(`gl_model.c:3620`).

### 2.1 Cabecera: 36 bytes

`dsprite_t` = 9 campos de 4 bytes. En Python: `struct.unpack('<3if3ifi', d)`.

| Offset | Tipo | Campo |
|---|---|---|
| `0x00` | int32 | firma `IDSP` |
| `0x04` | int32 | `version`, tiene que ser `1` |
| `0x08` | int32 | `type`, 0..4 (ver `SPR_*`) |
| `0x0c` | float32 | `boundingradius` |
| `0x10` | int32 | `width`, máximo entre frames |
| `0x14` | int32 | `height`, máximo entre frames |
| `0x18` | int32 | **`numframes`** |
| `0x1c` | float32 | `beamlength` |
| `0x20` | int32 | `synctype`, `0=ST_SYNC` `1=ST_RAND` |

⚠️ **`numframes` está en `0x18`, no en `0x04`.** En `0x04` está la versión, que
siempre vale 1, así que leer ahí da 1 siempre y el sprite parece correcto
mientras se pierde la animación entera. `tools/sprinfo.py` lo tenía mal y el
smoke test lo certificaba.

### 2.2 Frames

Después de la cabecera, `numframes` entradas. Cada una empieza por un `int32`
de tipo, y según lo que sea:

```
SPR_SINGLE (0)   dspriteframe_t {int32 origin[2]; int32 width; int32 height}   = 16 B
                 width*height bytes de índice de paleta
SPR_GROUP  (1)   int32 numframes
SPR_ANGLED (2)   numframes × float32 intervalo
                 numframes × (dspriteframe_t + width*height)
```

`SPR_ANGLED` exige exactamente 8 miembros, si no `Sys_Error`
(`gl_model.c:3576`). Un `interval <= 0` también es `Sys_Error`
(`gl_model.c:3598`).

### 2.3 Lo que NO está en el fichero

- **No hay nombre de 64 bytes** por frame.
- **No hay paleta de 256 bytes** por frame.

La paleta la carga el motor de `gfx/palette.lmp` (768 B) y los fullbrights se
detectan con `gfx/colormap.lmp` (`TexMgr_LoadPalette`, `gl_texmgr.c:735`). Los
píxeles son índices (`SRC_INDEXED`) contra esa paleta. Por eso cualquier
`--preview` que use el índice como luminancia es una aproximación, no el color
real.

### 2.4 Los sprites de LibreQuake

Solo hay 3, todos en `pak0.pak`, y los tres son `ST_SYNC` y `SPR_VP_PARALLEL`:

| Sprite | Bytes | Frames | Tamaño |
|---|---|---|---|
| `progs/s_bubble.spr` | 588 | 2 | 16x16 |
| `progs/s_light.spr` | 1080 | 1 | 32x32 |
| `progs/s_explod.spr` | 24732 | 6 | 64x64 |

Los tres se consumen enteros: `36 + nframes × (4 + 16 + w*h)`. Cero bytes de
cola. Esa aritmética es la prueba barata de que el recorrido de frames está
bien: si no cuadra, el parser se ha descolocado.

---

## 3. Alias model `.mdl` versión 6

Estructuras en `modelgen.h`, carga en `Mod_LoadAliasModel` (`gl_model.c:3315`).

### 3.1 Cabecera: 84 bytes

`mdl_t`. Todo `int`/`float` de 4 bytes, sin relleno. En Python:
`struct.unpack('<2i10f8if', d)`.

| Offset | Tipo | Campo |
|---|---|---|
| `0x00` | int32 | `ident` = `IDPO` |
| `0x04` | int32 | `version` = `6` |
| `0x08` | vec3_t | `scale` |
| `0x14` | vec3_t | `scale_origin` |
| `0x20` | float32 | `boundingradius` |
| `0x24` | vec3_t | `eyeposition` |
| `0x30` | int32 | `numskins` |
| `0x34` | int32 | `skinwidth` |
| `0x38` | int32 | `skinheight` |
| `0x3c` | int32 | `numverts` |
| `0x40` | int32 | `numtris` |
| `0x44` | int32 | `numframes` |
| `0x48` | int32 | `synctype` |
| `0x4c` | int32 | `flags` |
| `0x50` | float32 | `size` |

### 3.2 Disposición

El motor lo lee **secuencialmente, sin índices ni offsets**. Esto es lo que hay
que respectar al escribir un `.mdl`:

```
[0]  mdl_t                                  84 B
[1]  numskins × descriptor de skin
       ALIAS_SKIN_SINGLE: int32 tipo + skinwidth*skinheight bytes
       ALIAS_SKIN_GROUP:  int32 tipo + int32 numskins
                          + numskins × float32 intervalo
                          + numskins × (skinwidth*skinheight)
[2]  numverts × stvert_t                    12 B  {int32 onseam; int32 s; int32 t}
[3]  numtris  × dtriangle_t                16 B  {int32 facesfront; int32 vertindex[3]}
[4]  numframes × ( int32 frametype + frame )
       ALIAS_SINGLE: daliasframe_t 24 B {trivertx bboxmin; trivertx bboxmax; char name[16]}
                     numverts × trivertx_t 4 B  {byte v[3]; byte lightnormalindex}
       ALIAS_GROUP:  daliasgroup_t 20 B {int32 numframes; trivertx bboxmin; trivertx bboxmax}
                     numframes × float32 intervalo
                     numframes × (daliasframe_t + numverts × trivertx_t)
```

### 3.3 Lo que hay que tener en cuenta al exportar o importar

- **La posición real de un vértice es `v[k] * scale[k] + scale_origin[k]`**
  (`gl_model.c:3113-3115`). Los bytes van de 0 a 255.
- **La normal es un índice a una tabla fija de 256 entradas**, no tres floats.
  Las tablas están en `anorms.h` (256 × 3 floats) y `anorm_dots.h` (255 floats).
  Exportar a un formato con normales explícitas obliga a expandir esa tabla.
  Importar obliga a buscar la normal más cercana y guardar su índice.
- **`onseam` (`stvert_t`, bit `ALIAS_ONSEAM` = `0x20`)** marca los vértices que
  están en costura. Duplican la posición para que la iluminación no se mezcle.
- **Las skins son índices de 8 bits** y la paleta no está en el `.mdl`: sale
  del PCX del lump de texturas del `.bsp` de referencia.
- **`ALIAS_GROUP`** (frame groups multipose) lo usan 5 de los 81 modelos de
  LibreQuake (`flame`, `flame0`, `flame2`, `laser`, `spike`). Carga en
  `Mod_LoadAliasGroup` (`gl_model.c:2810`).
- `synctype` puede ser `ST_SYNC`, `ST_RAND` o `ST_FRAMETIME`
  (`modelgen.h:57`). En LibreQuake los 81 son `ST_SYNC`.

### 3.4 Límites que abortan el motor

| Límite | Valor | Efecto |
|---|---|---|
| `MAXALIASVERTS` | 32767 | `Sys_Error` |
| `MAXALIASFRAMES` | 1024 poses | `Sys_Error` |
| `MAX_SKINS` | 32 | `Sys_Error` |
| `MAXALIASTRIS_QS` | 4096 | aviso |
| `MAXALIASVERTS_QS` | 2000 | aviso |
| `MAX_LBM_HEIGHT` | 480 | aviso, solo altura de skin |

`MAX_LBM_HEIGHT` solo mira la altura. `oldone.mdl` tiene `skinwidth = 4096` y
carga igual, porque no hay tope de anchura: al escribir un exportador, avisar
del caso.

### 3.5 Los modelos de LibreQuake

Los 81 `.mdl` de los PAK son **todos** `IDPO` versión 6, sin una sola excepción.
72 de 81 ocupan el tamaño exacto que dice su cabecera; los 9 restantes
(`boss`, `tarbaby`, `eyes`, `flame`, `flame0`, `flame2`, `laser`, `spike`,
`teleport`) tienen **datos de cola que el motor ignora**, entre 749 y 1.8 MB.
Un parser que exija terminar justo en el último frame los rechazaría sin
motivo.

---

## 4. Brush model `.bsp`

Estructuras en `bspfile.h`, carga en `Mod_LoadBrushModel` (`gl_model.c:2426`).
El motor acepta la versión 29 y las variantes 2PSB, BSP2 y Q64.

**Orden de los lumps** (`bspfile.h:79-95`). No es el orden de id, y confundirlo
produce ficheros que cargan basura:

| Índice | Lump | | Índice | Lump |
|---|---|---|---|---|
| 0 | `ENTITIES` | | 8 | `LIGHTING` |
| 1 | `PLANES` | | 9 | `CLIPNODES` |
| 2 | `TEXTURES` | | 10 | `LEAFS` |
| 3 | `VERTEXES` | | 11 | `MARKSURFACES` |
| 4 | `VISIBILITY` | | 12 | `EDGES` |
| 5 | `NODES` | | 13 | `SURFEDGES` |
| 6 | `TEXINFO` | | 14 | `MODELS` |
| 7 | `FACES` | | | |

Cabecera: `version` (int32) + 15 × `{int32 fileofs; int32 filelen}` = 124 bytes.
**Todos los campos little-endian.** No existe el lump `SURFACES`: las caras van
en el índice 7, `FACES`.

### 4.1 Cuál es el mínimo que carga

Un `.bsp` **no** necesita visibilidad ni iluminación. Los lumps vacíos
degeneran a puntero nulo, y así se comportan:

| Lump | Vacío | Consecuencia |
|---|---|---|
| `ENTITIES` | tolerado | `entities = NULL`, mapa sin spawn (`gl_model.c:1015`) |
| `VISIBILITY` | tolerado | **todo visible** (`gl_model.c:192-200`) |
| `LIGHTING` | tolerado | superficies a negro o *fullbright* |
| `TEXTURES` | tolerado | todo con la textura *notexture* (`gl_model.c:558`) |
| `MARKSURFACES` | tolerado | sin *culling* por hoja |
| `FACES`+`VERTEXES`+`EDGES`+`SURFEDGES`+`TEXINFO` | tolerados | nada que dibujar |
| `PLANES` | **no** | `Mod_PointInLeaf` revienta |
| `NODES` | **no** | `Mod_SetParent(NULL, ...)` escribe sobre NULL, *segfault* |
| `LEAFS` | **no** | ídem, `leafs + 0` es `NULL` |
| `MODELS` | **no** | se desreferencia `submodels`, *segfault* |
| `CLIPNODES` | raro | el mapa carga pero **cualquier entidad móvil aborta** en `SV_RecursiveHullCheck` (`world.c:668`) |

O sea, el mínimo jugable es: cabecera, `PLANES`, `NODES`, `LEAFS`, `MODELS`, y
`CLIPNODES` en cuanto haya algo que se mueva.

⚠️ **Un lump vacío no es "puntero válido con 0 elementos"**, es
`Hunk_Alloc*(0) == NULL` (`zone.c:545`). Por eso los lumps obligatorios dan
*segfault* y no un error limpio. Es la diferencia entre un error que se lee y
uno que hay que depurar con un core dump.

### 4.2 El índice de plano NO lleva bit de signo

Esto es lo que más caro sale si se da por supuesto.

`dsnode_t.planenum` es un **`int32` usado como índice directo**:
`out->plane = loadmodel->planes + p` (`gl_model.c:1470`). No hay máscara
`& 0x7fffffff`, ni rama por signo, ni plano opuesto implícito. Además
`Mod_LoadClipnodes` **aborta si `planenum` es negativo** (`gl_model.c:2007`).

Conclusión: es la convención de Darkplaces/ericw-tools, **no** la de qbsp
original de id. Cuando un nodo necesite la cara negativa de un plano, ese plano
tiene que existir como entrada propia con la normal y la distancia negadas.

Lo que sí es convención: `children[0]` es el lado `d > 0` del plano. Elegir la
orientación del plano es decisión del compilador, porque el árbol sigue siendo
una partición válida en cualquier caso. Lo que no es opcional es escribir
`children` como índice de nodo si es `>= 0`, y como `-(leaf+1)` si es hoja
(`gl_model.c:1477-1491`, el `65535 - p` en `:1483`).

Cuidado también con el signo de `children`: el motor calcula
`65535 - p` a propósito, porque `-1` es la hoja 0. Un índice de hoja inválido no
es fatal, se remapea a la hoja sólida con un `Con_Printf`, o sea que **falla en
silencio**.

### 4.3 Otros límites y trampas

- **`dsface_t.planenum` es `short`**: una cara solo puede referenciar planos
  `0..32766`.
- **`numleafs > 32767` es error fatal** (`gl_model.c:1625`).
- **`extents` de textura `> 2000` en superficies no-`TEX_SPECIAL`** es
  `Sys_Error` "Bad surface extents" (`gl_model.c:1250`).
- **Cada `filelen` tiene que ser múltiplo exacto del tamaño de su estructura**,
  o `Sys_Error` "funny lump size". Hay 17 comprobaciones de este tipo.
- **`dmodel_t.origin` se carga y no se lee en ningún sitio.** Se puede escribir
  `0 0 0`. La colocación de un submodelo va en el `origin` de la entidad, en el
  lump `ENTITIES`.
- **`mins`/`maxs` de un submodelo se engordan 1 unidad** por el propio motor
  (`gl_model.c:2226`).
- **`headnode[0]` del submodelo 0 tiene que ser 0**, porque `SV_TruePointContents`
  arranca en el `0` fijo (`world.c:600`).
- **`headnode[3]` se carga y no se usa**: `SV_HullForEntity` solo elige 0, 1 o 2.
- **La hoja 0 es `CONTENTS_SOLID`** y no cuenta para `visleafs`.
- **El fichero tiene que pesar más de 124 bytes** para que el mapa aparezca en
  el menú (`gl_model.c:2639`). Y si el lump de entidades pesa menos de 4096
  bytes, hace falta un `message` o un `classname` conocido, o tampoco sale
  (`gl_model.c:2679-2737`).
- ⚠️ **`Mod_LoadBrushModel` no valida `fileofs + filelen <= filesize` en ningún
  punto** (`gl_model.c:2453-2492`). Un offset mal calculado es lectura
  arbitraria de memoria. Por eso un compilador propio necesita un validador
  propio: no hay red debajo.

#### El bobinado va en espejo respecto al plano

**Las caras que se ven tienen el bobinado en espejo de su plano**, no alineado.
Medido sobre `start.bsp` de LibreQuake: las 529 caras cuyo plano apunta hacia el
espectador tienen todas el bobinado opuesto a ese plano (el motor voltea el plano
de las caras con `side = 1`, y la relación se mantiene).

Con el bobinado alineado con el plano, el motor hace exactamente lo contrario de
lo que parece: el test de cara trasera del shader de cómputo (`dot(plane.xyz,
vieworg) < plane.w` en `cull/mark`) **aprueba** las caras correctas, se escriben
sus índices, y al rasterizar caen del lado equivocado y **no se ve nada del
mundo**. Ni un error, ni un aviso: solo el HUD. Por eso `write.c` recorre los
vértices al revés al sacar los surfedges.

#### El plano de un nodo y sus hijos tienen que ser coherentes

`children[0]` es el lado **positivo** del plano del nodo. Si al partir resulta que
un lado queda vacío y hay que voltear el plano, hay que voltear la variable de la
que salen **las dos cosas**: el plano que se guarda en el nodo *y* el con el que
se recortan las regiones de los dos hijos.

Voltear solo el índice deja el nodo diciendo una cosa y sus hijos siendo la otra.
El motor recorre el árbol con los planos de los nodos, así que a partir de ahí
cualquier punto cae en la hoja equivocada (el jugador, dentro de una habitación,
en la hoja de un muro) y el mundo no se dibuja. Por eso `build_tree` voltea
`split` entero y no solo `planenum`.

#### La región de una hoja es un poliedro, no una caja

La región es la intersección de los planos del camino. Llevarla como caja
envolvente (que es más grande) rompe dos cosas a la vez: el contenido de la hoja
se decide mal (una hoja dentro de un muro sale `EMPTY`) y el verificador del
invariante avisa siempre, porque para cualquier brush hay un plano del que la
caja ni cabe entera ni queda entera fuera. Con los vértices de verdad las dos
comparaciones son exactas.

### 4.4 Brush-entities: el `origin` no se deriva

En los `.bsp` de LibreQuake, **ninguna** brush-entity lleva clave `"origin"`,
en ninguno de los 13 mapas sueltos. Ni en la de Quake 1.06: el patrón es que
`qbsp` no la escribe para las entidades que ya son submodelos.

El motor **no la deduce**: usa `ent->origin` tal cual, en el render
(`r_world.c:207`) y en la colisión (`world.c:481`). Quien la deduce es el QC, a
mano, con el patrón clásico de `doors.qc`:
`self.origin = 0.5 * (self.absmin + self.abssmax)`.

Consecuencia para nuestro editor: **hay que escribir siempre `"origin"`
explícito** en el lump de entidades. Si no, la geometría aparece en `(0,0,0)`.

### 4.5 El motor no escribe `.bsp` ni lee `.map`

No existe `dumpbsp`, `writebsp`, `compile` ni `vis` en todo el código, y tampoco
hay ni una sola aparición de la cadena `.map` (`grep` vacío). El motor es **solo lector**
de BSP. En el repo no hay ni un `.map` en ninguna parte, y tampoco hay ningún
`qbsp`, `qodot`, `radiant`, `assimp` ni `blender` instalados.

Si se quiere editar niveles, el compilador y el editor son código nuestro.

### 4.6 Comandos de consola útiles

| Comando | Qué hace |
|---|---|
| `maps` / `map <n>` | lista y carga mapas |
| `viewmodel <n>` <br> `viewframe` `viewnext` `viewprev` | inspección de modelos alias |
| `mcache` | modelos en caché |
| `entities` | vuelca las entidades del cliente |
| `r_novis` | fuerza "todo visible" |
| `external_ents` | busca `<mapa>.ent` externo, por defecto activo |

`viewmodel` y familia son **solo de alias models**: `viewframe` indexa
`aliashdr_t.frames`, así que no sirven con brush models.

---

## 5. Límites del motor que el juego tiene que esquivar

Recopilados de la sesión, porque no son evidentes y cuesta mucho volver a
descubrirlos.

| Limitación | Detalle | Cómo se esquiva |
|---|---|---|
| **No hay botón de agacharse** | Ironwail quitó `in_duck`; al servidor solo llegan disparo (`button0`) y salto (`button2`) (`sv_user.c:467`) | Impulsos 20 y 21 |
| **Los comandos del cliente no llegan al juego** | `src_client` se rechaza y no hay reenvío a los progs (`cmd.c:909`) | Nada: solo `impulse` llega |
| **No se pueden crear cvars** | Los declara el motor en C; `Cvar_Set` sobre uno inexistente solo avisa (`cvar.c:499`) y desde la consola tampoco | `cvar()` solo sirve para leer los del motor |
| **`set` no es un comando** | Los comandos y los cvars están unificados: un cvar se escribe por su nombre pelado | `direkt_duck 1`, no `set direkt_duck 1` |
| **La velocidad la limita `sv_maxspeed`** | Un cvar global del servidor, no `self.maxspeed` (`sv_user.c:239`) | Recortar la velocidad en el QC |
| **`localcmd` no pone separador** | Varias llamadas seguidas se pegan (`echo Acoge B`) | Los literales empiezan por un espacio |
| **Línea de comandos de 255 caracteres** | `CMDLINE_LENGTH` en Ironwail, y `Cmd_StuffCmds_f` la relee del cvar `cmdline` | Lo que no quepa, a un `.cfg` |
| **`exec` no acepta rutas absolutas** | Solo nombres desnudos en la ruta del juego | `+exec direkt-test.cfg` |
| **La caja se puede cambiar desde el QC** | `SV_LinkEdict` usa `ent->v.mins`/`maxs` directamente (`world.c:481`) | Por eso el agachado encoge la caja sin tocar el motor |
| **En `worldspawn`, `self` es `world`** | Asignarle un campo aborta con `assignment to world entity` | El `think` vive en una entidad normal |

---

## El paquete portable

`make portable` deja `build/direkt-portable.tar.gz` con lo justo para jugar sin
compilar nada:

```
direkt-portable/
  bin/          ironwail, direkt-bsp, direkt-edit
  direkt/       progs.dat (la logica de juego)
  datos/        el directorio de LibreQuake tal cual
  fuente/       src, game, scripts, tools, docs, patches, ci, Makefile
  fuente/cache/ el tarball del motor CON su SHA-256
  direkt.sh     lanzador
  FUENTE-DEL-PAQUETE.txt
```

`direkt.sh` es `jugar` (por defecto), `test`, `editor`, `bsp` y `shell`.

Tres cosas que no son obvias:

- **El fuente va entero.** El binario es GPL y el directorio de datos tambien
  (lleva `pop.lmp` dentro de `pak1.pak`), asi que un GPL necesita su fuente
  delante. El tarball del motor va con su SHA-256 para que `make engine`
  funcione dentro del paquete sin red.
- **`DIREKT_GAMEDIR` lo pone el lanzador.** El generador de `.bsp` saca las
  texturas de ahi; en el repositorio mira en `build/lq/full/id1`, que en el
  paquete no existe, y sin la variable el `.bsp` sale sin lump TEXTURES.
- **El motor no se para con `-quit`.** Hay que esperarlo a que el mundo este
  listo mirando el log y mandarle `SIGTERM`, que es lo que hace
  `run-headless.sh`. Con `-quit` se queda esperando para siempre.

## 6. Licencias

El detalle completo está en `THIRD_PARTY.md`. Lo que no se puede perder de vista
al empaquetar:

- Direkt es **GPL-2.0** y no negociable: el motor es descendiente de Quake.
- **Un binario GPL necesita el código fuente completo acompañándolo.** En un
  `.tar.gz` redistribuible eso significa el QC de este repo, el tarball del
  motor con su SHA-256, y las partes GPL de LibreQuake.
- El directorio de datos **entero** cuenta como GPL, porque `pop.lmp` (GPL) va
  dentro de `pak1.pak` junto a los mapas. No hay modo "solo datos libres".
- El motor se puede parchear, y la maquinaria ya está montada:
  `patches/*.patch` se aplican en `scripts/fetch-deps.sh:77-90`, en orden
  alfabético, con `patch -p1 --forward` y marcador `.patches-applied`. El
  target `make patch-refresh` regenera el motor. Ahora mismo `patches/` está
  vacío y no se aplica nada.

## El generador de `.bsp` (`src/`)

Ironwail no trae compilador de mapas y LibreQuake no publica sus `.map`, así que
`direkt-bsp` los escribe desde cero. Reparto:

| Fichero | De qué se ocupa |
|---|---|
| `src/common.c` | memoria, vectores, planos, windings, brushes |
| `src/map.c` | parser del `.map` clásico |
| `src/brush.c` | división de windings y brushes, sección convexa |
| `src/compile.c` | registro de planos, árbol BSP, caras, texinfos |
| `src/clip.c` | las tres dilataciones de colisión |
| `src/write.c` | escritura del BSP29 y `check_bsp` |
| `src/main.c` | `--info`, `--check`, compilación |

### Decisiones que no son obvias

**El árbol de clipnodes va en preorden.** `gl_model.c:2521` usa `headnode[j]`
como `firstclipnode` y `world.c:668` aborta con `bad node number` en cuanto un
hijo tiene índice menor. O sea: el padre tiene que ir **antes** que sus hijos.
Con el orden natural de una recursión (crear el nodo, luego recursionar) el
padre salía el último del bloque y la primera consulta reventaba.

**La dilatación es hacia `lo - hmax` y `hi - hmin`.** El motor llama a
`SV_HullPointContents` con el *origen* del jugador, no con su caja. La caja es
`p + [hmin, hmax]`, así que se solapa con el semiplano `dot(n,x) <= d` cuando
`dot(n,p) + minH <= d`, es decir, el semiplano dilatado es `dot(n,p) <= d - minH`
con `minH = Σ (n_k > 0 ? hmin_k : hmax_k) · n_k`. Con `maxH` y sumando —que es lo
intuitivo— la brush crece hacia el lado equivocado: el suelo se dilataba hasta
`z=32` en vez de `z=24` y el jugador quedaba medio metro dentro de él al andar.

**La coordenada de un plano alineado es `dist · normal`, no `dist`.** Un plano
con normal `(0,0,-1)` y `dist 40` está en `z = -40`. Guardar `dist` tal cual
refleja los planos "hacia abajo" y el árbol deja de partir donde toca.

**`region_touches` necesita el punto *más cercano* al plano, no el más lejano.**
Para saber si una región está *fuera* de una brush, la pregunta es si para
algún plano todo el interior posible de la región queda por encima, o sea, si
`box_min >= d`. Con `box_max` se estaba comprobando si la región entera queda
*dentro* del semiplano, que no dice absolutamente nada.

**Los cinco parámetros de cara de un `.map` son `xoff yoff rot xscale yscale`.**
No `xscale yscale xoff yoff rot`, que es el orden que parece natural. Es un
error muy traicionero porque casi todos los mapas traen `textura 0 0 0 1 1`:
leído en el orden equivocado eso da escala 0 en los dos ejes, y una escala 0
deja los ejes de textura **nulos**. De ahi sale todo lo demás: los `texinfo`
deduplican entre sí y un mapa entero se queda con 2 o 3 en vez de 18, los
`extents` del lightmap salen de 1000 unidades de lado, y las superficies se
pintan negras o directamente no se pintan. Una escala 0 se trata como 1, que es
lo que hacen las herramientas.

**El plano de reparto es la mediana, no el primero que valga.** Elegir la
mediana de las coordenadas que cortan la región equilibra el árbol sola y
elimina el libro de planos "usados". Ese libro era el punto donde se colaban los
errores: un flag que se quedaba a 1 tras el primer plano descartaba todos los
siguientes, y `mejor = -1` en la elección de eje leía `por_eje[-1]`, y según lo que
hubiera ahí el eje X llegaba a no partirse nunca.

**`dsnode_t` no es todo `int32`.** `firstface` y `numfaces` son `uint16` en los
offsets 20 y 22, y `children` son `int16` en 4 y 6. Leerlos como enteros de 4
bytes devuelve números absurdos y hace que un validador dé falsos positivos.

**El lump `dheader_t` no lleva `mins`/`maxs`.** Son 124 bytes exactos:
`version` (4) más 15 lumps de 8. Los límites del mapa están en el lump
`dmodel`, como `float`, y el árbol de colisión arranca en los límites **sin
recortar 256 unidades por lado**, que no son los mismos.

### Cómo se comprueba

`scripts/bsp-test.sh` tiene cinco capas, y la última es la que de verdad importa:

1. Los tres `.map` de `src/test` compilan.
2. `--check` valida el fichero escrito: offsets, tamaños múltiplos, `planenum`,
   hijos, ciclos y nodos inalcanzables. Además se comprueba que el validador
   **falla** con un `.bsp` corrupto a propósito, porque un validador que se
   traga cualquier cosa no vale para nada.
3. `scripts/hullcheck.py` replica `SV_RecursiveHullCheck` al detalle —
  incluida la conversión de las hojas (`if (children[i] >= count) -= 65536`) y
  la regla `plane->type < 3` que hace que las normales de eje negativo usen
  producto escalar— y compara con la respuesta correcta calculada a partir de
  las brushes dilatadas. 20 puntos por mapa, 0 discrepancias.
4. El motor carga el mapa, el jugador se apoya (`FL_ONGROUND`), anda y lo
  paran los muros. Impulso 23 en `game/qc/player.qc` es la sonda que mira si la
  altura deja de bajar.

## El editor (`src/ed_*.c`)

Tres capas, separadas por lo que se puede probar sin pantalla:

| Capa | Sabe de | Fichero |
|---|---|---|
| documento | nada grafico | `src/ed_doc.c` |
| vista | matematicas | `src/ed_view.c` |
| ventana | SDL2 y OpenGL | `src/ed_gui.c` |
| texturas de la vista | atlas para OpenGL 1.2 | `src/edtex.c` |

El nucleo de geometria, `.map` y compilacion (`common.c`, `brush.c`, `map.c`,
`compile.c`, `clip.c`, `write.c`) lo comparten `direkt-bsp` y `direkt-edit`.
Cada uno anade su `main` y lo suyo encima; el `Makefile` lista los ficheros de
cada binario en vez de usar un glob, porque un glob se lleva tambien los `main`
del otro y los dos acaban con dos puntos de entrada.

### Convenciones que hay que respetar

**La vista pinta con las texturas de verdad, no con colores.** `edtex.c` junta en
una sola imagen las texturas que usa el documento (OpenGL 1.2 solo tiene una
textura por unidad) y cada cara se pinta con su casilla. Dos cosas lo hacen
funcionar:

- Las coordenadas salen de `brush_side_axes`, la **misma** función que rellena
  `texinfo_t.vecs` en el compilador. Si el editor se calculara los ejes por su
  cuenta, el mapa se vería de una manera aquí y de otra en el juego, y el
  editor estaría mintiendo sobre lo que se va a ver.
- La casilla se consigue **desplazando la coordenada**, no quedándose con la
  parte fraccionaria. Un mapa tiene coordenadas enteras y con los ejes unitarios
  las coordenadas de textura también, así que su parte fraccionaria es siempre
  0 y todas las caras salían de un solo texel. El juego repite la textura cada
  unidad de mundo y lo hace dejando crecer la coordenada (`GL_REPEAT`).

**En OpenGL la y crece hacia arriba y (0,0) es la esquina inferior izquierda.**
Al reves que en una ventana. El HUD coloca el panel de ayuda desde la altura de
la ventana hacia abajo y la barra de estado desde `y=0` hacia arriba.

**`glTexCoord2f` va antes que `glVertex3f`.** En el modo inmediato cada
coordenada de textura se aplica al vértice *siguiente*, no al anterior. Ponerla
después deja cada vértice con la del anterior.

**El culling necesita GL_BLEND para el alfa.** `glColor4f` con alfa y sin
`glEnable(GL_BLEND)` dibuja opaco: el panel de la ayuda sale negro y tapa la
escena entera.

**`glMatrixMode` hay que restaurarlo.** El HUD deja el modo en `GL_PROJECTION`;
la escena de al fotograma siguiente tiene que volver a `GL_MODELVIEW` o la
matriz de vista se carga en la de proyeccion y no se ve nada.

**`winding_reverse` copia, no invierte in situ.** Devuelve una winding nueva.
Los dos mecanismos conviven en el arbol: `brush_split` la usa, y el que la
ignora se queda con las normales al reves.

**El estado de una brush-entity es su `origin`, y el editor lo reescribe.**
Ver la nota del README: el motor no lo deduce de las brushes.

### Reparto de la propiedad de las brushes

Este es el punto mas delicado de todo el nucleo, y estava sin documentar:

- `parse_map` deja el mapa como dueno de todas sus brushes.
- `compile_map` **se las queda**: separa las del mundo en un arreglo, monta la
  lista del arbol con ese arreglo, y pone a cero las listas de brushes del mapa.
  Asi `free_map` ya no las toca y no hay doble free.
- Las brushes moviles las suelta `compile_map` mismo, porque todavia no se
  compilan.
- `free_bsp` suelta las brushes que quedaron colgando de las hojas.

El codigo anterior colgaba cada brush de la lista del mundo con `->next` sin
más, lo que dejaba cada entidad apuntando a la brush siguiente de otra entidad:
`free_map` podia liberar dos veces la misma. Ver `prepare()` en `clip.c`, que
tiene el mismo patron con los arrays estaticos por hull, y `brush_free`, que
tiene que soltar el `xstrdup` de la textura de cada cara.

### Pruebas

- `direkt-edit --selftest`: 40 pruebas de documento, ida y vuelta del `.map`,
  picking por rayo, arrastre de caras, deshacer, y que un mapa hecho en el
  editor compile a un `.bsp` que pasa `check_bsp`. Sin pantalla.
- `scripts/editor-test.sh`: lo anterior mas el dibujo. Dibuja un fotograma a un
  PPM y **comprueba que hay pixeles distintos del fondo**: el fallo tipico (el
  contexto GL se crea bien, la matriz se carga en el sitio equivocado) da una
  imagen totalmente negra sin decir nada.
- AddressSanitizer sobre el selftest: cero fugas y cero doble free.
