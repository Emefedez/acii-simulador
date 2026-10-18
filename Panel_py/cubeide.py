# -*- coding: utf-8 -*-
"""La configuración de depuración de STM32CubeIDE.

Sin esto hay que crear a mano una configuración «GDB Hardware Debugging»
apuntando a localhost:3333, que son diez campos y un fallo seguro. El fichero
se deja DENTRO del proyecto, que es donde Eclipse busca las configuraciones
compartidas.
"""
import os

from emulador import PUERTO_GDB, busca_gdb

# Eclipse llama a la configuración como se llame el fichero, y las lista todas
# juntas: si todos los proyectos la llaman igual, salen tres «Simulador ACII»
# indistinguibles. Por eso lleva el nombre del proyecto.
NOMBRE = 'Simulador ACII - %s.launch'
NOMBRE_VIEJO = 'Simulador ACII.launch'

PLANTILLA = '''<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<launchConfiguration type="org.eclipse.cdt.debug.gdbjtag.launchConfigurationType">
    <stringAttribute key="org.eclipse.cdt.debug.gdbjtag.core.connection" value="gdb:localhost:%(puerto)d#"/>
    <intAttribute key="org.eclipse.cdt.debug.gdbjtag.core.delay" value="0"/>
    <booleanAttribute key="org.eclipse.cdt.debug.gdbjtag.core.doHalt" value="false"/>
    <booleanAttribute key="org.eclipse.cdt.debug.gdbjtag.core.doReset" value="false"/>
    <stringAttribute key="org.eclipse.cdt.debug.gdbjtag.core.initCommands" value=""/>
    <stringAttribute key="org.eclipse.cdt.debug.gdbjtag.core.jtagDeviceId" value="org.eclipse.cdt.debug.gdbjtag.core.jtagdevice.genericDevice"/>
    <booleanAttribute key="org.eclipse.cdt.debug.gdbjtag.core.loadImage" value="false"/>
    <booleanAttribute key="org.eclipse.cdt.debug.gdbjtag.core.loadSymbols" value="true"/>
    <stringAttribute key="org.eclipse.cdt.debug.gdbjtag.core.protocol" value="remote"/>
    <stringAttribute key="org.eclipse.cdt.debug.gdbjtag.core.runCommands" value="monitor start&#13;&#10;monitor sysbus.cpu IsHalted false"/>
    <booleanAttribute key="org.eclipse.cdt.debug.gdbjtag.core.setPcRegister" value="false"/>
    <booleanAttribute key="org.eclipse.cdt.debug.gdbjtag.core.setResume" value="true"/>
    <booleanAttribute key="org.eclipse.cdt.debug.gdbjtag.core.setStopAt" value="true"/>
    <stringAttribute key="org.eclipse.cdt.debug.gdbjtag.core.stopAt" value="main"/>
    <booleanAttribute key="org.eclipse.cdt.debug.gdbjtag.core.useFileForImage" value="false"/>
    <booleanAttribute key="org.eclipse.cdt.debug.gdbjtag.core.useFileForSymbols" value="false"/>
    <booleanAttribute key="org.eclipse.cdt.debug.gdbjtag.core.useProjBinaryForImage" value="true"/>
    <booleanAttribute key="org.eclipse.cdt.debug.gdbjtag.core.useProjBinaryForSymbols" value="true"/>
    <booleanAttribute key="org.eclipse.cdt.debug.gdbjtag.core.useRemoteTarget" value="true"/>
    <stringAttribute key="org.eclipse.cdt.dsf.gdb.DEBUG_NAME" value="%(gdb)s"/>
    <intAttribute key="org.eclipse.cdt.launch.ATTR_BUILD_BEFORE_LAUNCH_ATTR" value="2"/>
    <stringAttribute key="org.eclipse.cdt.launch.DEBUGGER_START_MODE" value="remote"/>
    <stringAttribute key="org.eclipse.cdt.launch.PROGRAM_NAME" value="Debug/%(elf)s"/>
    <stringAttribute key="org.eclipse.cdt.launch.PROJECT_ATTR" value="%(proyecto)s"/>
    <booleanAttribute key="org.eclipse.cdt.launch.PROJECT_BUILD_CONFIG_AUTO_ATTR" value="false"/>
    <listAttribute key="org.eclipse.debug.core.MAPPED_RESOURCE_PATHS">
        <listEntry value="/%(proyecto)s"/>
    </listAttribute>
    <listAttribute key="org.eclipse.debug.core.MAPPED_RESOURCE_TYPES">
        <listEntry value="4"/>
    </listAttribute>
    <listAttribute key="org.eclipse.debug.ui.favoriteGroups">
        <listEntry value="org.eclipse.debug.ui.launchGroup.debug"/>
    </listAttribute>
    <stringAttribute key="process_factory_id" value="org.eclipse.cdt.dsf.gdb.GdbProcessFactory"/>
</launchConfiguration>
'''


def raiz_del_proyecto(elf):
    """De <raiz>/Debug/loquesea.elf a <raiz>/."""
    carpeta = os.path.dirname(os.path.abspath(elf))
    if os.path.basename(carpeta).lower() in ('debug', 'release'):
        carpeta = os.path.dirname(carpeta)
    return carpeta


def nombre_del_proyecto(raiz):
    """El nombre que Eclipse guarda en .project."""
    ruta = os.path.join(raiz, '.project')
    if not os.path.exists(ruta):
        return ''
    try:
        texto = open(ruta, encoding='utf-8', errors='replace').read()
    except OSError:
        return ''
    a, b = texto.find('<name>'), texto.find('</name>')
    return texto[a + 6:b].strip() if 0 <= a < b else ''


def asegura(elf):
    """Crea la configuración si falta. Devuelve (ruta, mensaje).

    `ruta` es '' si no se ha creado nada, y entonces `mensaje` dice por qué.
    """
    raiz = raiz_del_proyecto(elf)
    proyecto = nombre_del_proyecto(raiz)
    if not proyecto:
        return '', 'no parece un proyecto de STM32CubeIDE'

    destino = os.path.join(raiz, NOMBRE % proyecto)
    if os.path.exists(destino):
        return '', ''                     # ya estaba: ni ruido ni trabajo

    viejo = os.path.join(raiz, NOMBRE_VIEJO)
    if os.path.exists(viejo):
        # Se llamaba así antes de llevar el nombre del proyecto. Se renombra
        # para no dejar dos configuraciones iguales en el mismo proyecto.
        try:
            os.replace(viejo, destino)
            return destino, ''
        except OSError:
            pass

    texto = PLANTILLA % dict(puerto=PUERTO_GDB, gdb=busca_gdb(),
                             elf=os.path.basename(elf), proyecto=proyecto)
    try:
        # Sin BOM: Eclipse lee el fichero como UTF-8 y el BOM le sobra.
        with open(destino, 'wb') as f:
            f.write(texto.encode('utf-8'))
    except OSError as e:
        return '', 'no he podido escribirla: %s' % e
    return destino, ''
