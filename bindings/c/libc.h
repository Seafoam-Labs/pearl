#define _GNU_SOURCE 1
#undef _FORTIFY_SOURCE
#define _FORTIFY_SOURCE 0
#include <sys/prctl.h>
#include <signal.h>
#include <unistd.h>
#include <sys/resource.h>
#include <langinfo.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <dirent.h>
#include <errno.h>
#include <spawn.h>
