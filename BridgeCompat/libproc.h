#ifndef IOS_CLAUDE_BRIDGE_LIBPROC_H
#define IOS_CLAUDE_BRIDGE_LIBPROC_H

#include <sys/types.h>

#ifndef PROC_PIDPATHINFO_MAXSIZE
#define PROC_PIDPATHINFO_MAXSIZE 4096
#endif

#ifdef __cplusplus
extern "C" {
#endif

int proc_listallpids(void *buffer, int buffersize);
int proc_pidpath(int pid, void *buffer, uint32_t buffersize);
int proc_name(int pid, void *buffer, uint32_t buffersize);

#ifdef __cplusplus
}
#endif

#endif
