#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$SCRIPT_DIR/scripts"
LOG_DIR="$SCRIPT_DIR/log"
CLEAN_SCRIPT="$SCRIPTS_DIR/clean.sh"
BUILD_SCRIPT="$SCRIPTS_DIR/build.sh"
HOST_PRELAUNCH_SCRIPT="$SCRIPTS_DIR/init.sh"
RUNTIME_DIR="$SCRIPT_DIR/src"
cd "$SCRIPT_DIR"

if [ "$(uname -s)" != "Linux" ]; then
  echo "[-] This project runs on Linux only." >&2
  exit 1
fi

mkdir -p "$LOG_DIR"
RUN_LOG="$LOG_DIR/launch-$(date -u +%Y%m%dT%H%M%SZ)-$$.log"
exec 3>&1 4>&2
exec > >(tee -a "$RUN_LOG")
log_stdout_pid=$!
exec 2> >(tee -a "$RUN_LOG" >&2)
log_stderr_pid=$!

finish_logging() {
	local status="$1"
	exec 1>&3 2>&4
	wait "$log_stdout_pid" "$log_stderr_pid" || true
	exec 3>&- 4>&-
	exit "$status"
}

finish_logging_on_exit() {
	local status=$?
	trap - EXIT
	finish_logging "$status"
}
trap finish_logging_on_exit EXIT

echo "[+] Launch log: $RUN_LOG"

# Optional host-side setup hook. It runs before QEMU; guest commands belong in
# scripts/vm-startup.sh instead.
if [ -f "$HOST_PRELAUNCH_SCRIPT" ]; then
	echo "[+] Host pre-launch script: $HOST_PRELAUNCH_SCRIPT"
	bash "$HOST_PRELAUNCH_SCRIPT"
fi

KERNEL_IMAGE="${KERNEL_IMAGE:-$RUNTIME_DIR/bzImage}"
INITRAMFS_IMAGE="${INITRAMFS_IMAGE:-$RUNTIME_DIR/initramfs.cpio.gz}"
VMLINUX_IMAGE="$RUNTIME_DIR/vmlinux"
TRASH_GADGETS_FILE="$SCRIPT_DIR/data/tools/trash_gadgets"
TRASH_GADGETS_STAMP="$RUNTIME_DIR/.trash_gadgets.sha256"
TRASH_GADGETS_FORMAT="pwn-kernel-v3"
KERNEL_SSP_STAMP="$RUNTIME_DIR/.kernel_ssp"
DEFAULT_STARTUP_SCRIPT="$SCRIPTS_DIR/vm-startup.sh"
HOST_SHARE="${HOST_SHARE:-$SCRIPT_DIR/home}"
WSL_SHARE="${WSL_SHARE:-$HOME}"
HOST_HOME_SHARE="${HOST_HOME_SHARE:-$HOME}"
# The host directory can live anywhere; the guest always sees it at
# /home/d4vicl.  A path below $HOME works for a freshly-cloned project
# without requiring permission to create another user's home directory.
D4VICL_SHARE="${D4VICL_SHARE:-$HOME/pwn-kernel-share}"
BOOT_USER="${BOOT_USER:-ctf}"
QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
QEMU_MEMORY="${QEMU_MEMORY:-512M}"
QEMU_ACCEL="${QEMU_ACCEL:-auto}"
QEMU_GDB_PORT="${QEMU_GDB_PORT:-1234}"

trash_gadgets_are_current() {
	local expected actual
	[ -f "$TRASH_GADGETS_FILE" ] && [ -f "$TRASH_GADGETS_STAMP" ] || return 1
	expected="$TRASH_GADGETS_FORMAT:$(sha256sum "$TRASH_GADGETS_FILE" | awk '{print $1}')"
	actual="$(awk 'NR == 1 { print $1 }' "$TRASH_GADGETS_STAMP")"
	[ "$expected" = "$actual" ]
}

ssp_is_current() {
	local actual
	[ -f "$KERNEL_SSP_STAMP" ] || return 1
	actual="$(awk 'NR == 1 { print $1 }' "$KERNEL_SSP_STAMP")"
	[ "$actual" = "$ssp" ]
}

# Every protection is opt-in: ./launch.sh KASLR SMEP SMAP KPTI NX MITIGATIONS SSP
# ALL is the shorthand for the complete set above.
# The KALSR spelling is accepted as an alias because it appeared in early notes.
kaslr=0
smep=0
smap=0
kpti=0
nx=0
mitigations=0
ssp=0
build_requested=0

