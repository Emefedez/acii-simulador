//
// TM1638 para Renode: el modulo LED&KEY, simulado.
//
// Renode compila este fichero al vuelo con  include @TM1638Panel.cs
//
// POR QUE EN C# Y NO EN PYTHON
//
// Los perifericos en Python de Renode estan MAPEADOS EN MEMORIA: responden a
// lecturas y escrituras del bus. El TM1638 no esta mapeado: se maneja moviendo
// tres pines a mano, asi que hace falta recibir cambios de GPIO, y eso solo lo
// permite un periferico en C#.
//
// LO QUE HACE
//
// Escucha STB, CLK y DIO, decodifica el protocolo de tres hilos, mantiene los
// 16 bytes de RAM del display y sirve el estado por un socket TCP para que lo
// pinte un panel externo. Las pulsaciones llegan por ese mismo socket.
//
// UNA DIFERENCIA CON LA PLACA, Y ES A FAVOR
//
// En la placa el ancho del pulso de reloj depende del numero de instrucciones
// que hay entre subir y bajar CLK, y por eso la biblioteca no se puede tocar.
// Aqui eso desaparece: se reacciona a FLANCOS, no a tiempos. Un alumno puede
// reescribir la biblioteca y seguira funcionando en el simulador aunque en la
// placa no lo hiciera. Conviene saberlo antes de sacar conclusiones.
//
using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using Antmicro.Renode.Core;
using Antmicro.Renode.Logging;
using Antmicro.Renode.Peripherals;

namespace Antmicro.Renode.Peripherals.Miscellaneous
{
    public class TM1638Panel : IGPIOReceiver, INumberedGPIOOutput, IDisposable
    {
        // Los tres hilos, en el orden en que se conectan desde el .repl
        public const int PinSTB = 0;
        public const int PinCLK = 1;
        public const int PinDIO = 2;

        // LD2, el LED verde de la NUCLEO en PA5. NO es del modulo, pero va por
        // este mismo socket porque es el unico canal que tiene el panel: sin
        // esto, la P1 -que consiste en hacer parpadear LD2- no enseñaba nada en
        // el simulador. El LED si conmutaba dentro del emulador; lo que faltaba
        // era verlo.
        public const int PinLD2 = 3;

        public TM1638Panel(IMachine machine, int puerto = 3939)
        {
            this.machine = machine;
            this.puerto = puerto;
            Connections = new Dictionary<int, IGPIO> { { 0, new GPIO() } };
            Reset();
            ArrancaServidor();
        }

        // ------------------------------------------------------------ estado
        private readonly IMachine machine;
        private readonly int puerto;
        private readonly byte[] ram = new byte[16];   // pares: digitos, impares: LEDs
        private readonly object candado = new object();

        private bool stb = true, clk = true, dio;
        private bool ld2;
        private int bits;            // bits recibidos del byte en curso
        private byte enCurso;        // byte que se esta montando
        private int indice;          // que byte de la orden llevamos
        private byte orden;          // primer byte de la trama
        private int direccion;       // donde escribe la siguiente escritura
        private bool autoIncrementa = true;
        private bool encendido;
        private byte brillo = 7;
        private byte teclas;         // los ocho pulsadores, uno por bit
        private bool leyendo;        // estamos devolviendo el teclado
        private int bitLeido;        // cual de los 32 bits toca

        // Instrumentacion: para el PRIMER barrido en el que hay una tecla
        // pulsada, se anota en que flanco se afirma y cuantos flancos tuvo el
        // barrido entero. Es lo unico que faltaba por medir.
        private int flancoAfirmado = -1;
        private int flancosDelBarrido = -1;
        private bool barridoAnotado;

        public string Barrido
        {
            get
            {
                return string.Format(
                    "se afirmo en el flanco {0}; el barrido tuvo {1} flancos",
                    flancoAfirmado, flancosDelBarrido);
            }
        }

        // De la matriz del chip al orden natural S1..S8.
        //
        // SIN RESOLVER: el firmware lee los unos que ponemos -medido, 309
        // veces- y aun asi no reconoce la tecla. Se probaron los cuatro
        // desplazamientos posibles del indice y ninguno funciono. Estos son
        // los indices que documenta la biblioteca; ver el LEEME.
        private static readonly int[] IndiceDeTecla =
            { 0, 8, 16, 24, 4, 12, 20, 28 };

        public IReadOnlyDictionary<int, IGPIO> Connections { get; }

        // El conversor, para que el panel pueda mover el potenciometro por el
        // mismo socket. Se enlaza desde el .repl con  Conversor: adc1
        public IPeripheral Conversor { get; set; }

