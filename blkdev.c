#include "kernel.h"

/*
 * blkdev.c — Block device abstraction layer.
 *
 * Provides a single entry point blk_read(dev, sector, buf) that
 * dispatches to the appropriate low-level driver.
 */

int __cdecl blk_read(u8 dev, u16 sector, u8 *buf)
{
    switch (dev) {
    case DEV_FLOPPY:
        return floppy_read_sector(sector, buf);
    default:
        return -1;
    }
}
