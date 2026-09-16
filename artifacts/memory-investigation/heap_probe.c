#define _GNU_SOURCE
#include <dlfcn.h>
#include <glib-object.h>
#include <malloc.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>

/* Diagnostic preload, used only by the private reproduction. */
static volatile sig_atomic_t dump_requested, trim_requested;
static unsigned long created[6], finalized[6];
static void finalized_object(void *data, GObject *object) {
    (void)object;
    finalized[(size_t)data]++;
}
static void *track(void *object, size_t kind) {
    created[kind]++;
    g_object_weak_ref(object, finalized_object, (void *)kind);
    return object;
}
#define WRAP1(name, kind, type) \
void *name(type arg) { \
    static void *(*real)(type); \
    if (!real) real = dlsym(RTLD_NEXT, #name); \
    return track(real(arg), kind); \
}
WRAP1(gtk_application_window_new, 0, void *)
WRAP1(gtk_string_list_new, 1, const char **)
WRAP1(gtk_single_selection_new, 2, void *)
void *gtk_box_new(int orientation, int spacing) {
    static void *(*real)(int, int);
    if (!real) real = dlsym(RTLD_NEXT, "gtk_box_new");
    return track(real(orientation, spacing), 3);
}
void *gtk_list_view_new(void *model, void *factory) {
    static void *(*real)(void *, void *);
    if (!real) real = dlsym(RTLD_NEXT, "gtk_list_view_new");
    return track(real(model, factory), 4);
}
void *gtk_css_provider_new(void) {
    static void *(*real)(void);
    if (!real) real = dlsym(RTLD_NEXT, "gtk_css_provider_new");
    return track(real(), 5);
}
static void request(int signal) {
    if (signal == SIGUSR1) trim_requested = 1;
    dump_requested = 1;
}
static gboolean tick(void *unused) {
    (void)unused;
    if (!dump_requested) return G_SOURCE_CONTINUE;
    dump_requested = 0;
    if (trim_requested) { malloc_trim(0); trim_requested = 0; }
    struct mallinfo2 info = mallinfo2();
    fprintf(stderr, "HEAP arena=%zu allocated=%zu free=%zu mmap=%zu objects=", info.arena, info.uordblks, info.fordblks, info.hblkhd);
    for (size_t i=0; i<6; i++) fprintf(stderr, "%lu/%lu ", created[i], finalized[i]);
    fputc('\n', stderr);
    void (*dump)(const char *) = dlsym(RTLD_DEFAULT, "HeapProfilerDump");
    if (dump) dump("sample");
    return G_SOURCE_CONTINUE;
}
__attribute__((constructor)) static void setup(void) {
    signal(SIGUSR1, request);
    signal(SIGUSR2, request);
    g_timeout_add(100, tick, NULL);
}
