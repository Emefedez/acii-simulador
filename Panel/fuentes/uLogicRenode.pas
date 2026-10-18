unit uLogicRenode;

{ Arrancar y parar el emulador, sin nada de interfaz.

  Esto es lo que antes hacia un guion de Python al lado del panel. Meterlo
  aqui quita esa dependencia: el paquete ya solo necesita Renode.

  Lo que hay que hacer para que Renode ejecute un programa no es evidente, y
  son cinco pasos:

    1. Dejar los modelos, la plataforma y el .elf en una carpeta SIN ESPACIOS.
       Renode no sabe interpretar `include @` con espacios en la ruta, y no
       avisa: arranca y se queda parado.
    2. Escribir el guion .resc que carga todo eso.
    3. Lanzar Renode con el monitor en un puerto. SIN --port se cierra solo:
       el monitor lee fin de fichero en la entrada estandar y sale, y en el
       registro aparece "Machine paused" una decima de segundo despues de
       arrancar.
    4. Esperar a que el modulo abra su socket. La primera vez tarda, porque
       Renode compila los cuatro modelos en C#.
    5. Conectarse. De eso se encarga el formulario.
}

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.IOUtils,
  System.Types,
  IdTCPClient;

const
  { La carpeta donde se le deja a Renode todo lo que tiene que leer.
    Sin espacios y sin tildes, por lo dicho arriba. }
  CARPETA_TRABAJO = 'C:\ACII_sim';

  PUERTO_MODULO  = 3939;    { el display, al que se conecta este panel }
  PUERTO_MONITOR = 1234;    { el monitor de Renode }
  PUERTO_GDB     = 3333;    { el servidor GDB, al que se conecta CubeIDE }

  { Cuanto se espera como mucho a que arranque. La primera vez compila los
    modelos y puede pasar del minuto; despues son segundos. }
  ESPERA_MAXIMA_MS = 150000;

type
  TEmulador = record
    Proceso: THandle;
    Id: Cardinal;
    Registro: string;       { donde ha quedado la salida de Renode }
  end;

{ Donde esta instalado Renode. Cadena vacia si no aparece. }
function BuscaRenode: string;

{ La carpeta con los modelos y la plataforma. Al lado del ejecutable en
  el paquete que se entrega -..\plataforma-, y un nivel por encima en el
  archivo de la asignatura. Cadena vacia si falta. }
function BuscaPlataforma: string;

{ El programa de ejemplo que acompania al paquete, si esta. }
function BuscaEjemplo: string;

{ Copia lo que hace falta a la carpeta de trabajo y escribe el guion.
  Devuelve la ruta del guion, o cadena vacia y el motivo en Error. }
function PreparaEjecucion(const Elf: string; Esperar: Boolean;
                          out Error: string): string;

function ArrancaEmulador(const Renode, Guion: string; var Emu: TEmulador;
                         out Error: string): Boolean;
procedure ParaEmulador(var Emu: TEmulador);
function EmuladorVivo(const Emu: TEmulador): Boolean;

{ True si alguien escucha en ese puerto de la maquina local. }
function PuertoAbierto(Puerto: Integer): Boolean;

{ Lo ultimo que dijo Renode, para ensenarlo cuando algo falla. }
function UltimasLineas(const Fichero: string; Cuantas: Integer): string;

{ Deja en el proyecto la configuracion de depuracion de STM32CubeIDE, si no
  la tiene ya. Devuelve el nombre creado, o cadena vacia si ya existia o si
  no se pudo -y entonces Error dice por que-. }
function CreaConfiguracionCubeIDE(const Elf: string; out Error: string): string;

implementation

