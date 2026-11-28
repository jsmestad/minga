// Spike for issue #4386. Not production code and never merged.
//
// runpty [--ctty yes|no] [--slave rw|wo] [--timeout SEC] [--cols N] [--rows N] -- CMD...
//
// Runs CMD with a pseudo-terminal as stdout and stderr and /dev/null as stdin.
// Output bytes go to this program's stdout. One RESULT line goes to stderr.
//
// --ctty yes: a guard process becomes the session leader and takes the PTY as its controlling
//   terminal. It stays the foreground process group and runs CMD in a background group, so a
//   read from the terminal stops the whole command group with SIGTTIN and a change of terminal
//   settings stops it with SIGTTOU. The guard sees the stop through waitpid(WUNTRACED).
// --ctty no: the command has no controlling terminal at all.
// --slave rw|wo: whether fds 1 and 2 are opened read-write or write-only.
#define _XOPEN_SOURCE 700
#define _DARWIN_C_SOURCE
#define _DEFAULT_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t stop_requested = 0;
static void on_term(int sig) { (void)sig; stop_requested = 1; }

static double now(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec + ts.tv_nsec / 1e9;
}

// Exit codes the guard uses to tell the parent what happened.
enum { G_TTIN = 200, G_TTOU = 201, G_STOPPED_OTHER = 202, G_KILLED_BY_REQUEST = 203, G_EXEC_FAIL = 204 };

static void kill_group(pid_t pg, double grace) {
  // interrupt, then terminate, then kill
  int sigs[] = {SIGINT, SIGTERM, SIGKILL};
  for (int i = 0; i < 3; i++) {
    if (kill(-pg, sigs[i]) != 0 && errno == ESRCH) return;
    kill(-pg, SIGCONT);
    double until = now() + grace;
    while (now() < until) {
      if (kill(-pg, 0) != 0 && errno == ESRCH) return;
      usleep(10000);
    }
  }
}

static int guard(const char *slave_name, int ctty, int slave_wo, char **cmd) {
  if (setsid() < 0) { perror("setsid"); return G_EXEC_FAIL; }
  int slave = -1;
  if (ctty) {
    slave = open(slave_name, O_RDWR);
    if (slave < 0) { perror("open slave"); return G_EXEC_FAIL; }
#ifdef TIOCSCTTY
    if (ioctl(slave, TIOCSCTTY, 0) < 0) { perror("TIOCSCTTY"); return G_EXEC_FAIL; }
#endif
    tcsetpgrp(slave, getpgrp()); // the guard is the foreground group
  }
  struct sigaction sa = {0};
  sa.sa_handler = on_term;
  sigaction(SIGTERM, &sa, NULL);
  signal(SIGTTOU, SIG_IGN); // the guard must never be stopped by its own terminal

  pid_t child = fork();
  if (child == 0) {
    setpgid(0, 0); // a background group of its own
    signal(SIGTTOU, SIG_DFL);
    signal(SIGTERM, SIG_DFL);
    int out = open(slave_name, (slave_wo ? O_WRONLY : O_RDWR) | O_NOCTTY);
    int in = open("/dev/null", O_RDONLY);
    if (out < 0 || in < 0) _exit(G_EXEC_FAIL);
    dup2(in, 0); dup2(out, 1); dup2(out, 2);
    for (int fd = 3; fd < 64; fd++) close(fd);
    execvp(cmd[0], cmd);
    _exit(127);
  }
  setpgid(child, child);

  for (;;) {
    int st;
    pid_t r = waitpid(child, &st, WUNTRACED | WNOHANG);
    if (r == child) {
      if (WIFSTOPPED(st)) {
        int sig = WSTOPSIG(st);
        kill(-child, SIGKILL);
        kill(-child, SIGCONT);
        waitpid(child, &st, 0);
        return sig == SIGTTIN ? G_TTIN : sig == SIGTTOU ? G_TTOU : G_STOPPED_OTHER;
      }
      // The direct child is gone. Anything it left running in its group dies with the run.
      kill_group(child, 0.05);
      if (WIFEXITED(st)) return WEXITSTATUS(st);
      return 128 + WTERMSIG(st);
    }
    if (stop_requested) {
      kill_group(child, 0.2);
      waitpid(child, &st, 0);
      return G_KILLED_BY_REQUEST;
    }
    usleep(5000);
  }
}

