#!/bin/sh
# Deja el simulador listo para una sola cuenta, en Linux o en macOS.
#
#     ./instalar.sh
#
# No instala nada en el sistema ni pide contraseña: todo va dentro de la
# carpeta personal. Para los equipos del laboratorio, donde interesa que lo
# tenga todo el mundo, está `desplegar-laboratorio.sh`.
set -e

AQUI=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SISTEMA=$(uname -s)

echo "Simulador ACII — instalación para $(id -un)"
echo

# ---------------------------------------------------------------------------
# Python con un Tk que sirva
# ---------------------------------------------------------------------------
# En macOS el python3 del sistema trae **Tk 8.5**, que Apple dejó de mantener
# y da problemas de dibujo. Por eso no vale con encontrar «un python3»: hay
# que encontrar uno cuyo Tk sea 8.6 o superior, y son los de Homebrew y los de
# python.org.
PY=""
for c in /opt/homebrew/bin/python3 /usr/local/bin/python3 python3 python; do
    ruta=$(command -v "$c" 2>/dev/null) || continue
    if "$ruta" -c "import sys,tkinter; sys.exit(0 if tkinter.TkVersion>=8.6 else 1)" \
        >/dev/null 2>&1; then
        PY="$ruta"
        break
    fi
done

if [ -z "$PY" ]; then
    echo "FALTA un Python 3 con Tk 8.6 o superior." >&2
    if [ "$SISTEMA" = "Darwin" ]; then
        echo "  El python3 que trae macOS lleva Tk 8.5 y no vale. Instala uno:" >&2
        echo "      brew install python-tk" >&2
        echo "  o descarga Python de https://www.python.org/downloads/macos/" >&2
    else
        echo "  Tkinter en Linux va en un paquete aparte:" >&2
        echo "      Debian/Ubuntu   sudo apt install python3-tk" >&2
        echo "      Fedora          sudo dnf install python3-tkinter" >&2
        echo "      Arch            sudo pacman -S tk" >&2
    fi
    exit 1
fi
echo "  Python:            $PY  (Tk $("$PY" -c 'import tkinter;print(tkinter.TkVersion)'))"

# ---------------------------------------------------------------------------
# Las tipografías
# ---------------------------------------------------------------------------
# El panel ya se las carga solo para su proceso, así que esto no es
# imprescindible; se instalan igualmente para que se vean bien también en la
# guía y en cualquier otra cosa de la asignatura.
if [ "$SISTEMA" = "Darwin" ]; then
    TIPOGRAFIAS="$HOME/Library/Fonts"
else
    TIPOGRAFIAS="$HOME/.local/share/fonts"
fi
if ! mkdir -p "$TIPOGRAFIAS" 2>/dev/null; then
    # Instalación portable en entornos gestionados sin escritura en HOME.
    TIPOGRAFIAS="$AQUI/../.acii_fonts"
    mkdir -p "$TIPOGRAFIAS"
