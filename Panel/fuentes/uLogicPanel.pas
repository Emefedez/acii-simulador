unit uLogicPanel;

{ Lo que el panel sabe del modulo LED&KEY, sin nada de interfaz.

  Aqui vive el estado que llega por el socket y la traduccion de la linea de
  texto que manda el simulador. El formulario solo dibuja.

  El protocolo esta en ..\PROTOCOLO.md. En una linea:

    D 0058795050775E77 L 10000000 B 7 O 1
}

interface

uses
  System.SysUtils, System.Classes;

const
  N_DIGITOS = 8;
  N_LEDS    = 8;
  N_TECLAS  = 8;

  { Los siete segmentos mas el punto, en el orden del TM1638. El panel no
    necesita saber que letra es: enciende los bits que valgan 1. }
  SEG_A = $01;  SEG_B = $02;  SEG_C = $04;  SEG_D = $08;
  SEG_E = $10;  SEG_F = $20;  SEG_G = $40;  SEG_PUNTO = $80;

type
  TEstadoModulo = record
    Segmentos: array[0..N_DIGITOS - 1] of Byte;
    Leds:      array[0..N_LEDS - 1] of Boolean;
    Brillo:    Integer;
    Encendido: Boolean;
    { LD2, el LED verde de la placa en PA5. No es del modulo, pero viaja por
      el mismo socket porque es el unico canal del panel. Sin el, la P1 -que
      es hacer parpadear LD2- se ejecutaba bien y no se veia nada. }
    LD2:       Boolean;
  end;

{ Traduce una linea del simulador. Devuelve False si la linea no tiene la
  forma esperada, y entonces el estado se deja como estaba: mas vale no
  pintar que pintar basura. }
function LeeEstado(const Linea: string; var Estado: TEstadoModulo): Boolean;

{ Las ordenes que van al simulador. }
function OrdenTecla(Tecla: Integer; Abajo: Boolean): string;
function OrdenPotenciometro(Valor: Integer): string;
{ B1 es el pulsador AZUL DE LA PLACA, no una tecla del modulo. El panel los
  presenta juntos porque para quien usa el simulador son lo mismo -cosas que
  se pulsan-, pero en la placa estan en sitios distintos: S1 a S8 van al
  TM1638 y B1 va directo a un pin del microcontrolador. }
function OrdenB1(Abajo: Boolean): string;

{ El rebote de un pulsador, para quien quiera probarlo.

  En la placa, un pulsador no se cierra de golpe: rebota unos milisegundos y
  produce una rafaga de pulsos. Filtrarla es medio contenido de la Practica 2.
  Un panel que mande una pulsacion limpia NO reproduce eso, y un programa sin
  antirrebote parecera correcto aqui y fallara en el laboratorio.

  Devuelve la rafaga como una lista de (nivel, milisegundos de espera). }
type
  TReboteItem = record
    Abajo: Boolean;
    Espera: Integer;
  end;
  TRebote = array of TReboteItem;

function RafagaDeRebote(Abajo: Boolean): TRebote;

implementation

function HexAByte(const S: string; Pos: Integer): Byte;
begin
  Result := StrToIntDef('$' + Copy(S, Pos, 2), 0);
end;

function LeeEstado(const Linea: string; var Estado: TEstadoModulo): Boolean;
var
  Trozos: TArray<string>;
  i: Integer;
  Hex, Bits: string;
begin
  Result := False;

  { D <16 hex> L <8 bits> B <n> O <0|1> [G <0|1>]  ->  ocho trozos, o diez }
  Trozos := Linea.Trim.Split([' ']);
  if Length(Trozos) < 8 then Exit;
  if (Trozos[0] <> 'D') or (Trozos[2] <> 'L') or
     (Trozos[4] <> 'B') or (Trozos[6] <> 'O') then Exit;

  Hex  := Trozos[1];
  Bits := Trozos[3];
  if (Length(Hex) <> N_DIGITOS * 2) or (Length(Bits) <> N_LEDS) then Exit;

  for i := 0 to N_DIGITOS - 1 do
    Estado.Segmentos[i] := HexAByte(Hex, i * 2 + 1);

  for i := 0 to N_LEDS - 1 do
    Estado.Leds[i] := Bits[i + 1] = '1';

  Estado.Brillo    := StrToIntDef(Trozos[5], 7);
  Estado.Encendido := Trozos[7] = '1';

  { «G» va al final y es opcional: un simulador anterior no lo manda, y
    entonces LD2 se queda apagado en vez de invalidar la linea entera. }
  Estado.LD2 := (Length(Trozos) >= 10) and (Trozos[8] = 'G') and
                (Trozos[9] = '1');
  Result := True;
end;

function OrdenTecla(Tecla: Integer; Abajo: Boolean): string;
begin
  if Abajo then
    Result := Format('K%d 1', [Tecla])
  else
    Result := Format('K%d 0', [Tecla]);
end;

function OrdenPotenciometro(Valor: Integer): string;
begin
  if Valor < 0 then Valor := 0;
  if Valor > 4095 then Valor := 4095;
  Result := Format('P %d', [Valor]);
end;

function OrdenB1(Abajo: Boolean): string;
begin
  if Abajo then Result := 'B1 1' else Result := 'B1 0';
end;

function RafagaDeRebote(Abajo: Boolean): TRebote;
begin
  { Seis transiciones en unos 20 ms, y despues el nivel bueno. Son numeros
    del mismo orden que los de un pulsador real; lo que importa no es el
    valor exacto sino que haya rafaga. }
  SetLength(Result, 7);

  Result[0].Abajo := Abajo;      Result[0].Espera := 2;
  Result[1].Abajo := not Abajo;  Result[1].Espera := 3;
  Result[2].Abajo := Abajo;      Result[2].Espera := 2;
  Result[3].Abajo := not Abajo;  Result[3].Espera := 4;
  Result[4].Abajo := Abajo;      Result[4].Espera := 3;
  Result[5].Abajo := not Abajo;  Result[5].Espera := 2;
  Result[6].Abajo := Abajo;      Result[6].Espera := 0;   { el definitivo }
end;

end.
