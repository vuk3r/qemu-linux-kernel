#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    const char *endpoint = argc > 1 ? argv[1] : "/dev/pwn-college-char";
    char buffer[256];
    const char probe[] = "vm-compile test\n";
    ssize_t count;
    int file_descriptor;

    file_descriptor = open(endpoint, O_RDWR);
    if (file_descriptor < 0) {
        fprintf(stderr, "open %s: %s\n", endpoint, strerror(errno));
        return 1;
    }
    count = read(file_descriptor, buffer, sizeof(buffer) - 1);
    if (count < 0) {
        fprintf(stderr, "read %s: %s\n", endpoint, strerror(errno));
    } else {
        buffer[count] = '\0';
        printf("read(%s): %s", endpoint, buffer);
    }
    count = write(file_descriptor, probe, sizeof(probe) - 1);
    if (count < 0)
        fprintf(stderr, "write %s: %s\n", endpoint, strerror(errno));
    else
        printf("write(%s): %zd bytes\n", endpoint, count);
    if (close(file_descriptor) != 0) {
        perror("close");
        return 1;
    }
    return 0;
}
