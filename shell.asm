; shell.asm — Stage 2: 286 protected-mode shell loaded by boot.asm.
;
; Loaded by Stage 1 into physical RAM at 0x8000.
; Entered in 16-bit protected mode with:
;   CS = SEL_CODE (0x08), no valid DS/ES/SS yet
;
; Shell commands
;   help              print this command list
;   peek <addr>       read  a byte from physical address <addr> (1–6 hex digits)
;   poke <addr> <val> write a byte to  physical address <addr> (1–6 hex digits)
;   dump <addr> [len] hex+ASCII dump (default 128 bytes, max 256)
;                     <addr> may be any 24-bit (6-digit) address in the 80286's
;                     full 16 MB physical address space.
;   halt              halt the CPU
;
; Memory layout (see boot.asm for full map)
;   0x0500–0x0CFF   IDT  (built here)
;   0x6F00          stack top
;   0x7C00–0x7DFF   Stage 1
;   0x8000–0x8FFF   Stage 2 (this file, padded to 8 sectors = 4 KB)

BITS 16
ORG  0x8000

; ── Selectors (must match boot.asm) ───────────────────────────
SEL_NULL     equ 0x00
SEL_CODE     equ 0x08
SEL_DATA     equ 0x10
SEL_PHYSDATA equ 0x18    ; runtime-patchable physical window (entry 3 of GDT)

; ── Shell tunables ────────────────────────────────────────────
CMD_BUF_LEN  equ 64        ; max command-line length (chars, excl. NUL)
IDT_BASE     equ 0x0500    ; physical address of IDT
STACK_TOP    equ 0x6F00    ; PM stack

; ──────────────────────────────────────────────────────────────
; Stage 2 magic sentinel — Stage 1 checks this word is 0xCAFE
; ──────────────────────────────────────────────────────────────
dw 0xCAFE

; ──────────────────────────────────────────────────────────────
; PM entry — CS already SEL_CODE, data registers undefined
; ──────────────────────────────────────────────────────────────
stage2_entry:
    ; Reload data-class segment registers
    mov  ax, SEL_DATA
    mov  ds, ax
    mov  es, ax
    mov  ss, ax
    mov  sp, STACK_TOP

    ; ── Build IDT ─────────────────────────────────────────────
    ; 256 × 8-byte 286 interrupt gate descriptors → IDT_BASE
    ; All vectors point to isr_ignore.
    mov  di, IDT_BASE
    mov  cx, 256
.idt_fill:
    mov  word [di+0], isr_ignore
    mov  word [di+2], SEL_CODE
    mov  byte [di+4], 0x00
    mov  byte [di+5], 0x86          ; P=1 DPL=0 Type=0110 (286 intr gate)
    mov  word [di+6], 0x0000
    add  di, 8
    loop .idt_fill

    lidt [idt_ptr]

    ; ── Save GDT base for runtime segment patching ───────────
    ; phys_setup_seg will use this to locate the SEL_PHYSDATA
    ; GDT entry and patch its base address at will.
    sgdt [gdtr_buf]             ; [gdtr_buf]   = limit word
                                ; [gdtr_buf+2] = 24-bit GDT base (low 16 in a word)

    sti                             ; safe: IDT loaded, PICs fully masked

    ; ── Banner ────────────────────────────────────────────────
    mov  si, msg_banner
    call serial_puts

    ; ── Main REPL ─────────────────────────────────────────────
repl:
    mov  si, msg_prompt
    call serial_puts

    ; Read a line into cmd_buf
    call readline               ; result in cmd_buf, length in CX

    ; Skip empty lines
    jcxz repl

    ; Dispatch
    call dispatch

    jmp  repl

; ──────────────────────────────────────────────────────────────
; readline — read characters from COM1 into cmd_buf until CR.
;   Echoes printable characters back; BS erases last character.
;   Returns: cmd_buf NUL-terminated, CX = number of chars (excl. NUL).
; ──────────────────────────────────────────────────────────────
readline:
    push ax
    push bx
    push di
    mov  di, cmd_buf        ; DI → write position in buffer
    xor  bx, bx             ; BX = current length
