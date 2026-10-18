//
// Un puerto GPIO de la STM32F4 que SI distingue entrada de salida.
//
// POR QUE NO SE USA EL DE RENODE
//
// El GPIOPort.STM32_GPIOPort de Renode no modela el registro MODER: el
// registro de salida manda siempre sobre el de entrada. Medido: se pone un
// pin a 1 desde fuera y el IDR lo refleja, pero en cuanto el firmware escribe
// un 0 en su ODR, el IDR vuelve a 0 aunque el pin siga siendo entrada.
//
// Eso rompe dos cosas de esta asignatura:
//
//   1. LA LINEA DIO DEL TM1638, que es bidireccional. Al leer el teclado, el
//      firmware pasa el pin a entrada y manda el chip. Con el modelo de
//      Renode, el ultimo bit que quedo en el ODR -un cero, porque la orden de
//      lectura es 0x42- tapa lo que ponga el modulo, y las teclas no llegan.
//
//   2. TODA ENTRADA SIN NADA CONECTADO. En la placa, B1 lleva pull-up y en
//      reposo lee 1. En Renode lee 0, asi que el firmware cree el pulsador
//      apretado desde el arranque. No falla: hace otra cosa, que es peor.
//
// Este modelo resuelve las dos: el IDR sale del ODR solo si el pin es salida,
// y si es entrada sale de lo que haya fuera o, si no hay nada, de la
// resistencia de polarizacion que diga PUPDR.
//
using System;
using System.Collections.Generic;
using System.Linq;
using Antmicro.Renode.Core;
using Antmicro.Renode.Core.Structure.Registers;
using Antmicro.Renode.Logging;
using Antmicro.Renode.Peripherals.Bus;
using Antmicro.Renode.Peripherals.GPIOPort;

namespace Antmicro.Renode.Peripherals.GPIOPort
{
    [AllowedTranslations(AllowedTranslation.WordToDoubleWord |
                        AllowedTranslation.ByteToDoubleWord)]
    // Hereda de BaseGPIOPort, que es la clase de Renode para puertos: aporta
    // las conexiones de salida, el estado de las entradas y -lo que hacia
    // falta- el poder registrar un LED o un pulsador colgando de un pin.
    public class PuertoGPIO : BaseGPIOPort, IDoubleWordPeripheral, IKnownSize
    {
        public const int Pines = 16;

        // moderReset y pupdrReset: los valores de reinicio del puerto, que en
        // la F401 no son cero en GPIOA (PA13-PA15, el depurador) ni en GPIOB
        // (PB3-PB4). pullUpsExternos: pines con una resistencia a 3,3 V EN LA
        // PLACA, que leen 1 aunque el firmware no active la interna. En la
        // NUCLEO solo es PC13, el de B1.
        public PuertoGPIO(IMachine machine, uint moderReset = 0,
                          uint pupdrReset = 0, uint pullUpsExternos = 0)
            : base(machine, Pines)
        {
            this.moderReset = moderReset;
            this.pupdrReset = pupdrReset;
            this.pullUpsExternos = pullUpsExternos & 0xFFFFu;
            registros = new DoubleWordRegisterCollection(this);
            DefineRegisters();
            Reset();
        }

        public long Size { get { return 0x400; } }

        private readonly DoubleWordRegisterCollection registros;

        public uint ReadDoubleWord(long offset)
        {
            return registros.Read(offset);
        }

        public void WriteDoubleWord(long offset, uint value)
        {
            registros.Write(offset, value);
        }

        private readonly uint moderReset, pupdrReset, pullUpsExternos;
        private uint moder, pupdr, odr;
        // Que pines tienen algo conectado, y a que nivel.
        //
        // EL NIVEL SE GUARDA AQUI, NO EN EL State[] DE BaseGPIOPort. Medido:
        // fiandose de State[], un valor sostenido se perdia. Un periferico que
        // mantiene un pin alto varios ciclos solo genera UN aviso -los GPIO de
        // Renode solo propagan cambios- y el nivel dejaba de reflejarse.
        // Guardandolo aqui, cada lectura del IDR ve el ultimo nivel conocido,
        // haya habido aviso o no.
        // Como mascaras de bits y no como arrays: el IDR se lee muy a menudo
        // -el TM1638 se maneja pin a pin- y armarlo pin a pin salia caro.
        private uint hayFuera;      // pines con algo conectado
        private uint nivelFuera;    // a que nivel lo tienen

