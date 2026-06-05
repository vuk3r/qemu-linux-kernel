#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

KERNEL_IMAGE="${KERNEL_IMAGE:-linux-5.4/arch/x86/boot/bzImage}"
HOST_SHARE="${HOST_SHARE:-$SCRIPT_DIR/share}"
QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
QEMU_MEMORY="${QEMU_MEMORY:-512M}"
ENABLE_GDB="${ENABLE_GDB:-0}"
GDB_PORT="${GDB_PORT:-1234}"

if [ ! -f "$KERNEL_IMAGE" ]; then
	echo "[-] Missing $KERNEL_IMAGE. Run ./build.sh first." >&2
	exit 1
fi

if ! command -v "$QEMU_BIN" >/dev/null 2>&1; then
	echo "[-] Missing $QEMU_BIN. Install qemu-system-x86 or use the Docker wrapper." >&2
	exit 1
fi

mkdir -p "$HOST_SHARE"

#
# build root fs
#
pushd fs >/dev/null
find . -print0 | cpio --null -o --format=newc --quiet | gzip -9 > ../initramfs.cpio.gz
popd >/dev/null

#
# launch
#
qemu_args=()
if [ "$ENABLE_GDB" = "1" ]; then
	qemu_args+=(-gdb "tcp::${GDB_PORT}")
fi

"$QEMU_BIN" \
	-kernel "$KERNEL_IMAGE" \
	-initrd "$PWD/initramfs.cpio.gz" \
	-fsdev local,security_model=passthrough,id=fsdev0,path="$HOST_SHARE" \
	-device virtio-9p-pci,id=fs0,fsdev=fsdev0,mount_tag=hostshare \
	-m "$QEMU_MEMORY" \
	-nographic \
	-monitor none \
	-no-reboot \
	"${qemu_args[@]}" \
	-append "console=ttyS0 nokaslr panic=-1"
