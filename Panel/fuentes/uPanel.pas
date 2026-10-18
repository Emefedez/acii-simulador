unit uPanel;

{ El modulo LED&KEY, en pantalla.

  Se conecta al simulador por TCP -Indy 10- y dibuja lo que el firmware
  escribe: ocho digitos de siete segmentos, ocho LEDs y ocho pulsadores.
  Ademas mueve el potenciometro de la Practica 5.

  El formulario SOLO dibuja y manda ordenes. Lo que hay que saber del
  protocolo esta en uLogicPanel.

  La ventana se construye en codigo, sin .dfm, para poder compilarla desde
  linea de ordenes sin arrastrar el disenador.
}

interface

uses
  Winapi.Windows, Winapi.Messages,
  System.SysUtils, System.Classes, System.Types,
  System.SyncObjs,
  System.UITypes,
  Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.ExtCtrls, Vcl.StdCtrls,
  Vcl.Dialogs,
  IdTCPClient, IdGlobal,
  uLogicPanel, uLogicRenode, uControles;

type
  TLectorThread = class;

  TFormPanel = class(TForm)
  private
    FCliente: TIdTCPClient;
    FLector: TLectorThread;
    FEstado: TEstadoModulo;

    { EL HILO NO PINTA: DEJA LA ULTIMA LINEA AQUI Y UN RELOJ LA RECOGE.
      Medido: el simulador manda unas 600 lineas por segundo. Con un
      Synchronize por linea, el hilo principal se pasa el rato atendiendo al
      lector y no llega a repintar: el display salia en blanco. Y como cada
      linea llegaba a repintar la ventana entera, parpadeaba. }
    FSeccion: TCriticalSection;
    FUltima: string;
    FHayLinea: Boolean;
    FReloj: TTimer;

    { El modulo se dibuja entero -digitos, LEDs y las ocho teclas- en un
      unico lienzo. Poner las teclas dentro es lo que hace que parezca la
      placa y no un formulario con botones debajo. }
    FLienzo: TPaintBox;

    { LD2, el LED verde de la placa. Va en su propio TPaintBox, junto a B1, y
      no dentro del lienzo del modulo: es de la placa, y la P1 -que es
      justamente la practica de LD2- no enciende el modulo nunca. }
    FLD2: TPaintBox;
    FTeclaEncima: Integer;      { sobre que tecla esta el raton, o 0 }
    FTeclaPulsada: Integer;     { cual esta apretada con el raton, o 0 }

    { Las teclas del teclado del ordenador que estan apretadas. Windows
      repite el KeyDown mientras se mantiene una tecla, y sin esto se
      mandaria una pulsacion nueva cada pocos milisegundos. }
    FTeclado: array[1..N_TECLAS] of Boolean;
    FTecladoB1: Boolean;

    FPote: TDeslizador;
    FBtnB1: TBotonPlano;
    FChkRebotes: TCasilla;
    FLblEstado: TLabel;

    { Arrancar el emulador desde aqui, para no necesitar una consola ni
      Python. Lo de verdad esta en uLogicRenode. }
    FEdtPrograma: TEdit;
    FBtnExaminar: TBotonPlano;
    FChkEsperar: TCasilla;
    FBtnReiniciar: TBotonPlano;
    FBtnArrancar: TBotonPlano;

    FEmulador: TEmulador;
    FRelojArranque: TTimer;
    FEsperando: Integer;        { milisegundos que llevamos esperando }


    procedure MontaVentana;
    procedure PintaLienzo(Sender: TObject);
    procedure PintaLD2(Sender: TObject);
    procedure PintaDigito(C: TCanvas; x, y, an, al: Integer; Segmentos: Byte);
    procedure PintaLed(C: TCanvas; x, y, d: Integer; Encendido: Boolean);
    procedure PintaTecla(C: TCanvas; const R: TRect; const Texto: string;
                         Encima, Pulsada: Boolean);
    procedure PintaFondo(Sender: TObject);
    function TeclaEn(X, Y: Integer): Integer;
    function CajaTecla(i: Integer): TRect;
    procedure LienzoAbajo(Sender: TObject; Button: TMouseButton;
                          Shift: TShiftState; X, Y: Integer);
    procedure LienzoArriba(Sender: TObject; Button: TMouseButton;
                           Shift: TShiftState; X, Y: Integer);
    procedure LienzoMueve(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure LienzoSale(Sender: TObject);

    procedure ClicConectar(Sender: TObject);
    procedure ClicExaminar(Sender: TObject);
    procedure ClicArrancar(Sender: TObject);
    procedure ClicReiniciar(Sender: TObject);
    procedure VigilaArranque(Sender: TObject);
    procedure ParaTodo;
    procedure Arrancando(Si: Boolean);
    procedure Lanzamiento(Habilitado: Boolean);
    function CampoTexto(x, y, Ancho, Alto: Integer;
                        const Valor: string): TEdit;
    procedure PonPrograma(const Ruta: string);
    procedure AlMostrar(Sender: TObject);
    procedure TeclaPulsada(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure TeclaSoltada(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure AseguraConfiguracion(const Ruta: string);
    procedure SueltaElFoco;
    procedure TeclaEnPrograma(Sender: TObject; var Key: Word;
                              Shift: TShiftState);
    procedure EntraEnPrograma(Sender: TObject);
    function TeclaDeAtajo(Key: Word): Integer;
    procedure MuevePote(Sender: TObject);
    procedure B1Abajo(Sender: TObject);
    procedure B1Arriba(Sender: TObject);

    procedure MandaTecla(Tecla: Integer; Abajo: Boolean);
    procedure MandaB1(Abajo: Boolean);
    procedure Manda(const Orden: string);
    procedure Conectado(Si: Boolean);
    procedure Refresca(Sender: TObject);
  protected
    procedure CreateParams(var Params: TCreateParams); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure GuardaLinea(const Linea: string);
    procedure SeCayoLaConexion;
  end;

  { Lee lineas del simulador y las entrega al formulario. Va en un hilo
    porque el simulador manda una linea por cada cambio del display, y
    pueden ser muchas seguidas. }
  TLectorThread = class(TThread)
  private
    FCliente: TIdTCPClient;
    FForm: TFormPanel;
    FLinea: string;
    procedure Aviso;
  protected
    procedure Execute; override;
  public
    constructor Create(ACliente: TIdTCPClient; AForm: TFormPanel);
  end;

implementation

const
  MARGEN = 20;

  { El alto de la placa y donde empieza cada bloque. Todo cuelga de aqui,
    para poder mover un bloque sin recolocar veinte controles a mano. }
  ALTO_PLACA = 268;
  Y_POTE     = MARGEN + ALTO_PLACA + 34;
  Y_PROGRAMA = Y_POTE + 118;
  Y_ESTADO   = Y_PROGRAMA + 72;
  X_DERECHA  = 608;
  ALTO_FILA  = 32;   { el mismo para campos y botones de una fila }

{ ------------------------------------------------------------ el hilo --- }

constructor TLectorThread.Create(ACliente: TIdTCPClient; AForm: TFormPanel);
begin
  inherited Create(True);
  FCliente := ACliente;
  FForm := AForm;
  FreeOnTerminate := False;
end;

procedure TLectorThread.Aviso;
begin
  FForm.SeCayoLaConexion;
end;

procedure TLectorThread.Execute;
begin
  while not Terminated do
  begin
    try
      FLinea := FCliente.IOHandler.ReadLn;
      if Terminated then Break;
      { Solo dejarla escrita. Pintar es cosa del reloj del formulario. }
      FForm.GuardaLinea(FLinea);
    except
      Break;
    end;
  end;

  { SI EL HILO ACABA SIN QUE SE LO HAYAMOS PEDIDO, ES QUE SE CAYO LA
    CONEXION, Y HAY QUE DECIRLO. Medido: al morir el simulador, el panel
    seguia con el rotulo azul de "conectado" y con el ultimo fotograma en
    pantalla. Un display congelado que no dice que lo esta se lee como un
    programa que no avanza, y se busca el fallo donde no esta. }
  if not Terminated then
    Synchronize(Aviso);
end;

{ ------------------------------------------------------- el formulario --- }

{ SIN ESTO NO HAY BOTON EN LA BARRA DE TAREAS, y al minimizar la ventana
  desaparece del todo.

  La ventana se monta en el constructor, y en cuanto un control recibe
  `Parent := Self` se crea el handle del formulario. Eso pasa ANTES de que
  Application.CreateForm asigne Application.MainForm, asi que VCL cree que
  este no es el formulario principal y crea la ventana propiedad de la
  ventana oculta de Application y sin WS_EX_APPWINDOW. Windows no le da
  boton. Medido: EX=0x00010100, con owner distinto de cero.

  Aqui se declara lo que hace falta: sin dueno y marcada como ventana de
  aplicacion. }
procedure TFormPanel.CreateParams(var Params: TCreateParams);
begin
  inherited;
  Params.ExStyle := Params.ExStyle or WS_EX_APPWINDOW;
  Params.WndParent := 0;
end;

constructor TFormPanel.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);
  FCliente := TIdTCPClient.Create(nil);
  FSeccion := TCriticalSection.Create;

  { Sin esto, cada repintado borra el fondo y vuelve a dibujar encima, y se
    ve el parpadeo. }
  DoubleBuffered := True;

  MontaVentana;

  FReloj := TTimer.Create(Self);
  FReloj.Interval := 40;           { 25 repintados por segundo, de sobra }
  FReloj.OnTimer := Refresca;
  FReloj.Enabled := True;
  FillChar(FEstado, SizeOf(FEstado), 0);
  FEstado.Brillo := 7;
end;

destructor TFormPanel.Destroy;
begin
  { Si lo arrancamos nosotros, lo paramos: si no, queda un Renode corriendo
    sin ventana y el siguiente arranque choca con el puerto ocupado. }
  ParaEmulador(FEmulador);
  if Assigned(FLector) then
  begin
    FLector.Terminate;
    try FCliente.Disconnect; except end;
    FLector.WaitFor;
    FLector.Free;
  end;
  FCliente.Free;
  FSeccion.Free;
  inherited;
end;

procedure TFormPanel.MontaVentana;
begin
  Caption := 'ACII · Módulo LED&KEY';
  BorderStyle := bsSingle;
  BorderIcons := [biSystemMenu, biMinimize];
  ClientWidth := 760;
  ClientHeight := 556;
  Position := poScreenCenter;
  Color := clWhite;
  Font.Name := TIPO_TEXTO;
  Font.Size := 10;
  OnPaint := PintaFondo;
  OnShow := AlMostrar;

  { KeyPreview: el formulario ve las teclas antes que el control que tenga
    el foco, que si no se las quedaria el campo del programa. }
  KeyPreview := True;
  OnKeyDown := TeclaPulsada;
  OnKeyUp := TeclaSoltada;

  { --- el modulo --- }
  FLienzo := TPaintBox.Create(Self);
  FLienzo.Parent := Self;
  FLienzo.SetBounds(MARGEN, MARGEN, ClientWidth - 2 * MARGEN, ALTO_PLACA);
  FLienzo.OnPaint := PintaLienzo;
  FLienzo.OnMouseDown := LienzoAbajo;
  FLienzo.OnMouseUp := LienzoArriba;
  FLienzo.OnMouseMove := LienzoMueve;
  FLienzo.OnMouseLeave := LienzoSale;

  { --- potenciometro y pulsador de la placa --- }
  FPote := TDeslizador.Create(Self);
  FPote.Parent := Self;
  FPote.SetBounds(MARGEN, Y_POTE + 22, 420, 28);
  FPote.Min := 0;
  FPote.Max := 4095;
  FPote.OnCambia := MuevePote;

  { LD2 a la izquierda de B1, a su misma altura: en el hueco que queda entre
    el potenciometro, que acaba en x = 440, y el boton, que empieza en 608. }
  FLD2 := TPaintBox.Create(Self);
  FLD2.Parent := Self;
  FLD2.SetBounds(X_DERECHA - 78, Y_POTE + 20, 74, 34);
  FLD2.OnPaint := PintaLD2;

  FBtnB1 := TBotonPlano.Create(Self);
  FBtnB1.Parent := Self;
  FBtnB1.SetBounds(X_DERECHA, Y_POTE + 20, 132, 34);
  FBtnB1.Texto := 'B1';
  FBtnB1.Estilo := ebPlaca;
  FBtnB1.OnAbajo := B1Abajo;
  FBtnB1.OnArriba := B1Arriba;

  FChkRebotes := TCasilla.Create(Self);
  FChkRebotes.Parent := Self;
  FChkRebotes.SetBounds(MARGEN, Y_POTE + 58, 420, 22);
  FChkRebotes.Texto := 'Simular rebotes del pulsador, como en la placa';

  { --- el programa que se ejecuta ---
    Todo en esta fila mide ALTO_FILA y arranca en la misma y, asi que queda
    alineado por construccion y no por tanteo. }
  FEdtPrograma := CampoTexto(MARGEN, Y_PROGRAMA + 22, 428, ALTO_FILA, '');
  FEdtPrograma.OnKeyDown := TeclaEnPrograma;
  FEdtPrograma.OnEnter := EntraEnPrograma;

  FBtnExaminar := TBotonPlano.Create(Self);
  FBtnExaminar.Parent := Self;
  FBtnExaminar.SetBounds(MARGEN + 438, Y_PROGRAMA + 22, 108, ALTO_FILA);
  FBtnExaminar.Texto := 'Examinar…';
  FBtnExaminar.OnClick := ClicExaminar;

  { Arrancar con el programa DETENIDO en la primera instruccion, para poder
    poner un punto de ruptura en main antes de que se ejecute nada. Lo
    suelta el depurador; ver uLogicRenode. }
  FChkEsperar := TCasilla.Create(Self);
  FChkEsperar.Parent := Self;
  FChkEsperar.SetBounds(MARGEN, Y_ESTADO, 190, 22);
  FChkEsperar.Texto := 'Esperar al depurador';
  FChkEsperar.Hint := 'Arranca con el programa detenido en la primera '
                    + 'instruccion, para poder parar dentro de main';
  FChkEsperar.ShowHint := True;

  { Para volver a depurar desde la primera instruccion hay que rearmar el
    emulador, y eso es pararlo y arrancarlo. En un boton, para no tener que
    darle dos veces. }
  FBtnReiniciar := TBotonPlano.Create(Self);
  FBtnReiniciar.Parent := Self;
  FBtnReiniciar.SetBounds(MARGEN + 200, Y_ESTADO - 4, 112, 28);
  FBtnReiniciar.Texto := 'Reiniciar';
  FBtnReiniciar.Hint := 'Para el emulador y lo vuelve a arrancar, para poder '
                      + 'depurar otra vez desde el principio';
  FBtnReiniciar.ShowHint := True;
  FBtnReiniciar.OnClick := ClicReiniciar;

  FBtnArrancar := TBotonPlano.Create(Self);
  FBtnArrancar.Parent := Self;
  FBtnArrancar.SetBounds(X_DERECHA, Y_PROGRAMA + 22, 132, ALTO_FILA);
  FBtnArrancar.Texto := 'Arrancar';
  FBtnArrancar.Estilo := ebAcento;
  FBtnArrancar.OnClick := ClicArrancar;

  { --- el estado, sin mas controles ---
    No hay campos de direccion ni boton de conectar: el panel se conecta el
    solo, al arrancar el emulador o al abrirse si ya hay uno corriendo. Un
    boton que en el uso normal no se toca nunca solo estorba. }
  FLblEstado := TLabel.Create(Self);
  FLblEstado.Parent := Self;
  FLblEstado.AutoSize := False;
  FLblEstado.Layout := tlCenter;
  FLblEstado.SetBounds(MARGEN + 350, Y_ESTADO, 380, 22);
  FLblEstado.Font.Name := TIPO_TEXTO;
  FLblEstado.Font.Color := COLOR_GRIS600;
  FLblEstado.Caption := 'sin conexión';

  { El reloj que vigila el arranque. La primera vez Renode compila los
    modelos en C# y tarda, asi que no se puede esperar bloqueando: la
    ventana se quedaria colgada sin decir nada. }
  FRelojArranque := TTimer.Create(Self);
  FRelojArranque.Interval := 500;
  FRelojArranque.OnTimer := VigilaArranque;
  FRelojArranque.Enabled := False;

  { Si viene el programa de ejemplo, se propone: asi se puede probar que
    todo funciona sin haber compilado nada. }
  PonPrograma(BuscaEjemplo);
end;

{ Un campo de texto: un fondo gris plano y, DENTRO Y CENTRADO, un TEdit sin
  marco. Hay que centrarlo a mano midiendo la altura real de la fuente: un
  TEdit sin borde pega su texto arriba, y al lado de un boton del mismo alto
  se ve descolocado. }
function TFormPanel.CampoTexto(x, y, Ancho, Alto: Integer;
  const Valor: string): TEdit;
var
  Fondo: TPanel;
  AltoTexto: Integer;
begin
  Fondo := TPanel.Create(Self);
  Fondo.Parent := Self;
  Fondo.SetBounds(x, y, Ancho, Alto);
  Fondo.BevelOuter := bvNone;
  Fondo.Color := COLOR_GRIS100;
  Fondo.ParentBackground := False;

  Result := TEdit.Create(Self);
  Result.Parent := Fondo;
  Result.BorderStyle := bsNone;
  Result.Color := COLOR_GRIS100;
  Result.Font.Name := TIPO_MONO;
  Result.Font.Size := 9;
  Result.Font.Color := COLOR_TINTA;
  Result.AutoSelect := False;

  { Sin parada de tabulador. Es el unico control de la ventana que admite el
    foco, asi que si lo tiene VCL se lo da al activarse y no lo suelta: y
    mientras lo tenga, las teclas son texto y S1..S8 no responden. Con esto
    la ventana nace sin foco en ningun sitio -que es lo que quiere la placa-
    y el campo lo coge solo cuando se pincha en el. }
  Result.TabStop := False;

  Canvas.Font := Result.Font;
  AltoTexto := Canvas.TextHeight('Xg') + 2;
  Result.SetBounds(10, (Alto - AltoTexto) div 2, Ancho - 20, AltoTexto);
  Result.Text := Valor;
end;

{ Los rotulos de seccion y las lineas que separan, sobre el propio
  formulario: son decoracion, no controles. }
procedure TFormPanel.PintaLD2(Sender: TObject);
const
  D = 18;                                 { el diametro, como los del modulo }
var
  C: TCanvas;
  x, y: Integer;
begin
  C := FLD2.Canvas;
  C.Brush.Color := Color;
  C.FillRect(Rect(0, 0, FLD2.Width, FLD2.Height));

  x := FLD2.Width - D - 12;
  y := (FLD2.Height - D) div 2;

  { El rotulo, a la izquierda del LED. Con aire: el halo del LED encendido
    sale 5 pixeles hacia fuera, y a 6 el texto quedaba pegado a el. }
  C.Font.Name := TIPO_ROTULO;
  C.Font.Size := 8;
  C.Font.Style := [];
  C.Font.Color := COLOR_ACENTO;
  C.Brush.Style := bsClear;
  C.TextOut(x - 12 - C.TextWidth('LD2'),
            (FLD2.Height - C.TextHeight('LD2')) div 2, 'LD2');
  C.Brush.Style := bsSolid;

  { Verde, como en la NUCLEO, y con el mismo halo que los del modulo.
    Apagado va en gris claro: el gris oscuro de los del modulo esta pensado
    para la placa negra y aqui, sobre blanco, pareceria un agujero. }
  if FEstado.LD2 then
  begin
    C.Brush.Color := TColor($18380F);  C.Pen.Color := TColor($18380F);
    C.Ellipse(x - 5, y - 5, x + D + 5, y + D + 5);
    C.Brush.Color := TColor($40A020);  C.Pen.Color := TColor($40A020);
    C.Ellipse(x - 2, y - 2, x + D + 2, y + D + 2);
    C.Brush.Color := TColor($60F040);  C.Pen.Color := TColor($90FF70);
  end
  else
  begin
    C.Brush.Color := TColor($D1CCC9);  C.Pen.Color := TColor($B4ADA9);
  end;
  C.Ellipse(x, y, x + D, y + D);
end;

procedure TFormPanel.PintaFondo(Sender: TObject);

  procedure Linea(y: Integer);
  begin
    Canvas.Pen.Color := COLOR_GRIS300;
    Canvas.MoveTo(MARGEN, y);
    Canvas.LineTo(ClientWidth - MARGEN, y);
  end;

begin
  Canvas.Brush.Color := clWhite;
  Canvas.FillRect(ClientRect);

  Rotulo(Canvas, MARGEN, Y_POTE, 'Potenciómetro', COLOR_GRIS600);
  RotuloDer(Canvas, ClientWidth - MARGEN, Y_POTE, 'Pulsador de la placa',
            COLOR_GRIS600);

  { Los atajos, dichos donde se ven: si no, nadie los descubre. Y mientras
    se escribe la ruta las teclas son texto, asi que lo dice. }
  if (ActiveControl <> nil) and (ActiveControl is TCustomEdit) then
    RotuloDer(Canvas, ClientWidth - MARGEN, Y_POTE + 60,
              'Intro o un clic en la placa devuelven los atajos',
              COLOR_GRIS300, 8)
  else
    RotuloDer(Canvas, ClientWidth - MARGEN, Y_POTE + 60,
              'Desde el teclado:  1 a 8  ·  espacio = B1', COLOR_GRIS300, 8);

  Linea(Y_PROGRAMA - 14);
  Rotulo(Canvas, MARGEN, Y_PROGRAMA, 'Programa que se va a ejecutar',
         COLOR_GRIS600);



  { El valor del potenciometro, al lado de su rotulo }
  Canvas.Font.Name := TIPO_MONO;
  Canvas.Font.Size := 9;
  Canvas.Font.Color := COLOR_TINTA;
  Canvas.Brush.Style := bsClear;
  Canvas.TextOut(MARGEN + 138, Y_POTE - 1,
                 Format('%4d   ·   %d,%.2d V', [FPote.Valor,
                        (FPote.Valor * 3300 div 4095) div 1000,
                        ((FPote.Valor * 3300 div 4095) mod 1000) div 10]));
  Canvas.Brush.Style := bsSolid;

  { El punto de estado, delante del rotulo }
  if FCliente.Connected then
    Canvas.Brush.Color := COLOR_ACENTO
  else
    Canvas.Brush.Color := COLOR_GRIS300;
  Canvas.Pen.Color := Canvas.Brush.Color;
  Canvas.Ellipse(MARGEN + 330, Y_ESTADO + 6, MARGEN + 340, Y_ESTADO + 16);
end;

{ ----------------------------------------------------------- dibujar --- }

procedure TFormPanel.PintaDigito(C: TCanvas; x, y, an, al: Integer;
  Segmentos: Byte);
var
  g, m: Integer;

  procedure Seg(const P: array of TPoint; Bit: Byte);
  begin
    if Segmentos and Bit <> 0 then
      C.Brush.Color := COLOR_ROJO
    else
      C.Brush.Color := TColor($2A2A2A);   { apagado, pero visible }
    C.Pen.Color := C.Brush.Color;
    C.Polygon(P);
  end;

begin
  g := 6;                  { grosor del segmento }
  m := al div 2;           { mitad de la altura, donde va el segmento g }

  { Horizontales: a arriba, g en medio, d abajo }
  Seg([Point(x + g, y), Point(x + an - g, y),
       Point(x + an - g - g, y + g), Point(x + g + g, y + g)], SEG_A);
  Seg([Point(x + g, y + m), Point(x + an - g, y + m),
       Point(x + an - g - g, y + m + g), Point(x + g + g, y + m + g)], SEG_G);
  Seg([Point(x + g, y + al), Point(x + an - g, y + al),
       Point(x + an - g - g, y + al + g), Point(x + g + g, y + al + g)], SEG_D);

  { Verticales de arriba: f izquierda, b derecha }
  Seg([Point(x, y + g), Point(x + g, y + g + g),
       Point(x + g, y + m - g), Point(x, y + m)], SEG_F);
  Seg([Point(x + an, y + g), Point(x + an - g, y + g + g),
       Point(x + an - g, y + m - g), Point(x + an, y + m)], SEG_B);

  { Verticales de abajo: e izquierda, c derecha }
  Seg([Point(x, y + m + g), Point(x + g, y + m + g + g),
       Point(x + g, y + al - g), Point(x, y + al)], SEG_E);
  Seg([Point(x + an, y + m + g), Point(x + an - g, y + m + g + g),
       Point(x + an - g, y + al - g), Point(x + an, y + al)], SEG_C);

  { El punto decimal }
  if Segmentos and SEG_PUNTO <> 0 then
    C.Brush.Color := COLOR_ROJO
  else
    C.Brush.Color := TColor($2A2A2A);
  C.Pen.Color := C.Brush.Color;
  C.Ellipse(x + an + 6, y + al - 2, x + an + 6 + g + 2, y + al + g);
end;

procedure TFormPanel.PintaLed(C: TCanvas; x, y, d: Integer;
  Encendido: Boolean);
begin
  { Un LED encendido no es un circulo plano: derrama luz alrededor. Un halo
    apenas visible hace que se lea de un vistazo cual esta encendido. }
  if Encendido then
  begin
    C.Brush.Color := TColor($101038);
    C.Pen.Color := TColor($101038);
    C.Ellipse(x - 5, y - 5, x + d + 5, y + d + 5);
    C.Brush.Color := TColor($2020A0);
    C.Pen.Color := TColor($2020A0);
    C.Ellipse(x - 2, y - 2, x + d + 2, y + d + 2);
    C.Brush.Color := TColor($3050F0);
    C.Pen.Color := TColor($4060FF);
  end
  else
  begin
    C.Brush.Color := TColor($1E1E1E);
    C.Pen.Color := TColor($303030);
  end;
  C.Ellipse(x, y, x + d, y + d);
end;

{ Las ocho teclas van DENTRO de la placa, como en el modulo de verdad. }
function TFormPanel.CajaTecla(i: Integer): TRect;
var
  an, hueco, x: Integer;
begin
  an := 58;
  hueco := 12;
  x := (FLienzo.Width - (8 * an + 7 * hueco)) div 2 + (i - 1) * (an + hueco);
  Result := Rect(x, ALTO_PLACA - 78, x + an, ALTO_PLACA - 78 + 44);
end;

function TFormPanel.TeclaEn(X, Y: Integer): Integer;
var
  i: Integer;
begin
  for i := 1 to N_TECLAS do
    if PtInRect(CajaTecla(i), Point(X, Y)) then
      Exit(i);
  Result := 0;
end;

procedure TFormPanel.PintaTecla(C: TCanvas; const R: TRect;
  const Texto: string; Encima, Pulsada: Boolean);
var
  Fondo: TColor;
begin
  if Pulsada then Fondo := COLOR_ACENTO
  else if Encima then Fondo := TColor($4A4A4A)
  else Fondo := TColor($383838);

  { Una sombra por debajo: hace que la tecla sobresalga de la placa. }
  if not Pulsada then
    Caja(C, Rect(R.Left, R.Top + 3, R.Right, R.Bottom + 3),
         TColor($0E0E0E), 5);
  Caja(C, R, Fondo, 5);

  C.Font.Name := TIPO_TEXTO;
  C.Font.Size := 10;
  C.Font.Style := [];
  C.Font.Color := TColor($E0E0E0);
  C.Brush.Style := bsClear;
  C.TextOut(R.Left + (R.Width - C.TextWidth(Texto)) div 2,
            R.Top + (R.Height - C.TextHeight(Texto)) div 2, Texto);
  C.Brush.Style := bsSolid;
end;

procedure TFormPanel.PintaLienzo(Sender: TObject);
var
  C: TCanvas;
  i, x, an, hueco, x0: Integer;
begin
  C := FLienzo.Canvas;

  { La placa: un rectangulo oscuro con bisel, no un rectangulo negro. }
  C.Brush.Color := clWhite;
  C.FillRect(Rect(0, 0, FLienzo.Width, FLienzo.Height));
  Caja(C, Rect(0, 0, FLienzo.Width, FLienzo.Height), COLOR_BISEL, 10);
  Caja(C, Rect(2, 2, FLienzo.Width - 2, FLienzo.Height - 2), COLOR_PLACA, 9);

  { Serigrafia, como la del modulo real }
  Rotulo(C, 18, 14, 'LED & KEY', TColor($4A4A4A), 8);
  Rotulo(C, FLienzo.Width - 116, 14, 'TM1638', TColor($4A4A4A), 8);

  { La ventanilla del display, un poco mas negra que la placa }
  Caja(C, Rect(14, 38, FLienzo.Width - 14, 128), TColor($0A0A0A), 6);

  { Ocho digitos de siete segmentos }
  an := 44;
  hueco := 34;
  x0 := (FLienzo.Width - (8 * an + 7 * hueco)) div 2;
  for i := 0 to N_DIGITOS - 1 do
  begin
    x := x0 + i * (an + hueco);
    if FEstado.Encendido then
      PintaDigito(C, x, 52, an, 60, FEstado.Segmentos[i])
    else
      PintaDigito(C, x, 52, an, 60, 0);
  end;

  { Ocho LEDs, alineados bajo su digito }
  for i := 0 to N_LEDS - 1 do
    PintaLed(C, x0 + i * (an + hueco) + (an - 18) div 2, 148, 18,
             FEstado.Encendido and FEstado.Leds[i]);

  { Y las ocho teclas }
  for i := 1 to N_TECLAS do
    PintaTecla(C, CajaTecla(i), 'S' + IntToStr(i),
               FTeclaEncima = i, FTeclaPulsada = i);
end;

{ ------------------------------------------------- raton sobre la placa --- }

procedure TFormPanel.LienzoAbajo(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  t: Integer;
begin
  if Button <> mbLeft then Exit;
  SueltaElFoco;                   { tocar la placa devuelve los atajos }
  t := TeclaEn(X, Y);
  if t = 0 then Exit;
  FTeclaPulsada := t;
  FLienzo.Invalidate;
  MandaTecla(t, True);
end;

procedure TFormPanel.LienzoArriba(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  t: Integer;
begin
  if FTeclaPulsada = 0 then Exit;
  t := FTeclaPulsada;
  FTeclaPulsada := 0;
  FLienzo.Invalidate;
  MandaTecla(t, False);
end;

procedure TFormPanel.LienzoMueve(Sender: TObject; Shift: TShiftState;
  X, Y: Integer);
var
  t: Integer;
begin
  t := TeclaEn(X, Y);
  if t <> FTeclaEncima then
  begin
    FTeclaEncima := t;
    FLienzo.Invalidate;
  end;
end;

procedure TFormPanel.LienzoSale(Sender: TObject);
begin
  { Si se sale de la placa con una tecla apretada hay que soltarla, o el
    firmware la vera pulsada para siempre. }
  if FTeclaPulsada <> 0 then
  begin
    MandaTecla(FTeclaPulsada, False);
    FTeclaPulsada := 0;
  end;
  FTeclaEncima := 0;
  FLienzo.Invalidate;
end;

{ ----------------------------------------------------------- eventos --- }

{ Llamado DESDE EL HILO LECTOR. Aqui no se toca nada de la interfaz. }
procedure TFormPanel.GuardaLinea(const Linea: string);
begin
  FSeccion.Enter;
  try
    FUltima := Linea;
    FHayLinea := True;
  finally
    FSeccion.Leave;
  end;
end;

{ Llamado desde el hilo principal, 25 veces por segundo. Si han llegado
  lineas desde la ultima vez, se pinta la ultima: las intermedias no
  interesan, el display solo tiene un aspecto actual. }
procedure TFormPanel.Refresca(Sender: TObject);
var
  Linea: string;
  Hay, LD2Antes: Boolean;
begin
  FSeccion.Enter;
  try
    Hay := FHayLinea;
    Linea := FUltima;
    FHayLinea := False;
  finally
    FSeccion.Leave;
  end;

  LD2Antes := FEstado.LD2;
  if Hay and LeeEstado(Linea, FEstado) then
  begin
    FLienzo.Invalidate;
    { LD2 solo si ha cambiado: el modulo refresca muy a menudo y no hay por
      que repintar tambien el LED de la placa cada vez. }
    if FEstado.LD2 <> LD2Antes then
      FLD2.Invalidate;
  end;
end;

procedure TFormPanel.SeCayoLaConexion;
begin
  try FCliente.Disconnect; except end;
  Conectado(False);
  FLblEstado.Caption := 'el simulador ha cerrado la conexión';

  { Ya no hay nada corriendo: se vuelve a poder elegir programa. }
  FBtnArrancar.Texto := 'Arrancar';
  FBtnArrancar.Enabled := True;
  Lanzamiento(True);

  { Apagar el modulo. Dejar el ultimo fotograma seria mentir. }
  FillChar(FEstado, SizeOf(FEstado), 0);
  FEstado.Brillo := 7;
  FLienzo.Invalidate;
  FLD2.Invalidate;
end;

{ ------------------------------------------------- arrancar Renode --- }

{ De una ruta larga solo se ve el principio, que es lo que menos importa:
  el nombre del fichero esta al final. Se lleva el cursor al final para que
  el campo se desplace hasta ahi, y la ruta entera queda en la ayuda. }
procedure TFormPanel.PonPrograma(const Ruta: string);
begin
  FEdtPrograma.Text := Ruta;
  FEdtPrograma.Hint := Ruta;
  FEdtPrograma.ShowHint := True;
  if FEdtPrograma.HandleAllocated then
  begin
    FEdtPrograma.Perform(EM_SETSEL, Length(Ruta), Length(Ruta));
    FEdtPrograma.Perform(EM_SCROLLCARET, 0, 0);
  end;

  AseguraConfiguracion(Ruta);
end;

{ Deja hecha la configuracion de depuracion del proyecto al que pertenezca
  el .elf, si no la tenia. Se avisa: hay que ir a buscarla a Run > Debug
  Configurations, y pasa una sola vez por proyecto. }
procedure TFormPanel.AseguraConfiguracion(const Ruta: string);
var
  Creada, Fallo: string;
begin
  if Ruta = '' then Exit;

  Creada := CreaConfiguracionCubeIDE(Ruta, Fallo);
  if Creada = '' then Exit;

  FLblEstado.Caption := 'configuración de depuración añadida al proyecto';
  FLblEstado.Font.Color := COLOR_ACENTO;
  { Los cortes van a mano: si no, el dialogo sale de casi mil pixeles. }
  MessageDlg('Le he añadido al proyecto la configuración de depuración'#13#10 +
             '«' + ChangeFileExt(Creada, '') + '».'#13#10#13#10 +
             'En STM32CubeIDE la tienes en Run > Debug Configurations,'#13#10 +
             'bajo GDB Hardware Debugging. Si el proyecto ya estaba'#13#10 +
             'abierto, refréscalo con F5 para que aparezca.',
             mtInformation, [mbOK], 0);
end;

{ Al montar la ventana el campo todavia no tiene handle, asi que el
  desplazamiento no se aplica. Aqui si. }
procedure TFormPanel.AlMostrar(Sender: TObject);
begin
  PonPrograma(FEdtPrograma.Text);

  { Aqui manda la placa: ver el TabStop de CampoTexto. }
  ActiveControl := nil;

  { Si ya hay un emulador corriendo -lo arranco otra ventana, o simula.py
    desde la consola-, engancharse sin que haya que pedirlo. }
  if PuertoAbierto(PUERTO_MODULO) and not FCliente.Connected then
  begin
    ClicConectar(nil);
    FBtnArrancar.Texto := 'Parar';
    Lanzamiento(False);
  end;
end;

{ ---------------------------------------------- atajos de teclado --- }

{ 1..8 son las ocho teclas del modulo; el espacio, y tambien la B, son el
  pulsador azul de la placa. Se usan los numeros de arriba y los del teclado
  numerico, que es lo que la mano encuentra sola. }
{ Devuelve el foco a la ventana. El campo de la ruta es el unico control que
  lo coge, y mientras lo tenga las teclas son texto y no atajos -las rutas
  llevan digitos, espacios y alguna B-. Sin esto el foco se queda ahi para
  siempre y S1..S8 no vuelven a responder al teclado. }
procedure TFormPanel.SueltaElFoco;
begin
  if (ActiveControl <> nil) and (ActiveControl is TCustomEdit) then
  begin
    ActiveControl := nil;
    Invalidate;                   { el rotulo de los atajos cambia }
  end;
end;

{ Al entrar en el campo cambia el rotulo de los atajos. }
procedure TFormPanel.EntraEnPrograma(Sender: TObject);
begin
  Invalidate;
end;

{ Intro o Escape en el campo de la ruta: se ha acabado de escribir. }
procedure TFormPanel.TeclaEnPrograma(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  if (Key = VK_RETURN) or (Key = VK_ESCAPE) then
  begin
    Key := 0;                     { que no suene el pitido }
    SueltaElFoco;
  end;
end;

function TFormPanel.TeclaDeAtajo(Key: Word): Integer;
begin
  { Con el foco en un campo de texto las teclas son texto, no atajos: las
    rutas llevan digitos, espacios y la letra B. }
  if (ActiveControl <> nil) and (ActiveControl is TCustomEdit) then
    Exit(0);

  case Key of
    Ord('1')..Ord('8'): Result := Key - Ord('0');
    VK_NUMPAD1..VK_NUMPAD8: Result := Key - VK_NUMPAD1 + 1;
    VK_SPACE, Ord('B'): Result := -1;      { el pulsador de la placa }
  else
    Result := 0;
  end;
end;

procedure TFormPanel.TeclaPulsada(Sender: TObject; var Key: Word;
  Shift: TShiftState);
var
  t: Integer;
begin
  t := TeclaDeAtajo(Key);
  if t = 0 then Exit;
  Key := 0;                       { que no llegue al campo de texto }

  if t = -1 then
  begin
    if FTecladoB1 then Exit;      { repeticion automatica de Windows }
    FTecladoB1 := True;
    MandaB1(True);
    Exit;
  end;

  if FTeclado[t] then Exit;
  FTeclado[t] := True;
  FTeclaPulsada := t;             { que se vea apretada en la placa }
  FLienzo.Invalidate;
  MandaTecla(t, True);
end;

procedure TFormPanel.TeclaSoltada(Sender: TObject; var Key: Word;
  Shift: TShiftState);
var
  t: Integer;
begin
  t := TeclaDeAtajo(Key);
  if t = 0 then Exit;
  Key := 0;

  if t = -1 then
  begin
    if not FTecladoB1 then Exit;
    FTecladoB1 := False;
    MandaB1(False);
    Exit;
  end;

  if not FTeclado[t] then Exit;
  FTeclado[t] := False;
  if FTeclaPulsada = t then FTeclaPulsada := 0;
  FLienzo.Invalidate;
  MandaTecla(t, False);
end;

procedure TFormPanel.ClicExaminar(Sender: TObject);
var
  Dlg: TOpenDialog;
begin
  Dlg := TOpenDialog.Create(Self);
  try
    Dlg.Title := 'El programa compilado que se quiere ejecutar';
    Dlg.Filter := 'Programas compilados (*.elf)|*.elf|Todos|*.*';
    if FEdtPrograma.Text <> '' then
      Dlg.InitialDir := ExtractFilePath(FEdtPrograma.Text);
    if Dlg.Execute then
      PonPrograma(Dlg.FileName);
    SueltaElFoco;
  finally
    Dlg.Free;
  end;
end;

{ La ruta, Examinar y la casilla solo tienen sentido con el emulador
  parado: mientras uno corre no se puede cambiar el programa sin pararlo, y
  el campo enseniaria una ruta que no es la que se esta ejecutando. De paso,
  deshabilitado no puede coger el foco, y los atajos del teclado quedan
  garantizados mientras hay algo que pulsar. }
procedure TFormPanel.Lanzamiento(Habilitado: Boolean);
begin
  if not Habilitado then SueltaElFoco;
  FEdtPrograma.Enabled := Habilitado;
  TWinControl(FEdtPrograma.Parent).Enabled := Habilitado;
  FBtnExaminar.Enabled := Habilitado;
  FChkEsperar.Enabled := Habilitado;
end;

procedure TFormPanel.Arrancando(Si: Boolean);
begin
  FBtnArrancar.Enabled := not Si;
  Lanzamiento(not Si);
end;

procedure TFormPanel.ParaTodo;
begin
  FRelojArranque.Enabled := False;
  if FCliente.Connected then
    ClicConectar(nil);
  ParaEmulador(FEmulador);
  Arrancando(False);
  FBtnArrancar.Texto := 'Arrancar';
  FBtnArrancar.Enabled := True;
end;

procedure TFormPanel.ClicArrancar(Sender: TObject);
var
  Renode, Guion, Error: string;
begin
  SueltaElFoco;
  if EmuladorVivo(FEmulador) then
  begin
    ParaTodo;
    FLblEstado.Caption := 'emulador parado';
    FLblEstado.Font.Color := COLOR_GRIS600;
    Exit;
  end;

  Renode := BuscaRenode;
  if Renode = '' then
  begin
    MessageDlg('No encuentro Renode.'#13#10#13#10 +
               'Tendría que estar en la carpeta Renode, junto a la del ' +
               'panel: viene con el simulador. Si falta, vuelve a ' +
               'instalarlo o a descomprimir el ZIP entero.',
               mtWarning, [mbOK], 0);
    Exit;
  end;

  if FEdtPrograma.Text = '' then
  begin
    MessageDlg('Elige primero el programa que quieres ejecutar: es el ' +
               'fichero .elf que STM32CubeIDE deja en la carpeta Debug ' +
               'del proyecto.', mtInformation, [mbOK], 0);
    Exit;
  end;

  if PuertoAbierto(PUERTO_MODULO) then
  begin
    MessageDlg('Ya hay un simulador corriendo en el puerto ' +
               IntToStr(PUERTO_MODULO) + '.'#13#10#13#10 +
               'Ciérralo antes de arrancar otro.',
               mtWarning, [mbOK], 0);
    Exit;
  end;

  { Al arrancar, y no solo al elegir con Examinar: asi vale tambien si la
    ruta se escribe a mano. Si el proyecto ya la tiene, no se toca. }
  AseguraConfiguracion(FEdtPrograma.Text);

  Guion := PreparaEjecucion(FEdtPrograma.Text, FChkEsperar.Marcada, Error);
  if Guion = '' then
  begin
    MessageDlg(Error, mtError, [mbOK], 0);
    Exit;
  end;

  if not ArrancaEmulador(Renode, Guion, FEmulador, Error) then
  begin
    MessageDlg(Error, mtError, [mbOK], 0);
    Exit;
  end;

  Arrancando(True);
  FBtnArrancar.Texto := 'Arrancando…';
  FEsperando := 0;
  FRelojArranque.Enabled := True;
  FLblEstado.Caption := 'arrancando el emulador…';
  FLblEstado.Font.Color := COLOR_GRIS600;
end;

{ Parar y volver a arrancar de una vez. Es lo que hace falta para depurar
  otra vez desde el principio: el punto de ruptura del arranque solo se
  puede coger con un emulador recien nacido. }
procedure TFormPanel.ClicReiniciar(Sender: TObject);
var
  Espera: Integer;
begin
  if EmuladorVivo(FEmulador) then
  begin
    FLblEstado.Caption := 'reiniciando…';
    FLblEstado.Font.Color := COLOR_GRIS600;
    Application.ProcessMessages;
    ParaTodo;

    { El proceso ya esta muerto, pero el puerto puede tardar un momento en
      quedar libre. Sin esta espera, arrancar seguido avisa de que ya hay
      un simulador corriendo. }
    Espera := 0;
    while PuertoAbierto(PUERTO_MODULO) and (Espera < 5000) do
    begin
      Sleep(200);
      Inc(Espera, 200);
      Application.ProcessMessages;
    end;
  end;
  ClicArrancar(nil);
end;

procedure TFormPanel.VigilaArranque(Sender: TObject);
begin
  Inc(FEsperando, FRelojArranque.Interval);

  { Si el proceso se ha muerto, no tiene sentido seguir esperando. }
  if not EmuladorVivo(FEmulador) then
  begin
    FRelojArranque.Enabled := False;
    Arrancando(False);
    FBtnArrancar.Texto := 'Arrancar';
    FLblEstado.Caption := 'el emulador se ha cerrado al arrancar';
    MessageDlg('El emulador se ha cerrado nada más arrancar.'#13#10#13#10 +
               'Lo último que dijo:'#13#10#13#10 +
               UltimasLineas(FEmulador.Registro, 8),
               mtError, [mbOK], 0);
    Exit;
  end;

  if PuertoAbierto(PUERTO_MODULO) then
  begin
    FRelojArranque.Enabled := False;
    FBtnArrancar.Texto := 'Parar';
    FBtnArrancar.Enabled := True;   { el lanzamiento se queda cerrado }
    if not FCliente.Connected then
      ClicConectar(nil);
    Exit;
  end;

  if FEsperando >= ESPERA_MAXIMA_MS then
  begin
    FRelojArranque.Enabled := False;
    ParaEmulador(FEmulador);
    Arrancando(False);
    FBtnArrancar.Texto := 'Arrancar';
    FLblEstado.Caption := 'el emulador no ha llegado a arrancar';
    MessageDlg('El emulador no ha abierto el puerto ' +
               IntToStr(PUERTO_MODULO) + ' a tiempo.'#13#10#13#10 +
               'Lo último que dijo:'#13#10#13#10 +
               UltimasLineas(FEmulador.Registro, 8),
               mtError, [mbOK], 0);
    Exit;
  end;

  { La primera vez compila los modelos en C# y tarda; conviene decirlo o
    parece que se ha quedado colgado. }
  if FEsperando = 6000 then
    FLblEstado.Caption := 'arrancando el emulador… (la primera vez tarda: ' +
                          'compila los modelos)';
end;

procedure TFormPanel.Manda(const Orden: string);
begin
  if not FCliente.Connected then Exit;
  try
    FCliente.IOHandler.WriteLn(Orden);
  except
    Conectado(False);
  end;
end;

procedure TFormPanel.MandaTecla(Tecla: Integer; Abajo: Boolean);
var
  Rafaga: TRebote;
  i: Integer;
begin
  if not FChkRebotes.Marcada then
  begin
    Manda(OrdenTecla(Tecla, Abajo));
    Exit;
  end;

  { Con rebotes: la rafaga que produce un pulsador de verdad. Un programa
    sin antirrebote contara varias pulsaciones, que es justo lo que la
    Practica 2 ensena a evitar. }
  Rafaga := RafagaDeRebote(Abajo);
  for i := 0 to High(Rafaga) do
  begin
    Manda(OrdenTecla(Tecla, Rafaga[i].Abajo));
    if Rafaga[i].Espera > 0 then
      Sleep(Rafaga[i].Espera);
  end;
end;

{ B1 tambien rebota: es un pulsador mecanico como los del modulo. }
procedure TFormPanel.MandaB1(Abajo: Boolean);
var
  Rafaga: TRebote;
  i: Integer;
begin
  if not FChkRebotes.Marcada then
  begin
    Manda(OrdenB1(Abajo));
    Exit;
  end;
  Rafaga := RafagaDeRebote(Abajo);
  for i := 0 to High(Rafaga) do
  begin
    Manda(OrdenB1(Rafaga[i].Abajo));
    if Rafaga[i].Espera > 0 then Sleep(Rafaga[i].Espera);
  end;
end;

procedure TFormPanel.B1Abajo(Sender: TObject);
begin
  SueltaElFoco;
  MandaB1(True);
end;

procedure TFormPanel.B1Arriba(Sender: TObject);
begin
  MandaB1(False);
end;

procedure TFormPanel.MuevePote(Sender: TObject);
begin
  SueltaElFoco;
  Invalidate;                       { el valor esta pintado en el fondo }
  Manda(OrdenPotenciometro(FPote.Valor));
end;

procedure TFormPanel.Conectado(Si: Boolean);
begin
  if Si then
  begin
    { Se dice el puerto del servidor GDB porque esta siempre levantado y es
      lo que hay que poner en STM32CubeIDE. Es un hecho, no un estado: el
      panel no puede saber si alguien se ha conectado a el. }
    FLblEstado.Caption := 'conectado al simulador  ·  GDB en el puerto ' +
                          IntToStr(PUERTO_GDB);
    FLblEstado.Font.Color := COLOR_ACENTO;
    Invalidate;
  end
  else
  begin
    FLblEstado.Caption := 'sin conexión';
    FLblEstado.Font.Color := COLOR_GRIS600;
    Invalidate;
  end;
end;

procedure TFormPanel.ClicConectar(Sender: TObject);
begin
  if FCliente.Connected then
  begin
    if Assigned(FLector) then
    begin
      FLector.Terminate;
      try FCliente.Disconnect; except end;
      FLector.WaitFor;
      FreeAndNil(FLector);
    end;
    Conectado(False);
    Exit;
  end;

  { El hilo de una conexion que se cayo sola sigue ahi, ya terminado.
    Ahora si se puede esperar por el: nadie esta dentro de Synchronize. }
  if Assigned(FLector) then
  begin
    FLector.WaitFor;
    FreeAndNil(FLector);
  end;

  try
    FCliente.Host := '127.0.0.1';
    FCliente.Port := PUERTO_MODULO;
    FCliente.ConnectTimeout := 3000;
    FCliente.Connect;
    FLector := TLectorThread.Create(FCliente, Self);
    FLector.Start;
    Conectado(True);
  except
    on E: Exception do
    begin
      FLblEstado.Caption := 'no se pudo conectar: ' + E.Message;
      FLblEstado.Font.Color := COLOR_GRIS600;
    end;
  end;
end;

end.


