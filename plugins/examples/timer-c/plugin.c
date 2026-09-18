#include "plugin.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
void abort(void) { __builtin_trap(); }
static unsigned seconds = 60;
static bool running;
bool exports_pearl_plugin_guest_handle_event(exports_pearl_plugin_guest_event_t *event, plugin_string_t *err) {
    if (event->kind == PEARL_PLUGIN_TYPES_EVENT_KIND_ACTIVATE || event->kind == PEARL_PLUGIN_TYPES_EVENT_KIND_SETTINGS) {
        for (size_t i=0; i<event->settings.len; ++i) {
            pearl_plugin_types_setting_t *s=&event->settings.ptr[i];
            if (s->key.len==7 && !memcmp(s->key.ptr,"seconds",7)) {
                char value[32]={0}; size_t n=s->value.len<31?s->value.len:31;
                memcpy(value,s->value.ptr,n); seconds=(unsigned)atoi(value);
            }
        }
    }
    if (event->kind == PEARL_PLUGIN_TYPES_EVENT_KIND_CLICK) running = !running;
    if (event->kind == PEARL_PLUGIN_TYPES_EVENT_KIND_TIMER && running && seconds) --seconds;
    if (!seconds) running=false;
    if (!pearl_plugin_host_set_timer(running ? 1000 : 0,err)) return false;
    char label[64]; snprintf(label,sizeof(label),"%u:%02u",seconds/60,seconds%60);
    pearl_plugin_types_node_t nodes[2]={0};
    nodes[0].id=1; nodes[0].kind=PEARL_PLUGIN_TYPES_NODE_KIND_LABEL; plugin_string_set(&nodes[0].text,label);
    nodes[1].id=2; nodes[1].kind=PEARL_PLUGIN_TYPES_NODE_KIND_BUTTON; plugin_string_set(&nodes[1].text,running?"Pause":"Start");
    pearl_plugin_host_scene_t scene={.nodes={.ptr=nodes,.len=2}};
    return pearl_plugin_host_publish(&scene,err);
}
