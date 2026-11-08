#include <errno.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <unistd.h>

#include "playplay-token.h"

extern char **environ;

void fm_playplay_copy_build_token(uint8_t output[16])
{
    memcpy(output, playplay_build_token, sizeof(playplay_build_token));
}

int fm_playplay_spawn(int *fd, pid_t *pid)
{
    const char helper[] = "PlayPlayDecoder";
    char executable[4096];
    uint32_t capacity = sizeof(executable);
    if (_NSGetExecutablePath(executable, &capacity)) return ENAMETOOLONG;
    char *name = strrchr(executable, '/');
    if (!name || (size_t)(name + 1 - executable) + sizeof(helper) > sizeof(executable))
        return ENAMETOOLONG;
    memcpy(name + 1, helper, sizeof(helper));

    int fds[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) < 0) return errno;
    int error = 0;
    for (size_t i = 0; i < 2; ++i) {
        if (fds[i] <= STDERR_FILENO) {
            int copy = fcntl(fds[i], F_DUPFD, STDERR_FILENO + 1);
            if (copy < 0) { error = errno; goto done; }
            close(fds[i]);
            fds[i] = copy;
        }
        if (fcntl(fds[i], F_SETFD, FD_CLOEXEC) < 0) { error = errno; goto done; }
    }

    const struct timeval timeout = {10, 0};
    const int enabled = 1;
    if (setsockopt(fds[0], SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled)) ||
        setsockopt(fds[0], SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) ||
        setsockopt(fds[0], SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout))) {
        error = errno;
        goto done;
    }

    posix_spawn_file_actions_t actions;
    error = posix_spawn_file_actions_init(&actions);
    if (error) goto done;
    error = posix_spawn_file_actions_adddup2(&actions, fds[1], STDIN_FILENO);
    if (!error) error = posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO);
    if (!error) error = posix_spawn_file_actions_addclose(&actions, fds[0]);
    if (!error) error = posix_spawn_file_actions_addclose(&actions, fds[1]);
    char *argv[] = {executable, NULL};
    if (!error) error = posix_spawn(pid, executable, &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);

done:
    close(fds[1]);
    if (error) close(fds[0]);
    else *fd = fds[0];
    return error;
}

void fm_playplay_stop(pid_t pid)
{
    kill(pid, SIGKILL);
    while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {}
}
