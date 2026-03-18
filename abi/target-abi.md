# OS286 Target ABI v0

This document fixes the first C ABI target for OS286 before any compiler
integration work. The goal is not to describe every 80286 possibility. The goal
is to define one small, testable contract that matches the machine state already
implemented in the boot and shell code and that can be emitted by an existing
16-bit compiler.

## Execution model

- CPU mode: 80286 16-bit protected mode.
- Privilege level: ring 0 only.
- Endianness: little-endian.
- Code segment: base 0, limit 64 KiB, near calls only.
- Data segment: base 0, limit 64 KiB, near data only.
- Stack segment: base 0, limit 64 KiB, same logical address space as data.
- Required segment state on C entry: `CS = code`, `DS = ES = SS = data`, `SP`
  valid and even.

This matches the current protected-mode setup in
[boot.asm](/Users/john/depot/os286/boot.asm) and
[shell.asm](/Users/john/depot/os286/shell.asm): flat base-0 descriptors with a
single 64 KiB near code/data world for C.

## Compiler model

The reference compiler for ABI v0 is Open Watcom C in 16-bit DOS small model:

- target: DOS (`-bt=dos`)
- memory model: small (`-ms`)
- calling convention: `__cdecl` (`-ecc`)

Small model is the right fit for the current kernel because all near code and
near data live inside the same flat 64 KiB segment window already established by
the loader.

## Scalar types

ABI v0 assumes the following data model:

- `char` = 8 bits
- `short` = 16 bits
- `int` = 16 bits
- `long` = 32 bits
- near object pointer = 16 bits
- near function pointer = 16 bits

Far pointers, huge pointers, and mixed-model interfaces are out of scope for
ABI v0.

## Structure layout

- Structure fields use the compiler's normal 16-bit alignment rules.
- Natural alignment is capped at 2 bytes in the small-model proof used here.
- No packed-layout ABI is defined unless a specific interface explicitly uses a
  packing pragma.

For kernel-facing interfaces, the practical rule is: if a structure crosses the
ABI boundary, lock its layout with compile-time assertions.

## Calling convention

All external C functions in ABI v0 use near `__cdecl`.

- Arguments are passed on the stack.
- Arguments are pushed right to left.
- The caller removes arguments after the call.
- The callee returns with plain near `ret`.
- The stack grows downward.
- A frame pointer in `BP` is permitted and expected for debug-friendly builds.

For promoted integer arguments:

- `char` and `short` are passed as 16-bit stack slots after C default argument
  promotions.
- 32-bit scalar values occupy two 16-bit stack words in little-endian order.

## Return convention

- 8-bit and 16-bit integer returns: `AX`
- near pointer returns: `AX`
- 32-bit integer returns: `DX:AX`

Aggregate returns are deliberately excluded from ABI v0.

The Open Watcom proof build shows that a small `struct` return in this mode is
implemented through compiler-private DGROUP scratch storage and a returned near
pointer in `AX`. That behaviour is observable in the proof listing, but it is
not a good kernel ABI boundary because it is compiler-specific and not obviously
re-entrant. External OS286 interfaces should therefore use scalar returns or an
explicit caller-provided output pointer.

Floating-point return rules are intentionally not part of ABI v0. OS286 does not
yet define an x87 or software floating-point runtime contract.

## Register volatility

Code written against ABI v0 must treat these registers as volatile across a C
call:

- `AX`, `CX`, `DX`

These registers are treated as preserved by callees:

- `BX`, `SI`, `DI`, `BP`, `DS`

`ES` should be considered scratch unless an interface says otherwise.

## Boundary rules

- Interrupt handlers are not ordinary C functions and do not use this ABI.
- Assembly that calls C must establish `DS = SS = data selector` first.
- Assembly that is called from C must preserve the non-volatile register set and
  return with near `ret`.
- Name decoration is compiler-defined. Assembly interfaces should use explicit
  symbol aliases once kernel-side linkage begins.

## Proof strategy

The proof artifact is a single C file compiled by Open Watcom 16-bit C. It
locks the scalar and structure sizes with compile-time assertions and emits
functions that expose these ABI facts in the generated object code:

- stack arguments addressed from `BP`
- near `__cdecl` calls
- caller stack cleanup after each call
- 32-bit return in `DX:AX`
- observed small-aggregate return through compiler-private DGROUP scratch,
  which is why aggregate return is excluded from ABI v0

The build wrapper generates both an object file and a disassembly listing so the
ABI can be inspected without introducing a full linker or runtime dependency.