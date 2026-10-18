# -*- coding: utf-8 -*-
"""El socket con el simulador: 127.0.0.1:3939, texto plano, una linea por
mensaje. El protocolo entero esta en `Simulador/PROTOCOLO.md`.

Dos reglas que vienen de alli y que aqui se respetan:

- **La lectura va en un hilo**, porque `recv` bloquea y bloquear el hilo
  de la ventana la congela.
- **El hilo no pinta.** Deja la ultima linea en una variable protegida y es
  el reloj de la ventana quien la recoge. Sincronizar una vez por linea ahoga
  la interfaz: llegan centenares por segundo.
"""
import socket
import threading
import time

SALTO = b'\n'          # el protocolo cierra cada mensaje con un salto de linea


class Estado(object):
    """Lo ultimo que dijo el modulo."""

    def __init__(self):
        self.segmentos = [0] * 8
        self.leds = [False] * 8
        self.brillo = 7
        self.encendido = False
        self.ld2 = False        # el LED verde de la placa, no del modulo

    @classmethod
    def desde(cls, linea):
        """«D 0058795050775E77 L 10000000 B 7 O 1 G 0» -> Estado, o None."""
        p = linea.split()
        if len(p) < 8 or p[0] != 'D':
            return None
        e = cls()
        try:
            crudo = p[1]
            e.segmentos = [int(crudo[i * 2:i * 2 + 2], 16) for i in range(8)]
            e.leds = [c == '1' for c in p[3]][:8]
            e.brillo = int(p[5])
            e.encendido = p[7] == '1'
            # «G» va al final y es opcional: un simulador anterior no lo manda,
            # y entonces LD2 se queda apagado en vez de romper la lectura.
            if len(p) >= 10 and p[8] == 'G':
                e.ld2 = p[9] == '1'
        except (ValueError, IndexError):
            return None
        if len(e.leds) < 8:
            e.leds += [False] * (8 - len(e.leds))
        return e


class Modulo(object):
    """Cliente del socket del TM1638 simulado."""

    PUERTO = 3939

    def __init__(self, al_caerse=None):
        self._sock = None
        self._resto = b''
        self._hilo = None
        self._parar = threading.Event()
        self._cerrojo = threading.Lock()
        self._ultima = None
        self._al_caerse = al_caerse
        self.estado = Estado()

    # -- conexion ----------------------------------------------------------
    @property
    def conectado(self):
        return self._sock is not None

    def conecta(self, host='127.0.0.1', puerto=None, espera=3.0):
        if self._sock:
            return True
        puerto = puerto or self.PUERTO
        s = socket.create_connection((host, puerto), timeout=espera)
        s.settimeout(None)
        self._sock = s
        self._resto = b''
        self._parar.clear()
        self._hilo = threading.Thread(target=self._lee, daemon=True)
        self._hilo.start()
        return True

    def desconecta(self):
        """Cierre a peticion nuestra: no debe avisar de caida.

        SE CIERRA EL SOCKET, NO UN OBJETO DE FICHERO. Con `makefile` esto se
        colgaba: cerrar el fichero pide su cerrojo interno, y ese cerrojo lo
        tiene el hilo lector mientras esta parado dentro de la lectura. El
        que esperaba era el hilo de la ventana, asi que el panel se quedaba
        congelado al parar, y solo a veces, segun donde estuviera el lector.

        Cerrando el socket, la lectura bloqueada falla en el acto y el hilo
        se va solo.
        """
        self._parar.set()
        s, self._sock = self._sock, None
        if s:
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass          # ya estaba caido: da igual, lo que toca es cerrar
            try:
                s.close()
            except OSError:
                pass
        hilo = self._hilo
        self._hilo = None
        if hilo and hilo.is_alive():
            hilo.join(timeout=1.0)

    def _lee(self):
        """Trocea en lineas lo que va llegando. Se hace a mano, sobre recv,
        para no depender de un objeto de fichero que no se puede cerrar
        mientras se esta leyendo."""
        try:
            while not self._parar.is_set():
                trozo = self._sock.recv(4096)
                if not trozo:
                    break
                self._resto += trozo
                while SALTO in self._resto:
                    linea, self._resto = self._resto.split(SALTO, 1)
                    with self._cerrojo:
                        self._ultima = linea.decode('ascii', 'replace').strip()
        except (OSError, ValueError, AttributeError):
            pass

        # SI EL HILO ACABA SIN QUE SE LO HAYAMOS PEDIDO, SE CAYO LA CONEXION,
        # Y HAY QUE DECIRLO. Un display congelado que no avisa se lee como un
        # programa que no avanza, y se busca el fallo donde no esta.
        if not self._parar.is_set() and self._al_caerse:
            self._al_caerse()

    def recoge(self):
        """La ultima linea sin procesar, o None. La llama el reloj."""
        with self._cerrojo:
            linea, self._ultima = self._ultima, None
        if linea is None:
            return None
        nuevo = Estado.desde(linea)
        if nuevo:
            self.estado = nuevo
        return nuevo

    # -- escritura ---------------------------------------------------------
    def manda(self, linea):
        if not self._sock:
            return False
        try:
            self._sock.sendall((linea + '\n').encode('ascii'))
            return True
        except OSError:
            return False

    def potenciometro(self, valor):
        return self.manda('P %d' % max(0, min(4095, int(valor))))

    # Rafaga de rebote: seis transiciones en unos 20 ms, como el pulsador de
    # la placa. Va en un hilo aparte porque duerme, y dormir en el hilo de la
    # ventana la congela.
    REBOTES = 6
    REBOTE_MS = 3

    def pulsa(self, nombre, abajo, con_rebotes=False):
        """`nombre` es 'K1'..'K8' o 'B1'."""
        if not con_rebotes:
            return self.manda('%s %d' % (nombre, 1 if abajo else 0))

        def rafaga():
            for i in range(self.REBOTES):
                self.manda('%s %d' % (nombre, i % 2 if abajo else (i + 1) % 2))
                time.sleep(self.REBOTE_MS / 1000.0)
            self.manda('%s %d' % (nombre, 1 if abajo else 0))

        threading.Thread(target=rafaga, daemon=True).start()
        return True


def puerto_abierto(puerto=Modulo.PUERTO, host='127.0.0.1', espera=0.4):
    """True si alguien escucha ahi ahora mismo."""
    s = socket.socket()
    s.settimeout(espera)
    try:
        s.connect((host, puerto))
        return True
    except OSError:
        return False
    finally:
        try:
            s.close()
        except OSError:
            pass