        // El puerto donde vive B1, el pulsador azul de la placa. NO es una
        // tecla del modulo -esas son S1 a S8- pero el panel las presenta
        // juntas porque para quien usa el simulador son lo mismo: cosas que
        // se pulsan. Se enlaza con  Pulsador: gpioPortC  y  PinPulsador: 13
        public IPeripheral Pulsador { get; set; }
        public int PinPulsador { get; set; }

        public void Reset()
        {
            lock(candado)
            {
                Array.Clear(ram, 0, ram.Length);
                bits = indice = direccion = 0;
                enCurso = orden = 0;
                stb = clk = true;
                dio = false;
                autoIncrementa = true;
                encendido = false;
                brillo = 7;
                teclas = 0;
                leyendo = false;
                bitLeido = 0;
                flancoAfirmado = -1;
                flancosDelBarrido = -1;
                barridoAnotado = false;
            }
        }

        // ------------------------------------------------- el protocolo
        public void OnGPIO(int numero, bool valor)
        {
            lock(candado)
            {
                switch(numero)
                {
                case PinDIO:
                    dio = valor;
                    return;

                case PinLD2:
                    // Se publica en cuanto cambia, y no al cerrar una trama del
                    // modulo como el resto: la P1 no toca el TM1638 nunca, asi
                    // que esperando a una trama LD2 no llegaria jamas al panel.
                    if(ld2 != valor)
                    {
                        ld2 = valor;
                        Publica();
                    }
                    return;

                case PinSTB:
                    // STB baja: empieza una orden. STB sube: termina.
                    if(stb && !valor)
                    {
                        bits = 0; indice = 0; enCurso = 0;
                        leyendo = false; bitLeido = 0;
                    }
                    else if(!stb && valor)
                    {
                        if(flancoAfirmado >= 0 && !barridoAnotado)
                        {
                            flancosDelBarrido = bitLeido;
                            barridoAnotado = true;
                        }
                        leyendo = false;
                        Connections[0].Unset();
                        // LA TRAMA SE HA CERRADO: AHORA SI SE PUEDE PUBLICAR.
                        // Publicando byte a byte se mandaban tramas a medio
                        // escribir y el panel las pintaba: el display salia
                        // parpadeando. El chip real tampoco ensena nada hasta
                        // que STB vuelve a subir.
                        Publica();
                    }
                    stb = valor;
                    return;

                case PinCLK:
                    // Leyendo el teclado: ahora manda el chip. En cada flanco
                    // de subida se pone en DIO el bit que toca, y el firmware
                    // lo lee justo despues.
                    if(leyendo && !clk && valor)
                    {
                        var pulsada = false;
                        for(var k = 0; k < 8; k++)
                        {
                            if(IndiceDeTecla[k] == bitLeido && (teclas & (1 << k)) != 0)
                            {
                                pulsada = true;
                            }
                        }
                        // Renode deja que el ODR del MCU pise el valor que
                        // ponga un periferico, y no modela el cambio del pin a
                        // entrada. Asi que para que el firmware LEA algo hay
                        // que escribir el propio ODR del puerto.
                        if(pulsada && !barridoAnotado && flancoAfirmado < 0)
                        {
                            flancoAfirmado = bitLeido;
                        }
                        PonDIO(pulsada);
                        Connections[0].Set(pulsada);
                        if(pulsada) nPuestos++;
                        bitLeido++;
                        if(bitLeido > maxBits) maxBits = bitLeido;
                        clk = valor;
                        return;
                    }

                    // El chip captura en el flanco de SUBIDA, y el bit menos
                    // significativo va primero.
                    if(!stb && !clk && valor)
                    {
                        if(dio)
                        {
                            enCurso |= (byte)(1 << bits);
                        }
                        bits++;
                        if(bits == 8)
                        {
                            ByteRecibido(enCurso);
                            bits = 0; enCurso = 0; indice++;
                        }
                    }
                    clk = valor;
                    return;
                }
            }
        }

        // El ODR del puerto donde vive DIO. Se pasa desde el .repl porque
        // depende del cableado de la placa.
        public ulong RegistroDIO { get; set; }
        public int BitDIO { get; set; }

        private void PonDIO(bool alto)
        {
            if(RegistroDIO == 0) return;
            var v = machine.SystemBus.ReadDoubleWord(RegistroDIO);
            if(alto) v |= (uint)(1 << BitDIO);
            else     v &= ~(uint)(1 << BitDIO);
            machine.SystemBus.WriteDoubleWord(RegistroDIO, v);
        }

