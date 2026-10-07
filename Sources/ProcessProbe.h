#ifndef MAC_TASK_PROCESS_PROBE_H
#define MAC_TASK_PROCESS_PROBE_H
#include <stdint.h>
typedef struct {
    uint32_t uid;
    uint64_t seconds;
    uint64_t microseconds;
    int32_t nice;
} MTPProcessIdentity;
int MTPReadProcess(int32_t pid, MTPProcessIdentity *identity);
#endif
