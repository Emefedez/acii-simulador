unit uControles;

{ Los controles del panel, dibujados a mano.

  Los de VCL no se dejan estilar: un TButton pinta su propio marco en relieve
  y un TTrackBar su propia canaleta, y no hay forma de que se parezcan al
  resto de la asignatura. Estos son TGraphicControl -sin ventana propia, se
  dibujan sobre el formulario- y siguen el mismo sistema visual que los
  documentos: Barlow Condensed en versales para los rotulos, acero #5980A6
  como unico acento, esquinas de 4 px y nada de relieve.

  El formulario va con DoubleBuffered, asi que no parpadean.
}

interface

uses
  Winapi.Windows, Winapi.Messages,
  System.SysUtils, System.Classes, System.Types, System.Math,
  Vcl.Graphics, Vcl.Controls, Vcl.Forms;

const
  { El sistema visual de la asignatura. TColor va en BGR, al reves del hex. }
  COLOR_TINTA   = TColor($201F1D);   { 1D1F20 }
  COLOR_ACENTO  = TColor($A68059);   { 5980A6 }
  COLOR_ACENTO2 = TColor($BF9A76);   { el acento aclarado, para el paso del raton }
  COLOR_GRIS100 = TColor($F8F5F5);   { F5F5F8 }
  COLOR_GRIS200 = TColor($EBE8E8);
  COLOR_GRIS300 = TColor($D7D4D4);   { D4D4D7 }
  COLOR_GRIS400 = TColor($C8C4C4);
  COLOR_GRIS600 = TColor($7D7A7A);   { 7A7A7D }

  COLOR_ROJO    = TColor($3030E0);   { los segmentos encendidos }
  COLOR_ROJO_OFF= TColor($242424);   { y apagados, pero visibles }
  COLOR_PLACA   = TColor($141414);
  COLOR_BISEL   = TColor($2E2E2E);

  TIPO_ROTULO = 'Barlow Condensed';
  TIPO_TEXTO  = 'Barlow';
  TIPO_MONO   = 'IBM Plex Mono';

type
  TEstiloBoton = (ebAcento,      { la accion principal }
                  ebNeutro,      { las secundarias }
                  ebPlaca);      { B1, el pulsador azul de la placa }

  { Un boton plano. Ademas de OnClick tiene OnAbajo y OnArriba, porque los
    pulsadores hay que mandarlos al soltar tambien: el firmware detecta
    flancos y una pulsacion sin su suelta deja la tecla apretada. }
  TBotonPlano = class(TGraphicControl)
  private
    FTexto: string;
    FEstilo: TEstiloBoton;
    FEncima: Boolean;
    FPulsado: Boolean;
    FOnAbajo: TNotifyEvent;
    FOnArriba: TNotifyEvent;
    procedure PonTexto(const V: string);
    procedure PonEstilo(V: TEstiloBoton);
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
                        X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState;
                      X, Y: Integer); override;
    procedure CMMouseEnter(var Msg: TMessage); message CM_MOUSEENTER;
    procedure CMMouseLeave(var Msg: TMessage); message CM_MOUSELEAVE;
    procedure CMEnabledChanged(var Msg: TMessage); message CM_ENABLEDCHANGED;
  public
    constructor Create(AOwner: TComponent); override;
    property Texto: string read FTexto write PonTexto;
    property Estilo: TEstiloBoton read FEstilo write PonEstilo;
    property OnAbajo: TNotifyEvent read FOnAbajo write FOnAbajo;
    property OnArriba: TNotifyEvent read FOnArriba write FOnArriba;
    property OnClick;
    property Hint;
    property ShowHint;
  end;

  { Una casilla de verificacion sin el marco de Windows. }
  TCasilla = class(TGraphicControl)
  private
    FTexto: string;
    FMarcada: Boolean;
    FEncima: Boolean;
    procedure PonTexto(const V: string);
    procedure PonMarcada(V: Boolean);
  protected
    procedure Paint; override;
    procedure Click; override;
    procedure CMMouseEnter(var Msg: TMessage); message CM_MOUSEENTER;
    procedure CMMouseLeave(var Msg: TMessage); message CM_MOUSELEAVE;
  public
    constructor Create(AOwner: TComponent); override;
    property Texto: string read FTexto write PonTexto;
    property Marcada: Boolean read FMarcada write PonMarcada;
    property OnClick;
    property Hint;
    property ShowHint;
  end;

  { El potenciometro: una linea fina y un tirador redondo. }
  TDeslizador = class(TGraphicControl)
  private
    FMin, FMax, FValor: Integer;
    FArrastrando: Boolean;
    FEncima: Boolean;
    FOnCambia: TNotifyEvent;
    procedure PonValor(V: Integer);
    function PosDelTirador: Integer;
    procedure ValorDesdeX(X: Integer);
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
                        X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState;
                      X, Y: Integer); override;
    procedure CMMouseEnter(var Msg: TMessage); message CM_MOUSEENTER;
    procedure CMMouseLeave(var Msg: TMessage); message CM_MOUSELEAVE;
  public
    constructor Create(AOwner: TComponent); override;
    property Min: Integer read FMin write FMin;
    property Max: Integer read FMax write FMax;
    property Valor: Integer read FValor write PonValor;
    property OnCambia: TNotifyEvent read FOnCambia write FOnCambia;
  end;

