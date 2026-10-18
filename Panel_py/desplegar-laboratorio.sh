#!/bin/sh
# Instala el simulador para TODO EL MUNDO en un equipo del laboratorio.
#
#     sudo ./desplegar-laboratorio.sh
#
# A diferencia de `instalar.sh`, que solo toca la carpeta personal de quien lo
# lanza, esto deja el simulador en /opt y el lanzador en el menú de todas las
# cuentas. Pensado para pasarlo una vez por equipo, o por ansible.
set -e

AQUI=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DESTINO=/opt/acii-simulador
TIPOGRAFIAS=/usr/local/share/fonts/acii
APLICACIONES=/usr/share/applications

if [ "$(id -u)" -ne 0 ]; then
    echo "Esto hay que lanzarlo como root:  sudo $0" >&2
    exit 1
fi

echo "Simulador ACII — despliegue en $(hostname)"

# --- dependencias ----------------------------------------------------------
falta=""
command -v python3 >/dev/null 2>&1 || falta="$falta python3"
python3 -c "import tkinter" >/dev/null 2>&1 || falta="$falta python3-tk"
if [ -n "$falta" ]; then
    echo "  Instalando:$falta"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get install -y $falta
    else
        echo "  No es un sistema con apt: instala a mano$falta" >&2
        exit 1
    fi
fi

# --- el paquete ------------------------------------------------------------
# El panel se copia entero, incluida la plataforma: en el laboratorio no
# interesa que dependa de dónde estuviera el paquete al instalarlo.
mkdir -p "$DESTINO"
cp -r "$AQUI/." "$DESTINO/panel/"
if [ -d "$AQUI/../plataforma" ]; then
    cp -r "$AQUI/../plataforma" "$DESTINO/"
fi
if [ -d "$AQUI/../ejemplo" ]; then
    cp -r "$AQUI/../ejemplo" "$DESTINO/"
fi
chmod -R a+rX "$DESTINO"
chmod a+x "$DESTINO/panel/simulador-acii.sh"
echo "  Paquete:           $DESTINO"

# --- tipografías, para todas las cuentas -----------------------------------
mkdir -p "$TIPOGRAFIAS"
cp -f "$AQUI"/tipografias/*.ttf "$TIPOGRAFIAS"/
command -v fc-cache >/dev/null 2>&1 && fc-cache -f "$TIPOGRAFIAS" >/dev/null 2>&1
echo "  Tipografías:       $TIPOGRAFIAS"

# --- lanzador --------------------------------------------------------------
cat > "$APLICACIONES/acii-simulador.desktop" <<FIN
[Desktop Entry]
Type=Application
Name=Simulador ACII
Comment=Simulador de la placa NUCLEO-F401RE con el módulo LED&KEY
Exec=$DESTINO/panel/simulador-acii.sh
Icon=$DESTINO/panel/PanelACII.png
Terminal=false
Categories=Development;Electronics;
FIN
command -v update-desktop-database >/dev/null 2>&1 && \
    update-desktop-database "$APLICACIONES" >/dev/null 2>&1
echo "  Lanzador:          $APLICACIONES/acii-simulador.desktop"

# --- Renode ----------------------------------------------------------------
# Se pregunta al propio codigo del panel en vez de repetir aqui la lista
# de rutas: si se repite, un dia dice que falta Renode cuando esta
# puesto, y el alumnado se pone a instalarlo otra vez.
if python3 -c "import sys; sys.path.insert(0, '$AQUI'); import emulador; sys.exit(0 if emulador.busca_renode() else 1)" 2>/dev/null; then
    echo "  Renode:            bien"
else
    echo
    echo "  FALTA RENODE. Descarga el .deb de"
    echo "  https://github.com/renode/renode/releases  e instálalo:"
    echo "      sudo apt install ./renode_*.deb"
fi

# Cada usuario escribe en su propia carpeta de trabajo (~/.acii_sim), así que
# no hay que dar permisos a nada compartido ni limpiar entre sesiones.
echo
echo "Listo. Cada cuenta trabaja en su propio ~/.acii_sim."
