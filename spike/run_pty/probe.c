// Spike for issue #4386. Deterministic probes of what a command sees under runpty.
//   probe isatty        print isatty() for fds 0, 1, 2 and whether /dev/tty opens
//   probe read N        read one byte from fd N and report the result
//   probe devtty        open /dev/tty and read one byte
//   probe tcset N       tcgetattr + tcsetattr on fd N (what an editor or raw-mode program does)
//   probe winsize       report the terminal size and TERM
#define _XOPEN_SOURCE 700
#define _DARWIN_C_SOURCE
#define _DEFAULT_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>

int main(int argc, char **argv) {
  if (argc < 2) return 2;
  if (!strcmp(argv[1], "isatty")) {
    int fd = open("/dev/tty", O_RDWR);
    printf("isatty0=%d isatty1=%d isatty2=%d devtty=%s\n", isatty(0), isatty(1), isatty(2),
           fd >= 0 ? "opens" : strerror(errno));
    return 0;
  }
  if (!strcmp(argv[1], "read") && argc > 2) {
    char c;
    ssize_t n = read(atoi(argv[2]), &c, 1);
    printf("read fd%s -> %zd %s\n", argv[2], n, n < 0 ? strerror(errno) : n == 0 ? "EOF" : "byte");
    return 0;
  }
  if (!strcmp(argv[1], "devtty")) {
    int fd = open("/dev/tty", O_RDWR);
    if (fd < 0) { printf("open /dev/tty -> %s\n", strerror(errno)); return 1; }
    printf("open /dev/tty -> ok, reading\n");
    fflush(stdout);
    char c;
    ssize_t n = read(fd, &c, 1);
    printf("read /dev/tty -> %zd %s\n", n, n < 0 ? strerror(errno) : n == 0 ? "EOF" : "byte");
    return 0;
  }
  if (!strcmp(argv[1], "tcset") && argc > 2) {
    int fd = atoi(argv[2]);
    struct termios t;
    if (tcgetattr(fd, &t) != 0) { printf("tcgetattr fd%d -> %s\n", fd, strerror(errno)); return 1; }
    printf("tcgetattr fd%d -> ok, setting raw\n", fd);
    fflush(stdout);
    t.c_lflag &= ~(ICANON | ECHO);
    int r = tcsetattr(fd, TCSANOW, &t);
    printf("tcsetattr fd%d -> %s\n", fd, r == 0 ? "ok" : strerror(errno));
    return 0;
  }
  if (!strcmp(argv[1], "winsize")) {
    struct winsize ws = {0};
    int r = ioctl(1, TIOCGWINSZ, &ws);
    printf("winsize r=%d cols=%d rows=%d TERM=%s\n", r, ws.ws_col, ws.ws_row, getenv("TERM") ? getenv("TERM") : "(unset)");
    return 0;
  }
  return 2;
}