{ Un rotulo en versales con las letras separadas, como los epigrafes de los
  documentos. Windows no tiene interletraje en el Canvas, pero si un extra
  por caracter. }
procedure Rotulo(C: TCanvas; x, y: Integer; const Texto: string;
                 Color: TColor; Tam: Integer = 8);

{ Lo mismo, pegado al margen derecho: x es el borde donde termina. }
procedure RotuloDer(C: TCanvas; x, y: Integer; const Texto: string;
                    Color: TColor; Tam: Integer = 8);

{ Rectangulo de esquinas redondeadas, relleno y sin borde. }
procedure Caja(C: TCanvas; const R: TRect; Relleno: TColor; Radio: Integer = 4);

implementation

procedure Rotulo(C: TCanvas; x, y: Integer; const Texto: string;
                 Color: TColor; Tam: Integer = 8);
begin
  C.Font.Name := TIPO_ROTULO;
  C.Font.Size := Tam;
  C.Font.Style := [];
  C.Font.Color := Color;
  C.Brush.Style := bsClear;
  SetTextCharacterExtra(C.Handle, 2);
  C.TextOut(x, y, AnsiUpperCase(Texto));
  SetTextCharacterExtra(C.Handle, 0);
  C.Brush.Style := bsSolid;
end;

procedure RotuloDer(C: TCanvas; x, y: Integer; const Texto: string;
                    Color: TColor; Tam: Integer);
var
  Ancho: Integer;
begin
  C.Font.Name := TIPO_ROTULO;
  C.Font.Size := Tam;
  C.Font.Style := [];
  { TextWidth no cuenta el extra por caracter, hay que sumarlo a mano. }
  Ancho := C.TextWidth(AnsiUpperCase(Texto)) + 2 * Length(Texto);
  Rotulo(C, x - Ancho, y, Texto, Color, Tam);
end;

procedure Caja(C: TCanvas; const R: TRect; Relleno: TColor; Radio: Integer);
begin
  C.Brush.Color := Relleno;
  C.Pen.Color := Relleno;
  C.RoundRect(R.Left, R.Top, R.Right, R.Bottom, Radio * 2, Radio * 2);
end;

{ ----------------------------------------------------------- boton --- }

constructor TBotonPlano.Create(AOwner: TComponent);
begin
  inherited;
  Width := 120;
  Height := 32;
  FEstilo := ebNeutro;
end;

procedure TBotonPlano.PonTexto(const V: string);
begin
  if FTexto <> V then
  begin
    FTexto := V;
    Invalidate;
  end;
end;

procedure TBotonPlano.PonEstilo(V: TEstiloBoton);
begin
  if FEstilo <> V then
  begin
    FEstilo := V;
    Invalidate;
  end;
