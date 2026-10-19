#!/usr/bin/env bash
# =============================================================================
# setup-vscode.sh — Automated setup for Simulador ACII + VS Code Extension
# =============================================================================
# Sets up:
#   1. ACII Simulator launcher & fonts (via Panel_py/instalar.sh)
#   2. Renode 1.16.1 portable (auto-downloads for Linux x86_64 / arm64 if missing)
#   3. ~/.local/bin/stm32-make helper for STM32CubeIDE Debug/makefile builds
#   4. VS Code C/C++ extension (ms-vscode.cpptools) + ST-Link Auto Debug (.vsix)
#   5. VS Code user settings (stlinkAutodebug.simulator.debug, gdbPath,
#      stm32cube-ide-clangd.enableLinting, etc.)
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PANEL_PY="$ROOT_DIR/Panel_py"
EXT_DIR="$ROOT_DIR/vscode-extension"
RENODE_VERSION="1.16.1"

INSTALL_RENODE=1
CONFIGURE_SETTINGS=1

for arg in "$@"; do
  case "$arg" in
    --no-renode) INSTALL_RENODE=0 ;;
    --no-settings) CONFIGURE_SETTINGS=0 ;;
    -h|--help)
      cat <<HELP
Usage: ./setup-vscode.sh [--no-renode] [--no-settings]

Options:
  --no-renode     Skip automatic download of Renode ${RENODE_VERSION} portable if missing
  --no-settings   Skip updating VS Code user settings.json
  -h, --help      Show this help message
HELP
      exit 0
      ;;
    *)
      echo "Unknown option: $arg (run with --help for usage)" >&2
      exit 1
      ;;
  esac
done

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m  ✗\033[0m %s\n' "$*" >&2; }

# -----------------------------------------------------------------------------
# 1. Install ACII Simulator desktop entry & fonts
# -----------------------------------------------------------------------------
info "Step 1/5: Setting up Simulador ACII panel, fonts, and desktop launcher..."
chmod +x "$PANEL_PY/instalar.sh" "$PANEL_PY/simulador-acii.sh"
"$PANEL_PY/instalar.sh"

# Also update the repo-rootSimulador ACII.desktop with current absolute path
if [[ -f "$ROOT_DIR/acii-simulador.desktop" ]]; then
  sed "s#\\\$HOME/Downloads/ACII_Simulador#$ROOT_DIR#g" \
    "$ROOT_DIR/acii-simulador.desktop" > "$ROOT_DIR/Simulador ACII.desktop"
  chmod +x "$ROOT_DIR/Simulador ACII.desktop"
fi

# -----------------------------------------------------------------------------
# 2. Check / Install Renode 1.16.1 Portable
# -----------------------------------------------------------------------------
info "Step 2/5: Checking Renode ${RENODE_VERSION}..."
detect_renode() {
  python3 - "$PANEL_PY" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import emulador
r = emulador.busca_renode()
if not r:
    sys.exit(1)
v = emulador.version_renode(r) or "?"
print(f"{r}|{v}")
PY
}

if RENODE_INFO="$(detect_renode 2>/dev/null)"; then
  RENODE_BIN="${RENODE_INFO%%|*}"
  RENODE_FOUND_VER="${RENODE_INFO##*|}"
  if [[ "$RENODE_FOUND_VER" == "$RENODE_VERSION" ]]; then
    ok "Renode ${RENODE_FOUND_VER} found at: ${RENODE_BIN}"
  else
    warn "Found Renode ${RENODE_FOUND_VER} at ${RENODE_BIN} (recommended version is ${RENODE_VERSION})."
  fi
elif [[ "$INSTALL_RENODE" -eq 1 && "$(uname -s)" == "Linux" ]]; then
  ARCH="$(uname -m)"
  case "$ARCH" in
    aarch64|arm64)
      TARBALL="renode-${RENODE_VERSION}.linux-arm64-portable-dotnet.tar.gz"
      ;;
    x86_64|amd64)
      TARBALL="renode-${RENODE_VERSION}.linux-portable-dotnet.tar.gz"
      ;;
    *)
      TARBALL=""
      ;;
  esac

  if [[ -n "$TARBALL" ]]; then
    URL="https://github.com/renode/renode/releases/download/v${RENODE_VERSION}/${TARBALL}"
    DEST_PARENT="$(dirname "$ROOT_DIR")"
    DEST_DIR="$DEST_PARENT/renode_portable"
    TMP_TAR="$(mktemp --suffix=.tar.gz)"
    info "Downloading Renode ${RENODE_VERSION} portable (${ARCH})..."
    if curl -fL --progress-bar "$URL" -o "$TMP_TAR"; then
      mkdir -p "$DEST_DIR"
      tar -xzf "$TMP_TAR" -C "$DEST_DIR" --strip-components=1
      rm -f "$TMP_TAR"
      ok "Installed Renode ${RENODE_VERSION} portable to ${DEST_DIR}"
    else
      rm -f "$TMP_TAR"
      warn "Could not download Renode from ${URL}. Install v${RENODE_VERSION} manually."
    fi
  else
    warn "Unsupported architecture ${ARCH} for automatic Renode portable download."
  fi
