#include "kernel.h"

/*
 * fs.c — FAT12 read-only filesystem driver for a 1.44 MB floppy.
 */

static u8 sector_buf[512];
static u8 fat_buf[512];
static u8 fat_next_buf[512];
static struct fs_super super;
static struct fs_dirent listed_dirent;
static u16 reserved_sectors;
static u8 fat_count;
static u16 root_start_sector;
static u16 root_dir_sectors;
static u16 cluster_count;
static u16 fat_sector_cached;
static u16 fat_next_sector_cached;
static u8 mounted;

#define FAT_BPB_BYTES_PER_SECTOR   11U
#define FAT_BPB_SECTORS_PER_CLUS   13U
#define FAT_BPB_RESERVED_SECTORS   14U
#define FAT_BPB_FAT_COUNT          16U
#define FAT_BPB_ROOT_ENTRIES       17U
#define FAT_BPB_TOTAL_SECTORS_16   19U
#define FAT_BPB_SECTORS_PER_FAT    22U
#define FAT_BPB_TOTAL_SECTORS_32   32U

#define FAT_DIR_NAME_OFFSET        0U
#define FAT_DIR_EXT_OFFSET         8U
#define FAT_DIR_ATTR_OFFSET        11U
#define FAT_DIR_CLUSTER_OFFSET     26U
#define FAT_DIR_SIZE_OFFSET        28U

#define FAT_ATTR_VOLUME_ID         0x08U
#define FAT_ATTR_DIRECTORY         0x10U
#define FAT_ATTR_LFN               0x0FU

#define FAT12_BAD_CLUSTER          0x0FF7U
#define FAT12_EOC_MIN              0x0FF8U

static u16 read_le16(const u8 *ptr)
{
    return (u16)ptr[0] | ((u16)ptr[1] << 8);
}

static u32 read_le32(const u8 *ptr)
{
    u32 value;

    value = (u32)ptr[0];
    value |= (u32)ptr[1] << 8;
    value |= (u32)ptr[2] << 16;
    value |= (u32)ptr[3] << 24;
    return value;
}

static char to_upper_char(char ch)
{
    if (ch >= 'a' && ch <= 'z') {
        return (char)(ch - ('a' - 'A'));
    }
    return ch;
}

static void invalidate_fat_cache(void)
{
    fat_sector_cached = 0xffffU;
    fat_next_sector_cached = 0xffffU;
}

static int load_fat_sector(u16 sector, u8 *buf, u16 *cached_sector)
{
    if (*cached_sector != sector) {
        if (blk_read(DEV_FLOPPY, sector, buf) != 0) {
            return -1;
        }
        *cached_sector = sector;
    }
    return 0;
}

static u16 fat12_next_cluster(u16 cluster)
{
    u16 fat_offset;
    u16 fat_sector;
    u16 fat_index;
    u8 byte0;
    u8 byte1;
    u16 value;

    fat_offset = cluster + (cluster >> 1);
    fat_sector = (u16)(reserved_sectors + (fat_offset / 512U));
    fat_index = (u16)(fat_offset % 512U);

    if (load_fat_sector(fat_sector, fat_buf, &fat_sector_cached) != 0) {
        return 0xffffU;
    }

    byte0 = fat_buf[fat_index];
    if (fat_index == 511U) {
        if (load_fat_sector((u16)(fat_sector + 1U), fat_next_buf, &fat_next_sector_cached) != 0) {
            return 0xffffU;
        }
        byte1 = fat_next_buf[0];
    } else {
        byte1 = fat_buf[fat_index + 1U];
    }

    if ((cluster & 1U) != 0U) {
        value = (u16)(((u16)byte0 >> 4) | ((u16)byte1 << 4));
    } else {
        value = (u16)((u16)byte0 | (((u16)byte1 & 0x0fU) << 8));
    }

    return (u16)(value & 0x0fffU);
}

static void build_short_name(const u8 *entry, struct fs_dirent *out)
{
    u8 i;
    u8 pos;

    pos = 0;
    for (i = 0; i < 8U; ++i) {
        char ch = (char)entry[FAT_DIR_NAME_OFFSET + i];
        if (ch == ' ') {
            break;
        }
        out->name[pos] = ch;
        ++pos;
    }

    if (entry[FAT_DIR_EXT_OFFSET] != ' ') {
        out->name[pos] = '.';
        ++pos;
        for (i = 0; i < 3U; ++i) {
            char ch = (char)entry[FAT_DIR_EXT_OFFSET + i];
            if (ch == ' ') {
                break;
            }
            out->name[pos] = ch;
            ++pos;
        }
    }

    out->name[pos] = 0;
}