usage() {
	cat <<'EOF'
Usage: ./launch.sh [protections...] [--build] [--module HOST_KO]... [--chmod GUEST_PATH:MODE]... [--startup HOST_SCRIPT|--no-startup] [--test HOST_TEST] [--test-delay SECONDS]

Enable only the named protections. All protections not listed are disabled.
By default this command only boots artifacts already in src/; it never starts
a build. SSP is build-time, so use --build to apply an SSP change. KALSR is
accepted as an alias for the correctly spelled KASLR.

Protections: KASLR, SMEP, SMAP, KPTI, NX, MITIGATIONS, SSP, ALL
ALL:         enable every protection above.
--build:      build/refresh default artifacts before booting. The build is
              incremental when its inputs are already current.
--module: an existing .ko; it is insmod'ed after the shares mount.
--chmod:  set a /dev or /proc endpoint mode after modules load (for example,
          --chmod /dev/my-device:666). Repeat this option as needed.
--startup: run a host shell script as root in the guest after shares, modules,
           and endpoint modes are ready. Defaults to scripts/vm-startup.sh.
--no-startup: disable the default startup script for this boot.
--test:   an executable; it runs as ctf after modules load.
--test-delay: wait before the test runs (default: 0 seconds).

Files under D4VICL_SHARE, WSL_SHARE, or HOST_HOME_SHARE run in place. Other
paths are copied into the project share for this boot.
EOF
}

custom_modules=()
custom_device_modes=()
custom_test=""
custom_test_delay=0
startup_script="${STARTUP_SCRIPT:-$DEFAULT_STARTUP_SCRIPT}"
custom_startup=""

stage_artifact() {
	local host_path="$1" kind="$2" digest destination mode suffix
	digest="$(sha256sum "$host_path" | awk '{print $1}')"
	case "$kind" in
		module) mode=0644; suffix=.ko ;;
		startup) mode=0755; suffix=.sh ;;
		test) mode=0755; suffix='' ;;
		*) echo "[-] Internal error: unknown artifact type $kind." >&2; exit 1 ;;
	esac
	destination="$HOST_SHARE/.launch-artifacts/${kind}-${digest}${suffix}"
	if [ ! -f "$destination" ]; then
		mkdir -p "$HOST_SHARE/.launch-artifacts"
		install -m "$mode" "$host_path" "$destination"
	fi
	printf '/home/ctf/.launch-artifacts/%s-%s%s\n' "$kind" "$digest" "$suffix"
}

