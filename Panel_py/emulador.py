# -*- coding: utf-8 -*-
"""Arrancar y parar Renode, en Windows, Linux y macOS.

Es la traduccion de `Panel/uLogicRenode.pas`, con la misma secuencia que ya
usaba `simula.py`: copiar los modelos y la plataforma a una carpeta de trabajo
SIN ESPACIOS, escribir el guion `.resc`, lanzar Renode con el monitor en un
puerto y esperar a que el modulo abra el suyo.

Lo unico que cambia entre sistemas son las rutas y como se mata el proceso.
"""
import glob
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import time

from modulo import puerto_abierto

ES_WINDOWS = sys.platform.startswith('win')
ES_MAC = sys.platform == 'darwin'

AQUI = os.path.dirname(os.path.abspath(__file__))

PUERTO_MODULO = 3939      # el socket del display
PUERTO_MONITOR = 1234     # el monitor de Renode
PUERTO_GDB = 3333         # el servidor GDB al que se engancha CubeIDE

PIEZAS = [
    'PuertoGPIO.cs',
    'TemporizadorSTM32.cs',
    'PotenciometroADC.cs',
    'TM1638Panel.cs',
    'nucleo_f401re.repl',
    'STM32F40x.svd.gz',     # lo carga el .repl; sin el, Renode lo descarga
]

GUION = """:name: ACII simulador
using sysbus
include @{t}/PuertoGPIO.cs
include @{t}/TemporizadorSTM32.cs
include @{t}/PotenciometroADC.cs
include @{t}/TM1638Panel.cs
mach create "ACII"
machine LoadPlatformDescription @{t}/nucleo_f401re.repl
sysbus LoadELF @{t}/{elf}
machine StartGdbServer {gdb}
{start}"""


class ErrorEmulador(Exception):
    """Algo impide arrancar, y hay que contarlo entero."""


# ---------------------------------------------------------------------------
# Donde esta cada cosa
# ---------------------------------------------------------------------------
def plataforma():
    """Los modelos y el .repl: al lado en el archivo, o en plataforma/ en el
    paquete que se entrega."""
    dentro = os.path.join(AQUI, 'plataforma')
    if os.path.isdir(dentro):
        return dentro
    arriba = os.path.dirname(AQUI)          # .../Simulador
    if os.path.exists(os.path.join(arriba, 'nucleo_f401re.repl')):
        return arriba
    return os.path.join(arriba, 'plataforma')


def carpeta_trabajo():
    """Una ruta SIN ESPACIOS: Renode no sabe interpretar `include @` con
    espacios, y el archivo de la asignatura vive en una ruta que tiene cinco.
    """
    if ES_WINDOWS:
        return r'C:\ACII_sim'
    # En instalaciones normales se usa la carpeta de la cuenta.  El
    # instalador portable puede fijar ACII_SIM_HOME para equipos donde la
    # cuenta está bloqueada (por ejemplo, un entorno gestionado).
    destino = os.environ.get('ACII_SIM_HOME',
                             os.path.join(os.path.expanduser('~'), '.acii_sim'))
    if ' ' in destino:                       # una casa con espacios: al /tmp
        return '/tmp/acii_sim'
    return destino


def busca_renode():
    """Renode no se instala en el PATH en Windows, y en Linux depende de si
    vino del .deb, del tarball o del AppImage."""
    candidatos = [shutil.which('renode')]
    if ES_WINDOWS:
        # Primero el que viene con el simulador, en ..\Renode: la version
        # probada. Mismo orden que BuscaRenode en uLogicRenode.pas.
        candidatos.insert(0, os.path.normpath(
            os.path.join(AQUI, '..', 'Renode', 'renode.exe')))
        candidatos += [
            r'C:\Program Files\Renode\Renode.exe',
            r'C:\Program Files (x86)\Renode\Renode.exe',
        ]
    elif ES_MAC:
        # El de dentro del .app, NO el `macos_run.command` que hay al lado:
        # ese es el de doble clic y abre una ventana de Terminal.
        dentro = 'Renode.app/Contents/MacOS/renode'
        candidatos += [
            os.path.join('/Applications', dentro),
            os.path.join(os.path.expanduser('~'), 'Applications', dentro),
            '/opt/homebrew/bin/renode',
            '/usr/local/bin/renode',
        ]
    else:
        casa = os.path.expanduser('~')
        candidatos += [
            '/usr/bin/renode',
            '/opt/renode/renode',
            '/opt/renode_portable/renode',
            os.path.join(casa, 'renode_portable', 'renode'),
            os.path.join(casa, '.local', 'bin', 'renode'),
        ]
        # También se admite el Renode portable que acompaña al paquete de la
        # asignatura.  Así el simulador queda autocontenido y no depende del
        # PATH ni de permisos de instalación en /opt.
        paquete = os.path.dirname(os.path.dirname(AQUI))
        candidatos.append(os.path.join(paquete, 'renode_portable', 'renode'))
        # El AppImage no tiene un sitio fijo: se busca por nombre.
        for sitio in (casa, os.path.join(casa, 'Descargas'),
                      os.path.join(casa, 'Downloads'),
                      os.path.join(casa, 'Aplicaciones'),
                      os.path.join(casa, 'Applications')):
            candidatos += sorted(glob.glob(os.path.join(sitio,
                                                        'renode*.AppImage')))
    for c in candidatos:
        if c and os.path.exists(c):
            return c
    return None


