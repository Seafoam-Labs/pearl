/* Private shell/backend coordination. Holds belong to the current backend
 * owner. */
#include <gio/gio.h>
#include <string.h>
#include "../portal/identity.h"
#define NAME "org.seafoam.Pearl.Session"
#define PATH "/org/seafoam/Pearl/Session"
#define IFACE NAME ".Inhibit"
static GDBusConnection *bus;
typedef struct {
  guint flags;
  char *app, *reason;
} SessionHold;
static void hold_free(gpointer data) {
  SessionHold *h = data;
  g_free(h->app);
  g_free(h->reason);
  g_free(h);
}
static GHashTable *holds;
static char *owner;
static guint watch, registration, name_id, end_timer, next_cookie;
static guint state = 1;
static gboolean locked;
static void (*changed)(void *);
static void *context;
static void (*end_callback)(void *, gboolean);
static const char xml[] =
    "<node><interface name='" IFACE
    "'><method name='Acquire'><arg type='s' direction='in'/><arg type='u' "
    "direction='in'/><arg type='s' direction='in'/><arg type='u' "
    "direction='out'/></method><method name='Release'><arg type='u' "
    "direction='in'/></method><method name='QueryEndResponse'/><property "
    "name='Locked' type='b' access='read'/><property name='State' type='u' "
    "access='read'/></interface></node>";
