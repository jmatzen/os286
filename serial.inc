; serial.inc — COM1 (8250 UART) polled I/O routines.
;
; %include this file anywhere in a NASM BITS 16 source.
; All routines work identically in real mode and 16-bit protected mode;
; both environments allow I/O at CPL 0 and use the same port map.
;
; COM1 I/O port map  (base = 0x3F8)
; ─────────────────────────────────────────────────────────────────────
;   Base+0  0x3F8  THR (write) / RBR (read)   Tx/Rx Holding Register
;   Base+1  0x3F9  IER                         Interrupt Enable Register
;   Base+2  0x3FA  FCR (write) / IIR (read)   FIFO Control / Status
;   Base+3  0x3FB  LCR                         Line Control Register
;   Base+4  0x3FC  MCR                         Modem Control Register
;   Base+5  0x3FD  LSR                         Line Status Register
;   When LCR bit 7 (DLAB) = 1:
;     Base+0  DLL (Divisor Latch Low byte)
;     Base+1  DLH (Divisor Latch High byte)
;
; LSR bit meanings used here
;   bit 0  DR    Data Ready          — received byte waiting in RBR
;   bit 5  THRE  Tx Holding Reg Empty — safe to write next byte to THR
;
; Exported routines
; ─────────────────────────────────────────────────────────────────────
;   serial_init      Set up COM1: 115200 8-N-1, FIFOs cleared, polled
;   serial_putchar   Send the byte in AL (blocks until THRE)
;   serial_getchar   Read one byte into AL (blocks until DR)
;   serial_puts      Send NUL-terminated string pointed to by SI

; ──────────────────────────────────────────────────────────────────────
; serial_init — initialise COM1
; Clobbers: AX, DX
; ──────────────────────────────────────────────────────────────────────
serial_init:
    ; 1. Disable all UART interrupts
    mov  dx, 0x3F9          ; IER
    xor  al, al
    out  dx, al

    ; 2. Set DLAB=1 to access baud-rate divisor latches
    mov  dx, 0x3FB          ; LCR
    mov  al, 0x80
    out  dx, al

    ; 3. Divisor = 1  →  115200 baud  (UART clock 1.8432 MHz / 16 / 1)
    mov  dx, 0x3F8          ; DLL
    mov  al, 0x01
    out  dx, al
    mov  dx, 0x3F9          ; DLH
    xor  al, al
    out  dx, al

    ; 4. LCR = 0x03 → 8 data bits, no parity, 1 stop bit, clear DLAB
    mov  dx, 0x3FB          ; LCR
    mov  al, 0x03
    out  dx, al

    ; 5. FCR = 0xC7 → enable FIFO, clear Rx & Tx queues, 14-byte trigger
    mov  dx, 0x3FA          ; FCR
    mov  al, 0xC7
    out  dx, al

    ; 6. MCR = 0x0B → assert DTR & RTS, enable OUT2 (required for IRQ on
    ;    real hardware; harmless for polled use)
    mov  dx, 0x3FC          ; MCR
    mov  al, 0x0B
    out  dx, al
    ret

; ──────────────────────────────────────────────────────────────────────
; serial_putchar — transmit byte in AL, spin until THRE
; Clobbers: nothing  (saves & restores AX, DX)
; ──────────────────────────────────────────────────────────────────────
serial_putchar:
    push ax
    push dx
    mov  ah, al             ; stash byte — IN will overwrite AL
.spc_spin:
    mov  dx, 0x3FD          ; LSR
    in   al, dx
    test al, 0x20           ; THRE bit 5
    jz   .spc_spin
    mov  dx, 0x3F8          ; THR — write byte
    mov  al, ah
    out  dx, al
    pop  dx
    pop  ax
    ret

; ──────────────────────────────────────────────────────────────────────
; serial_getchar — block until a byte arrives, return it in AL
; Clobbers: AX, DX
; ──────────────────────────────────────────────────────────────────────
serial_getchar:
.sgc_spin:
    mov  dx, 0x3FD          ; LSR
    in   al, dx
    test al, 0x01           ; DR bit 0
    jz   .sgc_spin
    mov  dx, 0x3F8          ; RBR — read received byte
    in   al, dx
    ret

; ──────────────────────────────────────────────────────────────────────
; serial_puts — send NUL-terminated string at DS:SI, SI advances past NUL
; Clobbers: AL, SI
; ──────────────────────────────────────────────────────────────────────
serial_puts:
.sp_loop:
    mov  al, [si]
    test al, al             ; NUL terminator?
    jz   .sp_done
    inc  si
    call serial_putchar
    jmp  .sp_loop
.sp_done:
    ret
