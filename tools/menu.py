#!/usr/bin/env python3
"""Menu de inicio de Direkt.

    tools/menu.py                    # ventana
    tools/menu.py --probar           # pruebas sin ventana
    tools/menu.py --comprobar        # consulta la release y sale

Es la puerta de entrada al paquete portable: una ventana con un lateral (el
sidebar) desde la que se juega, se echapura un rato al minijuego o se mira si
hay una release nueva.

Dos decisiones que condicionan el resto:

*   El menu NO comprueba el juego. Comprobar que el motor arranca es lo que ya
    hace direkt.sh, con su reintento al otro motor y demas. Aqui solo se llama a
    ese script y se le deja hacer su trabajo, para no tener la logica de arranque
    en dos sitios.

*   El menu NO es obligatorio. Si no hay Python con tkinter, o no hay pantalla,
    el juego sigue entrando igual con ./direkt.sh jugar. Ver --probar.

Lo de buscar la release se hace con la API de GitHub desde un hilo aparte, para
que la ventana abra al instante. Y si no hay red, o el usuario esta sin conexion,
solo se avisa: el menu no impide jugar por eso.
"""

# Sin esto, las anotaciones que mencionan tk (por ejemplo "-> tk.Frame") se
# evaluan al importar el modulo, y en un Python sin tkinter -- que es lo que
# pasa en parte de los entornos de compilacion -- reventan con un AttributeError
# de None. Con esto quedan como texto y solo hacen falta si se llega a dibujar.
from __future__ import annotations

import argparse
import json
import platform
import queue
import random
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

# ---------------------------------------------------------------------------
# Constantes
# ---------------------------------------------------------------------------

API_RELEASE = "https://api.github.com/repos/motlaxquia/Direkt/releases/latest"
URL_RELEASES = "https://github.com/motlaxquia/Direkt/releases"

#: Segundos que dura cada boton del minijuego, de menos a mas.
MIN_SEGUNDOS_BOTON = 1.0
MAX_SEGUNDOS_BOTON = 5.0

#: Duracion de una partida del minijuego.
SEGUNDOS_PARTIDA = 30.0

TIMEOUT_RED = 8.0


# ---------------------------------------------------------------------------
# Release
# ---------------------------------------------------------------------------


def comparar_version(a: str, b: str) -> int:
    """Compara dos versiones "v1.2.3".

    Devuelve >0 si a es mas nueva que b, <0 si es mas vieja y 0 si son iguales.
    Las partes que no son numeros (por ejemplo un "-beta") se comparan como
    texto y pierden contra un numero, que es como se lee en la practica.
    """
    def partes(v: str):
        limpia = v.strip().lstrip("vV")
        trozos,actual,num = [], "", True
        for ch in limpia:
            if ch.isdigit():
                actual += ch
            elif ch == "." and num:
                trozos.append((1, int(actual or 0), ""))
                actual, num = "", True
            else:
                num = False
                actual += ch
        if actual:
            trozos.append((1, int(actual), "") if num else (0, 0, actual))
        return trozos or [(0, 0, "")]

    pa, pb = partes(a), partes(b)
    for x, y in zip(pa, pb):
        if x != y:
            return 1 if x > y else -1
    if len(pa) == len(pb):
        return 0
    return 1 if len(pa) > len(pb) else -1


class Release:
    """Lo que nos cuenta la API de GitHub sobre la ultima release."""

    def __init__(self, etiqueta: str, publicada: str, enlace: str,
                 notas: str, assets: list):
        self.etiqueta = etiqueta
        self.publicada = publicada
        self.enlace = enlace
        self.notas = notas
        self.assets = assets

    @property
    def nombre(self) -> str:
        return self.etiqueta.lstrip("v")

    def asset(self, sufijo: str) -> str | None:
        for nombre, url in self.assets:
            if nombre.endswith(sufijo):
                return url
        return None


