# Native macOS Open Watcom Build Notes

These notes describe the build path that was verified in this workspace for a
native macOS-hosted Open Watcom x86 compiler under
[open-watcom-v2](open-watcom-v2).

## Scope

- Host OS: macOS
- Host CPU used here: Apple Silicon (`arm64`)
- Host toolchain: Apple Clang / Xcode command line tools
- Goal: native Open Watcom host tools plus x86 compiler binaries
- Non-goal: documentation generation, DOSBox, Wine, or installer packaging

## Prerequisites

The build uses the macOS native toolchain. At minimum you need:

```sh
xcode-select --install
```

You also need `make` on `PATH`.

## Environment

From [open-watcom-v2](open-watcom-v2):

```sh
cd /Users/john/depot/os286/open-watcom-v2

export OWROOT="$PWD"
export OWTOOLS=CLANG
export OWDOCBUILD=0
export OWVERBOSE=1
```

`OWDOCBUILD=0` matches the default shell setup in
[setvars.sh](setvars.sh), but it is worth setting explicitly when you want a
compiler-only workflow.

## Bootstrap

Build the native host tools first:

```sh
./build.sh boot
```

This produces the bootstrap tools in [build/binbuild](build/binbuild), notably:

- [build/binbuild/wmake](build/binbuild/wmake)
- [build/binbuild/builder](build/binbuild/builder)
- [build/binbuild/bwcc](build/binbuild/bwcc)

On the machine used for this build, these are native `Mach-O 64-bit executable arm64`
binaries.

## Release Build

To populate the release tree with the host-native compiler binaries:

```sh
OWBUILD_STAGE=build OWTOOLS=CLANG OWROOT="$PWD" OWDOCBUILD=0 OWVERBOSE=1 ./ci/buildx.sh
```

This runs `builder rel` and copies build outputs into [rel](rel).

## Expected Native Compiler Outputs

On Apple Silicon macOS, the host-native toolchain ends up in [rel/armo64](rel/armo64):

- [rel/armo64/wcc](rel/armo64/wcc)
- [rel/armo64/wcc386](rel/armo64/wcc386)
- [rel/armo64/wlink](rel/armo64/wlink)
- [rel/armo64/wasm](rel/armo64/wasm)

Important: [rel/binl](rel/binl) contains Linux-hosted tools, not macOS-hosted
ones. Trying to run [rel/binl/wcc](rel/binl/wcc) on macOS will fail with `exec format error`.

## Using The Native Compiler

Set the runtime environment to the release tree and the macOS host bin
directory:

```sh
export WATCOM="$PWD/rel"
export PATH="$WATCOM/armo64:$PATH"
```

Example smoke test:

```sh
printf 'int main(void){return 0;}\n' > /tmp/ow_smoke.c
wcc /tmp/ow_smoke.c
```

Observed result in this workspace:

- the compiler ran successfully as a native macOS binary
- it compiled the source with `0 warnings, 0 errors`
- it wrote the object file to the current working directory as `ow_smoke.o`

The produced test object was identified as `8086 relocatable (Microsoft)`.

## Notes And Caveats

- `OWDOCBUILD=0` does disable the main docs tree, but it does not prevent all
  help-generation steps.
- In this workspace, `builder rel` still continued into the browser/help area
  and eventually stopped in `bld/browser/nt386` when `wmake` entered
  `docs/nt` and required DOSBox through `build/mif/wgmlcmd.mif`.
- That failure happens after the native compiler binaries above have already
  been produced.
- If your only goal is a usable native compiler toolchain, the build is good
  enough once the binaries in [rel/armo64](rel/armo64) exist and run.

## Verified Outputs In This Workspace

The following files were present after the build attempt:

- [build/binbuild/bwcc](build/binbuild/bwcc)
- [build/binbuild/wmake](build/binbuild/wmake)
- [rel/armo64/wcc](rel/armo64/wcc)
- [rel/armo64/wcc386](rel/armo64/wcc386)
- [rel/armo64/wlink](rel/armo64/wlink)

## Non-native ABI Proof Target

The top-level repository target `make abi-proof` is separate from the native
Open Watcom v2 build documented here. At the time these notes were written, the
top-level [Makefile](../Makefile) still used Wine for that ABI proof path.