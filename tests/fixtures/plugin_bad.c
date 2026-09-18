#include "plugin.h"
void abort(void) { __builtin_trap(); }
bool exports_pearl_plugin_guest_handle_event(exports_pearl_plugin_guest_event_t *event, plugin_string_t *err) {
    (void)event;
#if TEST_CASE == 1
    for (;;) { __asm__ volatile(""); }
#elif TEST_CASE == 2
    __builtin_trap();
#elif TEST_CASE == 3
    plugin_string_t message; plugin_string_set(&message,"bounded log");
    for (int i=0;i<100;i++) pearl_plugin_host_log(&message);
#else
    pearl_plugin_types_node_t nodes[2]={0};
    nodes[0].id=1; nodes[0].kind=PEARL_PLUGIN_TYPES_NODE_KIND_LABEL;
    plugin_string_set(&nodes[0].text,"pending");
    nodes[1]=nodes[0];
    pearl_plugin_host_scene_t scene={.nodes={.ptr=nodes,.len=TEST_CASE==4?2:1}};
#if TEST_CASE == 6
    if (__builtin_wasm_memory_grow(0,65536) != (size_t)-1) __builtin_trap();
    plugin_string_set(&nodes[0].text,"growth rejected");
#endif
    bool result=pearl_plugin_host_publish(&scene,err);
#if TEST_CASE == 5
    __builtin_trap();
#endif
    return result;
#endif
    return true;
}
