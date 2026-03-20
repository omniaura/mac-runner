#ifndef CHELPERS_H
#define CHELPERS_H

/// Run a command through the system shell with proper terminal I/O handling.
/// Unlike posix_spawn (used by Foundation's Process), system() properly manages
/// terminal foreground process groups, allowing interactive commands like sudo
/// to read passwords from /dev/tty.
int run_system_command(const char *command);

#endif