const
  { El SVD va junto al .repl, que lo carga por ruta relativa: sin el,
    Renode lo descargaria de internet al montar la placa. }
  PIEZAS: array[0..5] of string = (
    'PuertoGPIO.cs',
    'TemporizadorSTM32.cs',
    'PotenciometroADC.cs',
    'TM1638Panel.cs',
    'nucleo_f401re.repl',
    'STM32F40x.svd.gz');

  { OJO CON LOS NOMBRES: Delphi no distingue mayusculas, asi que una
    constante ARRANQUE y una variable local Arranque serian el MISMO
    identificador, y dentro de la funcion ganaria la variable. Paso una vez:
    el guion salia sin las ordenes de arranque. Por eso van aqui dentro. }
  GUION =
    ':name: ACII simulador'#13#10 +
    'using sysbus'#13#10 +
    'include @%0:s/PuertoGPIO.cs'#13#10 +
    'include @%0:s/TemporizadorSTM32.cs'#13#10 +
    'include @%0:s/PotenciometroADC.cs'#13#10 +
    'include @%0:s/TM1638Panel.cs'#13#10 +
    'mach create "ACII"'#13#10 +
    'machine LoadPlatformDescription @%0:s/nucleo_f401re.repl'#13#10 +
    'sysbus LoadELF @%0:s/%1:s'#13#10 +
    '%2:s';

  { Ejecutar y ya. El servidor GDB se levanta igualmente: no cuesta nada, y
    quien quiera depurar a media ejecucion solo tiene que conectarse -al
    hacerlo, el depurador detiene el programa el mismo-. }
  FINAL_NORMAL =
    'machine StartGdbServer %0:d'#13#10 +
    'start'#13#10;

  { Esperar al depurador, con NADA ejecutado.
  
    `IsHalted true` congela el procesador antes de que corra una sola
    instruccion, y como Renode solo fija el PC al arrancar, hay que ponerselo
    a mano: el punto de entrada sale del propio ELF.
  
    Sin `start`: el tiempo de la emulacion lo arranca el depurador con
    `monitor start`, y suelta el procesador con
    `monitor sysbus.cpu IsHalted false`. Esas dos ordenes van en la caja
    «Run Commands» de STM32CubeIDE, que se ejecuta DESPUES de poner los
    puntos de ruptura. Asi uno en la primera linea de main SI se cumple.
  
    Medido: al conectar, PC en Reset_Handler y cero instrucciones. }
  FINAL_ESPERANDO =
    'sysbus.cpu IsHalted true'#13#10 +
    'sysbus.cpu PC 0x%1:x'#13#10 +
    'machine StartGdbServer %0:d'#13#10;

{ El punto de entrada del programa, del encabezado del propio ELF: cuatro
  bytes en el desplazamiento 24, en orden de byte bajo primero. Ya trae
  puesto el bit de Thumb, que es lo que espera el Cortex-M. }
function PuntoDeEntrada(const Elf: string): Cardinal;
var
  F: TFileStream;
begin
  Result := 0;
  try
    F := TFileStream.Create(Elf, fmOpenRead or fmShareDenyNone);
    try
      if F.Size < 28 then Exit;
      F.Position := 24;
      F.ReadBuffer(Result, SizeOf(Result));
    finally
      F.Free;
    end;
  except
    Result := 0;
  end;
end;

function DirDelPrograma: string;
begin
  Result := IncludeTrailingPathDelimiter(
              ExtractFilePath(ParamStr(0)));
end;

function BuscaRenode: string;
const
  CANDIDATOS: array[0..1] of string = (
    'C:\Program Files\Renode\Renode.exe',
    'C:\Program Files (x86)\Renode\Renode.exe');
var
  i: Integer;
  Propio: string;
begin
  { PRIMERO EL QUE VIENE CON EL SIMULADOR, en ..\Renode\: la 1.16.1, que es la
    probada. El instalado va despues y solo para el archivo de la asignatura,
    que no lo lleva: con otra version -un alumno tenia la 1.17- Renode se
    quedaba colgado al montar la placa, y nada lo explicaba. }
  Propio := TPath.GetFullPath(DirDelPrograma + '..\Renode\renode.exe');
  if FileExists(Propio) then
    Exit(Propio);
  for i := Low(CANDIDATOS) to High(CANDIDATOS) do
    if FileExists(CANDIDATOS[i]) then
      Exit(CANDIDATOS[i]);
  Result := '';
end;

function BuscaPlataforma: string;
var
  Candidato: string;
