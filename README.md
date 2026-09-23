# pwn-kernel local kernel environment

Môi trường local cho kernel-pwn: Linux 6.8.9, BusyBox static, QEMU và các
module mẫu cho pwn-kernel. Project chỉ chạy/build trên Linux hoặc WSL.

`launch.sh` là entry point duy nhất ở root. Các script phụ nằm trong
`scripts/`; artifact VM sinh ra nằm trong `src/`.

## Layout

| Vị trí | Nội dung |
| --- | --- |
| `./launch.sh` | Lệnh chính để build khi cần và chạy VM. |
| `src/` | Artifact sinh ra: `bzImage`, `initramfs.cpio.gz`, `vmlinux`, cùng stamp của trash gadgets và SSP profile. QEMU boot từ hai file đầu; `vmlinux` chỉ dùng để debug/tìm gadget. |
| `scripts/` | `build.sh`, `clean.sh`, `init.sh` (host pre-launch), `vm-compile`, wrapper `launch`, và `vm-startup.sh`. Mọi script mới nên đặt ở đây. |
| `data/src/` | Source C/Makefile của kernel module, khác với `src/` ở root. |
| `data/rootfs/` | Nội dung initramfs, gồm init của guest. |
| `data/tools/` | Tool trong guest và cấu hình `trash_gadgets`. |
| `home/` | Thư mục project được mount vào guest tại `/home/ctf`; nó là runtime state, không được Git theo dõi. |
| `log/` | Log build, launch, và smoke test. |

## Build và chạy

```bash
chmod +x launch.sh scripts/build.sh scripts/clean.sh scripts/vm-compile scripts/vm-startup.sh
./launch.sh
```

`launch.sh` mặc định chỉ boot artifact đã có trong `src/`; nó không tự build,
kể cả khi `trash_gadgets` hoặc SSP đã đổi. Khi cần cập nhật artifact, thêm
`--build`:

```bash
./launch.sh --build
# Hoặc build trực tiếp:
SKIP_DEPS=1 JOBS=8 ./scripts/build.sh
```

Với thay đổi SSP hoặc `data/tools/trash_gadgets`, dùng rõ `--build`, ví dụ
`./launch.sh --build ALL`. Không có `--build`, launcher chỉ reuse `src/bzImage`
và `src/initramfs.cpio.gz`; nếu artifact chưa tồn tại, nó dừng và yêu cầu cờ này.

Khi source dự án nằm dưới `/mnt/<drive>/` trong WSL, Linux source tree được
cache ở `~/.cache/pwnkernel/` vì NTFS/FAT không phù hợp để build kernel. Ở
native Linux, cache mặc định là `data/build/`. Có thể đặt `BUILD_DIR=/path`
để dùng cache khác.

Sửa `data/rootfs/` hoặc `data/src/` thì chạy lại `scripts/build.sh`. Sửa
`scripts/vm-startup.sh` không cần rebuild: launcher stage file đó cho từng
lần boot.

`scripts/clean.sh` chỉ xoá artifact tạm, download dang dở, core dump và
launch artifact tạm; nó không xoá `src/`, `data/` hay log đã lưu.

## Startup script trong VM

Có hai hook khác nhau trong `scripts/`:

- `init.sh` chạy trên host/WSL ngay trước khi QEMU được gọi. Dùng nó cho bước
  chuẩn bị host, ví dụ compile một module hoặc copy artifact.
- `vm-startup.sh` được stage vào share và chạy bên trong guest bằng `root` sau
  khi VM boot xong.

Sửa [`scripts/vm-startup.sh`](scripts/vm-startup.sh) để chạy lệnh tự động
trong guest. File được chạy bằng `root` sau khi các 9p share đã mount, module
mặc định/custom đã load và endpoint mode đã được áp dụng; nó chạy trước
`--test` và shell tương tác.

```sh
#!/bin/sh
# scripts/vm-startup.sh
insmod /home/d4vicl/labs/my_module.ko
chmod 666 /dev/my_module
```

Không cần `sudo` trong file này. Nếu một lệnh thất bại, status được in ra và
VM vẫn vào shell để bạn debug. Launcher dùng file mặc định mỗi lần chạy; có
thể thay file hoặc tắt cho một boot:

```bash
./launch.sh --startup "$HOME/labs/guest-startup.sh"
./launch.sh --no-startup
STARTUP_SCRIPT="$HOME/labs/guest-startup.sh" ./launch.sh
```

## Mitigations / bảo vệ

Mặc định launcher tạo môi trường dễ tái lập cho kernel-pwn. Nó truyền
`nokaslr pti=off mitigations=off` và QEMU expose CPU `qemu64,-smep,-smap,-nx`.
SSP cũng tắt mặc định, nhưng là bảo vệ build-time: dùng `SSP` sẽ rebuild kernel
trước khi boot. Vì vậy chỉ protection được ghi trên command line mới được yêu
cầu bật; mỗi lần chạy là một cấu hình mới, không có trạng thái bật/tắt được
lưu lại.