static void fill_dirent(const u8 *entry, struct fs_dirent *out)
{
    build_short_name(entry, out);
    out->first_cluster = read_le16(entry + FAT_DIR_CLUSTER_OFFSET);
    out->size = read_le32(entry + FAT_DIR_SIZE_OFFSET);
}

static int entry_matches_name(const u8 *entry, const char *name)
{
    u8 i;
    u8 has_extension;
    char target[11];

    for (i = 0; i < 11U; ++i) {
        target[i] = ' ';
    }

    i = 0;
    has_extension = 0;
    while (*name != 0 && *name != '.' && i < 8U) {
        target[i] = to_upper_char(*name);
        ++name;
        ++i;
    }

    if (*name == '.') {
        u8 ext_index;

        has_extension = 1;
        ++name;
        ext_index = 0;
        while (*name != 0 && ext_index < 3U) {
            target[8U + ext_index] = to_upper_char(*name);
            ++name;
            ++ext_index;
        }
    }

    if (*name != 0) {
        return 0;
    }

    if (has_extension) {
        for (i = 0; i < 11U; ++i) {
            if ((char)entry[i] != target[i]) {
                return 0;
            }
        }
        return 1;
    }

    for (i = 0; i < 8U; ++i) {
        if ((char)entry[i] != target[i]) {
            return 0;
        }
    }

    return 1;
}

static int is_usable_file_entry(const u8 *entry)
{
    u8 attr;

    if (entry[0] == 0x00U || entry[0] == 0xe5U) {
        return 0;
    }

    attr = entry[FAT_DIR_ATTR_OFFSET];
    if ((attr & FAT_ATTR_LFN) == FAT_ATTR_LFN) {
        return 0;
    }
    if ((attr & FAT_ATTR_VOLUME_ID) != 0U) {
        return 0;
    }
    if ((attr & FAT_ATTR_DIRECTORY) != 0U) {
        return 0;
    }

    return 1;
}

int __cdecl fs_mount(void)
{
    u16 total_sectors;
    u16 data_sectors;
    u32 total_sectors32;

    mounted = 0;
    invalidate_fat_cache();

    if (floppy_reset() != 0) {
        kputs("fat12: floppy reset failed (no disk?)\r\n");
        return -1;
    }

    if (blk_read(DEV_FLOPPY, 0, sector_buf) != 0) {
        kputs("fat12: cannot read boot sector\r\n");
        return -1;
    }

    super.bytes_per_sector = read_le16(sector_buf + FAT_BPB_BYTES_PER_SECTOR);
    super.sectors_per_cluster = sector_buf[FAT_BPB_SECTORS_PER_CLUS];
    reserved_sectors = read_le16(sector_buf + FAT_BPB_RESERVED_SECTORS);
    fat_count = sector_buf[FAT_BPB_FAT_COUNT];
    super.root_entries = read_le16(sector_buf + FAT_BPB_ROOT_ENTRIES);
    total_sectors = read_le16(sector_buf + FAT_BPB_TOTAL_SECTORS_16);
    super.sectors_per_fat = read_le16(sector_buf + FAT_BPB_SECTORS_PER_FAT);
    total_sectors32 = read_le32(sector_buf + FAT_BPB_TOTAL_SECTORS_32);

    if (super.bytes_per_sector != 512U ||
        super.sectors_per_cluster == 0U ||
        reserved_sectors == 0U ||
        fat_count == 0U ||
        super.root_entries == 0U ||
        super.sectors_per_fat == 0U) {
        kputs("fat12: unsupported BPB\r\n");
        return -1;
    }

    if (total_sectors == 0U) {
        if (total_sectors32 == 0UL || total_sectors32 > 0xffffUL) {
            kputs("fat12: invalid geometry\r\n");
            return -1;
        }
        total_sectors = (u16)total_sectors32;
    }

    super.total_sectors = total_sectors;
    root_dir_sectors = (u16)(((u32)super.root_entries * 32UL + 511UL) / 512UL);
    root_start_sector = (u16)(reserved_sectors + (u16)fat_count * super.sectors_per_fat);
    super.data_start_sector = (u16)(root_start_sector + root_dir_sectors);

    if (super.data_start_sector >= super.total_sectors) {
        kputs("fat12: invalid data area\r\n");
        return -1;
    }

    data_sectors = (u16)(super.total_sectors - super.data_start_sector);
    cluster_count = (u16)(data_sectors / super.sectors_per_cluster);
    if (cluster_count == 0U || cluster_count >= 4085U) {
        kputs("fat12: only FAT12 floppies are supported\r\n");
        return -1;
    }

    mounted = 1;
    kputs("fat12: mounted\r\n");
    return 0;
}

