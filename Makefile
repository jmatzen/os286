# ── Toolchain ─────────────────────────────────────────────────
ASM    := nasm
QEMU   := qemu-system-i386
WATCOM ?= /Users/john/depot/os286/open-watcom-v2/rel
OWBIN  ?= $(WATCOM)/armo64
WCC    := $(OWBIN)/wcc
WLINK  := $(OWBIN)/wlink
WASM   := $(OWBIN)/wasm
WDIS   := $(OWBIN)/wdis

# ── Files ─────────────────────────────────────────────────────
IMG_RM   := hello.img          # real-mode hello world
IMG_PM   := hello_pm.img       # standalone 286 PM echo demo
IMG_OS   := os.img             # 2-stage: boot.asm + shell.asm
STAGE2_SECTORS := 16

STAGE1   := boot.bin
STAGE2   := shell.bin
STAGE2_C_OBJ   := stage2_shell.o
STAGE2_ASM_OBJ := stage2_start.obj
STAGE2_MAP     := shell.map
STAGE2_LNK     := shell.lnk

# ── Default target ────────────────────────────────────────────
.PHONY: all
all: $(IMG_RM) $(IMG_PM) $(IMG_OS)

# ── Assemble flat binary images ───────────────────────────────
$(IMG_RM): hello.asm serial.inc
	$(ASM) -f bin $< -o $@
	@echo "Built $@ ($$(wc -c < $@) bytes)"

$(IMG_PM): hello_pm.asm serial.inc
	$(ASM) -f bin $< -o $@
	@echo "Built $@ ($$(wc -c < $@) bytes)"

$(STAGE1): boot.asm serial.inc
	$(ASM) -f bin $< -o $@
	@echo "Built $@ ($$(wc -c < $@) bytes)"

$(STAGE2_ASM_OBJ): shell.asm
	$(WASM) -q -fo=$@ $<

$(STAGE2_C_OBJ): shell.c
	WATCOM=$(WATCOM) EDPATH=$(WATCOM)/eddat INCLUDE=$(WATCOM)/h $(WCC) -q -bt=dos -ms -ecc -s -zl -zu -fo=$@ $<

$(STAGE2): $(STAGE2_ASM_OBJ) $(STAGE2_C_OBJ) $(STAGE2_LNK)
	$(WLINK) @$(STAGE2_LNK)
	@size=$$(wc -c < $@); \
	if [ "$$size" -gt $$(( $(STAGE2_SECTORS) * 512 )) ]; then \
		echo "Stage 2 is $$size bytes, exceeds $$(( $(STAGE2_SECTORS) * 512 )) bytes"; \
		exit 1; \
	fi
	@truncate -s $$(( $(STAGE2_SECTORS) * 512 )) $@
	@echo "Built $@ ($$(wc -c < $@) bytes padded)"

# Concatenate stage1 + stage2 into a single disk image
$(IMG_OS): $(STAGE1) $(STAGE2)
	cat $^ > $@
	@echo "Built $@ ($$(wc -c < $@) bytes)"

# ── QEMU helper macro ─────────────────────────────────────────
# file.locking=off is required on volumes that do not support
# POSIX byte-range locks (e.g. AFP/SMB/APFS network mounts).
define qemu_run
	$(QEMU) \
	    -drive if=none,id=disk0,driver=raw,file.driver=file,file.locking=off,file.filename=$(1) \
	    -device ide-hd,drive=disk0 \
	    -serial mon:stdio \
	    -display none \
	    -nographic
endef

# ── Run targets ───────────────────────────────────────────────
.PHONY: run
run: $(IMG_RM)
	$(call qemu_run,$(IMG_RM))

.PHONY: run-pm
run-pm: $(IMG_PM)
	$(call qemu_run,$(IMG_PM))

.PHONY: run-os
run-os: $(IMG_OS)
	$(call qemu_run,$(IMG_OS))

.PHONY: abi-proof
abi-proof:
	rm -f abi/abi_proof.obj abi/abi_proof.lst abi/abi_proof.err
	@WATCOM=$(WATCOM) EDPATH=$(WATCOM)/eddat INCLUDE=$(WATCOM)/h $(WCC) -q -bt=dos -ms -ecc -s -d1 -of+ -fo=abi/abi_proof.obj abi/abi_proof.c > abi/abi_proof.err 2>&1 || { cat abi/abi_proof.err; exit 1; }
	@WATCOM=$(WATCOM) EDPATH=$(WATCOM)/eddat INCLUDE=$(WATCOM)/h $(WDIS) -s abi/abi_proof.obj > abi/abi_proof.lst 2>> abi/abi_proof.err || { cat abi/abi_proof.err; exit 1; }
	@echo "ABI proof build succeeded."

.PHONY: abi-proof-clean
abi-proof-clean:
	rm -f abi/abi_proof.obj abi/abi_proof.lst abi/abi_proof.err

# ── Clean ─────────────────────────────────────────────────────
.PHONY: clean
clean:
	rm -f $(IMG_RM) $(IMG_PM) $(IMG_OS) $(STAGE1) $(STAGE2)
	rm -f $(STAGE2_C_OBJ) $(STAGE2_ASM_OBJ) $(STAGE2_MAP)
	rm -f abi/abi_proof.obj abi/abi_proof.lst abi/abi_proof.err

