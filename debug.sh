#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VMLINUX_IMAGE="${VMLINUX_IMAGE:-$SCRIPT_DIR/src/vmlinux}"
HOST_SHARE="${HOST_SHARE:-$SCRIPT_DIR/share}"
QEMU_GDB_PORT="${QEMU_GDB_PORT:-1234}"
DEBUGGER_BIN="${DEBUGGER:-pwndbg}"
NM_BIN="${NM:-nm}"
RUNTIME_SYMBOLS_FILE="${RUNTIME_SYMBOLS_FILE:-$HOST_SHARE/.kernel-runtime-symbols-$QEMU_GDB_PORT}"
check_only=0

usage() {
	cat <<'EOF'
Usage: ./debug.sh [--check] [GDB_ARGUMENT ...]

Automatically calculates the current VM's KASLR slide and relocates vmlinux
symbols before connecting to QEMU.  Use the same QEMU_GDB_PORT for launch.sh
and debug.sh when the port is not 1234.

Environment overrides:
  QEMU_GDB_PORT       QEMU GDB port (default: 1234)
  VMLINUX_IMAGE       vmlinux with debug symbols (default: ./src/vmlinux)
  HOST_SHARE          project share directory (default: ./share)
  RUNTIME_SYMBOLS_FILE explicit guest-generated symbol marker
  DEBUGGER            debugger executable (default: pwndbg)
  NM                  nm executable (default: nm)

Options:
  --check             verify and print the slide without starting GDB
  -h, --help          show this help
EOF
}

gdb_args=()
while [ "$#" -gt 0 ]; do
	case "$1" in
		--check) check_only=1 ;;
		-h|--help) usage; exit 0 ;;
		--) shift; gdb_args+=("$@"); break ;;
		*) gdb_args+=("$1") ;;
	esac
	shift
done

case "$QEMU_GDB_PORT" in
	''|*[!0-9]*) echo "[-] QEMU_GDB_PORT must be a TCP port number." >&2; exit 2 ;;
esac
if [ "$QEMU_GDB_PORT" -lt 1 ] || [ "$QEMU_GDB_PORT" -gt 65535 ]; then
	echo "[-] QEMU_GDB_PORT must be between 1 and 65535." >&2
	exit 2
fi

[ -r "$VMLINUX_IMAGE" ] || {
	echo "[-] Missing readable vmlinux: $VMLINUX_IMAGE" >&2
	exit 1
}
[ -r "$RUNTIME_SYMBOLS_FILE" ] || {
	echo "[-] Runtime symbols are not ready: $RUNTIME_SYMBOLS_FILE" >&2
	echo "    Boot the VM first with: QEMU_GDB_PORT=$QEMU_GDB_PORT ./launch.sh ..." >&2
	exit 1
}
command -v "$NM_BIN" >/dev/null 2>&1 || {
	echo "[-] Missing nm executable: $NM_BIN" >&2
	exit 1
}

# A marker older than vmlinux cannot describe this artifact.  launch.sh also
# removes the port-specific marker before boot so a new VM cannot reuse it.
if [ "$RUNTIME_SYMBOLS_FILE" -ot "$VMLINUX_IMAGE" ]; then
	echo "[-] Runtime symbols are older than vmlinux; refusing a stale offset." >&2
	echo "    Restart the VM so it writes a fresh marker." >&2
	exit 1
fi

declare -A runtime_symbols=()
while IFS='=' read -r key value; do
	case "$key" in
		format|boot_id|_text|start_kernel|trash_gadgets)
			runtime_symbols["$key"]="$value"
			;;
	esac
done < "$RUNTIME_SYMBOLS_FILE"

if [ "${runtime_symbols[format]:-}" != "pwn-kernel-debug-v1" ]; then
	echo "[-] Unsupported runtime-symbol marker format." >&2
	exit 1
fi

declare -A static_symbols=()
while IFS='=' read -r symbol address; do
	static_symbols["$symbol"]="$address"
done < <(
	"$NM_BIN" -n "$VMLINUX_IMAGE" |
		awk '$3 == "_text" || $3 == "start_kernel" || $3 == "trash_gadgets" { print $3 "=0x" $1 }'
)

required_symbols=(_text start_kernel trash_gadgets)
for symbol in "${required_symbols[@]}"; do
	runtime_address="${runtime_symbols[$symbol]:-}"
	static_address="${static_symbols[$symbol]:-}"
	if [[ ! "$runtime_address" =~ ^0x[[:xdigit:]]{1,16}$ ]] ||
	   [[ "$runtime_address" =~ ^0x0+$ ]]; then
		echo "[-] Invalid or hidden runtime address for $symbol: ${runtime_address:-missing}" >&2
		echo "    Check /proc/kallsyms as root inside the guest." >&2
		exit 1
	fi
	if [[ ! "$static_address" =~ ^0x[[:xdigit:]]{1,16}$ ]]; then
		echo "[-] Symbol $symbol is missing from $VMLINUX_IMAGE" >&2
		exit 1
	fi
done

# Formula: slide = runtime(symbol) - link-time(symbol).  All three independent
# anchors must produce exactly the same result, otherwise the VM and vmlinux do
# not match (or the marker is stale), so loading symbols would be misleading.
slide=$(( ${runtime_symbols[_text]} - ${static_symbols[_text]} ))
for symbol in start_kernel trash_gadgets; do
	candidate_slide=$(( ${runtime_symbols[$symbol]} - ${static_symbols[$symbol]} ))
	if [ "$candidate_slide" -ne "$slide" ]; then
		echo "[-] Offset mismatch for $symbol." >&2
		printf '    _text slide: 0x%x; %s slide: 0x%x\n' "$slide" "$symbol" "$candidate_slide" >&2
		echo "    Refusing to load symbols from a mismatched or stale vmlinux." >&2
		exit 1
	fi
done

if [ "$slide" -lt 0 ] || [ $((slide & 0xfff)) -ne 0 ]; then
	printf '[-] Invalid KASLR slide: 0x%x (must be non-negative and page-aligned).\n' "$slide" >&2
	exit 1
fi
printf -v slide_hex '0x%x' "$slide"

echo "[+] vmlinux:       $VMLINUX_IMAGE"
echo "[+] guest boot ID: ${runtime_symbols[boot_id]:-unknown}"
echo "[+] static _text:  ${static_symbols[_text]}"
echo "[+] runtime _text: ${runtime_symbols[_text]}"
echo "[+] KASLR slide:   $slide_hex (verified with 3 symbols)"

if [ "$check_only" -eq 1 ]; then
	exit 0
fi
command -v "$DEBUGGER_BIN" >/dev/null 2>&1 || {
	echo "[-] Missing debugger: $DEBUGGER_BIN" >&2
	exit 1
}

exec "$DEBUGGER_BIN" -q "$VMLINUX_IMAGE" \
	-ex "set \$kaslr_slide = $slide_hex" \
	-ex "symbol-file -o $slide_hex $VMLINUX_IMAGE" \
	-ex "target remote :$QEMU_GDB_PORT" \
	"${gdb_args[@]}"
