; hello_pm.asm — 286-style 16-bit protected-mode boot sector.
;
;   1. Enters 286-compatible protected mode (GDT with zero upper bytes).
;   2. Prints "Hello, World! (286 Protected Mode)" to COM1.
;   3. Enters a serial echo loop: every received byte is transmitted back.
;      Bare CR (0x0D) is expanded to CR+LF for clean line endings.
;
; Serial routines are shared via serial.inc (serial_init, serial_putchar,
; serial_getchar, serial_puts).
;
; 286 descriptor format (8 bytes each)
;   [0..1]  limit[15:0]  max 0xFFFF (64 KB − 1, byte granularity)
;   [2..3]  base[15:0]
;   [4]     base[23:16]  (24-bit physical address)
;   [5]     access byte  P | DPL | S | Type
;   [6..7]  0x0000       reserved on 286 (no G/D/B bits)
;
; Memory layout
;   0x0000–0x03FF  IVT (not used after PM entry)
;   0x0500–0x0CFF  IDT (built at runtime: 256 × 8-byte interrupt gates)
;   0x0D00–0x6EFF  free RAM
;   0x6F00          PM stack top
;   0x7C00–0x7DFF  this boot sector (code + GDT + data)

BITS 16
ORG  0x7C00

; ── Selector constants ────────────────────────────────────────
; A selector is a GDT byte offset with RPL=0, TI=0.
SEL_NULL  equ 0x00
SEL_CODE  equ 0x08      ; descriptor 1 — 16-bit code, ring 0
SEL_DATA  equ 0x10      ; descriptor 2 — 16-bit data, ring 0

; ──────────────────────────────────────────────────────────────
; Real-mode entry
; ──────────────────────────────────────────────────────────────
start:
    cli                     ; disable interrupts — must stay off until we have an IDT
    xor  ax, ax
    mov  ds, ax
    mov  es, ax
    mov  ss, ax
    mov  sp, 0x7C00         ; stack below boot sector
    ; NOTE: no sti — we never re-enable interrupts.  serial_init is polled I/O
    ; and needs no interrupts.  Re-enabling here would let the 8253 timer IRQ0
    ; fire between PE=1 and pm_entry, where there is no IDT — instant triple-fault.

    call serial_init        ; program COM1 while BIOS state is intact

    ; ── Mask all IRQs on both 8259A PICs ──────────────────────
    ; The PIT timer (IRQ0) fires every ~55 ms.  In PM without an IDT any
    ; unmasked IRQ causes a triple-fault → CPU reset.  We mask every line on
    ; both master (0x21) and slave (0xA1) PIC before touching CR0.
    mov  al, 0xFF
    out  0x21, al           ; mask all 8 master IRQs (IRQ0-7)
    out  0xA1, al           ; mask all 8 slave  IRQs (IRQ8-15)

    lgdt [gdt_ptr]          ; load GDTR

    ; Set CR0.PE — enter protected mode
    mov  eax, cr0           ; 0x66 prefix emitted by NASM (BITS 16)
    or   eax, 0x00000001
    mov  cr0, eax

    ; Far jump: flush pipeline + load CS with PM code selector
    jmp  SEL_CODE:pm_entry

; ──────────────────────────────────────────────────────────────
; 16-bit protected-mode entry
; ──────────────────────────────────────────────────────────────
pm_entry:
    mov  ax, SEL_DATA       ; reload data-class registers with PM selectors
    mov  ds, ax             ; (stale real-mode values are illegal in PM)
    mov  es, ax
    mov  ss, ax
    mov  sp, 0x6F00         ; PM stack (inside flat 64 KB segment)

    ; ── Build IDT at 0x0500 ──────────────────────────────────
    ; Dynamically fill 256 × 8-byte 286-compatible interrupt gate descriptors,
    ; all pointing to isr_ignore.  Physical RAM at 0x0500–0x0CFF is free.
    ;
    ; 286 interrupt gate layout (8 bytes):
    ;   [0..1]  handler offset[15:0]  — label value == phys addr (CS base = 0)
    ;   [2..3]  code segment selector
    ;   [4]     0x00 (reserved / param count)
    ;   [5]     0x86 → P=1 DPL=0 Type=0110 (286 16-bit interrupt gate)
    ;   [6..7]  0x0000 (286 reserved — must be zero)
    mov  di, 0x0500
    mov  cx, 256