def pedir_release(url: str = API_RELEASE, timeout: float = TIMEOUT_RED) -> Release:
    """Descarga la ultima release. Lanza cualquier excepcion si no se puede."""
    peticion = urllib.request.Request(
        url, headers={"Accept": "application/vnd.github+json",
                      "User-Agent": "direkt-menu"})
    with urllib.request.urlopen(peticion, timeout=timeout) as respuesta:
        datos = json.load(respuesta)
    assets = [(a.get("name", ""), a.get("browser_download_url", ""))
              for a in datos.get("assets", [])]
    return Release(datos.get("tag_name", ""), datos.get("published_at", ""),
                   datos.get("html_url", URL_RELEASES), datos.get("body", ""),
                   assets)


def version_local(raiz: Path) -> str | None:
    """La version que trae este paquete, si el launcher la deja escrita."""
    try:
        for linea in (raiz / "direkt.conf").read_text(encoding="utf-8").splitlines():
            if linea.strip().startswith("version"):
                return linea.split("=", 1)[1].strip().strip('"')
    except OSError:
        pass
    return None


# ---------------------------------------------------------------------------
# Minijuego
# ---------------------------------------------------------------------------


class Minijuego:
    """Reglas del minijuego, sin nada de dibujo.

    Va separado de la ventana a proposito: asi se puede probar sin pantalla, que
    es como lo comprueba --probar.
    """

    def __init__(self, semilla: int | None = None):
        self.azar = random.Random(semilla)
        self.aciertos = 0
        self.fallos = 0
        self.racha = 0
        self.mejor_racha = 0

    def segundos_boton(self) -> float:
        """Cuanto vive el siguiente boton: de 1 a 5 segundos."""
        return self.azar.uniform(MIN_SEGUNDOS_BOTON, MAX_SEGUNDOS_BOTON)

    def acierto(self) -> None:
        self.aciertos += 1
        self.racha += 1
        self.mejor_racha = max(self.mejor_racha, self.racha)

    def fallo(self) -> None:
        self.fallos += 1
        self.racha = 0

    @property
    def puntuacion(self) -> int:
        return self.aciertos * 10 + self.mejor_racha * 5

    @property
    def precision(self) -> float:
        total = self.aciertos + self.fallos
        return 100.0 * self.aciertos / total if total else 0.0


# ---------------------------------------------------------------------------
# Lanzador
# ---------------------------------------------------------------------------


class Lanzador:
    """Llama a direkt.sh, que es quien sabe arrancar el juego."""

    def __init__(self, raiz: Path):
        self.raiz = raiz
        self.script = raiz / ("direkt.sh" if platform.system() != "Windows"
                             else "direkt.bat")

    def disponible(self) -> bool:
        return self.script.exists()

    def _correr(self, *args: str, capturar: bool = False):
        comando = [str(self.script), *args]
        if platform.system() == "Windows":
            # Un .bat no se ejecuta directamente con subprocess.
            comando = ["cmd", "/c", *comando]
        return subprocess.run(comando, cwd=str(self.raiz), check=False,
                              capture_output=capturar, text=True)

    def motor(self) -> str:
        """El motor configurado ahora mismo: auto, ironwail o quakespasm."""
        if not self.disponible():
            return "sin lanzador"
        try:
            r = self._correr("motor", capturar=True)
        except OSError:
            return "sin lanzador"
        for linea in (r.stdout or "").splitlines():
            if "motor elegido" in linea:
                return linea.split(":", 1)[1].strip()
        return "auto"

    def poner_motor(self, motor: str) -> None:
        self._correr("motor", motor)

    def jugar(self) -> int:
        """Arranca el juego y espera a que se cierre."""
        try:
            return self._correr("jugar").returncode
        except OSError as exc:
            print(f"ERROR: no se pudo arrancar el juego: {exc}", file=sys.stderr)
            return 1


# ---------------------------------------------------------------------------
# Ventana
# ---------------------------------------------------------------------------