fi
cp -n "$AQUI"/tipografias/*.ttf "$TIPOGRAFIAS"/ 2>/dev/null || true
if command -v fc-cache >/dev/null 2>&1; then
    fc-cache -f "$TIPOGRAFIAS" >/dev/null 2>&1 || true
fi
echo "  Tipografías:       $TIPOGRAFIAS"

# ---------------------------------------------------------------------------
# El lanzador
# ---------------------------------------------------------------------------
chmod +x "$AQUI/simulador-acii.sh"

if [ "$SISTEMA" = "Darwin" ]; then
    # macOS no usa los .desktop de Linux, y un .command tampoco vale: abre una
    # ventana de Terminal vacia delante del panel, y lo que se ve es el
    # Terminal en blanco con el panel escondido detras. Se monta un paquete de
    # aplicacion de verdad, que arranca sin ninguna ventana de por medio.
    APLICACIONES="$HOME/Applications"
    APP="$APLICACIONES/Simulador ACII.app"
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

    cat > "$APP/Contents/Info.plist" <<FIN
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Simulador ACII</string>
    <key>CFBundleDisplayName</key><string>Simulador ACII</string>
    <key>CFBundleIdentifier</key><string>es.uvigo.esei.acii.simulador</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>simulador</string>
    <key>CFBundleIconFile</key><string>simulador</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
FIN

    cat > "$APP/Contents/MacOS/simulador" <<FIN
#!/bin/sh
exec "$PY" "$AQUI/panel.py" "\$@"
FIN
    chmod +x "$APP/Contents/MacOS/simulador"

    # El icono, si el sistema sabe convertirlo. Si no, se queda con el
    # generico: es un detalle, no vale la pena que falle la instalacion.
    # sips solo sabe convertir a icns desde tamaños estándar: un PNG de 64x64
    # lo rechaza con «Error 13», que no explica nada. Por eso el icono sale de
    # `icono.png`, que es el logo de la asignatura a 512x512.
    if command -v sips >/dev/null 2>&1 && [ -f "$AQUI/icono.png" ]; then
        ICONO="$APP/Contents/Resources/simulador.icns"
        sips -s format icns "$AQUI/icono.png" --out "$ICONO" \
            >/dev/null 2>&1 || true
    fi

    # Quitar el .command de instalaciones anteriores, para no dejar dos
    # lanzadores que hacen lo mismo y uno mal.
    rm -f "$HOME/Desktop/Simulador ACII.command"

    echo "  Lanzador:          $APP"
else
    APLICACIONES="$HOME/.local/share/applications"
    if ! (mkdir -p "$APLICACIONES" && touch "$APLICACIONES/.acii_write_test") 2>/dev/null; then
        APLICACIONES="$AQUI/../.acii_applications"
        mkdir -p "$APLICACIONES"
    else
        rm -f "$APLICACIONES/.acii_write_test"
    fi
    cat > "$APLICACIONES/acii-simulador.desktop" <<FIN
[Desktop Entry]
Type=Application
Name=Simulador ACII
Comment=Simulador de la placa NUCLEO-F401RE con el módulo LED&KEY
Exec=$AQUI/simulador-acii.sh
Icon=$AQUI/PanelACII.png
Terminal=false
Categories=Development;Electronics;
FIN
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$APLICACIONES" >/dev/null 2>&1 || true
    fi
    echo "  Lanzador:          en el menú de aplicaciones"
fi

# ---------------------------------------------------------------------------
# Renode
# ---------------------------------------------------------------------------
# Lo único que hace falta de fuera, y no se instala aquí a propósito: es un
# paquete grande, con su propia versión, y conviene que se vea lo que se está
# metiendo en el equipo.
#
# Se le pregunta al propio código del panel en vez de repetir aquí la lista de
# rutas: si se repite, un día dice que falta Renode cuando está puesto, y el
# alumnado se pone a instalarlo otra vez.
#
# Y se le pregunta la versión: el simulador está probado con la 1.16.1, y con
# otra (un alumno tenía la 1.17) Renode puede quedarse colgado al arrancar.
PROBADA=$("$PY" -c "import sys; sys.path.insert(0, '$AQUI'); import emulador; \
print(emulador.VERSION_PROBADA)" 2>/dev/null)
if VERSION=$("$PY" -c "import sys; sys.path.insert(0, '$AQUI'); import emulador; \
r = emulador.busca_renode(); print(emulador.version_renode(r) or '?') if r else sys.exit(1)" 2>/dev/null); then
    if [ "$VERSION" = "$PROBADA" ]; then
        echo "  Renode:            bien ($VERSION)"
    else
        echo
        echo "  RENODE ES LA VERSIÓN $VERSION, y el simulador está probado con la $PROBADA."
        echo "  Con otra puede quedarse colgado al arrancar. Cámbiala por la $PROBADA:"
        echo "  https://github.com/renode/renode/releases/tag/v$PROBADA"
        echo
    fi
else
    echo
    echo "  FALTA RENODE, que es lo único que hay que instalar aparte."
    echo "  Tiene que ser la $PROBADA: https://github.com/renode/renode/releases/tag/v$PROBADA"
    if [ "$SISTEMA" = "Darwin" ]; then
        echo "  Baja el .dmg de macOS —renode-$PROBADA-dotnet.osx-arm64-portable.dmg"
        echo "  si tu Mac es de Apple Silicon— ábrelo y arrastra Renode.app a Aplicaciones."
    else
        echo "  En Debian o Ubuntu, el .deb:"
        echo "      sudo apt install ./renode_${PROBADA}_amd64.deb"
    fi
fi

echo
if [ "$SISTEMA" = "Darwin" ]; then
    echo "Listo. Tienes «Simulador ACII» en tu carpeta Aplicaciones."
else
    echo "Listo. Búscalo como «Simulador ACII» en el menú de aplicaciones."
fi
echo "También se lanza con:  $AQUI/simulador-acii.sh"
echo
# El lanzador APUNTA a esta carpeta, no copia nada. Si se mueve o se
# borra, deja de funcionar y el error no dice por que.
echo "OJO: el lanzador apunta a esta carpeta. Si la mueves o la borras,"
echo "deja de funcionar; vuelve a ejecutar este instalador si la cambias de sitio."