| Tùy chọn | Launcher thực hiện | Ý nghĩa |
| --- | --- | --- |
| `KASLR` | Không truyền `nokaslr` | Cho kernel randomize base address nếu kernel/config/entropy hỗ trợ. |
| `SMEP` | QEMU dùng `+smep` | Chặn kernel thực thi mã từ user page. |
| `SMAP` | QEMU dùng `+smap` | Chặn kernel đọc/ghi user page trừ khi kernel chủ động mở quyền. |
| `KPTI` hoặc `PTI` | Truyền `pti=on` | Ép x86 Kernel Page Table Isolation; kernel build được kiểm tra `CONFIG_PAGE_TABLE_ISOLATION=y`. |
| `NX` | QEMU dùng `+nx` | Expose NX/DEP; quyền execute cuối cùng vẫn phụ thuộc page permission. |
| `MITIGATIONS` | Không truyền `mitigations=off` | Cho kernel áp dụng chính sách mặc định cho lỗ hổng vi kiến trúc CPU/side-channel, như nhóm Spectre, Meltdown, MDS hoặc Retbleed khi CPU/kernel hỗ trợ. Nó độc lập với các mục khác, không phải master switch. |
| `SSP` | Rebuild với `CONFIG_STACKPROTECTOR=y` và `CONFIG_STACKPROTECTOR_STRONG=y` | Stack Smashing Protector/stack canary: compiler đặt canary gần return address của các hàm phù hợp và kiểm tra trước khi return. Canary hỏng thường dẫn đến kernel panic thay vì tiếp tục control-flow đã bị ghi đè. |
| `ALL` | Bật tất cả mục trên | Shorthand cho `KASLR SMEP SMAP KPTI NX MITIGATIONS SSP`. |

Ví dụ:

```bash
# Mặc định: mọi protection do launcher quản lý, gồm SSP, đều tắt.
./launch.sh

# Chỉ cho phép KASLR.
./launch.sh KASLR

# Yêu cầu toàn bộ protection launcher hỗ trợ. SSP làm kernel rebuild.
./launch.sh KASLR SMEP SMAP KPTI NX MITIGATIONS SSP

# Cách viết ngắn tương đương.
./launch.sh ALL

# Giữ toàn bộ trừ SMAP: chỉ cần không ghi SMAP.
./launch.sh KASLR SMEP KPTI NX MITIGATIONS SSP

# Tắt SSP ở lần chạy sau: bỏ SSP. Launcher rebuild lại kernel không có canary.
./launch.sh KASLR SMEP SMAP KPTI NX MITIGATIONS
```

Không có cờ `--no-smep` hay `--disable-*`: muốn tắt một protection thì bỏ tên
nó khỏi lệnh. Đặc biệt, chuyển giữa có/không `SSP` cần rebuild vì compiler đã
chèn hoặc bỏ canary trong machine code. Tên cờ không phân biệt hoa/thường;
`KALSR` là alias cũ của `KASLR`, còn `MITIGATION` là alias của `MITIGATIONS`.

Launcher lưu profile SSP của lần build thành công trong `src/.kernel_ssp`.
Nếu profile này đã khớp — ví dụ kernel trước đã build với SSP và chạy
`./launch.sh ALL` — launcher tái dùng `bzImage`/`vmlinux`; KASLR, SMEP, SMAP,
KPTI, NX và MITIGATIONS chỉ đổi QEMU/kernel command line nên không cần build.

Các cờ trên chỉ bỏ cơ chế launcher tắt protection hoặc expose CPU feature;
chúng không cam kết kernel sẽ tuyệt đối bật một mitigation trong mọi điều
kiện. Kiểm tra input trong guest:

```bash
cat /proc/cmdline
grep -Eo 'smep|smap|nx' /proc/cpuinfo | sort -u
# Trạng thái CPU-mitigation thực tế (nếu kernel export các file này):
grep -H . /sys/devices/system/cpu/vulnerabilities/* 2>/dev/null
```

Sau khi guest boot, dùng script có sẵn trong shared folder để in tóm tắt các
lớp bảo vệ và bằng chứng kiểm tra tương ứng:

```sh
sh /home/ctf/check-protections.sh
```

Với KPTI, output `ON (pti=on confirmed by boot log)` xác nhận cả command line
`pti=on` và thông báo `Kernel/User page tables isolation` của kernel.

