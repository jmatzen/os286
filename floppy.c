#include "kernel.h"

/*
 * floppy.c — ISA floppy controller driver for OS286.
 *
 * Drives the 82077AA FDC via port I/O and the 8237 DMA controller.
 * Only drive 0 (1.44 MB, 3.5") is supported.
 *
 * Floppy geometry (1.44 MB):
 *   80 cylinders × 2 heads × 18 sectors/track = 2880 sectors
 *   Sector size = 512 bytes
 *
 * FDC ports (primary controller):
 *   0x3F2  DOR  — Digital Output Register
 *   0x3F4  MSR  — Main Status Register
 *   0x3F5  FIFO — Data (command/result bytes)
 *   0x3F7  DIR  — Digital Input / CCR (config control)
 *
 * DMA channel 2 ports:
 *   0x04   Ch2 address (low/high, flip-flop)
 *   0x05   Ch2 count   (low/high, flip-flop)
 *   0x81   Ch2 page register
 *   0x0A   Single mask register
 *   0x0B   Mode register
 *   0x0C   Flip-flop reset
 */

/* FDC port definitions */
#define FDC_DOR   0x3F2U
#define FDC_MSR   0x3F4U
#define FDC_FIFO  0x3F5U
#define FDC_CCR   0x3F7U

/* DOR bits */
#define DOR_DRIVE0  0x00U
#define DOR_RESET   0x04U
#define DOR_DMA     0x08U
#define DOR_MOTOR0  0x10U

/* MSR bits */
#define MSR_RQM     0x80U
#define MSR_DIO     0x40U

/* FDC commands */
#define CMD_SPECIFY   0x03U
#define CMD_RECALIB   0x07U
#define CMD_SENSE_INT 0x08U
#define CMD_READ_DATA 0xE6U  /* MFM + multitrack + skip */

/* 1.44 MB geometry */
#define FD_SECTORS_PER_TRACK  18U
#define FD_HEADS              2U

/* Timeout for polling loops (approximate iteration counts) */
#define FDC_TIMEOUT  50000U
#define IRQ_TIMEOUT  500000UL

extern u16 floppy_irq_flag;

static u8 fdc_motor_on;

static void fdc_delay(void)
{
    u16 i;
    for (i = 0; i < 100; ++i) {
        inb(0x80);  /* ~1 µs per read of port 0x80 */
    }
}

/* Wait for FDC ready to accept a command/data byte */
static int fdc_wait_ready(void)
{
    u16 i;
    for (i = 0; i < FDC_TIMEOUT; ++i) {
        if (inb(FDC_MSR) & MSR_RQM) {
            return 1;
        }
    }
    return 0;
}

/* Send a byte to the FDC FIFO */
static int fdc_send(u8 val)
{
    if (!fdc_wait_ready()) return 0;
    outb(FDC_FIFO, val);
    return 1;
}

/* Read a byte from the FDC FIFO */
static int fdc_recv(u8 *out)
{
    u16 i;
    for (i = 0; i < FDC_TIMEOUT; ++i) {
        u8 msr = inb(FDC_MSR);
        if ((msr & (MSR_RQM | MSR_DIO)) == (MSR_RQM | MSR_DIO)) {
            *out = inb(FDC_FIFO);
            return 1;
        }
    }
    return 0;
}

/* Wait for the floppy IRQ (IRQ 6) */
static int fdc_wait_irq(void)
{
    u32 timeout = IRQ_TIMEOUT;
    while (timeout != 0) {
        if (floppy_irq_flag) {
            floppy_irq_flag = 0;
            return 1;
        }
        --timeout;
    }
    return 0;
}

/* SENSE INTERRUPT results (static to avoid stack-pointer issues with -zu) */
static u8 sense_st0;
static u8 sense_cyl;

static int fdc_sense_interrupt(void)
{
    if (!fdc_send(CMD_SENSE_INT)) return 0;
    if (!fdc_recv(&sense_st0)) return 0;
    if (!fdc_recv(&sense_cyl)) return 0;
    return 1;
}

static void motor_on(void)
{
    if (!fdc_motor_on) {
        outb(FDC_DOR, DOR_DRIVE0 | DOR_RESET | DOR_DMA | DOR_MOTOR0);
        fdc_motor_on = 1;
        /* Wait for motor spin-up (~300ms equivalent delay) */
        {
            u16 i;
            for (i = 0; i < 3000; ++i) fdc_delay();
        }
    }
}

static void motor_off(void)
{
    outb(FDC_DOR, DOR_DRIVE0 | DOR_RESET | DOR_DMA);
    fdc_motor_on = 0;
}

/* CHS results (static to avoid stack-pointer issues with -zu) */
static u8 chs_cyl;
static u8 chs_head;
static u8 chs_sector;

static void lba_to_chs(u16 lba)
{
    chs_cyl    = (u8)(lba / (FD_HEADS * FD_SECTORS_PER_TRACK));
    chs_head   = (u8)((lba / FD_SECTORS_PER_TRACK) % FD_HEADS);
    chs_sector = (u8)((lba % FD_SECTORS_PER_TRACK) + 1);  /* 1-based */
}

