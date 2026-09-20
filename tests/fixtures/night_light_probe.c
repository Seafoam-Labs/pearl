// Private-session contract probe. Never run against an unselected user display.
#define _GNU_SOURCE
#include <wayland-client.h>
#include <sys/mman.h>
#include <unistd.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "night-gamma.h"
static struct wl_output *output;
static struct zwlr_gamma_control_manager_v1 *manager;
struct result { uint32_t size; int failed; };
static void size_event(void *data, struct zwlr_gamma_control_v1 *c, uint32_t size) { (void)c; ((struct result *)data)->size = size; }
static void failed_event(void *data, struct zwlr_gamma_control_v1 *c) { (void)c; ((struct result *)data)->failed = 1; }
static const struct zwlr_gamma_control_v1_listener listener = {size_event, failed_event};
static void global(void *data, struct wl_registry *r, uint32_t name, const char *interface, uint32_t version) {
    (void)data;
    if (!strcmp(interface,"wl_output") && !output) output=wl_registry_bind(r,name,&wl_output_interface,version < 3 ? version : 3);
    if (!strcmp(interface,"zwlr_gamma_control_manager_v1")) manager=wl_registry_bind(r,name,&zwlr_gamma_control_manager_v1_interface,1);
}
static void removed(void *data, struct wl_registry *r, uint32_t name) { (void)data; (void)r; (void)name; }
static const struct wl_registry_listener registry_listener = {global, removed};
int main(void) {
    const char *runtime=getenv("XDG_RUNTIME_DIR");
    if (!runtime || strncmp(runtime,"/tmp/pearl-dev-",15)) return 2;
    struct wl_display *d=wl_display_connect(NULL);
    if (!d) return 3;
    struct wl_registry *r=wl_display_get_registry(d);
    wl_registry_add_listener(r,&registry_listener,NULL);
    if (wl_display_roundtrip(d)<0 || !output) return 4;
    if (!manager) { puts("{\"protocol\":false}"); wl_display_disconnect(d); return 0; }
    struct result first={0}, second={0}, after={0};
    struct zwlr_gamma_control_v1 *one=zwlr_gamma_control_manager_v1_get_gamma_control(manager,output);
    zwlr_gamma_control_v1_add_listener(one,&listener,&first);
    if (wl_display_roundtrip(d)<0) return 5;
    int uploaded=0;
    if (!first.failed && first.size>=2 && first.size<=65536) {
        size_t bytes=(size_t)first.size*3*sizeof(uint16_t);
        uint16_t *table=malloc(bytes);
        if (!table) return 6;
        for (uint32_t channel=0;channel<3;channel++) for (uint32_t i=0;i<first.size;i++) table[channel*first.size+i]=(uint16_t)((uint64_t)i*65535/(first.size-1));
        int fd=memfd_create("night-light-probe",MFD_CLOEXEC);
        if (fd<0 || write(fd,table,bytes)!=(ssize_t)bytes) return 7;
        zwlr_gamma_control_v1_set_gamma(one,fd);
        close(fd); free(table);
        if (wl_display_roundtrip(d)<0) return 8;
        uploaded=1;
        struct zwlr_gamma_control_v1 *two=zwlr_gamma_control_manager_v1_get_gamma_control(manager,output);
        zwlr_gamma_control_v1_add_listener(two,&listener,&second);
        if (wl_display_roundtrip(d)<0) return 9;
        zwlr_gamma_control_v1_destroy(two);
    }
    zwlr_gamma_control_v1_destroy(one);
    if (wl_display_roundtrip(d)<0) return 10;
    struct zwlr_gamma_control_v1 *three=zwlr_gamma_control_manager_v1_get_gamma_control(manager,output);
    zwlr_gamma_control_v1_add_listener(three,&listener,&after);
    if (wl_display_roundtrip(d)<0) return 11;
    zwlr_gamma_control_v1_destroy(three);
    zwlr_gamma_control_manager_v1_destroy(manager);
    if (wl_display_roundtrip(d)<0) return 12;
    printf("{\"protocol\":true,\"gamma_size\":%u,\"failed\":%s,\"identity_uploaded\":%s,\"second_failed\":%s,\"after_release_failed\":%s}\n", first.size,first.failed?"true":"false",uploaded?"true":"false",second.failed?"true":"false",after.failed?"true":"false");
    wl_display_disconnect(d);
    return 0;
}