else
  warn "Renode ${RENODE_VERSION} not found. Download it from: https://github.com/renode/renode/releases/tag/v${RENODE_VERSION}"
fi

# -----------------------------------------------------------------------------
# 3. Ensure stm32-make build wrapper is installed
# -----------------------------------------------------------------------------
info "Step 3/5: Checking STM32 build helper (stm32-make)..."
mkdir -p "$HOME/.local/bin"
if command -v stm32-make >/dev/null 2>&1 || [[ -x "$HOME/.local/bin/stm32-make" ]]; then
  ok "stm32-make already available: $(command -v stm32-make || echo "$HOME/.local/bin/stm32-make")"
else
  cat > "$HOME/.local/bin/stm32-make" <<'MAKE_EOF'
#!/usr/bin/env bash
# Wrapper to run `make` for STM32CubeIDE Debug/makefile projects using either:
#   1. STM32CubeIDE's bundled GNU Tools for STM32 (via muvm-run on Asahi ARM64, or directly on x86_64)
#   2. System arm-none-eabi-gcc + make on PATH
set -euo pipefail
shopt -s nullglob
found=(
  "$HOME"/st/stm32cubeide_*/plugins/com.st.stm32cube.ide.mcu.externaltools.gnu-tools-for-stm32.*/tools/bin
  /opt/st/stm32cubeide_*/plugins/com.st.stm32cube.ide.mcu.externaltools.gnu-tools-for-stm32.*/tools/bin
)
tools=""
if (( ${#found[@]} )); then
  tools="$(printf '%s\n' "${found[@]}" | sort -V | tail -1)"
fi

if [[ -n "$tools" ]]; then
  if [[ "$(uname -m)" != "x86_64" && -x "$HOME/.local/bin/muvm-run" ]]; then
    # Inside muvm gcc's output is not a terminal: the wrappers in color/ force
    # colored diagnostics in VS Code's build terminal.
    exec "$HOME/.local/bin/muvm-run" env PATH="$HOME/.local/lib/stm32-make/color:$tools:/usr/bin:/bin" \
      FEX_ROOTFS=/run/fex-emu/rootfs FEX_SERVERSOCKETPATH=stm32-fex2609 make "$@"
  fi
  export PATH="$tools:$PATH"
fi

if ! command -v arm-none-eabi-gcc >/dev/null 2>&1; then
  echo "stm32-make: arm-none-eabi-gcc not found. Install arm-none-eabi-gcc or STM32CubeIDE." >&2
  exit 1
fi
exec make "$@"
MAKE_EOF
  chmod +x "$HOME/.local/bin/stm32-make"
  ok "Created $HOME/.local/bin/stm32-make"
fi

# Colored gcc diagnostics through stm32-make's muvm path (harmless elsewhere).
COLOR_DIR="$HOME/.local/lib/stm32-make/color"
mkdir -p "$COLOR_DIR"
for cc in arm-none-eabi-gcc arm-none-eabi-g++; do
  cat > "$COLOR_DIR/$cc" <<WRAP_EOF
#!/bin/sh
# Colored diagnostics for builds through stm32-make, then the real $cc.
IFS=:; for d in \$PATH; do
  [ "\$d" != "$COLOR_DIR" ] && [ -x "\$d/$cc" ] && exec "\$d/$cc" -fdiagnostics-color=always "\$@"
done
echo "$cc: compiler not found in PATH" >&2; exit 127
WRAP_EOF
  chmod +x "$COLOR_DIR/$cc"
done
ok "Colored build diagnostics: $COLOR_DIR"

# Check GDB with ARM support
if command -v arm-none-eabi-gdb >/dev/null 2>&1; then
  GDB_BIN="$(command -v arm-none-eabi-gdb)"
  ok "Found ARM GDB: $GDB_BIN"
elif command -v gdb-multiarch >/dev/null 2>&1; then
  GDB_BIN="$(command -v gdb-multiarch)"
  ok "Found multiarch GDB: $GDB_BIN"
elif command -v gdb >/dev/null 2>&1; then
  GDB_BIN="$(command -v gdb)"
  ok "Found system GDB: $GDB_BIN"
else
  GDB_BIN=""
  warn "Neither gdb nor arm-none-eabi-gdb found. Install gdb or arm-none-eabi-gdb for debugging."
fi

# -----------------------------------------------------------------------------
# 4. Package & Install VS Code extensions
# -----------------------------------------------------------------------------
info "Step 4/5: Packaging and installing VS Code extension (stlink-autodebug)..."
VSIX_PATH="$(python3 "$EXT_DIR/pack.py")"
ok "Packaged VSIX: $VSIX_PATH"

CODE_BIN=""
for candidate in code codium code-oss; do
  if command -v "$candidate" >/dev/null 2>&1; then
    CODE_BIN="$candidate"
    break
  fi
done

if [[ -n "$CODE_BIN" ]]; then
  INSTALLED_EXTS="$("$CODE_BIN" --list-extensions 2>/dev/null || true)"
  if ! grep -qix "ms-vscode.cpptools" <<<"$INSTALLED_EXTS"; then
    info "Installing required C/C++ extension (ms-vscode.cpptools)..."
    "$CODE_BIN" --install-extension ms-vscode.cpptools --force >/dev/null 2>&1 && \
      ok "Installed ms-vscode.cpptools" || \
      warn "Could not install ms-vscode.cpptools automatically; install it from the Extensions view."
  else
    ok "C/C++ extension (ms-vscode.cpptools) already installed"
  fi

  "$CODE_BIN" --install-extension "$VSIX_PATH" --force >/dev/null 2>&1
  ok "Installed $(basename "$VSIX_PATH") into VS Code ($CODE_BIN)"
else
  warn "VS Code CLI ('code') not found on PATH. Install the VSIX manually with:"
  warn "  code --install-extension \"$VSIX_PATH\" --force"
fi

# -----------------------------------------------------------------------------
# 5. Configure VS Code settings.json (non-destructively, preserving comments)
# -----------------------------------------------------------------------------
if [[ "$CONFIGURE_SETTINGS" -eq 1 ]]; then
  info "Step 5/5: Checking VS Code user settings..."
  if [[ "$(uname -s)" == "Darwin" ]]; then
    VSCODE_SETTINGS="$HOME/Library/Application Support/Code/User/settings.json"
  else
    VSCODE_SETTINGS="${XDG_CONFIG_HOME:-$HOME/.config}/Code/User/settings.json"
  fi

  python3 - "$VSCODE_SETTINGS" "$PANEL_PY/simulador-acii.sh" "$GDB_BIN" <<'PY'
import os
import re
import sys

settings_file, sim_script, gdb_bin = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(os.path.dirname(settings_file), exist_ok=True)

if not os.path.exists(settings_file) or os.path.getsize(settings_file) == 0:
    content = "{\n}\n"
else:
    with open(settings_file, "r", encoding="utf-8") as f:
        content = f.read()

desired = [
    ("stlinkAutodebug.simulator.debug", "true"),
    # The STM32Cube clangd extension drops every error/warning while typing
    # unless this is on (it is off by default).
    ("stm32cube-ide-clangd.enableLinting", "true"),
]
# Only set simulator.path if the repo is not in the default ~/Downloads/ACII_Simulador
default_sim = os.path.expanduser("~/Downloads/ACII_Simulador/Panel_py/simulador-acii.sh")
if os.path.abspath(sim_script) != os.path.abspath(default_sim):
    desired.append(("stlinkAutodebug.simulator.path", f'"{sim_script}"'))

if gdb_bin and gdb_bin != "/usr/bin/gdb":
    desired.append(("stlinkAutodebug.gdbPath", f'"{gdb_bin}"'))

added = []
for key, val in desired:
    pattern = rf'"{re.escape(key)}"\s*:'
    if re.search(pattern, content):
        continue
    # Insert right before the final closing brace '}'
    idx = content.rfind("}")
    if idx == -1:
        continue
    prefix = content[:idx].rstrip()
    # Add a trailing comma to the previous property if needed
    lines = [ln for ln in prefix.splitlines() if ln.strip() and not ln.strip().startswith("//")]
    if lines and not lines[-1].rstrip().endswith(("{", ",")):
        last_line = lines[-1]
        last_pos = prefix.rfind(last_line) + len(last_line)
        prefix = prefix[:last_pos] + "," + prefix[last_pos:]
    content = f'{prefix}\n  "{key}": {val}\n{content[idx:]}'
    added.append(f"{key} = {val}")

if added:
    with open(settings_file, "w", encoding="utf-8") as f:
        f.write(content)
    print("  ✓ Added to settings.json: " + ", ".join(added))
else:
    print("  ✓ VS Code settings.json already configured")
PY
fi

echo
info "All done! Open any STM32CubeMX/CubeIDE project (.ioc) in VS Code:"
echo "  • Click '▶ ACII' in the bottom status bar (with '☑ Debug' toggled) or press F5"
echo "    on 'Debug <project> (ACII Simulator)' to build, launch the simulator, and debug."