int __cdecl fs_list(void)
{
    u16 sector;
    u16 entry_index;

    if (!mounted) {
        kputs("fat12: not mounted\r\n");
        return -1;
    }

    for (sector = 0; sector < root_dir_sectors; ++sector) {
        if (blk_read(DEV_FLOPPY, (u16)(root_start_sector + sector), sector_buf) != 0) {
            kputs("fat12: cannot read root directory\r\n");
            return -1;
        }

        for (entry_index = 0; entry_index < 16U; ++entry_index) {
            u16 offset;
            u8 *entry;
            u8 name_len;

            offset = (u16)(entry_index * 32U);
            entry = sector_buf + offset;
            if (entry[0] == 0x00U) {
                return 0;
            }
            if (!is_usable_file_entry(entry)) {
                continue;
            }

            fill_dirent(entry, &listed_dirent);
            name_len = 0;
            while (listed_dirent.name[name_len] != 0) {
                kputch(listed_dirent.name[name_len]);
                ++name_len;
            }
            while (name_len < 12U) {
                kputch(' ');
                ++name_len;
            }
            print_hex24(listed_dirent.size);
            kputs(" bytes\r\n");
        }
    }

    return 0;
}

int __cdecl fs_find(const char *name, struct fs_dirent *out)
{
    u16 sector;
    u16 entry_index;

    if (!mounted) return -1;

    for (sector = 0; sector < root_dir_sectors; ++sector) {
        if (blk_read(DEV_FLOPPY, (u16)(root_start_sector + sector), sector_buf) != 0) {
            return -1;
        }

        for (entry_index = 0; entry_index < 16U; ++entry_index) {
            u16 offset;
            u8 *entry;

            offset = (u16)(entry_index * 32U);
            entry = sector_buf + offset;
            if (entry[0] == 0x00U) {
                return -1;
            }
            if (!is_usable_file_entry(entry)) {
                continue;
            }
            if (entry_matches_name(entry, name)) {
                fill_dirent(entry, out);
                return 0;
            }
        }
    }

    return -1;
}

int __cdecl fs_read_file(const struct fs_dirent *entry, u8 *buf, u16 max)
{
    u32 remaining;
    u16 cluster;
    u16 sector;
    u16 offset = 0;
    u8 sector_in_cluster;

    if (!mounted) {
        return -1;
    }

    remaining = entry->size;
    if (remaining > (u32)max) {
        remaining = (u32)max;
    }

    if (remaining == 0UL) {
        return 0;
    }

    cluster = entry->first_cluster;
    if (cluster < 2U || cluster >= (u16)(cluster_count + 2U)) {
        kputs("fat12: invalid start cluster\r\n");
        return -1;
    }

    while (remaining > 0) {
        for (sector_in_cluster = 0; sector_in_cluster < super.sectors_per_cluster && remaining > 0UL; ++sector_in_cluster) {
            u16 chunk;

            sector = (u16)(super.data_start_sector + (u16)((cluster - 2U) * super.sectors_per_cluster) + sector_in_cluster);
            if (blk_read(DEV_FLOPPY, sector, sector_buf) != 0) {
                kputs("fat12: read error\r\n");
                return -1;
            }

            chunk = (remaining > 512UL) ? 512U : (u16)remaining;
            {
                u16 i;
                for (i = 0; i < chunk; ++i) {
                    buf[offset + i] = sector_buf[i];
                }
            }

            offset += chunk;
            remaining -= chunk;
        }

        if (remaining > 0UL) {
            cluster = fat12_next_cluster(cluster);
            if (cluster == 0xffffU || cluster == FAT12_BAD_CLUSTER) {
                kputs("fat12: bad cluster chain\r\n");
                return -1;
            }
            if (cluster >= FAT12_EOC_MIN) {
                kputs("fat12: unexpected end of file\r\n");
                return -1;
            }
            if (cluster < 2U || cluster >= (u16)(cluster_count + 2U)) {
                kputs("fat12: cluster out of range\r\n");
                return -1;
            }
        }
    }

    return (int)offset;
}
