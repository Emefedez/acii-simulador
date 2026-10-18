# -*- coding: utf-8 -*-
"""El dibujo del panel: la placa, el display, los LED y las teclas.

Todo se pinta en un unico lienzo, igual que en el panel de Delphi. Poner las
teclas DENTRO del dibujo es lo que hace que parezca la placa y no un
formulario con botones debajo.

Los colores y la geometria no son nuevos: salen de `Panel/uControles.pas` y
`Panel/uPanel.pas`. Los TColor de Delphi van en BGR, asi que el $3030E0 del
codigo original es el #E03030 de aqui.
"""

# --- colores, de uControles.pas --------------------------------------------
TINTA = '#1D1F20'
ACENTO = '#5980A6'
ACENTO2 = '#769ABF'        # el acento aclarado, para el paso del raton
# El acento HUNDIDO, para lo que esta pulsado. Antes un boton pulsado se
# pintaba con ACENTO2, el mismo color que el paso del raton: con el raton
# encima -que es siempre, porque se esta pulsando- no se distinguia nada.
ACENTO_PULSADO = '#22405F'
ACENTO_SOMBRA = '#3A5675'
ACENTO_TINTA = '#3D6690'   # los rotulos en acento, con contraste para leerse
GRIS100 = '#F5F5F8'
GRIS200 = '#E8E8EB'
GRIS300 = '#D4D4D7'
GRIS400 = '#C4C4C8'
GRIS600 = '#5E5E62'        # texto secundario: el #7A7A7D original se leia mal

# El display se leia mal: rojo apagado sobre una ventanilla casi negra, y los
# segmentos apagados casi tan visibles como los encendidos. Ahora la
# ventanilla es un gris ahumado, el rojo encendido es mas vivo y lleva un
# halo, y los apagados quedan como un fantasma tenue.
ROJO = '#FF4B3A'           # los segmentos encendidos
ROJO_HALO = '#5A2220'      # su resplandor, un poco por fuera
ROJO_OFF = '#34302F'       # y apagados, visibles pero sin competir
PLACA = '#141414'
BISEL = '#2E2E2E'
VENTANILLA = '#24262A'
SERIGRAFIA = '#8A8A8A'     # el #4A4A4A original apenas se veia sobre la placa

TECLA_FONDO = '#383838'
TECLA_ENCIMA = '#4A4A4A'
TECLA_SOMBRA = '#0E0E0E'
TECLA_TEXTO = '#E0E0E0'
TECLA_PULSADA = '#8DB4E2'  # sobre la placa negra el acento normal se queda corto
TECLA_PULSADA_TEXTO = '#0E1A28'

LED_HALO = '#381010'
LED_MEDIO = '#A02020'
LED_CENTRO = '#F05030'
LED_BORDE = '#FF6040'
LED_OFF = '#1E1E1E'
LED_OFF_BORDE = '#303030'

# LD2, el LED verde de la placa. Mismo dibujo que los del modulo, en verde:
# en la NUCLEO es verde, y distinguirlo de un vistazo de los rojos del modulo
# evita confundir de donde viene cada luz.
LD2_HALO = '#0F3818'
LD2_MEDIO = '#20A040'
LD2_CENTRO = '#40F060'
LD2_BORDE = '#70FF90'
# Apagado, sobre el fondo claro de esa zona: el gris oscuro de los LED del
# modulo esta pensado para ir sobre la placa negra y aqui pareceria un agujero.
LD2_OFF = '#C9CCD1'
LD2_OFF_BORDE = '#A9ADB4'

# --- tipos -----------------------------------------------------------------
TIPO_ROTULO = 'Barlow Condensed'
TIPO_TEXTO = 'Barlow'
TIPO_MONO = 'IBM Plex Mono'

# --- geometria, de uPanel.pas ----------------------------------------------
# Son unidades de DISEÑO, no pixeles: el lienzo del panel las escala al tamaño
# de la ventana (ver Lienzo en panel.py). Por eso aqui no se toca nada para las
# pantallas HiDPI.
ANCHO, ALTO = 760, 556
MARGEN = 20
ALTO_PLACA = 268
Y_POTE = MARGEN + ALTO_PLACA + 34
Y_PROGRAMA = Y_POTE + 118
Y_ESTADO = Y_PROGRAMA + 72
ALTO_FILA = 32

N_DIGITOS = 8
N_TECLAS = 8

DIGITO_AN, DIGITO_AL, DIGITO_HUECO = 44, 60, 34
TECLA_AN, TECLA_AL, TECLA_HUECO = 58, 44, 12
ALTO_PASTILLA = 17         # el «mantener» de debajo de cada tecla

SEG_A, SEG_B, SEG_C, SEG_D, SEG_E, SEG_F, SEG_G, SEG_PUNTO = (
    1, 2, 4, 8, 16, 32, 64, 128)


