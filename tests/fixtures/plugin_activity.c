#include "plugin.h"
void abort(void) { __builtin_trap(); }
static bool subscribed = true;

bool exports_pearl_plugin_guest_handle_event(exports_pearl_plugin_guest_event_t *event, plugin_string_t *err) {
    (void)err;
    if (event->kind == PEARL_PLUGIN_TYPES_EVENT_KIND_ACTIVATE)
        pearl_plugin_host_input_activity(true);
    if (event->kind == PEARL_PLUGIN_TYPES_EVENT_KIND_PREVIEW) {
        subscribed = !subscribed;
        pearl_plugin_host_input_activity(subscribed);
    }
    if (event->kind == PEARL_PLUGIN_TYPES_EVENT_KIND_CLICK) {
        pearl_plugin_host_input_activity(event->node == 2 || event->node == 3);
        if (event->node == 3 || event->node == 4) __builtin_trap();
    }
    return true;
}
