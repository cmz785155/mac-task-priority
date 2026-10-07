#include "ProcessProbe.h"
#include <libproc.h>
#include <sys/resource.h>
#include <errno.h>
int MTPReadProcess(int32_t pid, MTPProcessIdentity *identity) {
    if (!identity || pid <= 1) return 0;
    struct proc_bsdinfo p, after;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &p, sizeof(p)) != sizeof(p)) return 0;
    errno = 0;
    int nice = getpriority(PRIO_PROCESS, (id_t)pid);
    if (errno) return 0;
    // Verify that identity did not change while obtaining the priority.
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &after, sizeof(after)) != sizeof(after) ||
        p.pbi_uid != after.pbi_uid || p.pbi_start_tvsec != after.pbi_start_tvsec || p.pbi_start_tvusec != after.pbi_start_tvusec) return 0;
    identity->uid = p.pbi_uid;
    identity->seconds = p.pbi_start_tvsec;
    identity->microseconds = p.pbi_start_tvusec;
    identity->nice = nice;
    return 1;
}
