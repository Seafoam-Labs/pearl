// Private test client for real output power changes (no compositor test hooks).
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wayland-client.h>
#include "output-power.h"
struct output { struct wl_output *proxy; char name[256]; };
static struct output outputs[32];
static size_t count;
static struct zwlr_output_power_manager_v1 *manager;
static int completed, failed;
static void geometry(void *d,struct wl_output *o,int32_t x,int32_t y,int32_t pw,int32_t ph,int32_t sub,const char *make,const char *model,int32_t tr) {}
static void mode(void *d,struct wl_output *o,uint32_t f,int32_t w,int32_t h,int32_t r) {}
static void done(void *d,struct wl_output *o) {}
static void scale(void *d,struct wl_output *o,int32_t s) {}
static void name(void *data,struct wl_output *o,const char *value) { snprintf(((struct output *)data)->name,256,"%s",value); }
static void description(void *d,struct wl_output *o,const char *value) {}
static const struct wl_output_listener output_listener={geometry,mode,done,scale,name,description};
static void global(void *data,struct wl_registry *registry,uint32_t id,const char *interface,uint32_t version) {
    if (!strcmp(interface,"zwlr_output_power_manager_v1")) manager=wl_registry_bind(registry,id,&zwlr_output_power_manager_v1_interface,1);
    if (!strcmp(interface,"wl_output") && count<32 && version>=4) {
        struct output *output=&outputs[count++];output->proxy=wl_registry_bind(registry,id,&wl_output_interface,4);
        wl_output_add_listener(output->proxy,&output_listener,output);
    }
}
static void removed(void *d,struct wl_registry *r,uint32_t id) {}
static const struct wl_registry_listener registry_listener={global,removed};
static void power_mode(void *data,struct zwlr_output_power_v1 *power,uint32_t value) { if (value==*(uint32_t *)data) completed=1; }
static void power_failed(void *data,struct zwlr_output_power_v1 *power) { failed=1; }
static const struct zwlr_output_power_v1_listener power_listener={power_mode,power_failed};
int main(int argc,char **argv) {
    if(argc!=3 || (strcmp(argv[2],"on")&&strcmp(argv[2],"off"))) return 2;
    struct wl_display *display=wl_display_connect(NULL);if(!display)return 3;
    struct wl_registry *registry=wl_display_get_registry(display);wl_registry_add_listener(registry,&registry_listener,NULL);
    wl_display_roundtrip(display);wl_display_roundtrip(display);
    struct wl_output *selected=NULL;for(size_t i=0;i<count;i++)if(!strcmp(outputs[i].name,argv[1]))selected=outputs[i].proxy;
    if(!selected||!manager)return 4;
    uint32_t wanted=!strcmp(argv[2],"on")?ZWLR_OUTPUT_POWER_V1_MODE_ON:ZWLR_OUTPUT_POWER_V1_MODE_OFF;
    struct zwlr_output_power_v1 *power=zwlr_output_power_manager_v1_get_output_power(manager,selected);
    zwlr_output_power_v1_add_listener(power,&power_listener,&wanted);
    wl_display_roundtrip(display);
    if(!completed)zwlr_output_power_v1_set_mode(power,wanted);
    while(!completed&&!failed)if(wl_display_dispatch(display)<0)return 5;
    wl_display_disconnect(display);return failed?6:0;
}