try:
    import tkinter as tk
    from tkinter import font as tkfont
except ImportError:  # pragma: no cover - depende de como se instalo Python
    tk = None


TINTA = "#1a1a1a"
PAPEL = "#f4f1e8"
ACENTO = "#c8452e"
TENUE = "#6b6b6b"
APAGADO = "#9a9a9a"

FUENTES = ("DejaVu Sans", "Segoe UI", "Helvetica Neue", "Arial")
FUENTES_MONO = ("DejaVu Sans Mono", "Consolas", "Menlo", "Courier New")


class Ventana(tk.Tk if tk else object):
    """La ventana del menu, con el sidebar a la izquierda."""

    def __init__(self, raiz: Path, inicial: str = ""):
        if tk is None:
            raise SystemExit(
                "ERROR: este Python no trae tkinter, que es lo que dibuja el "
                "menu.\nSe juega igual con ./direkt.sh jugar")
        super().__init__()
        self.raiz = raiz
        self.lanzador = Lanzador(raiz)
        self.release: Release | None = None
        self.error_red = ""
        # La consulta a la API va en un hilo aparte para no congelar la ventana,
        # pero de ese hilo NO se toca Tk: solo se deja el resultado en esta cola y
        # es el hilo principal, con su after, quien lo recoge. Tk no es seguro
        # desde fuera de su hilo y llamarlo desde ahi revienta el proceso entero
        # si el usuario cierra la ventana mientras se consulta.
        self.cola: "queue.Queue[tuple]" = queue.Queue()
        self.cerrado = False

        self.title("Direkt")
        self.configure(bg=PAPEL)
        self.resizable(False, False)

        cuerpo = tkfont.nametofont("TkDefaultFont")
        cuerpo.configure(family=FUENTES[0], size=11)
        tkfont.nametofont("TkDefaultFont").configure(family=FUENTES[0], size=11)

        self.marco = tk.Frame(self, bg=PAPEL)
        self.marco.pack(fill="both", expand=True)

        self._sidebar()
        self.contenido = tk.Frame(self.marco, bg=PAPEL)
        self.contenido.pack(side="left", fill="both", expand=True,
                            padx=26, pady=26)

        # La variable de los botones de motor va antes de construir las paginas,
        # porque la de jugar la consulta al construirse.
        self.var_motor = tk.StringVar(value="auto")

        # Las tres paginas se construyen antes de mostrarse. La respuesta de la
        # API puede llegar con el usuario en cualquier parte, y si la pagina de
        # descargas no existe todavia no hay donde ponerla. Ninguna se dibuja
        # hasta que se elige en el sidebar.
        self.paginas: dict[str, tk.Frame] = {}
        for clave in ("jugar", "minijuego", "descargas"):
            self.paginas[clave] = self._construir(clave)
        self._reflejar_motor()
        self.temporizador: str | None = None
        self.protocol("WM_DELETE_WINDOW", self.cerrar)
        self.ir(inicial or "jugar")
        self.after(120, self._pedir_release)
        self.after(200, self._vaciar_cola)

    def cerrar(self) -> None:
        """Cierra Cancelando antes los temporizadores vivos.

        Si se cierra con un after() pendiente, al dispararse contra una ventana
        ya destruida el interprete de Tk revienta el proceso entero. Se cancela
        el que se sepa y se vacia la cola antes de tirar la ventana.
        """
        if self.temporizador is not None:
            try:
                self.after_cancel(self.temporizador)
            except Exception:
                pass
            self.temporizador = None
        try:
            for _ in self.tk.call("after", "info"):
                self.tk.call("after", "cancel", _)
        except Exception:
            pass
        self.cerrado = True
        self.destroy()

    # -- sidebar ----------------------------------------------------------

    def _sidebar(self) -> None:
        barra = tk.Frame(self.marco, bg=TINTA, width=210)
        barra.pack(side="left", fill="y")
        barra.pack_propagate(False)

        tk.Label(barra, text="DIREKT", bg=TINTA, fg=PAPEL,
                 font=(FUENTES[0], 22, "bold")).pack(pady=(28, 2))
        tk.Label(barra, text="un toque y se muere", bg=TINTA, fg=TENUE,
                 font=(FUENTES[0], 9)).pack(pady=(0, 10))

        # El motor y el sistema van arriba del todo, no abajo: al fondo se metia
        # debajo del boton de Salir y no se leia. Ademas conviven mejor con el
        # titulo, que es de lo que trata el menu.
        self.etiqueta_motor = tk.Label(barra, text="", bg=TINTA, fg=APAGADO,
                                       font=(FUENTES_MONO[0], 8),
                                       justify="left", anchor="w", wraplength=166)
        self.etiqueta_motor.pack(fill="x", padx=22, pady=(0, 14))
        tk.Frame(barra, bg="#3a3a3a", height=1).pack(fill="x", padx=22,
                                                    pady=(0, 14))

        self.botones: dict[str, tk.Button] = {}
        for clave, texto in (("jugar", "Jugar"),
                             ("minijuego", "Minijuego"),
                             ("descargas", "Descargas"),
                             ("salir", "Salir")):
            b = tk.Button(barra, text=texto, bg=TINTA, fg=PAPEL,
                          activebackground=ACENTO, activeforeground=PAPEL,
                          relief="flat", bd=0, anchor="w",
                          font=(FUENTES[0], 13),
                          padx=22, pady=11, cursor="hand2",
                          command=(lambda c=clave: self.ir(c)))
            b.pack(fill="x")
            self.botones[clave] = b

        tk.Frame(barra, bg=TINTA).pack(fill="both", expand=True)

    # -- paginas ----------------------------------------------------------

    def ir(self, clave: str) -> None:
        if clave == "salir":
            self.cerrar()
            return
        for nombre, boton in self.botones.items():
            boton.configure(bg=ACENTO if nombre == clave else TINTA)
        if clave not in self.paginas:
            self.paginas[clave] = self._construir(clave)
        for nombre, pagina in self.paginas.items():
            if nombre == clave:
                pagina.pack(fill="both", expand=True)
            else:
                pagina.pack_forget()

    def _construir(self, clave: str) -> tk.Frame:
        marco = tk.Frame(self.contenido, bg=PAPEL)
        if clave == "jugar":
            self._pagina_jugar(marco)
        elif clave == "minijuego":
            self._pagina_minijuego(marco)
        else:
            self._pagina_descargas(marco)
        return marco

    def _pagina_jugar(self, marco: tk.Frame) -> None:
        tk.Label(marco, text="Jugar", bg=PAPEL, fg=TINTA,
                 font=(FUENTES[0], 26, "bold")).pack(anchor="w")
        tk.Label(marco,
                 text="Tienes una vida. Un toque y se muere.",
                 bg=PAPEL, fg=TENUE, font=(FUENTES[0], 11)).pack(anchor="w",
                                                                pady=(2, 22))

        if not self.lanzador.disponible():
            tk.Label(marco, text=f"No encuentro {self.lanzador.script.name} "
                                 " junto a este archivo.", bg=PAPEL,
                     fg=ACENTO, wraplength=440, justify="left").pack(anchor="w")
            return

        juego = tk.Frame(marco, bg=PAPEL)
        juego.pack(anchor="w")
        tk.Button(juego, text="Empezar", bg=ACENTO, fg="#ffffff",
                  activebackground="#a8381f", activeforeground="#ffffff",
                  relief="flat", bd=0, font=(FUENTES[0], 15, "bold"),
                  padx=34, pady=13, cursor="hand2",
                  command=self._jugar).pack(side="left")
        tk.Button(juego, text="Comprobar motores", bg=PAPEL, fg=TINTA,
                  activebackground=TINTA, activeforeground=PAPEL,
                  relief="flat", bd=2, font=(FUENTES[0], 12),
                  padx=18, pady=11, cursor="hand2",
                  command=self._comprobar).pack(side="left", padx=(10, 0))

        tk.Label(marco, text="MOTOR", bg=PAPEL, fg=TENUE,
                 font=(FUENTES[0], 9, "bold")).pack(anchor="w", pady=(30, 6))
        # Una sola variable para los tres: si cada uno tuviera la suya no se
        # comportarian como un grupo y se podrian marcar dos a la vez.
        self.motores = {}
        for clave, texto in (("auto", "Automatico"),
                             ("ironwail", "Ironwail (Grafica)"),
                             ("quakespasm", "Quakespasm (Ligero)")):
            b = tk.Radiobutton(marco, text=texto, value=clave,
                               variable=self.var_motor, bg=PAPEL, fg=TINTA,
                               selectcolor=PAPEL, activebackground=PAPEL,
                               font=(FUENTES[0], 11), anchor="w",
                               cursor="hand2",
                               command=lambda c=clave: self._poner_motor(c))
            b.pack(anchor="w")
            self.motores[clave] = b

        self.aviso_jugar = tk.Label(marco, text="", bg=PAPEL, fg=TENUE,
                                    font=(FUENTES_MONO[0], 9), anchor="w",
                                    justify="left", wraplength=440)
        self.aviso_jugar.pack(anchor="w", pady=(16, 0))


    def _reflejar_motor(self) -> None:
        """Marca el motor configurado sin escribir nada.

        Ponerlo con invoke() disparaba el comando y guardaba en direkt.conf
        aunque el usuario no hubiera tocado nada, asi que se fija el valor de
        la variable directamente.
        """
        motor = self.lanzador.motor()
        elegido = motor.split()[0] if motor else "auto"
        if elegido not in self.motores:
            elegido = "auto"
        self.var_motor.set(elegido)
        self.etiqueta_motor.configure(
            text=f"motor: {motor}\n{platform.system()}")

    def _pagina_minijuego(self, marco: tk.Frame) -> None:
        tk.Label(marco, text="Minijuego", bg=PAPEL, fg=TINTA,
                 font=(FUENTES[0], 26, "bold")).pack(anchor="w")
        tk.Label(marco, text="Aparecen botones y tienes que pulsarlos antes de "
                             "que se acaben el tiempo.",
                 bg=PAPEL, fg=TENUE, font=(FUENTES[0], 11),
                 wraplength=460, justify="left").pack(anchor="w", pady=(2, 16))

        fila = tk.Frame(marco, bg=PAPEL)
        fila.pack(anchor="w")
        tk.Button(fila, text="Jugar 30 segundos", bg=ACENTO, fg="#ffffff",
                  activebackground="#a8381f", activeforeground="#ffffff",
                  relief="flat", bd=0, font=(FUENTES[0], 13, "bold"),
                  padx=26, pady=11, cursor="hand2",
                  command=self._empezar_minijuego).pack(side="left")

        self.marcador = tk.Label(marco, text="", bg=PAPEL, fg=TINTA,
                                 font=(FUENTES_MONO[0], 13), anchor="w")
        self.marcador.pack(anchor="w", pady=(18, 0))

        self.campo = tk.Canvas(marco, width=470, height=290, bg="#ffffff",
                               highlightthickness=2,
                               highlightbackground="#ddd8c8")
        self.campo.pack(anchor="w", pady=(10, 0))
        self.objetivo: dict | None = None
        self.reglas = Minijuego()
        self.quedan = 0.0
        self._texto_centro("Pulsa el boton de arriba para empezar.")

    def _pagina_descargas(self, marco: tk.Frame) -> None:
        tk.Label(marco, text="Descargas", bg=PAPEL, fg=TINTA,
                 font=(FUENTES[0], 26, "bold")).pack(anchor="w")
        self.info_release = tk.Label(marco, text="Buscando la ultima release...",
                                     bg=PAPEL, fg=TENUE,
                                     font=(FUENTES[0], 11), anchor="w",
                                     justify="left", wraplength=460)
        self.info_release.pack(anchor="w", pady=(4, 16))

        self.caja_hash = tk.Text(marco, width=52, height=6, bg="#ffffff",
                                 relief="flat", highlightthickness=2,
                                 highlightbackground="#ddd8c8",
                                 font=(FUENTES_MONO[0], 9), wrap="none")
        self.caja_hash.pack(anchor="w")
        self.caja_hash.configure(state="disabled")

        tk.Button(marco, text="Ver releases en GitHub", bg=PAPEL, fg=TINTA,
                  activebackground=TINTA, activeforeground=PAPEL,
                  relief="flat", bd=2, font=(FUENTES[0], 12),
                  padx=18, pady=10, cursor="hand2",
                  command=self._abrir_releases).pack(anchor="w", pady=(18, 0))

    # -- acciones ---------------------------------------------------------

    def _jugar(self) -> None:
        self.aviso_jugar.configure(text="Arrancando...")
        self.update_idletasks()
        self.withdraw()
        try:
            self.lanzador.jugar()
        finally:
            self.deiconify()

    def _comprobar(self) -> None:
        self.aviso_jugar.configure(text="Comprobando... (puede tardar)")
        self.update_idletasks()
        self.withdraw()
        try:
            self.lanzador._correr("test")
        finally:
            self.deiconify()

    def _poner_motor(self, motor: str) -> None:
        try:
            self.lanzador.poner_motor(motor)
        except OSError as exc:
            self.aviso_jugar.configure(text=f"no se pudo cambiar: {exc}")
            return
        self._reflejar_motor()

    def _texto_centro(self, texto: str) -> None:
        self.campo.delete("all")
        self.campo.create_text(235, 145, text=texto, fill=TENUE,
                               font=(FUENTES[0], 11), width=400,
                               justify="center")

    def _empezar_minijuego(self) -> None:
        if self.temporizador is not None:
            self.after_cancel(self.temporizador)
        self.reglas = Minijuego()
        self.fin = time.monotonic() + SEGUNDOS_PARTIDA
        self.quedan = SEGUNDOS_PARTIDA
        self._marcador()
        self._programar(150, self._poner_objetivo)

    def _marcador(self) -> None:
        self.marcador.configure(
            text=f"{self.reglas.aciertos} aciertos   "
                 f"{self.reglas.fallos} fallos   "
                 f"{self.reglas.puntuacion} puntos   "
                 f"{max(0.0, self.quedan):4.1f} s")

    def _programar(self, ms: float, accion) -> None:
        # after() no admite coma flotante, y los tiempos del minijuego se
        # calculan en segundos, con lo que llegan con decimales.
        self.temporizador = self.after(int(ms), accion)

    def _poner_objetivo(self) -> None:
        self.quedan = self.fin - time.monotonic()
        if self.quedan <= 0:
            self._terminar()
            return

        vida = self.reglas.segundos_boton()
        ancho = self.campo.winfo_width() or 470
        alto = self.campo.winfo_height() or 290
        ancho_b, alto_b = 104, 42
        x = random.randint(4, max(5, ancho - ancho_b - 4))
        y = random.randint(4, max(5, alto - alto_b - 4))

        self.campo.delete("all")
        boton = self.campo.create_rectangle(
            x, y, x + ancho_b, y + alto_b, fill=ACENTO, outline="")
        self.campo.create_text(x + ancho_b / 2, y + alto_b / 2, text="DALE",
                               fill="#ffffff", font=(FUENTES[0], 13, "bold"))
        # La barra se encoge: deja ver cuanto queda sin tener que poner un reloj.
        self.campo.create_rectangle(x, y + alto_b + 4,
                                    x + ancho_b * vida / MAX_SEGUNDOS_BOTON,
                                    y + alto_b + 9, fill=TINTA, outline="")
        self.campo.tag_bind(boton, "<Button-1>",
                            lambda _e: self._tocado(vida))

        self.objetivo = {"boton": boton, "vida": vida, "t0": time.monotonic()}
        self._quitar_objetivo(vida * 1000)   # segundos -> milisegundos

    def _tocado(self, vida: float) -> None:
        if self.objetivo is None:
            return
        if self.temporizador is not None:
            self.after_cancel(self.temporizador)
        self.reglas.acierto()
        self.quedan = self.fin - time.monotonic()
        self._marcador()
        self.campo.delete("all")
        self.objetivo = None
        self._programar(60, self._poner_objetivo)

    def _quitar_objetivo(self, ms: int) -> None:
        def fuera():
            if self.objetivo is not None:
                self.reglas.fallo()
                self._marcador()
                self.campo.delete("all")
                self.objetivo = None
            self._programar(40, self._poner_objetivo)
        self._programar(int(ms), fuera)

    def _terminar(self) -> None:
        self.campo.delete("all")
        self.objetivo = None
        self.quedan = 0.0
        self._marcador()
        self._texto_centro(
            f"Fin.  {self.reglas.aciertos} aciertos, {self.reglas.fallos} fallos\n"
            f"{self.reglas.puntuacion} puntos   "
            f"mejor racha {self.reglas.mejor_racha}   "
            f"{self.reglas.precision:.0f} % de acierto")

    # -- red --------------------------------------------------------------

    def _pedir_release(self) -> None:
        def worker():
            try:
                self.cola.put((pedir_release(), ""))
            except Exception as exc:                # sin red, offline, 404...
                self.cola.put((None, str(exc)))

        threading.Thread(target=worker, daemon=True).start()

    def _vaciar_cola(self) -> None:
        """Recoge lo que dejo el hilo de la API y lo pinta."""
        if self.cerrado:
            return
        while True:
            try:
                release, error = self.cola.get_nowait()
            except queue.Empty:
                break
            self.release = release
            self.error_red = error
        self._pintar_release()
        self.after(200, self._vaciar_cola)

    def _pintar_release(self) -> None:
        if self.release is None:
            self.info_release.configure(
                text=f"No se pudo mirar si hay release nueva ({self.error_red}).\n"
                     "El juego se puede descargar igual desde la pagina.",
                fg=ACENTO)
            return
        local = version_local(self.raiz)
        linea = (f"Ultima release: {self.release.nombre}"
                 f"  ({self.release.publicada[:10]})")
        if local and comparar_version(self.release.etiqueta, local) > 0:
            linea += f"\nEste paquete es la {local}. Hay una mas nueva."
            self.info_release.configure(text=linea, fg=ACENTO)
        else:
            self.info_release.configure(
                text=linea + ("\nEste paquete va al dia." if local else ""),
                fg=TINTA)

        texto = "".join(f"{url.rsplit('/', 1)[-1]}\n"
                        for nombre, url in self.release.assets if url)
        self.caja_hash.configure(state="normal")
        self.caja_hash.delete("1.0", "end")
        self.caja_hash.insert("1.0", texto or "sin ficheros adjuntos")
        self.caja_hash.configure(state="disabled")

    def _abrir_releases(self) -> None:
        import webbrowser
        webbrowser.open(self.release.enlace if self.release else URL_RELEASES)