.rl_loop:
    call serial_getchar     ; AL ← received byte
    cmp  al, 0x0D           ; CR → end of line
    je   .rl_done
    cmp  al, 0x08           ; BS (backspace)
    je   .rl_bs
    cmp  al, 0x7F           ; DEL (some terminals send this for backspace)
    je   .rl_bs
    cmp  al, 0x20           ; below space → ignore control chars
    jb   .rl_loop
    cmp  bx, CMD_BUF_LEN-1  ; buffer full?
    jae  .rl_loop
    ; Store and echo
    mov  [di], al
    inc  di
    inc  bx
    call serial_putchar
    jmp  .rl_loop
.rl_bs:
    test bx, bx
    jz   .rl_loop           ; nothing to erase
    dec  di
    dec  bx
    ; Send BS SPACE BS to erase the character on the terminal
    push ax
    mov  al, 0x08
    call serial_putchar
    mov  al, 0x20
    call serial_putchar
    mov  al, 0x08
    call serial_putchar
    pop  ax
    jmp  .rl_loop
.rl_done:
    mov  byte [di], 0       ; NUL-terminate
    mov  cx, bx             ; return length
    ; Echo CR+LF
    mov  al, 0x0D
    call serial_putchar
    mov  al, 0x0A
    call serial_putchar
    pop  di
    pop  bx
    pop  ax
    ret

; ──────────────────────────────────────────────────────────────
; dispatch — parse cmd_buf, find matching command, call handler.
; ──────────────────────────────────────────────────────────────
dispatch:
    push si
    push di
    push bx

    ; ── Skip leading spaces ───────────────────────────────────
    mov  si, cmd_buf
.skip_lead:
    mov  al, [si]
    cmp  al, ' '
    jne  .skip_done
    inc  si
    jmp  .skip_lead
.skip_done:

    ; ── Walk command table ────────────────────────────────────
    mov  bx, cmd_table
.cmd_loop:
    mov  di, [bx]           ; pointer to command name string
    test di, di
    jz   .cmd_not_found     ; end-of-table sentinel (NULL pointer)
    call str_match          ; compare [SI..] with [DI..] up to first space
    jc   .cmd_loop_next     ; no match — try next
    ; Match — advance SI past the command word and any spaces
.skip_word:
    mov  al, [si]
    cmp  al, ' '
    je   .skip_spaces
    test al, al
    jz   .call_handler
    inc  si
    jmp  .skip_word
.skip_spaces:
    inc  si
    cmp  byte [si], ' '
    je   .skip_spaces
    jmp  .call_handler
.call_handler:
    ; Handler address is at bx+2
    call word [bx+2]
    jmp  .dispatch_done
.cmd_loop_next:
    add  bx, 4              ; each table entry is 4 bytes (word ptr  + word ptr)
    jmp  .cmd_loop
.cmd_not_found:
    mov  si, msg_unknown
    call serial_puts
.dispatch_done:
    pop  bx
    pop  di
    pop  si
    ret

; ──────────────────────────────────────────────────────────────
; str_match — case-insensitive prefix match.
;   SI → input string (may have trailing args)
;   DI → command name (NUL terminated)
;   Returns: CF=0  if [DI] is a prefix of [SI] and SI[len(DI)] ∈ {' ', 0}
;            CF=1  no match
;   Trashes: nothing (saves AX, BX)
; ──────────────────────────────────────────────────────────────
str_match:
    push ax
    push bx
    push si
    push di
.sm_loop:
    mov  al, [di]
    test al, al
    jz   .sm_end_of_cmd     ; exhausted command name — check delimiter
    mov  bl, [si]
    call to_lower_al        ; lowercase AL (cmd char)
    xchg al, bl
    call to_lower_al        ; lowercase AL (input char)
    xchg al, bl
    cmp  al, bl
    jne  .sm_no_match
    inc  si
    inc  di
    jmp  .sm_loop
.sm_end_of_cmd:
    mov  al, [si]
    cmp  al, ' '
    je   .sm_match
    test al, al
    je   .sm_match
    ; falls through to no_match if next char is not space/NUL
.sm_no_match:
    pop  di
    pop  si
    pop  bx
    pop  ax
    stc
    ret
.sm_match:
    pop  di
    pop  si
    pop  bx
    pop  ax
    clc
    ret

; ──────────────────────────────────────────────────────────────
; to_lower_al — convert AL to lowercase if A-Z
; ──────────────────────────────────────────────────────────────
to_lower_al:
    cmp  al, 'A'
    jb   .done
    cmp  al, 'Z'
    ja   .done
    or   al, 0x20
