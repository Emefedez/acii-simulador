'use strict';
// ST-Link Auto Debug: for every STM32CubeMX project (.ioc) in the workspace,
// generates the files needed to build, flash and debug it on a real board with
// native OpenOCD + GDB (openocd.cfg, .vscode/tasks.json, .vscode/launch.json),
// and offers to flash/debug when an ST-Link is connected. Runs only in
// workspaces containing a .ioc file; the probe is checked when the project
// opens and, optionally, on kernel USB hotplug events (no polling).
// Without a board, it builds and runs (or debugs) the project in the ACII
// simulator: the course's Renode model of the NUCLEO-F401RE + LED&KEY panel.
const vscode = require('vscode');
const { spawn } = require('child_process');
const fs = require('fs');
const net = require('net');
const os = require('os');
const path = require('path');

const SCRIPTS = '/usr/share/openocd/scripts';
const USB_SYSFS = '/sys/bus/usb/devices';
const USB_DEV = '/dev/bus/usb';
const SKIP_DIRS = new Set(['node_modules', 'Drivers', 'Middlewares', 'Debug', 'Release', 'build']);
const OPENOCD_LOG = '.vscode/openocd.log';
const SIM_GDB_PORT = 3333; // fixed by the simulator (emulador.PUERTO_GDB)
const SIM_START_TIMEOUT = 120000; // Renode compiles its C# models on first start

function readText(file) {
  try { return fs.readFileSync(file, 'utf8').trim(); } catch { return undefined; }
}

const hex = s => s.toLowerCase().replace(/^0x/, '').padStart(4, '0');

// ---------------------------------------------------------------- probe

// The USB IDs OpenOCD itself drives as an ST-Link, so detection matches it.
function stlinkIds(scripts = SCRIPTS) {
  const ids = new Set();
  const m = /^hla_vid_pid\s+(.+)$/m.exec(readText(path.join(scripts, 'interface/stlink.cfg')) ?? '');
  const t = m ? m[1].trim().split(/\s+/) : [];
  for (let i = 0; i + 1 < t.length; i += 2) ids.add(`${hex(t[i])}:${hex(t[i + 1])}`);
  if (ids.size === 0) {
    for (const p of ['3744', '3748', '374b', '374d', '374e', '374f', '3752', '3753', '3754']) ids.add(`0483:${p}`);
  }
  return ids;
}

function findStlink(ids, root = USB_SYSFS) {
  let names;
  try { names = fs.readdirSync(root); } catch { return undefined; }
  for (const name of names) {
    if (name.includes(':')) continue; // USB interfaces, not devices
    const dir = path.join(root, name);
    const id = `${readText(path.join(dir, 'idVendor'))}:${readText(path.join(dir, 'idProduct'))}`;
    if (!ids.has(id)) continue;
    const bus = readText(path.join(dir, 'busnum'));
    const dev = readText(path.join(dir, 'devnum'));
    return {
      id,
      product: readText(path.join(dir, 'product')) || 'ST-Link',
      node: bus && dev ? path.join(USB_DEV, bus.padStart(3, '0'), dev.padStart(3, '0')) : undefined,
    };
  }
  return undefined;
}

function canOpen(node) {
  if (!node) return true;
  try { fs.accessSync(node, fs.constants.R_OK | fs.constants.W_OK); return true; } catch { return false; }
}

// ---------------------------------------------------------------- projects

function findIocFiles(dir, depth = 2) {
  const out = [];
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return out; }
  for (const e of entries) {
    if (e.isFile() && e.name.endsWith('.ioc')) out.push(path.join(dir, e.name));
    else if (e.isDirectory() && depth > 0 && !e.name.startsWith('.') && !SKIP_DIRS.has(e.name)) {
      out.push(...findIocFiles(path.join(dir, e.name), depth - 1));
    }
  }
  return out;
}

// Everything the generated files need, read from the .ioc and the build files
// CubeMX/CubeIDE produced next to it. `folder` is the workspace folder path.
function readProject(iocFile, folder) {
  const props = {};
  for (const line of (readText(iocFile) ?? '').split(/\r?\n/)) {
    const i = line.indexOf('=');
    if (i > 0) props[line.slice(0, i)] = line.slice(i + 1);
  }
  const dir = path.dirname(iocFile);
  const name = props['ProjectManager.ProjectName'] || path.basename(iocFile, '.ioc');
  const project = {
    ioc: iocFile,
    dir,
    folder: folder ?? dir,
    rel: folder ? path.relative(folder, dir) : '',
    name,
    family: props['Mcu.Family'],
    mcu: props['Mcu.UserName'] || props['Mcu.Name'],
    board: props.board && props.board !== 'custom' ? props.board : undefined,
    build: 'none',
    artifact: name,
  };
  const cmakeLists = readText(path.join(dir, 'CMakeLists.txt'));
  const makefile = readText(path.join(dir, 'Debug', 'makefile'));
  if (cmakeLists && fs.existsSync(path.join(dir, 'CMakePresets.json'))) {
    project.build = 'cmake'; // CubeMX "CMake" toolchain
    project.artifact = /set\s*\(\s*CMAKE_PROJECT_NAME\s+"?([^\s")]+)/i.exec(cmakeLists)?.[1] ?? name;
  } else if (makefile) {
    project.build = 'make'; // STM32CubeIDE managed build
    project.artifact = /^BUILD_ARTIFACT_NAME\s*:=\s*(.+)$/m.exec(makefile)?.[1].trim() ?? name;
  }
  return project;
}

// STM32CubeIDE writes the project's absolute path into Debug/makefile (the
// linker script, -T"C:\Users\...\proj\STM32F401RETX_FLASH.ld"). A project
// built on Windows then fails here with "multiple target patterns" (make reads
// the drive's colon). Each Windows path is replaced by the relative path, from
// Debug/, of the longest tail of it that exists in the project. Returns the
// replacements made ([] if none), writing the file only if there were any.
function fixWindowsMakefile(projectDir) {
  const file = path.join(projectDir, 'Debug', 'makefile');
  let text;
  try { text = fs.readFileSync(file, 'utf8'); } catch { return []; }
  const fixes = [];
  const fixed = text.replace(/\b[A-Za-z]:\\[^\s"'$()]+/g, win => {
    const parts = win.split('\\').slice(1).filter(Boolean);
    for (let i = 0; i < parts.length; i++) {
      const target = path.join(projectDir, ...parts.slice(i));
      if (!fs.existsSync(target)) continue;
      const rel = path.relative(path.dirname(file), target).split(path.sep).join('/');
      fixes.push(`${win} -> ${rel}`);
      return rel;
    }
    return win;
  });
  if (fixes.length) fs.writeFileSync(file, fixed);
  return fixes;
}

// Objects in Debug/ compiled on Windows (a project brought from a CubeIDE on
// Windows): their debug info names C:\... sources, so a debugger here cannot
// show the code, and make may keep them even after the sources change. Deletes
// them with their .d/.su/.cyclo so the next build compiles everything here.
// Returns how many objects were deleted.
function removeWindowsObjects(projectDir) {
  const objects = [];
  const walk = dir => {
    let entries;
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      const p = path.join(dir, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name.endsWith('.o')) objects.push(p);
    }
  };
  walk(path.join(projectDir, 'Debug'));
  let removed = 0;
  for (const o of objects) {
    let text;
    try { text = fs.readFileSync(o).toString('latin1'); } catch { continue; }
    // A Windows directory in the debug strings: "C:\ST\STM32CubeIDE..." from
    // gcc, "C:/Users/.../Debug" from the assembler.
    if (!/[A-Za-z]:[\\/][\w .-]+[\\/]/.test(text)) continue;
    for (const ext of ['.o', '.d', '.su', '.cyclo']) {
      try { fs.unlinkSync(o.slice(0, -2) + ext); } catch { /* not there */ }
    }
    removed++;
  }
  return removed;
}

