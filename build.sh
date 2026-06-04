#!/usr/bin/env bash
set -euo pipefail

export KERNEL_VERSION=5.4
export BUSYBOX_VERSION=1.32.0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

JOBS="${JOBS:-2}"

#
# dependencies
#
if [ "${SKIP_DEPS:-0}" != "1" ]; then
  echo "[+] Checking / installing dependencies..."
  if command -v apt-get >/dev/null 2>&1; then
    if [ "$(id -u)" -eq 0 ]; then
      apt-get -q update
      apt-get -q install -y bc bison flex libelf-dev cpio build-essential libssl-dev qemu-system-x86 wget
    elif command -v sudo >/dev/null 2>&1; then
      sudo apt-get -q update
      sudo apt-get -q install -y bc bison flex libelf-dev cpio build-essential libssl-dev qemu-system-x86 wget
    else
      echo "[-] apt-get is available, but sudo is not. Install dependencies manually or run with SKIP_DEPS=1 in the Docker image." >&2
      exit 1
    fi
  else
    echo "[-] apt-get is not available. Run this script in Linux/WSL or use the Docker wrapper." >&2
    exit 1
  fi
else
  echo "[+] Skipping dependency installation (SKIP_DEPS=1)."
fi

#
# linux kernel
#

echo "[+] Downloading kernel..."
if [ ! -f linux-$KERNEL_VERSION.tar.gz ]; then
  wget -c https://mirrors.edge.kernel.org/pub/linux/kernel/v5.x/linux-$KERNEL_VERSION.tar.gz
else
  echo "[+] Using cached linux-$KERNEL_VERSION.tar.gz."
fi
[ -e linux-$KERNEL_VERSION ] || tar xzf linux-$KERNEL_VERSION.tar.gz

if [ "${FORCE_KERNEL_REBUILD:-0}" != "1" ] && \
  [ -f linux-$KERNEL_VERSION/arch/x86/boot/bzImage ] && \
  [ -f linux-$KERNEL_VERSION/vmlinux ]; then
  echo "[+] Using existing kernel image linux-$KERNEL_VERSION/arch/x86/boot/bzImage."
