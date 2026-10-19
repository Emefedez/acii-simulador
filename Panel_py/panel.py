# -*- coding: utf-8 -*-
"""El panel del simulador: la ventana.

Traduccion del panel de Delphi a Tkinter, para que funcione tambien en Linux
y en macOS. La apariencia, la geometria y los colores son los mismos: salen
de `Panel/uPanel.pas`, no se han vuelto a inventar.

    python panel.py [programa.elf] [--arrancar] [--esperar] [--ordenes]

    --arrancar   arranca el simulador nada mas abrir, con ese programa
    --esperar    marca «Esperar al depurador»: la maquina no echa a andar
                 hasta que GDB se engancha (localhost:3333) y la manda seguir
    --ordenes    lee ordenes por la entrada estandar, una por linea, en JSON:
                 {"orden": "arranca", "elf": "...", "esperar": false}
                 {"orden": "para"}   {"orden": "cierra"}
                 y cuenta lo que pasa por la salida estandar, en lineas que
                 empiezan por «@». Es lo que usa la extension de VS Code.
                 (@arrancando elf, @gdb 3333, @monitor N, @conectado,
                 @parado, @caido, @fallo texto, @cerrado)

Todo se dibuja en un unico lienzo. El unico control de verdad es la caja de
texto de la ruta, porque hay que poder escribir en ella.
"""
import json
import os
import queue
import sys
import threading
import tkinter as tk
from tkinter import filedialog, font as tkfont, messagebox

import dibujo as D
import tipografias
from modulo import Modulo, puerto_abierto
from emulador import (Emulador, ErrorEmulador, PUERTO_GDB, PUERTO_MODULO,
                      aviso_de_version, busca_renode)
import cubeide

AQUI = os.path.dirname(os.path.abspath(__file__))

# Cuanto esperamos a que Renode abra el puerto. La primera vez compila los
# cuatro modelos en C# y tarda lo suyo.
ESPERA_ARRANQUE_MS = 90000
LATIDO_MS = 40                  # 25 repintados por segundo, como el original

# Donde va LD2: el centro de su LED, en el hueco entre el final del
# potenciometro (x = 437) y el boton B1 (x = 606), a la altura del boton. Es de
# la placa, como B1, y por eso va a su lado y no en el modulo.
X_LD2 = 580

# B1 y su «mantener», debajo.
B1_X, B1_Y, B1_AN = D.ANCHO - D.MARGEN - 134, D.Y_POTE + 26, 134
B1_PASTILLA = (B1_X, B1_Y + D.ALTO_FILA + 7, B1_X + B1_AN,
               B1_Y + D.ALTO_FILA + 7 + D.ALTO_PASTILLA)

# Los tamaños de letra, en pixeles de diseño: se escalan con el lienzo. Son
# algo mayores que los 9-11 puntos del panel de Delphi, que se leian mal.
PX_ROTULO, PX_TEXTO, PX_MONO, PX_TECLA, PX_BOTON, PX_MINI = 13, 14, 13, 16, 16, 11


class Lienzo(tk.Canvas):
    """Un Canvas que dibuja en unidades de diseño (D.ANCHO x D.ALTO) y las
    lleva al tamaño que tenga la ventana.

    Antes la geometria iba en pixeles fijos: en una pantalla HiDPI la placa
    salia diminuta, y al cambiar el tamaño de la ventana se quedaba pequeña en
    una esquina, o cortada. Ahora todo `create_*` pasa por aqui: las
    coordenadas se multiplican por `f` y se centran con (`ox`, `oy`), y los
    sucesos del raton hacen el camino inverso con `a_diseno`. Los tamaños de
    letra los escala Fuente.
    """

    def __init__(self, master, **kw):
        tk.Canvas.__init__(self, master, **kw)
        self.f, self.ox, self.oy = 1.0, 0.0, 0.0

    def _create(self, tipo, args, kw):
        args = list(tk._flatten(args))
        cnf = args.pop() if args and isinstance(args[-1], dict) else {}
        kw = dict(cnf, **kw)
        pts = [v * self.f + (self.oy if i % 2 else self.ox)
               for i, v in enumerate(args)]
        if tipo != 'text':
            for k in ('width', 'height'):
                if k in kw:
                    kw[k] = max(1, kw[k] * self.f)
        return tk.Canvas._create(self, tipo, pts, kw)

    def a_diseno(self, ev):
        """El suceso, con x e y en unidades de diseño."""
        ev.x = (ev.x - self.ox) / self.f
        ev.y = (ev.y - self.oy) / self.f
        return ev


class Fuente(tkfont.Font):
    """Una tipografia con el tamaño en pixeles de diseño. `measure` contesta
    en las mismas unidades, que es en las que se colocan las cosas."""

    def __init__(self, lienzo, px, **kw):
        self.lienzo, self.px = lienzo, px
        tkfont.Font.__init__(self, size=-px, **kw)

    def escala(self, f):
        self.configure(size=-max(6, int(round(self.px * f))))

    def measure(self, text, displayof=None):
        return tkfont.Font.measure(self, text, displayof) / self.lienzo.f


