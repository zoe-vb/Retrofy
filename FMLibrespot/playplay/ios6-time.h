#ifndef UNICORN_IOS6_TIME_H
#define UNICORN_IOS6_TIME_H
#include <mach/mach_time.h>
#include <stdint.h>
#include <time.h>
#define CLOCK_MONOTONIC 6
static inline int ios6_clock_gettime(int clock, struct timespec *time)
{
    (void)clock;
    mach_timebase_info_data_t scale;
    if (mach_timebase_info(&scale) != 0 || scale.denom == 0) return -1;
    uint64_t ticks = mach_absolute_time();
    uint64_t ns = (ticks / scale.denom) * scale.numer +
                  (ticks % scale.denom) * scale.numer / scale.denom;
    time->tv_sec = ns / 1000000000;
    time->tv_nsec = ns % 1000000000;
    return 0;
}
#define clock_gettime ios6_clock_gettime
#endif
