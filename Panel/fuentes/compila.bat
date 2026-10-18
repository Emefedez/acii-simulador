@echo off
rem Compila el panel desde linea de ordenes, sin abrir el IDE.
rem
rem Se prueban las versiones de Studio de mas nueva a mas vieja: no todas las
rem instalaciones traen los recursos de Win32, y hace falta una que si.
rem
rem OJO con el SET entrecomillado de dentro del FOR: sin las comillas, el
rem "(x86)" de la ruta cierra el bloque y cmd falla con "No se esperaba
rem \Embarcadero\Studio\%V en este momento".

setlocal
set "BDS="
for %%V in (37.0 23.0 22.0 21.0) do (
  if not defined BDS if exist "C:\Program Files (x86)\Embarcadero\Studio\%%V\bin\dcc32.exe" (
    set "BDS=C:\Program Files (x86)\Embarcadero\Studio\%%V"
  )
)

if not defined BDS (
  echo No encuentro Delphi instalado.
  exit /b 1
)

set "LIB=%BDS%\lib\win32\release"
if not exist "%LIB%\System.dcu" set "LIB=%BDS%\lib\win32\debug"

echo Compilando con %BDS%
"%BDS%\bin\dcc32.exe" -B -Q -U"%LIB%" PanelACII.dpr
if errorlevel 1 (
  echo.
  echo FALLO la compilacion
  exit /b 1
)
echo.
echo PanelACII.exe listo
