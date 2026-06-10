#include "PTYHelper.h"
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <util.h>        /* openpty */
#include <sys/ioctl.h>
#include <termios.h>
#include <sys/wait.h>

int pty_spawn(const char *executable,
              char *const argv[],
              char *const envp[],
              const char *cwd,
              unsigned short cols,
              unsigned short rows,
              pid_t *pid_out)
{
    int master = -1, slave = -1;
    struct winsize ws = { .ws_row = rows, .ws_col = cols };
    if (openpty(&master, &slave, NULL, NULL, &ws) != 0) return -1;

    pid_t pid = fork();
    if (pid < 0) { close(master); close(slave); return -1; }

    if (pid == 0) {
        /* Child: become a new session so we can take the PTY as ctty */
        setsid();
        ioctl(slave, TIOCSCTTY, 0);
        dup2(slave, STDIN_FILENO);
        dup2(slave, STDOUT_FILENO);
        dup2(slave, STDERR_FILENO);
        if (slave > STDERR_FILENO) close(slave);
        if (master > STDERR_FILENO) close(master);
        if (cwd) chdir(cwd);
        execve(executable, argv, envp);
        _exit(127);
    }

    /* Parent */
    close(slave);
    *pid_out = pid;
    return master;
}

int pty_wait(pid_t pid) {
    int status = 0;
    waitpid(pid, &status, 0);
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}