        // MODER y PUPDR, ya digeridos a un bit por pin. Se rehacen al
        // escribirlos, que pasa cuatro veces en el arranque, y no en cada
        // lectura del IDR, que pasa cientos de miles de veces. Calcularlas
        // dentro de LeeIDR se probo y costo un tercio de la velocidad.
        private uint mascaraSalidas;
        private uint mascaraPullUp;

        private void RehazMascaras()
        {
            uint sal = 0, pu = 0;
            for(var i = 0; i < Pines; i++)
            {
                if(((moder >> (2 * i)) & 3) == 1) sal |= 1u << i;
                if(((pupdr >> (2 * i)) & 3) == 1) pu  |= 1u << i;
            }
            mascaraSalidas = sal;
            mascaraPullUp = pu;
        }

        private readonly int[] recibidos = new int[Pines];
        private readonly int[] altos = new int[Pines];
        private readonly int[] comoSalida = new int[Pines];

        public string Recibido
        {
            get
            {
                var s = "";
                for(var i = 0; i < Pines; i++)
                {
                    if(recibidos[i] > 0)
                    {
                        s += string.Format(
                            "pin {0}: {1} avisos, {2} altos, {3} con el pin declarado SALIDA.  ",
                            i, recibidos[i], altos[i], comoSalida[i]);
                    }
                }
                return s == "" ? "nadie ha movido ningun pin" : s;
            }
        }

        public override void Reset()
        {
            base.Reset();
            registros.Reset();
            moder = moderReset;
            pupdr = pupdrReset;
            odr = 0;
            // Lo que cuelga de una resistencia de la placa esta a 1 desde el
            // primer instante. Antes esto se forzaba para el pin 13 de TODOS
            // los puertos, y PA13 o PB13 leian 1 sin nada conectado.
            hayFuera = pullUpsExternos;
            nivelFuera = pullUpsExternos;
            RehazMascaras();
        }

        private bool EsSalida(int pin)
        {
            return ((mascaraSalidas >> pin) & 1) != 0;
        }

        // 01 = pull-up, 10 = pull-down, 00 = al aire
        private int Polarizacion(int pin)
        {
            return (int)((pupdr >> (2 * pin)) & 3);
        }

        // AQUI ESTA TODO. El valor que lee el programa en el IDR.
        private bool NivelDelPin(int pin)
        {
            if(EsSalida(pin))
            {
                return ((odr >> pin) & 1) != 0;
            }
            if(((hayFuera >> pin) & 1) != 0)
            {
                return ((nivelFuera >> pin) & 1) != 0;   // manda quien este conectado
            }
            if(Polarizacion(pin) == 1)
            {
                return true;               // pull-up: en reposo, uno
            }
            return false;                  // pull-down, o al aire
        }

        public int lecturasIDR, lecturasCon5Alto;

        public string Leido
        {
            get { return string.Format("{0} lecturas del IDR, {1} con el pin 5 en alto",
                                       lecturasIDR, lecturasCon5Alto); }
        }

        // El IDR entero de una vez, con mascaras. Es la misma regla que
        // NivelDelPin, escrita para los dieciseis pines a la vez:
        //   salida            -> lo que diga el ODR
        //   entrada conectada  -> lo que ponga quien este conectado
        //   entrada al aire    -> 1 si hay pull-up, 0 si no
        private uint LeeIDR()
        {
            var entradas = (~mascaraSalidas) & 0xFFFFu;

            var v = (odr & mascaraSalidas)
                  | (entradas & hayFuera & nivelFuera)
                  | (entradas & ~hayFuera & mascaraPullUp);

            lecturasIDR++;
            if((v & (1u << 5)) != 0) lecturasCon5Alto++;
            return v;
        }

        // Un periferico o un pulsador mueve un pin de este puerto.
        public override void OnGPIO(int numero, bool valor)
        {
            if(numero < 0 || numero >= Pines)
            {
                this.Log(LogLevel.Warning, "pin fuera de rango: {0}", numero);
                return;
            }
            base.OnGPIO(numero, valor);

            // Y AL EXTI. Sin esta linea el nivel se apunta para el IDR -o
            // sea, se puede leer por sondeo- pero no llega al controlador de
            // interrupciones, porque Connections solo se movia desde el ODR
            // y solo para los pines de salida. Resultado: el pulsador se lee
            // bien preguntando por el, y no genera ninguna interrupcion.
            if(!EsSalida(numero))
            {
                Connections[numero].Set(valor);
            }

            hayFuera |= 1u << numero;
            if(valor) nivelFuera |=  1u << numero;
            else      nivelFuera &= ~(1u << numero);
            recibidos[numero]++;
            if(valor) altos[numero]++;
            if(EsSalida(numero)) comoSalida[numero]++;
        }

