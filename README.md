# Simulador ACII (`NUCLEO-F401RE` + `LED&KEY`) & VS Code Extension

Virtual simulator for the **STM32 NUCLEO-F401RE** development board and the **TM1638 LED&KEY** expansion module (8× 7-segment displays, 8× red LEDs `L1`–`L8`, 8× keypad buttons `S1`–`S8`, user button `B1`, and user LED `LD2`), bundled with the **ST-Link Auto Debug (`stlink-autodebug`)** VS Code extension for one-click building, running, and source-level GDB debugging.

---

## Quick Start: Linux & macOS (Automagic Setup)

Clone the repository and run the automated setup script:

```bash
git clone git@github.com:Emefedez/acii-simulador.git ~/Downloads/ACII_Simulador
cd ~/Downloads/ACII_Simulador
./setup-vscode.sh
```

### What `./setup-vscode.sh` does automatically:
1. **Simulator Panel & Launcher (`Panel_py/instalar.sh`)**: Checks Python 3 + Tkinter (`>= 8.6`), installs the panel fonts (`Barlow`, `Barlow Condensed`, `IBM Plex Mono`), and creates the desktop application launcher (`~/.local/share/applications/acii-simulador.desktop` on Linux or `~/Applications/Simulador ACII.app` on macOS).
2. **Renode `1.16.1` Portable**: Checks if Renode `1.16.1` is installed. If missing on Linux (`x86_64` or `arm64`/`aarch64`), automatically downloads and extracts the official `renode-1.16.1` portable release into `../renode_portable/`, where the simulator detects it automatically without needing root privileges.
3. **STM32 Build Helper (`~/.local/bin/stm32-make`)**: Ensures `stm32-make` is available to compile STM32CubeIDE `Debug/makefile` projects using either STM32CubeIDE's bundled GNU Tools for STM32 or the system `arm-none-eabi-gcc` toolchain.
4. **VS Code Extensions**: Packages `vscode-extension/stlink-autodebug-0.4.16.vsix` (zero npm/Node dependencies required) and installs both `ms-vscode.cpptools` and `stlink-autodebug` into VS Code.
5. **VS Code User Settings**: Non-destructively configures `stlinkAutodebug.simulator.debug` and `stm32cube-ide-clangd.enableLinting` (and `stlinkAutodebug.simulator.path` / `stlinkAutodebug.gdbPath` if non-default) in your VS Code `settings.json`.

`stm32-make` also routes the compilers through `~/.local/lib/stm32-make/color/` so build errors are colored in VS Code's terminal when the build runs inside `muvm` (Asahi Linux).