# ---------------------------------------------------------------------------
# Primitivas
# ---------------------------------------------------------------------------
def caja(c, x0, y0, x1, y1, relleno, radio=4, etiqueta=None):
    """Rectangulo de esquinas redondeadas, relleno y sin borde.

    Tk no trae la primitiva `RoundRect` de la GDI: se compone con cuatro
    cuartos de circulo y dos rectangulos, y el resultado es el mismo.
    """
    d = radio * 2
    t = {'fill': relleno, 'outline': relleno}
    if etiqueta:
        t['tags'] = etiqueta
    c.create_arc(x0, y0, x0 + d, y0 + d, start=90, extent=90, **t)
    c.create_arc(x1 - d, y0, x1, y0 + d, start=0, extent=90, **t)
    c.create_arc(x0, y1 - d, x0 + d, y1, start=180, extent=90, **t)
    c.create_arc(x1 - d, y1 - d, x1, y1, start=270, extent=90, **t)
    c.create_rectangle(x0 + radio, y0, x1 - radio, y1, **t)
    c.create_rectangle(x0, y0 + radio, x1, y1 - radio, **t)


def texto(c, x, y, cadena, color, fuente, anclaje='nw', etiqueta=None):
    """Texto normal: teclas, botones, casillas, estado."""
    t = {'text': cadena, 'fill': color, 'font': fuente, 'anchor': anclaje}
    if etiqueta:
        t['tags'] = etiqueta
    return c.create_text(x, y, **t)


# Los rotulos en versalitas van con dos pixeles de aire entre letras. En
# Delphi eso es una llamada a la GDI -SetTextCharacterExtra(Handle, 2)-; Tk
# no tiene equivalente, asi que se dibuja letra a letra. Son rotulos fijos,
# se pintan una vez.
ESPACIADO = 2


def ancho_rotulo(cadena, fuente):
    return sum(fuente.measure(ch) + ESPACIADO for ch in cadena) - ESPACIADO


def rotulo(c, x, y, cadena, color, fuente, anclaje='nw', etiqueta=None):
    """El Rotulo de uControles.pas: en mayusculas y con el aire entre letras."""
    cadena = cadena.upper()
    if anclaje == 'ne':
        x -= ancho_rotulo(cadena, fuente)
    t = {'fill': color, 'font': fuente, 'anchor': 'nw'}
    if etiqueta:
        t['tags'] = etiqueta
    for ch in cadena:
        c.create_text(x, y, text=ch, **t)
        x += fuente.measure(ch) + ESPACIADO


# ---------------------------------------------------------------------------
# El modulo
# ---------------------------------------------------------------------------
def digito(c, x, y, an, al, segmentos, etiqueta=None):
    """Un digito de siete segmentos, con el mismo calculo que PintaDigito.

    Los segmentos apagados NO se dejan en negro: se pintan en gris muy
    oscuro. Un display real se ve entero aunque no este iluminado, y verlo
    ayuda a leer que hay encendido.
    """
    g = 6                    # grosor del segmento
    m = al // 2              # mitad de la altura, donde va el segmento g

    segs = [
        ([x + g, y, x + an - g, y,
          x + an - g - g, y + g, x + g + g, y + g], SEG_A),
        ([x + g, y + m, x + an - g, y + m,
          x + an - g - g, y + m + g, x + g + g, y + m + g], SEG_G),
        ([x + g, y + al, x + an - g, y + al,
          x + an - g - g, y + al + g, x + g + g, y + al + g], SEG_D),
        ([x, y + g, x + g, y + g + g, x + g, y + m - g, x, y + m], SEG_F),
        ([x + an, y + g, x + an - g, y + g + g,
          x + an - g, y + m - g, x + an, y + m], SEG_B),
        ([x, y + m + g, x + g, y + m + g + g,
          x + g, y + al - g, x, y + al], SEG_E),
        ([x + an, y + m + g, x + an - g, y + m + g + g,
          x + an - g, y + al - g, x + an, y + al], SEG_C),
    ]
    punto = (x + an + 6, y + al - 2, x + an + 6 + g + 2, y + al + g)
    tg = {'tags': etiqueta} if etiqueta else {}

    # Primero TODOS los halos y luego los segmentos: si no, el halo de un
    # segmento encendido taparia el borde del vecino ya pintado.
    for puntos, bit in segs:
        if segmentos & bit:
            c.create_polygon(puntos, fill=ROJO_HALO, outline=ROJO_HALO,
                             width=4, joinstyle='round', **tg)
    if segmentos & SEG_PUNTO:
        c.create_oval(punto[0] - 2, punto[1] - 2, punto[2] + 2, punto[3] + 2,
                      fill=ROJO_HALO, outline=ROJO_HALO, **tg)
    for puntos, bit in segs:
        col = ROJO if segmentos & bit else ROJO_OFF
        c.create_polygon(puntos, fill=col, outline=col, **tg)
    col = ROJO if segmentos & SEG_PUNTO else ROJO_OFF
    c.create_oval(*punto, fill=col, outline=col, **tg)


