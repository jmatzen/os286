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

        EXTRN   _kmain:NEAR

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
gdtr_buf dw      0, 0, 0
STAGE2DATA ENDS

END stage2_image