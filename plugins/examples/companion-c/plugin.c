#include "plugin.h"
#include <string.h>
void abort(void) { __builtin_trap(); }
static bool alternate;
bool exports_pearl_plugin_guest_handle_event(exports_pearl_plugin_guest_event_t *event, plugin_string_t *err) {
    pearl_plugin_host_availability_t activity = pearl_plugin_host_input_activity(true);
    bool tap = event->kind == PEARL_PLUGIN_TYPES_EVENT_KIND_CLICK || event->kind == PEARL_PLUGIN_TYPES_EVENT_KIND_PREVIEW || event->kind == PEARL_PLUGIN_TYPES_EVENT_KIND_ACTIVITY;
    if (tap) alternate = !alternate;
    pearl_plugin_types_node_t nodes[2] = {0};
    nodes[0].id = 1; nodes[0].kind = PEARL_PLUGIN_TYPES_NODE_KIND_IMAGE;
    plugin_string_set(&nodes[0].text,"Pearl cat companion");
    if (tap && !event->reduced_motion) plugin_string_set(&nodes[0].clip,alternate?"tap-left":"tap-right");
    else plugin_string_set(&nodes[0].clip,"idle");
    nodes[1].id = 2; nodes[1].kind = PEARL_PLUGIN_TYPES_NODE_KIND_BUTTON;
    plugin_string_set(&nodes[1].text,activity == PEARL_PLUGIN_HOST_AVAILABILITY_AVAILABLE ? "Tap" : "Tap (local preview)");
    pearl_plugin_host_scene_t scene = {.nodes={.ptr=nodes,.len=2}};
    return pearl_plugin_host_publish(&scene,err);
}