# La version con la que esta probado todo: modelos, placa, medidas y los
# verificadores de examen. Con otra, un alumno se quedo colgado al montar la
# placa (la 1.17) y el panel solo decia que el puerto no se abria a tiempo.
VERSION_PROBADA = '1.16.1'
_versiones = {}


def version_renode(ruta):
    """'1.16.1', o None si no se pudo saber. Tarda unos segundos -Renode
    arranca entero para contestar-, asi que se guarda."""
    if ruta not in _versiones:
        v = None
        try:
            salida = subprocess.run([ruta, '--version'], capture_output=True,
                                    timeout=60).stdout.decode('utf-8', 'replace')
            m = re.search(r'Renode v(\d+\.\d+\.\d+)', salida)
            v = m.group(1) if m else None
        except (OSError, subprocess.SubprocessError):
            pass
        _versiones[ruta] = v
    return _versiones[ruta]


def aviso_de_version(ruta):
    """El texto del aviso si ese Renode no es la version probada, o None."""
    v = version_renode(ruta)
    if v == VERSION_PROBADA:
        return None
    return ('Este Renode es la versión %s, y el simulador está probado con la '
            '%s. Con otra puede quedarse colgado al arrancar, sin dar más '
            'explicación.\n\nSe baja de github.com/renode/renode/releases '
            '(la v%s).\n\nPuedes seguir, pero si no arranca, es lo primero '
            'que hay que cambiar.' % (v or 'desconocida', VERSION_PROBADA,
                                      VERSION_PROBADA))


def raices_cubeide():
    """Donde se instala STM32CubeIDE en cada sistema."""
    if ES_WINDOWS:
        return sorted(glob.glob(r'C:\ST\STM32CubeIDE*'))
    casa = os.path.expanduser('~')
    fuera = []
    for patron in ('/opt/st/stm32cubeide*', os.path.join(casa, 'st',
                                                         'stm32cubeide*'),
                   os.path.join(casa, 'STM32CubeIDE*')):
        fuera += sorted(glob.glob(patron))
    return fuera


def busca_gdb():
    """El gdb que trae CubeIDE, en su carpeta de complemento con version."""
    exe = 'arm-none-eabi-gdb.exe' if ES_WINDOWS else 'arm-none-eabi-gdb'
    for raiz in raices_cubeide():
        for medio in ('STM32CubeIDE/plugins', 'plugins'):
            patron = os.path.join(raiz, medio, '*gnu-tools-for-stm32*')
            for c in sorted(glob.glob(patron)):
                cand = os.path.join(c, 'tools', 'bin', exe)
                if os.path.exists(cand):
                    return cand
    return shutil.which(exe) or 'arm-none-eabi-gdb'


def puerto_libre(preferido):
    """El puerto pedido si está libre; si no, cualquiera que lo esté.

    Se pide al sistema uno efímero y se devuelve: hay una carrera teórica
    entre soltarlo y que Renode lo coja, pero es de milisegundos y la
    alternativa —probar puertos a mano— tiene la misma carrera y encima
    tarda más.
    """
    if not puerto_abierto(preferido, espera=0.2):
        return preferido
    s = socket.socket()
    try:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]
    finally:
        s.close()


def _quien_usa(puerto):
    """La orden que le dice a cada sistema quién tiene ese puerto cogido."""
    if ES_WINDOWS:
        return 'netstat -ano | findstr :%d' % puerto
    if ES_MAC:
        return 'lsof -nP -iTCP:%d -sTCP:LISTEN' % puerto
    return "ss -lptn 'sport = :%d'" % puerto


