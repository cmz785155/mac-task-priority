// No persistent privilege. Each explicitly authorized session supervises one
// process, then restores its nice value when the app exits or the lease ends.
#include <libproc.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <signal.h>
#include <sys/event.h>


static int info(int pid, struct proc_bsdinfo *p) {
    return pid > 1 && proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, p, sizeof(*p)) == sizeof(*p);
}
static int same(int pid, const struct proc_bsdinfo *expected) {
    struct proc_bsdinfo p;
    return info(pid, &p) && p.pbi_uid == expected->pbi_uid &&
        p.pbi_start_tvsec == expected->pbi_start_tvsec && p.pbi_start_tvusec == expected->pbi_start_tvusec;
}
static int priority(int pid, int *value) {
    errno = 0; *value = getpriority(PRIO_PROCESS, pid); return errno == 0;
}
static int number(const char *s, long long *n) {
    char *end; errno = 0; *n = strtoll(s, &end, 10);
    return !errno && *s && !*end && *n >= 0;
}
static int marker(const char *path, uid_t uid, const struct stat *original) {
    struct stat s;
    return !lstat(path, &s) && S_ISREG(s.st_mode) && s.st_uid == uid &&
        (s.st_mode & 0777) == 0600 && s.st_dev == original->st_dev && s.st_ino == original->st_ino;
}
// Sleep in the kernel until cancellation, either process exits, or the lease
// deadline is reached. No repeating timer or sampling wakeup is registered.
static int wait_events(int pid, int ownerpid, const char *path, const struct timespec *deadline, const struct proc_bsdinfo *target, const struct proc_bsdinfo *owner, uid_t uid, const struct stat *lease) {
    int file = open(path, O_EVTONLY | O_NOFOLLOW);
    if (file < 0) return 0;
    int queue = kqueue();
    if (queue < 0) { close(file); return 0; }
    struct kevent changes[3], event;
    EV_SET(&changes[0], (uintptr_t)pid, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT, 0, NULL);
    EV_SET(&changes[1], (uintptr_t)ownerpid, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT, 0, NULL);
    EV_SET(&changes[2], (uintptr_t)file, EVFILT_VNODE, EV_ADD | EV_ONESHOT,
           NOTE_DELETE | NOTE_RENAME | NOTE_WRITE | NOTE_ATTRIB | NOTE_REVOKE, 0, NULL);
    if (kevent(queue, changes, 3, NULL, 0, NULL) < 0) { close(queue); close(file); return 0; }
    // Close the gap between identity validation and event registration.
    if (!same(pid, target) || !same(ownerpid, owner) || !marker(path, uid, lease)) {
        close(queue); close(file); return 1;
    }
    struct stat opened;
    if (fstat(file, &opened) || opened.st_dev != lease->st_dev || opened.st_ino != lease->st_ino) {
        close(queue); close(file); return 1;
    }
    int supported = 1;
    for (;;) {
        struct timespec now, remaining;
        clock_gettime(CLOCK_MONOTONIC, &now);
        remaining.tv_sec = deadline->tv_sec - now.tv_sec;
        remaining.tv_nsec = deadline->tv_nsec - now.tv_nsec;
        if (remaining.tv_nsec < 0) { remaining.tv_sec--; remaining.tv_nsec += 1000000000; }
        if (remaining.tv_sec < 0) break;
        int n = kevent(queue, NULL, 0, &event, 1, &remaining);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 || (n > 0 && (event.flags & EV_ERROR))) supported = 0;
        break;
    }
    close(queue); close(file); return supported;
}

