/* The pinned Linux-PAM application ABI; system libc supplies POSIX identities. */
#include <security/pam_appl.h>
#include <pwd.h>
#include <unistd.h>