begin
  { En el paquete que se entrega: Panel\PanelACII.exe y ..\plataforma\ }
  Candidato := TPath.GetFullPath(DirDelPrograma + '..\plataforma\');
  if FileExists(Candidato + 'nucleo_f401re.repl') then
    Exit(IncludeTrailingPathDelimiter(Candidato));

  { En el archivo de la asignatura: Panel\PanelACII.exe y los .cs un nivel
    por encima, sueltos. }
  Candidato := TPath.GetFullPath(DirDelPrograma + '..\');
  if FileExists(Candidato + 'nucleo_f401re.repl') then
    Exit(IncludeTrailingPathDelimiter(Candidato));

  Result := '';
end;

function BuscaEjemplo: string;
var
  Candidato: string;
begin
  Candidato := TPath.GetFullPath(DirDelPrograma + '..\ejemplo\Garaje.elf');
  if FileExists(Candidato) then Exit(Candidato);
  Candidato := TPath.GetFullPath(DirDelPrograma + '..\Garaje.elf');
  if FileExists(Candidato) then Exit(Candidato);
  Result := '';
end;

function PreparaEjecucion(const Elf: string; Esperar: Boolean;
                          out Error: string): string;
var
  Plataforma, Trabajo, NombreElf, Texto, Cierre: string;
  i: Integer;
  Fichero: TStringList;
begin
  Result := '';
  Error := '';

  if not FileExists(Elf) then
  begin
    Error := 'No existe el programa: ' + Elf;
    Exit;
  end;

  Plataforma := BuscaPlataforma;
  if Plataforma = '' then
  begin
    Error := 'No encuentro la carpeta «plataforma» con los modelos del ' +
             'simulador. Tiene que estar al lado de la del panel.';
    Exit;
  end;

  Trabajo := IncludeTrailingPathDelimiter(CARPETA_TRABAJO);
  try
    if not TDirectory.Exists(Trabajo) then
      TDirectory.CreateDirectory(Trabajo);

    for i := Low(PIEZAS) to High(PIEZAS) do
    begin
      if not FileExists(Plataforma + PIEZAS[i]) then
      begin
        Error := 'Falta una pieza del simulador: ' + PIEZAS[i];
        Exit;
      end;
      TFile.Copy(Plataforma + PIEZAS[i], Trabajo + PIEZAS[i], True);
    end;

    NombreElf := ExtractFileName(Elf);
    TFile.Copy(Elf, Trabajo + NombreElf, True);
  except
    on E: Exception do
    begin
      Error := 'No he podido preparar ' + CARPETA_TRABAJO + ': ' + E.Message;
      Exit;
    end;
  end;

  if Esperar then
    Cierre := Format(FINAL_ESPERANDO, [PUERTO_GDB, PuntoDeEntrada(Elf)])
  else
    Cierre := Format(FINAL_NORMAL, [PUERTO_GDB]);

  { Renode quiere barras normales en las rutas de `include`. }
  Texto := Format(GUION, [StringReplace(ExcludeTrailingPathDelimiter(Trabajo),
                                        '\', '/', [rfReplaceAll]),
                          NombreElf, Cierre]);

  Fichero := TStringList.Create;
  try
    Fichero.Text := Texto;
    try
      Fichero.SaveToFile(Trabajo + 'simula.resc', TEncoding.ASCII);
    except
      on E: Exception do
      begin
        Error := 'No he podido escribir el guion: ' + E.Message;
        Exit;
      end;
    end;
  finally
    Fichero.Free;
  end;

  Result := Trabajo + 'simula.resc';
end;

function ArrancaEmulador(const Renode, Guion: string; var Emu: TEmulador;
                         out Error: string): Boolean;
var
  Inicio: TStartupInfo;
  Info: TProcessInformation;
  Orden: string;
  Seguridad: TSecurityAttributes;
  hLog: THandle;
begin
  Result := False;
  Error := '';
  Emu.Proceso := 0;
  Emu.Id := 0;
  Emu.Registro := IncludeTrailingPathDelimiter(CARPETA_TRABAJO) + 'renode.log';

  { La salida de Renode a un fichero: cuando algo falla, ahi esta el motivo,
    y si no se recoge no queda ningun rastro. El manejador tiene que ser
    heredable para que el hijo pueda escribir en el. }
  Seguridad.nLength := SizeOf(Seguridad);
  Seguridad.lpSecurityDescriptor := nil;
  Seguridad.bInheritHandle := True;
  hLog := CreateFile(PChar(Emu.Registro), GENERIC_WRITE,
                     FILE_SHARE_READ or FILE_SHARE_WRITE, @Seguridad,
                     CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);

  FillChar(Inicio, SizeOf(Inicio), 0);
  Inicio.cb := SizeOf(Inicio);
  Inicio.dwFlags := STARTF_USESHOWWINDOW;
  Inicio.wShowWindow := SW_HIDE;
  if hLog <> INVALID_HANDLE_VALUE then
  begin
    Inicio.dwFlags := Inicio.dwFlags or STARTF_USESTDHANDLES;
    Inicio.hStdOutput := hLog;
    Inicio.hStdError := hLog;
    Inicio.hStdInput := 0;
  end;

  Orden := Format('"%s" --disable-xwt --port %d "%s"',
                  [Renode, PUERTO_MONITOR,
                   StringReplace(Guion, '\', '/', [rfReplaceAll])]);

  if CreateProcess(nil, PChar(Orden), nil, nil, hLog <> INVALID_HANDLE_VALUE,
                   CREATE_NO_WINDOW, nil, nil, Inicio, Info) then
  begin
    CloseHandle(Info.hThread);
    Emu.Proceso := Info.hProcess;
    Emu.Id := Info.dwProcessId;
    Result := True;
  end
  else
    Error := 'No he podido arrancar Renode: ' + SysErrorMessage(GetLastError);

  if hLog <> INVALID_HANDLE_VALUE then
    CloseHandle(hLog);
end;

function EmuladorVivo(const Emu: TEmulador): Boolean;
var
  Codigo: Cardinal;
begin
  Result := (Emu.Proceso <> 0) and
            GetExitCodeProcess(Emu.Proceso, Codigo) and
            (Codigo = STILL_ACTIVE);
end;

procedure ParaEmulador(var Emu: TEmulador);
begin
  if Emu.Proceso = 0 then Exit;
  if EmuladorVivo(Emu) then
  begin
    TerminateProcess(Emu.Proceso, 0);
    { Esperar a que muera de verdad. Hasta que Windows no lo entierra sigue
      escuchando en sus puertos, y arrancar otro a continuacion falla con
      «ya hay un simulador corriendo». }
    WaitForSingleObject(Emu.Proceso, 5000);
  end;
  CloseHandle(Emu.Proceso);
  Emu.Proceso := 0;
  Emu.Id := 0;
end;

function PuertoAbierto(Puerto: Integer): Boolean;
var
  C: TIdTCPClient;
begin
  Result := False;
  C := TIdTCPClient.Create(nil);
  try
    C.Host := '127.0.0.1';
    C.Port := Puerto;
    C.ConnectTimeout := 400;
    try
      C.Connect;
      Result := True;
      C.Disconnect;
    except
      { cerrado: no es un error, es la respuesta }
    end;
  finally
    C.Free;
  end;
end;

{ ------------------------------- la configuracion de STM32CubeIDE --- }

{ Se escribe DENTRO del proyecto y no en el espacio de trabajo, por dos
  razones: el panel no tiene forma de saber que espacio de trabajo usa
  CubeIDE, y una configuracion guardada en el proyecto viaja con el. Eclipse
  las llama «compartidas» y las encuentra sola: aparecen en
  Run > Debug Configurations, bajo GDB Hardware Debugging.

  Las dos ordenes de runCommands son las que arrancan el emulador y sueltan
  el procesador. Sin ellas, con el panel esperando, el depurador se cuelga. }
const
  PLANTILLA_LAUNCH =
    '<?xml version="1.0" encoding="UTF-8" standalone="no"?>'#13#10 +
    '<launchConfiguration type="org.eclipse.cdt.debug.gdbjtag.launchConfigurationType">'#13#10 +
    '    <stringAttribute key="org.eclipse.cdt.debug.gdbjtag.core.connection" value="gdb:localhost:%2:d#"/>'#13#10 +
    '    <intAttribute key="org.eclipse.cdt.debug.gdbjtag.core.delay" value="0"/>'#13#10 +
    '    <booleanAttribute key="org.eclipse.cdt.debug.gdbjtag.core.doHalt" value="false"/>'#13#10 +
    '    <booleanAttribute key="org.eclipse.cdt.debug.gdbjtag.core.doReset" value="false"/>'#13#10 +
    '    <stringAttribute key="org.eclipse.cdt.debug.gdbjtag.core.initCommands" value=""/>'#13#10 +
    '    <stringAttribute key="org.eclipse.cdt.debug.gdbjtag.core.jtagDeviceId" value="org.eclipse.cdt.debug.gdbjtag.core.jtagdevice.genericDevice"/>'#13#10 +
    '    <booleanAttribute key="org.eclipse.cdt.debug.gdbjtag.core.loadImage" value="false"/>'#13#10 +
    '    <booleanAttribute key="org.eclipse.cdt.debug.gdbjtag.core.loadSymbols" value="true"/>'#13#10 +
    '    <stringAttribute key="org.eclipse.cdt.debug.gdbjtag.core.protocol" value="remote"/>'#13#10 +
    '    <stringAttribute key="org.eclipse.cdt.debug.gdbjtag.core.runCommands" value="monitor start&#13;&#10;monitor sysbus.cpu IsHalted false"/>'#13#10 +
    '    <booleanAttribute key="org.eclipse.cdt.debug.gdbjtag.core.setPcRegister" value="false"/>'#13#10 +
    '    <booleanAttribute key="org.eclipse.cdt.debug.gdbjtag.core.setResume" value="true"/>'#13#10 +
    '    <booleanAttribute key="org.eclipse.cdt.debug.gdbjtag.core.setStopAt" value="true"/>'#13#10 +
    '    <stringAttribute key="org.eclipse.cdt.debug.gdbjtag.core.stopAt" value="main"/>'#13#10 +
    '    <booleanAttribute key="org.eclipse.cdt.debug.gdbjtag.core.useFileForImage" value="false"/>'#13#10 +
    '    <booleanAttribute key="org.eclipse.cdt.debug.gdbjtag.core.useFileForSymbols" value="false"/>'#13#10 +
    '    <booleanAttribute key="org.eclipse.cdt.debug.gdbjtag.core.useProjBinaryForImage" value="true"/>'#13#10 +
    '    <booleanAttribute key="org.eclipse.cdt.debug.gdbjtag.core.useProjBinaryForSymbols" value="true"/>'#13#10 +
    '    <booleanAttribute key="org.eclipse.cdt.debug.gdbjtag.core.useRemoteTarget" value="true"/>'#13#10 +
    '    <stringAttribute key="org.eclipse.cdt.dsf.gdb.DEBUG_NAME" value="%3:s"/>'#13#10 +
    '    <intAttribute key="org.eclipse.cdt.launch.ATTR_BUILD_BEFORE_LAUNCH_ATTR" value="2"/>'#13#10 +
    '    <stringAttribute key="org.eclipse.cdt.launch.DEBUGGER_START_MODE" value="remote"/>'#13#10 +
    '    <stringAttribute key="org.eclipse.cdt.launch.PROGRAM_NAME" value="Debug/%1:s"/>'#13#10 +
    '    <stringAttribute key="org.eclipse.cdt.launch.PROJECT_ATTR" value="%0:s"/>'#13#10 +
    '    <booleanAttribute key="org.eclipse.cdt.launch.PROJECT_BUILD_CONFIG_AUTO_ATTR" value="false"/>'#13#10 +
    '    <listAttribute key="org.eclipse.debug.core.MAPPED_RESOURCE_PATHS">'#13#10 +
    '        <listEntry value="/%0:s"/>'#13#10 +
    '    </listAttribute>'#13#10 +
    '    <listAttribute key="org.eclipse.debug.core.MAPPED_RESOURCE_TYPES">'#13#10 +
    '        <listEntry value="4"/>'#13#10 +
    '    </listAttribute>'#13#10 +
    { Favorita del grupo de depuracion: sale arriba del desplegable de la
      mosca, por delante del historial. Sin esto hay que lanzarla una vez
      desde Debug Configurations para que aparezca siquiera. }
    '    <listAttribute key="org.eclipse.debug.ui.favoriteGroups">'#13#10 +
    '        <listEntry value="org.eclipse.debug.ui.launchGroup.debug"/>'#13#10 +
    '    </listAttribute>'#13#10 +
    '    <stringAttribute key="process_factory_id" value="org.eclipse.cdt.dsf.gdb.GdbProcessFactory"/>'#13#10 +
    '</launchConfiguration>'#13#10;

  { Eclipse llama a la configuracion como se llame el fichero, y las lista
    todas juntas: si todos los proyectos la llaman igual, salen tres
    «Simulador ACII» indistinguibles. Por eso lleva el nombre del proyecto. }
  NOMBRE_LAUNCH = 'Simulador ACII - %s.launch';

  { Como se llamaban antes de que llevaran el nombre del proyecto. Se mira
    para no dejar dos configuraciones iguales en el mismo proyecto. }
  NOMBRE_LAUNCH_VIEJO = 'Simulador ACII.launch';

{ El gdb que trae STM32CubeIDE. Vive en una carpeta de complemento cuyo
  nombre lleva la version, asi que hay que buscarlo. }
function BuscaGdb: string;
var
  Raices, Complementos: TStringDynArray;
  Raiz, Carpeta, Candidato: string;
begin
  Result := 'arm-none-eabi-gdb';        { por si estuviera en el PATH }
  try
    if not TDirectory.Exists('C:\ST') then Exit;
    Raices := TDirectory.GetDirectories('C:\ST', 'STM32CubeIDE*');
    for Raiz in Raices do
    begin
      Carpeta := Raiz + '\STM32CubeIDE\plugins';
      if not TDirectory.Exists(Carpeta) then Continue;
      Complementos := TDirectory.GetDirectories(Carpeta, '*gnu-tools-for-stm32*');
      for Candidato in Complementos do
        if FileExists(Candidato + '\tools\bin\arm-none-eabi-gdb.exe') then
          Exit(Candidato + '\tools\bin\arm-none-eabi-gdb.exe');
    end;
  except
    { si algo falla se queda el nombre a secas }
  end;
end;

{ La raiz del proyecto a partir del .elf: <raiz>\Debug\loquesea.elf }
function RaizDelProyecto(const Elf: string): string;
var
  Carpeta: string;
begin
  Carpeta := ExcludeTrailingPathDelimiter(ExtractFilePath(Elf));
  if SameText(ExtractFileName(Carpeta), 'Debug') or
     SameText(ExtractFileName(Carpeta), 'Release') then
    Result := IncludeTrailingPathDelimiter(ExtractFilePath(Carpeta))
  else
    Result := IncludeTrailingPathDelimiter(Carpeta);
end;

{ El nombre del proyecto, del .project de Eclipse. }
function NombreDelProyecto(const Raiz: string): string;
var
  Texto: string;
  a, b: Integer;
begin
  Result := '';
  if not FileExists(Raiz + '.project') then Exit;
  try
    Texto := TFile.ReadAllText(Raiz + '.project');
  except
    Exit;
  end;
  a := Pos('<name>', Texto);
  b := Pos('</name>', Texto);
  if (a > 0) and (b > a) then
    Result := Trim(Copy(Texto, a + 6, b - a - 6));
end;

function CreaConfiguracionCubeIDE(const Elf: string; out Error: string): string;
var
  Raiz, Proyecto, Nombre, Destino, Texto: string;
begin
  Result := '';
  Error := '';

  Raiz := RaizDelProyecto(Elf);
  Proyecto := NombreDelProyecto(Raiz);
  if Proyecto = '' then
  begin
    Error := 'no parece un proyecto de STM32CubeIDE';
    Exit;
  end;

  Nombre := Format(NOMBRE_LAUNCH, [Proyecto]);
  Destino := Raiz + Nombre;
  if FileExists(Destino) or FileExists(Raiz + NOMBRE_LAUNCH_VIEJO) then
    Exit;                                { ya la tiene: no se toca }

  Texto := Format(PLANTILLA_LAUNCH,
                  [Proyecto, ExtractFileName(Elf), PUERTO_GDB, BuscaGdb]);
  try
    { Sin marca de orden de bytes: los .launch que escribe Eclipse no la
      llevan, y TFile.WriteAllText la pondria. }
    TFile.WriteAllBytes(Destino, TEncoding.UTF8.GetBytes(Texto));
  except
    on E: Exception do
    begin
      Error := E.Message;
      Exit;
    end;
  end;
  Result := Nombre;
end;

function UltimasLineas(const Fichero: string; Cuantas: Integer): string;
var
  L: TStringList;
  i, desde: Integer;
begin
  Result := '';
  if not FileExists(Fichero) then Exit;
  L := TStringList.Create;
  try
    try
      L.LoadFromFile(Fichero);
    except
      Exit;
    end;
    desde := L.Count - Cuantas;
    if desde < 0 then desde := 0;
    for i := desde to L.Count - 1 do
      Result := Result + L[i] + sLineBreak;
  finally
    L.Free;
  end;
end;

end.