int main(int argc, char **argv) {
    struct proc_bsdinfo target, owner; int current;
    long long pid;
    if (argc == 3 && !strcmp(argv[1], "--inspect")) {
        if (!number(argv[2], &pid) || pid > 2147483647 || !info((int)pid, &target) || !priority((int)pid, &current)) return 1;
        printf("%u %llu %llu %d\n", target.pbi_uid,
            (unsigned long long)target.pbi_start_tvsec, (unsigned long long)target.pbi_start_tvusec, current);
        return 0;
    }
    if (argc != 13 || strcmp(argv[1], "--session") || geteuid() != 0) {
        fprintf(stderr, "Explicit administrator authorization required for a bounded priority session.\n"); return 1;
    }
    long long uid, sec, usec, ownerpid, ownersec, ownerusec, duration;
    if (!number(argv[2], &pid) || pid > 2147483647 || !number(argv[3], &uid) || uid < 501 || uid > 2147483647 ||
        !number(argv[4], &sec) || !number(argv[5], &usec) || !number(argv[8], &ownerpid) || ownerpid > 2147483647 ||
        !number(argv[9], &ownersec) || !number(argv[10], &ownerusec) || !number(argv[12], &duration) || duration < 1 || duration > 1800) return 1;
    // Only two fixed scheduling presets. No arbitrary shell, signal or power command.
    int desired;
    if (!strcmp(argv[7], "-5")) desired = -5;
    else if (!strcmp(argv[7], "-10")) desired = -10;
    else return 1;
    char *end; errno = 0; long original = strtol(argv[6], &end, 10);
    if (errno || !*argv[6] || *end || original < -20 || original > 20 || original <= desired) return 1;
    if (!info((int)pid, &target) || target.pbi_uid != uid || target.pbi_start_tvsec != (uint64_t)sec || target.pbi_start_tvusec != (uint64_t)usec ||
        !info((int)ownerpid, &owner) || owner.pbi_uid != uid || owner.pbi_start_tvsec != (uint64_t)ownersec || owner.pbi_start_tvusec != (uint64_t)ownerusec ||
        !priority((int)pid, &current) || current != original) {
        fprintf(stderr, "Process identity or original priority changed; no change made.\n"); return 1;
    }
    struct stat lease;
    if (lstat(argv[11], &lease) || !S_ISREG(lease.st_mode) || lease.st_uid != uid || (lease.st_mode & 0777) != 0600) return 1;
    int ack[2]; if (pipe(ack)) return 1;
    pid_t child = fork();
    if (child < 0) return 1;
    if (child > 0) {
        close(ack[1]); char result = 0;
        ssize_t count = read(ack[0], &result, 1); close(ack[0]);
        if (count == 1 && result == 'Y') { printf("Priority session verified; supervisor PID %d; automatic restoration enabled.\n", child); return 0; }
        waitpid(child, NULL, 0); fprintf(stderr, "Priority change failed or could not be verified.\n"); return 1;
    }
    close(ack[0]); signal(SIGPIPE, SIG_IGN); setsid();
    int null = open("/dev/null", O_RDWR);
    if (null >= 0) { dup2(null, 0); dup2(null, 1); dup2(null, 2); if (null > 2) close(null); }
    int changed = 0;
    if (same((int)pid, &target) && same((int)ownerpid, &owner) && marker(argv[11], (uid_t)uid, &lease) &&
        priority((int)pid, &current) && current == original && setpriority(PRIO_PROCESS, (id_t)pid, desired) == 0) changed = 1;
    char result = changed && priority((int)pid, &current) && current == desired ? 'Y' : 'N';
    write(ack[1], &result, 1); close(ack[1]);
    if (result == 'Y') {
        struct timespec deadline, now, interval = {1, 0};
        clock_gettime(CLOCK_MONOTONIC, &deadline); deadline.tv_sec += duration;
        if (same((int)pid, &target) && same((int)ownerpid, &owner) && marker(argv[11], (uid_t)uid, &lease) &&
            !wait_events((int)pid, (int)ownerpid, argv[11], &deadline, &target, &owner, (uid_t)uid, &lease)) {
            // Preserve recovery if this macOS rejects one of the event filters.
            do {
                nanosleep(&interval, NULL); clock_gettime(CLOCK_MONOTONIC, &now);
                if (!same((int)pid, &target) || !same((int)ownerpid, &owner) || !marker(argv[11], (uid_t)uid, &lease) ||
                    !priority((int)pid, &current) || current != desired) break;
            } while (now.tv_sec < deadline.tv_sec || (now.tv_sec == deadline.tv_sec && now.tv_nsec < deadline.tv_nsec));
        }
    }
    // Never act on a reused PID or overwrite a priority changed by another tool.
    if (changed && same((int)pid, &target) && priority((int)pid, &current) && current == desired)
        setpriority(PRIO_PROCESS, (id_t)pid, (int)original);
    _exit(0);
}
