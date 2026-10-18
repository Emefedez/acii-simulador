# -*- coding: utf-8 -*-
"""Hace lo mismo que el boton Arrancar, pero contandolo todo por consola.

    cd .../ACII_Simulador/Panel_py
    python3 diagnostico.py
"""
import os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import emulador as E
from modulo import puerto_abierto

elf = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    'ejemplo', 'Garaje.elf')

renode = E.busca_renode()
print('renode   :', renode)
if renode:
    v = E.version_renode(renode)
    print('version  :', v or '?', '' if v == E.VERSION_PROBADA
          else '  <-- el simulador esta probado con la %s' % E.VERSION_PROBADA)
print('programa :', elf, '' if os.path.exists(elf) else '  <-- NO EXISTE')
print('trabajo  :', E.carpeta_trabajo())
if not os.path.exists(elf):
    raise SystemExit(1)

e = E.Emulador()
try:
    e.arranca(elf)
except Exception as ex:
    print()
    print('FALLA AL ARRANCAR:', type(ex).__name__)
    print(ex)
    raise SystemExit(1)

print('lanzado, esperando al puerto 3939...')
for i in range(120):
    if puerto_abierto(3939):
        print('LISTO en %d s. El simulador funciona.' % i)
        e.para()
        raise SystemExit(0)
    if not e.vivo:
        print()
        print('RENODE SE HA MUERTO a los %d s. Codigo de salida: %s'
              % (i, e.proceso.returncode))
        break
    time.sleep(1)
else:
    print('no ha abierto el puerto en 120 s')

print()
print('--- ultimas 40 lineas de', e.registro)
try:
    print(''.join(open(e.registro, errors='replace').readlines()[-40:]))
except OSError as ex:
    print('no se puede leer:', ex)
e.para()