int main(int argc, char **argv) {
  int ctty = 1, slave_wo = 0, cols = 120, rows = 50;
  double timeout = 10.0;
  int i = 1;
  for (; i < argc; i++) {
    if (!strcmp(argv[i], "--")) { i++; break; }
    else if (!strcmp(argv[i], "--ctty") && i + 1 < argc) ctty = !strcmp(argv[++i], "yes");
    else if (!strcmp(argv[i], "--slave") && i + 1 < argc) slave_wo = !strcmp(argv[++i], "wo");
    else if (!strcmp(argv[i], "--timeout") && i + 1 < argc) timeout = atof(argv[++i]);
    else if (!strcmp(argv[i], "--cols") && i + 1 < argc) cols = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--rows") && i + 1 < argc) rows = atoi(argv[++i]);
    else { fprintf(stderr, "bad arg %s\n", argv[i]); return 2; }
  }
  if (i >= argc) { fprintf(stderr, "no command\n"); return 2; }

  int master = posix_openpt(O_RDWR | O_NOCTTY);
  if (master < 0 || grantpt(master) < 0 || unlockpt(master) < 0) { perror("pty"); return 2; }
  char slave_name[256];
  strncpy(slave_name, ptsname(master), sizeof slave_name - 1);
  struct winsize ws = {.ws_row = rows, .ws_col = cols};
  ioctl(master, TIOCSWINSZ, &ws);
  // Lines end in \n, not \r\n, and nothing is echoed.
  int s = open(slave_name, O_RDWR | O_NOCTTY);
  struct termios t;
  if (s >= 0) ioctl(s, TIOCSWINSZ, &ws);
  if (s >= 0 && tcgetattr(s, &t) == 0) {
    t.c_oflag &= ~(OPOST);
    t.c_lflag &= ~(ECHO | TOSTOP);
    tcsetattr(s, TCSANOW, &t);
  }

  double started = now();
  pid_t g = fork();
  if (g == 0) {
    close(master);
    if (s >= 0) close(s);
    _exit(guard(slave_name, ctty, slave_wo, &argv[i]));
  }
  // Keep `s` open in the parent so the master never reports hangup before the guard exits.
  int timed_out = 0, st = 0, done = 0;
  char buf[65536];
  size_t total = 0;
  while (!done) {
    struct pollfd p = {.fd = master, .events = POLLIN};
    int pr = poll(&p, 1, 20);
    if (pr > 0 && (p.revents & POLLIN)) {
      ssize_t n = read(master, buf, sizeof buf);
      if (n > 0) { fwrite(buf, 1, (size_t)n, stdout); total += (size_t)n; }
    }
    if (waitpid(g, &st, WNOHANG) == g) done = 1;
    if (!done && !timed_out && now() - started > timeout) { timed_out = 1; kill(g, SIGTERM); }
  }
  // Drain what is left.
  fcntl(master, F_SETFL, O_NONBLOCK);
  for (;;) {
    ssize_t n = read(master, buf, sizeof buf);
    if (n <= 0) break;
    fwrite(buf, 1, (size_t)n, stdout); total += (size_t)n;
  }
  fflush(stdout);
  int code = WIFEXITED(st) ? WEXITSTATUS(st) : 128 + WTERMSIG(st);
  const char *how =
      timed_out ? "TIMEOUT_KILLED" :
      code == G_TTIN ? "STOPPED_READ_TTY(SIGTTIN)" :
      code == G_TTOU ? "STOPPED_SET_TTY(SIGTTOU)" :
      code == G_STOPPED_OTHER ? "STOPPED_OTHER" :
      code == G_EXEC_FAIL ? "SETUP_FAILED" : "EXITED";
  fprintf(stderr, "RESULT how=%s code=%d secs=%.2f bytes=%zu ctty=%s slave=%s\n", how, code, now() - started,
          total, ctty ? "yes" : "no", slave_wo ? "wo" : "rw");
  return 0;
}
