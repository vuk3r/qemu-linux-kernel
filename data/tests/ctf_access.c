#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <limits.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>

#define PWN_GET _IO('p', 1)
#define PWN_SET _IO('p', 2)

static void check(int ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL: %s (errno=%d: %s)\n", what, errno, strerror(errno));
        exit(1);
    }
}

static void read_endpoint(const char *path, const char *expected)
{
    char buf[128] = {0};
    int fd = open(path, O_RDWR);
    check(fd >= 0, path);
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    check(n == (ssize_t)strlen(expected) && !strcmp(buf, expected), "endpoint read");
    check(read(fd, buf, sizeof(buf)) == 0, "endpoint EOF");
    close(fd);
}

static void root_demo(int seccomp)
{
    pid_t pid = fork();
    check(pid >= 0, "fork");
    if (!pid) {
        int fd = open("/proc/pwn-college-root", O_RDWR);
        check(fd >= 0, "open root demo as ctf");
        if (seccomp) {
            struct sock_filter filter[] = {
                BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, arch)),
                BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, AUDIT_ARCH_X86_64, 1, 0),
                BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS),
                BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),
                BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_getpid, 0, 1),
                BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | EPERM),
                BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
            };
            struct sock_fprog prog = {sizeof(filter) / sizeof(filter[0]), filter};
            check(prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) == 0, "no_new_privs");
            check(prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &prog) == 0, "seccomp filter");
            errno = 0;
            check(syscall(SYS_getpid) == -1 && errno == EPERM, "filter active");
            check(ioctl(fd, PWN_GET, 0x31337UL) == 0, "seccomp demo ioctl");
            check(syscall(SYS_getpid) > 0, "seccomp demo bypass on 6.8.9");
            check(getuid() == 1000, "seccomp demo stays ctf");
        } else {
            check(ioctl(fd, PWN_GET, 0x13371337UL) == 0, "root demo ioctl");
            check(getuid() == 0 && geteuid() == 0, "root demo credentials on 6.8.9");
        }
        close(fd);
        _exit(0);
    }
    int status;
    check(waitpid(pid, &status, 0) == pid, "waitpid");
    check(WIFEXITED(status) && WEXITSTATUS(status) == 0, "demo child exit");
}

static void sudo_demo(void)
{
    gid_t groups[32];
    int count = getgroups(sizeof(groups) / sizeof(groups[0]), groups);
    int found = 0;
    check(count >= 0, "ctf supplementary groups");
    for (int i = 0; i < count; i++)
        found |= groups[i] == 27;
    check(found, "ctf belongs to sudo group");

    pid_t pid = fork();
    check(pid >= 0, "fork sudo");
    if (!pid) {
        execl("/usr/bin/sudo", "sudo", "/bin/sh", "-c",
              "test \"$(id -u)\" = 0 && rmmod hello_log && insmod /hello_log.ko",
              (char *)NULL);
        _exit(127);
    }
    int status;
    check(waitpid(pid, &status, 0) == pid, "wait sudo");
    check(WIFEXITED(status) && WEXITSTATUS(status) == 0, "sudo rmmod and insmod");
}

int main(int argc, char **argv)
{
    check(argc == 2, "expected mounted WSL test directory");
    check(getuid() == 1000 && geteuid() == 1000 && getgid() == 1000, "must run as ctf");
    const char *modules[] = {
        "/hello_log.ko", "/hello_dev_char.ko", "/hello_proc_char.ko",
        "/hello_ioctl.ko", "/make_root.ko",
    };
    for (size_t i = 0; i < sizeof(modules) / sizeof(modules[0]); i++) {
        unsigned char magic[4];
        int module = open(modules[i], O_RDONLY);
        check(module >= 0, modules[i]);
        check(read(module, magic, sizeof(magic)) == 4 && !memcmp(magic, "\177ELF", 4), "ctf can read module file");
        close(module);
    }
    read_endpoint("/dev/pwn-college-char", "Hello pwn.college!\n");
    read_endpoint("/proc/pwn-college-char", "Hello pwn-college!\n");
    int fd = open("/proc/pwn-college-ioctl", O_RDWR);
    check(fd >= 0, "open ioctl endpoint as ctf");
    char password[16] = "PASSWORD";
    char flag[128] = {0};
    check(ioctl(fd, PWN_SET, password) == 0, "PWN_SET");
    check(ioctl(fd, PWN_GET, flag) == 0 && flag[0] != '\0', "PWN_GET");
    close(fd);
    errno = 0;
    check(open("/flag", O_RDONLY) == -1 && errno == EACCES, "flag remains root-only");
    root_demo(0);
    root_demo(1);
    sudo_demo();
    check(getuid() == 1000, "parent remains ctf");

    char content[32] = {0};
    char path[PATH_MAX];
    int n = snprintf(path, sizeof(path), "%s/host-proof.txt", argv[1]);
    check(n > 0 && n < (int)sizeof(path), "host proof path");
    fd = open(path, O_RDONLY);
    check(fd >= 0, "WSL to guest open");
    check(read(fd, content, sizeof(content)) == 9 && !memcmp(content, "from-wsl\n", 9), "WSL to guest read");
    close(fd);
    n = snprintf(path, sizeof(path), "%s/guest-proof.txt", argv[1]);
    check(n > 0 && n < (int)sizeof(path), "guest proof path");
    fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0644);
    check(fd >= 0, "guest to WSL create as ctf");
    check(write(fd, "from-ctf\n", 9) == 9, "guest to WSL write");
    close(fd);
    puts("CTF_ACCESS_PASS: uid=1000, sudo insmod, open/read/ioctl, root/seccomp demos, shared mount");
    return 0;
}
