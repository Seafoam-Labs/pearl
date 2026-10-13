#include <gio/gio.h>
#include <gio/gunixfdlist.h>
#include <glib-unix.h>
#include <unistd.h>
extern void pearl_session_portal_start(void (*)(void *), void *);
extern void pearl_session_portal_stop(void);
extern guint pearl_session_portal_holds(void);
extern void pearl_session_portal_update(gboolean);
extern void pearl_session_portal_begin_end(void (*)(void *, gboolean));
static guint notice_id, notice_count, replacements;
static guint inhibitors;
static gboolean released(gint fd, GIOCondition condition, gpointer data) {
  (void)condition;
  (void)data;
  inhibitors--;
  close(fd);
  return G_SOURCE_REMOVE;
}
static void ended(void *context, gboolean allowed) {
  (void)context;
  (void)allowed;
}
static void call(GDBusConnection *c, const char *sender, const char *path,
                 const char *iface, const char *member, GVariant *params,
                 GDBusMethodInvocation *inv, gpointer data) {
  (void)c;
  (void)sender;
  (void)path;
  (void)iface;
  (void)data;
  if (!g_strcmp0(member, "InhibitorCount")) {
    g_dbus_method_invocation_return_value(inv,
                                          g_variant_new("(u)", inhibitors));
    return;
  }
  if (!g_strcmp0(member, "Inhibit")) {
    int fds[2];
    if (pipe(fds)) {
      g_dbus_method_invocation_return_error(inv, G_IO_ERROR, G_IO_ERROR_FAILED,
                                            "pipe");
      return;
    }
    GUnixFDList *list = g_unix_fd_list_new();
    g_unix_fd_list_append(list, fds[1], NULL);
    close(fds[1]);
    inhibitors++;
    g_unix_fd_add(fds[0], G_IO_HUP, released, NULL);
    g_dbus_method_invocation_return_value_with_unix_fd_list(
        inv, g_variant_new("(h)", 0), list);
    g_object_unref(list);
    return;
  }

  if (!g_strcmp0(member, "Notify")) {
    guint replace;
    g_variant_get_child(params, 1, "u", &replace);
    if (replace) {
      replacements++;
    } else {
      notice_id++;
      notice_count++;
    }
    g_dbus_method_invocation_return_value(
        inv, g_variant_new("(u)", replace ? replace : notice_id));
    return;
  }
  if (!g_strcmp0(member, "CloseNotification")) {
    notice_count--;
    g_dbus_method_invocation_return_value(inv, NULL);
    return;
  }
  if (!g_strcmp0(member, "Notices")) {
    g_dbus_method_invocation_return_value(
        inv, g_variant_new("(uu)", notice_count, replacements));
    return;
  }
  if (!g_strcmp0(member, "Trigger")) {
    g_dbus_connection_emit_signal(
        c, NULL, "/org/freedesktop/Notifications",
        "org.freedesktop.Notifications", "ActionInvoked",
        g_variant_new("(us)", notice_id, "button-0"), NULL);
    g_dbus_method_invocation_return_value(inv, NULL);
    return;
  }

  if (!g_strcmp0(member, "Holds")) {
    g_dbus_method_invocation_return_value(
        inv, g_variant_new("(u)", pearl_session_portal_holds()));
    return;
  }
  if (!g_strcmp0(member, "Lock")) {
    gboolean locked;
    g_variant_get(params, "(b)", &locked);
    pearl_session_portal_update(locked);
  } else
    pearl_session_portal_begin_end(ended);
  g_dbus_method_invocation_return_value(inv, NULL);
}
int main(void) {
  GDBusConnection *bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, NULL);
  GDBusNodeInfo *node = g_dbus_node_info_new_for_xml(
      "<node><interface name='org.pearl.Test'><method "
      "name='InhibitorCount'><arg type='u' direction='out'/></method><method "
      "name='Notices'><arg "
      "type='u' direction='out'/><arg type='u' "
      "direction='out'/></method><method name='Trigger'/><method "
      "name='Holds'><arg type='u' direction='out'/></method><method "
      "name='Lock'><arg type='b' direction='in'/></method><method "
      "name='End'/></interface></node>",
      NULL);
  const GDBusInterfaceVTable vtable = {.method_call = call};
  g_dbus_connection_register_object(bus, "/org/seafoam/Pearl/Test",
                                    node->interfaces[0], &vtable, NULL, NULL,
                                    NULL);
  GDBusNodeInfo *notify = g_dbus_node_info_new_for_xml(
      "<node><interface name='org.freedesktop.Notifications'><method "
      "name='Notify'><arg type='s' direction='in'/><arg type='u' "
      "direction='in'/><arg type='s' direction='in'/><arg type='s' "
      "direction='in'/><arg type='s' direction='in'/><arg type='as' "
      "direction='in'/><arg type='a{sv}' direction='in'/><arg type='i' "
      "direction='in'/><arg type='u' direction='out'/></method><method "
      "name='CloseNotification'><arg type='u' direction='in'/></method><signal "
      "name='ActionInvoked'><arg type='u'/><arg "
      "type='s'/></signal></interface></node>",
      NULL);
  g_dbus_connection_register_object(bus, "/org/freedesktop/Notifications",
                                    notify->interfaces[0], &vtable, NULL, NULL,
                                    NULL);
  g_bus_own_name_on_connection(bus, "org.freedesktop.Notifications", 0, NULL,
                               NULL, NULL, NULL);
  GDBusNodeInfo *logind = g_dbus_node_info_new_for_xml(
      "<node><interface name='org.freedesktop.login1.Manager'><method "
      "name='Inhibit'><arg type='s' direction='in'/><arg type='s' "
      "direction='in'/><arg type='s' direction='in'/><arg type='s' "
      "direction='in'/><arg type='h' "
      "direction='out'/></method></interface></node>",
      NULL);
  g_dbus_connection_register_object(bus, "/org/freedesktop/login1",
                                    logind->interfaces[0], &vtable, NULL, NULL,
                                    NULL);
  g_bus_own_name_on_connection(bus, "org.freedesktop.login1", 0, NULL, NULL,
                               NULL, NULL);
  pearl_session_portal_start(NULL, NULL);
  g_print("Ready\n");
  GMainLoop *loop = g_main_loop_new(NULL, FALSE);
  g_main_loop_run(loop);
  pearl_session_portal_stop();
  return 0;
}
