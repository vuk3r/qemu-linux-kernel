# pwn.college local kernel environment

Linux 6.8.9, static BusyBox, QEMU, and the pwn.college demo modules.

## Build and run (Linux only)

This project is intentionally Linux-only. Build artifacts needed by QEMU stay
at the project root; source trees and build-only inputs are under `data/`.

```bash
chmod +x build.sh launch.sh clean.sh vm-compile
./launch.sh
```

`build.sh` keeps its kernel and BusyBox cache in `data/build/` on a native
Linux filesystem. When this project is under `/mnt/<drive>/` in WSL, it uses
`~/.cache/pwnkernel/` instead because Linux source trees cannot build safely
on a case-insensitive Windows filesystem. Set `BUILD_DIR=/path` to override
either location.

`./launch.sh` automatically starts `build.sh` (including dependency setup) if
the root-level `bzImage` or `initramfs.cpio.gz` is missing. Once built, it
only consumes those artifacts and `share/`; edit `data/rootfs/` or
`data/src/` and rebuild to update them.

Each build and launch writes a timestamped log to `log/`. `launch.sh` invokes
`clean.sh` before QEMU starts and again when it exits. It removes only
temporary launch artifacts, partial downloads, core dumps, and misplaced
root-level logs; it never deletes `bzImage`, `initramfs.cpio.gz`, `data/`, or
saved logs.

The retained layout is:

| Location | Purpose |
| --- | --- |
| project root | `build.sh`, `launch.sh`, `vm-compile`, kernel image, initramfs, and `share/` needed to run |
| `data/` | build cache, rootfs/module sources, helper source, tests, archives, and retired Windows-only files |
| `log/` | historical and new build/launch/test logs |

Build from Linux:

For a manual rebuild, use `SKIP_DEPS=1 JOBS=8 ./build.sh`; otherwise simply
run `./launch.sh`.

## Runtime protections

All selectable protections are off by default. Enable only those named:

```bash
./launch.sh KASLR SMEP
```

Supported options: `KASLR` (`KALSR` also works), `SMEP`, `SMAP`, `KPTI`, `NX`,
and `MITIGATIONS`. Unnamed protections remain off. Stack initialization and
vmapped kernel stacks are build-time settings (`INIT_STACK_NONE`, no
`VMAP_STACK`), not launcher options.

## Shared directories

| Host path | Guest path |
| --- | --- |
| project `share/` | `/home/ctf` |
| host home | `/mnt/wsl` |
| host `$HOME` | `~/host` (that is, `/home/ctf/host`) |
| `$HOME/pwn-college-share` | `/home/d4vicl` |

All mounts are read/write. Override them with `HOST_SHARE`, `WSL_SHARE`,
`HOST_HOME_SHARE`, or `D4VICL_SHARE` when necessary. `~/host` exposes the
host's `$HOME` directly, so a module does not need to be copied into
`pwnkernel-share` first.

## Load a module from the `ctf` shell

After rebuilding once, `ctf` can use `vm-insmod` directly; no VM restart is
needed. The helper runs `sudo insmod` and then `sudo chmod` internally, so the
user does not need to type either command.

```bash
./build.sh
./launch.sh
```

Inside the guest as `ctf`, a module placed anywhere in the host home is
available under `~/host`:

```sh
vm-insmod ~/host/pwnkernel-share/sbof.ko
ls -l /dev/sbof
```

By default the endpoint is `/dev/<module-name>` and its mode is `666`. Supply
an explicit endpoint and optional mode when the module uses another path:

```sh
vm-insmod ~/host/labs/my_module.ko /proc/my-module 644
```

Loading a module still grants kernel-level control; use this only in the local
teaching VM.

## Add a module and test

Put a module source at `data/src/my_module.c`; all `data/src/*.c` except `sudo.c` build
automatically and boot from the initramfs. Tests should be static executables.

```bash
SKIP_DEPS=1 ./build.sh
mkdir -p "$HOME/pwn-college-share"
gcc -static -O2 -o "$HOME/pwn-college-share/my-test" data/tests/my_test.c
./launch.sh KASLR SMEP --test "$HOME/pwn-college-share/my-test"
```

## Run a host-built C program

Use `vm-compile` from the Linux host/WSL terminal to compile a source as a
static executable. It is a project file, so invoke it as `./vm-compile`; it
does not exist inside the guest, which intentionally has no compiler.

To invoke it without `./` (and have Bash complete it after typing `vm-`) in
the current project terminal, add this project directory to that shell's
`PATH`:

```bash
export PATH="$PWD:$PATH"
```

```bash
vm-compile data/tests/test.c ./test
./launch.sh --test ./test
```

Static linking is required because the guest does not contain the host's
dynamic libraries. The `tests/test.c` sample is kept as a basic module
endpoint test.

For a separately built module, pass its artifacts directly:

```bash
./launch.sh KASLR SMEP \
  --module "$HOME/pwn-college-share/labs/my_module.ko" \
  --chmod /dev/my-module:666 \
  --test "$HOME/pwn-college-share/labs/my_test"
```

`--module` may be repeated. `--chmod` is optional and applies an explicit
mode to a `/dev` or `/proc` endpoint after `insmod`, before the test runs as
UID 1000 (`ctf`). Artifacts outside the two host-share directories are staged
into the project share automatically.

The existing demo endpoints are `/dev/pwn-college-char`,
`/proc/pwn-college-char`, `/proc/pwn-college-ioctl`, and
`/proc/pwn-college-root`. Use `BOOT_USER=root` for a root guest shell. QEMU
always includes `-s`, so GDB can attach to port 1234.

## Configurable trash gadgets

`data/tools/trash_gadgets` is a deliberately small source file for local CTF
experiments. Each non-empty line that does not begin with `#` is copied into a
dedicated x86-64 assembly function in the order written. Use GNU assembler's
Intel syntax, separate instructions with `;`, and include the terminating
`ret` yourself. For example:

```asm
pop rax; ret
pop rdi; ret
pop rsi; ret
push rax; pop rdi; add byte ptr [rcx], bh; ret
```

`launch.sh` hashes this file before boot. If it changed, it rebuilds and
relinks the default kernel automatically, and writes the uncompressed ELF to
the project-root `vmlinux`. The configured default can be checked with:

```bash
rp --file ./vmlinux --rop 5 | grep -F 'push rax ; pop rdi ; add byte [rcx], bh ; ret'
```

## Verify

```bash
python3 data/tests/smoke.py
```

The smoke test validates module access, ioctl behavior, the guest `sudo`
helper, and the shared mounts. The `tests/` directory is retained because it
contains this regression check and the `vm-compile` sample program.
