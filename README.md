# lol-serial-test

x86 bare-metal assembly program that prints **Hello, World!** to a QEMU
serial console (COM1 / 8250 UART) from a 512-byte boot sector.

---

## Files

| File | Description |
|------|-------------|
| `hello.asm` | NASM x86 real-mode source |
| `Makefile` | Build and run targets |

---

## Prerequisites

### macOS

```bash
brew install nasm qemu
```

### Linux (Debian / Ubuntu)

```bash
sudo apt install nasm qemu-system-x86
```

### Verify

```bash
nasm --version        # >= 2.14 recommended
qemu-system-i386 --version
```

---

## Build

```bash
make
```

This runs:

```
nasm -f bin hello.asm -o hello.img
```

Producing a raw 512-byte boot-sector image (`hello.img`).

---

## Run

```bash
make run
```

This executes:

```
qemu-system-i386 \
    -drive if=none,id=disk0,driver=raw,file.driver=file,file.filename=hello.img,file.locking=off \
    -device ide-hd,drive=disk0 \
    -serial stdio \
    -display none \
    -nographic
```

**Expected output in the terminal:**

```
Hello, World!
```

Press **Ctrl-A**, then **X** to exit QEMU.

---

## How it works

1. QEMU loads the 512-byte image as an IDE disk MBR and jumps to `0x7C00`.
2. The code initialises COM1 (`0x3F8`) at 115200 baud, 8-N-1.
3. Each character is polled through the Transmitter Holding Register Empty
   (THRE) bit of the Line Status Register before being written to the
   Transmit Holding Register.
4. `-serial stdio` in QEMU maps COM1 to the host's stdin/stdout, so the
   output appears directly in your terminal.

---

## Manual QEMU run (without make)

```bash
nasm -f bin hello.asm -o hello.img

qemu-system-i386 \
    -drive if=none,id=disk0,driver=raw,file.driver=file,file.filename=hello.img,file.locking=off \
    -device ide-hd,drive=disk0 \
    -serial stdio \
    -display none \
    -nographic
```

---

## Clean

```bash
make clean
```
