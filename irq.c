#include "kernel.h"

/* ── Assembly ISR entry points ────────────────────────────── */
extern void __cdecl isr_exc_0(void);
extern void __cdecl isr_exc_1(void);
extern void __cdecl isr_exc_2(void);
extern void __cdecl isr_exc_3(void);
extern void __cdecl isr_exc_4(void);
extern void __cdecl isr_exc_5(void);
extern void __cdecl isr_exc_6(void);
extern void __cdecl isr_exc_7(void);
extern void __cdecl isr_exc_8(void);
extern void __cdecl isr_exc_9(void);
extern void __cdecl isr_exc_10(void);
extern void __cdecl isr_exc_11(void);
extern void __cdecl isr_exc_12(void);
extern void __cdecl isr_exc_13(void);
extern void __cdecl isr_exc_14(void);
extern void __cdecl isr_exc_15(void);
extern void __cdecl isr_exc_16(void);

extern void __cdecl isr_irq_0(void);
extern void __cdecl isr_irq_1(void);
extern void __cdecl isr_irq_2(void);
extern void __cdecl isr_irq_3(void);
extern void __cdecl isr_irq_4(void);
extern void __cdecl isr_irq_5(void);
extern void __cdecl isr_irq_6(void);
extern void __cdecl isr_irq_7(void);
extern void __cdecl isr_irq_8(void);
extern void __cdecl isr_irq_9(void);
extern void __cdecl isr_irq_10(void);
extern void __cdecl isr_irq_11(void);
extern void __cdecl isr_irq_12(void);
extern void __cdecl isr_irq_13(void);
extern void __cdecl isr_irq_14(void);
extern void __cdecl isr_irq_15(void);

extern void __cdecl syscall_entry(void);
extern void __cdecl pic_remap(void);
extern void __cdecl idt_set_gate(u16 vector, u16 offset, u16 selector, u8 type_attr);
extern u8 __cdecl serial_getchar(void);
extern u16 floppy_irq_flag;

static const char *exc_names[] = {
    "Divide error",
    "Debug",
    "NMI",
    "Breakpoint",
    "Overflow",
    "Bound range",
    "Invalid opcode",
    "No coprocessor",
    "Double fault",
    "Coprocessor overrun",
    "Invalid TSS",
    "Segment not present",
    "Stack fault",
    "General protection",
    "Page fault",
    "Reserved",
    "x87 FPU error"
};

/* Exception handler — called from assembly stubs */
void __cdecl fault_handler(u16 vector)
{
    kputs("\r\n*** EXCEPTION ");
    print_hex_byte((u8)vector);
    kputs(": ");
    if (vector <= 16) {
        kputs(exc_names[vector]);
    } else {
        kputs("Unknown");
    }
    kputs(" ***\r\nSystem halted.\r\n");
    khalt();
}

/* IRQ handler — called from assembly stubs */
void __cdecl irq_handler(u16 irq)
{
    if (irq == 6) {
        floppy_irq_flag = 1;
    }
    /* other IRQs silently acknowledged by the stub's EOI */
}

/* Syscall dispatcher — called from the INT 0x80 assembly stub */
u16 __cdecl syscall_dispatch(u16 ax, u16 bx)
{
    u8 num = (u8)(ax >> 8);
    u8 param = (u8)ax;

    switch (num) {
    case SYS_EXIT:
        /* Return to caller via a special return mechanism.
           We set a flag that the exec loop checks. The IRET in
           the stub returns to the code after the CALL in the loader,
           which then checks the flag. For simplicity, the exit
           syscall performs a far-ish return by manipulating the
           return. Since we can't easily unwind from an ISR back
           to the kernel's call site, the program should just
           use RET instead. SYS_EXIT is treated as equivalent to RET. */
        break;
    case SYS_PUTCHAR:
        kputch((char)param);
        break;
    case SYS_GETCHAR:
        return (u16)serial_getchar();
    case SYS_PUTS:
        kputs((const char *)bx);
        break;
    }
    return 0;
}

/* Set up the IDT with proper exception, IRQ, and syscall handlers */
static void install_idt(void)
{
    u16 i;
    typedef void (__cdecl *isr_fn)(void);

    /* Exception handlers 0-16 */
    static const isr_fn exc_table[] = {
        isr_exc_0,  isr_exc_1,  isr_exc_2,  isr_exc_3,
        isr_exc_4,  isr_exc_5,  isr_exc_6,  isr_exc_7,
        isr_exc_8,  isr_exc_9,  isr_exc_10, isr_exc_11,
        isr_exc_12, isr_exc_13, isr_exc_14, isr_exc_15,
        isr_exc_16
    };

    /* IRQ handlers 0-15 -> vectors 0x20-0x2F */
    static const isr_fn irq_table[] = {
        isr_irq_0,  isr_irq_1,  isr_irq_2,  isr_irq_3,
        isr_irq_4,  isr_irq_5,  isr_irq_6,  isr_irq_7,
        isr_irq_8,  isr_irq_9,  isr_irq_10, isr_irq_11,
        isr_irq_12, isr_irq_13, isr_irq_14, isr_irq_15
    };

    /* Install exception handlers (vectors 0-16) */
    for (i = 0; i < 17; ++i) {
        idt_set_gate(i, (u16)exc_table[i], SEL_CODE, 0x86);
    }

    /* Install IRQ handlers (vectors 0x20-0x2F) */
    for (i = 0; i < 16; ++i) {
        idt_set_gate((u16)(IRQ_BASE_MASTER + i), (u16)irq_table[i], SEL_CODE, 0x86);
    }

    /* Install syscall handler at INT 0x80 */
    idt_set_gate(SYSCALL_VECTOR, (u16)syscall_entry, SEL_CODE, 0x86);
}

void __cdecl irq_init(void)
{
    /* Remap PICs so hardware IRQs don't collide with exceptions */
    pic_remap();

    /* Install proper IDT entries */
    install_idt();

    /* Unmask IRQ6 (floppy) on master PIC; keep everything else masked */
    outb(PIC1_DATA, (u8)~(1U << 6));
    outb(PIC2_DATA, 0xFF);
}
