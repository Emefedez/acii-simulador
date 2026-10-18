# El socket entre Renode y el panel

El periférico `TM1638Panel` abre un servidor TCP en **127.0.0.1:3939**. El panel se conecta
como cliente. Texto plano, una línea por mensaje, terminada en `\n`.

Está pensado para escribirse con **Indy 10** —`TIdTCPClient`— sin más dependencias.

## Del simulador al panel: el estado

Se envía **una línea cada vez que cambia algo**, y también al conectarse, para que el panel
pinte el estado actual sin esperar.

Dos precisiones que importan al escribir el panel:

- La línea sale **cuando el módulo cierra la trama** (cuando STB vuelve a subir), nunca a
  mitad. El chip real tampoco enseña nada hasta ese momento. Un simulador que publique byte a
  byte manda tramas a medio escribir y el display **parpadea**.
- **Una trama idéntica a la anterior no se reenvía.** El firmware refresca el display sin
  parar —en la placa también—, y sin este filtro se mandarían centenares de líneas por
  segundo, todas iguales.

```
D 0058795050775E77 L 10000000 B 7 O 1 G 0
```

| Campo | Qué es |
| --- | --- |
| `D` | **16 dígitos hexadecimales**: los ocho bytes de segmentos, de izquierda a derecha |
| `L` | **8 caracteres `0` o `1`**: los ocho LEDs, de izquierda a derecha |
| `B` | **Brillo**, de 0 a 7 |
| `O` | **1** si el display está encendido, **0** si apagado |
| `G` | **1** si **LD2**, el LED verde de la placa (PA5), está encendido, **0** si apagado |

**`G` no es del módulo.** LD2 va directo a un pin del microcontrolador, como B1, pero viaja
por este socket porque es el único canal del panel. Sin él, la Práctica 1 —que consiste en
hacer parpadear LD2— se ejecutaba bien y en el panel no se veía nada. Un cambio de LD2 manda
línea aunque el módulo no haya cambiado.

`G` va **al final** para que un lector que solo mire los ocho primeros trozos siga
funcionando. El panel lo trata como **opcional**: si no llega, LD2 se pinta apagado.

Cada byte de `D` son los siete segmentos más el punto decimal, en el orden del TM1638:

```
   bit 0  a  (segmento de arriba)        aaa
   bit 1  b  (arriba derecha)           f   b
   bit 2  c  (abajo derecha)            f   b
   bit 3  d  (abajo)                     ggg
   bit 4  e  (abajo izquierda)          e   c
   bit 5  f  (arriba izquierda)         e   c
   bit 6  g  (el del medio)              ddd  h
   bit 7  h  (el punto decimal)
```

Así que **el panel no necesita saber qué letra es**: enciende los segmentos cuyo bit vale 1.
Es exactamente lo que hace el hardware, y evita mantener dos tablas de caracteres.

## Del panel al simulador: las teclas

Una línea por cambio. Nada más:

```
K3 1     <- se ha pulsado la tecla 3
K3 0     <- se ha soltado
```

Las teclas van de **K1 a K8**, de izquierda a derecha, como en el módulo.

⚠️ **Manda el 1 y el 0 por separado.** El firmware detecta flancos, así que una pulsación sin
su suelta deja la tecla apretada para siempre.

## Del panel al simulador: el potenciómetro

```
P 2048     <- el cursor a la mitad del recorrido
```

El valor va de **0 a 4095**, los doce bits del conversor, igual que en la placa. Mándalo cada
vez que el mando se mueva; el simulador se queda con el último.

## Del panel al simulador: el pulsador de la placa

```
B1 1     <- pulsado
B1 0     <- soltado
```

**B1 es el pulsador azul de la placa, no una tecla del módulo.** Está en PC13, va directo al
microcontrolador y no pasa por el TM1638. En el panel conviene presentarlo aparte de S1..S8,
porque son cosas distintas aunque las dos se pulsen.

Lleva pull-up: en reposo el pin lee **1**, y al pulsar lee **0**. El simulador ya hace esa
inversión, así que el panel manda `B1 1` cuando el usuario aprieta.

## Un detalle que conviene aprovechar

En la placa, un pulsador **rebota**: al cerrarse produce durante unos milisegundos una ráfaga
de pulsos, y filtrarla es medio contenido de la Práctica 2. Un panel que mande un solo `K3 1`
limpio **no reproduce eso**, y un programa sin antirrebote parecerá correcto en el simulador y
fallará en el laboratorio.

Merece la pena que el panel tenga una casilla **«simular rebotes»** que, al pulsar, mande la
ráfaga: cinco o seis transiciones en unos 20 ms antes de quedarse quieta. Con eso el simulador
enseña lo mismo que la placa en vez de esconderlo.

## Esqueleto en Delphi

```pascal
// Recibir el estado
procedure TFormPanel.IdTCPClient1Connected(Sender: TObject);
begin
  // el simulador manda el estado nada mas conectarse
end;

procedure TFormPanel.LeeEstado;
var
  linea: string;
  p: TArray<string>;
begin
  linea := IdTCPClient1.IOHandler.ReadLn;
  p := linea.Split([' ']);
  // p[0]='D'  p[1]=segmentos  p[2]='L'  p[3]=leds  p[4]='B'  p[5]=brillo ...
  PintaSegmentos(p[1]);
  PintaLeds(p[3]);
end;

// Enviar una tecla
procedure TFormPanel.BotonAbajo(indice: Integer);
begin
  IdTCPClient1.IOHandler.WriteLn(Format('K%d 1', [indice]));
end;
```

La lectura va **en un hilo**: `ReadLn` bloquea, y bloquear el hilo principal congela la
ventana.

Y el hilo **no debe pintar**. Que deje la última línea en una variable protegida y que un
reloj del formulario, a 25 repintados por segundo, recoja la que haya. Sincronizar con el
hilo principal una vez por línea lo ahoga: la ventana deja de repintarse y el display sale en
blanco.