On **Windows**, `setup-vscode.sh` does not apply: follow [Windows Setup](#windows-setup) below.

---

## Windows Setup

There is no setup script for Windows yet; these steps do by hand what `setup-vscode.sh` does. Run the commands in **PowerShell**.

> The extension's Windows support (0.4.15) has not been tested on a Windows machine yet. If a step fails, the **ST-Link Auto Debug** output channel in VS Code (*View → Output*) says what it ran.

### 1. Install the prerequisites

| Component | What to install | Notes |
| :--- | :--- | :--- |
| **Python 3 + Tkinter** | Python `>= 3.8` from [python.org](https://www.python.org/downloads/windows/) | Tk 8.6 comes with it. Keep **"py launcher"** ticked in the installer: the extension starts the panel with `py -3` (or `python` if there is no launcher). The Microsoft Store `python` stub does not work. |
| **Renode** | **v1.16.1**: [`renode-1.16.1.setup.exe`](https://github.com/renode/renode/releases/tag/v1.16.1) | Installs to `C:\Program Files\Renode`, where the panel finds it. Or extract `renode-1.16.1.windows-portable-dotnet.zip` so that `renode.exe` ends up at `ACII_Simulador\Renode\renode.exe`. |
| **STM32CubeIDE** | [STM32CubeIDE for Windows](https://www.st.com/en/development-tools/stm32cubeide.html), default install folder (`C:\ST\STM32CubeIDE_<version>`) | Provides `make`, `arm-none-eabi-gcc` and `arm-none-eabi-gdb`. The extension finds them there by itself. |
| **VS Code** | [Visual Studio Code](https://code.visualstudio.com/) + **C/C++** (`ms-vscode.cpptools`) | Needed for debugging. Optional: **STM32Cube for VS Code** (`stmicroelectronics.stm32-vscode-extension`), for clangd code checking as you type. |

Check Python and Tk:

```powershell
py -3 -c "import tkinter; print(tkinter.TkVersion)"   # must print 8.6 or higher
```

### 2. Get the simulator

Clone (or unzip) the repository to `Downloads\ACII_Simulador`, where the extension looks for it:

```powershell
git clone https://github.com/Emefedez/acii-simulador.git "$env:USERPROFILE\Downloads\ACII_Simulador"
cd "$env:USERPROFILE\Downloads\ACII_Simulador"
```

Try the panel on its own (the fonts load by themselves; nothing to install):

```powershell
py -3 Panel_py\panel.py
```

Load `ejemplo\ejemplo.elf` and press **Arrancar**. The first start takes a while because Renode compiles its C# models. If Windows Defender Firewall asks about Renode, allow it: the panel, Renode and GDB talk over `localhost` ports 1234, 3333 and 3939.

### 3. Install the VS Code extension

The packed extension is in the repository. Install it:

```powershell
code --install-extension ms-vscode.cpptools
code --install-extension vscode-extension\stlink-autodebug-0.4.16.vsix --force
```

To rebuild the `.vsix` after changing the extension: `py -3 vscode-extension\pack.py`.

### 4. VS Code settings

Open *Ctrl+Shift+P → Preferences: Open User Settings (JSON)* and add:

```jsonc
"stlinkAutodebug.simulator.debug": true,       // the ACII button debugs (stops at breakpoints)
"stm32cube-ide-clangd.enableLinting": true      // show errors/warnings while typing (STM32Cube clangd)
```

Only if your setup differs from the defaults:

```jsonc
// The repository is somewhere other than Downloads\ACII_Simulador:
"stlinkAutodebug.simulator.path": "D:\\ruta\\ACII_Simulador\\Panel_py\\panel.py",
// STM32CubeIDE is not under C:\ST: add its two tools\bin folders
// (...gnu-tools-for-stm32...\tools\bin and ...externaltools.make...\tools\bin)
// to PATH and use:
"stlinkAutodebug.makeCommand": "make",
"stlinkAutodebug.gdbPath": "arm-none-eabi-gdb"
```

### 5. Use it

Open the project folder (the one with the `.ioc`) in VS Code, accept the setup the extension offers, and press **▶ ACII** in the status bar, or **F5** on **Debug &lt;project&gt; (ACII Simulator)**: see [Using the Virtual Simulator with VS Code](#using-the-virtual-simulator-with-vs-code).

What is different on Windows:

- **Build**: with the default `stlinkAutodebug.makeCommand` (`stm32-make`, which does not exist on Windows), the build task runs STM32CubeIDE's `make.exe` with its GNU Tools for STM32 first in `PATH`, written into `.vscode/tasks.json`.
- **Projects copied between machines**: the Linux-side fix for `C:\...` paths in `Debug/makefile` is not applied on Windows, where those paths are the machine's own.
- **Real board (ST-Link)**: flashing and debugging a physical NUCLEO need an OpenOCD on `PATH` (for example the [xPack OpenOCD](https://xpack-dev-tools.github.io/openocd-xpack/)) or `stlinkAutodebug.openocdPath`; automatic ST-Link plug detection is Linux only. The simulator does not need OpenOCD.

---

## Manual Setup Guide

### 1. Prerequisites

| Component | Requirement | Installation Hint |
| :--- | :--- | :--- |
| **Python 3 + Tkinter** | Python `>= 3.8` with Tk `>= 8.6` | Arch: `sudo pacman -S python tk`<br>Ubuntu/Debian: `sudo apt install python3 python3-tk`<br>macOS: `brew install python-tk` |
| **Renode** | **v1.16.1** (exact version tested with custom C# peripherals) | [Renode v1.16.1 Releases](https://github.com/renode/renode/releases/tag/v1.16.1) (`linux-portable-dotnet`, `linux-arm64-portable-dotnet`, or `osx-arm64-portable.dmg`) |
| **ARM Toolchain & Make** | `arm-none-eabi-gcc` + `make` (or STM32CubeIDE) | Arch: `sudo pacman -S arm-none-eabi-gcc arm-none-eabi-newlib make`<br>Ubuntu/Debian: `sudo apt install gcc-arm-none-eabi make` |
| **GDB** | Multi-arch `gdb` or `arm-none-eabi-gdb` | Arch: `sudo pacman -S gdb`<br>Ubuntu/Debian: `sudo apt install gdb-multiarch` |
| **VS Code** | Visual Studio Code + `ms-vscode.cpptools` | `code --install-extension ms-vscode.cpptools` |

### 2. Install the Simulator Standalone

```bash
./Panel_py/instalar.sh
```

You can launch the simulator from your system application menu (**Simulador ACII**) or directly from the terminal:

```bash
./Panel_py/simulador-acii.sh
```

### 3. Build & Install the VS Code Extension Manually

The extension lives in [`vscode-extension/`](./vscode-extension/) and uses a zero-dependency Python packager (`pack.py`):

```bash
python3 vscode-extension/pack.py
code --install-extension vscode-extension/stlink-autodebug-0.4.16.vsix --force
```

---

## Using the Virtual Simulator with VS Code

### 1. Open an STM32 Project
Open any folder containing an STM32CubeMX / STM32CubeIDE `.ioc` file in VS Code.

- **Automatic Project Setup**: On open, the extension offers to generate `.vscode/tasks.json`, `.vscode/launch.json` (including both `Debug <project> (ST-Link)` and `Debug <project> (ACII Simulator)`), `.vscode/c_cpp_properties.json`, `compile_commands.json`, and `openocd.cfg`.
- **Code checking while typing**: `compile_commands.json` gives clangd (used by the STM32Cube extension instead of the C/C++ extension's IntelliSense) the Debug build's include paths, defines and warnings, so HAL symbols resolve and errors show as you type, not only when building. The STM32Cube clangd extension hides them unless `stm32cube-ide-clangd.enableLinting` is on: the extension offers to turn it on. After changing it, run **clangd: Restart language server** if nothing shows.
- **Automatic Windows Makefile Fix**: If the project was previously built in STM32CubeIDE on Windows, the extension automatically converts hardcoded `C:\...` paths in `Debug/makefile` to relative paths and cleans Windows-compiled `.o`/`.d` files so local builds and GDB source mapping work immediately.

### 2. Run or Debug in the ACII Simulator

You can launch the simulator from VS Code in three ways:

1. **Status Bar (`▶ ACII` / `☑ Debug`)**:
   - In the bottom-left status bar, click **`☑ Debug`** to toggle between **Debug mode** (builds, starts the simulator paused at reset, attaches GDB, and stops at `main` and your breakpoints) and **Run mode** (builds, starts the simulator, and runs the firmware immediately).
   - Click **`▶ ACII`** to build the project and launch (or hot-reload) the ACII Simulator.
2. **Press `F5` (Run and Debug)**:
   - Select **`Debug <project> (ACII Simulator)`** in the Run and Debug sidebar and press **`F5`**. The extension intercepts the launch, builds the latest `.elf`, starts/restarts the simulator in `--esperar` mode, and attaches GDB on `localhost:3333`.
3. **Command Palette (`Ctrl+Shift+P`)**:
   - `ST-Link: Build & Run in ACII Simulator (no debugger)`
   - `ST-Link: Build & Debug in ACII Simulator`
   - `ST-Link: Close ACII Simulator`

### 3. Debugging Timed Code (`HAL_Delay`, `uwTick`, Debouncing)

When the CPU is halted at a breakpoint or stepping line-by-line, hardware timers (`SysTick`) pause with the core, so `uwTick` only advances by microseconds per step. The extension provides three features to make debugging timed code effortless:

- **Auto-Advance on Step (`stlinkAutodebug.autoAdvanceSteps`, enabled by default)**:
  When a `Step Over` (`F10`), `Step Into` (`F11`), or `Step Out` (`Shift+F11`) remains running for more than **1.5 seconds** (for instance, inside `HAL_Delay()` or a `while (uwTick - t0 < 50)` debounce wait), the extension automatically connects to Renode's monitor (the port the panel reports, normally `localhost:1234`) and increments `uwTick` by `stlinkAutodebug.advanceTimeMs` (`100 ms`) every `500 ms` until the step finishes.
- **Advance Program Time (`$(watch)` Debug Toolbar Button)**:
  While paused at a breakpoint, click the **watch icon (`⌚`)** in the debug toolbar (or run `ST-Link: Advance Program Time (HAL tick)`) to add `stlinkAutodebug.advanceTimeMs` (`100 ms`) directly to `uwTick`.
- **Hold-to-Step (`F10` / `F11` / `Shift+F11`)**:
  Hold down `F10`, `F11`, or `Shift+F11` to step continuously at a steady rate (`stlinkAutodebug.heldStepRate`, default `8` steps/second) without queuing excess steps after you release the key.

### 4. Interacting with Buttons in the Simulator Panel

- **Momentary Press**: Left-click `B1` or `S1`–`S8` (or press keyboard keys `B` and `1`–`8`).
- **Latch / Hold (`mantener`) for Debugging**: While the program is paused at a breakpoint in VS Code, a momentary click would release before you resume execution. To keep a button held down while stepping through code:
  - Tick the **`mantener`** checkbox under `B1` or `S1`–`S8`, **or**
  - **Right-click** or **Shift+click** the button directly on the board canvas.
- **Resizable Window**: Drag any corner of the simulator window to scale the board smoothly between `0.75×` and `2.2×`.

---

## VS Code Extension Settings (`stlinkAutodebug.*`)

| Setting | Default | Description |
| :--- | :--- | :--- |
| `stlinkAutodebug.simulator.path` | `""` *(auto-detected)* | Path to `simulador-acii.sh`, `panel.py`, or the `ACII_Simulador` folder. Auto-detected from `acii-simulador.desktop` or `~/Downloads/ACII_Simulador` (`%USERPROFILE%\Downloads\ACII_Simulador` on Windows, where `panel.py` is used). |
| `stlinkAutodebug.simulator.debug` | `false` *(set to `true` by `setup-vscode.sh`)* | Whether the `ACII` status bar button starts a GDB debug session (`true`) or just runs the firmware (`false`). |
| `stlinkAutodebug.stopAtMain` | `true` | Automatically adds a `main` function breakpoint in the Breakpoints view so debug sessions stop at the start of `main()`. |
| `stlinkAutodebug.advanceTimeMs` | `100` | Milliseconds added to `uwTick` by `Advance Program Time` and auto-advancing steps. |
| `stlinkAutodebug.autoAdvanceSteps` | `true` | Automatically advances `uwTick` via the Renode monitor when a step (`F10`/`F11`/`Shift+F11`) is stuck waiting on `uwTick` for >1.5s. |
| `stlinkAutodebug.heldStepRate` | `8` | Maximum steps per second when holding down `F10`, `F11`, or `Shift+F11`. |
| `stlinkAutodebug.makeCommand` | `"stm32-make"` | Command used to build `Debug/makefile` projects. If `stm32-make` is not installed (Windows), STM32CubeIDE's own `make` is used with its toolchain first in `PATH`. |
| `stlinkAutodebug.gdbPath` | `"/usr/bin/gdb"` | Path to GDB (`gdb`, `gdb-multiarch`, or `arm-none-eabi-gdb`). If `/usr/bin/gdb` does not exist (Windows), STM32CubeIDE's `arm-none-eabi-gdb` is used, else one from `PATH`. |
| `stlinkAutodebug.openocdPath` | `"openocd"` | OpenOCD executable (used when flashing/debugging a physical ST-Link board). |

---

## Repository Structure

```text
ACII_Simulador/
├── README.md                  # This documentation & setup guide
├── setup-vscode.sh            # Automated setup (Linux/macOS) for Simulator + Renode + VS Code
├── GUIA DEL SIMULADOR.pdf     # Original simulator user guide (Spanish)
├── acii-simulador.desktop     # Linux desktop entry template
├── Panel_py/                  # Cross-platform Python/Tkinter simulator panel
│   ├── panel.py               # Main GUI & --ordenes JSON control interface for VS Code
│   ├── emulador.py            # Renode 1.16.1 lifecycle & port management (1234/3333/3939)
│   ├── modulo.py              # TCP socket client for the TM1638 LED&KEY model
│   ├── dibujo.py              # Vector canvas renderer with dynamic scaling
│   ├── cubeide.py             # STM32CubeIDE project & ELF discovery
│   ├── instalar.sh            # Font & desktop launcher installer (Linux & macOS)
│   ├── simulador-acii.sh      # POSIX launcher script
│   └── LEEME.md               # Technical notes on the Python panel & local patches
├── plataforma/                # Renode platform definition & custom C# peripheral models
│   ├── nucleo_f401re.repl     # STM32F401RE + LED&KEY board description
│   ├── ModuloLedKey.cs        # TM1638 7-segment display, LEDs, and keypad peripheral
│   ├── PuertoGPIO.cs          # Custom STM32F4 GPIO model with external pull-ups
│   ├── Temporizador.cs        # Timer peripheral model
│   └── ConversorADC.cs        # ADC peripheral model
├── vscode-extension/          # ST-Link Auto Debug VS Code extension (v0.4.16)
│   ├── package.json           # Extension manifest
│   ├── extension.js           # Extension implementation (ST-Link + ACII Simulator)
│   ├── pack.py                # Zero-dependency VSIX builder
│   ├── README.md              # Extension-specific documentation
│   └── stlink-autodebug-0.4.16.vsix
├── ejemplo/                   # Prebuilt example firmware (ejemplo.elf)
└── Panel/                     # Original Windows Delphi panel sources
```
