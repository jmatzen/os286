#include "kernel.h"

extern void __cdecl serial_putchar(int ch);
extern u8 __cdecl pm_read_phys(u16 addr_lo, u16 addr_hi);
extern void __cdecl pm_write_phys(u16 addr_lo, u16 addr_hi, int value);
extern void __cdecl stage2_halt(void);

static const char msg_banner[] =
    "\r\n"
    "OS286  --  16-bit protected mode kernel\r\n"
    "Type 'help' for commands.\r\n"
    "\r\n";

void __cdecl kputch(char ch)
{
    serial_putchar((unsigned char)ch);
}

void __cdecl kputs(const char *text)
{
    while (*text != 0) {
        kputch(*text);
        ++text;
    }
}

u8 __cdecl kread_phys_byte(u32 address)
{
    return pm_read_phys((u16)address, (u16)(address >> 16));
}

void __cdecl kwrite_phys_byte(u32 address, u8 value)
{
    pm_write_phys((u16)address, (u16)(address >> 16), value);
}

void __cdecl khalt(void)
{
    stage2_halt();
}

void __cdecl kmain(void)
{
    kputs(msg_banner);
    console_run();
}
