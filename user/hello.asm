; hello.asm — Sample OS286 user program.
;
; Linked at ORG 0x2000 (PROC_BASE).  Uses INT 0x80 syscalls
; to print a message, then returns to the kernel via RET.

BITS 16
ORG  0x2000

start:
    mov  si, msg
.loop:
    lodsb
    test al, al
    jz   .done
    mov  ah, 0x01           ; SYS_PUTCHAR
    int  0x80
    jmp  .loop
.done:
    ret                     ; return to kernel

msg: db "Hello from userspace!", 0x0D, 0x0A, 0