// Mcu.Family "STM32F4" -> stm32f4x.cfg; "STM32L0" -> stm32l0.cfg.
function targetCfg(family, scripts = SCRIPTS) {
  if (!family) return undefined;
  const base = family.toLowerCase();
  return [`${base}x.cfg`, `${base}.cfg`].find(c => fs.existsSync(path.join(scripts, 'target', c)));
}

// Newest mtime among files under dir accepted by test, skipping build output.
function newest(dir, test, depth, skip = SKIP_DIRS) {
  let best;
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return best; }
  for (const e of entries) {
    const p = path.join(dir, e.name);
    let found;
    if (e.isFile() && test(e.name)) {
      try { found = { file: p, mtime: fs.statSync(p).mtimeMs }; } catch { /* vanished */ }
    } else if (e.isDirectory() && depth > 0 && !e.name.startsWith('.') && !skip.has(e.name)) {
      found = newest(p, test, depth - 1, skip);
    }
    if (found && (!best || found.mtime > best.mtime)) best = found;
  }
  return best;
}

// The ELF, relative to the project directory.
function elfRel(project) {
  if (project.build === 'make') return path.join('Debug', `${project.artifact}.elf`);
  if (project.build === 'cmake') return path.join('build', 'Debug', `${project.artifact}.elf`);
  const found = newest(project.dir, n => n.endsWith('.elf'), 3, new Set(['node_modules']));
  return found ? path.relative(project.dir, found.file) : path.join('Debug', `${project.name}.elf`);
}

function elfIsStale(project) {
  const elf = path.join(project.dir, elfRel(project));
  const src = newest(project.dir, n => /\.(c|cpp|h|hpp|s|ld|ioc)$/i.test(n), 4);
  try { return !!src && src.mtime > fs.statSync(elf).mtimeMs; } catch { return false; }
}

function labels(project) {
  return {
    build: `Build ${project.name}`,
    flash: `Flash ${project.name} (ST-Link)`,
    debug: `Debug ${project.name} (ST-Link)`,
    simDebug: `Debug ${project.name} (ACII Simulator)`,
  };
}

// The tasks.json / launch.json entries for a project, with ${workspaceFolder}
// paths so the files stay valid if the project folder moves.
function entries(project, s) {
  const P = (...parts) => ['${workspaceFolder}', project.rel, ...parts].filter(Boolean).join('/');
  const l = labels(project);
  const elf = P(...elfRel(project).split(path.sep));
  const cfg = P('openocd.cfg');
  const quiet = 'tcl_port disabled; telnet_port disabled';
  const tasks = [];
  if (project.build === 'make') {
    tasks.push({
      label: l.build,
      type: 'process',
      command: s.makeCommand,
      args: [`-j${os.cpus().length}`, 'all'],
      options: { cwd: P('Debug') },
      group: 'build',
      problemMatcher: { base: '$gcc', fileLocation: ['autoDetect', P('Debug')] },
    });
  } else if (project.build === 'cmake') {
    tasks.push({
      label: l.build,
      type: 'process',
      command: 'bash',
      args: ['-c', `{ test -f build/Debug/CMakeCache.txt || ${s.cubeCommand} cmake --preset Debug; } && ${s.cubeCommand} cmake --build --preset Debug`],
      options: { cwd: P() },
      group: 'build',
      problemMatcher: { base: '$gcc', fileLocation: ['autoDetect', P('build', 'Debug')] },
    });
  }
  const built = project.build !== 'none';
  tasks.push({
    label: l.flash,
    type: 'process',
    command: s.openocdPath,
    args: ['-f', cfg, '-c', `gdb_port disabled; ${quiet}`, '-c', `program {${elf}} verify reset exit`],
    options: { cwd: P() },
    ...(built ? { dependsOn: l.build } : {}),
    problemMatcher: [],
  });
  // GDB starts OpenOCD itself over a pipe: no TCP port to collide, OpenOCD
  // exits with the session, and paths with spaces survive. In pipe mode
  // OpenOCD prints nothing, so its log goes to a file the extension reports.
  const launch = {
    ...remoteLaunch(l.debug, elf, P(), s,
      `| ${s.openocdPath} -c "gdb_port pipe; ${quiet}; log_output {\${workspaceFolder}/${OPENOCD_LOG}}" -f "${cfg}"`),
    ...(built ? { preLaunchTask: l.build } : {}),
    postRemoteConnectCommands: [
      { text: 'monitor reset halt', description: 'Halt the MCU' },
      { text: 'load', description: 'Flash the ELF' },
      { text: 'monitor reset halt', description: 'Restart from reset' },
    ],
  };
  // F5 on this entry doesn't connect by itself: the extension intercepts it
  // and builds, opens (or restarts) the simulator and attaches, as the ACII
  // button does with Debug ticked, so it also works after the panel closed.
  const configurations = [launch];
  if (findSimulator(s.simulatorPath)) configurations.push(simulatorLaunch({ ...project, dir: P() }, elf, s));
  return { tasks, launch, configurations };
}

// IntelliSense settings for cpptools: the include paths and defines STM32CubeIDE
// has for the Debug build (.cproject), so hover, go-to-definition and the
// doc comments of the project's own headers (TM1638.h...) work without CubeIDE.
// The .cproject paths are relative to Debug/; without it, the usual HAL ones.
function cppProperties(project) {
  const P = (...parts) => ['${workspaceFolder}', project.rel, ...parts].filter(Boolean).join('/');
  const cproject = readText(path.join(project.dir, '.cproject')) ?? '';
  const start = cproject.search(/<configuration\b[^>]*\bname="Debug"/);
  const block = start < 0 ? '' : cproject.slice(start, cproject.indexOf('</configuration>', start));
  const values = kind => {
    const m = new RegExp(`<option\\b[^>]*c\\.compiler\\.option\\.${kind}"[^>]*>([\\s\\S]*?)</option>`).exec(block);
    return m ? [...m[1].matchAll(/<listOptionValue\b[^>]*\bvalue="([^"]*)"/g)].map(v => v[1]) : [];
  };
  let include = values('includepaths')
    .filter(v => !v.includes('${'))
    .map(v => path.posix.normalize(path.posix.join('Debug', v.replace(/\\/g, '/'))));
  const defines = values('definedsymbols');
  if (!include.length) {
    const fam = (project.family ?? '').toUpperCase();
    include = ['Core/Inc', `Drivers/${fam}xx_HAL_Driver/Inc`, `Drivers/${fam}xx_HAL_Driver/Inc/Legacy`,
      `Drivers/CMSIS/Device/ST/${fam}xx/Include`, 'Drivers/CMSIS/Include']
      .filter(d => fs.existsSync(path.join(project.dir, d)));
    defines.push('USE_HAL_DRIVER');
  }
  const gcc = which('arm-none-eabi-gcc');
  return JSON.stringify({
    configurations: [{
      name: project.name,
      includePath: include.map(d => P(d)),
      defines,
      ...(gcc ? { compilerPath: gcc } : {}),
      cStandard: 'gnu11',
      intelliSenseMode: 'linux-gcc-arm',
    }],
    version: 4,
  }, null, 2) + '\n';
}

