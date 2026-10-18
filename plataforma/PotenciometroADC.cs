//
// El conversor A/D de la placa, con un potenciometro que se puede mover.
//
// POR QUE NO SE USA EL DE RENODE
//
// Renode trae Analog.STM32_ADC y arranca bien: el firmware lo inicializa y
// lee sin fallar. Pero el modelo NO OFRECE NINGUNA FORMA DE DARLE UN VALOR:
// no expone SetADCValue, y su registro de datos es de solo lectura tambien
// desde el bus. Devuelve siempre cero, asi que la practica 5 se veria correr
// mostrando 0 y 0,0 V para siempre.
//
// Este modelo implementa lo justo que toca la HAL y anade lo que hacia falta:
// un valor que se puede cambiar en marcha, desde el monitor de Renode o desde
// el panel.
//
//   sysbus.adc1 Valor 2048
//
using System;
using Antmicro.Renode.Core;
using Antmicro.Renode.Core.Structure.Registers;
using Antmicro.Renode.Logging;
using Antmicro.Renode.Peripherals.Bus;
using Antmicro.Renode.Peripherals.Timers;
using Antmicro.Renode.Time;

namespace Antmicro.Renode.Peripherals.Analog
{
    // EL DMA LEE DE 16 EN 16 BITS. Un BasicDoubleWordPeripheral solo atiende
    // accesos de 32, asi que la lectura del DMA no llegaba al registro y se
    // transferian ceros: las cuentas bajaban, la memoria no cambiaba, y no
    // habia ningun aviso. Esto le dice al bus que parta los accesos.
    [AllowedTranslations(AllowedTranslation.WordToDoubleWord |
                        AllowedTranslation.ByteToDoubleWord)]
    public class PotenciometroADC : BasicDoubleWordPeripheral, IKnownSize
    {
        public PotenciometroADC(IMachine machine, uint conversionesPorSegundo = 1000)
            : base(machine)
        {
            DMARequest = new GPIO();
            IRQ = new GPIO();

            // EL DISPARO. En la placa, la P6 arranca las conversiones con un
            // temporizador: HAL_TIM_Base_Start(&htim3) y el TRGO de TIM3 se
            // lleva al conversor por hardware. Renode NO MODELA esa conexion,
            // asi que aqui el conversor convierte por su cuenta a un ritmo
            // fijo. Es una simplificacion, y se nota en una cosa: el periodo
            // de muestreo no es el que programe el alumno.
            reloj = new LimitTimer(machine.ClockSource, conversionesPorSegundo,
                                   this, "adc", limit: 1, enabled: false,
                                   eventEnabled: true, autoUpdate: true);
            reloj.LimitReached += Convierte;

            DefineRegisters();
            Reset();
        }

        public GPIO DMARequest { get; private set; }
        public GPIO IRQ { get; private set; }

        private readonly LimitTimer reloj;
        private uint canal;        // cual de la secuencia toca
        private uint nCanales = 1; // cuantos hay en la secuencia
        private bool porDMA;       // CR2 pide transferencia por DMA

        // Un ciclo de conversion: saca por DR el valor del canal que toca y
        // pide al DMA que se lo lleve. Al terminar la secuencia, vuelve a
        // empezar, que es lo que hace el modo continuo.
        private void Convierte()
        {
            if(!porDMA)
            {
                return;
            }

            // MODO CIRCULAR A MANO. El STM32DMA de Renode no implementa el bit
            // CIRC -lo dice el mismo por registro: "Unhandled bits: [8] Tags:
            // CIRC"-, asi que no recarga la cuenta de transferencias ni
            // devuelve la direccion al principio del buffer. En cuanto se
            // agotan las primeras, cada peticion se descarta con
            // "no data to send", y el programa se queda leyendo ceros.
            //
            // Aqui se rehace la cuenta al empezar cada barrido, que es
            // exactamente lo que haria el modo circular.
            if(canal == 0 && RegistroNDTR != 0)
            {
                if(!apuntado)
                {
                    destino = machine.SystemBus.ReadDoubleWord(RegistroM0AR);
                    apuntado = true;
                }
                machine.SystemBus.WriteDoubleWord(RegistroNDTR, nCanales);
                machine.SystemBus.WriteDoubleWord(RegistroM0AR, destino);
            }

            DMARequest.Set(true);
            DMARequest.Set(false);
            canal = (canal + 1) % nCanales;
        }

        // Registros del flujo de DMA que atiende a este conversor. Se pasan
        // desde el .repl porque dependen del cableado: la P6 usa DMA2 flujo 0.
        public ulong RegistroNDTR { get; set; }
        public ulong RegistroM0AR { get; set; }

        private uint destino;      // donde empieza el buffer del programa
        private bool apuntado;     // ya lo hemos anotado

        public long Size { get { return 0x100; } }