.done:
    ret

; ──────────────────────────────────────────────────────────────
; parse_hex — parse hex string at SI, return value in BX.
;   SI advances past parsed digits.
;   Returns: CF=0 ok, BX=value
;            CF=1 no valid digit found
; ──────────────────────────────────────────────────────────────
parse_hex:
    push cx
    push ax
    xor  bx, bx
    xor  cx, cx             ; digit count
.ph_loop:
    mov  al, [si]
    call to_lower_al
    cmp  al, '0'
    jb   .ph_done
    cmp  al, '9'
    jbe  .ph_digit
    cmp  al, 'a'
    jb   .ph_done
    cmp  al, 'f'
    ja   .ph_done
    sub  al, 'a'-10
    jmp  .ph_store
.ph_digit:
    sub  al, '0'
.ph_store:
    shl  bx, 4
    and  ax, 0x000F
    or   bx, ax
    inc  si
    inc  cx
    jmp  .ph_loop
.ph_done:
    test cx, cx             ; any digits consumed?
    jz   .ph_fail
    pop  ax
    pop  cx
    clc
    ret
.ph_fail:
    pop  ax
    pop  cx
    stc
    ret

; ──────────────────────────────────────────────────────────────
; parse_hex24 — parse up to 6 hex digits at SI, return 24-bit value.
;   Returns: CF=0 → DX:BX  (DL = bits 23:16, DH = 0, BX = bits 15:0)
;            CF=1 → no valid digit found
;   SI advances past the parsed digits.
; ──────────────────────────────────────────────────────────────
parse_hex24:
    push ax
    push cx
    xor  dx, dx             ; result high (DL = bits 23:16)
    xor  bx, bx             ; result low  (bits 15:0)
    xor  cx, cx             ; digit count
.ph24_loop:
    mov  al, [si]
    call to_lower_al
    cmp  al, '0'
    jb   .ph24_done
    cmp  al, '9'
    jbe  .ph24_digit
    cmp  al, 'a'
    jb   .ph24_done
    cmp  al, 'f'
    ja   .ph24_done
    sub  al, 'a'-10
    jmp  .ph24_store
.ph24_digit:
    sub  al, '0'
.ph24_store:
    ; Shift DX:BX left by 4; the top nibble of BX flows into DL.
    push ax                  ; save incoming digit
    mov  ah, bh
    shr  ah, 4               ; AH = bits 15:12 of BX (nibble to carry into DL)
    shl  dx, 4               ; DX <<= 4 (upper byte climbs; we only care about DL)
    or   dl, ah              ; bring top nibble of old BX into new DL
    shl  bx, 4               ; BX <<= 4
    pop  ax                  ; restore digit
    or   bl, al
    inc  si
    inc  cx
    jmp  .ph24_loop
.ph24_done:
    test cx, cx
    jz   .ph24_fail
    pop  cx
    pop  ax
    clc
    ret
.ph24_fail:
    pop  cx
    pop  ax
    stc
    ret

; skip_spaces helper — advance SI past spaces
skip_spaces:
.ss_loop:
    cmp  byte [si], ' '
    jne  .ss_done
    inc  si
    jmp  .ss_loop
.ss_done:
    ret

; ──────────────────────────────────────────────────────────────
; print_hex_byte — print BL as two hex digits to serial
; ──────────────────────────────────────────────────────────────
print_hex_byte:
    push ax
    push bx
    push cx
    mov  al, bl
    mov  cl, 4
    shr  al, cl
    call .nibble
    mov  al, bl
    and  al, 0x0F
    call .nibble
    pop  cx
    pop  bx
    pop  ax
    ret
.nibble:
    cmp  al, 10
    jb   .digit
    add  al, 'a'-10
    call serial_putchar
    ret
.digit:
    add  al, '0'
    call serial_putchar
    ret

; ──────────────────────────────────────────────────────────────
; print_hex_word — print BX as four hex digits to serial
; ──────────────────────────────────────────────────────────────
print_hex_word:
    push bx
    mov  bl, bh
    call print_hex_byte
    pop  bx
    mov  bl, bl             ; BL already = low byte
    call print_hex_byte
    ret

