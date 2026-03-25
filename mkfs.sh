#!/bin/sh
# mkfs.sh — Create an OS286FS floppy image.
#
# Usage: ./mkfs.sh <output.img> <file1> [file2] ...
#
# Each file is stored contiguously on the image.  The superblock
# occupies sector 0, the directory occupies sector 1, and file
# data starts at sector 2.
#
# Maximum 32 files.  Filenames are truncated to 8 characters.
# Total image size is padded to 1.44 MB (2880 sectors).

set -e

if [ $# -lt 2 ]; then
    echo "Usage: $0 <output.img> <file1> [file2] ..." >&2
    exit 1
fi

OUTIMG="$1"
shift

SECTOR_SIZE=512
DIR_SECTOR=1
DATA_START=2
MAX_FILES=32
NAME_LEN=8
DIRENT_SIZE=16
FLOPPY_SECTORS=2880
FLOPPY_SIZE=$((FLOPPY_SECTORS * SECTOR_SIZE))

# Collect file info
FILE_COUNT=0
for f in "$@"; do
    if [ ! -f "$f" ]; then
        echo "Error: $f not found" >&2
        exit 1
    fi
    FILE_COUNT=$((FILE_COUNT + 1))
    if [ "$FILE_COUNT" -gt "$MAX_FILES" ]; then
        echo "Error: too many files (max $MAX_FILES)" >&2
        exit 1
    fi
done

# Create empty 1.44 MB image
dd if=/dev/zero of="$OUTIMG" bs=$SECTOR_SIZE count=$FLOPPY_SECTORS 2>/dev/null

# --- Write superblock (sector 0) ---
# Use printf to write binary.  All values are little-endian 16-bit.

write_le16() {
    # Write a 16-bit little-endian value to fd 3
    lo=$(($1 & 0xFF))
    hi=$((($1 >> 8) & 0xFF))
    printf "\\$(printf '%03o' "$lo")\\$(printf '%03o' "$hi")"
}

# Build superblock in a temp file
SUPER=$(mktemp)
{
    write_le16 0x3638   # magic "86"
    write_le16 1        # version
    write_le16 "$FILE_COUNT"
    write_le16 "$FLOPPY_SECTORS"
} > "$SUPER"
# Pad to 512 bytes
SUPER_SIZE=$(wc -c < "$SUPER" | tr -d ' ')
dd if=/dev/zero bs=1 count=$((SECTOR_SIZE - SUPER_SIZE)) 2>/dev/null >> "$SUPER"
dd if="$SUPER" of="$OUTIMG" bs=$SECTOR_SIZE seek=0 conv=notrunc 2>/dev/null
rm -f "$SUPER"

# --- Write directory and file data ---
DIR=$(mktemp)
: > "$DIR"

CUR_SECTOR=$DATA_START

for f in "$@"; do
    RAWNAME=$(basename "$f")
    BASENAME=$(echo "$RAWNAME" | sed 's/\.[^.]*$//' | cut -c1-${NAME_LEN})
    FSIZE=$(wc -c < "$f" | tr -d ' ')

    # Write directory entry (16 bytes)
    ENTRY=$(mktemp)
    {
        # Filename: pad with NULs to NAME_LEN bytes
        NAMELEN=${#BASENAME}
        printf '%s' "$BASENAME"
        i=$NAMELEN
        while [ "$i" -lt "$NAME_LEN" ]; do
            printf '\0'
            i=$((i + 1))
        done
        # start_sect (u16 LE)
        write_le16 "$CUR_SECTOR"
        # size (u16 LE)
        write_le16 "$FSIZE"
        # reserved (4 bytes)
        printf '\0\0\0\0'
    } > "$ENTRY"
    cat "$ENTRY" >> "$DIR"
    rm -f "$ENTRY"

    # Write file data at CUR_SECTOR
    dd if="$f" of="$OUTIMG" bs=$SECTOR_SIZE seek=$CUR_SECTOR conv=notrunc 2>/dev/null

    # Advance sector pointer
    SECTORS_USED=$(( (FSIZE + SECTOR_SIZE - 1) / SECTOR_SIZE ))
    if [ "$SECTORS_USED" -eq 0 ]; then
        SECTORS_USED=1
    fi
    CUR_SECTOR=$((CUR_SECTOR + SECTORS_USED))
done

# Pad directory to sector size
DIR_SIZE=$(wc -c < "$DIR" | tr -d ' ')
if [ "$DIR_SIZE" -lt "$SECTOR_SIZE" ]; then
    dd if=/dev/zero bs=1 count=$((SECTOR_SIZE - DIR_SIZE)) 2>/dev/null >> "$DIR"
fi
dd if="$DIR" of="$OUTIMG" bs=$SECTOR_SIZE seek=$DIR_SECTOR conv=notrunc 2>/dev/null
rm -f "$DIR"

echo "Created $OUTIMG: $FILE_COUNT file(s), data starts at sector $DATA_START"
