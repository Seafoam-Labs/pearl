#define _GNU_SOURCE 1
#undef _FORTIFY_SOURCE
#define _FORTIFY_SOURCE 0
#include <curl/curl.h>
#include <pthread.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>
#include <sys/statvfs.h>
#include <sys/file.h>