to_guest_path() {
	local host_path="$1" kind="$2" guest_path
	case "$host_path" in
		"$D4VICL_SHARE"/*) guest_path="/home/d4vicl/${host_path#"$D4VICL_SHARE"/}" ;;
		"$WSL_SHARE"/*) guest_path="/mnt/wsl/${host_path#"$WSL_SHARE"/}" ;;
		*) stage_artifact "$host_path" "$kind"; return ;;
	esac
	if [[ "$guest_path" == *[[:space:],]* ]]; then
		stage_artifact "$host_path" "$kind"
	else
		printf '%s\n' "$guest_path"
	fi
}

add_custom_module() {
	local host_path="$1"
	if [ ! -f "$host_path" ]; then
		echo "[-] Module must be an existing .ko path: $host_path" >&2
		exit 2
	fi
	case "$host_path" in *.ko) ;; *) echo "[-] Module must end in .ko: $host_path" >&2; exit 2 ;; esac
	custom_modules+=("$(to_guest_path "$host_path" module)")
}

add_device_mode() {
	local specification="$1" device_path mode
	device_path="${specification%:*}"
	mode="${specification##*:}"
	if [ "$device_path" = "$specification" ] || [ -z "$device_path" ]; then
		echo "[-] --chmod must be GUEST_PATH:MODE: $specification" >&2
		exit 2
	fi
	case "$device_path" in
		/dev/*|/proc/*) ;;
		*) echo "[-] --chmod path must be below /dev or /proc: $device_path" >&2; exit 2 ;;
	esac
	case "$mode" in
		[0-7][0-7][0-7]|[0-7][0-7][0-7][0-7]) ;;
		*) echo "[-] --chmod mode must be three or four octal digits: $mode" >&2; exit 2 ;;
	esac
	custom_device_modes+=("$device_path:$mode")
}

set_startup_script() {
	local host_path="$1"
	if [ ! -f "$host_path" ] || [ ! -r "$host_path" ]; then
		echo "[-] Startup script must be a readable file: $host_path" >&2
		exit 2
	fi
	startup_script="$host_path"
}

set_custom_test() {
	local host_path="$1"
	if [ -n "$custom_test" ]; then
		echo '[-] Specify --test only once.' >&2
		exit 2
	fi
	if [ ! -x "$host_path" ]; then
		echo "[-] Test must be an executable file: $host_path" >&2
		exit 2
	fi
	custom_test="$(to_guest_path "$host_path" test)"
}

set_custom_test_delay() {
	case "$1" in
		''|*[!0-9]*) echo "[-] --test-delay must be a non-negative integer: $1" >&2; exit 2 ;;
		*) custom_test_delay="$1" ;;
	esac
}

# Clear artifacts from the previous boot before option parsing stages the
# modules, tests, or startup script requested for this boot.
bash "$CLEAN_SCRIPT" before-run

while [ "$#" -gt 0 ]; do
	argument="$1"
	case "$argument" in
		-h|--help|HELP) usage; exit 0 ;;
		--build) build_requested=1 ;;
		--module)
			[ "$#" -ge 2 ] || { echo '[-] --module needs a path.' >&2; exit 2; }
			add_custom_module "$2"
			shift 2
			continue
			;;
		--module=*) add_custom_module "${argument#--module=}" ;;
		--chmod)
			[ "$#" -ge 2 ] || { echo '[-] --chmod needs GUEST_PATH:MODE.' >&2; exit 2; }
			add_device_mode "$2"
			shift 2
			continue
			;;
		--chmod=*) add_device_mode "${argument#--chmod=}" ;;
		--startup)
			[ "$#" -ge 2 ] || { echo '[-] --startup needs a script path.' >&2; exit 2; }
			set_startup_script "$2"
			shift 2
			continue
			;;
		--startup=*) set_startup_script "${argument#--startup=}" ;;
		--no-startup) startup_script="" ;;
		--test)
			[ "$#" -ge 2 ] || { echo '[-] --test needs a path.' >&2; exit 2; }
			set_custom_test "$2"
			shift 2
			continue
			;;
		--test=*) set_custom_test "${argument#--test=}" ;;
		--test-delay)
			[ "$#" -ge 2 ] || { echo '[-] --test-delay needs seconds.' >&2; exit 2; }
			set_custom_test_delay "$2"
			shift 2
			continue
			;;
		--test-delay=*) set_custom_test_delay "${argument#--test-delay=}" ;;
		*)
			case "${argument^^}" in
				KASLR|KALSR) kaslr=1 ;;
				SMEP) smep=1 ;;
				SMAP) smap=1 ;;
				KPTI|PTI) kpti=1 ;;
				NX) nx=1 ;;
				MITIGATIONS|MITIGATION) mitigations=1 ;;
				SSP) ssp=1 ;;
				ALL)
					kaslr=1
					smep=1
					smap=1
					kpti=1
					nx=1
					mitigations=1
					ssp=1
					;;
				*)
					echo "[-] Unknown protection or option: $argument" >&2
					usage >&2
					exit 2
					;;
			esac
			;;
	esac
	shift
done

if [ -n "$startup_script" ]; then
	set_startup_script "$startup_script"
	custom_startup="$(to_guest_path "$startup_script" startup)"
fi

# A supplied kernel is opaque to this launcher: SSP lives in compiler output,
# so it cannot be toggled or verified through QEMU command-line arguments.
if [ "$KERNEL_IMAGE" != "$RUNTIME_DIR/bzImage" ] && [ "$ssp" = "1" ]; then
	echo '[-] SSP requires the project default kernel. Remove KERNEL_IMAGE or rebuild your custom kernel with stack protection enabled.' >&2
	exit 1
fi
if [ "$KERNEL_IMAGE" != "$RUNTIME_DIR/bzImage" ]; then
	echo '[!] Custom KERNEL_IMAGE supplied; its SSP state is not managed by launch.sh.' >&2
fi

if [ "$build_requested" = "1" ]; then
	if [ "$KERNEL_IMAGE" != "$RUNTIME_DIR/bzImage" ] || \
	   [ "$INITRAMFS_IMAGE" != "$RUNTIME_DIR/initramfs.cpio.gz" ]; then
		echo '[-] --build only builds the project default artifacts in src/; remove custom KERNEL_IMAGE/INITRAMFS_IMAGE first.' >&2
		exit 1
	fi
	echo '[+] --build requested; refreshing default artifacts...'
	KERNEL_SSP="$ssp" bash "$BUILD_SCRIPT"
	if [ ! -f "$KERNEL_IMAGE" ] || [ ! -f "$INITRAMFS_IMAGE" ] || \
	   [ ! -f "$VMLINUX_IMAGE" ] || ! trash_gadgets_are_current || ! ssp_is_current; then
		echo '[-] Build finished without the requested default artifact profile.' >&2
		exit 1
	fi
elif [ ! -f "$KERNEL_IMAGE" ] || [ ! -f "$INITRAMFS_IMAGE" ]; then
	echo '[-] Runtime artifacts are missing. Build them explicitly with: ./launch.sh --build' >&2
	exit 1
elif [ "$KERNEL_IMAGE" = "$RUNTIME_DIR/bzImage" ]; then
	if [ ! -f "$VMLINUX_IMAGE" ]; then
		echo '[!] src/vmlinux is missing; VM will boot, but debug.sh cannot load symbols. Run ./launch.sh --build to restore it.' >&2
	fi
	if ! trash_gadgets_are_current; then
		echo '[!] data/tools/trash_gadgets differs from the booted artifact; reusing it. Run ./launch.sh --build to apply it.' >&2
	fi
	if ! ssp_is_current; then
		actual_ssp="$(awk 'NR == 1 { print $1 }' "$KERNEL_SSP_STAMP" 2>/dev/null || true)"
		echo "[!] Requested SSP=$ssp, but the existing kernel SSP profile is ${actual_ssp:-unknown}; reusing it. Run ./launch.sh --build to change SSP." >&2
	else
		echo '[+] Reusing existing kernel artifacts (no --build requested).'
	fi
fi

artifact_ssp="$(awk 'NR == 1 { print $1 }' "$KERNEL_SSP_STAMP" 2>/dev/null || true)"

if ! command -v "$QEMU_BIN" >/dev/null 2>&1; then
	echo "[-] Missing $QEMU_BIN. Install qemu-system-x86 or use the Docker wrapper." >&2
	exit 1
fi

case "$BOOT_USER" in
  ctf|root) ;;
  *) echo '[-] BOOT_USER must be ctf or root.' >&2; exit 1 ;;
esac

case "$QEMU_GDB_PORT" in
  ''|*[!0-9]*) echo "[-] QEMU_GDB_PORT must be a TCP port number." >&2; exit 2 ;;
esac
if [ "$QEMU_GDB_PORT" -lt 1 ] || [ "$QEMU_GDB_PORT" -gt 65535 ]; then
	echo "[-] QEMU_GDB_PORT must be between 1 and 65535." >&2
	exit 2
fi
mkdir -p "$HOST_SHARE" "$HOST_SHARE/host" "$WSL_SHARE" "$HOST_HOME_SHARE" "$D4VICL_SHARE"
RUNTIME_SYMBOLS_FILE="$HOST_SHARE/.kernel-runtime-symbols-$QEMU_GDB_PORT"
rm -f -- "$RUNTIME_SYMBOLS_FILE"
echo "[+] Project home: $HOST_SHARE -> /home/ctf"
echo "[+] Host home share: $WSL_SHARE -> /mnt/wsl (read/write)"
echo "[+] Host home shortcut: $HOST_HOME_SHARE -> /home/ctf/host (read/write)"
echo "[+] Persistent d4vicl share: $D4VICL_SHARE -> /home/d4vicl (read/write)"

cleanup_after_run() {
	status=$?
	trap - EXIT
	rm -f -- "$RUNTIME_SYMBOLS_FILE"
	bash "$CLEAN_SCRIPT" after-run || true
	finish_logging "$status"
}
trap cleanup_after_run EXIT

#
# launch
#
qemu_accel=()
case "$QEMU_ACCEL" in
	auto)
		if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then qemu_accel=(-enable-kvm); else qemu_accel=(-accel tcg); fi
		;;
	kvm) qemu_accel=(-enable-kvm) ;;
	tcg) qemu_accel=(-accel tcg) ;;
	*) echo '[-] QEMU_ACCEL must be auto, kvm, or tcg.' >&2; exit 2 ;;
esac

cpu_features=()
if [ "$smep" = "1" ]; then cpu_features+=(+smep); else cpu_features+=(-smep); fi
if [ "$smap" = "1" ]; then cpu_features+=(+smap); else cpu_features+=(-smap); fi
if [ "$nx" = "1" ]; then cpu_features+=(+nx); else cpu_features+=(-nx); fi
QEMU_CPU="qemu64,$(IFS=,; echo "${cpu_features[*]}")"

kernel_args=(console=ttyS0 panic=-1 "ctf.shell=$BOOT_USER" "ctf.gdb_port=$QEMU_GDB_PORT")
if [ "$kaslr" = "0" ]; then kernel_args+=(nokaslr); fi
if [ "$kpti" = "1" ]; then kernel_args+=(pti=on); else kernel_args+=(pti=off); fi
if [ "$mitigations" = "0" ]; then kernel_args+=(mitigations=off); fi
if [ "${#custom_modules[@]}" -gt 0 ]; then
	custom_modules_cmdline="$(IFS=,; echo "${custom_modules[*]}")"
	kernel_args+=("ctf.modules=$custom_modules_cmdline")
fi
if [ "${#custom_device_modes[@]}" -gt 0 ]; then
	custom_device_modes_cmdline="$(IFS=,; echo "${custom_device_modes[*]}")"
	kernel_args+=("ctf.chmod=$custom_device_modes_cmdline")
fi
if [ -n "$custom_startup" ]; then
	kernel_args+=("ctf.startup=$custom_startup")
fi
if [ -n "$custom_test" ]; then
	kernel_args+=("ctf.test=$custom_test" "ctf.test_delay=$custom_test_delay")
fi
KERNEL_CMDLINE="${kernel_args[*]}"

enabled_protections=()
if [ "$kaslr" = "1" ]; then enabled_protections+=(KASLR); fi
if [ "$smep" = "1" ]; then enabled_protections+=(SMEP); fi
if [ "$smap" = "1" ]; then enabled_protections+=(SMAP); fi
if [ "$kpti" = "1" ]; then enabled_protections+=(KPTI); fi
if [ "$nx" = "1" ]; then enabled_protections+=(NX); fi
if [ "$mitigations" = "1" ]; then enabled_protections+=(MITIGATIONS); fi
if [ "$ssp" = "1" ]; then enabled_protections+=(SSP); fi
if [ "${#enabled_protections[@]}" -eq 0 ]; then
	echo "[+] Requested protections: none (all selectable protections are disabled)"
else
	echo "[+] Requested protections: ${enabled_protections[*]}"
fi
if [ "$KERNEL_IMAGE" = "$RUNTIME_DIR/bzImage" ]; then
	case "$artifact_ssp" in
		1) echo '[+] Kernel SSP artifact: enabled (strong stack protector)' ;;
		0) echo '[+] Kernel SSP artifact: disabled' ;;
		*) echo '[!] Kernel SSP artifact: unknown (missing or invalid src/.kernel_ssp stamp)' >&2 ;;
	esac
fi
if [ "${#custom_modules[@]}" -gt 0 ]; then
	echo "[+] Custom module(s): ${custom_modules[*]}"
fi
if [ "${#custom_device_modes[@]}" -gt 0 ]; then
	echo "[+] Endpoint mode(s): ${custom_device_modes[*]}"
fi
if [ -n "$custom_startup" ]; then
	echo "[+] Startup script as root: $custom_startup"
fi
if [ -n "$custom_test" ]; then
	echo "[+] Test as ctf: $custom_test (delay: ${custom_test_delay}s)"
fi

"$QEMU_BIN" \
	"${qemu_accel[@]}" \
	-cpu "$QEMU_CPU" \
	-kernel "$KERNEL_IMAGE" \
	-initrd "$INITRAMFS_IMAGE" \
	-fsdev local,security_model=passthrough,id=fsdev0,path="$HOST_SHARE" \
	-device virtio-9p-pci,id=fs0,fsdev=fsdev0,mount_tag=hostshare \
	-fsdev local,security_model=mapped-xattr,id=fsdev1,path="$WSL_SHARE" \
	-device virtio-9p-pci,id=fs1,fsdev=fsdev1,mount_tag=wslshare \
	-fsdev local,security_model=mapped-xattr,id=fsdev2,path="$D4VICL_SHARE" \
	-device virtio-9p-pci,id=fs2,fsdev=fsdev2,mount_tag=d4viclshare \
	-fsdev local,security_model=mapped-xattr,id=fsdev3,path="$HOST_HOME_SHARE" \
	-device virtio-9p-pci,id=fs3,fsdev=fsdev3,mount_tag=hosthome \
	-m "$QEMU_MEMORY" \
	-nographic \
	-monitor none \
	-no-reboot \
	-gdb "tcp::$QEMU_GDB_PORT" \
	-append "$KERNEL_CMDLINE"