; ──────────────────────────────────────────────────────────────
; print_hex24 — print DX:BX as 6 hex digits  (DL = bits 23:16, BX = bits 15:0)
; ──────────────────────────────────────────────────────────────
print_hex24:
    push bx
    push dx
    push bx             ; save low 16 bits for second call
    mov  bx, dx         ; BL = DL = bits 23:16
    call print_hex_byte ; emit two high-digit hex chars
    pop  bx             ; restore low 16 bits
    call print_hex_word ; emit four low-digit hex chars
    pop  dx
    pop  bx
    ret

; ──────────────────────────────────────────────────────────────
; phys_setup_seg — aim SEL_PHYSDATA at the 24-bit linear address in DX:BX.
;   DL = bits 23:16,  BX = bits 15:0.
;   Patches bytes 2-4 of the SEL_PHYSDATA GDT descriptor, then reloads ES.
;   The GDT is in flat DS so [GDT_base + SEL_PHYSDATA + 2] is directly writable.
;   Clobbers: AX, DI
; ──────────────────────────────────────────────────────────────
phys_setup_seg:
    push ax
    push di
    ; GDT base was captured into gdtr_buf at startup by SGDT.
    ; The GDT resides in the boot sector (≤0x7FFF), so its base fits in 16 bits.
    mov  di, [gdtr_buf+2]        ; DI = GDT linear base (low 16 bits)
    add  di, SEL_PHYSDATA + 2    ; DI → descriptor bytes 2-4 (base field)
    mov  [di],   bx              ; base[15:0]
    mov  [di+2], dl              ; base[23:16]
    ; Reload ES to flush the descriptor cache with the new base.
    mov  ax, SEL_PHYSDATA
    mov  es, ax
    pop  di
    pop  ax
    ret

; ═══════════════════════════════════════════════════════════════
; COMMAND HANDLERS
; Each handler: SI points to the argument string (after the command
; and any separating spaces).  Trashes: AX, BX, CX, DX, SI, DI.
; ═══════════════════════════════════════════════════════════════

; ── help ──────────────────────────────────────────────────────
cmd_help:
    mov  si, msg_help
    call serial_puts
    ret

; ── peek <addr> ───────────────────────────────────────────────
; Read one byte from physical address <addr> (1–4 hex digits).
; Prints:  [XXXX] = YY
cmd_peek:
    call skip_spaces
    call parse_hex
    jc   .bad_addr
    ; BX = address — must be in [0x0000, 0xFFFF] for our flat segment
    push bx
    mov  al, '['
    call serial_putchar
    call print_hex_word     ; prints BX
    mov  si, str_eq
    call serial_puts
    pop  bx
    mov  bl, [bx]           ; read from flat DS (base=0, limit=0xFFFF)
    call print_hex_byte
    mov  al, 0x0D
    call serial_putchar
    mov  al, 0x0A
    call serial_putchar
    ret
.bad_addr:
    mov  si, msg_usage_peek
    call serial_puts
    ret

; ── poke <addr> <val> ─────────────────────────────────────────
; Write one byte to any 24-bit physical address.
cmd_poke:
    call skip_spaces
    call parse_hex24        ; DX:BX = 24-bit address
    jc   .bad
    push bx                 ; save address lo
    push dx                 ; save address hi
    call skip_spaces
    call parse_hex          ; BX = value byte
    jc   .bad_pop
    mov  al, bl             ; value → AL before we restore the address
    pop  dx
    pop  bx                 ; DX:BX = address again
    call phys_setup_seg     ; ES → physical address
    mov  [es:0], al         ; write byte
    mov  si, msg_ok
    call serial_puts
    ret
.bad_pop:
    pop  dx
    pop  bx
.bad:
    mov  si, msg_usage_poke
    call serial_puts
    ret

; ── halt ──────────────────────────────────────────────────────
cmd_halt:
    mov  si, msg_halting
    call serial_puts
    cli
    hlt
    jmp  $                  ; loop if NMI wakes CPU

