# OS286 System Design

This document defines the architecture for OS286: program execution model,
kernel memory map, syscall ABI, executable format, and filesystem layout.

## Program Execution Model

OS286 runs entirely in 286 16-bit protected mode at ring 0 with flat
base-0 descriptors.  User programs share the same 64 KiB code/data address
space as the kernel.  There is no hardware memory protection between the
kernel and user programs.

A user program is a flat binary loaded at `PROC_BASE` (0x2000).  The kernel
reads the file from the floppy filesystem into that address range and performs
a near CALL to `PROC_BASE`.  The program runs as ordinary ring-0 code and
returns to the kernel with a near RET or via the `exit` syscall (INT 0x80,
AH=0x00).

Only one program runs at a time.  There is no multitasking.

## Kernel Memory Map

All addresses are physical = logical (DS/ES/SS base = 0).

```
0x0000 - 0x04FF   Reserved
0x0500 - 0x0CFF   IDT  (256 entries × 8 = 2048 bytes)
0x0D00 - 0x0FFF   Kernel variables
0x1000 - 0x11FF   DMA bounce buffer (512 bytes, 4 KiB aligned)
0x1200 - 0x1FFF   Free
0x2000 - 0x4FFF   Process load area (12 KiB, PROC_BASE)
0x5000 - 0x6EFF   Stack space  (grows ↓ from 0x6F00)
0x6F00            Stack top
0x7000 - 0x7BFF   Free
0x7C00 - 0x7DFF   Stage 1 boot sector + GDT
0x8000 - 0xFFFF   Stage 2 kernel (code + data, ≤ 32 KiB)
```

## Interrupt Layout

The master PIC is remapped to INT 0x20 – 0x27 and the slave PIC to
INT 0x28 – 0x2F so that hardware IRQs do not collide with CPU exceptions.

```
0x00 - 0x1F   CPU exceptions  (divide error, GPF, etc.)
0x20 - 0x27   Master PIC IRQs 0-7  (timer, kbd, cascade, COM2, COM1,
                                      LPT2, floppy, LPT1)
0x28 - 0x2F   Slave PIC IRQs 8-15
0x80          Syscall gate
```

## Syscall ABI

User programs invoke kernel services with `INT 0x80`.

| AH   | Name    | Input        | Output | Description           |
|------|---------|--------------|--------|-----------------------|
| 0x00 | exit    | —            | —      | Return to kernel      |
| 0x01 | putchar | AL = char    | —      | Write char to console |
| 0x02 | getchar | —            | AL     | Read char from console|
| 0x03 | puts    | BX = string  | —      | Write string          |

## Executable Format

User programs are **headerless flat binaries** assembled/linked at
`ORG 0x2000` (`PROC_BASE`).  The first byte of the file is the first
instruction.  Maximum program size is 12 KiB.

The filesystem directory supplies the file size; no in-band metadata is
needed.

## Floppy Filesystem — OS286FS

A read-only filesystem stored on a 1.44 MB floppy image.

### Superblock (sector 0, 512 bytes)

| Offset | Size | Field        |
|--------|------|------------- |
| 0      | 2    | Magic 0x3638 |
| 2      | 2    | Version (1)  |
| 4      | 2    | File count   |
| 6      | 2    | Total sectors|
| 8      | 504  | Reserved     |

### Directory (sector 1, 512 bytes)

Up to 32 entries, 16 bytes each:

| Offset | Size | Field              |
|--------|------|--------------------|
| 0      | 8    | Filename (NUL-pad) |
| 8      | 2    | Start sector       |
| 10     | 2    | Size in bytes      |
| 12     | 4    | Reserved           |

### Data (sectors 2+)

File data stored contiguously starting at the sector indicated in the
directory entry.

## Block Device Layer

A minimal abstraction providing `blk_read(dev, sector, buf)`.  The only
device implemented is the floppy (DEV_FLOPPY = 0).  The layer translates
logical sector numbers into the correct CHS parameters and performs the
ISA DMA + FDC command sequence.
