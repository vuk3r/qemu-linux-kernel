#!/bin/sh
# Runs inside the guest as root after shares, built-in modules, custom modules,
# and requested endpoint modes are ready. Edit this file; no rebuild is needed.
#
# Examples:
# insmod /home/d4vicl/labs/my_module.ko
# chmod 666 /dev/my_module
# echo 1 > /proc/sys/kernel/kptr_restrict
cd modules/
vm-insmod /home/ctf/modules/*.ko
cd ..
sudo cat /proc/kallsyms | grep sbof  > /home/ctf/debug.info
sudo cat /proc/kallsyms | grep prepare_kernel_cred  >> /home/ctf/debug.info
sudo cat /proc/kallsyms | grep commit_creds  >> /home/ctf/debug.info
sudo cat /proc/kallsyms | grep init_task  >> /home/ctf/debug.info
sudo cat /proc/kallsyms | grep nfsd_debug  >> /home/ctf/debug.info
sudo cat /proc/kallsyms | grep swapgs_restore_regs_and_return_to_usermode  >> /home/ctf/debug.info
# ln -s /src/vmlinux vmlinux