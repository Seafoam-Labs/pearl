// One C import keeps GTK/GIO/Cairo and Linux ABI types consistent across modules.
pub const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_FORTIFY_SOURCE", "0");
    @cDefine("__GI_SCANNER__", "1");
    @cDefine("__GLIB_H_INSIDE__", "1");
    @cInclude("glibconfig.h");
    @cInclude("glib/gmacros.h");
    @cInclude("glib/glib-typeof.h");
    @cUndef("glib_typeof");
    @cUndef("G_GNUC_BEGIN_IGNORE_DEPRECATIONS");
    @cUndef("G_GNUC_END_IGNORE_DEPRECATIONS");
    @cDefine("G_GNUC_BEGIN_IGNORE_DEPRECATIONS", "");
    @cDefine("G_GNUC_END_IGNORE_DEPRECATIONS", "");
    @cDefine("GLIB_DISABLE_DEPRECATION_WARNINGS", "1");
    @cDefine("GDK_DISABLE_DEPRECATION_WARNINGS", "1");
    @cDefine("GTK_COMPILATION", "1"); // GTK 4.22 version-header import guard precedes pragma once.
    @cInclude("gtk/gtk.h");
    @cInclude("gio/gdesktopappinfo.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("dirent.h");
    @cInclude("errno.h");
    @cInclude("signal.h");
    @cInclude("sys/syscall.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/statvfs.h");
    @cInclude("sys/wait.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/ioctl.h");
    @cInclude("ifaddrs.h");
    @cInclude("net/if.h");
    @cInclude("arpa/inet.h");
    @cInclude("dlfcn.h");
    @cInclude("poll.h");
});
