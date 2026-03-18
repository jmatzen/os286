typedef unsigned char u8;
typedef unsigned short u16;
typedef unsigned long u32;

#ifndef __WATCOMC__
#define __cdecl
#endif

void __cdecl kputch(char ch);
void __cdecl kputs(const char *text);
u8 __cdecl kread_phys_byte(u32 address);
void __cdecl kwrite_phys_byte(u32 address, u8 value);
void __cdecl khalt(void);

void __cdecl console_run(void);