def escala_inicial(raiz):
    """El tamaño con que se abre la ventana, respecto al diseño.

    Tk no se entera de la escala del escritorio: en XWayland con
    `force_zero_scaling`, o en cualquier X11 sin Xft.dpi, cree que la pantalla
    es de 96 ppp aunque sea HiDPI. Se toma la mayor entre lo que dice X y
    GDK_SCALE -la que el escritorio fija para las aplicaciones X- y se recorta
    para que quepa. ACII_ESCALA la impone a mano. Despues la ventana se puede
    estirar a gusto: el lienzo sigue a la ventana.
    """
    try:
        return max(0.5, float(os.environ['ACII_ESCALA']))
    except (KeyError, ValueError):
        pass
    f = raiz.winfo_fpixels('1i') / 96.0
    try:
        f = max(f, float(os.environ.get('GDK_SCALE', '')))
    except ValueError:
        pass
    cabe = min(0.85 * raiz.winfo_screenheight() / D.ALTO,
               0.9 * raiz.winfo_screenwidth() / D.ANCHO)
    return max(1.0, min(f, cabe))


class Panel(tk.Tk):

    def __init__(self, elf_inicial='', esperar=False, ordenes=False):
        # ANTES de crear la ventana: Tk consulta la lista de familias al
        # arrancar, y una fuente añadida después ya no entra.
        tipografias.carga()
        tk.Tk.__init__(self)
        self.title('ACII · Módulo LED&KEY')
        self.configure(bg=D.GRIS100)
        self._icono()

        self.modulo = Modulo(al_caerse=self._se_cayo)
        self.emulador = Emulador()
        self.ordenes = queue.Queue() if ordenes else None

        self.tecla_encima = 0
        self.tecla_pulsada = 0          # con el raton
        self._teclado = [False] * 9     # 1..8, para no repetir con el teclado
        self._teclado_b1 = False
        self._sueltas = {}              # anti-repeticion de X11
        self.b1_pulsado = False         # con el raton
        self.fijas = set()              # 'K1'..'K8', 'B1' con «mantener»
        self._enviado = {}              # lo ultimo mandado de cada una
        self.pote = 0
        self.rebotes = tk.BooleanVar(value=False)
        self.esperar = tk.BooleanVar(value=esperar)
        self.mensaje = 'sin conexión'
        self.arrancando = 0             # ms que llevamos esperando
        self.gdb_avisado = True         # ya se dijo que GDB esta listo
        self.version_vista = False      # la de Renode se mira una vez

        f = escala_inicial(self)
        self.lienzo = Lienzo(self, width=int(D.ANCHO * f),
                             height=int(D.ALTO * f), bg=D.GRIS100,
                             highlightthickness=0)
        self.lienzo.pack(fill='both', expand=True)
        self.minsize(D.ANCHO // 2, D.ALTO // 2)
        self.lienzo.f = f
        self._tipografias()

        self.botones = []               # los dibujados: hit-test a mano
        self.entrada = tk.Entry(self, font=self.f_mono, bg='#FFFFFF',
                                fg=D.TINTA, relief='flat',
                                highlightthickness=0, borderwidth=0)
        if elf_inicial:
            self.entrada.insert(0, elf_inicial)
        self._repinta()
        self._ata_sucesos()
        self.after(LATIDO_MS, self._latido)

    # -- puesta a punto ----------------------------------------------------
    def _icono(self):
        ico = os.path.join(AQUI, 'PanelACII.png')
        if os.path.exists(ico):
            try:
                self.iconphoto(True, tk.PhotoImage(file=ico))
            except tk.TclError:
                pass

    def _tipografias(self):
        """Las tres de la asignatura. Vienen en `tipografias/` y las carga
        tipografias.carga() para este proceso. Si aun asi faltan, Tk cae en la de
        reserva sin quejarse, y se avisa por consola: una ventana con otra
        tipografia se ve rara y nadie sabe por que."""
        disponibles = set(tkfont.families())
        for f in (D.TIPO_ROTULO, D.TIPO_TEXTO, D.TIPO_MONO):
            if f not in disponibles:
                print('Aviso: no está instalada la fuente %r; se usará otra.'
                      % f)
        c = self.lienzo
        self.f_rotulo = Fuente(c, PX_ROTULO, family=D.TIPO_ROTULO,
                               weight='bold')
        self.f_texto = Fuente(c, PX_TEXTO, family=D.TIPO_TEXTO)
        self.f_mono = Fuente(c, PX_MONO, family=D.TIPO_MONO)
        self.f_tecla = Fuente(c, PX_TECLA, family=D.TIPO_TEXTO, weight='bold')
        self.f_boton = Fuente(c, PX_BOTON, family=D.TIPO_TEXTO, weight='bold')
        self.f_mini = Fuente(c, PX_MINI, family=D.TIPO_TEXTO, weight='bold')
        self.fuentes = (self.f_rotulo, self.f_texto, self.f_mono,
                        self.f_tecla, self.f_boton, self.f_mini)
        for fu in self.fuentes:
            fu.escala(c.f)

    def _repinta(self):
        """Todo de nuevo: al montar y cada vez que cambia la escala."""
        c = self.lienzo
        c.delete('all')
        self.x_placa, self.y_placa = D.MARGEN, D.MARGEN
        self.an_placa = D.ANCHO - 2 * D.MARGEN
        y = D.Y_PROGRAMA + 25
        c.create_window(D.MARGEN + 9, y + 6, anchor='nw', window=self.entrada,
                        width=402, height=20)
        self._pinta_fijo()
        self._pinta_display()
        self._pinta_teclas()
        self._pinta_mandos()
        self._pinta_estado()

    def _cambia_tamano(self, ev):
        """La ventana cambio de tamaño: la placa la llena, sin deformarse."""
        c = self.lienzo
        f = min(ev.width / float(D.ANCHO), ev.height / float(D.ALTO))
        ox = (ev.width - D.ANCHO * f) / 2.0
        oy = (ev.height - D.ALTO * f) / 2.0
        if abs(f - c.f) < 0.002 and abs(ox - c.ox) < 1 and abs(oy - c.oy) < 1:
            return
        c.f, c.ox, c.oy = f, ox, oy
        for fu in self.fuentes:
            fu.escala(f)
        # Al arrastrar el borde llegan decenas por segundo: se repinta una
        # vez, cuando se calman.
        if getattr(self, '_repintado', None):
            self.after_cancel(self._repintado)
        self._repintado = self.after(20, self._repinta)

    def _ata_sucesos(self):
        c = self.lienzo
        d = lambda f: (lambda ev: f(c.a_diseno(ev)))
        c.bind('<Configure>', self._cambia_tamano)
        c.bind('<Button-1>', d(self._raton_abajo))
        c.bind('<ButtonRelease-1>', d(self._raton_arriba))
        c.bind('<Button-3>', d(self._raton_derecho))
        c.bind('<Motion>', d(self._raton_mueve))
        c.bind('<B1-Motion>', d(self._raton_arrastra))
        c.bind('<Leave>', self._raton_sale)
        self.bind_all('<KeyPress>', self._tecla_abajo)
        self.bind_all('<KeyRelease>', self._tecla_arriba)
        self.protocol('WM_DELETE_WINDOW', self._cierra)

    # -- dibujo ------------------------------------------------------------
    def _pinta_fijo(self):
        c = self.lienzo
        x0, y0 = self.x_placa, self.y_placa
        x1, y1 = x0 + self.an_placa, y0 + D.ALTO_PLACA

        D.caja(c, x0, y0, x1, y1, D.BISEL, 10)
        D.caja(c, x0 + 2, y0 + 2, x1 - 2, y1 - 2, D.PLACA, 9)
        D.rotulo(c, x0 + 18, y0 + 14, 'LED & KEY', D.SERIGRAFIA, self.f_rotulo)
        D.rotulo(c, x1 - 18, y0 + 14, 'TM1638', D.SERIGRAFIA, self.f_rotulo,
                 'ne')
        D.caja(c, x0 + 14, y0 + 38, x1 - 14, y0 + 128, D.VENTANILLA, 6)

        D.rotulo(c, D.MARGEN, D.Y_POTE, 'POTENCIÓMETRO', D.ACENTO_TINTA,
                 self.f_rotulo)
        D.rotulo(c, D.ANCHO - D.MARGEN, D.Y_POTE, 'PULSADOR DE LA PLACA',
                 D.ACENTO_TINTA, self.f_rotulo, 'ne')
        # El rotulo de LD2 va a la izquierda del LED, en SU fila, y no encima
        # junto a «PULSADOR DE LA PLACA»: con la pantalla al 125 % ese texto
        # crece hacia la izquierda y se montaba encima del de LD2.
        # Con aire respecto al LED: encendido, su halo sale 5 pixeles hacia
        # fuera y, mas pegado, tocaba el texto.
        D.texto(c, X_LD2 - 22, D.Y_POTE + 42, 'LD2', D.ACENTO_TINTA,
                self.f_rotulo, 'e')
        D.rotulo(c, D.ANCHO - D.MARGEN, D.Y_POTE + 88,
                 'TECLADO:  1 A 8  ·  ESPACIO = B1  ·  CLIC DERECHO = MANTENER',
                 D.GRIS600, self.f_mini, 'ne')

        c.create_line(D.MARGEN, D.Y_PROGRAMA - 12, D.ANCHO - D.MARGEN,
                      D.Y_PROGRAMA - 12, fill=D.GRIS300)
        D.rotulo(c, D.MARGEN, D.Y_PROGRAMA, 'PROGRAMA QUE SE VA A EJECUTAR',
                 D.ACENTO_TINTA, self.f_rotulo)

        # La caja de la ruta: un filete gris y fondo blanco, con el Entry
        # dentro. El borde por defecto de Tk es un marco hundido que no pega
        # con el resto.
        y = D.Y_PROGRAMA + 25
        D.caja(c, D.MARGEN, y, D.MARGEN + 420, y + D.ALTO_FILA, D.GRIS400, 4)
        D.caja(c, D.MARGEN + 1, y + 1, D.MARGEN + 419, y + D.ALTO_FILA - 1,
               '#FFFFFF', 4)

    def _pinta_display(self):
        c = self.lienzo
        c.delete('display')
        e = self.modulo.estado
        x0 = self.x_placa + D.x_primer_digito(self.an_placa)
        paso = D.DIGITO_AN + D.DIGITO_HUECO
        for i in range(D.N_DIGITOS):
            seg = e.segmentos[i] if e.encendido else 0
            D.digito(c, x0 + i * paso, self.y_placa + 52, D.DIGITO_AN,
                     D.DIGITO_AL, seg, 'display')
        for i in range(D.N_DIGITOS):
            D.led(c, x0 + i * paso + (D.DIGITO_AN - 18) // 2,
                  self.y_placa + 142, 18, e.encendido and e.leds[i], 'display')

        # LD2 NO depende de que el modulo este encendido: es de la placa. La
        # P1 no enciende el TM1638 nunca, y es justo la practica de LD2.
        D.led(c, X_LD2 - 9, D.Y_POTE + 33, 18, e.ld2, 'display', verde=True)

    def _pinta_teclas(self):
        c = self.lienzo
        c.delete('teclas')
        for i in range(1, D.N_TECLAS + 1):
            x0, y0, x1, y1 = D.caja_tecla(i, self.x_placa, self.y_placa,
                                          self.an_placa)
            D.tecla(c, x0, y0, x1 - x0, y1 - y0, 'S%d' % i,
                    self.tecla_encima == i, self._pulsada('K%d' % i),
                    self.f_tecla, 'teclas')
            fija = 'K%d' % i in self.fijas
            px0, py0, px1, py1 = D.caja_pastilla(i, self.x_placa,
                                                 self.y_placa, self.an_placa)
            D.pastilla(c, px0, py0, px1 - px0, py1 - py0,
                       'mantenida' if fija else 'mantener', fija,
                       self.f_mini, True, 'teclas')

    def _pinta_mandos(self):
        c = self.lienzo
        c.delete('mandos')
        self.botones = []

        # potenciometro
        voltios = self.pote * 3.3 / 4095.0
        D.texto(c, D.MARGEN + 156, D.Y_POTE,
                '%d  ·  %s V' % (self.pote, ('%.2f' % voltios).replace('.',
                                                                      ',')),
                D.GRIS600, self.f_mono, 'nw', 'mandos')
        y = D.Y_POTE + 40
        self.pote_x0, self.pote_x1 = D.MARGEN + 8, D.MARGEN + 417
        c.create_line(self.pote_x0, y, self.pote_x1, y, fill=D.GRIS300,
                      width=4, tags='mandos')
        cx = self.pote_x0 + (self.pote_x1 - self.pote_x0) * self.pote / 4095.0
        c.create_oval(cx - 8, y - 8, cx + 8, y + 8, fill=D.ACENTO,
                      outline=D.ACENTO, tags='mandos')

        # B1, y debajo su «mantener»
        b1 = self._pulsada('B1')
        self._boton('B1 · pulsado' if b1 else 'B1', B1_X, B1_Y, B1_AN,
                    D.ALTO_FILA, 'pulsador', pulsado=b1, nombre='b1')
        x0, y0, x1, y1 = B1_PASTILLA
        fija = 'B1' in self.fijas
        D.pastilla(c, x0, y0, x1 - x0, y1 - y0,
                   'B1 mantenido' if fija else 'mantener B1 pulsado', fija,
                   self.f_mini, False, 'mandos')
        self.botones.append(dict(nombre='fija_b1', x0=x0, y0=y0 - 2, x1=x1,
                                 y1=y1 + 2,
                                 accion=lambda: self._alterna_fija('B1')))

        # casillas
        self._casilla(D.MARGEN + 8, D.Y_POTE + 70, self.rebotes,
                      'Simular rebotes del pulsador, como en la placa',
                      'rebotes')
        self._casilla(D.MARGEN + 8, D.Y_ESTADO, self.esperar,
                      'Esperar al depurador', 'esperar')

        # botones del programa
        y = D.Y_PROGRAMA + 25
        self._boton('Examinar…', D.MARGEN + 440, y, 134, D.ALTO_FILA, 'claro',
                    accion=self._examinar, nombre='examinar')
        vivo = self.emulador.vivo or self.modulo.conectado
        self._boton('Parar' if vivo else 'Arrancar',
                    D.ANCHO - D.MARGEN - 134, y, 134, D.ALTO_FILA, 'acento',
                    accion=self._arrancar_o_parar, nombre='arrancar')
        if vivo:
            self._boton('Reiniciar', D.MARGEN + 588, y, 134, D.ALTO_FILA,
                        'claro', accion=self._reiniciar, nombre='reiniciar')

    def _boton(self, texto, x, y, an, al, estilo, accion=None, pulsado=False,
               nombre=''):
        c = self.lienzo
        encima = getattr(self, '_boton_encima', '') == nombre
        if estilo == 'pulsador':
            # Como las teclas: en reposo sobresale con su sombra, y pulsado
            # baja, se oscurece y lleva un filete. Antes pulsado y «raton
            # encima» eran el mismo azul claro y no se veia la diferencia.
            if pulsado:
                y += 3
                D.caja(c, x - 2, y - 2, x + an + 2, y + al + 2, D.TINTA, 6,
                       'mandos')
                D.caja(c, x, y, x + an, y + al, D.ACENTO_PULSADO, 4, 'mandos')
            else:
                D.caja(c, x, y + 3, x + an, y + al + 3, D.ACENTO_SOMBRA, 4,
                       'mandos')
                D.caja(c, x, y, x + an, y + al,
                       D.ACENTO2 if encima else D.ACENTO, 4, 'mandos')
            tinta = '#FFFFFF'
        elif estilo == 'acento':
            fondo = D.ACENTO2 if (encima or pulsado) else D.ACENTO
            tinta = '#FFFFFF'
            D.caja(c, x, y, x + an, y + al, fondo, 4, 'mandos')
        else:
            fondo = D.GRIS200 if encima else D.GRIS100
            tinta = D.TINTA
            D.caja(c, x, y, x + an, y + al, D.GRIS400, 4, 'mandos')
            D.caja(c, x + 1, y + 1, x + an - 1, y + al - 1, fondo, 4, 'mandos')
        D.texto(c, x + an // 2, y + al // 2, texto, tinta, self.f_boton,
                'center', 'mandos')
        self.botones.append(dict(nombre=nombre, x0=x, y0=y, x1=x + an,
                                 y1=y + al, accion=accion))

    def _casilla(self, x, y, variable, texto, nombre):
        c = self.lienzo
        c.create_rectangle(x, y, x + 16, y + 16, fill='#FFFFFF',
                           outline=D.GRIS600, tags='mandos')
        if variable.get():
            c.create_line(x + 4, y + 8, x + 7, y + 12, fill=D.ACENTO, width=2,
                          tags='mandos')
            c.create_line(x + 7, y + 12, x + 12, y + 4, fill=D.ACENTO,
                          width=2, tags='mandos')
        D.texto(c, x + 26, y - 1, texto, D.TINTA, self.f_texto, 'nw', 'mandos')
        an = self.f_texto.measure(texto) + 26
        self.botones.append(dict(nombre=nombre, x0=x, y0=y, x1=x + an,
                                 y1=y + 18,
                                 accion=lambda v=variable: self._alterna(v)))

    def _alterna(self, variable):
        variable.set(not variable.get())
        self._pinta_mandos()

    def _pinta_estado(self):
        c = self.lienzo
        c.delete('estado')
        conectado = self.modulo.conectado
        color = D.ACENTO_TINTA if conectado else D.GRIS600
        c.create_oval(D.ANCHO - 372, D.Y_ESTADO + 5, D.ANCHO - 364,
                      D.Y_ESTADO + 13, fill=color, outline=color,
                      tags='estado')
        D.texto(c, D.ANCHO - 356, D.Y_ESTADO - 1, self.mensaje, color,
                self.f_texto, 'nw', 'estado')
        if conectado:
            D.texto(c, D.ANCHO - D.MARGEN, D.Y_ESTADO,
                    'GDB en el puerto %d' % PUERTO_GDB, D.GRIS600,
                    self.f_mono, 'ne', 'estado')

    # -- pulsar ------------------------------------------------------------
    # Una tecla o B1 esta pulsada si lo esta por CUALQUIERA de los tres
    # caminos: el raton, el teclado o su «mantener». Cada cambio pasa por
    # _sincroniza, que solo manda al simulador cuando el total cambia: soltar
    # el raton sobre una tecla mantenida no la suelta.
    def _pulsada(self, nombre):
        if nombre in self.fijas:
            return True
        if nombre == 'B1':
            return self.b1_pulsado or self._teclado_b1
        i = int(nombre[1])
        return self.tecla_pulsada == i or self._teclado[i]

    def _sincroniza(self, nombre):
        abajo = self._pulsada(nombre)
        if self._enviado.get(nombre, False) != abajo:
            self._enviado[nombre] = abajo
            self.modulo.pulsa(nombre, abajo, self.rebotes.get())
        if nombre == 'B1':
            self._pinta_mandos()
        else:
            self._pinta_teclas()

    def _alterna_fija(self, nombre):
        """El «mantener» de una tecla o de B1: la deja pulsada hasta que se
        vuelve a tocar, para poder avanzar paso a paso en el depurador con el
        boton apretado."""
        if nombre in self.fijas:
            self.fijas.discard(nombre)
        else:
            self.fijas.add(nombre)
        self._sincroniza(nombre)

    # -- raton -------------------------------------------------------------
    def _boton_en(self, x, y):
        for b in self.botones:
            if b['x0'] <= x <= b['x1'] and b['y0'] <= y <= b['y1']:
                return b
        return None

    def _raton_abajo(self, ev):
        self.lienzo.focus_set()
        i = D.pastilla_en(ev.x, ev.y, self.x_placa, self.y_placa,
                          self.an_placa)
        if i:
            self._alterna_fija('K%d' % i)
            return
        i = D.tecla_en(ev.x, ev.y, self.x_placa, self.y_placa, self.an_placa)
        if i:
            # Pulsar una tecla mantenida la suelta: es lo que uno espera.
            if 'K%d' % i in self.fijas:
                self._alterna_fija('K%d' % i)
                return
            self.tecla_pulsada = i
            self._sincroniza('K%d' % i)
            return
        b = self._boton_en(ev.x, ev.y)
        if b and b['nombre'] == 'b1':
            if 'B1' in self.fijas:
                self._alterna_fija('B1')
                return
            self.b1_pulsado = True
            self._sincroniza('B1')
            return
        if self._sobre_pote(ev.x, ev.y):
            self._mueve_pote(ev.x)
            return
        if b and b['accion']:
            b['accion']()

    def _raton_derecho(self, ev):
        """Clic derecho en una tecla o en B1: mantener / soltar."""
        i = D.tecla_en(ev.x, ev.y, self.x_placa, self.y_placa, self.an_placa)
        if i:
            self._alterna_fija('K%d' % i)
            return
        b = self._boton_en(ev.x, ev.y)
        if b and b['nombre'] == 'b1':
            self._alterna_fija('B1')

    def _raton_arriba(self, ev):
        if self.tecla_pulsada:
            i, self.tecla_pulsada = self.tecla_pulsada, 0
            self._sincroniza('K%d' % i)
        if self.b1_pulsado:
            self.b1_pulsado = False
            self._sincroniza('B1')

    def _raton_mueve(self, ev):
        i = D.tecla_en(ev.x, ev.y, self.x_placa, self.y_placa, self.an_placa)
        if i != self.tecla_encima:
            self.tecla_encima = i
            self._pinta_teclas()
        b = self._boton_en(ev.x, ev.y)
        nombre = b['nombre'] if b else ''
        if nombre != getattr(self, '_boton_encima', ''):
            self._boton_encima = nombre
            self._pinta_mandos()

    def _raton_arrastra(self, ev):
        if self._sobre_pote(ev.x, ev.y) or self.tecla_pulsada == 0:
            if abs(ev.y - (D.Y_POTE + 40)) < 30:
                self._mueve_pote(ev.x)

    def _raton_sale(self, ev):
        if self.tecla_encima:
            self.tecla_encima = 0
            self._pinta_teclas()

    def _sobre_pote(self, x, y):
        return (self.pote_x0 - 10 <= x <= self.pote_x1 + 10
                and abs(y - (D.Y_POTE + 40)) < 14)

    def _mueve_pote(self, x):
        t = (x - self.pote_x0) / float(self.pote_x1 - self.pote_x0)
        self.pote = max(0, min(4095, int(round(t * 4095))))
        self.modulo.potenciometro(self.pote)
        self._pinta_mandos()

    # -- teclado -----------------------------------------------------------
    def _escribiendo(self):
        """Con el foco en la caja de texto las teclas son texto, no atajos:
        las rutas llevan dígitos y espacios."""
        try:
            return self.focus_get() is self.entrada
        except KeyError:
            return False

    def _cual(self, ev):
        """Que boton toca para esa tecla, o None.

        Se mira el `keysym` ANTES que el caracter. El caracter no siempre
        llega: no viene en los sucesos sinteticos, y con algunas
        distribuciones de teclado no es el que uno esperaria. El keysym de
        un digito es el propio digito, en cualquier distribucion.
        """
        k = ev.keysym
        if k == 'space':
            return 'B1'
        if k.startswith('KP_'):          # el teclado numerico vale igual
            k = k[3:]
        if len(k) == 1 and k in '12345678':
            return 'K%s' % k
        if len(ev.char) == 1 and ev.char in '12345678':
            return 'K%s' % ev.char
        return None

    def _tecla_abajo(self, ev):
        if self._escribiendo():
            return
        nombre = self._cual(ev)
        if not nombre:
            return
        # Anti-repeticion: en X11 mantener una tecla llega como pares
        # soltar/pulsar seguidos, y en Windows como pulsar repetido.
        pendiente = self._sueltas.pop(nombre, None)
        if pendiente is not None:
            self.after_cancel(pendiente)
            return
        if nombre == 'B1':
            if self._teclado_b1:
                return
            self._teclado_b1 = True
        else:
            i = int(nombre[1])
            if self._teclado[i]:
                return
            self._teclado[i] = True
        # Como con el raton: pulsar una mantenida la suelta.
        if nombre in self.fijas:
            self.fijas.discard(nombre)
        self._sincroniza(nombre)

    def _tecla_arriba(self, ev):
        if self._escribiendo():
            return
        nombre = self._cual(ev)
        if not nombre:
            return
        # La suelta se aplaza 30 ms: si es una repeticion, el pulsar que
        # viene detras la cancela y la tecla no parpadea.
        self._sueltas[nombre] = self.after(
            30, lambda n=nombre: self._suelta_de_verdad(n))

    def _suelta_de_verdad(self, nombre):
        self._sueltas.pop(nombre, None)
        if nombre == 'B1':
            self._teclado_b1 = False
        else:
            self._teclado[int(nombre[1])] = False
        self._sincroniza(nombre)

    # -- arranque ----------------------------------------------------------
    def _examinar(self):
        inicial = os.path.dirname(self.entrada.get()) or os.path.expanduser('~')
        ruta = filedialog.askopenfilename(
            title='El programa que se va a ejecutar',
            initialdir=inicial,
            filetypes=[('Programas compilados', '*.elf'),
                       ('Todos los ficheros', '*.*')])
        if ruta:
            self.entrada.delete(0, tk.END)
            self.entrada.insert(0, os.path.normpath(ruta))

    def _arrancar_o_parar(self):
        if self.emulador.vivo or self.modulo.conectado:
            self._para_todo()
        else:
            self._arranca()

    def _reiniciar(self):
        self._para_todo()
        self._arranca()

    def _arranca(self):
        elf = self.entrada.get().strip('" ')
        if not elf or not os.path.exists(elf):
            self._avisa('fallo', 'no existe el programa %s' % (elf or '(vacío)'))
            messagebox.showwarning(
                'El programa no existe',
                'No encuentro el fichero:\n\n%s\n\n'
                'Compila el proyecto en CubeIDE —el .elf sale en su carpeta '
                'Debug— y elígelo con Examinar.' % (elf or '(vacío)'),
                parent=self)
            return
        # Desde VS Code la depuracion la pone la extension: la configuracion
        # de CubeIDE no hace falta, y su aviso solo interrumpe.
        if self.ordenes is None:
            ruta, aviso = cubeide.asegura(elf)
            if ruta:
                messagebox.showinfo(
                    'Configuración de depuración creada',
                    'He dejado la configuración de depuración en el '
                    'proyecto:\n\n%s\n\nEn CubeIDE tienes que refrescar el '
                    'proyecto (F5) para que aparezca.'
                    % os.path.basename(ruta), parent=self)
        # La version de Renode, una vez por sesion. Solo avisa: quien tenga
        # otra y le funcione, que siga.
        renode = busca_renode()
        if renode and not self.version_vista:
            self.version_vista = True
            aviso = aviso_de_version(renode)
            if aviso:
                messagebox.showwarning('Otra versión de Renode', aviso,
                                       parent=self)
        try:
            self.emulador.arranca(elf, self.esperar.get())
        except ErrorEmulador as e:
            self._avisa('fallo', str(e).replace('\n', ' '))
            messagebox.showerror('No se ha podido arrancar', str(e),
                                 parent=self)
            return
        self.arrancando = 1
        self.gdb_avisado = False
        self.mensaje = 'arrancando el simulador…'
        self._avisa('arrancando', elf)
        self._bloquea(True)
        self._pinta_mandos()
        self._pinta_estado()

    def _para_todo(self):
        self.modulo.desconecta()
        self.emulador.para()
        self.arrancando = 0
        self.gdb_avisado = True
        self._enviado = {}              # el simulador nuevo empieza sin nada
        self.mensaje = 'sin conexión'
        self._avisa('parado')
        self._bloquea(False)
        self._pinta_display()
        self._pinta_mandos()
        self._pinta_estado()

    def _bloquea(self, si):
        """Con el emulador vivo la ruta no se toca: cambiarla no cambiaría lo
        que se está ejecutando, y además así los atajos de teclado funcionan
        sin que el foco se quede en la caja."""
        self.entrada.configure(state='disabled' if si else 'normal')
        if not si:
            return
        self.lienzo.focus_set()

    def _motivo_del_registro(self, cuantas=6):
        """Las últimas líneas con pinta de error, para meterlas en el aviso."""
        try:
            with open(self.emulador.registro, encoding='utf-8',
                      errors='replace') as f:
                lineas = [l.rstrip() for l in f if l.strip()]
        except OSError:
            return 'No he podido leer el registro.'
        if not lineas:
            return 'El registro está vacío: Renode no llegó ni a arrancar.'
        # Las de ERROR son las que explican; si no hay, valen las ultimas.
        malas = [l for l in lineas if 'ERROR' in l or 'Unhandled' in l]
        return '\n'.join((malas or lineas)[-cuantas:])[:700]

    def _gdb_listo(self):
        """Si Renode ya abrio el servidor de GDB. Se mira en su registro y no
        conectando al puerto: una conexion de prueba es un depurador que se
        engancha y se va, y con «Esperar al depurador» eso no es inocuo."""
        try:
            with open(self.emulador.registro, encoding='utf-8',
                      errors='replace') as f:
                return 'GDB server with all CPUs started' in f.read()
        except OSError:
            return False

    def _se_cayo(self):
        """Lo llama el hilo lector. No toca la ventana: deja el aviso y el
        latido se encarga."""
        self._caida = True

    # -- ordenes desde fuera (VS Code) ----------------------------------------
    def _avisa(self, que, detalle=''):
        """Una linea para quien lanzo el panel con --ordenes."""
        if self.ordenes is None:
            return
        try:
            print(('@%s %s' % (que, detalle)).rstrip(), flush=True)
        except (OSError, ValueError):
            pass                        # quien escuchaba ya no esta

    def escucha_ordenes(self):
        def lee():
            for linea in sys.stdin:
                linea = linea.strip()
                if linea:
                    self.ordenes.put(linea)
        threading.Thread(target=lee, daemon=True).start()

    def _atiende(self, linea):
        try:
            o = json.loads(linea)
        except ValueError:
            self._avisa('fallo', 'orden ilegible: %s' % linea)
            return
        que = o.get('orden')
        if que == 'arranca':
            if self.emulador.vivo or self.modulo.conectado:
                self._para_todo()
            self.entrada.configure(state='normal')
            self.entrada.delete(0, tk.END)
            self.entrada.insert(0, o.get('elf', ''))
            self.esperar.set(bool(o.get('esperar')))
            self._arranca()
            self.deiconify()
            self.lift()
        elif que == 'para':
            self._para_todo()
        elif que == 'cierra':
            self._cierra()

    # -- el latido ---------------------------------------------------------
    def _latido(self):
        if self.ordenes is not None:
            while not self.ordenes.empty():
                self._atiende(self.ordenes.get_nowait())
        if getattr(self, '_caida', False):
            self._caida = False
            self.modulo.desconecta()
            self.mensaje = 'se ha caído la conexión'
            self._avisa('caido')
            self._bloquea(False)
            self._pinta_mandos()
            self._pinta_estado()
        if not self.gdb_avisado and self.emulador.vivo and self._gdb_listo():
            self.gdb_avisado = True
            self._avisa('gdb', str(PUERTO_GDB))
        if self.arrancando:
            self.arrancando += LATIDO_MS
            if puerto_abierto(PUERTO_MODULO, espera=0.05):
                self._conecta()
            elif not self.emulador.vivo:
                self.arrancando = 0
                self.mensaje = 'el emulador se ha cerrado solo'
                self._avisa('fallo', 'Renode ha terminado sin abrir el puerto')
                self._bloquea(False)
                self._pinta_mandos()
                self._pinta_estado()
                # SE ENSEÑA EL FINAL DEL REGISTRO AQUI MISMO. Decir «mira el
                # registro» y dar una ruta obliga a irse al terminal, y lo que
                # de verdad hace falta son las tres ultimas lineas, que dicen
                # el motivo. Paso con un puerto ocupado: Renode abortaba y el
                # panel se quedaba callado.
                messagebox.showerror(
                    'El emulador se ha cerrado',
                    'Renode ha terminado sin abrir el puerto.\n\n%s\n\n'
                    'El registro completo está en:\n%s'
                    % (self._motivo_del_registro(), self.emulador.registro),
                    parent=self)
            elif self.arrancando > ESPERA_ARRANQUE_MS:
                self.arrancando = 0
                self.mensaje = 'el simulador no ha arrancado'
                self._avisa('fallo', 'el simulador no ha arrancado a tiempo')
                self._pinta_estado()
        if self.modulo.conectado and self.modulo.recoge():
            self._pinta_display()
        self.after(LATIDO_MS, self._latido)

    def _conecta(self):
        try:
            self.modulo.conecta()
        except OSError:
            return
        self.arrancando = 0
        self.mensaje = ('esperando al depurador' if self.esperar.get()
                        else 'conectado al simulador')
        # El puerto del monitor de Renode (el primero libre desde 1234): la
        # extension lo usa para adelantar uwTick. Antes que «conectado».
        self._avisa('monitor', str(self.emulador.monitor))
        self._avisa('conectado')
        self.modulo.potenciometro(self.pote)
        # Lo que este mantenido sigue pulsado en el simulador nuevo.
        for nombre in sorted(self.fijas):
            self._sincroniza(nombre)
        self._pinta_mandos()
        self._pinta_estado()

    def _cierra(self):
        self.modulo.desconecta()
        self.emulador.para()
        self._avisa('cerrado')
        self.destroy()


def main():
    elf = ''
    for a in sys.argv[1:]:
        if a.lower().endswith('.elf'):
            elf = os.path.abspath(a)
    if not busca_renode():
        print('Aviso: no encuentro Renode. El panel abre igual, pero no podrá')
        print('arrancar nada hasta que instales la 1.16.1: https://github.com/renode/renode/releases/tag/v1.16.1')
    panel = Panel(elf, esperar='--esperar' in sys.argv,
                  ordenes='--ordenes' in sys.argv)
    if '--ordenes' in sys.argv:
        panel.escucha_ordenes()
    if '--arrancar' in sys.argv and elf:
        panel.after(100, panel._arranca)
    panel.mainloop()


if __name__ == '__main__':
    main()
