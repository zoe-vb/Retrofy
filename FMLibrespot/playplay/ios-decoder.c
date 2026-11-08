#include <libkern/OSCacheControl.h>
#include <syslog.h>

#include "spotiya.c"

void __clear_cache(void *start, void *end)
{
    sys_icache_invalidate(start, (uintptr_t)end - (uintptr_t)start);
}

int main(void)
{
    openlog("PlayPlayDecoder", LOG_PID, LOG_USER);
    return serve();
}