        private void ByteRecibido(byte b)
        {
            if(indice == 0)
            {
                orden = b;
                switch(b & 0xC0)
                {
                case 0x40:                       // orden de datos
                    autoIncrementa = (b & 0x04) == 0;
                    if((b & 0x02) != 0)          // 0x42: leer el teclado
                    {
                        leyendo = true;
                        bitLeido = 0;

                        nLecturas++;
                    }
                    break;
                case 0xC0:                       // orden de direccion
                    direccion = b & 0x0F;
                    break;
                case 0x80:                       // control del display
                    encendido = (b & 0x08) != 0;
                    brillo = (byte)(b & 0x07);
                    break;
                }
                return;
            }

            // bytes siguientes: solo tienen sentido tras una orden de direccion
            if((orden & 0xC0) == 0xC0)
            {
                ram[direccion & 0x0F] = b;
                if(autoIncrementa)
                {
                    direccion = (direccion + 1) & 0x0F;
                }
            }
        }

        // --------------------------------------------------- el socket
        private TcpListener oyente;
        private Thread hilo;
        private volatile bool corriendo;
        private readonly List<TcpClient> clientes = new List<TcpClient>();

        private void ArrancaServidor()
        {
            corriendo = true;
            hilo = new Thread(Escucha) { IsBackground = true, Name = "TM1638Panel" };
            hilo.Start();
        }

        private void Escucha()
        {
            try
            {
                oyente = new TcpListener(IPAddress.Loopback, puerto);
                oyente.Start();
                while(corriendo)
                {
                    var c = oyente.AcceptTcpClient();
                    lock(clientes) { clientes.Add(c); }
                    var t = new Thread(() => Atiende(c)) { IsBackground = true };
                    t.Start();
                    Publica(true);
                }
            }
            catch(Exception e)
            {
                if(corriendo)
                {
                    this.Log(LogLevel.Warning, "TM1638Panel: el servidor se ha caido: {0}", e.Message);
                }
            }
        }

        // El panel manda una linea por pulsacion:  K<n> 1  /  K<n> 0
        private void Atiende(TcpClient c)
        {
            try
            {
                var flujo = c.GetStream();
                var buf = new byte[128];
                var linea = new StringBuilder();
                int n;
                while(corriendo && (n = flujo.Read(buf, 0, buf.Length)) > 0)
                {
                    for(var i = 0; i < n; i++)
                    {
                        var ch = (char)buf[i];
                        if(ch == '\n')
                        {
                            Tecla(linea.ToString().Trim());
                            linea.Clear();
                        }
                        else if(ch != '\r')
                        {
                            linea.Append(ch);
                        }
                    }
                }
            }
            catch { }
            finally
            {
                lock(clientes) { clientes.Remove(c); }
                try { c.Close(); } catch { }
            }
        }

        // El panel tambien mueve el potenciometro por este mismo socket, para
        // no obligarle a abrir dos conexiones. La orden es:  P <0..4095>
        private void Potenciometro(string valor)
        {
            int v;
            if(!int.TryParse(valor, out v)) return;
            if(Conversor == null)
            {
                this.Log(LogLevel.Warning,
                         "llego un valor de potenciometro y no hay conversor conectado");
                return;
            }
            try
            {
                Conversor.GetType().GetProperty("Valor")
                         .SetValue(Conversor, (uint)(v < 0 ? 0 : v));
            }
            catch(Exception e)
            {
                this.Log(LogLevel.Warning, "no se pudo mover el potenciometro: {0}",
                         e.Message);
            }
        }

        // B1, el pulsador de la placa:  B1 1  /  B1 0
        private void BotonPlaca(string valor)
        {
            if(Pulsador == null)
            {
                this.Log(LogLevel.Warning,
                         "llego una pulsacion de B1 y no hay puerto conectado");
                return;
            }
            try
            {
                Pulsador.GetType().GetMethod("Pulsa")
                        .Invoke(Pulsador, new object[] { PinPulsador, valor == "1" });
            }
            catch(Exception e)
            {
                this.Log(LogLevel.Warning, "no se pudo pulsar B1: {0}", e.Message);
            }
        }

        private void Tecla(string linea)
        {
            var p = linea.Split(' ');
            if(p.Length != 2) return;
            if(p[0] == "P")
            {
                Potenciometro(p[1]);
                return;
            }
            if(p[0] == "B1")
            {
                BotonPlaca(p[1]);
                return;
            }
            if(p[0].Length < 2 || p[0][0] != 'K') return;
            int k;
            if(!int.TryParse(p[0].Substring(1), out k) || k < 1 || k > 8) return;
            lock(candado)
            {
                if(p[1] == "1") teclas |= (byte)(1 << (k - 1));
                else            teclas &= (byte)~(1 << (k - 1));
            }
            this.Log(LogLevel.Debug, "TM1638Panel: tecla {0} = {1}", k, p[1]);
        }

