; echo.asm — OS286 user program: read chars and echo them.
;
; Reads characters from the console and echoes them back.
; Press Escape (0x1B) to exit.

BITS 16
ORG  0x2000

start:
    ; Print prompt
    mov  si, prompt
.prompt_loop:
    lodsb
    test al, al
    jz   .read
    mov  ah, 0x01           ; SYS_PUTCHAR
    int  0x80
    jmp  .prompt_loop

.read:
    mov  ah, 0x02           ; SYS_GETCHAR
    int  0x80
    cmp  al, 0x1B           ; Escape?
    je   .quit
    mov  ah, 0x01           ; SYS_PUTCHAR
    int  0x80
    cmp  al, 0x0D           ; CR? echo LF too
    jne  .read
    mov  al, 0x0A
    mov  ah, 0x01
    int  0x80
    jmp  .read

.quit:
    ; Print newline and return
    mov  al, 0x0D
    mov  ah, 0x01
    int  0x80
    mov  al, 0x0A
    mov  ah, 0x01
    int  0x80
    ret

prompt: db "Echo (ESC to quit): ", 0
