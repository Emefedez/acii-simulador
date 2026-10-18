# -*- coding: utf-8 -*-
"""Carga las tipografías del panel desde la carpeta `fuentes/`.

Hace falta porque **no se puede dar por hecho que estén instaladas**. En la
máquina donde se escribió esto, Barlow e IBM Plex Mono estaban instaladas
«por usuario» y aun así Tk no las veía; en Linux directamente no estarán. Sin
esto la ventana sale con otra tipografía y con otras medidas, y nadie sabe por
qué.

Se cargan **para este proceso y nada más**: no se instalan en el sistema ni se
deja rastro. Eso es cosa del instalador, no del panel.

Hay que llamar a `carga()` ANTES de crear la ventana de Tk: la lista de
familias se consulta al arrancar.

Las tres son de licencia SIL Open Font, redistribuibles; el texto de la
licencia va al lado de los .ttf.
"""
import ctypes
import os
import sys

AQUI = os.path.dirname(os.path.abspath(__file__))
CARPETA = os.path.join(AQUI, 'tipografias')

FAMILIAS = ('Barlow', 'Barlow Condensed', 'IBM Plex Mono')


def ficheros():
    if not os.path.isdir(CARPETA):
        return []
    return [os.path.join(CARPETA, f) for f in sorted(os.listdir(CARPETA))
            if f.lower().endswith(('.ttf', '.otf'))]


def _windows(rutas):
    FR_PRIVATE = 0x10
    gdi = ctypes.windll.gdi32
    caras = 0
    for r in rutas:
        caras += gdi.AddFontResourceExW(ctypes.c_wchar_p(r), FR_PRIVATE, 0)
    return caras > 0


def _macos(rutas):
    """macOS: se registran en CoreText, solo para este proceso.

    NO vale fontconfig aquí: el Tk de macOS dibuja con CoreText, no con Xft,
    y aunque fontconfig esté instalado no se entera de nada. Comprobado en un
    Mac mini M4: con fontconfig, Tk no veía ninguna de las tres; con esto, las
    tres. Es el equivalente exacto de AddFontResourceEx en Windows.
    """
    import ctypes.util
    cf = ctypes.CDLL(ctypes.util.find_library('CoreFoundation'))
    ct = ctypes.CDLL(ctypes.util.find_library('CoreText'))
    cf.CFURLCreateFromFileSystemRepresentation.restype = ctypes.c_void_p
    cf.CFURLCreateFromFileSystemRepresentation.argtypes = [
        ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_bool]
    ct.CTFontManagerRegisterFontsForURL.restype = ctypes.c_bool
    ct.CTFontManagerRegisterFontsForURL.argtypes = [
        ctypes.c_void_p, ctypes.c_uint32, ctypes.c_void_p]

    AMBITO_PROCESO = 1
    bien = 0
    for r in rutas:
        crudo = r.encode('utf-8')
        url = cf.CFURLCreateFromFileSystemRepresentation(
            None, crudo, len(crudo), False)
        bien += bool(ct.CTFontManagerRegisterFontsForURL(
            url, AMBITO_PROCESO, None))
    return bien > 0


def _fontconfig(rutas):
    """Linux: se añaden a la configuración de fontconfig en memoria.

    Tk dibuja el texto con Xft, que usa la configuración por defecto de
    fontconfig, así que basta con añadirlas ahí.
    """
    for nombre in ('libfontconfig.so.1', 'libfontconfig.so'):
        try:
            fc = ctypes.CDLL(nombre)
            break
        except OSError:
            continue
    else:
        return False

    fc.FcConfigAppFontAddFile.restype = ctypes.c_int
    fc.FcConfigAppFontAddFile.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    bien = 0
    for r in rutas:
        bien += bool(fc.FcConfigAppFontAddFile(None, r.encode('utf-8')))
    return bien > 0


def carga():
    """Devuelve True si se han podido cargar. No levanta nunca: quedarse sin
    la tipografía buena es feo, pero no impide trabajar."""
    rutas = ficheros()
    if not rutas:
        return False
    try:
        if sys.platform.startswith('win'):
            return _windows(rutas)
        if sys.platform == 'darwin':
            return _macos(rutas)
        return _fontconfig(rutas)
    except Exception:
        return False


def instala_en_el_sistema():
    """Para el instalador, no para el panel: deja las tipografías puestas
    para todo el escritorio del usuario.

    El panel no lo necesita —se las carga él solo—, pero así se ven bien
    también en la guía y en cualquier otra cosa de la asignatura.

    Devuelve la carpeta donde las ha dejado, o '' si no ha hecho nada.
    """
    if sys.platform.startswith('win'):
        return ''
    import shutil
    import subprocess
    if sys.platform == 'darwin':
        destino = os.path.join(os.path.expanduser('~'), 'Library', 'Fonts')
    else:
        destino = os.path.join(os.path.expanduser('~'), '.local', 'share',
                               'fonts')
    os.makedirs(destino, exist_ok=True)
    puestas = 0
    for r in ficheros():
        fuera = os.path.join(destino, os.path.basename(r))
        if not os.path.exists(fuera):
            shutil.copy2(r, fuera)
            puestas += 1
    if puestas:
        try:
            subprocess.call(['fc-cache', '-f', destino],
                            stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL)
        except OSError:
            pass
    return destino
