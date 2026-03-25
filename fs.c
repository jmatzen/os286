#include "kernel.h"

/*
 * fs.c — OS286FS read-only filesystem driver.
 *
 * The filesystem lives on the floppy disk (DEV_FLOPPY).
 * Layout:
 *   Sector 0: Superblock
 *   Sector 1: Directory (up to 32 entries, 16 bytes each)
 *   Sector 2+: File data (contiguous per file)
 */

static u8 sector_buf[512];
static struct fs_super super;
static u8 mounted;

int __cdecl fs_mount(void)
{
    struct fs_super *sb;

    mounted = 0;

    if (floppy_reset() != 0) {
        kputs("fs: floppy reset failed (no disk?)\r\n");
        return -1;
    }

    /* Read superblock (sector 0) */
    if (blk_read(DEV_FLOPPY, 0, sector_buf) != 0) {
        kputs("fs: cannot read superblock\r\n");
        return -1;
    }

    sb = (struct fs_super *)sector_buf;
    if (sb->magic != FS_MAGIC || sb->version != FS_VERSION) {
        kputs("fs: bad superblock magic\r\n");
        return -1;
    }

    super.magic       = sb->magic;
    super.version     = sb->version;
    super.file_count  = sb->file_count;
    super.total_sects = sb->total_sects;

    if (super.file_count > FS_MAX_FILES) {
        super.file_count = FS_MAX_FILES;
    }

    mounted = 1;
    kputs("fs: mounted (");
    print_hex_word(super.file_count);
    kputs(" files)\r\n");
    return 0;
}

int __cdecl fs_list(void)
{
    u16 i;
    struct fs_dirent *dir;

    if (!mounted) {
        kputs("fs: not mounted\r\n");
        return -1;
    }

    /* Read directory sector */
    if (blk_read(DEV_FLOPPY, FS_DIR_SECTOR, sector_buf) != 0) {
        kputs("fs: cannot read directory\r\n");
        return -1;
    }

    dir = (struct fs_dirent *)sector_buf;
    for (i = 0; i < super.file_count; ++i) {
        u8 j;
        /* Print filename */
        for (j = 0; j < FS_NAME_LEN; ++j) {
            if (dir[i].name[j] == 0) break;
            kputch(dir[i].name[j]);
        }
        /* Pad to 10 chars */
        while (j < 10) {
            kputch(' ');
            ++j;
        }
        /* Print size */
        print_hex_word(dir[i].size);
        kputs(" bytes\r\n");
    }

    return 0;
}

static int name_match(const char *a, const char *b)
{
    u8 i;
    for (i = 0; i < FS_NAME_LEN; ++i) {
        char ca = a[i];
        char cb = b[i];
        if (ca == 0 && cb == 0) return 1;
        if (ca == 0 || cb == 0) {
            /* treat remaining as NUL padding */
            if (ca != 0 || cb != 0) return 0;
        }
        if (ca != cb) return 0;
    }
    return 1;
}

int __cdecl fs_find(const char *name, struct fs_dirent *out)
{
    u16 i;
    struct fs_dirent *dir;

    if (!mounted) return -1;

    if (blk_read(DEV_FLOPPY, FS_DIR_SECTOR, sector_buf) != 0) {
        return -1;
    }

    dir = (struct fs_dirent *)sector_buf;
    for (i = 0; i < super.file_count; ++i) {
        if (name_match(name, dir[i].name)) {
            u8 j;
            for (j = 0; j < FS_NAME_LEN; ++j) {
                out->name[j] = dir[i].name[j];
            }
            out->start_sect = dir[i].start_sect;
            out->size        = dir[i].size;
            return 0;
        }
    }

    return -1;
}

int __cdecl fs_read_file(const struct fs_dirent *entry, u8 *buf, u16 max)
{
    u16 remaining;
    u16 sector;
    u16 offset = 0;

    remaining = entry->size;
    if (remaining > max) {
        remaining = max;
    }

    sector = entry->start_sect;

    while (remaining > 0) {
        u16 chunk;

        if (blk_read(DEV_FLOPPY, sector, sector_buf) != 0) {
            kputs("fs: read error\r\n");
            return -1;
        }

        chunk = (remaining > 512U) ? 512U : remaining;
        {
            u16 i;
            for (i = 0; i < chunk; ++i) {
                buf[offset + i] = sector_buf[i];
            }
        }

        offset    += chunk;
        remaining -= chunk;
        ++sector;
    }

    return (int)offset;
}