/* Set up 8237 DMA channel 2 for a single-sector floppy read */
static void dma_setup_read(void)
{
    u16 addr = DMA_BUF_ADDR;
    u16 count = DMA_BUF_SIZE - 1;  /* byte count - 1 */

    outb(0x0A, 0x06);  /* mask channel 2 */
    outb(0x0C, 0xFF);  /* reset flip-flop */
    outb(0x04, (u8)(addr & 0xFF));          /* address low */
    outb(0x04, (u8)((addr >> 8) & 0xFF));   /* address high */
    outb(0x81, 0x00);  /* page register = 0 (we're in first 64K) */
    outb(0x0C, 0xFF);  /* reset flip-flop */
    outb(0x05, (u8)(count & 0xFF));         /* count low */
    outb(0x05, (u8)((count >> 8) & 0xFF));  /* count high */
    outb(0x0B, 0x46);  /* mode: single, addr inc, read from device, ch2 */
    outb(0x0A, 0x02);  /* unmask channel 2 */
}

void __cdecl floppy_init(void)
{
    fdc_motor_on = 0;
    floppy_irq_flag = 0;

    /* Set data rate for 1.44 MB (500 Kbps) */
    outb(FDC_CCR, 0x00);
}

int __cdecl floppy_reset(void)
{
    floppy_irq_flag = 0;

    /* Toggle reset via DOR */
    outb(FDC_DOR, 0x00);
    fdc_delay();
    outb(FDC_DOR, DOR_DRIVE0 | DOR_RESET | DOR_DMA);

    /* Wait for reset IRQ */
    if (!fdc_wait_irq()) {
        kputs("floppy: reset timeout\r\n");
        return -1;
    }

    /* Sense interrupt for all 4 drives (required by spec) */
    {
        u8 i;
        for (i = 0; i < 4; ++i) {
            fdc_sense_interrupt();
        }
    }

    /* Set data rate */
    outb(FDC_CCR, 0x00);

    /* SPECIFY: SRT=8ms, HUT=0, HLT=5ms, NDMA=0 */
    if (!fdc_send(CMD_SPECIFY)) return -1;
    if (!fdc_send(0xCF))        return -1;  /* SRT=0xC(8ms), HUT=0xF */
    if (!fdc_send(0x06))        return -1;  /* HLT=6ms, NDMA=0 */

    /* Recalibrate (seek to track 0) */
    motor_on();
    floppy_irq_flag = 0;
    if (!fdc_send(CMD_RECALIB)) return -1;
    if (!fdc_send(0x00))        return -1;  /* drive 0 */

    if (!fdc_wait_irq()) {
        kputs("floppy: recalibrate timeout\r\n");
        motor_off();
        return -1;
    }

    fdc_sense_interrupt();
    motor_off();

    return 0;
}

int __cdecl floppy_read_sector(u16 lba, u8 *buf)
{
    static u8 result[7];
    u16 i;

    if (lba >= 2880U) return -1;

    lba_to_chs(lba);
    motor_on();

    /* Seek to the correct cylinder */
    floppy_irq_flag = 0;
    if (!fdc_send(0x0F))              goto fail;  /* SEEK command */
    if (!fdc_send(chs_head << 2))     goto fail;  /* head << 2 | drive 0 */
    if (!fdc_send(chs_cyl))           goto fail;

    if (!fdc_wait_irq()) {
        kputs("floppy: seek timeout\r\n");
        goto fail;
    }
    fdc_sense_interrupt();

    /* Set up DMA for the read */
    dma_setup_read();

    /* Issue READ DATA command */
    floppy_irq_flag = 0;
    if (!fdc_send(CMD_READ_DATA))            goto fail;
    if (!fdc_send((chs_head << 2) | 0x00))   goto fail;
    if (!fdc_send(chs_cyl))                  goto fail;
    if (!fdc_send(chs_head))                 goto fail;
    if (!fdc_send(chs_sector))               goto fail;
    if (!fdc_send(0x02))                     goto fail;  /* 512 bytes/sector */
    if (!fdc_send(FD_SECTORS_PER_TRACK))     goto fail;  /* EOT */
    if (!fdc_send(0x1B))                     goto fail;  /* GAP3 for 1.44M */
    if (!fdc_send(0xFF))                     goto fail;  /* DTL (unused) */

    /* Wait for transfer to complete */
    if (!fdc_wait_irq()) {
        kputs("floppy: read timeout\r\n");
        goto fail;
    }

    /* Read result phase (7 bytes) */
    for (i = 0; i < 7; ++i) {
        if (!fdc_recv(&result[i])) goto fail;
    }

    /* Check for errors: ST0 bits 7:6, ST1, ST2 */
    if ((result[0] & 0xC0) != 0 || result[1] != 0 || result[2] != 0) {
        kputs("floppy: read error\r\n");
        goto fail;
    }

    /* Copy from DMA buffer to caller's buffer */
    {
        volatile u8 *dma = (volatile u8 *)DMA_BUF_ADDR;
        for (i = 0; i < DMA_BUF_SIZE; ++i) {
            buf[i] = dma[i];
        }
    }

    return 0;

fail:
    motor_off();
    return -1;
}