guint pearl_session_portal_holds(void) {
  guint flags = 0;
  if (holds) {
    GHashTableIter it;
    gpointer value;
    g_hash_table_iter_init(&it, holds);
    while (g_hash_table_iter_next(&it, NULL, &value))
      flags |= ((SessionHold *)value)->flags;
  }
  return flags;
}
char *pearl_session_portal_reason(void) {
  if (holds) {
    GHashTableIter it;
    gpointer value;
    g_hash_table_iter_init(&it, holds);
    while (g_hash_table_iter_next(&it, NULL, &value)) {
      SessionHold *h = value;
      if (h->flags & 1)
        return g_strdup_printf("%s is preventing logout: %s",
                               *h->app ? h->app : "An application", h->reason);
    }
  }
  return g_strdup("An application is preventing logout.");
}
static void publish(void) {
  if (!bus)
    return;
  GVariantBuilder b;
  g_variant_builder_init(&b, G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(&b, "{sv}", "Locked", g_variant_new_boolean(locked));
  g_variant_builder_add(&b, "{sv}", "State", g_variant_new_uint32(state));
  g_dbus_connection_emit_signal(
      bus, NULL, PATH, "org.freedesktop.DBus.Properties", "PropertiesChanged",
      g_variant_new("(s@a{sv}@as)", IFACE, g_variant_builder_end(&b),
                    g_variant_new_strv(NULL, 0)),
      NULL);
}
void pearl_session_portal_update(gboolean value) {
  if (locked != value) {
    locked = value;
    publish();
  }
}
static void call(GDBusConnection *c, const char *sender, const char *path,
                 const char *iface, const char *member, GVariant *params,
                 GDBusMethodInvocation *inv, gpointer data) {
  (void)c;
  (void)path;
  (void)iface;
  (void)data;
  if (!owner || strcmp(sender, owner)) {
    g_dbus_method_invocation_return_error(
        inv, G_DBUS_ERROR, G_DBUS_ERROR_ACCESS_DENIED,
        "Only Pearl's current portal backend may coordinate inhibitors");
    return;
  }
  if (!strcmp(member, "Acquire")) {
    const char *app, *reason;
    guint flags;
    g_variant_get(params, "(&su&s)", &app, &flags, &reason);
    if (!flags || (flags & ~15u) || strlen(app) > 255 ||
        strlen(reason) > 4096 || g_hash_table_size(holds) >= 256 ||
        state == 3) {
      g_dbus_method_invocation_return_error(inv, G_DBUS_ERROR,
                                            G_DBUS_ERROR_INVALID_ARGS,
                                            "Invalid or unavailable hold");
      return;
    }
    do {
      next_cookie++;
    } while (!next_cookie ||
             g_hash_table_contains(holds, GUINT_TO_POINTER(next_cookie)));
    SessionHold *hold = g_new0(SessionHold, 1);
    hold->flags = flags;
    hold->app = g_strdup(app);
    hold->reason = g_strdup(reason);
    g_hash_table_insert(holds, GUINT_TO_POINTER(next_cookie), hold);
    if (changed)
      changed(context);
    g_dbus_method_invocation_return_value(inv,
                                          g_variant_new("(u)", next_cookie));
  } else if (!strcmp(member, "Release")) {
    guint cookie;
    g_variant_get(params, "(u)", &cookie);
    g_hash_table_remove(holds, GUINT_TO_POINTER(cookie));
    if (changed)
      changed(context);
    g_dbus_method_invocation_return_value(inv, NULL);
  } else
    g_dbus_method_invocation_return_value(inv, NULL);
}
static GVariant *property(GDBusConnection *c, const char *sender,
                          const char *path, const char *iface, const char *name,
                          GError **error, gpointer data) {
  (void)c;
  (void)sender;
  (void)path;
  (void)iface;
  (void)error;
  (void)data;
  return !strcmp(name, "Locked") ? g_variant_new_boolean(locked)
                                 : g_variant_new_uint32(state);
}
static const GDBusInterfaceVTable vtable = {.method_call = call,
                                            .get_property = property};
static void appeared(GDBusConnection *c, const char *name, const char *unique,
                     gpointer data) {
  (void)c;
  (void)name;
  (void)data;
  g_free(owner);
  owner = g_strdup(unique);
  g_hash_table_remove_all(holds);
  if (changed)
    changed(context);
}
static void vanished(GDBusConnection *c, const char *name, gpointer data) {
  (void)c;
  (void)name;
  (void)data;
  g_clear_pointer(&owner, g_free);
  g_hash_table_remove_all(holds);
  if (changed)
    changed(context);
}
void pearl_session_portal_start(void (*callback)(void *), void *data) {
  if (bus)
    return;
  changed = callback;
  context = data;
  holds = g_hash_table_new_full(g_direct_hash, g_direct_equal, NULL, hold_free);
  state = 1;
  bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, NULL);
  if (!bus)
    return;
  g_autoptr(GDBusNodeInfo) node = g_dbus_node_info_new_for_xml(xml, NULL);
  registration = g_dbus_connection_register_object(
      bus, PATH, node->interfaces[0], &vtable, NULL, NULL, NULL);
  if (registration)
    name_id = g_bus_own_name_on_connection(
        bus, NAME, G_BUS_NAME_OWNER_FLAGS_NONE, NULL, NULL, NULL, NULL);
  watch = g_bus_watch_name_on_connection(
      bus, PEARL_PORTAL_BUS_NAME,
      G_BUS_NAME_WATCHER_FLAGS_NONE, appeared, vanished, NULL, NULL);
}
static gboolean finish_end(gpointer data) {
  (void)data;
  end_timer = 0;
  gboolean allowed = !(pearl_session_portal_holds() & 1);
  state = allowed ? 3 : 1;
  publish();
  void (*callback)(void *, gboolean) = end_callback;
  end_callback = NULL;
  if (callback)
    callback(context, allowed);
  return G_SOURCE_REMOVE;
}
void pearl_session_portal_begin_end(void (*callback)(void *, gboolean)) {
  if (end_timer)
    return;
  end_callback = callback;
  state = 2;
  publish();
  end_timer = g_timeout_add(1000, finish_end, NULL);
}
void pearl_session_portal_abort_end(void) {
  state = 1;
  publish();
}
void pearl_session_portal_stop(void) {
  if (end_timer)
    g_source_remove(end_timer);
  end_timer = 0;
  end_callback = NULL;
  changed = NULL;
  context = NULL;
  if (watch)
    g_bus_unwatch_name(watch);
  watch = 0;
  if (name_id)
    g_bus_unown_name(name_id);
  name_id = 0;
  if (registration)
    g_dbus_connection_unregister_object(bus, registration);
  registration = 0;
  g_clear_object(&bus);
  g_clear_pointer(&holds, g_hash_table_unref);
  g_clear_pointer(&owner, g_free);
}
