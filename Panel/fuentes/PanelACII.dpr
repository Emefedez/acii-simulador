program PanelACII;

{ El modulo LED&KEY del simulador, en pantalla.

  Se compila desde linea de ordenes con compila.bat, o se abre en el IDE.
  No lleva .dfm a proposito: la ventana se monta en codigo. }

uses
  Vcl.Forms,
  uPanel in 'uPanel.pas',
  uLogicPanel in 'uLogicPanel.pas',
  uLogicRenode in 'uLogicRenode.pas',
  uControles in 'uControles.pas';

{ El icono del programa: sale en la barra de titulo, en la barra de tareas y
  en el Explorador. El recurso ya viene compilado -PanelACII.res- porque
  brcc32, el compilador de recursos de Delphi, es de 1999 y falla con
  «Allocate failed» ante un icono de 32 bits con transparencia. Si hay que
  rehacerlo:

    rc.exe /fo PanelACII.res PanelACII.rc      (Windows SDK)

  El .ico sale de logo_ac.png, el mismo emblema que llevan los documentos. }
{$R PanelACII.res}



var
  Panel: TFormPanel;

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.Title := 'ACII · Módulo LED&KEY';

  { CreateForm y no Create a secas: es lo unico que deja MainForm apuntando
    al formulario. Creandolo a mano, Application.Run no tiene ventana
    principal y sale de inmediato: el programa abre y cierra sin decir nada. }
  Application.CreateForm(TFormPanel, Panel);
  Application.Run;
end.
