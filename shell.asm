.286p

SEL_CODE     EQU 08h
SEL_DATA     EQU 10h
SEL_PHYSDATA EQU 18h
IDT_BASE     EQU 0500h
STACK_TOP    EQU 06F00h

DGROUP GROUP STAGE2DATA

BEGTEXT SEGMENT BYTE PUBLIC USE16 'CODE'
        ASSUME cs:BEGTEXT, ds:DGROUP, es:DGROUP, ss:DGROUP

        PUBLIC  stage2_image
        PUBLIC  _serial_putchar
        PUBLIC  _serial_getchar
        PUBLIC  _pm_read_phys
        PUBLIC  _pm_write_phys
        PUBLIC  _stage2_halt
        PUBLIC  _outb
        PUBLIC  _inb
        PUBLIC  _pic_remap
        PUBLIC  _idt_set_gate
        PUBLIC  _floppy_irq_flag
        PUBLIC  _syscall_entry

        EXTRN   _kmain:NEAR
        EXTRN   _fault_handler:NEAR
        EXTRN   _irq_handler:NEAR
        EXTRN   _syscall_dispatch:NEAR

stage2_image:
        dw      0CAFEh

stage2_entry:
        mov     ax, SEL_DATA
        mov     ds, ax
        mov     es, ax
        mov     ss, ax
        mov     sp, STACK_TOP

        mov     di, IDT_BASE
        mov     cx, 256
idt_fill:
        mov     word ptr [di+0], OFFSET isr_ignore
        mov     word ptr [di+2], SEL_CODE
        mov     byte ptr [di+4], 00h
        mov     byte ptr [di+5], 86h
        mov     word ptr [di+6], 0000h
        add     di, 8
        loop    idt_fill

        lidt    fword ptr [idt_ptr]
        sgdt    fword ptr [gdtr_buf]
        sti

        call    _kmain
        jmp     _stage2_halt

isr_ignore:
        push    ax
        mov     al, 20h
        out     0A0h, al
        out     020h, al
        pop     ax
        iret

;; ── Port I/O wrappers for C ──────────────────────────────────
;; void __cdecl outb(u16 port, u8 val);
_outb proc near
        push    bp
        mov     bp, sp
        push    ax
        push    dx
        mov     dx, word ptr [bp+4]     ; port
        mov     al, byte ptr [bp+6]     ; val
        out     dx, al
        pop     dx
        pop     ax
        pop     bp
        ret
_outb endp

;; u8 __cdecl inb(u16 port);
_inb proc near
        push    bp
        mov     bp, sp
        push    dx
        mov     dx, word ptr [bp+4]     ; port
        in      al, dx
        xor     ah, ah
        pop     dx
        pop     bp
        ret
_inb endp

;; ── PIC remapping ────────────────────────────────────────────
;; void __cdecl pic_remap(void)
;; Remaps master PIC to INT 0x20, slave to INT 0x28.
_pic_remap proc near
        push    ax
        push    dx

        ;; ICW1: begin init, ICW4 needed
        mov     al, 11h
        out     020h, al
        call    io_delay
        out     0A0h, al
        call    io_delay

        ;; ICW2: vector offsets
        mov     al, 20h             ; master starts at 0x20
        out     021h, al
        call    io_delay
        mov     al, 28h             ; slave starts at 0x28
        out     0A1h, al
        call    io_delay

        ;; ICW3: cascade wiring
        mov     al, 04h             ; master: slave on IRQ2
        out     021h, al
        call    io_delay
        mov     al, 02h             ; slave: cascade identity 2
        out     0A1h, al
        call    io_delay

        ;; ICW4: 8086 mode
        mov     al, 01h
        out     021h, al
        call    io_delay
        out     0A1h, al
        call    io_delay

        ;; Mask all IRQs initially
        mov     al, 0FFh
        out     021h, al
        out     0A1h, al

        pop     dx
        pop     ax
        ret
_pic_remap endp

io_delay:
        jmp     short $+2
        jmp     short $+2
        ret

;; ── IDT gate writer ──────────────────────────────────────────
;; void __cdecl idt_set_gate(u16 vector, u16 offset, u16 selector, u8 type_attr);
_idt_set_gate proc near
        push    bp
        mov     bp, sp
        push    ax
        push    bx
        push    di
        push    es

        mov     ax, SEL_DATA
        mov     es, ax

        ;; Compute IDT entry address: IDT_BASE + vector * 8
        mov     ax, word ptr [bp+4]     ; vector
        shl     ax, 1
        shl     ax, 1
        shl     ax, 1
        add     ax, IDT_BASE
        mov     di, ax

        ;; Write the 8-byte gate descriptor
        mov     ax, word ptr [bp+6]     ; offset
        mov     es:[di+0], ax
        mov     ax, word ptr [bp+8]     ; selector
        mov     es:[di+2], ax
        mov     byte ptr es:[di+4], 00h
        mov     al, byte ptr [bp+10]    ; type_attr
        mov     es:[di+5], al
        mov     word ptr es:[di+6], 0000h

        pop     es
        pop     di
        pop     bx
        pop     ax
        pop     bp
        ret