        // El valor que devuelve el conversor: 0 a 4095, doce bits.
        // Es lo que en la placa se cambia girando el potenciometro.
        private uint valor;
        public uint Valor
        {
            get { return valor; }
            set
            {
                valor = value > 4095 ? 4095 : value;
                this.Log(LogLevel.Debug, "potenciometro = {0}", valor);
            }
        }

        // Comodidad para el panel y para las clases: en lugar del valor crudo,
        // el porcentaje de giro. 0 es todo a la izquierda, 100 el tope.
        public uint Porcentaje
        {
            get { return valor * 100 / 4095; }
            set { Valor = (value > 100 ? 100 : value) * 4095 / 100; }
        }

        public override void Reset()
        {
            base.Reset();
            valor = 0;
            canal = 0;
            nCanales = 1;
            porDMA = false;
            apuntado = false;
            destino = 0;
            reloj.Enabled = false;
            DMARequest.Unset();
            IRQ.Unset();
        }

        // Los otros dos canales de la secuencia de la P6. No se miden: son
        // valores tipicos del F401 a temperatura ambiente, y sirven para que
        // el programa tenga algo coherente que leer.
        private const uint VREFINT_CRUDO = 1502;   // 1,21 V
        private const uint TEMP_CRUDO    = 943;    // unos 25 grados

        // La P6 recorre VREFINT, sensor de temperatura y potenciometro, en ese
        // orden. Con un solo canal -la P5- siempre es el potenciometro.
        private uint ValorDelCanal()
        {
            if(nCanales <= 1) return valor;
            if(canal == 0)    return VREFINT_CRUDO;
            if(canal == 1)    return TEMP_CRUDO;
            return valor;
        }

        private void DefineRegisters()
        {
            // SR: la conversion se da SIEMPRE por terminada. En la placa hay
            // que esperar unos microsegundos; aqui no hay nada que esperar, y
            // fingir la espera solo aniadiria una fuente de fallos.
            Registers.Estado.Define(this)
                .WithFlag(0, FieldMode.Read, valueProviderCallback: _ => false, name: "AWD")
                .WithFlag(1, FieldMode.Read, valueProviderCallback: _ => true,  name: "EOC")
                .WithFlag(2, FieldMode.Read, valueProviderCallback: _ => true,  name: "JEOC")
                .WithFlag(3, FieldMode.Read, valueProviderCallback: _ => false, name: "JSTRT")
                .WithFlag(4, FieldMode.Read, valueProviderCallback: _ => true,  name: "STRT")
                .WithFlag(5, FieldMode.Read, valueProviderCallback: _ => false, name: "OVR")
                .WithReservedBits(6, 26);

            // La HAL escribe en estos y no lee nada que dependa de ellos.
            Registers.Control1.Define(this).WithValueField(0, 32, name: "CR1");
            // CR2: aqui esta el bit que dice que la conversion va por DMA, y
            // el que enciende el conversor.
            Registers.Control2.Define(this)
                .WithFlag(0, name: "ADON",
                          writeCallback: (_, v) => { reloj.Enabled = v; })
                .WithReservedBits(1, 7)
                .WithFlag(8, name: "DMA", writeCallback: (_, v) => { porDMA = v; })
                .WithFlag(9, name: "DDS")
                .WithTag("resto", 10, 22);
            Registers.Muestreo1.Define(this).WithValueField(0, 32, name: "SMPR1");
            Registers.Muestreo2.Define(this).WithValueField(0, 32, name: "SMPR2");
            // SQR1: los bits 20 a 23 dicen cuantas conversiones tiene la
            // secuencia, menos una.
            Registers.Secuencia1.Define(this)
                .WithValueField(0, 20, name: "SQ13_16")
                .WithValueField(20, 4, name: "L",
                                writeCallback: (_, v) => { nCanales = (uint)v + 1; })
                .WithReservedBits(24, 8);
            Registers.Secuencia2.Define(this).WithValueField(0, 32, name: "SQR2");
            Registers.Secuencia3.Define(this).WithValueField(0, 32, name: "SQR3");

            // DR: aqui esta la diferencia con el modelo de Renode. Leerlo
            // devuelve lo que valga el potenciometro en este momento.
            Registers.Datos.Define(this)
                .WithValueField(0, 16, FieldMode.Read,
                                valueProviderCallback: _ => ValorDelCanal(),
                                name: "DATA")
                .WithReservedBits(16, 16);
        }

        private enum Registers
        {
            Estado     = 0x00,   // SR
            Control1   = 0x04,   // CR1
            Control2   = 0x08,   // CR2
            Muestreo1  = 0x0C,   // SMPR1
            Muestreo2  = 0x10,   // SMPR2
            Secuencia1 = 0x2C,   // SQR1
            Secuencia2 = 0x30,   // SQR2
            Secuencia3 = 0x34,   // SQR3
            Datos      = 0x4C,   // DR
        }
    }
}
