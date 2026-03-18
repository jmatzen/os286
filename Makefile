# ── Toolchain ─────────────────────────────────────────────────
ASM    := nasm
QEMU   := qemu-system-i386

# ── Files ─────────────────────────────────────────────────────
IMG_RM   := hello.img          # real-mode hello world
IMG_PM   := hello_pm.img       # standalone 286 PM echo demo
IMG_OS   := os.img             # 2-stage: boot.asm + shell.asm

WINE     := arch -x86_64 /opt/homebrew/bin/wine

STAGE1   := boot.bin
STAGE2   := shell.bin

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

$(STAGE2): shell.asm serial.inc
	$(ASM) -f bin $< -o $@
	@echo "Built $@ ($$(wc -c < $@) bytes)"

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
	$(WINE) cmd /c Z:\\Users\\john\\depot\\os286\\abi\\ow_build.bat

.PHONY: abi-proof-clean
abi-proof-clean:
	rm -f abi/abi_proof.obj abi/abi_proof.lst abi/abi_proof.err

# ── Clean ─────────────────────────────────────────────────────
.PHONY: clean
clean:
	rm -f $(IMG_RM) $(IMG_PM) $(IMG_OS) $(STAGE1) $(STAGE2)
	rm -f abi/abi_proof.obj abi/abi_proof.lst abi/abi_proof.err