# ---------------------------------------------------------------------------
# Modo sin ventana
# ---------------------------------------------------------------------------


def probar() -> int:
    """Comprueba lo que no necesita pantalla."""
    fallos = []

    def igual(obtenido, esperado, nombre):
        if obtenido != esperado:
            fallos.append(f"{nombre}: {obtenido!r} != {esperado!r}")

    igual(comparar_version("v1.2.3", "v1.2.3"), 0, "versiones iguales")
    igual(comparar_version("v1.3.0", "v1.2.9") > 0, True, "1.3.0 es mas nueva")
    igual(comparar_version("v0.9.0", "v0.10.0") < 0, True, "0.9 es mas vieja que 0.10")
    igual(comparar_version("v2.0.0", "v1.99.99") > 0, True, "mayor version")
    igual(comparar_version("v1.0.0", "") > 0, True, "sin version no es la ultima")

    r = Release("v1.2.3", "2026-01-01T00:00:00Z", "http://x/releases",
                "", [("direkt-portable-linux.tar.gz", "http://x/a.tar.gz"),
                     ("direkt-portable-windows.zip", "http://x/b.zip")])
    igual(r.nombre, "1.2.3", "nombre sin la v")
    igual(r.asset(".tar.gz"), "http://x/a.tar.gz", "asset por sufijo")
    igual(r.asset(".dmg"), None, "asset que no esta")

    m = Minijuego(semilla=7)
    for _ in range(200):
        s = m.segundos_boton()
        if not (MIN_SEGUNDOS_BOTON <= s <= MAX_SEGUNDOS_BOTON):
            fallos.append(f"el boton vivio {s:.2f} s, fuera de 1..5")
            break
    m.acierto()
    m.acierto()
    m.fallo()
    m.acierto()
    igual(m.aciertos, 3, "aciertos")
    igual(m.fallos, 1, "fallos")
    igual(m.mejor_racha, 2, "mejor racha")
    igual(m.puntuacion, 3 * 10 + 2 * 5, "puntuacion")
    igual(round(m.precision), 75, "precision")

    igual(Minijuego(semilla=1).segundos_boton() !=
          Minijuego(semilla=2).segundos_boton(), True, "la semilla cambia el azar")

    if tk is not None:
        igual(Ventana is not None, True, "la clase existe")
    else:
        print("AVISO: este Python no trae tkinter; el menu no abrira, "
              "pero el juego sigue entrando con ./direkt.sh jugar")

    for f in fallos:
        print(f"FALLO: {f}", file=sys.stderr)
    if fallos:
        return 1
    print("MENU TEST CORRECTO")
    return 0