end;

procedure TBotonPlano.Paint;
var
  Fondo, Letra: TColor;
  R: TRect;
  h: Integer;
begin
  R := ClientRect;

  case FEstilo of
    ebAcento:
      begin
        Fondo := COLOR_ACENTO;
        if FPulsado then Fondo := COLOR_TINTA
        else if FEncima then Fondo := COLOR_ACENTO2;
        Letra := clWhite;
      end;
    ebPlaca:
      begin
        { El pulsador de la placa es azul de verdad; aqui es el acento, que
          es el mismo azul acero del resto del material. }
        Fondo := COLOR_ACENTO;
        if FPulsado then Fondo := COLOR_TINTA
        else if FEncima then Fondo := COLOR_ACENTO2;
        Letra := clWhite;
      end;
  else
    begin
      { UN TONO MAS OSCURO QUE LOS CAMPOS DE TEXTO, que son GRIS100. Con el
        mismo gris, un boton plano al lado de un campo no se distingue de
        el: parecen los dos huecos donde escribir. }
      Fondo := COLOR_GRIS200;
      if FPulsado then Fondo := COLOR_GRIS400
      else if FEncima then Fondo := COLOR_GRIS300;
      Letra := COLOR_TINTA;
    end;
  end;

  if not Enabled then
  begin
    Fondo := COLOR_GRIS100;
    Letra := COLOR_GRIS300;
  end;

  Caja(Canvas, R, Fondo);

  Canvas.Font.Name := TIPO_TEXTO;
  Canvas.Font.Size := 10;
  Canvas.Font.Style := [];
  Canvas.Font.Color := Letra;
  Canvas.Brush.Style := bsClear;
  h := Canvas.TextHeight(FTexto);
  Canvas.TextOut((Width - Canvas.TextWidth(FTexto)) div 2,
                 (Height - h) div 2, FTexto);
  Canvas.Brush.Style := bsSolid;
end;

procedure TBotonPlano.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
begin
  inherited;
  if Button <> mbLeft then Exit;
  FPulsado := True;
  Invalidate;
  if Assigned(FOnAbajo) then FOnAbajo(Self);
end;

