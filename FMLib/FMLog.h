//
//  FMLog.h
//  Retrofy
//
//  NSLog also writes to /var/mobile/retrofy.log, so logs can be read on the device without a computer. Both prefix
//  headers include this, which makes every NSLog in the app go through FMLog. Past 1 MB the log moves to
//  retrofy.log.1 and a new one starts.
//

#ifdef __OBJC__

#import <Foundation/Foundation.h>
#include <fcntl.h>
#include <stdio.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#define FMLogPath "/var/mobile/retrofy.log"
#define FMLogOldPath "/var/mobile/retrofy.log.1"
#define FMLogMaximumSize (1024 * 1024)

static inline void FMLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

static inline void FMLog(NSString *format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    // CoreFoundation, so this is the same with and without ARC.
    CFStringRef message = CFStringCreateWithFormatAndArguments(NULL, NULL, (__bridge CFStringRef)format, arguments);
    va_end(arguments);
    if (!message) return;
    NSLog(@"%@", (__bridge NSString *)message);

    struct timeval now;
    gettimeofday(&now, NULL);
    struct tm local;
    localtime_r(&now.tv_sec, &local);
    char stamp[32];
    strftime(stamp, sizeof(stamp), "%Y-%m-%d %H:%M:%S", &local);
    NSString *line = [NSString stringWithFormat:@"%s.%03d %@\n", stamp, (int)(now.tv_usec / 1000), (__bridge NSString *)message];
    CFRelease(message);

    struct stat info;
    if (stat(FMLogPath, &info) == 0 && info.st_size > FMLogMaximumSize) rename(FMLogPath, FMLogOldPath);
    // Appending with one write keeps lines from different threads whole.
    int file = open(FMLogPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (file < 0) return;
    const char *bytes = [line UTF8String];
    if (bytes) write(file, bytes, strlen(bytes));
    close(file);
}

#define NSLog(...) FMLog(__VA_ARGS__)

#endif
