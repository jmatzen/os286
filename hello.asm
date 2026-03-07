; hello.asm — x86 bare-metal "Hello, World!" to COM1 serial port
;
; Assembled as a flat 512-byte MBR boot sector (NASM -f bin).
; QEMU boots it, COM1 output is forwarded to the host terminal.
; Serial routines are shared via serial.inc.

BITS 16
ORG  0x7C00

; ──────────────────────────────────────────────────────────────
; Entry point
; ──────────────────────────────────────────────────────────────
start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti

    call serial_init

    mov  si, msg
    call serial_puts

.halt:
    hlt
    jmp .halt

; ──────────────────────────────────────────────────────────────
; Serial routines — shared include
; ──────────────────────────────────────────────────────────────
%include "serial.inc"

; ──────────────────────────────────────────────────────────────
; Data
; ──────────────────────────────────────────────────────────────
msg:
    db "Hello, World!", 0x0D, 0x0A, 0

; ──────────────────────────────────────────────────────────────
; Boot sector padding + magic signature
; ──────────────────────────────────────────────────────────────
times 510 - ($ - $$) db 0
dw 0xAA55

