#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <linux/ioctl.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define PWN_ROOT _IO('p', 1)

static int member_of_sudo(void)
{
    struct group *sudo_group = getgrnam("sudo");
    gid_t groups[64];
    int count;

    if (!sudo_group)
        return 0;
    if (getgid() == sudo_group->gr_gid || getegid() == sudo_group->gr_gid)
        return 1;
    count = getgroups((int)(sizeof(groups) / sizeof(groups[0])), groups);
    if (count < 0)
        return 0;
    for (int i = 0; i < count; i++) {
        if (groups[i] == sudo_group->gr_gid)
            return 1;
    }
    return 0;
}

int main(int argc, char **argv)
{
    int fd;

    if (argc < 2) {
        fprintf(stderr, "usage: sudo command [args...] | sudo -s\n");
        return 2;
    }
    if (geteuid() != 0 && !member_of_sudo()) {
        fprintf(stderr, "sudo: user is not in the sudo group\n");
        return 1;
    }
    fd = open("/proc/pwn-kernel-root", O_RDWR | O_CLOEXEC);
    if (fd < 0 || ioctl(fd, PWN_ROOT, 0x13371337UL) != 0) {
        fprintf(stderr, "sudo: cannot acquire root privileges: %s\n", strerror(errno));
        if (fd >= 0)
            close(fd);
        return 1;
    }
    close(fd);
    if (geteuid() != 0 || getuid() != 0) {
        fprintf(stderr, "sudo: credential change failed\n");
        return 1;
    }
    setenv("PATH", "/bin:/sbin:/usr/bin:/usr/sbin", 1);
    if (!strcmp(argv[1], "-s")) {
        char *shell[] = {"/bin/sh", NULL};
        execv(shell[0], shell);
    } else {
        int first = !strcmp(argv[1], "--") ? 2 : 1;
        if (first >= argc) {
            fprintf(stderr, "usage: sudo command [args...] | sudo -s\n");
            return 2;
        }
        execvp(argv[first], &argv[first]);
    }
    fprintf(stderr, "sudo: exec failed: %s\n", strerror(errno));
    return 127;
}