procedure TBotonPlano.MouseUp(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
begin
  inherited;
  if Button <> mbLeft then Exit;
  FPulsado := False;
  Invalidate;
  if Assigned(FOnArriba) then FOnArriba(Self);
end;

procedure TBotonPlano.CMMouseEnter(var Msg: TMessage);
begin
  inherited;
  FEncima := True;
  Invalidate;
end;

procedure TBotonPlano.CMMouseLeave(var Msg: TMessage);
begin
  inherited;
  FEncima := False;
  { Si se sale con el boton apretado, el MouseUp no llega aqui: hay que
    soltar igual, o la tecla se queda pulsada para siempre. }
  if FPulsado then
  begin
    FPulsado := False;
    if Assigned(FOnArriba) then FOnArriba(Self);
  end;
  Invalidate;
end;

procedure TBotonPlano.CMEnabledChanged(var Msg: TMessage);
begin
  inherited;
  Invalidate;
end;

{ ---------------------------------------------------------- casilla --- }

constructor TCasilla.Create(AOwner: TComponent);
begin
  inherited;
  Width := 300;
  Height := 22;
end;

procedure TCasilla.PonTexto(const V: string);
begin
  FTexto := V;
  Invalidate;
end;

procedure TCasilla.PonMarcada(V: Boolean);
begin
  if FMarcada <> V then
  begin
    FMarcada := V;
    Invalidate;
  end;
end;

procedure TCasilla.Paint;
var
  R: TRect;
  y: Integer;
begin
  y := (Height - 16) div 2;
  R := Rect(0, y, 16, y + 16);

  if FMarcada then
    Caja(Canvas, R, COLOR_ACENTO, 3)
  else
  begin
    Caja(Canvas, R, COLOR_GRIS100, 3);
    Canvas.Brush.Style := bsClear;
    if FEncima then
      Canvas.Pen.Color := COLOR_GRIS600
    else
      Canvas.Pen.Color := COLOR_GRIS300;
    Canvas.RoundRect(R.Left, R.Top, R.Right, R.Bottom, 6, 6);
    Canvas.Brush.Style := bsSolid;
  end;

  if FMarcada then
  begin
    Canvas.Pen.Color := clWhite;
    Canvas.Pen.Width := 2;
    Canvas.MoveTo(R.Left + 4, R.Top + 8);
    Canvas.LineTo(R.Left + 7, R.Top + 11);
    Canvas.LineTo(R.Left + 12, R.Top + 5);
    Canvas.Pen.Width := 1;
  end;

  Canvas.Font.Name := TIPO_TEXTO;
  Canvas.Font.Size := 10;
  Canvas.Font.Style := [];
  Canvas.Font.Color := COLOR_TINTA;
  Canvas.Brush.Style := bsClear;
  Canvas.TextOut(24, (Height - Canvas.TextHeight(FTexto)) div 2, FTexto);
  Canvas.Brush.Style := bsSolid;
end;

procedure TCasilla.Click;
begin
  FMarcada := not FMarcada;
  Invalidate;
  inherited;
end;

procedure TCasilla.CMMouseEnter(var Msg: TMessage);
begin
  inherited;
  FEncima := True;
  Invalidate;
end;

procedure TCasilla.CMMouseLeave(var Msg: TMessage);
begin
  inherited;
  FEncima := False;
  Invalidate;
end;

{ ------------------------------------------------------- deslizador --- }

constructor TDeslizador.Create(AOwner: TComponent);
begin
  inherited;
  Width := 400;
  Height := 28;
  FMin := 0;
  FMax := 4095;
  FValor := 0;
end;

procedure TDeslizador.PonValor(V: Integer);
begin
  if V < FMin then V := FMin;
  if V > FMax then V := FMax;
  if FValor <> V then
  begin
    FValor := V;
    Invalidate;
    if Assigned(FOnCambia) then FOnCambia(Self);
  end;
end;

function TDeslizador.PosDelTirador: Integer;
begin
  if FMax = FMin then Exit(9);
  Result := 9 + MulDiv(FValor - FMin, Width - 18, FMax - FMin);
end;

procedure TDeslizador.ValorDesdeX(X: Integer);
begin
  if Width <= 18 then Exit;
  PonValor(FMin + MulDiv(X - 9, FMax - FMin, Width - 18));
end;

procedure TDeslizador.Paint;
var
  cy, px: Integer;
begin
  cy := Height div 2;
  px := PosDelTirador;

  { la canaleta, y la parte recorrida en acento }
  Caja(Canvas, Rect(9, cy - 2, Width - 9, cy + 2), COLOR_GRIS300, 2);
  if px > 9 then
    Caja(Canvas, Rect(9, cy - 2, px, cy + 2), COLOR_ACENTO, 2);

  { el tirador }
  Canvas.Brush.Color := COLOR_ACENTO;
  Canvas.Pen.Color := COLOR_ACENTO;
  Canvas.Ellipse(px - 8, cy - 8, px + 8, cy + 8);
  if FEncima or FArrastrando then
  begin
    Canvas.Brush.Color := clWhite;
    Canvas.Pen.Color := clWhite;
    Canvas.Ellipse(px - 3, cy - 3, px + 3, cy + 3);
  end;
end;

procedure TDeslizador.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
begin
  inherited;
  if Button <> mbLeft then Exit;
  FArrastrando := True;
  ValorDesdeX(X);
end;

procedure TDeslizador.MouseMove(Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  if FArrastrando then ValorDesdeX(X);
end;

procedure TDeslizador.MouseUp(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
begin
  inherited;
  FArrastrando := False;
  Invalidate;
end;

procedure TDeslizador.CMMouseEnter(var Msg: TMessage);
begin
  inherited;
  FEncima := True;
  Invalidate;
end;

procedure TDeslizador.CMMouseLeave(var Msg: TMessage);
begin
  inherited;
  FEncima := False;
  Invalidate;
end;

end.
