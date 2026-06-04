# pwn.college local kernel environment UPDATE

This repo builds a small local kernel-pwn environment for QEMU. It builds
Linux 5.4, a static BusyBox rootfs, and demo kernel modules.

## Usage

```bash
cd pwnkernel
bash ./build.sh
bash ./launch.sh
```

If dependencies are already installed:

```bash
SKIP_DEPS=1 bash ./build.sh
```

Default parallelism is `JOBS=2` to avoid high memory usage. You can override it:

```bash
JOBS=4 bash ./build.sh
```

## Why the original version breaks on newer Kali

The original scripts target older toolchains. Newer Kali Rolling versions may
use GCC 15+, which exposes several incompatibilities:

- Linux 5.4 special build stages may compile with a newer C standard, where
  `false` and `bool` conflict with old kernel definitions.
- `CONFIG_DEBUG_INFO_BTF=y` can fail with older kernel sources and newer tools.
- Linux 5.4 `objtool` uses `-Werror`, so new GCC warnings can stop the build.
- BusyBox 1.32 `tc` does not build cleanly against newer Linux headers.
- The original `-j16` build can use too much memory.

## What was changed

- Disabled BTF debug info.
- Forced old C mode where Linux 5.4 needs it.
- Removed `-Werror` from fragile kernel tool build steps.
- Disabled the BusyBox `tc` applet.
- Reduced default build jobs to `JOBS=2`.
- Added `SKIP_DEPS=1` support.
- `launch.sh` now shares only `pwnkernel/share`, not the host `$HOME`.

Tested on Kali Rolling 2026.1 with GCC 15.2.0 and QEMU 10.2.2.

## Result

After a successful build:

- `linux-5.4/arch/x86/boot/bzImage` is the QEMU kernel image.
- `fs/` is the root filesystem.
- `fs/*.ko` are demo kernel modules.
- `launch.sh` boots into a root shell:

```text
Welcome to pwn.college
/ #
```
