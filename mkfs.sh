#!/bin/sh
# mkfs.sh — Create a standard FAT12 1.44 MB floppy image.

set -e

if [ $# -lt 2 ]; then
    echo "Usage: $0 <output.img> <file1> [file2] ..." >&2
    exit 1
fi

OUTIMG="$1"
shift

SECTOR_SIZE=512
SECTORS_PER_CLUSTER=1
RESERVED_SECTORS=1
FAT_COUNT=2
ROOT_ENTRIES=224
SECTORS_PER_FAT=9
SECTORS_PER_TRACK=18
HEADS=2
FLOPPY_SECTORS=2880
ROOT_DIR_SECTORS=$(((ROOT_ENTRIES * 32 + SECTOR_SIZE - 1) / SECTOR_SIZE))
FIRST_DATA_SECTOR=$((RESERVED_SECTORS + FAT_COUNT * SECTORS_PER_FAT + ROOT_DIR_SECTORS))
DATA_CLUSTERS=$(((FLOPPY_SECTORS - FIRST_DATA_SECTOR) / SECTORS_PER_CLUSTER))

BOOT=$(mktemp)
FAT=$(mktemp)
ROOT=$(mktemp)
USED_NAMES=$(mktemp)

cleanup() {
    rm -f "$BOOT" "$FAT" "$ROOT" "$USED_NAMES"
}

trap cleanup EXIT INT TERM

write_byte() {
    printf "\\$(printf '%03o' "$1")"
}

write_le16() {
    write_byte $(($1 & 0xff))
    write_byte $((($1 >> 8) & 0xff))
}

write_le32() {
    write_byte $(($1 & 0xff))
    write_byte $((($1 >> 8) & 0xff))
    write_byte $((($1 >> 16) & 0xff))
    write_byte $((($1 >> 24) & 0xff))
}

write_padded_text() {
    text=$(printf '%s' "$1" | cut -c1-"$2")
    width="$2"
    length=$(printf '%s' "$text" | wc -c | tr -d ' ')

    printf '%s' "$text"
    while [ "$length" -lt "$width" ]; do
        printf ' '
        length=$((length + 1))
    done
}

read_byte_at() {
    od -An -tu1 -j "$1" -N1 "$2" | tr -d ' '
}

write_byte_at() {
    printf "\\$(printf '%03o' "$1")" | dd of="$3" bs=1 seek="$2" conv=notrunc 2>/dev/null
}

fat_set_entry() {
    cluster="$1"
    value=$(($2 & 0x0fff))
    offset=$((cluster + cluster / 2))

    if [ $((cluster % 2)) -eq 0 ]; then
        b1=$(read_byte_at "$offset" "$FAT")
        if [ -z "$b1" ]; then
            b1=0
        fi
        write_byte_at $((value & 0xff)) "$offset" "$FAT"
        write_byte_at $((((value >> 8) & 0x0f) | (b1 & 0xf0))) $((offset + 1)) "$FAT"
    else
        b0=$(read_byte_at "$offset" "$FAT")
        if [ -z "$b0" ]; then
            b0=0
        fi
        write_byte_at $(((b0 & 0x0f) | ((value << 4) & 0xf0))) "$offset" "$FAT"
        write_byte_at $(((value >> 4) & 0xff)) $((offset + 1)) "$FAT"
    fi
}

if [ $# -gt "$ROOT_ENTRIES" ]; then
    echo "Error: too many files (max $ROOT_ENTRIES)" >&2
    exit 1
fi

dd if=/dev/zero of="$OUTIMG" bs=$SECTOR_SIZE count=$FLOPPY_SECTORS 2>/dev/null
dd if=/dev/zero of="$FAT" bs=$SECTOR_SIZE count=$SECTORS_PER_FAT 2>/dev/null
dd if=/dev/zero of="$ROOT" bs=$SECTOR_SIZE count=$ROOT_DIR_SECTORS 2>/dev/null
: > "$USED_NAMES"

{
    write_byte 0xeb
    write_byte 0x3c
    write_byte 0x90
    printf 'OS286   '
    write_le16 "$SECTOR_SIZE"
    write_byte "$SECTORS_PER_CLUSTER"
    write_le16 "$RESERVED_SECTORS"
    write_byte "$FAT_COUNT"
    write_le16 "$ROOT_ENTRIES"
    write_le16 "$FLOPPY_SECTORS"
    write_byte 0xf0
    write_le16 "$SECTORS_PER_FAT"
    write_le16 "$SECTORS_PER_TRACK"
    write_le16 "$HEADS"
    write_le32 0
    write_le32 0
    write_byte 0x00
    write_byte 0x00
    write_byte 0x29
    write_le32 0x4f533236
    printf 'OS286FLOPPY'
    printf 'FAT12   '
} > "$BOOT"

BOOT_SIZE=$(wc -c < "$BOOT" | tr -d ' ')
dd if=/dev/zero bs=1 count=$((510 - BOOT_SIZE)) 2>/dev/null >> "$BOOT"
write_byte 0x55 >> "$BOOT"
write_byte 0xaa >> "$BOOT"

dd if="$BOOT" of="$OUTIMG" bs=$SECTOR_SIZE seek=0 conv=notrunc 2>/dev/null

write_byte_at 0xf0 0 "$FAT"
write_byte_at 0xff 1 "$FAT"
write_byte_at 0xff 2 "$FAT"

FILE_COUNT=0
NEXT_CLUSTER=2

for f in "$@"; do
    if [ ! -f "$f" ]; then
        echo "Error: $f not found" >&2
        exit 1
    fi

    RAW_NAME=$(basename "$f")
    STEM=${RAW_NAME%.*}
    if [ "$STEM" = "$RAW_NAME" ]; then
        EXT=
    else
        EXT=${RAW_NAME##*.}
    fi

    STEM_UP=$(printf '%s' "$STEM" | tr '[:lower:]' '[:upper:]' | cut -c1-8)
    EXT_UP=$(printf '%s' "$EXT" | tr '[:lower:]' '[:upper:]' | cut -c1-3)
    SHORT_KEY="${STEM_UP}.${EXT_UP}"

    if grep -Fqx "$SHORT_KEY" "$USED_NAMES"; then
        echo "Error: duplicate FAT 8.3 name after truncation: $RAW_NAME" >&2
        exit 1
    fi
    printf '%s\n' "$SHORT_KEY" >> "$USED_NAMES"

    FSIZE=$(wc -c < "$f" | tr -d ' ')
    CLUSTERS_USED=$(((FSIZE + SECTOR_SIZE - 1) / SECTOR_SIZE))

    if [ "$CLUSTERS_USED" -eq 0 ]; then
        START_CLUSTER=0
    else
        START_CLUSTER=$NEXT_CLUSTER
        LAST_CLUSTER=$((START_CLUSTER + CLUSTERS_USED - 1))
        if [ "$LAST_CLUSTER" -gt $((DATA_CLUSTERS + 1)) ]; then
            echo "Error: floppy image full" >&2
            exit 1
        fi

        INDEX=0
        while [ "$INDEX" -lt "$CLUSTERS_USED" ]; do
            CLUSTER=$((START_CLUSTER + INDEX))
            if [ "$INDEX" -eq $((CLUSTERS_USED - 1)) ]; then
                NEXT_VALUE=0x0fff
            else
                NEXT_VALUE=$((CLUSTER + 1))
            fi
            fat_set_entry "$CLUSTER" "$NEXT_VALUE"

            DATA_SECTOR=$((FIRST_DATA_SECTOR + (CLUSTER - 2) * SECTORS_PER_CLUSTER))
            dd if="$f" of="$OUTIMG" bs=$SECTOR_SIZE skip="$INDEX" seek="$DATA_SECTOR" count=1 conv=notrunc 2>/dev/null

            INDEX=$((INDEX + 1))
        done

        NEXT_CLUSTER=$((LAST_CLUSTER + 1))
    fi

    ENTRY=$(mktemp)
    {
        write_padded_text "$STEM_UP" 8
        write_padded_text "$EXT_UP" 3
        write_byte 0x20
        write_byte 0x00
        write_byte 0x00
        write_le16 0
        write_le16 0
        write_le16 0
        write_le16 0
        write_le16 0
        write_le16 0
        write_le16 "$START_CLUSTER"
        write_le32 "$FSIZE"
    } > "$ENTRY"
    dd if="$ENTRY" of="$ROOT" bs=32 seek="$FILE_COUNT" conv=notrunc 2>/dev/null
    rm -f "$ENTRY"

    FILE_COUNT=$((FILE_COUNT + 1))
done

dd if="$FAT" of="$OUTIMG" bs=$SECTOR_SIZE seek=$RESERVED_SECTORS conv=notrunc 2>/dev/null
dd if="$FAT" of="$OUTIMG" bs=$SECTOR_SIZE seek=$((RESERVED_SECTORS + SECTORS_PER_FAT)) conv=notrunc 2>/dev/null
dd if="$ROOT" of="$OUTIMG" bs=$SECTOR_SIZE seek=$((RESERVED_SECTORS + FAT_COUNT * SECTORS_PER_FAT)) conv=notrunc 2>/dev/null

echo "Created FAT12 floppy image $OUTIMG: $FILE_COUNT file(s), data starts at sector $FIRST_DATA_SECTOR"
