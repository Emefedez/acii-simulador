# El panel multiplataforma

El mismo panel del simulador, en Python y Tkinter, para que funcione también
en **Linux** y en **macOS**. El de Delphi (`../Panel/`) sigue siendo el de
Windows; este no lo sustituye, lo acompaña.

## Por qué no valía el de Delphi

Está escrito con la **VCL**, que es de Windows y solo de Windows, y además
llama a la API del sistema directamente (`CreateProcess`,
`WaitForSingleObject`). Portarlo a Lazarus habría sido traducir 2.400 líneas,
de las cuales la mayoría son dibujo a mano.

Y ahí está lo que hizo barata esta versión: `uControles.pas` declara los
botones, las casillas y el deslizador como `TGraphicControl`, es decir, **ya
estaban dibujados a mano**. De controles nativos solo había una caja de texto.
Un `Canvas` de Tk reproduce ese dibujo punto por punto, así que el argumento
habitual contra Tkinter —que se ve anticuado— aquí no aplica.

## Qué hay aquí

| Fichero | Qué es |
| --- | --- |
| `panel.py` | La ventana: sucesos, teclado, ratón y el latido de repintado |
| `dibujo.py` | El dibujo: placa, dígitos, LED, teclas. Colores y geometría de `uPanel.pas` |
| `modulo.py` | El socket con el simulador. El protocolo está en `../PROTOCOLO.md` |
| `emulador.py` | Arrancar y parar Renode, y dónde está cada cosa en cada sistema |
| `cubeide.py` | La configuración de depuración que se deja dentro del proyecto |
| `tipografias.py` | Carga las tipografías del paquete, sin instalarlas |
| `tipografias/` | Barlow, Barlow Condensed e IBM Plex Mono, con su licencia OFL |

## Cómo se lanza

```
python panel.py [programa.elf]
```

En Linux, `./simulador-acii.sh`, que comprueba antes que estén Python y
Tkinter y dice qué instalar si faltan. `./instalar.sh` lo deja en el menú de
aplicaciones de la cuenta; `sudo ./desplegar-laboratorio.sh`, en el de todas.

**Lo único que hay que instalar aparte es Renode, y tiene que ser la 1.16.1.** En Windows ya no hace falta: desde la 1.2.0 va dentro del paquete. Aquí el panel, `instalar.sh` y `diagnostico.py` avisan si la versión es otra.

## Las tres decisiones que no son evidentes

**Las tipografías se cargan, no se instalan.** No se puede dar por hecho que
estén: en la máquina donde se escribió esto, Barlow estaba instalada «por
usuario» en Windows y Tk seguía sin verla. `tipografias.py` las mete en el
proceso, con la API que corresponde a cada sistema —`AddFontResourceEx` en
Windows, `FcConfigAppFontAddFile` en Linux y
`CTFontManagerRegisterFontsForURL` en macOS— y no deja rastro en el sistema.
**En macOS no vale fontconfig**: su Tk dibuja con CoreText y no se entera.
Instalarlas de verdad es cosa de los guiones de instalación.

**El hilo lector no pinta.** Deja la última línea en una variable protegida y
el latido, veinticinco veces por segundo, recoge la que haya. Es lo que ya
decía `PROTOCOLO.md`: sincronizar una vez por línea ahoga la interfaz, porque
llegan centenares por segundo.

**En Linux, Renode se mata por grupo de procesos.** El `renode` de Linux es un
guion de shell que lanza mono; matando solo el guion queda vivo el hijo, que
es justamente quien tiene el puerto abierto, y el siguiente arranque falla con
«ya hay un simulador corriendo». Por eso se lanza con `start_new_session` y se
mata con `killpg`.

## Lo que está probado y lo que no

Los tres sistemas, de extremo a extremo y **desde el paquete que se entrega**,
no desde el árbol de trabajo:

| | Windows 11 | Debian 13 | macOS 26 |
| --- | --- | --- | --- |
| Arrancar Renode desde el panel | 6 s | 6 s | 3 s |
| Las teclas llegan al programa | sí | sí | sí |
| Parar, y volver a arrancar | sí | sí | sí |
| Al parar no queda proceso ni puerto ocupado | sí | sí | sí |
| Las tres tipografías, cargadas del paquete | sí | sí | sí |
| Mantener una tecla manda UNA pulsación | sí | sí | sí |
| El instalador deja lanzador y tipografías | — | sí | sí |
| Versión de Tk | 8.6 | 8.6 | **9.0.4** |