def led(c, x, y, d, encendido, etiqueta=None, verde=False):
    """Un LED. Encendido derrama luz: sin el halo no se lee de un vistazo
    cual esta activo. `verde` es para LD2, el de la placa."""
    tg = {'tags': etiqueta} if etiqueta else {}
    if verde:
        halo, medio, centro, borde = LD2_HALO, LD2_MEDIO, LD2_CENTRO, LD2_BORDE
        off, off_borde = LD2_OFF, LD2_OFF_BORDE
    else:
        halo, medio, centro, borde = LED_HALO, LED_MEDIO, LED_CENTRO, LED_BORDE
        off, off_borde = LED_OFF, LED_OFF_BORDE
    if encendido:
        c.create_oval(x - 5, y - 5, x + d + 5, y + d + 5,
                      fill=halo, outline=halo, **tg)
        c.create_oval(x - 2, y - 2, x + d + 2, y + d + 2,
                      fill=medio, outline=medio, **tg)
        c.create_oval(x, y, x + d, y + d, fill=centro, outline=borde, **tg)
    else:
        c.create_oval(x, y, x + d, y + d, fill=off, outline=off_borde, **tg)


def tecla(c, x, y, an, al, rotulo_tecla, encima, pulsada, fuente,
          etiqueta=None):
    # Una sombra por debajo: hace que la tecla sobresalga de la placa. Al
    # apretarla desaparece Y LA TECLA BAJA a ocuparla, que es lo que se ve
    # como hundirse. Ademas cambia a un azul claro: sobre la placa negra el
    # acento oscuro de antes se confundia con el gris del paso del raton.
    if pulsada:
        y += 3
        caja(c, x - 2, y - 2, x + an + 2, y + al + 2, '#FFFFFF', 6, etiqueta)
        caja(c, x, y, x + an, y + al, TECLA_PULSADA, 5, etiqueta)
        tinta = TECLA_PULSADA_TEXTO
    else:
        caja(c, x, y + 3, x + an, y + al + 3, TECLA_SOMBRA, 5, etiqueta)
        caja(c, x, y, x + an, y + al,
             TECLA_ENCIMA if encima else TECLA_FONDO, 5, etiqueta)
        tinta = TECLA_TEXTO
    texto(c, x + an // 2, y + al // 2, rotulo_tecla, tinta, fuente,
          'center', etiqueta)


def pastilla(c, x, y, an, al, cadena, activa, fuente, oscura, etiqueta=None):
    """El interruptor de «mantener pulsado» de una tecla o de B1.

    Activa va en el acento, con el texto en blanco; inactiva, apagada y con el
    texto en gris. `oscura` es para las de encima de la placa negra."""
    if activa:
        caja(c, x, y, x + an, y + al, ACENTO, al // 2, etiqueta)
        tinta = '#FFFFFF'
    elif oscura:
        caja(c, x, y, x + an, y + al, '#3A3A3A', al // 2, etiqueta)
        caja(c, x + 1, y + 1, x + an - 1, y + al - 1, PLACA, al // 2 - 1,
             etiqueta)
        tinta = '#A8A8A8'
    else:
        caja(c, x, y, x + an, y + al, GRIS400, al // 2, etiqueta)
        caja(c, x + 1, y + 1, x + an - 1, y + al - 1, GRIS100, al // 2 - 1,
             etiqueta)
        tinta = GRIS600
    texto(c, x + an / 2.0, y + al / 2.0, cadena, tinta, fuente, 'center',
          etiqueta)


def x_primer_digito(ancho_placa):
    """La rejilla de digitos y LED va centrada en la placa."""
    return (ancho_placa - (N_DIGITOS * DIGITO_AN
                           + (N_DIGITOS - 1) * DIGITO_HUECO)) // 2


def x_primera_tecla(ancho_placa):
    return (ancho_placa - (N_TECLAS * TECLA_AN
                           + (N_TECLAS - 1) * TECLA_HUECO)) // 2


def caja_tecla(i, x_placa, y_placa, ancho_placa):
    """El rectangulo de la tecla i (1..8), en coordenadas del lienzo."""
    x = x_placa + x_primera_tecla(ancho_placa) + (i - 1) * (TECLA_AN
                                                            + TECLA_HUECO)
    y = y_placa + ALTO_PLACA - 84
    return x, y, x + TECLA_AN, y + TECLA_AL


def caja_pastilla(i, x_placa, y_placa, ancho_placa):
    """El «mantener» de la tecla i, justo debajo de ella."""
    x0, y0, x1, y1 = caja_tecla(i, x_placa, y_placa, ancho_placa)
    return x0 + 4, y1 + 9, x1 - 4, y1 + 9 + ALTO_PASTILLA


def pastilla_en(x, y, x_placa, y_placa, ancho_placa):
    """Sobre que «mantener» de tecla cae el punto, o 0."""
    for i in range(1, N_TECLAS + 1):
        x0, y0, x1, y1 = caja_pastilla(i, x_placa, y_placa, ancho_placa)
        if x0 <= x <= x1 and y0 - 2 <= y <= y1 + 2:
            return i
    return 0


def tecla_en(x, y, x_placa, y_placa, ancho_placa):
    """Sobre que tecla cae el punto, o 0."""
    for i in range(1, N_TECLAS + 1):
        x0, y0, x1, y1 = caja_tecla(i, x_placa, y_placa, ancho_placa)
        if x0 <= x <= x1 and y0 <= y <= y1:
            return i
    return 0