function openocdCfg(project, target) {
  const what = [project.mcu, project.board].filter(Boolean).join(', ');
  return `# OpenOCD setup for ${project.name}${what ? ` (${what})` : ''}, generated by ST-Link Auto Debug.\n` +
    '# Used by the Flash/Debug task and launch configuration; edit freely, it is not overwritten.\n' +
    'source [find interface/stlink.cfg]\n' +
    `source [find target/${target}]\n`;
}

// Adds missing entries; replaces an entry only while it is exactly what this
// extension last wrote (`written` maps key -> JSON), so user edits are kept.
function mergeEntries(current, desired, key, written, scope) {
  const out = Array.isArray(current) ? current.slice() : [];
  const added = [];
  const updated = [];
  for (const d of desired) {
    const id = `${scope}:${d[key]}`;
    const json = JSON.stringify(d);
    const i = out.findIndex(e => e && e[key] === d[key]);
    if (i < 0) {
      out.push(d);
      added.push(d[key]);
    } else if (JSON.stringify(out[i]) === written[id] && written[id] !== json) {
      out[i] = d;
      updated.push(d[key]);
    } else {
      continue;
    }
    written[id] = json;
  }
  return { out, changed: added.length + updated.length > 0, added, updated };
}

// What apply() found to change, for a prompt: "add openocd.cfg and update
// “Debug x (ST-Link)” in .vscode/launch.json". `onlyUpdates`: nothing is new,
// only entries this extension wrote earlier (and nobody edited) change.
function describeChanges(changes) {
  const quote = names => names.map(n => `“${n}”`).join(', ');
  const adds = changes.filter(c => c.added.length).map(c => c.newFile ? c.file : `${quote(c.added)} to ${c.file}`);
  const updates = changes.filter(c => c.updated.length).map(c => `${quote(c.updated)} in ${c.file}`);
  const text = [adds.length ? `add ${adds.join(', ')}` : '', updates.length ? `update ${updates.join(', ')}` : '']
    .filter(Boolean).join(' and ');
  return { text, onlyUpdates: !adds.length };
}

function which(cmd) {
  if (cmd.includes('/')) return fs.existsSync(cmd) ? cmd : undefined;
  for (const dir of (process.env.PATH ?? '').split(':').concat(['/usr/bin', '/usr/local/bin'])) {
    const p = path.join(dir, cmd);
    try { fs.accessSync(p, fs.constants.X_OK); return p; } catch { /* keep looking */ }
  }
  return undefined;
}

// ---------------------------------------------------------------- simulator

// The ACII simulator's launcher (simulador-acii.sh, which finds a Python with
// Tk 8.6 and keeps its state inside the package), or panel.py. `configured`
// may name either, or the package / Panel_py folder. Otherwise it is found
// from the menu entry its installer writes, then the usual unpack places.
function findSimulator(configured, home = os.homedir()) {
  const launchers = dir => [path.join(dir, 'simulador-acii.sh'), path.join(dir, 'Panel_py', 'simulador-acii.sh'),
    path.join(dir, 'panel.py'), path.join(dir, 'Panel_py', 'panel.py')];
  const candidates = [];
  if (configured) {
    const p = configured.replace(/^~(?=\/|$)/, home);
    candidates.push(p, ...launchers(p));
  } else {
    for (const d of [path.join(home, '.local/share/applications'), '/usr/share/applications', '/usr/local/share/applications']) {
      const exec = /^Exec=(.+)$/m.exec(readText(path.join(d, 'acii-simulador.desktop')) ?? '')?.[1];
      if (exec) candidates.push(exec.trim().replace(/^"|"$/g, '').replace(/\s+%\w$/, ''));
    }
    for (const d of ['Downloads', 'Descargas', '', 'Applications', 'Aplicaciones']) {
      candidates.push(...launchers(path.join(home, d, 'ACII_Simulador')));
    }
  }
  return candidates.find(c => /\.(sh|py)$/.test(c) && fs.existsSync(c));
}

// GDB attaches to the simulator's GDB server; the simulator was started
// halted at reset ("Esperar al depurador") until GDB attaches.
function simulatorLaunch(project, elf, s) {
  return remoteLaunch(labels(project).simDebug, elf, project.dir, s, `localhost:${SIM_GDB_PORT}`);
}

// A cppdbg launch that connects GDB to `server` (host:port, or "| command"
// for a pipe). It stops only at the user's breakpoints: an automatic stop at
// main (a tbreak the debug adapter doesn't know) is reported as an exception.
// The target waits at reset until then, so even breakpoints in the startup
// code are hit. cppdbg must make the connection itself, via
// miDebuggerServerAddress: when it is done with customLaunchSetupCommands
// instead, cppdbg takes the program for a local process and pauses it with
// `kill -INT <pid>`, which never reaches the MCU, so Pause, and breakpoints
// added while it runs, did nothing.
function remoteLaunch(name, elf, cwd, s, server) {
  return {
    name,
    type: 'cppdbg',
    request: 'launch',
    program: elf,
    cwd,
    MIMode: 'gdb',
    miDebuggerPath: s.gdbPath,
    // cppdbg on an ARM64 host otherwise fails with "Specified argument was
    // out of the range of valid values. (Parameter 'arch')".
    targetArchitecture: 'arm',
    miDebuggerServerAddress: server,
    setupCommands: [{ text: '-enable-pretty-printing', ignoreFailures: true }],
  };
}

// ------------------------------------------------- stepping in the simulator

// The port of the Renode monitor of the simulator we started: the panel gives
// Renode `--port N` (the first free one from 1234) and its script is simula.resc.
function renodeMonitorPort() {
  for (const pid of fs.readdirSync('/proc').filter(n => /^\d+$/.test(n))) {
    let argv;
    try { argv = fs.readFileSync(`/proc/${pid}/cmdline`, 'latin1').split('\0'); } catch { continue; }
    const i = argv.indexOf('--port');
    if (i >= 0 && argv.some(a => /renode$/.test(a)) && argv.some(a => a.endsWith('simula.resc'))) return Number(argv[i + 1]);
  }
  return undefined;
}