def comprobar() -> int:
    """Solo la consulta a la API, para ver si hay red y si responde."""
    try:
        rel = pedir_release()
    except Exception as exc:
        print(f"ERROR: no se pudo consultar la API: {exc}", file=sys.stderr)
        return 1
    print(f"{rel.etiqueta}  {rel.publicada}")
    for nombre, url in rel.assets:
        print(f"  {nombre}  {url}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Menu de inicio de Direkt")
    ap.add_argument("--raiz", type=Path, default=Path(__file__).resolve().parent,
                    help="carpeta del paquete portable")
    ap.add_argument("--probar", action="store_true",
                    help="comprueba lo que no necesita pantalla y sale")
    ap.add_argument("--comprobar", action="store_true",
                    help="consulta la ultima release y sale")
    ap.add_argument("--pagina", choices=("jugar", "minijuego", "descargas"),
                    default="", help="abre directamente en una pagina")
    args = ap.parse_args()

    if args.probar:
        return probar()
    if args.comprobar:
        return comprobar()
    if tk is None:
        print("ERROR: este Python no trae tkinter, que es lo que dibuja el "
              "menu.\nSe juega igual con ./direkt.sh jugar", file=sys.stderr)
        return 1
    try:
        ventana = Ventana(args.raiz, args.pagina)
    except tk.TclError as exc:
        # Sin display no hay ventana que abrir: por SSH, en una sesion sin X ni
        # Wayland, o con DISPLAY mal puesto. No es un fallo del menu, asi que se
        # avisa y se deja que el lanzador juegue directamente.
        print(f"No se puede abrir una ventana aqui ({exc}).", file=sys.stderr)
        return 2
    ventana.mainloop()
    return 0


if __name__ == "__main__":
    sys.exit(main())