        // Pulsar un boton desde el monitor, sin necesidad de un periferico:
        //   gpioPortC Pulsa 13 true
        public void Pulsa(int pin, bool abajo)
        {
            OnGPIO(pin, !abajo);           // los pulsadores van a masa
        }

        // Al escribir en el ODR hay que avisar a lo que cuelgue del pin: los
        // LED, el modulo, lo que sea. Solo de los pines que son salida.
        private void PropagaSalidas(uint anterior)
        {
            // SOLO LOS BITS QUE HAN CAMBIADO. Recorrer los dieciseis pines en
            // cada escritura sale caro: el TM1638 se maneja moviendo pines a
            // mano, y son cientos de miles de escrituras por segundo. Medido:
            // con el bucle completo, la emulacion iba a 33 MIPS.
            var cambios = anterior ^ odr;
            while(cambios != 0)
            {
                var bit = cambios & (uint)(-(int)cambios);   // el mas bajo
                var i = 0;
                var t = bit;
                while(t > 1) { t >>= 1; i++; }
                cambios ^= bit;
                if(i < Pines && EsSalida(i))
                {
                    Connections[i].Set((odr & bit) != 0);
                }
            }
        }

        private void DefineRegisters()
        {
            registros.DefineRegister((long)Registers.Modo)
                .WithValueField(0, 32, name: "MODER",
                                valueProviderCallback: _ => moder,
                                writeCallback: (_, v) => { moder = (uint)v; RehazMascaras(); });

            registros.DefineRegister((long)Registers.Polaridad)
                .WithValueField(0, 32, name: "PUPDR",
                                valueProviderCallback: _ => pupdr,
                                writeCallback: (_, v) => { pupdr = (uint)v; RehazMascaras(); });

            registros.DefineRegister((long)Registers.Entrada)
                .WithValueField(0, 32, FieldMode.Read, name: "IDR",
                                valueProviderCallback: _ => LeeIDR());

            registros.DefineRegister((long)Registers.Salida)
                .WithValueField(0, 32, name: "ODR",
                                valueProviderCallback: _ => odr,
                                writeCallback: (_, v) =>
                                {
                                    var antes = odr;
                                    odr = (uint)v;
                                    PropagaSalidas(antes);
                                });

            // BSRR: los 16 bits bajos ponen a uno, los altos a cero. Es como
            // escribe la HAL, y por eso tiene que estar.
            registros.DefineRegister((long)Registers.PonYQuita)
                .WithValueField(0, 32, FieldMode.Write, name: "BSRR",
                                writeCallback: (_, v) =>
                                {
                                    var antes = odr;
                                    odr |=  (uint)(v & 0xFFFF);
                                    odr &= ~(uint)((v >> 16) & 0xFFFF);
                                    PropagaSalidas(antes);
                                });

            // Los que la HAL escribe y de los que no depende nada aqui.
            registros.DefineRegister((long)Registers.Tipo).WithValueField(0, 32, name: "OTYPER");
            registros.DefineRegister((long)Registers.Velocidad).WithValueField(0, 32, name: "OSPEEDR");
            registros.DefineRegister((long)Registers.Bloqueo).WithValueField(0, 32, name: "LCKR");
            registros.DefineRegister((long)Registers.FuncionBaja).WithValueField(0, 32, name: "AFRL");
            registros.DefineRegister((long)Registers.FuncionAlta).WithValueField(0, 32, name: "AFRH");
        }

        private enum Registers
        {
            Modo        = 0x00,   // MODER
            Tipo        = 0x04,   // OTYPER
            Velocidad   = 0x08,   // OSPEEDR
            Polaridad   = 0x0C,   // PUPDR
            Entrada     = 0x10,   // IDR
            Salida      = 0x14,   // ODR
            PonYQuita   = 0x18,   // BSRR
            Bloqueo     = 0x1C,   // LCKR
            FuncionBaja = 0x20,   // AFRL
            FuncionAlta = 0x24,   // AFRH
        }
    }
}
