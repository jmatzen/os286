; boot.asm — Stage 1 boot sector (512 bytes, MBR).
;
; Responsibilities:
;   1. Initialise real-mode segments and stack.
;   2. Init COM1 serial port (polled).
;   3. Mask both 8259A PICs so no hardware IRQ fires during mode switch.
;   4. Load Stage 2 (STAGE2_SECTORS sectors starting at LBA 1) into
;      physical RAM at STAGE2_LOAD (0x8000) using BIOS INT 13h / AH=02h.
;   5. Build a flat 286-compatible GDT in the boot sector's own data area.
;   6. Switch to 286 protected mode (CR0.PE=1).
;   7. Far-jump to STAGE2_LOAD in PM — Stage 2 takes it from there.
;
; Memory map after Stage 1
;   0x0000–0x03FF  real-mode IVT  (abandoned)
;   0x0500–0x0CFF  IDT            (built by Stage 2)
;   0x0D00–0x6EFF  free RAM
;   0x6F00         PM stack top   (set by Stage 2)
;   0x7C00–0x7DFF  Stage 1        (this file)
;   0x8000–…       Stage 2        (C shell + PM shim, loaded here)
;
; Disk layout (single flat image, 512-byte sectors)
;   Sector 0  (LBA 0)  Stage 1 — boot.asm
;   Sector 1+ (LBA 1)  Stage 2 — C shell + PM shim  (STAGE2_SECTORS sectors)

BITS 16
ORG  0x7C00

; ── Constants ─────────────────────────────────────────────────
SEL_NULL        equ 0x00
SEL_CODE        equ 0x08
SEL_DATA        equ 0x10

STAGE2_LOAD     equ 0x8000          ; physical load address for Stage 2
STAGE2_SECTORS  equ 16              ; how many 512-byte sectors to read
                                    ; (must match shell.bin padded size)

; ──────────────────────────────────────────────────────────────
; Entry point — real mode
; ──────────────────────────────────────────────────────────────
start:
    cli
    xor  ax, ax
    mov  ds, ax
    mov  es, ax
    mov  ss, ax
    mov  sp, 0x7C00             ; stack just below boot sector
    sti                         ; safe — still in real mode with IVT intact

    ; BIOS passes the boot drive number in DL — save it
    mov  [boot_drive], dl

    call serial_init

    ; ── Print load message ────────────────────────────────────
    mov  si, msg_loading
    call rm_puts

    ; ── Mask both PICs before we ever leave real mode ─────────
    ; We do this now so the masks are in place before CR0.PE=1.
    ; Stage 2 will re-enable interrupts only after loading the IDT.
    mov  al, 0xFF
    out  0x21, al               ; mask master PIC (IRQ0–7)
    out  0xA1, al               ; mask slave  PIC (IRQ8–15)

    ; ── Load Stage 2 with BIOS INT 13h / AH=02h ──────────────
    ; ES:BX = destination buffer  →  0x0000:0x8000
    ; DL = drive number (saved above)
    ; CH = cylinder 0, CL = starting sector (1-based: sector 2 = LBA 1)
    ; DH = head 0
    ; AL = sector count
    mov  ax, 0x0000
    mov  es, ax
    mov  bx, STAGE2_LOAD
    mov  dl, [boot_drive]
    mov  al, STAGE2_SECTORS
    mov  ch, 0                  ; cylinder 0
    mov  cl, 2                  ; sector 2 (1-based; sector 1 is the MBR)
    mov  dh, 0                  ; head 0
    mov  ah, 0x02               ; INT 13h / AH=02h — read sectors
    int  0x13
    jc   .disk_error            ; CF set on error

    ; ── Verify Stage 2 signature ──────────────────────────────
    ; Stage 2 places 0xCAFE at its very start as a magic sentinel.
    cmp  word [STAGE2_LOAD], 0xCAFE
    jne  .sig_error

    mov  si, msg_ok
    call rm_puts

    ; ── Switch to 286 protected mode ─────────────────────────
    cli                         ; disable interrupts for the switch
    lgdt [gdt_ptr]

    mov  eax, cr0
    or   eax, 0x00000001
    mov  cr0, eax

    ; Far jump into Stage 2 — flushes pipeline, loads CS = SEL_CODE
    ; Stage 2 is physically at 0x8000; its ORG matches that address,
    ; so the label offset from ORG 0x8000 == physical address (CS base=0).
    jmp  SEL_CODE:STAGE2_LOAD

.disk_error:
    mov  si, msg_disk_err
    call rm_puts
    jmp  .halt

.sig_error:
    mov  si, msg_sig_err
    call rm_puts

.halt:
    cli
    hlt
    jmp  .halt

; ──────────────────────────────────────────────────────────────
; rm_puts — print NUL-terminated string at DS:SI in real mode
; (serial_puts from serial.inc is also available but requires
;  the segment setup done by pm_entry; this wrapper is safe in RM)
; ──────────────────────────────────────────────────────────────
rm_puts:
.loop:
    lodsb
    test al, al
    jz   .done
    call serial_putchar
    jmp  .loop
.done:
    ret

; ──────────────────────────────────────────────────────────────
; Serial routines (real-mode safe)
; ──────────────────────────────────────────────────────────────
%include "serial.inc"

; ──────────────────────────────────────────────────────────────
; GDT — three 8-byte 286-compatible descriptors
; ──────────────────────────────────────────────────────────────
align 8
gdt_start:
    ; Entry 0: null descriptor (mandatory)
    dq 0

    ; Entry 1 (SEL_CODE = 0x08): 16-bit code, ring 0
    ;   base=0, limit=0xFFFF, P=1 DPL=0 S=1 Type=1010 (exec/read)
    ;   bytes 6-7 = 0x0000 → 286-compatible (no G/D/B)
    dw 0xFFFF, 0x0000
    db 0x00, 10011010b
    dw 0x0000

    ; Entry 2 (SEL_DATA = 0x10): 16-bit data, ring 0
    ;   base=0, limit=0xFFFF, P=1 DPL=0 S=1 Type=0010 (read/write)
    dw 0xFFFF, 0x0000
    db 0x00, 10010010b
    dw 0x0000

    ; Entry 3 (SEL_PHYSDATA = 0x18): 16-bit data, ring 0 — runtime-patchable physical window
    ;   base=0 (patched by shell at runtime to any 24-bit address), limit=0xFFFF
    ;   Shell patches bytes 2-4 of this descriptor to re-aim ES anywhere in the
    ;   80286's 24-bit (16 MB) address space, then reloads ES with this selector.
    dw 0xFFFF, 0x0000
    db 0x00, 10010010b
    dw 0x0000

gdt_end:

gdt_ptr:
    dw  gdt_end - gdt_start - 1
    dd  gdt_start

; ──────────────────────────────────────────────────────────────
; Data
; ──────────────────────────────────────────────────────────────
boot_drive:     db 0

msg_loading:    db "Stage1: loading stage2...", 0x0D, 0x0A, 0
msg_ok:         db "Stage1: OK, entering PM", 0x0D, 0x0A, 0
msg_disk_err:   db "Stage1: DISK ERROR", 0x0D, 0x0A, 0
msg_sig_err:    db "Stage1: BAD SIGNATURE", 0x0D, 0x0A, 0

; ──────────────────────────────────────────────────────────────
; Boot sector magic
; ──────────────────────────────────────────────────────────────
times 510 - ($ - $$) db 0
dw 0xAA55
