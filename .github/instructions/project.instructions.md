---
description: Describe when these instructions should be loaded by the agent based on task context
# applyTo: 'Describe when these instructions should be loaded by the agent based on task context' # when provided, instructions will automatically be added to the request context when the pattern matches an attached file
---

This project is a 286 protected mode Unix-like (i.e. Xenix/286)

don't use python for anything.
openwatcom is in /open-watcom-v2
do not use wine, dosbox, or anything else like that as part of the build toolchain.

After the Open Watcom build completes, use the native host compiler from
`/Users/john/depot/os286/open-watcom-v2/rel/armo64` on macOS.

Typical setup:

```sh
export WATCOM=/Users/john/depot/os286/open-watcom-v2/rel
export PATH="$WATCOM/armo64:$PATH"
```

Compile a C file with:

```sh
wcc source.c
```

The compiler writes the object file in the current directory by default. Use
`wcc386` for 386-targeted C and `wlink` to link the resulting objects.

When working on C sources in this repository, prefer `wcc` or `wcc386` where
practical instead of switching to another C compiler.

# notes

floppy driver: https://github.com/Stichting-MINIX-Research-Foundation/minix/blob/master/minix/drivers/storage/floppy/floppy.c
