// Watch the Port's stdin without reading it. The language server uses the original stdio file descriptors, so the guard never relays LSP bytes.
#define _DARWIN_C_SOURCE
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <libproc.h>
#include <mach/mach.h>
#include <sys/event.h>
#include <sys/proc_info.h>
#elif defined(__linux__)
#include <poll.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#endif

extern char **environ;

#if defined(__APPLE__)
struct descendant {
    pid_t pid;
    uintptr_t watch;
    uint64_t start_sec;
    uint64_t start_usec;
    audit_token_t identity;
};

struct tracker {
    int queue;
    struct descendant *children;
    size_t count;
    size_t capacity;
    uintptr_t last_watch; // Zero is reserved for the direct server process.
};

static int watch_process(int queue, pid_t pid, uintptr_t watch)
{
    struct kevent event;
    EV_SET(&event, pid, EVFILT_PROC, EV_ADD | EV_CLEAR, NOTE_FORK | NOTE_EXEC | NOTE_EXIT, 0, (void *)watch);
    return kevent(queue, &event, 1, NULL, 0, NULL);
}

static bool identity_is_live(audit_token_t *identity)
{
    char path[PROC_PIDPATHINFO_MAXSIZE];
    return proc_pidpath_audittoken(identity, path, sizeof(path)) > 0;
}

static bool read_identity(pid_t pid, audit_token_t *identity, struct proc_bsdinfo *info)
{
    mach_port_t task;
    if (pid <= 1 || task_name_for_pid(mach_task_self(), pid, &task) != KERN_SUCCESS) return false;
    mach_msg_type_number_t count = TASK_AUDIT_TOKEN_COUNT;
    kern_return_t result = task_info(task, TASK_AUDIT_TOKEN, (task_info_t)identity, &count);
    mach_port_deallocate(mach_task_self(), task);
    return result == KERN_SUCCESS &&
           proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, info, sizeof(*info)) == sizeof(*info) &&
           identity_is_live(identity);
}

static bool child_identity(struct descendant *child, pid_t parent, audit_token_t *parent_identity)
{
    struct proc_bsdinfo info;
    if (!read_identity(child->pid, &child->identity, &info) ||
        info.pbi_ppid != (unsigned)parent ||
        (parent_identity != NULL && !identity_is_live(parent_identity)))
        return false;
    child->start_sec = info.pbi_start_tvsec;
    child->start_usec = info.pbi_start_tvusec;
    return true;
}

// exec changes the audit token's PID version but keeps the original process birth time. Only refresh a token for that same process.
static bool refresh_identity(struct descendant *child)
{
    if (identity_is_live(&child->identity)) return true;
    audit_token_t identity;
    struct proc_bsdinfo info;
    if (!read_identity(child->pid, &identity, &info) ||
        info.pbi_start_tvsec != child->start_sec || info.pbi_start_tvusec != child->start_usec)
        return false;
    child->identity = identity;
    return true;
}

static bool already_watched(struct tracker *tracker, pid_t pid)
{
    for (size_t i = 0; i < tracker->count; i++) {
        struct descendant *entry = &tracker->children[i];
        if (entry->pid == pid && refresh_identity(entry)) return true;
    }
    return false;
}

static bool remember(struct tracker *tracker, struct descendant child)
{
    if (tracker->count == tracker->capacity) {
        size_t capacity = tracker->capacity == 0 ? 16 : tracker->capacity * 2;
        struct descendant *larger = realloc(tracker->children, capacity * sizeof(*larger));
        if (larger == NULL) {
            perror("minga-lsp-guard: allocating process tracker");
            return false;
        }
        tracker->children = larger;
        tracker->capacity = capacity;
    }

    child.watch = ++tracker->last_watch;
    if (watch_process(tracker->queue, child.pid, child.watch) < 0) return false;
    tracker->children[tracker->count++] = child;
    return true;
}

static void discover_children(struct tracker *tracker, pid_t parent, audit_token_t *parent_identity)
{
    pid_t local[32];
    pid_t *pids = local;
    int capacity = sizeof(local) / sizeof(*local);
    int count;
    while ((count = proc_listchildpids(parent, pids, capacity * sizeof(*pids))) >= capacity) {
        capacity *= 2;
        pid_t *larger = realloc(pids == local ? NULL : pids, capacity * sizeof(*pids));
        if (larger == NULL) {
            perror("minga-lsp-guard: allocating child list");
            break;
        }
        pids = larger;
    }

    for (int i = 0; i < count; i++) {
        struct descendant child = {.pid = pids[i]};
        if (!already_watched(tracker, child.pid) &&
            child_identity(&child, parent, parent_identity) &&
            remember(tracker, child))
            discover_children(tracker, child.pid, &child.identity);
    }
    if (pids != local) free(pids);
}

