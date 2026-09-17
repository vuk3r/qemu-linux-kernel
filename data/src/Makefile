# Every C source here is a kernel module except the guest-side sudo program.
# Kbuild parses this file from the kernel tree, so discover sources relative to
# its exported $(src), not relative to Kbuild's current directory.
MODULE_DIR := $(if $(src),$(src),$(CURDIR))
module_sources := $(notdir $(wildcard $(MODULE_DIR)/*.c))
module_sources := $(filter-out sudo.c %.mod.c,$(module_sources))
obj-m := $(patsubst %.c,%.o,$(module_sources))
KERNEL_VERSION=6.8.9
KERNEL_DIR ?= ../build/linux-$(KERNEL_VERSION)

all:
	$(MAKE) -C "$(KERNEL_DIR)" M="$(CURDIR)" modules

clean:
	$(MAKE) -C "$(KERNEL_DIR)" M="$(CURDIR)" clean