`SSP`, `CONFIG_INIT_STACK_NONE=y` và `VMAP_STACK` là build-time. `launch.sh`
đã tự rebuild khi `SSP` đổi, còn hai mục kia cần sửa `scripts/build.sh`/kernel
config rồi rebuild. Các hardening khác của Linux defconfig/toolchain không do
launcher quản lý và có thể vẫn tồn tại. SSP không chặn UAF, heap overflow hay
canary bị lộ/bypass; riêng assembly trong `trash_gadgets.S` cũng không được
compiler chèn canary. Nếu đặt `KERNEL_IMAGE` riêng, launcher không thể kiểm tra
hay thay đổi SSP của file đó; `SSP` chỉ dùng với kernel mặc định trong `src/`.

Đổi SSP có thể mất vài phút: strong canary thay đổi compiler flag của rất nhiều
file C trong kernel, nên đây gần như là một lần compile kernel đầy đủ trước khi
QEMU có thể boot. Những lần launch không đổi SSP vẫn dùng artifact có sẵn và
chỉ mất thời gian boot VM.

Build mặc định dùng toàn bộ CPU hiện có (`nproc`). Khi cần giới hạn để máy vẫn
responsive, đặt rõ `JOBS`, ví dụ: `JOBS=4 ./launch.sh`.

QEMU mở GDB stub ở TCP port `1234` mặc định. Nếu port này đang được dùng, giữ
nguyên debugger hiện có và chọn port khác, ví dụ: `QEMU_GDB_PORT=1235 ./launch.sh ALL`.

Khi KASLR bật, dùng `debug.sh` để tự tính `slide = runtime(_text) -
link-time(_text)` rồi relocate symbol của `src/vmlinux`. Script kiểm tra cùng
offset bằng thêm `start_kernel` và `trash_gadgets`, vì vậy sẽ từ
chối nếu marker cũ hoặc `vmlinux` không khớp VM:

```bash
./debug.sh                 # VM dùng GDB port 1234
./debug.sh --check         # chỉ tính và kiểm tra offset
QEMU_GDB_PORT=1235 ./debug.sh
```

## Share, module và test

| Host | Guest |
| --- | --- |
| `home/` của project | `/home/ctf` |
| Host home | `/mnt/wsl` |
| Host `$HOME` | `/home/ctf/host` |
| `$HOME/pwn-kernel-share` | `/home/d4vicl` |

Các mount đều read/write. Override bằng `HOST_SHARE`, `WSL_SHARE`,
`HOST_HOME_SHARE`, hoặc `D4VICL_SHARE` nếu cần.

Mọi `data/src/*.c` (trừ `sudo.c`) được build thành module, đưa vào initramfs
và `insmod` lúc boot. Module `.ko` riêng và test static có thể đưa vào launch:

```bash
./launch.sh KASLR SMEP \
  --module "$HOME/pwn-kernel-share/labs/my_module.ko" \
  --chmod /dev/my-module:666 \
  --test "$HOME/pwn-kernel-share/labs/my_test"
```

`--module` lặp lại được. `--chmod` chỉ cho `/dev/*` hoặc `/proc/*`; nó chạy
sau `insmod` và trước test. `--test` chạy với user `ctf`; thêm
`--test-delay SECONDS` nếu cần chờ thiết bị sẵn sàng.

Trong shell guest, `vm-insmod` là tiện ích tải nhanh module với endpoint mode:

```sh
vm-insmod ~/host/pwnkernel-share/sbof.ko
vm-insmod ~/host/labs/my_module.ko /proc/my-module 644
```

## Compile chương trình host

Compile static executable cho guest:

```bash
./scripts/vm-compile data/tests/test.c ./test
./launch.sh --test ./test
```

Guest không có compiler và không có host dynamic libraries, vì vậy static
linking là bắt buộc.

## Configurable trash gadgets

`data/tools/trash_gadgets` chứa một gadget x86-64 trên mỗi dòng. Dòng trống và
dòng bắt đầu bằng `#` bị bỏ qua. Dùng GNU assembler Intel syntax, phân tách
instruction bằng `;`, và tự ghi `ret` kết thúc gadget.

```asm
pop rax; ret
pop rdi; ret
pop rsi; ret
push rax; pop rdi; add byte ptr [rcx], bh; ret
```

`launch.sh` hash file này. Nếu thay đổi, launcher rebuild/relink kernel mặc
định và ghi ELF chưa nén vào `src/vmlinux`:

```bash
rp --file ./src/vmlinux --rop 5 | grep -F 'push rax ; pop rdi ; add byte [rcx], bh ; ret'
```

## Explicit build

`./launch.sh` never rebuilds on its own. To apply a changed gadget list, SSP
profile, rootfs, or module source, run `./launch.sh --build` (optionally with
the protection flags, for example `./launch.sh --build ALL`). Without it, the
existing `src/` artifacts are booted unchanged.

## Verify

```bash
python3 data/tests/smoke.py
```

Smoke test kiểm tra module interface, ioctl, `sudo` helper và shared mount.
QEMU luôn được chạy với `-s`, nên GDB có thể attach vào port 1234.