# ---------------------------------------------------------------------------
# El ciclo de vida
# ---------------------------------------------------------------------------
class Emulador(object):

    def __init__(self):
        self.proceso = None
        self.monitor = PUERTO_MONITOR      # el de verdad se elige al arrancar
        self.registro = os.path.join(carpeta_trabajo(), 'renode.log')

    @property
    def vivo(self):
        return self.proceso is not None and self.proceso.poll() is None

    def prepara(self, elf, esperar=False):
        """Deja en la carpeta de trabajo todo lo que Renode va a leer.

        Con `esperar` el guion no lleva `start`: la maquina se queda en el
        reinicio hasta que el depurador se engancha y la manda seguir, asi que
        se puede parar en main sin que el programa haya echado a andar.
        """
        trabajo = carpeta_trabajo()
        if not os.path.isdir(trabajo):
            os.makedirs(trabajo)

        origen = plataforma()
        for p in PIEZAS:
            ruta = os.path.join(origen, p)
            if not os.path.exists(ruta):
                raise ErrorEmulador(
                    'falta una pieza del simulador: %s\nla busqué en %s'
                    % (p, origen))
            shutil.copy2(ruta, os.path.join(trabajo, p))

        nombre = os.path.basename(elf)
        shutil.copy2(elf, os.path.join(trabajo, nombre))

        guion = os.path.join(trabajo, 'simula.resc')
        with open(guion, 'w', encoding='utf-8') as f:
            f.write(GUION.format(t=trabajo.replace('\\', '/'), elf=nombre,
                                 gdb=PUERTO_GDB,
                                 start='' if esperar else 'start\n'))
        return guion

    def arranca(self, elf, esperar=False):
        if puerto_abierto(PUERTO_MODULO):
            raise ErrorEmulador(
                'ya hay un simulador corriendo en el puerto %d.\n'
                'Ciérralo antes, o usa Reiniciar.' % PUERTO_MODULO)

        # El de GDB SÍ tiene que ser este y no otro: la configuración de
        # depuración que se deja en el proyecto de CubeIDE lo lleva escrito.
        if puerto_abierto(PUERTO_GDB):
            raise ErrorEmulador(
                'el puerto %d está ocupado por otro programa, y es el que\n'
                'usa el depurador. Cierra lo que lo esté usando.\n\n'
                'Para saber qué es:\n'
                '    %s' % (PUERTO_GDB, _quien_usa(PUERTO_GDB)))

        renode = busca_renode()
        if not renode:
            raise ErrorEmulador(
                'no encuentro Renode.\n'
                'Instala la 1.16.1: https://github.com/renode/renode/releases/tag/v1.16.1')

        # EL DEL MONITOR SE ELIGE, NO SE IMPONE. Renode aborta si no puede
        # abrirlo -«AddressAlreadyInUse», y se muere con un core dumped que el
        # panel no tiene forma de explicar-, y el 1234 lo usa mucha gente. A
        # nadie de fuera le importa cuál sea, asi que se coge el primero libre.
        self.monitor = puerto_libre(PUERTO_MONITOR)

        guion = self.prepara(elf, esperar)
        log = open(self.registro, 'w', encoding='utf-8', errors='replace')
        orden = [renode, '--disable-xwt', '--port', str(self.monitor),
                 guion.replace('\\', '/')]

        extra = {}
        if ES_WINDOWS:
            extra['creationflags'] = getattr(subprocess, 'CREATE_NO_WINDOW', 0)
        else:
            # Sesion propia para poder matar el arbol: en Linux `renode` es un
            # guion de shell que lanza mono, y matar el guion dejaria vivo al
            # hijo, que es quien tiene el puerto abierto.
            extra['start_new_session'] = True

        self.proceso = subprocess.Popen(orden, stdout=log,
                                        stderr=subprocess.STDOUT, **extra)
        return self.proceso

    def para(self, espera=5.0):
        """Lo mata y ESPERA A QUE MUERA DE VERDAD.

        Hasta que el sistema no lo entierra, el puerto sigue ocupado y un
        arranque inmediato falla con «ya hay un simulador corriendo».
        """
        if not self.vivo:
            self.proceso = None
            return
        try:
            if ES_WINDOWS:
                self.proceso.terminate()
            else:
                os.killpg(os.getpgid(self.proceso.pid), signal.SIGTERM)
        except (OSError, PermissionError):
            pass

        try:
            self.proceso.wait(timeout=espera)
        except subprocess.TimeoutExpired:
            try:
                if ES_WINDOWS:
                    self.proceso.kill()
                else:
                    os.killpg(os.getpgid(self.proceso.pid), signal.SIGKILL)
                self.proceso.wait(timeout=espera)
            except (OSError, subprocess.TimeoutExpired):
                pass
        self.proceso = None

        # Y ademas esperar a que el puerto se libere: el sistema tarda un
        # poco mas que el proceso en soltarlo.
        fin = time.time() + espera
        while time.time() < fin and puerto_abierto(PUERTO_MODULO, espera=0.2):
            time.sleep(0.2)
