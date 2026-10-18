#!/bin/sh
# Lanza el panel del simulador ACII, en Linux o en macOS.
#
# Vive dentro del paquete y se apaña solo: encuentra su propia carpeta, así
# que funciona esté donde esté y da igual desde dónde se llame.
set -e

AQUI=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# Mantiene el portable autocontenido en la carpeta del paquete cuando la
# cuenta no puede escribir en ~/.config o ~/.acii_sim.
PAQUETE=$(CDPATH= cd -- "$AQUI/../.." && pwd)
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$PAQUETE/.acii_config}"
export ACII_SIM_HOME="${ACII_SIM_HOME:-$PAQUETE/.acii_sim}"
mkdir -p "$XDG_CONFIG_HOME" "$ACII_SIM_HOME"

# No basta con encontrar «un python3»: hace falta que su Tk sea 8.6 o
# superior. El python3 que trae macOS lleva Tk 8.5, que Apple dejó de
# mantener; y en Linux Tkinter va en un paquete aparte que no suele estar
# puesto. Sin esta comprobación, el error que sale es un ImportError o una
# ventana que se dibuja mal, y ninguno de los dos dice qué hay que hacer.
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
    echo "No encuentro un Python 3 con Tk 8.6 o superior." >&2
    if [ "$(uname -s)" = "Darwin" ]; then
        echo "  El python3 que trae macOS lleva Tk 8.5 y no vale:" >&2
        echo "      brew install python-tk" >&2
        echo "  o Python desde https://www.python.org/downloads/macos/" >&2
    else
        echo "  Debian/Ubuntu   sudo apt install python3-tk" >&2
        echo "  Fedora          sudo dnf install python3-tkinter" >&2
        echo "  Arch            sudo pacman -S tk" >&2
    fi
    exit 1
fi

exec "$PY" "$AQUI/panel.py" "$@"
