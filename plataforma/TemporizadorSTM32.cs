//
// TIM2 de la STM32F4: un temporizador que SI hace caso a lo que le escriben.
//
// POR QUE NO SE USA EL DE RENODE
//
// El Timers.STM32_Timer que trae Renode arranca -acepta CR1, DIER y las
// escrituras de la HAL sin quejarse- pero NO APLICA EL VALOR DE RECARGA. Se
// queda con el initialLimit del .repl y cuenta hasta ahi. Medido con la
// Practica 6: ARR valia 9999 y el contador iba por 100.472, o sea que nunca
// desbordaba y la interrupcion no llegaba jamas.
//
// El efecto es de los malos: el programa arranca, pinta, no da ningun error,
// y sencillamente no avanza. Las practicas 4, 6 y 7 se quedaban asi.
//
// LO QUE HACE ESTE
//
// Prescalador y recarga como en el chip:
//
//     periodo = frecuencia / ((PSC + 1) * (ARR + 1))
//
// que es exactamente la formula del capitulo 8 del libro. Al escribir
// cualquiera de los dos, el periodo se recalcula.
//
using System;
using Antmicro.Renode.Core;
using Antmicro.Renode.Core.Structure.Registers;
using Antmicro.Renode.Logging;
using Antmicro.Renode.Peripherals.Bus;
using Antmicro.Renode.Time;

namespace Antmicro.Renode.Peripherals.Timers
{
    public class TemporizadorSTM32 : BasicDoubleWordPeripheral, IKnownSize
    {
        public TemporizadorSTM32(IMachine machine, ulong frecuencia = 84000000)
            : base(machine)
        {
            this.frecuencia = frecuencia;
            IRQ = new GPIO();

            reloj = new LimitTimer(machine.ClockSource, frecuencia, this, "tim",
                                   limit: 0xFFFFFFFF, direction: Direction.Ascending,
                                   enabled: false, eventEnabled: true,
                                   autoUpdate: true);
            reloj.LimitReached += Desborde;

            DefineRegisters();
            Reset();
        }

        public long Size { get { return 0x400; } }
        public GPIO IRQ { get; private set; }

        private readonly ulong frecuencia;
        private readonly LimitTimer reloj;
        private uint psc, arr = 0xFFFFFFFF;
        private bool habilitado, interrumpe, pendiente;

        public override void Reset()
        {
            base.Reset();
            psc = 0;
            arr = 0xFFFFFFFF;
            habilitado = interrumpe = pendiente = false;
            reloj.Enabled = false;
            IRQ.Unset();
        }

        private void Desborde()
        {
            pendiente = true;
            if(interrumpe)
            {
                IRQ.Set(true);
            }
        }

        // Lo que hace que este modelo funcione y el otro no: cada vez que
        // cambia el prescalador o la recarga, se rehace la cuenta.
        private void Recalcula()
        {
            reloj.Enabled = false;
            reloj.Divider = (ulong)(psc + 1);
            reloj.Limit = (ulong)arr + 1;
            reloj.Enabled = habilitado;
            this.Log(LogLevel.Debug,
                     "TIM: psc={0} arr={1} -> {2} Hz", psc, arr,
                     frecuencia / ((double)(psc + 1) * (arr + 1)));
        }

        private void DefineRegisters()
        {
            Registers.Control1.Define(this)
                .WithFlag(0, name: "CEN",
                          writeCallback: (_, v) => { habilitado = v; reloj.Enabled = v; },
                          valueProviderCallback: _ => habilitado)
                .WithTag("resto", 1, 31);

            Registers.HabilitaIRQ.Define(this)
                .WithFlag(0, name: "UIE",
                          writeCallback: (_, v) =>
                          {
                              interrumpe = v;
                              if(!v) IRQ.Unset();
                          },
                          valueProviderCallback: _ => interrumpe)
                .WithTag("resto", 1, 31);

            // SR: el bit de desbordamiento. Escribir un 0 lo borra, que es lo
            // que hace la HAL al atender la interrupcion.
            Registers.Estado.Define(this)
                .WithFlag(0, name: "UIF",
                          valueProviderCallback: _ => pendiente,
                          writeCallback: (_, v) =>
                          {
                              if(!v) { pendiente = false; IRQ.Unset(); }
                          })
                .WithTag("resto", 1, 31);

            Registers.Cuenta.Define(this)
                .WithValueField(0, 32, name: "CNT",
                                valueProviderCallback: _ => (uint)reloj.Value,
                                writeCallback: (_, v) => reloj.Value = v);

            Registers.Prescalador.Define(this)
                .WithValueField(0, 16, name: "PSC",
                                valueProviderCallback: _ => psc,
                                writeCallback: (_, v) => { psc = (uint)v; Recalcula(); })
                .WithReservedBits(16, 16);

            Registers.Recarga.Define(this)
                .WithValueField(0, 32, name: "ARR",
                                valueProviderCallback: _ => arr,
                                writeCallback: (_, v) => { arr = (uint)v; Recalcula(); });

            // La HAL toca estos al inicializar y no lee nada que dependa de
            // ellos: basta con aceptarlos sin quejarse.
            Registers.Control2.Define(this).WithValueField(0, 32, name: "CR2");
            Registers.Esclavo.Define(this).WithValueField(0, 32, name: "SMCR");
            Registers.Evento.Define(this).WithValueField(0, 32, name: "EGR");
            Registers.Division.Define(this).WithValueField(0, 32, name: "RCR");
        }

        private enum Registers
        {
            Control1     = 0x00,   // CR1
            Control2     = 0x04,   // CR2
            Esclavo      = 0x08,   // SMCR
            HabilitaIRQ  = 0x0C,   // DIER
            Estado       = 0x10,   // SR
            Evento       = 0x14,   // EGR
            Cuenta       = 0x24,   // CNT
            Prescalador  = 0x28,   // PSC
            Recarga      = 0x2C,   // ARR
            Division     = 0x30,   // RCR
        }
    }
}
