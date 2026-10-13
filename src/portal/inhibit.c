#include "contracts.h"
#include "portal.h"
#include <gio/gunixfdlist.h>
#include <string.h>
#include <unistd.h>
#define SHELL "org.seafoam.Pearl.Session"
#define SHELL_PATH "/org/seafoam/Pearl/Session"
#define SHELL_IFACE SHELL ".Inhibit"
typedef struct Inhibitors Inhibitors;
typedef struct {
  gint refs;
  Inhibitors *service;
  char *path, *sender, *app, *reason, *shell;
  guint flags, cookie, registration;
  int fd;
  gboolean closed;
  GDBusMethodInvocation *call;
  GCancellable *cancel;
} Hold;
typedef struct {
  Inhibitors *service;
  char *path, *sender;
  guint registration;
  gboolean waiting;
} Monitor;
struct Inhibitors {
  Portal *portal;
  GHashTable *holds, *monitors;
  char *shell;
  guint watch, signal;
  gboolean ready, locked;
  guint state;
};
static Hold *hold_ref(Hold *h) {
  h->refs++;
  return h;
}
static void release_cookie(Hold *h) {
  if (h->cookie) {
    g_dbus_connection_call(
        h->service->portal->bus, h->shell, SHELL_PATH, SHELL_IFACE, "Release",
        g_variant_new("(u)", h->cookie), NULL, G_DBUS_CALL_FLAGS_NO_AUTO_START,
        3000, NULL, NULL, NULL);
    h->cookie = 0;
  }
}
static void hold_unref(Hold *h) {
  if (--h->refs)
    return;
  release_cookie(h);
  if (h->fd >= 0)
    close(h->fd);
  g_clear_object(&h->call);
  g_object_unref(h->cancel);
  g_free(h->path);
  g_free(h->sender);
  g_free(h->app);
  g_free(h->reason);
  g_free(h->shell);
  g_free(h);
}
static void hold_close(Hold *h) {
  if (h->closed)
    return;
  h->closed = TRUE;
  g_cancellable_cancel(h->cancel);
  release_cookie(h);
  if (h->fd >= 0) {
    close(h->fd);
    h->fd = -1;
  }
  if (h->registration)
    g_dbus_connection_unregister_object(h->service->portal->bus,
                                        h->registration);
  if (h->call) {
    portal_error(h->call, "Cancelled", "Inhibition was cancelled");
    g_clear_object(&h->call);
  }
  g_hash_table_remove(h->service->holds, h->path);
}
static void close_hold(GDBusConnection *c, const char *sender, const char *path,
                       const char *iface, const char *method, GVariant *params,
                       GDBusMethodInvocation *call, gpointer data) {
  (void)c;
  (void)path;
  (void)iface;
  (void)method;
  (void)params;
  Hold *h = data;
  if (strcmp(sender, h->sender)) {
    portal_error(call, "NotAllowed", "Hold belongs to another sender");
    return;
  }
  g_dbus_method_invocation_return_value(call, NULL);
  hold_close(h);
}
static const GDBusInterfaceVTable hold_vtable = {.method_call = close_hold};
static void monitor_free(gpointer data) {
  Monitor *m = data;
  g_dbus_connection_unregister_object(m->service->portal->bus, m->registration);
  g_free(m->path);
  g_free(m->sender);
  g_free(m);
}
static void close_monitor(GDBusConnection *c, const char *sender,
                          const char *path, const char *iface,
                          const char *method, GVariant *params,
                          GDBusMethodInvocation *call, gpointer data) {
  (void)c;
  (void)path;
  (void)iface;
  (void)method;
  (void)params;
  Monitor *m = data;
  if (strcmp(sender, m->sender)) {
    portal_error(call, "NotAllowed", "Monitor belongs to another sender");
    return;
  }
  g_dbus_method_invocation_return_value(call, NULL);
  g_hash_table_remove(m->service->monitors, m->path);
}
static const GDBusInterfaceVTable monitor_vtable = {.method_call =
                                                        close_monitor};