        // Estado en una linea, facil de leer desde cualquier lenguaje:
        //   D <16 bytes en hex> L <8 bits> B <brillo> O <0|1>
        // La ultima linea que se mando. El firmware refresca el display sin
        // parar -en la placa tambien-, y sin esto se estarian mandando
        // centenares de lineas por segundo todas iguales.
        private string ultimaLinea;

        private void Publica(bool forzar = false)
        {
            string linea;
            lock(candado)
            {
                var sb = new StringBuilder("D ");
                for(var i = 0; i < 16; i += 2) sb.AppendFormat("{0:X2}", ram[i]);
                sb.Append(" L ");
                for(var i = 1; i < 16; i += 2) sb.Append((ram[i] & 1) != 0 ? '1' : '0');
                // El campo G va AL FINAL a proposito: un panel antiguo que solo
                // lea hasta O sigue funcionando, simplemente no ve LD2.
                sb.AppendFormat(" B {0} O {1} G {2}\n", brillo, encendido ? 1 : 0,
                                ld2 ? 1 : 0);
                linea = sb.ToString();
                if(!forzar && linea == ultimaLinea)
                {
                    return;
                }
                ultimaLinea = linea;
            }
            var datos = Encoding.ASCII.GetBytes(linea);
            lock(clientes)
            {
                foreach(var c in clientes.ToList())
                {
                    try { c.GetStream().Write(datos, 0, datos.Length); }
                    catch { clientes.Remove(c); }
                }
            }
        }

        // Pulsar desde el propio Renode, sin panel:
        //   gpioPortA.tm1638 Pulsa 1 true
        public int nLecturas, maxBits, nPuestos;
        public string Diag { get { return string.Format(
            "lecturas {0}  bits por lectura {1}  bits puestos a 1: {2}",
            nLecturas, maxBits, nPuestos); } }

        // Aislar el camino de vuelta: pone DIO a mano y se mira el IDR.
        public void Prueba(bool valor)
        {
            Connections[0].Set(valor);
        }

        public void Pulsa(int tecla, bool abajo)
        {
            if(tecla < 1 || tecla > 8) return;
            lock(candado)
            {
                if(abajo) teclas |= (byte)(1 << (tecla - 1));
                else      teclas &= (byte)~(1 << (tecla - 1));
            }
        }

        // Para verificar desde el propio Renode, sin panel:
        //   tm1638 Texto
        public string Texto
        {
            get
            {
                lock(candado)
                {
                    var sb = new StringBuilder();
                    for(var i = 0; i < 16; i += 2) sb.Append(ASegmentos(ram[i]));
                    return sb.ToString();
                }
            }
        }

        // Los bytes en crudo. Sirve para depurar el propio periferico: si el
        // texto sale raro, esto dice si el fallo esta en el protocolo o en la
        // tabla de segmentos.
        public string Hex
        {
            get
            {
                lock(candado)
                {
                    return string.Join(" ", ram.Select(x => x.ToString("X2")));
                }
            }
        }

        public string Leds
        {
            get
            {
                lock(candado)
                {
                    var sb = new StringBuilder();
                    for(var i = 1; i < 16; i += 2) sb.Append((ram[i] & 1) != 0 ? '*' : '.');
                    return sb.ToString();
                }
            }
        }

        // La tabla de la biblioteca, al reves: de segmentos a caracter. Solo
        // sirve para poder LEER el display en las pruebas; el panel dibuja los
        // segmentos y no necesita esto.
        private static char ASegmentos(byte s)
        {
            switch(s & 0x7F)
            {
            case 0x3F: return '0'; case 0x06: return '1'; case 0x5B: return '2';
            case 0x4F: return '3'; case 0x66: return '4'; case 0x6D: return '5';
            case 0x7D: return '6'; case 0x07: return '7'; case 0x7F: return '8';
            case 0x6F: return '9'; case 0x00: return ' '; case 0x08: return '_';
            case 0x40: return '-'; case 0x77: return 'A'; case 0x39: return 'C';
            case 0x79: return 'E'; case 0x71: return 'F'; case 0x76: return 'H';
            case 0x0E: return 'J'; case 0x38: return 'L'; case 0x73: return 'P';
            case 0x3E: return 'U'; case 0x5F: return 'a'; case 0x7C: return 'b';
            case 0x58: return 'c'; case 0x5E: return 'd'; case 0x74: return 'h';
            case 0x04: return 'i'; case 0x54: return 'n'; case 0x5C: return 'o';
            case 0x50: return 'r'; case 0x78: return 't'; case 0x1C: return 'u';
            case 0x6E: return 'y';
            default:   return '?';
            }
        }

        public void Dispose()
        {
            corriendo = false;
            try { if(oyente != null) oyente.Stop(); } catch { }
            lock(clientes)
            {
                foreach(var c in clientes) { try { c.Close(); } catch { } }
                clientes.Clear();
            }
        }
    }
}
