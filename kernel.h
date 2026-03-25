typedef unsigned char u8;
typedef unsigned short u16;
typedef unsigned long u32;

#ifndef __WATCOMC__
#define __cdecl
#endif

/* ── Memory map constants ─────────────────────────────────── */
#define IDT_BASE        0x0500U
#define IDT_ENTRIES     256
#define DMA_BUF_ADDR    0x1000U
#define DMA_BUF_SIZE    512U
#define PROC_BASE       0x2000U
#define PROC_MAX_SIZE   0x3000U   /* 12 KiB */
#define STACK_TOP       0x6F00U

/* GDT selectors (must match boot.asm / shell.asm) */
#define SEL_CODE        0x08U
#define SEL_DATA        0x10U
#define SEL_PHYSDATA    0x18U

/* ── PIC constants ────────────────────────────────────────── */
#define PIC1_CMD        0x20U
#define PIC1_DATA       0x21U
#define PIC2_CMD        0xA0U
#define PIC2_DATA       0xA1U
#define IRQ_BASE_MASTER 0x20U
#define IRQ_BASE_SLAVE  0x28U

/* ── Syscall numbers (INT 0x80, AH=number) ────────────────── */
#define SYS_EXIT        0x00U
#define SYS_PUTCHAR     0x01U
#define SYS_GETCHAR     0x02U
#define SYS_PUTS        0x03U
#define SYSCALL_VECTOR  0x80U

/* ── Block device IDs ─────────────────────────────────────── */
#define DEV_FLOPPY      0

struct fs_super {
    u16 bytes_per_sector;
    u8  sectors_per_cluster;
    u16 total_sectors;
    u16 root_entries;
    u16 sectors_per_fat;
    u16 data_start_sector;
};

struct fs_dirent {
    char name[13];
    u16  first_cluster;
    u32  size;
};

/* ── Kernel core (kernel.c) ───────────────────────────────── */
void __cdecl kputch(char ch);
void __cdecl kputs(const char *text);
u8   __cdecl kread_phys_byte(u32 address);
void __cdecl kwrite_phys_byte(u32 address, u8 value);
void __cdecl khalt(void);
void __cdecl kinit(void);

/* ── Console (console.c) ──────────────────────────────────── */
void __cdecl console_run(void);

/* hex printing helpers */
void __cdecl print_hex_byte(u8 value);
void __cdecl print_hex_word(u16 value);
void __cdecl print_hex24(u32 value);

/* ── Port I/O (shell.asm) ─────────────────────────────────── */
extern void __cdecl outb(u16 port, u8 val);
extern u8   __cdecl inb(u16 port);

/* ── IRQ / exceptions (irq.c) ─────────────────────────────── */
void __cdecl irq_init(void);
void __cdecl fault_handler(u16 vector);
void __cdecl irq_handler(u16 irq);

/* ── Floppy driver (floppy.c) ─────────────────────────────── */
void __cdecl floppy_init(void);
int  __cdecl floppy_reset(void);
int  __cdecl floppy_read_sector(u16 lba, u8 *buf);

/* ── Block device layer (blkdev.c) ────────────────────────── */
int  __cdecl blk_read(u8 dev, u16 sector, u8 *buf);

/* ── Filesystem (fs.c) ────────────────────────────────────── */
int  __cdecl fs_mount(void);
int  __cdecl fs_list(void);
int  __cdecl fs_find(const char *name, struct fs_dirent *out);
int  __cdecl fs_read_file(const struct fs_dirent *entry, u8 *buf, u16 max);

/* ── Exec / process (exec.c) ──────────────────────────────── */
int  __cdecl exec_run(const char *name);