static void emit_state(Monitor *m) {
  Inhibitors *s = m->service;
  GVariantBuilder b;
  g_variant_builder_init(&b, G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(&b, "{sv}", "screensaver-active",
                        g_variant_new_boolean(s->locked));
  g_variant_builder_add(&b, "{sv}", "session-state",
                        g_variant_new_uint32(s->state));
  m->waiting = s->state == 2;
  g_dbus_connection_emit_signal(
      s->portal->bus, m->sender, PORTAL_PATH, IMPL "Inhibit", "StateChanged",
      g_variant_new("(o@a{sv})", m->path, g_variant_builder_end(&b)), NULL);
}
void portal_inhibit_clear(Portal *p) {
  Inhibitors *s = p->inhibitors;
  if (!s)
    return;
  while (g_hash_table_size(s->holds)) {
    GHashTableIter it;
    gpointer h;
    g_hash_table_iter_init(&it, s->holds);
    g_hash_table_iter_next(&it, NULL, &h);
    hold_close(h);
  }
  GHashTableIter it;
  gpointer value;
  g_hash_table_iter_init(&it, s->monitors);
  while (g_hash_table_iter_next(&it, NULL, &value)) {
    Monitor *m = value;
    g_dbus_connection_emit_signal(p->bus, m->sender, m->path, IMPL "Session",
                                  "Closed", NULL, NULL);
  }
  g_hash_table_remove_all(s->monitors);
}
static void state_read(Inhibitors *s, GVariant *values) {
  gboolean locked = s->locked;
  guint state = s->state;
  g_variant_lookup(values, "Locked", "b", &locked);
  g_variant_lookup(values, "State", "u", &state);
  if (state < 1 || state > 3)
    return;
  gboolean change = locked != s->locked || state != s->state || !s->ready;
  s->locked = locked;
  s->state = state;
  s->ready = TRUE;
  if (change) {
    GHashTableIter it;
    gpointer m;
    g_hash_table_iter_init(&it, s->monitors);
    while (g_hash_table_iter_next(&it, NULL, &m))
      emit_state(m);
  }
}
static void shell_signal(GDBusConnection *c, const char *sender,
                         const char *path, const char *iface,
                         const char *member, GVariant *params, gpointer data) {
  (void)c;
  (void)path;
  (void)iface;
  (void)member;
  Inhibitors *s = data;
  if (!s->shell || strcmp(sender, s->shell) ||
      !g_variant_is_of_type(params, G_VARIANT_TYPE("(sa{sv}as)")))
    return;
  const char *changed;
  g_variant_get_child(params, 0, "&s", &changed);
  if (strcmp(changed, SHELL_IFACE))
    return;
  g_autoptr(GVariant) values = g_variant_get_child_value(params, 1);
  state_read(s, values);
}
static void appeared(GDBusConnection *c, const char *name, const char *owner,
                     gpointer data) {
  (void)name;
  Inhibitors *s = data;
  portal_inhibit_clear(s->portal);
  g_free(s->shell);
  s->shell = g_strdup(owner);
  s->ready = FALSE; /* Bounded, same-user service; no UI is waiting during
                       discovery. */
  g_autoptr(GVariant) reply = g_dbus_connection_call_sync(
      c, owner, SHELL_PATH, "org.freedesktop.DBus.Properties", "GetAll",
      g_variant_new("(s)", SHELL_IFACE), G_VARIANT_TYPE("(a{sv})"),
      G_DBUS_CALL_FLAGS_NO_AUTO_START, 1000, NULL, NULL);
  if (reply) {
    g_autoptr(GVariant) values = g_variant_get_child_value(reply, 0);
    state_read(s, values);
  }
}
static void vanished(GDBusConnection *c, const char *name, gpointer data) {
  (void)c;
  (void)name;
  Inhibitors *s = data;
  portal_inhibit_clear(s->portal);
  g_clear_pointer(&s->shell, g_free);
  s->ready = FALSE;
}
void portal_inhibit_init(Portal *p) {
  Inhibitors *s = g_new0(Inhibitors, 1);
  p->inhibitors = s;
  s->portal = p;
  s->state = 1;
  s->holds = g_hash_table_new_full(g_str_hash, g_str_equal, NULL,
                                   (GDestroyNotify)hold_unref);
  s->monitors =
      g_hash_table_new_full(g_str_hash, g_str_equal, NULL, monitor_free);
  s->signal = g_dbus_connection_signal_subscribe(
      p->bus, NULL, "org.freedesktop.DBus.Properties", "PropertiesChanged",
      SHELL_PATH, NULL, G_DBUS_SIGNAL_FLAGS_NONE, shell_signal, s, NULL);
  s->watch = g_bus_watch_name_on_connection(p->bus, SHELL,
                                            G_BUS_NAME_WATCHER_FLAGS_NONE,
                                            appeared, vanished, s, NULL);
}
void portal_inhibit_stop(Portal *p) {
  Inhibitors *s = p->inhibitors;
  portal_inhibit_clear(p);
  g_bus_unwatch_name(s->watch);
  g_dbus_connection_signal_unsubscribe(
      p->bus, s->signal); /* Outstanding callbacks are cancelled; process exits
                             after teardown. */
  g_hash_table_unref(s->holds);
  g_hash_table_unref(s->monitors);
  g_free(s->shell);
  g_free(s);
  p->inhibitors = NULL;
}
static void acquired(Hold *h, gboolean success) {
  if (h->closed)
    return;
  if (success) {
    g_dbus_method_invocation_return_value(h->call, NULL);
    g_clear_object(&h->call);
  } else {
    portal_error(h->call, "Failed",
                 "Could not acquire all requested session holds");
    g_clear_object(&h->call);
    hold_close(h);
  }
}
static void logind_done(GObject *source, GAsyncResult *result, gpointer data) {
  Hold *h = data;
  g_autoptr(GUnixFDList) fds = NULL;
  g_autoptr(GVariant) reply = g_dbus_connection_call_with_unix_fd_list_finish(
      G_DBUS_CONNECTION(source), &fds, result, NULL);
  if (reply && fds && !h->closed) {
    gint index;
    g_variant_get(reply, "(h)", &index);
    h->fd = g_unix_fd_list_get(fds, index, NULL);
  }
  acquired(h, h->fd >= 0);
  hold_unref(h);
}
static void shell_acquired(GObject *source, GAsyncResult *result,
                           gpointer data) {
  Hold *h = data;
  g_autoptr(GVariant) reply =
      g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, NULL);
  if (reply)
    g_variant_get(reply, "(u)", &h->cookie);
  if (h->closed) {
    release_cookie(h);
    hold_unref(h);
    return;
  }
  if (!h->cookie) {
    acquired(h, FALSE);
    hold_unref(h);
    return;
  }
  if (!(h->flags & 12)) {
    acquired(h, TRUE);
    hold_unref(h);
    return;
  }
  g_autoptr(GDBusConnection) system =
      g_bus_get_sync(G_BUS_TYPE_SYSTEM, h->cancel, NULL);
  if (!system) {
    acquired(h, FALSE);
    hold_unref(h);
    return;
  }
  const char *what = (h->flags & 12) == 12 ? "sleep:idle"
                     : (h->flags & 4)      ? "sleep"
                                           : "idle";
  g_dbus_connection_call_with_unix_fd_list(
      system, "org.freedesktop.login1", "/org/freedesktop/login1",
      "org.freedesktop.login1.Manager", "Inhibit",
      g_variant_new("(ssss)", what, h->app, h->reason, "block"),
      G_VARIANT_TYPE("(h)"), G_DBUS_CALL_FLAGS_NO_AUTO_START, 5000, NULL,
      h->cancel, logind_done, h);
}
void portal_inhibit(Portal *p, const char *method, GVariant *params,
                    GDBusMethodInvocation *call) {
  Inhibitors *s = p->inhibitors;
  const char *sender = g_dbus_method_invocation_get_sender(call);
  if (!s->ready || !s->shell) {
    portal_error(call, "Failed", "Pearl session coordination is unavailable");
    return;
  }
  if (!strcmp(method, "QueryEndResponse")) {
    const char *path;
    g_variant_get(params, "(&o)", &path);
    Monitor *m = g_hash_table_lookup(s->monitors, path);
    if (!m || strcmp(m->sender, sender) || !m->waiting) {
      portal_error(call, "InvalidArgument",
                   "No pending query for this session");
      return;
    }
    m->waiting = FALSE;
    g_dbus_method_invocation_return_value(call, NULL);
    return;
  }
  if (!strcmp(method, "CreateMonitor")) {
    const char *path;
    g_variant_get_child(params, 1, "&o", &path);
    if (strlen(path) > 1024 ||
        !g_str_has_prefix(path, PORTAL_PATH "/session/") ||
        g_hash_table_contains(s->monitors, path) ||
        g_hash_table_size(s->monitors) >= 128) {
      g_dbus_method_invocation_return_value(call, g_variant_new("(u)", 2));
      return;
    }
    Monitor *m = g_new0(Monitor, 1);
    m->service = s;
    m->path = g_strdup(path);
    m->sender = g_strdup(sender);
    g_autoptr(GDBusNodeInfo) node =
        g_dbus_node_info_new_for_xml(xml_Session, NULL);
    m->registration = g_dbus_connection_register_object(
        p->bus, path, node->interfaces[0], &monitor_vtable, m, NULL, NULL);
    if (!m->registration) {
      g_free(m->path);
      g_free(m->sender);
      g_free(m);
      g_dbus_method_invocation_return_value(call, g_variant_new("(u)", 2));
      return;
    }
    g_hash_table_insert(s->monitors, m->path, m);
    g_dbus_method_invocation_return_value(call, g_variant_new("(u)", 0));
    emit_state(m);
    return;
  }
  const char *path, *app;
  guint flags;
  g_variant_get_child(params, 0, "&o", &path);
  g_variant_get_child(params, 1, "&s", &app);
  g_variant_get_child(params, 3, "u", &flags);
  g_autoptr(GVariant) options = g_variant_get_child_value(params, 4);
  const char *reason = portal_string(options, "reason", "Application is busy");
  if (!flags || (flags & ~15u) || strlen(reason) > 4096 || strlen(app) > 255 ||
      strlen(path) > 1024 || !g_str_has_prefix(path, PORTAL_PATH "/request/") ||
      g_hash_table_contains(s->holds, path) ||
      g_hash_table_size(s->holds) >= 256) {
    portal_error(call, "InvalidArgument", "Invalid inhibition");
    return;
  }
  Hold *h = g_new0(Hold, 1);
  h->refs = 1;
  h->service = s;
  h->path = g_strdup(path);
  h->sender = g_strdup(sender);
  h->app = g_strdup(app);
  h->reason = g_strdup(reason);
  h->shell = g_strdup(s->shell);
  h->flags = flags;
  h->fd = -1;
  h->call = g_object_ref(call);
  h->cancel = g_cancellable_new();
  g_autoptr(GDBusNodeInfo) node =
      g_dbus_node_info_new_for_xml(xml_Request, NULL);
  h->registration = g_dbus_connection_register_object(
      p->bus, path, node->interfaces[0], &hold_vtable, h, NULL, NULL);
  if (!h->registration) {
    portal_error(call, "Failed", "Could not export hold");
    hold_unref(h);
    return;
  }
  g_hash_table_insert(s->holds, h->path, h);
  /* Do not cancel the Acquire RPC: its reply owns the cookie even if Close
   * wins. */
  g_dbus_connection_call(p->bus, s->shell, SHELL_PATH, SHELL_IFACE, "Acquire",
                         g_variant_new("(sus)", app, flags, reason),
                         G_VARIANT_TYPE("(u)"), G_DBUS_CALL_FLAGS_NO_AUTO_START,
                         5000, NULL, shell_acquired, hold_ref(h));
}
