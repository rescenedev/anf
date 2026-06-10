#pragma once
#include <stdint.h>
#include <sys/types.h>

/// Spawns a child process with a PTY as its controlling terminal.
/// Returns the master fd on success, -1 on error.
/// `pid_out` receives the child PID.
int pty_spawn(const char *executable,
              char *const argv[],
              char *const envp[],
              const char *cwd,       /* may be NULL */
              unsigned short cols,
              unsigned short rows,
              pid_t *pid_out);

/// waitpid wrapper — returns exit code (or -1 if signalled).
int pty_wait(pid_t pid);