static int watch_until_closed(struct tracker *tracker, pid_t server)
{
    struct kevent event;
    EV_SET(&event, STDIN_FILENO, EVFILT_READ, EV_ADD | EV_CLEAR, 0, 0, NULL);
    if (kevent(tracker->queue, &event, 1, NULL, 0, NULL) < 0) return -1;
    if (watch_process(tracker->queue, server, 0) < 0) return errno == ESRCH ? 0 : -1;
    discover_children(tracker, server, NULL);

    for (;;) {
        if (kevent(tracker->queue, NULL, 0, &event, 1, NULL) < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (event.filter == EVFILT_READ) {
            if (event.flags & EV_EOF) return 0;
        } else if (event.udata == NULL) {
            if (event.fflags & NOTE_EXIT) return 0;
            discover_children(tracker, server, NULL);
        } else {
            for (size_t i = 0; i < tracker->count; i++) {
                struct descendant child = tracker->children[i];
                if (child.watch != (uintptr_t)event.udata) continue;
                if (event.fflags & NOTE_EXIT)
                    tracker->children[i] = tracker->children[--tracker->count];
                else if (refresh_identity(&tracker->children[i])) {
                    child.identity = tracker->children[i].identity;
                    discover_children(tracker, child.pid, &child.identity);
                }
                break;
            }
        }
    }
}

static int stop_and_reap(pid_t server, int *status)
{
    struct tracker tracker = {.queue = kqueue()};
    int watched = tracker.queue < 0 ? -1 : watch_until_closed(&tracker, server);
    if (watched < 0) perror("minga-lsp-guard: watching language server");

    // NOTE_EXIT arrives after reparenting on Darwin. Keep identities observed before the root exited, and scan again for children still reachable at close.
    kill(-server, SIGSTOP);
    kill(server, SIGSTOP);
    if (tracker.queue >= 0) discover_children(&tracker, server, NULL);
    for (size_t i = 0; i < tracker.count; i++) {
        if (!refresh_identity(&tracker.children[i])) continue;
        struct descendant child = tracker.children[i];
        if (proc_signal_with_audittoken(&child.identity, SIGSTOP) == 0)
            discover_children(&tracker, child.pid, &child.identity);
    }
    for (size_t i = 0; i < tracker.count; i++)
        proc_signal_with_audittoken(&tracker.children[i].identity, SIGKILL);
    free(tracker.children);
    kill(-server, SIGKILL);
    kill(server, SIGKILL);

    pid_t result;
    do {
        result = waitpid(server, status, 0);
    } while (result < 0 && errno == EINTR);
    if (result < 0) perror("minga-lsp-guard: reaping language server");
    return watched < 0 || result < 0 ? -1 : 0;
}
#elif defined(__linux__)
static int wait_for_close_or_exit(pid_t server)
{
    int child = (int)syscall(SYS_pidfd_open, server, 0);
    if (child < 0) return errno == ESRCH ? 0 : -1;

    // With no requested stdin events, poll reports hangup even with unread bytes and never wakes for JSON-RPC data.
    struct pollfd fds[] = {{.fd = STDIN_FILENO}, {.fd = child, .events = POLLIN}};
    int result;
    do {
        result = poll(fds, 2, -1);
    } while (result < 0 && errno == EINTR);
    return result;
}

// The subreaper adopts children that left the server's group. Signal every adopted child before trying to reap again: a child blocked in the kernel must not prevent its siblings from being killed.
static int stop_and_reap(pid_t server, int *status)
{
    int watched = wait_for_close_or_exit(server);
    if (watched < 0) perror("minga-lsp-guard: watching language server");
    kill(-server, SIGKILL);
    kill(server, SIGKILL);

    char path[64];
    snprintf(path, sizeof(path), "/proc/self/task/%ld/children", (long)getpid());
    bool server_reaped = false;
    for (int pass = 0; pass < 100; pass++) {
        pid_t result;
        int current_status;
        while ((result = waitpid(-1, &current_status, WNOHANG)) > 0 || (result < 0 && errno == EINTR)) {
            if (result == server) {
                *status = current_status;
                server_reaped = true;
            }
        }
        if (result < 0) {
            if (errno == ECHILD && server_reaped) return watched < 0 ? -1 : 0;
            break;
        }

        FILE *children = fopen(path, "r");
        if (children == NULL) break;
        pid_t child;
        while (fscanf(children, "%d", &child) == 1)
            if (child > 1) kill(child, SIGKILL);
        fclose(children);
        // Let the kernel reap killed processes and reparent any surviving descendants before enumerating again.
        nanosleep(&(struct timespec){.tv_nsec = 10000000}, NULL);
    }
    fputs("minga-lsp-guard: could not reap all language server processes\n", stderr);
    return -1;
}
#endif

int main(int argc, char **argv)
{
    if (argc < 3) return 64;
    int log = open(argv[1], O_WRONLY | O_CREAT | O_APPEND, 0666);
    if (log < 0 || dup2(log, STDERR_FILENO) < 0) {
        perror("minga-lsp-guard: opening stderr log");
        return 71;
    }
    if (log != STDERR_FILENO) close(log);
    // Keep direct children waitable even if the process that exec'd the guard ignored SIGCHLD.
    signal(SIGCHLD, SIG_DFL);

#if defined(__linux__)
    if (prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) < 0) {
        perror("minga-lsp-guard: enabling child reaping");
        return 71;
    }
#endif

    posix_spawnattr_t attr;
    int error = posix_spawnattr_init(&attr);
    if (error == 0) error = posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
    pid_t server;
    if (error == 0) error = posix_spawn(&server, argv[2], NULL, &attr, argv + 2, environ);
    if (error != 0) {
        errno = error;
        perror("minga-lsp-guard: starting language server");
        return 71;
    }
    posix_spawnattr_destroy(&attr);

    int status;
    if (stop_and_reap(server, &status) < 0) return 71;
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}