else
  echo "[+] Building kernel..."
  make -C linux-$KERNEL_VERSION defconfig
  echo "CONFIG_NET_9P=y" >> linux-$KERNEL_VERSION/.config
  echo "CONFIG_NET_9P_DEBUG=n" >> linux-$KERNEL_VERSION/.config
  echo "CONFIG_9P_FS=y" >> linux-$KERNEL_VERSION/.config
  echo "CONFIG_9P_FS_POSIX_ACL=y" >> linux-$KERNEL_VERSION/.config
  echo "CONFIG_9P_FS_SECURITY=y" >> linux-$KERNEL_VERSION/.config
  echo "CONFIG_NET_9P_VIRTIO=y" >> linux-$KERNEL_VERSION/.config
  echo "CONFIG_VIRTIO_PCI=y" >> linux-$KERNEL_VERSION/.config
  echo "CONFIG_VIRTIO_BLK=y" >> linux-$KERNEL_VERSION/.config
  echo "CONFIG_VIRTIO_BLK_SCSI=y" >> linux-$KERNEL_VERSION/.config
  echo "CONFIG_VIRTIO_NET=y" >> linux-$KERNEL_VERSION/.config
  echo "CONFIG_VIRTIO_CONSOLE=y" >> linux-$KERNEL_VERSION/.config
  echo "CONFIG_HW_RANDOM_VIRTIO=y" >> linux-$KERNEL_VERSION/.config
  echo "CONFIG_DRM_VIRTIO_GPU=y" >> linux-$KERNEL_VERSION/.config
  echo "CONFIG_VIRTIO_PCI_LEGACY=y" >> linux-$KERNEL_VERSION/.config
  echo "CONFIG_VIRTIO_BALLOON=y" >> linux-$KERNEL_VERSION/.config
  echo "CONFIG_VIRTIO_INPUT=y" >> linux-$KERNEL_VERSION/.config
  echo "CONFIG_CRYPTO_DEV_VIRTIO=y" >> linux-$KERNEL_VERSION/.config
  echo "CONFIG_BALLOON_COMPACTION=y" >> linux-$KERNEL_VERSION/.config
  echo "CONFIG_PCI=y" >> linux-$KERNEL_VERSION/.config
  echo "CONFIG_PCI_HOST_GENERIC=y" >> linux-$KERNEL_VERSION/.config
  echo "CONFIG_GDB_SCRIPTS=y" >> linux-$KERNEL_VERSION/.config
  echo "CONFIG_DEBUG_INFO=y" >> linux-$KERNEL_VERSION/.config
  echo "CONFIG_DEBUG_INFO_REDUCED=n" >> linux-$KERNEL_VERSION/.config
  echo "CONFIG_DEBUG_INFO_SPLIT=n" >> linux-$KERNEL_VERSION/.config
  echo "CONFIG_DEBUG_FS=y" >> linux-$KERNEL_VERSION/.config
  echo "CONFIG_DEBUG_INFO_DWARF4=y" >> linux-$KERNEL_VERSION/.config
  echo "CONFIG_DEBUG_INFO_BTF=n" >> linux-$KERNEL_VERSION/.config
  echo "CONFIG_FRAME_POINTER=y" >> linux-$KERNEL_VERSION/.config
  make -C linux-$KERNEL_VERSION olddefconfig

  sed -i 'N;s/WARN("missing symbol table");\n\t\treturn -1;/\n\t\treturn 0;\n\t\t\/\/ A missing symbol table is actually possible if its an empty .o file.  This can happen for thunk_64.o./g' linux-$KERNEL_VERSION/tools/objtool/elf.c

  sed -i 's/unsigned long __force_order/\/\/ unsigned long __force_order/g' linux-$KERNEL_VERSION/arch/x86/boot/compressed/pgtable_64.c

  # Fix Linux 5.4 builds with newer GCC versions.
  sed -i 's/REALMODE_CFLAGS\t:= $(M16_CFLAGS)/REALMODE_CFLAGS\t:= -std=gnu89 $(M16_CFLAGS)/' linux-$KERNEL_VERSION/arch/x86/Makefile
  sed -i 's/KBUILD_CFLAGS[[:space:]]*:= $(cflags-y)/KBUILD_CFLAGS := -std=gnu89 $(cflags-y)/' linux-$KERNEL_VERSION/drivers/firmware/efi/libstub/Makefile
  sed -i 's/KBUILD_CFLAGS := -m$(BITS) -O2/KBUILD_CFLAGS := -std=gnu89 -m$(BITS) -O2/' linux-$KERNEL_VERSION/arch/x86/boot/compressed/Makefile
  sed -i 's/-Werror//g' linux-$KERNEL_VERSION/tools/objtool/Makefile
  sed -i 's/-Werror//g' linux-$KERNEL_VERSION/tools/lib/subcmd/Makefile
  sed -i 's/-Werror//g' linux-$KERNEL_VERSION/tools/build/Makefile.build

  make -C linux-$KERNEL_VERSION -j"$JOBS" bzImage \
    HOSTCFLAGS="-Wno-error=redundant-decls -Wno-error=use-after-free"
fi
#
# Busybox
#

echo "[+] Downloading busybox..."
if [ ! -f busybox-$BUSYBOX_VERSION.tar.bz2 ]; then
  wget -c https://busybox.net/downloads/busybox-$BUSYBOX_VERSION.tar.bz2
else
  echo "[+] Using cached busybox-$BUSYBOX_VERSION.tar.bz2."
fi
[ -e busybox-$BUSYBOX_VERSION ] || tar xjf busybox-$BUSYBOX_VERSION.tar.bz2

echo "[+] Building busybox..."
make -C busybox-$BUSYBOX_VERSION defconfig
sed -i 's/# CONFIG_STATIC is not set/CONFIG_STATIC=y/g' busybox-$BUSYBOX_VERSION/.config
sed -i 's/^CONFIG_TC=y/# CONFIG_TC is not set/' busybox-$BUSYBOX_VERSION/.config
sed -i 's/^CONFIG_FEATURE_TC_INGRESS=y/# CONFIG_FEATURE_TC_INGRESS is not set/' busybox-$BUSYBOX_VERSION/.config
make -C busybox-$BUSYBOX_VERSION -j"$JOBS"
make -C busybox-$BUSYBOX_VERSION install

#
# filesystem
#

echo "[+] Building filesystem..."
cd fs
mkdir -p bin sbin etc proc sys usr/bin usr/sbin root home/ctf
cd ..
cp -a busybox-$BUSYBOX_VERSION/_install/* fs

#
# modules
#

echo "[+] Building modules..."
cd src
make
cd ..
cp src/*.ko fs/