; ── dump <addr> [<len>] ───────────────────────────────────────
; Classic hex+ASCII dump, 16 bytes per row, anywhere in the 80286 24-bit space.
; Syntax:  dump <hex-addr> [<hex-len>]
; Default len = 128.  Max len clamped to 256.
;
; Output format:
;   XXXXXX: YY YY YY YY YY YY YY YY  YY YY YY YY YY YY YY YY  |................|
;
; ES is re-aimed via phys_setup_seg at the start of EVERY row so that 24-bit
; address wrap-around works correctly (e.g. 0xfffff0 + 0x10 → 0x000000).
; Each row reads ES:0 .. ES:row_count-1, never crossing a segment boundary.
;
; Register usage inside the row loops:
;   BX / DX — 24-bit row address (DL=bits23:16, BX=bits15:0); set by phys_setup_seg
;   SI       — column offset within the row (0..row_count-1)
;   CX       — per-pass countdown
;   DX       — reused as column index after address label
cmd_dump:
    call skip_spaces
    call parse_hex24        ; DX:BX = 24-bit start address
    jc   .bad
    mov  [dump_base_lo], bx
    mov  [dump_base_hi], dx ; DL = bits 23:16 stored in low byte of word

    call skip_spaces
    call parse_hex          ; optional length (16-bit, value ≤ 256)
    jc   .use_default
    cmp  bx, 0x100          ; clamp to 256
    jbe  .len_ok
    mov  bx, 0x100
.len_ok:
    mov  [dump_count], bx
    jmp  .row_init
.use_default:
    mov  word [dump_count], 128

.row_init:
    mov  word [dump_row_off], 0

.row_loop:
    mov  cx, [dump_count]
    test cx, cx
    jz   .done

    ; row_count = min(count, 16)
    cmp  cx, 16
    jbe  .lt16
    mov  cx, 16
.lt16:
    mov  [dump_row], cx

    ; ── compute 24-bit row address (wraps at 0x1000000) ──────
    ; row_addr = (dump_base + dump_row_off) mod 2^24
    ; adc to DL is 8-bit so overflow naturally wraps bits 23:16.
    mov  bx, [dump_base_lo]
    mov  dx, [dump_base_hi]   ; DL = bits 23:16
    mov  ax, [dump_row_off]
    add  bx, ax
    adc  dl, 0                ; 24-bit add; DL wraps on overflow → correct mod 2^24

    ; Point ES at the row's physical base; DX:BX unchanged after call.
    call phys_setup_seg

    ; ── address label ────────────────────────────────────────
    call print_hex24          ; "XXXXXX"  (DX:BX preserved by callee)
    mov  al, ':'
    call serial_putchar
    mov  al, ' '
    call serial_putchar

    ; ── hex pass — SI = column index 0..row_count-1 ──────────
    xor  si, si
    mov  cx, [dump_row]
    xor  dx, dx               ; DX = column index
.hex_loop:
    test cx, cx
    jz   .hex_pad_start
    cmp  dx, 8                ; extra space between the two groups of 8
    jne  .hex_no_mid
    mov  al, ' '
    call serial_putchar
.hex_no_mid:
    mov  bl, [es:si]          ; physical address = row_base + si
    inc  si
    dec  cx
    call print_hex_byte       ; "YY"
    mov  al, ' '
    call serial_putchar
    inc  dx
    jmp  .hex_loop

    ; pad short last row so the ASCII column stays aligned
.hex_pad_start:
    cmp  dx, 16
    je   .hex_done
    cmp  dx, 8
    jne  .hex_pad_no_mid
    mov  al, ' '
    call serial_putchar
.hex_pad_no_mid:
    mov  al, ' '              ; 3 spaces for missing "YY "
    call serial_putchar
    call serial_putchar
    call serial_putchar
    inc  dx
    jmp  .hex_pad_start
.hex_done:

    ; ── ASCII pass — SI restarts at 0 ────────────────────────
    mov  al, ' '
    call serial_putchar
    mov  al, '|'
    call serial_putchar

    xor  si, si
    mov  cx, [dump_row]
.ascii_loop:
    test cx, cx
    jz   .ascii_done
    mov  al, [es:si]          ; physical address = row_base + si
    inc  si
    dec  cx
    cmp  al, 0x20             ; below space → non-printable
    jb   .dot
    cmp  al, 0x7E             ; above '~'  → non-printable
    ja   .dot
    jmp  .ascii_print
.dot:
    mov  al, '.'
.ascii_print:
    call serial_putchar
    jmp  .ascii_loop
.ascii_done:
    mov  al, '|'
    call serial_putchar
    mov  al, 0x0D
    call serial_putchar
    mov  al, 0x0A
    call serial_putchar

    ; advance row offset and remaining count, loop
    mov  cx, [dump_row]
    add  [dump_row_off], cx
    sub  [dump_count], cx
    jmp  .row_loop