_idt_set_gate endp

;; ── Exception stubs ──────────────────────────────────────────
;; Each pushes the vector number and calls _fault_handler.
;; _fault_handler never returns (it halts).

ISR_EXC MACRO num
_isr_exc_&num proc near
        push    num
        call    _fault_handler
        add     sp, 2
        iret
_isr_exc_&num endp
        PUBLIC _isr_exc_&num
ENDM

ISR_EXC 0
ISR_EXC 1
ISR_EXC 2
ISR_EXC 3
ISR_EXC 4
ISR_EXC 5
ISR_EXC 6
ISR_EXC 7
ISR_EXC 8
ISR_EXC 9
ISR_EXC 10
ISR_EXC 11
ISR_EXC 12
ISR_EXC 13
ISR_EXC 14
ISR_EXC 15
ISR_EXC 16

;; ── IRQ stubs ────────────────────────────────────────────────
;; Each saves registers, calls _irq_handler(irq_num), sends EOI.

ISR_IRQ MACRO num
_isr_irq_&num proc near
        push    ax
        push    cx
        push    dx
        push    ds
        push    es
        mov     ax, SEL_DATA
        mov     ds, ax
        mov     es, ax
        push    num
        call    _irq_handler
        add     sp, 2
IF num GE 8
        mov     al, 20h
        out     0A0h, al
ENDIF
        mov     al, 20h
        out     020h, al
        pop     es
        pop     ds
        pop     dx
        pop     cx
        pop     ax
        iret
_isr_irq_&num endp
        PUBLIC _isr_irq_&num
ENDM

ISR_IRQ 0
ISR_IRQ 1
ISR_IRQ 2
ISR_IRQ 3
ISR_IRQ 4
ISR_IRQ 5
ISR_IRQ 6
ISR_IRQ 7
ISR_IRQ 8
ISR_IRQ 9
ISR_IRQ 10
ISR_IRQ 11
ISR_IRQ 12
ISR_IRQ 13
ISR_IRQ 14
ISR_IRQ 15

;; ── Syscall handler (INT 0x80) ───────────────────────────────
;; AX = syscall (AH=number, AL=sub-param), BX=arg
;; Returns result in AX.
_syscall_entry proc near
        push    ds
        push    es
        push    bx
        push    cx
        push    dx

        mov     cx, SEL_DATA
        mov     ds, cx
        mov     es, cx

        ;; Push args: ax (syscall+param), bx (extra arg)
        push    bx
        push    ax
        call    _syscall_dispatch
        add     sp, 4
        ;; Return value is in AX

        pop     dx
        pop     cx
        pop     bx
        pop     es
        pop     ds
        iret
_syscall_entry endp

_serial_putchar proc near
        push    bp
        mov     bp, sp
        push    ax
        push    dx

        mov     al, byte ptr [bp+4]
        mov     ah, al
spc_spin:
        mov     dx, 03FDh
        in      al, dx
        test    al, 20h
        jz      spc_spin
        mov     dx, 03F8h
        mov     al, ah
        out     dx, al

        pop     dx
        pop     ax
        pop     bp
        ret
_serial_putchar endp

_serial_getchar proc near
sgc_spin:
        mov     dx, 03FDh
        in      al, dx
        test    al, 01h
        jz      sgc_spin
        mov     dx, 03F8h
        in      al, dx
        xor     ah, ah
        ret
_serial_getchar endp

_pm_read_phys proc near
        push    bp
        mov     bp, sp
        push    bx
        push    dx
        push    di
        push    es

        mov     bx, [bp+4]
        mov     dx, [bp+6]
        call    phys_setup_es
        xor     ax, ax
        mov     al, es:[0]

        pop     es
        pop     di
        pop     dx
        pop     bx
        pop     bp
        ret
_pm_read_phys endp

_pm_write_phys proc near
        push    bp
        mov     bp, sp
        push    ax
        push    bx
        push    dx
        push    di
        push    es

        mov     bx, [bp+4]
        mov     dx, [bp+6]
        mov     ah, byte ptr [bp+8]
        call    phys_setup_es
        mov     es:[0], ah

        pop     es
        pop     di
        pop     dx
        pop     bx
        pop     ax
        pop     bp
        ret
_pm_write_phys endp

_stage2_halt proc near
        cli
halt_loop:
        hlt
        jmp     halt_loop
_stage2_halt endp

phys_setup_es:
        mov     di, word ptr gdtr_buf+2
        add     di, SEL_PHYSDATA + 2
        mov     [di], bx
        mov     [di+2], dl
        mov     ax, SEL_PHYSDATA
        mov     es, ax
        ret

idt_ptr:
        dw      256 * 8 - 1
        dd      IDT_BASE

BEGTEXT ENDS

STAGE2DATA SEGMENT WORD PUBLIC USE16 'DATA'
        PUBLIC  gdtr_buf
        PUBLIC  _floppy_irq_flag
gdtr_buf dw      0, 0, 0
_floppy_irq_flag dw 0
STAGE2DATA ENDS

END stage2_image