.idt_fill:
    mov  word [di+0], isr_ignore    ; handler offset (physical, CS base = 0)
    mov  word [di+2], SEL_CODE      ; code segment selector
    mov  byte [di+4], 0x00
    mov  byte [di+5], 0x86          ; P=1 DPL=0 Type=0110
    mov  word [di+6], 0x0000
    add  di, 8
    loop .idt_fill

    lidt [idt_ptr]          ; load IDTR

    ; Interrupts are now safe to enable: IDT is loaded and both PICs are
    ; fully masked (done before CR0.PE), so no hardware IRQ can fire.
    ; CPU exceptions will hit isr_ignore instead of triple-faulting.
    sti

    ; ── Print banner ──────────────────────────────────────────
    mov  si, msg_hello
    call serial_puts

    ; ── Print echo prompt ─────────────────────────────────────
    mov  si, msg_prompt
    call serial_puts

    ; ── Echo loop ─────────────────────────────────────────────
    ; Receive one byte, transmit it back.  Bare CR → CR+LF.
echo_loop:
    call serial_getchar     ; AL ← next received byte (blocks)
    call serial_putchar     ; echo byte back
    cmp  al, 0x0D           ; was it a bare CR?
    jne  echo_loop
    mov  al, 0x0A           ; yes — append LF for clean line endings
    call serial_putchar
    jmp  echo_loop

; (unreachable — loop is infinite)
    cli
    hlt

; ──────────────────────────────────────────────────────────────
; isr_ignore — no-op ISR installed for all 256 IDT vectors.
;
;   Sends a non-specific End-Of-Interrupt (EOI, 0x20) to both PIC chips
;   so the controller clears its ISR bit.  For CPU exceptions no EOI is
;   needed, but sending one is harmless.  Returns with IRET.
;
; Clobbers: nothing (saves & restores AX)
; ──────────────────────────────────────────────────────────────
isr_ignore:
    push ax
    mov  al, 0x20
    out  0xA0, al           ; slave  PIC — non-specific EOI
    out  0x20, al           ; master PIC — non-specific EOI
    pop  ax
    iret

; ──────────────────────────────────────────────────────────────
; Serial routines — shared include
; ──────────────────────────────────────────────────────────────
%include "serial.inc"

; ──────────────────────────────────────────────────────────────
; GDT — three 8-byte 286-compatible descriptors
; ──────────────────────────────────────────────────────────────
align 8
gdt_start:
    ; Descriptor 0: null (mandatory)
    dq 0

    ; Descriptor 1 (SEL_CODE = 0x08): 16-bit execute/read, ring 0
    dw 0xFFFF           ; limit[15:0] = 64 KB
    dw 0x0000           ; base[15:0]  = 0
    db 0x00             ; base[23:16] = 0
    db 10011010b        ; P=1 DPL=0 S=1 Type=1010
    dw 0x0000           ; 286 reserved bytes (must be zero)

    ; Descriptor 2 (SEL_DATA = 0x10): 16-bit read/write, ring 0
    dw 0xFFFF
    dw 0x0000
    db 0x00
    db 10010010b        ; P=1 DPL=0 S=1 Type=0010
    dw 0x0000

gdt_end:

; LGDT operand: 2-byte limit, 4-byte linear base
gdt_ptr:
    dw  gdt_end - gdt_start - 1
    dd  gdt_start

; LIDT operand: 2-byte limit, 4-byte linear base
; IDT entries are written to this address at runtime by the build loop.
idt_ptr:
    dw  256*8 - 1           ; limit = 2047 (256 entries × 8 bytes − 1)
    dd  0x0500              ; linear base — free RAM below boot sector

; ──────────────────────────────────────────────────────────────
; Data
; ──────────────────────────────────────────────────────────────
msg_hello:
    db  "Hello, World! (286 Protected Mode)", 0x0D, 0x0A, 0
msg_prompt:
    db  "Echo ready -- type to echo:", 0x0D, 0x0A, 0

; ──────────────────────────────────────────────────────────────
; Boot sector signature
; ──────────────────────────────────────────────────────────────
times 510 - ($ - $$) db 0
dw 0xAA55