.done:
    ret
.bad:
    mov  si, msg_usage_dump
    call serial_puts
    ret

; ═══════════════════════════════════════════════════════════════
; isr_ignore — no-op ISR for all 256 IDT vectors
; ═══════════════════════════════════════════════════════════════
isr_ignore:
    push ax
    mov  al, 0x20
    out  0xA0, al           ; slave  PIC EOI (harmless for exceptions)
    out  0x20, al           ; master PIC EOI
    pop  ax
    iret

; ──────────────────────────────────────────────────────────────
; Serial routines (shared include)
; ──────────────────────────────────────────────────────────────
%include "serial.inc"

; ═══════════════════════════════════════════════════════════════
; Command dispatch table
;   Each entry: dw <name_ptr>, dw <handler_ptr>
;   Terminated by dw 0, dw 0
; ═══════════════════════════════════════════════════════════════
cmd_table:
    dw  str_help,  cmd_help
    dw  str_peek,  cmd_peek
    dw  str_poke,  cmd_poke
    dw  str_dump,  cmd_dump
    dw  str_halt,  cmd_halt
    dw  0, 0                ; end sentinel

; ── Command name strings ──────────────────────────────────────
str_help:   db "help", 0
str_peek:   db "peek", 0
str_poke:   db "poke", 0
str_dump:   db "dump", 0
str_halt:   db "halt", 0
str_eq:     db "] = ", 0

; ── Messages ──────────────────────────────────────────────────
msg_banner:
    db  0x0D, 0x0A
    db  "286 PM Shell  --  loaded by stage1", 0x0D, 0x0A
    db  "Type 'help' for commands.", 0x0D, 0x0A
    db  0x0D, 0x0A, 0

msg_prompt:         db "> ", 0
msg_unknown:        db "unknown command (try 'help')", 0x0D, 0x0A, 0
msg_ok:             db "ok", 0x0D, 0x0A, 0
msg_halting:        db "Halting.", 0x0D, 0x0A, 0
msg_usage_peek:     db "usage: peek <hex-addr>             (addr up to 6 hex digits)", 0x0D, 0x0A, 0
msg_usage_poke:     db "usage: poke <hex-addr> <hex-val>   (addr up to 6 hex digits)", 0x0D, 0x0A, 0
msg_usage_dump:     db "usage: dump <hex-addr> [<hex-len>] (addr up to 6 hex digits)", 0x0D, 0x0A, 0

msg_help:
    db  "Commands:", 0x0D, 0x0A
    db  "  help              this list", 0x0D, 0x0A
    db  "  peek <addr>       read byte at physical address (24-bit, up to 6 hex digits)", 0x0D, 0x0A
    db  "  poke <addr> <val> write byte to physical address (24-bit)", 0x0D, 0x0A
    db  "  dump <addr> [len] hex+ASCII dump (default 128 bytes; addr 24-bit)", 0x0D, 0x0A
    db  "  halt              halt the CPU", 0x0D, 0x0A
    db  0

; ── IDTR operand (built into static data; IDT itself is in RAM) ──
idt_ptr:
    dw  256*8 - 1
    dd  IDT_BASE

; ── Line input buffer ─────────────────────────────────────────
cmd_buf:    times CMD_BUF_LEN+1 db 0

; ── dump command scratch variables ────────────────────────────
dump_base_lo: dw  0        ; bits 15:0 of the 24-bit dump start address
dump_base_hi: dw  0        ; bits 23:16 in the low byte (DL-equivalent)
dump_row_off: dw  0        ; current row's byte offset from dump_base
dump_count:   dw  0        ; remaining bytes to dump
dump_row:     dw  0        ; bytes in the current row

; ── GDT pointer captured at startup ──────────────────────────
; sgdt stores: word limit at +0, then the GDT linear base starting at +2
; (24-bit base on 286, padded to 4 bytes by the instruction).
gdtr_buf:     times 6 db 0

; ── Pad Stage 2 to exactly STAGE2_SECTORS × 512 bytes ─────────
; boot.asm reads exactly STAGE2_SECTORS from disk; the binary must
; not be shorter (NASM will error if it is too long).
STAGE2_SECTORS  equ 8
times (STAGE2_SECTORS * 512) - ($ - $$) db 0