// Sends monitor commands to Renode, resolves with each one's output.
function renodeMonitor(port, commands) {
  return new Promise((resolve, reject) => {
    const sock = net.connect(port, '127.0.0.1');
    const outputs = [];
    let buf = '';
    sock.setTimeout(4000, () => { sock.destroy(); reject(new Error('Renode monitor timed out')); });
    sock.on('error', reject);
    sock.on('data', d => { buf += d.toString('latin1'); });
    sock.on('connect', async () => {
      const send = async c => { buf = ''; sock.write(c + '\r\n'); await new Promise(r => setTimeout(r, 250)); return buf.replace(/\x1b\[[0-9;]*m/g, ''); };
      try {
        await send('');
        for (const c of commands) outputs.push(await send(c));
        sock.end();
        resolve(outputs);
      } catch (e) { sock.destroy(); reject(e); }
    });
  });
}

// Address of the HAL tick counter in an ELF, from GDB: "…at address 0x20000094."
function uwTickAddress(gdbPath, elf) {
  return new Promise(resolve => {
    const p = spawn(gdbPath, ['-batch', '-nx', '-ex', 'info address uwTick', elf]);
    let out = '';
    p.stdout.on('data', d => { out += d; });
    p.on('error', () => resolve(undefined));
    p.on('close', () => resolve(/at address (0x[0-9a-f]+)/i.exec(out)?.[1]));
  });
}

// ---------------------------------------------------------------- extension

let stopSimulatorOnExit; // set by activate: closes the simulator panel we started

function activate(context) {
  const log = vscode.window.createOutputChannel('ST-Link Auto Debug', { log: true });
  const ids = stlinkIds();
  const status = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 50);
  status.command = 'stlinkAutodebug.debug';
  status.tooltip = 'Build, flash & debug an STM32 project on this board';
  // The simulator's Run button and, next to it, the "debug" checkbox. With ids
  // (so each can be shown/hidden on its own from the status bar's menu) and a
  // high priority: at the end of the left side they were cut off when the
  // status bar was full.
  const simStatus = vscode.window.createStatusBarItem('stlinkAutodebug.simulator', vscode.StatusBarAlignment.Left, 1000);
  simStatus.name = 'ACII Simulator: Run';
  simStatus.command = 'stlinkAutodebug.simulate';
  const simDebugStatus = vscode.window.createStatusBarItem('stlinkAutodebug.simulatorDebug', vscode.StatusBarAlignment.Left, 999);
  simDebugStatus.name = 'ACII Simulator: Debug checkbox';
  simDebugStatus.command = 'stlinkAutodebug.toggleSimulatorDebug';
  const config = () => vscode.workspace.getConfiguration('stlinkAutodebug');
  const settings = () => {
    const c = config();
    return {
      onConnect: c.get('onConnect'),
      generateFiles: c.get('generateFiles'),
      openocdPath: c.get('openocdPath'),
      gdbPath: c.get('gdbPath'),
      makeCommand: c.get('makeCommand'),
      cubeCommand: c.get('cubeCommand'),
      simulatorPath: c.get('simulator.path'),
      simulatorDebug: c.get('simulator.debug'),
      stopAtMain: c.get('stopAtMain'),
      advanceTimeMs: c.get('advanceTimeMs'),
      autoAdvanceSteps: c.get('autoAdvanceSteps'),
      heldStepRate: c.get('heldStepRate'),
    };
  };
  const sessions = new Map(); // debug session id -> start time
  const simSessions = new Set(); // our debug sessions attached to the ACII simulator
  let current; // device node of the probe last seen, so a replug asks again
  let watchers = [];
  let timer;
  let flashDone; // listener for the running Flash task
  let sim; // the simulator panel we started: { proc, listeners }
  let simBusy = false; // a build/start is in progress
  let simAttaching = false; // simulate() is starting the session itself
  const running = new Set(); // ids of debug sessions whose program is running
  let lastStep = 0; // when the step keys last stepped

  const iocWatcher = vscode.workspace.createFileSystemWatcher('**/*.ioc');
  // CubeMX writes the .ioc first; the build system appears later (CubeIDE's
  // Debug/makefile on first build, or the CMake files on code generation).
  const buildWatcher = vscode.workspace.createFileSystemWatcher('**/{Debug/makefile,CMakePresets.json}', false, false, true);
  const resync = uri => {
    const dir = path.basename(path.dirname(uri.fsPath)) === 'Debug' ? path.dirname(path.dirname(uri.fsPath)) : path.dirname(uri.fsPath);
    const ioc = uri.fsPath.endsWith('.ioc') ? uri.fsPath : findIocFiles(dir, 0)[0];
    if (ioc) setUp([projectFor(ioc)].filter(Boolean), false).catch(e => log.appendLine(`setup error: ${e.message}`));
  };

  context.subscriptions.push(
    log, status, simStatus, simDebugStatus, iocWatcher, buildWatcher,
    iocWatcher.onDidCreate(resync),
    buildWatcher.onDidCreate(resync),
    buildWatcher.onDidCreate(uri => fixMakefile(path.dirname(path.dirname(uri.fsPath)))),
    // CubeIDE regenerates it on every build there.
    buildWatcher.onDidChange(uri => fixMakefile(path.dirname(path.dirname(uri.fsPath)))),
    { dispose: () => { clearTimeout(timer); stopWatching(); flashDone?.dispose(); closeSimulator(); } },
    vscode.commands.registerCommand('stlinkAutodebug.debug', () => run('debug')),
    vscode.commands.registerCommand('stlinkAutodebug.flash', () => run('flash')),
    vscode.commands.registerCommand('stlinkAutodebug.setup', () => setUp(allProjects(), true)),
    vscode.commands.registerCommand('stlinkAutodebug.simulate', () => simulate()),
    vscode.commands.registerCommand('stlinkAutodebug.simulateRun', () => simulate(undefined, false)),
    vscode.commands.registerCommand('stlinkAutodebug.simulateDebug', () => simulate(undefined, true)),
    vscode.commands.registerCommand('stlinkAutodebug.toggleSimulatorDebug', () => setSimulatorDebug(!settings().simulatorDebug)),
    vscode.commands.registerCommand('stlinkAutodebug.simulatorDebugOn', () => setSimulatorDebug(true)),
    vscode.commands.registerCommand('stlinkAutodebug.simulatorDebugOff', () => setSimulatorDebug(false)),
    vscode.commands.registerCommand('stlinkAutodebug.stopSimulator', () => closeSimulator()),
    vscode.commands.registerCommand('stlinkAutodebug.advanceTime', () => advanceTime()),
    vscode.commands.registerCommand('stlinkAutodebug.heldStepOver', () => heldStep('stepOver')),
    vscode.commands.registerCommand('stlinkAutodebug.heldStepInto', () => heldStep('stepInto')),
    vscode.commands.registerCommand('stlinkAutodebug.heldStepOut', () => heldStep('stepOut')),
    // Whether each session's program is running or stopped, from the debug
    // protocol itself: the step keys must not send a step while one is still
    // in flight.
    vscode.debug.registerDebugAdapterTrackerFactory('cppdbg', {
      createDebugAdapterTracker(session) {
        return {
          onWillReceiveMessage(m) {
            if (m.type === 'request' && ['next', 'stepIn', 'stepOut', 'continue', 'stepBack', 'reverseContinue'].includes(m.command)) running.add(session.id);
          },
          onDidSendMessage(m) {
            if (m.type !== 'event') return;
            if (m.event === 'stopped') running.delete(session.id);
            else if (m.event === 'continued') running.add(session.id);
          },
          onExit() { running.delete(session.id); },
        };
      },
    }),
    vscode.workspace.onDidChangeConfiguration(e => {
      if (e.affectsConfiguration('stlinkAutodebug.watchUsb')) syncWatching();
      if (e.affectsConfiguration('stlinkAutodebug.simulator')) showSimStatus();
    }),
    vscode.debug.onDidStartDebugSession(s => {
      if (s.configuration.type === 'cppdbg' && / \(ST-Link\)$/.test(s.configuration.name)) sessions.set(s.id, Date.now());
    }),
    vscode.debug.onDidTerminateDebugSession(s => { simSessions.delete(s); reportOpenocd(s); }),
    vscode.debug.onDidStartDebugSession(s => { if (/ \(ACII Simulator\)$/.test(s.name)) simSessions.add(s); }),
    // A step in the simulator over code that waits for time (while (!tickPass()),
    // HAL_Delay) never ends: GDB single-steps nanoseconds of simulated time
    // per step and the wait needs milliseconds. While a step stays pending,
    // push uwTick forward through the Renode monitor, like Advance Program Time.
    vscode.debug.registerDebugAdapterTrackerFactory('cppdbg', {
      createDebugAdapterTracker(session) {
        if (!/ \(ACII Simulator\)$/.test(session.name)) return undefined;
        let pending;
        let addr; // uwTick in this session's ELF
        const stop = () => { if (pending) { clearInterval(pending.timer); clearTimeout(pending.delay); pending = undefined; } };
        const push = async () => {
          const st = settings();
          const port = renodeMonitorPort();
          addr ??= await uwTickAddress(st.gdbPath, session.configuration.program);
          if (!pending || !port || !addr) return;
          try {
            const [read] = await renodeMonitor(port, [`sysbus ReadDoubleWord ${addr}`]);
            const now = parseInt(read.match(/0x[0-9a-f]+/gi)?.pop() ?? '', 16); // after the echoed command
            if (!Number.isNaN(now) && pending) {
              await renodeMonitor(port, [`sysbus WriteDoubleWord ${addr} ${now + Math.round(st.advanceTimeMs)}`]);
              log.appendLine(`step still running: advanced uwTick by ${st.advanceTimeMs} ms`);
            }
          } catch (e) { log.appendLine(`step still running, could not advance time: ${e.message}`); }
        };
        return {
          onWillReceiveMessage(m) {
            if (m.type !== 'request' || !['next', 'stepIn', 'stepOut'].includes(m.command) || !settings().autoAdvanceSteps) return;
            stop();
            const mine = { timer: undefined, delay: undefined };
            pending = mine;
            mine.delay = setTimeout(() => {
              if (pending !== mine) return;
              mine.timer = setInterval(push, 500);
              push();
            }, 1500);
          },
          onDidSendMessage(m) {
            if (m.type === 'event' && ['stopped', 'terminated', 'exited'].includes(m.event)) stop();
          },
          onExit: stop,
        };
      },
    }),
    // Every way of starting one of our sessions (the commands, F5 on the
    // launch.json entry) passes through here, before breakpoints are sent.
    vscode.debug.registerDebugConfigurationProvider('cppdbg', {
      resolveDebugConfiguration(folder, cfg) {
        // A simulator entry started from launch.json (F5, Restart) has no
        // simulator behind it yet: start one and attach from simulate().
        if (/ \(ACII Simulator\)$/.test(cfg.name ?? '') && !simAttaching) {
          const project = allProjects().find(p => labels(p).simDebug === cfg.name);
          simulate(project, true);
          return undefined;
        }
        if (/ \((ST-Link|ACII Simulator)\)$/.test(cfg.name ?? '')) stopAtMain(settings());
        return cfg;
      },
    }),
  );

  for (const p of allProjects()) fixMakefile(p.dir);
  setUp(allProjects(), false).catch(e => log.appendLine(`setup error: ${e.message}`));
  syncWatching();
  check();
  showSimStatus();
  vscode.commands.executeCommand('setContext', 'stlinkAutodebug.active', true);

  function allProjects() {
    return (vscode.workspace.workspaceFolders ?? [])
      .flatMap(f => findIocFiles(f.uri.fsPath).map(ioc => readProject(ioc, f.uri.fsPath)));
  }

  function projectFor(ioc) {
    const folder = vscode.workspace.getWorkspaceFolder(vscode.Uri.file(ioc));
    return folder ? readProject(ioc, folder.uri.fsPath) : undefined;
  }

  // ------------------------------------------------------------ file setup

  // Offers to add what a project is missing; writes nothing unless accepted
  // (or generateFiles is "auto"). `explicit` is the Set Up command.
  async function setUp(projects, explicit) {
    const s = settings();
    if (!explicit && s.generateFiles === 'off') return;
    const declined = context.workspaceState.get('declined', []);
    for (const project of projects) {
      if (!explicit && declined.includes(project.ioc)) continue;
      const pending = await apply(project, s, false);
      if (!pending.length) {
        if (explicit) vscode.window.showInformationMessage(`${project.name} is already set up for ST-Link.`);
        continue;
      }
      if (explicit || s.generateFiles === 'ask') {
        const { text, onlyUpdates } = describeChanges(pending);
        const ok = onlyUpdates ? 'Update' : 'Set up';
        const choice = await vscode.window.showInformationMessage(
          onlyUpdates
            ? `ST-Link Auto Debug generates ${project.name}'s build/flash/debug entries differently now. ` +
              `Update the ones it wrote earlier (you haven't edited them): ${text.replace(/^update /, '')}?`
            : `${project.name} is an STM32 project without the ST-Link build/flash/debug setup. ${text[0].toUpperCase()}${text.slice(1)}?`,
          ok, ...(explicit ? [] : ["Don't ask for this project"]));
        if (choice === "Don't ask for this project") {
          await context.workspaceState.update('declined', [...declined, project.ioc]);
          log.appendLine(`${project.name}: setup declined; run "ST-Link: Set Up Project for Board Debugging" to add it later`);
        }
        if (choice !== ok) continue;
      }
      if (explicit) {
        await context.workspaceState.update('declined', declined.filter(f => f !== project.ioc));
      }
      const written = await apply(project, s, true);
      if (written.length) {
        const { text, onlyUpdates } = describeChanges(written);
        log.appendLine(`${project.name}: ${text}`);
        vscode.window.showInformationMessage(
          (onlyUpdates ? `${project.name}: updated ${text.replace(/^update /, '')}.` : `${project.name} is set up for ST-Link: ${text.replace(/\bupdate\b/, 'updated').replace(/^add/, 'added')}.`) +
          (project.build === 'none' ? ' No build system yet: build it once in STM32CubeIDE or generate it with the CMake toolchain.' : ''));
      }
      checkTools(project, s);
    }
  }

  // Works out (and with write=true, makes) the changes; returns what changes.
  async function apply(project, s, write) {
    const changes = [];
    const folderUri = vscode.Uri.file(project.folder);
    const target = targetCfg(project.family);
    const cfgFile = path.join(project.dir, 'openocd.cfg');
    if (!fs.existsSync(cfgFile)) {
      if (!target) {
        log.appendLine(`${project.name}: OpenOCD has no target configuration for ${project.family}`);
      } else {
        if (write) fs.writeFileSync(cfgFile, openocdCfg(project, target));
        changes.push({ file: path.join(project.rel, 'openocd.cfg'), newFile: true, added: ['openocd.cfg'], updated: [] });
      }
    }
    const cppFile = path.join(project.folder, '.vscode', 'c_cpp_properties.json');
    if (!fs.existsSync(cppFile)) {
      if (write) {
        fs.mkdirSync(path.dirname(cppFile), { recursive: true });
        fs.writeFileSync(cppFile, cppProperties(project));
      }
      changes.push({ file: '.vscode/c_cpp_properties.json', newFile: true, added: ['c_cpp_properties.json'], updated: [] });
    }
    const { tasks, configurations } = entries(project, s);
    const written = { ...context.workspaceState.get('written', {}) };
    for (const [section, key, version, desired, file] of [
      ['tasks', 'tasks', '2.0.0', tasks, '.vscode/tasks.json'],
      ['launch', 'configurations', '0.2.0', configurations, '.vscode/launch.json'],
    ]) {
      const cfg = vscode.workspace.getConfiguration(section, folderUri);
      const info = cfg.inspect(key);
      const current = info?.workspaceFolderValue ?? info?.workspaceValue ?? [];
      const merge = mergeEntries(current, desired, section === 'tasks' ? 'label' : 'name', written, `${project.folder}:${section}`);
      if (!merge.changed) continue;
      changes.push({ file, newFile: !Array.isArray(current) || !current.length, added: merge.added, updated: merge.updated });
      if (!write) continue;
      const v = cfg.inspect('version');
      if (!(v?.workspaceFolderValue ?? v?.workspaceValue)) {
        await cfg.update('version', version, vscode.ConfigurationTarget.WorkspaceFolder);
      }
      await cfg.update(key, merge.out, vscode.ConfigurationTarget.WorkspaceFolder);
    }
    if (write) await context.workspaceState.update('written', written);
    return changes;
  }

  function fixMakefile(dir) {
    if (path.basename(dir) === 'Debug' || !fs.existsSync(path.join(dir, 'Debug', 'makefile'))) return;
    let fixes, removed;
    try {
      fixes = fixWindowsMakefile(dir);
      removed = removeWindowsObjects(dir);
    } catch (e) {
      return void log.appendLine(`${dir}: could not fix the Windows build: ${e.message}`);
    }
    for (const f of fixes) log.appendLine(`${path.basename(dir)}: Debug/makefile: ${f}`);
    if (removed) log.appendLine(`${path.basename(dir)}: removed ${removed} objects compiled on Windows`);
    const done = [
      fixes.length ? `replaced ${fixes.length} Windows path${fixes.length > 1 ? 's' : ''} in Debug/makefile with relative ones` : '',
      removed ? `removed ${removed} object${removed > 1 ? 's' : ''} compiled there, so the next build compiles them here (and the debugger finds the sources)` : '',
    ].filter(Boolean);
    if (done.length) {
      vscode.window.showInformationMessage(`${path.basename(dir)} was built by STM32CubeIDE on Windows: ${done.join('; ')}.`);
    }
  }

  function checkTools(project, s) {
    const need = [s.openocdPath, s.gdbPath];
    if (project.build === 'make') need.push(s.makeCommand);
    if (project.build === 'cmake') need.push(s.cubeCommand);
    const absent = need.filter(c => !which(c));
    if (absent.length) vscode.window.showWarningMessage(`ST-Link setup for ${project.name}: not found on PATH: ${absent.join(', ')}.`);
  }

  // ------------------------------------------------------------ USB events

  function syncWatching() {
    stopWatching();
    if (!config().get('watchUsb')) return;
    // Device nodes appear in /dev/bus/usb/NNN on plug and vanish on unplug. On
    // Apple Silicon a port's host controller (and so /dev/bus/usb itself) only
    // exists while something is plugged in, so also watch the parents for the
    // tree appearing; every event re-syncs the watched set.
    const dirs = ['/dev', '/dev/bus', USB_DEV];
    try { for (const d of fs.readdirSync(USB_DEV)) dirs.push(path.join(USB_DEV, d)); } catch { /* no USB host yet */ }
    for (const d of dirs) {
      if (!fs.existsSync(d)) continue;
      try {
        const w = fs.watch(d, () => schedule(1000));
        w.on('error', () => schedule(1000)); // the directory went away with its controller
        watchers.push(w);
      } catch (e) {
        log.appendLine(`cannot watch ${d}: ${e.message}`);
      }
    }
  }

  function stopWatching() {
    for (const w of watchers) w.close();
    watchers = [];
  }

  // Hotplug events come in bursts, and udev grants device access shortly after
  // the node appears; wait for both to settle.
  function schedule(ms) {
    clearTimeout(timer);
    timer = setTimeout(() => { syncWatching(); check(); }, ms);
  }

  function check() {
    const probe = findStlink(ids);
    const key = probe && (probe.node ?? probe.id);
    if (key === current) return;
    current = key;
    if (!probe) {
      status.hide();
      log.appendLine('ST-Link disconnected');
      return;
    }
    log.appendLine(`ST-Link connected: ${probe.product} (${probe.id}) ${probe.node ?? ''}`);
    status.text = `$(debug-alt) ${probe.product}`;
    status.show();
    onConnect(probe).catch(e => log.appendLine(`error: ${e.message}`));
  }

  async function onConnect(probe) {
    if (!canOpen(probe.node)) {
      // udev may not have applied the access rule yet.
      await new Promise(r => setTimeout(r, 1500));
      if (!canOpen(probe.node)) return permissionWarning(probe);
    }
    const mode = config().get('onConnect');
    if (mode === 'nothing' || vscode.debug.activeDebugSession) return;
    const project = await pickProject(true);
    if (!project) return;
    if (mode !== 'ask') return run(mode, project);
    const target = project.board ?? project.mcu ?? 'board';
    let msg = `${probe.product} connected. Flash ${project.name} to the ${target}?`;
    if (project.build === 'none' && !fs.existsSync(path.join(project.dir, elfRel(project)))) {
      msg += ' No ELF found yet: build the project first.';
    } else if (project.build === 'none' && elfIsStale(project)) {
      msg += ' Its ELF is older than the sources: build first to flash your latest code.';
    }
    const choice = await vscode.window.showInformationMessage(msg, 'Flash & Debug', 'Flash only');
    if (choice === 'Flash & Debug') await run('debug', project);
    else if (choice === 'Flash only') await run('flash', project);
  }

  function permissionWarning(probe) {
    vscode.window.showWarningMessage(
      `${probe.product} found, but ${probe.node} is not accessible to your user. ` +
      'Unplug and replug it so the udev rules apply.');
  }

  async function pickProject(quiet) {
    const projects = allProjects();
    if (projects.length === 0) {
      if (!quiet) vscode.window.showWarningMessage('No STM32CubeMX project (.ioc) in this workspace.');
      return undefined;
    }
    if (projects.length === 1) return projects[0];
    const pick = await vscode.window.showQuickPick(
      projects.map(p => ({ label: p.name, description: p.board ?? p.mcu, detail: p.dir, project: p })),
      { placeHolder: 'Which STM32 project?' });
    return pick?.project;
  }

  // ------------------------------------------------------------ actions

  async function run(action, project) {
    project ??= await pickProject(false);
    if (!project) return;
    const probe = findStlink(ids);
    if (!probe) return void vscode.window.showErrorMessage('No ST-Link connected.');
    if (!canOpen(probe.node)) return permissionWarning(probe);
    const s = settings();
    const pending = await apply(project, s, false);
    if (pending.length) {
      if (s.generateFiles !== 'auto') {
        const ok = await vscode.window.showInformationMessage(
          `To flash and debug ${project.name}, ST-Link Auto Debug needs to ${describeChanges(pending).text}. OK?`, 'Set up');
        if (ok !== 'Set up') return;
      }
      await apply(project, s, true);
      checkTools(project, s);
    }
    if (!fs.existsSync(path.join(project.dir, 'openocd.cfg'))) {
      return void vscode.window.showErrorMessage(`No openocd.cfg for ${project.name}: OpenOCD has no target configuration for ${project.family ?? 'this MCU'}.`);
    }
    if (project.build === 'none' && !fs.existsSync(path.join(project.dir, elfRel(project)))) {
      return void vscode.window.showErrorMessage(`No ELF found for ${project.name}. Build the project first.`);
    }
    const folder = vscode.workspace.getWorkspaceFolder(vscode.Uri.file(project.dir));
    const l = labels(project);
    const { tasks, launch } = entries(project, s);
    log.appendLine(`${action}: ${project.name} (${project.dir})`);

    if (action === 'flash') {
      // Prefer the workspace task, so its Build dependency and any edits apply.
      const scope = folder?.uri.toString();
      const task = (await vscode.tasks.fetchTasks()).find(t => t.name === l.flash && t.scope?.uri?.toString() === scope)
        ?? inlineTask(tasks.find(t => t.label === l.flash), folder, project);
      // A failed Build dependency never starts the Flash process; drop any
      // listener left from such a run before adding this one.
      flashDone?.dispose();
      flashDone = vscode.tasks.onDidEndTaskProcess(e => {
        if (e.execution.task.name !== l.flash) return;
        flashDone.dispose();
        if (e.exitCode === 0) vscode.window.showInformationMessage(`Flashed ${project.name}; the board is running it.`);
        else vscode.window.showErrorMessage(`Flashing ${project.name} failed (exit code ${e.exitCode}). See the terminal.`);
      });
      return vscode.tasks.executeTask(task);
    }

    if (!vscode.extensions.getExtension('ms-vscode.cpptools')) {
      return void vscode.window.showErrorMessage('Debugging needs the C/C++ extension (ms-vscode.cpptools).');
    }
    const named = (vscode.workspace.getConfiguration('launch', folder?.uri).get('configurations') ?? [])
      .some(c => c && c.name === l.debug);
    await vscode.debug.startDebugging(folder, named ? l.debug : launch);
  }

  // ------------------------------------------------------------ simulator

  // A `main` function breakpoint in the Breakpoints view, so a session stops
  // at the start. Unlike a tbreak in the launch commands, the debug adapter
  // knows it (it is reported as a breakpoint, not an exception) and the user
  // sees it and can untick or remove it. One that exists, even unticked, is
  // left alone.
  function stopAtMain(s) {
    if (!s.stopAtMain) return;
    if (vscode.debug.breakpoints.some(b => b instanceof vscode.FunctionBreakpoint && b.functionName === 'main')) return;
    vscode.debug.addBreakpoints([new vscode.FunctionBreakpoint('main')]);
    log.appendLine('added a function breakpoint on main (Breakpoints view; stlinkAutodebug.stopAtMain)');
  }

  // While paused, program time stands still (the SysTick that drives the HAL
  // tick stops with the core, on the board as in the simulator), and a step
  // runs only microseconds of it. So anything timed - a debounce, a delay -
  // never happens when stepping. This adds `advanceTimeMs` to the HAL's
  // millisecond counter, as if that much time had passed.
  async function advanceTime() {
    const session = vscode.debug.activeDebugSession;
    if (session?.type !== 'cppdbg') return void vscode.window.showErrorMessage('Advance program time needs a paused C/C++ debug session.');
    const ms = Math.round(settings().advanceTimeMs);
    const frameId = vscode.debug.activeStackItem?.frameId;
    try {
      await session.customRequest('evaluate', { expression: `-exec set var uwTick = uwTick + ${ms}`, context: 'repl', frameId });
      const now = await session.customRequest('evaluate', { expression: 'uwTick', context: 'watch', frameId });
      vscode.window.setStatusBarMessage(`$(watch) Program time +${ms} ms (HAL tick now ${now.result} ms)`, 5000);
      log.appendLine(`advanced uwTick by ${ms} ms to ${now.result}`);
    } catch (e) {
      vscode.window.showErrorMessage(`Could not advance program time: ${e.message}. It needs the program paused and built with the STM32 HAL (uwTick).`);
    }
  }

  // F10/F11/Shift+F11 in our debug sessions. VS Code reports no key release,
  // but a held key repeats (about 25 times a second after a short delay), so:
  // a press steps as usual, and while the repeats keep coming, it steps at
  // most `heldStepRate` times a second, dropping repeats that arrive while the
  // last step is still running. Releasing the key ends the repeats, and so
  // the stepping.
  async function heldStep(kind) {
    const session = vscode.debug.activeDebugSession;
    if (!session || running.has(session.id)) return;
    const now = Date.now();
    if (now - lastStep < 1000 / Math.max(1, settings().heldStepRate)) return;
    lastStep = now;
    // Resolves once the adapter acknowledged the step, by which time the
    // tracker has marked the session running until its 'stopped' event.
    try {
      await vscode.commands.executeCommand(`workbench.action.debug.${kind}`);
    } catch (e) {
      log.appendLine(`${kind}: ${e.message}`);
    }
  }

  async function setSimulatorDebug(on) {
    await config().update('simulator.debug', on, vscode.ConfigurationTarget.Global);
    vscode.window.setStatusBarMessage(`ACII simulator: ${on ? 'debug (stops at your breakpoints)' : 'just run'}`, 3000);
  }

  function showSimStatus() {
    const debug = settings().simulatorDebug;
    simStatus.text = `$(${debug ? 'debug-alt' : 'play'}) ACII`;
    simStatus.tooltip = `Build and ${debug ? 'debug' : 'run'} in the ACII simulator`;
    simDebugStatus.text = `$(${debug ? 'pass-filled' : 'circle-large-outline'}) Debug`;
    simDebugStatus.tooltip = `Debug in the ACII simulator: ${debug ? 'on (stops at your breakpoints)' : 'off (just runs)'}. Click to toggle.`;
    simStatus.show();
    simDebugStatus.show();
  }

  // Builds the project, then runs it in the ACII simulator, or debugs it there
  // (`debug` defaults to the stlinkAutodebug.simulator.debug checkbox). The
  // simulator panel opens if it is not open yet and is reused afterwards.
  async function simulate(project, debug) {
    if (simBusy) return void vscode.window.showInformationMessage('The ACII simulator is already starting.');
    project ??= await pickProject(false);
    if (!project) return;
    const s = settings();
    debug ??= s.simulatorDebug;
    const script = findSimulator(s.simulatorPath);
    if (!script) {
      const choice = await vscode.window.showErrorMessage(
        'ACII simulator not found. Set stlinkAutodebug.simulator.path to its simulador-acii.sh (in the Panel_py folder).',
        'Open Settings');
      if (choice) vscode.commands.executeCommand('workbench.action.openSettings', 'stlinkAutodebug.simulator.path');
      return;
    }
    if (debug && !vscode.extensions.getExtension('ms-vscode.cpptools')) {
      return void vscode.window.showErrorMessage('Debugging needs the C/C++ extension (ms-vscode.cpptools).');
    }
    simBusy = true;
    try {
      // A debug session still attached to the old simulator would lose its
      // target when the simulator restarts.
      for (const session of [vscode.debug.activeDebugSession].filter(Boolean)) {
        if (/ \(ACII Simulator\)$/.test(session.name)) await vscode.debug.stopDebugging(session);
      }
      fixMakefile(project.dir);
      if (project.build !== 'none' && !(await build(project, s))) return;
      const elf = path.join(project.dir, elfRel(project));
      if (!fs.existsSync(elf)) {
        return void vscode.window.showErrorMessage(`No ELF found for ${project.name} (${elf}). Build the project first.`);
      }
      if (project.build === 'none' && elfIsStale(project)) {
        vscode.window.showWarningMessage(`${project.name}'s ELF is older than its sources and it has no build system here: running the old build.`);
      }
      log.appendLine(`simulator ${debug ? 'debug' : 'run'}: ${elf}`);
      const started = startSimulator(script);
      const ready = waitForSim(debug ? 'gdb' : 'conectado');
      sim.proc.stdin.write(JSON.stringify({ orden: 'arranca', elf, esperar: debug }) + '\n');
      await vscode.window.withProgress({
        location: vscode.ProgressLocation.Notification,
        title: `${started ? 'Opening' : 'Restarting'} the ACII simulator with ${project.name}…`,
      }, () => ready);
      if (!debug) return;
      // The simulator is up: a run may restart it from here on, even while
      // VS Code is still starting the debug session.
      simBusy = false;
      const folder = vscode.workspace.getWorkspaceFolder(vscode.Uri.file(project.dir));
      simAttaching = true;
      try {
        await vscode.debug.startDebugging(folder, simulatorLaunch(project, elf, s));
      } finally {
        simAttaching = false;
      }
    } catch (e) {
      vscode.window.showErrorMessage(`ACII simulator: ${e.message}`, 'Show log').then(c => { if (c) log.show(); });
    } finally {
      simBusy = false;
    }
  }

  // Runs the project's Build task; resolves to whether it succeeded.
  async function build(project, s) {
    const folder = vscode.workspace.getWorkspaceFolder(vscode.Uri.file(project.dir));
    const l = labels(project);
    const scope = folder?.uri.toString();
    const task = (await vscode.tasks.fetchTasks()).find(t => t.name === l.build && t.scope?.uri?.toString() === scope)
      ?? inlineTask(entries(project, s).tasks.find(t => t.label === l.build), folder, project);
    let execution;
    const ended = new Promise(resolve => {
      const done = vscode.tasks.onDidEndTaskProcess(e => {
        if (e.execution !== execution && e.execution.task.name !== task.name) return;
        done.dispose();
        resolve(e.exitCode);
      });
    });
    execution = await vscode.tasks.executeTask(task);
    const code = await ended;
    if (code !== 0) vscode.window.showErrorMessage(`Building ${project.name} failed (exit code ${code}). See the terminal.`);
    return code === 0;
  }

  // Starts the simulator panel unless ours is still open; true if started.
  // It is driven over stdin (--ordenes) and reports "@event detail" lines.
  function startSimulator(script) {
    if (sim && sim.proc.exitCode === null && !sim.proc.killed) return false;
    const [cmd, args] = script.endsWith('.py') ? ['python3', [script]] : [script, []];
    const proc = spawn(cmd, [...args, '--ordenes'], { cwd: path.dirname(script), stdio: ['pipe', 'pipe', 'pipe'] });
    const current = { proc, listeners: new Set() };
    sim = current;
    log.appendLine(`simulator: started ${script} (pid ${proc.pid})`);
    let buffered = '';
    proc.stdout.on('data', chunk => {
      const lines = (buffered + chunk).split('\n');
      buffered = lines.pop();
      for (const line of lines.filter(Boolean)) {
        log.appendLine(`simulator: ${line}`);
        const m = /^@(\S+)\s*(.*)$/.exec(line);
        if (m) for (const l of current.listeners) l(m[1], m[2]);
      }
    });
    proc.stderr.on('data', chunk => log.append(`simulator: ${chunk}`));
    proc.stdin.on('error', () => { /* the panel was closed */ });
    const gone = (why) => {
      log.appendLine(`simulator: panel ${why}`);
      for (const l of current.listeners) l('cerrado', why);
      if (sim === current) sim = undefined;
      // The simulator is the debug target: with it gone, the session has
      // nothing to talk to, so end it instead of leaving it hanging.
      for (const session of [...simSessions]) vscode.debug.stopDebugging(session);
    };
    proc.on('error', e => gone(`could not start: ${e.message}`));
    proc.on('exit', code => gone(`closed (exit code ${code})`));
    return true;
  }

  // Resolves when the simulator reports `event`; rejects on a failure.
  function waitForSim(event) {
    const current = sim;
    return new Promise((resolve, reject) => {
      const finish = (fn, v) => { clearTimeout(t); current.listeners.delete(listener); fn(v); };
      const t = setTimeout(() => finish(reject, new Error('the simulator did not start in time')), SIM_START_TIMEOUT);
      const listener = (name, detail) => {
        if (name === event) finish(resolve);
        else if (name === 'fallo') finish(reject, new Error(detail || 'the simulator could not start'));
        else if (name === 'cerrado') finish(reject, new Error(`the simulator panel ${detail || 'was closed'}`));
      };
      current.listeners.add(listener);
    });
  }

  function closeSimulator() {
    if (!sim) return;
    try { sim.proc.stdin.write(JSON.stringify({ orden: 'cierra' }) + '\n'); } catch { /* already gone */ }
  }

  // VS Code closing or the extension reloading: ask the panel to close (it
  // stops Renode too) and wait for it. Killing the panel instead would leave
  // Renode running, since it lives in its own session.
  stopSimulatorOnExit = () => {
    const current = sim;
    if (!current || current.proc.exitCode !== null) return Promise.resolve();
    return new Promise(resolve => {
      const t = setTimeout(resolve, 8000);
      current.proc.once('exit', () => { clearTimeout(t); resolve(); });
      closeSimulator();
    });
  };

  // A task from a generated entry, for when tasks.json generation is off.
  function inlineTask(entry, folder, project) {
    const resolve = v => v.split('${workspaceFolder}').join(project.folder);
    return new vscode.Task({ type: 'process' }, folder ?? vscode.TaskScope.Workspace, entry.label, 'ST-Link',
      new vscode.ProcessExecution(entry.command, entry.args.map(resolve), { cwd: resolve(entry.options.cwd) }), []);
  }

  // OpenOCD is silent in pipe mode; surface its errors when a session fails.
  function reportOpenocd(session) {
    const started = sessions.get(session.id);
    sessions.delete(session.id);
    if (!started || !session.workspaceFolder) return;
    const file = path.join(session.workspaceFolder.uri.fsPath, OPENOCD_LOG);
    let text;
    try {
      if (fs.statSync(file).mtimeMs < started - 1000) return;
      text = fs.readFileSync(file, 'utf8');
    } catch { return; }
    const errors = text.split('\n').filter(l => l.startsWith('Error:'));
    if (!errors.length) return;
    let hint = '';
    if (errors.some(e => /open failed|unable to open|LIBUSB_ERROR/i.test(e))) {
      hint = ' Is the ST-Link connected and not used by another program?';
    } else if (errors.some(e => /target voltage|init mode failed|unable to connect/i.test(e))) {
      hint = ' Check that the board is powered and the SWD wiring/jumpers are in place.';
    }
    vscode.window.showErrorMessage(`OpenOCD: ${errors[0].replace(/^Error:\s*/, '')}.${hint}`, 'Open log').then(c => {
      if (c) vscode.window.showTextDocument(vscode.Uri.file(file));
    });
  }
}

function deactivate() { return stopSimulatorOnExit?.(); }

module.exports = {
  activate,
  deactivate,
  _test: { stlinkIds, findStlink, findIocFiles, readProject, targetCfg, elfRel, elfIsStale, entries, openocdCfg, mergeEntries, describeChanges, fixWindowsMakefile, removeWindowsObjects, findSimulator, simulatorLaunch, renodeMonitorPort, renodeMonitor, uwTickAddress },
};