Debian fue la WSL2 del equipo de trabajo, con WSLg; macOS, un Mac mini M4 por
SSH. Renode se probó con el **portable** en Linux
(`renode-1.16.1.linux-portable-dotnet`) y con el **DMG oficial arm64** en Mac.
Con el `.deb` de Linux, que instala un guion de shell que lanza otro proceso,
el matar por grupo debería seguir valiendo —está escrito para eso— pero **no
se ha probado**.

## Lo que solo apareció al probar en cada sistema

**En Linux, los `.sh` iban con fin de línea de Windows.** El `#!/bin/sh`
llevaba pegado un retorno de carro y la respuesta era «required file not
found», que no dice nada. Ahora el empaquetador los fuerza a fin de línea de
Unix al copiarlos, porque cualquier editor de Windows vuelve a meterlo y no se
ve hasta que alguien lo ejecuta.

**En Linux, el teclado se leía por el carácter y no por el `keysym`.** El
carácter no siempre llega. Ahora se mira el keysym primero, y de paso valen
las teclas del teclado numérico.

**En macOS, las tipografías no cargaban.** `carga()` devolvía `False` y Tk no
veía ninguna: su Tk usa CoreText, no fontconfig. Ahora se registran con
`CTFontManagerRegisterFontsForURL`.

**En macOS, `busca_renode()` apuntaba al fichero equivocado**, al
`macos_run.command`, que es el de doble clic y abre una ventana de Terminal.
El bueno es el `renode` de dentro del paquete de la aplicación.

**En macOS, el python3 del sistema trae Tk 8.5**, obsoleto. Los guiones ya no
buscan «un python3» sino uno cuyo Tk sea 8.6 o superior, y si no lo hay dicen
cómo instalarlo. Por eso el alumnado de Mac necesita el Python de Homebrew o
el de python.org.

**Y en Windows, un bloqueo intermitente al parar**: se cerraba el objeto de
`makefile()` mientras el hilo lector tenía su cerrojo. Ahora se trocean las
líneas sobre `recv` y se cierra el socket, que desbloquea la lectura.

## Cambios locales (octubre de 2026)

- **La ventana escala.** El lienzo dibuja en unidades de diseño (760 × 556) y
  las lleva al tamaño de la ventana, que ahora se puede estirar: la placa la
  llena sin deformarse. La escala inicial sale de GDK_SCALE o de los ppp de X
  (`ACII_ESCALA=1.5` la impone). Letra algo mayor y textos con más contraste.
- **«mantener» debajo de cada tecla y de B1** (o clic derecho sobre ella): la
  deja pulsada hasta volver a tocarla, para avanzar paso a paso en el
  depurador con el botón apretado. Sustituye a la casilla global.
- **Pulsado se ve.** B1 pulsado baja, se oscurece y dice «B1 · pulsado»; las
  teclas pulsadas pasan a azul claro con filete blanco.
- **«Esperar al depurador» funciona**: la máquina no echa a andar hasta que
  GDB se engancha a localhost:3333.
- **PuertoGPIO**: el parche que ponía a 1 el pin 13 lo hacía en TODOS los
  puertos (PA13, PB13…). Ahora es `pullUpsExternos` en el `.repl`, solo para
  PC13 (B1), y PUPDR arranca con el valor de reinicio real (`pupdrReset`).
- `panel.py --arrancar --esperar --ordenes`: ver el principio de `panel.py`.
  `--ordenes` es lo que usa la extensión ST-Link Auto Debug de VS Code.
  Avisa también del puerto del monitor de Renode (`@monitor N`), para que
  la extensión lo encuentre en cualquier sistema (antes lo buscaba en `/proc`).

Copia de antes de estos cambios: `~/Downloads/ACII_Simulador-before-claude-20261012.tar.gz`.
- **El display se lee mejor**: ventanilla gris ahumado (#24262A) en vez de
  casi negra, rojo encendido más vivo (#FF4B3A) con halo, y los segmentos
  apagados más tenues.
