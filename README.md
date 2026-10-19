# Simulador ACII (`NUCLEO-F401RE` + `LED&KEY`) & VS Code Extension

Virtual simulator for the **STM32 NUCLEO-F401RE** development board and the **TM1638 LED&KEY** expansion module (8× 7-segment displays, 8× red LEDs `L1`–`L8`, 8× keypad buttons `S1`–`S8`, user button `B1`, and user LED `LD2`), bundled with the **ST-Link Auto Debug (`stlink-autodebug`)** VS Code extension for one-click building, running, and source-level GDB debugging.

---

## Quick Start (Automagic Setup)

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
4. **VS Code Extensions**: Packages `vscode-extension/stlink-autodebug-0.4.14.vsix` (zero npm/Node dependencies required) and installs both `ms-vscode.cpptools` and `stlink-autodebug` into VS Code.
5. **VS Code User Settings**: Non-destructively configures `stlinkAutodebug.simulator.debug` (and `stlinkAutodebug.simulator.path` / `stlinkAutodebug.gdbPath` if non-default) in your VS Code `settings.json`.

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
code --install-extension vscode-extension/stlink-autodebug-0.4.14.vsix --force
```

---

## Using the Virtual Simulator with VS Code

### 1. Open an STM32 Project
Open any folder containing an STM32CubeMX / STM32CubeIDE `.ioc` file in VS Code.

- **Automatic Project Setup**: On open, the extension offers to generate `.vscode/tasks.json`, `.vscode/launch.json` (including both `Debug <project> (ST-Link)` and `Debug <project> (ACII Simulator)`), `.vscode/c_cpp_properties.json`, and `openocd.cfg`.
- **Automatic Windows Makefile Fix**: If the project was previously built in STM32CubeIDE on Windows, the extension automatically converts hardcoded `C:\...` paths in `Debug/makefile` to relative paths and cleans Windows-compiled `.o`/`.d` files so local builds and GDB source mapping work immediately.

### 2. Run or Debug in the ACII Simulator

You can launch the simulator from VS Code in three ways:

1. **Status Bar (`▶ ACII` / `☑ Debug`)**:
   - In the bottom-left status bar, click **`☑ Debug`** to toggle between **Debug mode** (builds, starts the simulator paused at reset, attaches GDB, and stops at `main` and your breakpoints) and **Run mode** (builds, starts the simulator, and runs the firmware immediately).
   - Click **`▶ ACII`** to build the project and launch (or hot-reload) the ACII Simulator.
2. **Press `F5` (Run and Debug)**:
   - Select **`Debug <project> (ACII Simulator)`** in the Run and Debug sidebar and press **`F5`**. The extension intercepts the launch, builds the latest `.elf`, starts/restarts the simulator in `--esperar` mode, and attaches GDB on `localhost:3333`.
3. **Command Palette (`Ctrl+Shift+P`)**:
   - `ST-Link: Run in ACII Simulator`
   - `ST-Link: Debug in ACII Simulator`

### 3. Debugging Timed Code (`HAL_Delay`, `uwTick`, Debouncing)

When the CPU is halted at a breakpoint or stepping line-by-line, hardware timers (`SysTick`) pause with the core, so `uwTick` only advances by microseconds per step. The extension provides three features to make debugging timed code effortless:

- **Auto-Advance on Step (`stlinkAutodebug.autoAdvanceSteps`, enabled by default)**:
  When a `Step Over` (`F10`), `Step Into` (`F11`), or `Step Out` (`Shift+F11`) remains running for more than **1.5 seconds** (for instance, inside `HAL_Delay()` or a `while (uwTick - t0 < 50)` debounce wait), the extension automatically connects to Renode's monitor (`localhost:1234`) and increments `uwTick` by `stlinkAutodebug.advanceTimeMs` (`1000 ms`) every `500 ms` until the step finishes.
- **Advance Program Time (`$(watch)` Debug Toolbar Button)**:
  While paused at a breakpoint, click the **watch icon (`⌚`)** in the debug toolbar (or run `ST-Link: Advance Program Time (uwTick)`) to add `1000 ms` directly to `uwTick`.
- **Hold-to-Step (`F10` / `F11` / `Shift+F11`)**:
  Hold down `F10`, `F11`, or `Shift+F11` to step continuously at a steady rate (`stlinkAutodebug.heldStepRate`, default `5` steps/second) without queuing excess steps after you release the key.

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
| `stlinkAutodebug.simulator.path` | `""` *(auto-detected)* | Path to `simulador-acii.sh`, `panel.py`, or the `ACII_Simulador` folder. Auto-detected from `acii-simulador.desktop` or `~/Downloads/ACII_Simulador`. |
| `stlinkAutodebug.simulator.debug` | `false` *(set to `true` by `setup-vscode.sh`)* | Whether the `ACII` status bar button starts a GDB debug session (`true`) or just runs the firmware (`false`). |
| `stlinkAutodebug.stopAtMain` | `true` | Automatically adds a `main` function breakpoint in the Breakpoints view so debug sessions stop at the start of `main()`. |
| `stlinkAutodebug.advanceTimeMs` | `1000` | Milliseconds added to `uwTick` by `Advance Program Time` and auto-advancing steps. |
| `stlinkAutodebug.autoAdvanceSteps` | `true` | Automatically advances `uwTick` via the Renode monitor when a step (`F10`/`F11`/`Shift+F11`) is stuck waiting on `uwTick` for >1.5s. |
| `stlinkAutodebug.heldStepRate` | `5` | Maximum steps per second when holding down `F10`, `F11`, or `Shift+F11`. |
| `stlinkAutodebug.makeCommand` | `"stm32-make"` | Command used to build `Debug/makefile` projects. |
| `stlinkAutodebug.gdbPath` | `"/usr/bin/gdb"` | Path to GDB (`gdb`, `gdb-multiarch`, or `arm-none-eabi-gdb`). |
| `stlinkAutodebug.openocdPath` | `"/usr/bin/openocd"` | Path to OpenOCD (used when flashing/debugging a physical ST-Link board). |

---

## Repository Structure

```text
ACII_Simulador/
├── README.md                  # This documentation & setup guide
├── setup-vscode.sh            # Automated setup script for Simulator + Renode + VS Code
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
├── vscode-extension/          # ST-Link Auto Debug VS Code extension (v0.4.14)
│   ├── package.json           # Extension manifest
│   ├── extension.js           # Extension implementation (ST-Link + ACII Simulator)
│   ├── pack.py                # Zero-dependency VSIX builder
│   ├── README.md              # Extension-specific documentation
│   └── stlink-autodebug-0.4.14.vsix
├── ejemplo/                   # Prebuilt example firmware (ejemplo.elf)
└── Panel/                     # Original Windows Delphi panel sources
```
