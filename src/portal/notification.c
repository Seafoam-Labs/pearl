#include "portal.h"
#include <fcntl.h>
#include <gio/gunixfdlist.h>
#include <glib/gstdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#define NOTIFY_NAME "org.freedesktop.Notifications"
#define NOTIFY_PATH "/org/freedesktop/Notifications"
typedef struct {
  char *app, *id, *owner, *token;
  guint native_id;
  GHashTable *actions;
} Notice;
typedef struct {
  Portal *portal;
  GDBusMethodInvocation *call;
  char *key, *owner;
  Notice *notice;
  int icon_fd;
  gboolean remove;
} NoticeJob;
/* Only identities and action routing are retained, never notification text or
 * icons. The runtime directory expires at logout; the bus GUID and service
 * owner prevent numeric IDs crossing service or session boundaries. */
#define STATE_TYPE "(ssa(ssua{s(sav)}))"
#define STATE_LIMIT (8 * 1024 * 1024)
static char *state_path(Portal *p) {
  const char *runtime = g_getenv("XDG_RUNTIME_DIR");
  if (!runtime || !g_path_is_absolute(runtime))
    return NULL;
  g_autofree char *directory =
      g_build_filename(runtime, PEARL_PORTAL_STATE, NULL);
  struct stat st;
  if (g_mkdir_with_parents(directory, 0700) || lstat(directory, &st) ||
      !S_ISDIR(st.st_mode) || st.st_uid != getuid() || (st.st_mode & 077))
    return NULL;
  g_autofree char *name =
      g_strconcat(g_dbus_connection_get_guid(p->bus), ".notifications", NULL);
  return g_build_filename(directory, name, NULL);
}
static void save_state(Portal *p) {
  g_autofree char *path = state_path(p);
  if (!path)
    return;
  if (!p->notification_owner || !g_hash_table_size(p->notifications)) {
    g_unlink(path);
    return;
  }
  GVariantBuilder entries;
  g_variant_builder_init(&entries, G_VARIANT_TYPE("a(ssua{s(sav)})"));
  GHashTableIter iter;
  gpointer value;
  g_hash_table_iter_init(&iter, p->notifications);
  while (g_hash_table_iter_next(&iter, NULL, &value)) {
    Notice *n = value;
    GVariantBuilder actions;
    g_variant_builder_init(&actions, G_VARIANT_TYPE("a{s(sav)}"));
    GHashTableIter ai;
    gpointer key, stored;
    g_hash_table_iter_init(&ai, n->actions);
    while (g_hash_table_iter_next(&ai, &key, &stored))
      g_variant_builder_add(&actions, "{s@(sav)}", (char *)key,
                            g_variant_ref(stored));
    g_variant_builder_add(&entries, "(ssu@a{s(sav)})", n->app, n->id,
                          n->native_id, g_variant_builder_end(&actions));
  }
  g_autoptr(GVariant) state = g_variant_ref_sink(
      g_variant_new("(ss@a(ssua{s(sav)}))", g_dbus_connection_get_guid(p->bus),
                    p->notification_owner, g_variant_builder_end(&entries)));
  if (g_variant_get_size(state) <= STATE_LIMIT)
    g_file_set_contents_full(path, g_variant_get_data(state),
                             g_variant_get_size(state),
                             G_FILE_SET_CONTENTS_CONSISTENT, 0600, NULL);
}
static void load_state(Portal *p) {
  g_autofree char *path = state_path(p);
  if (!path)
    return;
  int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
  if (fd < 0)
    return;
  struct stat st;
  if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_uid != getuid() ||
      (st.st_mode & 077) || st.st_size < 1 || st.st_size > STATE_LIMIT) {
    close(fd);
    return;
  }
  g_autofree char *contents = g_malloc(st.st_size);
  gsize used = 0;
  while (used < (gsize)st.st_size) {
    ssize_t count = read(fd, contents + used, st.st_size - used);
    if (count <= 0)
      break;
    used += count;
  }
  close(fd);
  if (used != (gsize)st.st_size)
    return;
  g_autoptr(GBytes) bytes = g_bytes_new_take(g_steal_pointer(&contents), used);
  g_autoptr(GVariant) state = g_variant_ref_sink(
      g_variant_new_from_bytes(G_VARIANT_TYPE(STATE_TYPE), bytes, FALSE));
  if (!g_variant_is_normal_form(state))
    return;
  const char *guid, *owner;
  GVariant *array;
  g_variant_get(state, "(&s&s@a(ssua{s(sav)}))", &guid, &owner, &array);
  g_autoptr(GVariant) entries = array;
  if (strcmp(guid, g_dbus_connection_get_guid(p->bus)) ||
      g_strcmp0(owner, p->notification_owner) ||
      g_variant_n_children(entries) > 256)
    return;
  for (guint i = 0; i < g_variant_n_children(entries); i++) {
    g_autoptr(GVariant) item = g_variant_get_child_value(entries, i);
    const char *app, *id;
    guint native_id;
    GVariant *actions;
    g_variant_get(item, "(&s&su@a{s(sav)})", &app, &id, &native_id, &actions);
    g_autoptr(GVariant) owned_actions = actions;
    if (strlen(app) > 255 || strlen(id) > 1024 || strchr(app, '\n') ||
        strchr(id, '\n') || !native_id || g_variant_n_children(actions) > 8)
      continue;
    Notice *n = g_new0(Notice, 1);
    n->app = g_strdup(app);
    n->id = g_strdup(id);
    n->owner = g_strdup(owner);
    n->native_id = native_id;
    n->actions = g_hash_table_new_full(g_str_hash, g_str_equal, g_free,
                                       (GDestroyNotify)g_variant_unref);
    GVariantIter iter;
    const char *key;
    GVariant *stored;
    g_variant_iter_init(&iter, actions);
    while (g_variant_iter_next(&iter, "{&s@(sav)}", &key, &stored))
      g_hash_table_insert(n->actions, g_strdup(key), stored);
    g_hash_table_insert(p->notifications, g_strdup_printf("%s\n%s", app, id),
                        n);
  }
}
static void notice_free(gpointer data) {
  Notice *n = data;
  g_free(n->app);
  g_free(n->id);
  g_free(n->owner);
  g_free(n->token);
  g_hash_table_unref(n->actions);
  g_free(n);
}
static void job_free(NoticeJob *job) {
  if (job->icon_fd >= 0)
    close(job->icon_fd);
  g_clear_object(&job->call);
  if (job->notice)
    notice_free(job->notice);
  g_hash_table_remove(job->portal->notification_busy, job->key);
  g_free(job->key);
  g_free(job->owner);
  g_free(job);
}
static void sent(GObject *source, GAsyncResult *result, gpointer data) {
  NoticeJob *job = data;
  Portal *p = job->portal;
  g_autoptr(GError) error = NULL;
  g_autoptr(GVariant) reply =
      g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, &error);
  if (!reply || g_strcmp0(job->owner, p->notification_owner) ||
      !portal_authorized(p, g_dbus_method_invocation_get_sender(job->call))) {
    portal_error(job->call, "Failed",
                 "Notification service is unavailable or changed ownership");
    job_free(job);
    return;
  }
  if (job->remove)
    g_hash_table_remove(p->notifications, job->key);
  else {
    g_variant_get(reply, "(u)", &job->notice->native_id);
    g_hash_table_replace(p->notifications, g_strdup(job->key), job->notice);
    job->notice = NULL;
  }
  save_state(p);
  g_dbus_method_invocation_return_value(job->call, NULL);
  job_free(job);
}
static gboolean action(Notice *n, GVariantBuilder *out, const char *key,
                       const char *label, const char *name, GVariant *target) {
  if ((!*name && strcmp(key, "default")) || strlen(name) > 1024 ||
      strlen(label) > 160 || (target && g_variant_get_size(target) > 1024))
    return FALSE;
  GVariantBuilder args;
  g_variant_builder_init(&args, G_VARIANT_TYPE("av"));
  if (target)
    g_variant_builder_add(&args, "v", target);
  g_hash_table_insert(n->actions, g_strdup(key),
                      g_variant_ref_sink(g_variant_new(
                          "(s@av)", name, g_variant_builder_end(&args))));
  g_variant_builder_add(out, "s", key);
  g_variant_builder_add(out, "s", label);
  return TRUE;
}
static char *icon_name(GDBusMethodInvocation *call, GVariant *notification,
                       int *fd) {
  g_autoptr(GVariant) icon = g_variant_lookup_value(notification, "icon", NULL);
  if (!icon)
    return g_strdup("");
  while (g_variant_is_of_type(icon, G_VARIANT_TYPE_VARIANT)) {
    GVariant *child = g_variant_get_variant(icon);
    g_variant_unref(icon);
    icon = child;
  }
  if (g_variant_is_of_type(icon, G_VARIANT_TYPE_STRING)) {
    const char *name = g_variant_get_string(icon, NULL);
    return !strchr(name, '/') ? g_strdup(name) : NULL;
  }
  if (!g_variant_is_of_type(icon, G_VARIANT_TYPE("(sv)")))
    return NULL;
  const char *kind;
  GVariant *value;
  g_variant_get(icon, "(&sv)", &kind, &value);
  g_autoptr(GVariant) owned = value;
  if (!strcmp(kind, "themed") &&
      g_variant_is_of_type(value, G_VARIANT_TYPE("as")) &&
      g_variant_n_children(value)) {
    const char *name;
    g_variant_get_child(value, 0, "&s", &name);
    return !strchr(name, '/') ? g_strdup(name) : NULL;
  }
  if (!strcmp(kind, "bytes") &&
      g_variant_is_of_type(value, G_VARIANT_TYPE_BYTESTRING)) {
    gsize size;
    const guint8 *bytes = g_variant_get_fixed_array(value, &size, 1);
    if (!size || size > 4 * 1024 * 1024)
      return NULL;
    int descriptor = memfd_create("pearl-notification-icon",
                                  MFD_CLOEXEC | MFD_ALLOW_SEALING);
    if (descriptor < 0)
      return NULL;
    if (write(descriptor, bytes, size) != (ssize_t)size ||
        fcntl(descriptor, F_ADD_SEALS,
              F_SEAL_WRITE | F_SEAL_GROW | F_SEAL_SHRINK | F_SEAL_SEAL) < 0) {
      close(descriptor);
      return NULL;
    }
    *fd = descriptor;
    return g_strdup_printf("/proc/%u/fd/%d", (guint)getpid(), descriptor);
  }
  if (!strcmp(kind, "file") &&
      g_variant_is_of_type(value, G_VARIANT_TYPE_STRING)) {
    g_autofree char *path =
        g_filename_from_uri(g_variant_get_string(value, NULL), NULL, NULL);
    if (!path)
      return NULL;
    int descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    struct stat st;
    if (descriptor < 0)
      return NULL;
    if (fstat(descriptor, &st) || !S_ISREG(st.st_mode) || st.st_size <= 0 ||
        st.st_size > 4 * 1024 * 1024) {
      close(descriptor);
      return NULL;
    }
    *fd = descriptor;
    return g_strdup_printf("/proc/%u/fd/%d", (guint)getpid(), descriptor);
  }
  if (!strcmp(kind, "file-descriptor") &&
      g_variant_is_of_type(value, G_VARIANT_TYPE_HANDLE)) {
    GUnixFDList *fds = g_dbus_message_get_unix_fd_list(
        g_dbus_method_invocation_get_message(call));
    if (!fds)
      return NULL;
    int descriptor = g_unix_fd_list_get(fds, g_variant_get_handle(value), NULL);
    if (descriptor < 0)
      return NULL;
    struct stat st;
    int seals = fcntl(descriptor, F_GET_SEALS);
    if (fstat(descriptor, &st) || !S_ISREG(st.st_mode) || st.st_size <= 0 ||
        st.st_size > 4 * 1024 * 1024 || seals < 0 || !(seals & F_SEAL_WRITE)) {
      close(descriptor);
      return NULL;
    }
    *fd = descriptor;
    return g_strdup_printf("/proc/%u/fd/%d", (guint)getpid(), descriptor);
  }
  return NULL;
}
void portal_notification(Portal *p, const char *method, GVariant *params,
                         GDBusMethodInvocation *call) {
  const char *app, *id;
  g_variant_get_child(params, 0, "&s", &app);
  g_variant_get_child(params, 1, "&s", &id);
  if (strlen(app) > 255 || strlen(id) > 1024 || strchr(app, '\n') ||
      strchr(id, '\n')) {
    portal_error(call, "InvalidArgument", "Invalid notification identity");
    return;
  }
  g_autofree char *key = g_strdup_printf("%s\n%s", app, id);
  if (!p->notification_owner) {
    portal_error(call, "Failed", "Pearl notification service is unavailable");
    return;
  }
  if (g_hash_table_contains(p->notification_busy, key)) {
    portal_error(call, "Failed", "A notification update is already pending");
    return;
  }
  Notice *old = g_hash_table_lookup(p->notifications, key);
  gboolean remove = !strcmp(method, "RemoveNotification");
  if (remove && !old) {
    g_dbus_method_invocation_return_value(call, NULL);
    return;
  }
  if (!remove && !old &&
      g_hash_table_size(p->notifications) +
              g_hash_table_size(p->notification_busy) >=
          256) {
    portal_error(call, "Failed", "Notification capacity reached");
    return;
  }
  NoticeJob *job = g_new0(NoticeJob, 1);
  job->portal = p;
  job->call = g_object_ref(call);
  job->key = g_strdup(key);
  job->owner = g_strdup(p->notification_owner);
  job->icon_fd = -1;
  job->remove = remove;
  g_hash_table_add(p->notification_busy, g_strdup(key));
  if (remove) {
    g_dbus_connection_call(
        p->bus, job->owner, NOTIFY_PATH, NOTIFY_NAME, "CloseNotification",
        g_variant_new("(u)", old->native_id), NULL,
        G_DBUS_CALL_FLAGS_NO_AUTO_START, 5000, NULL, sent, job);
    return;
  }
  g_autoptr(GVariant) values = g_variant_get_child_value(params, 2);
  if (g_variant_get_size(values) > 1024 * 1024) {
    portal_error(call, "InvalidArgument",
                 "Notification exceeds resource limits");
    job_free(job);
    return;
  }
  Notice *n = g_new0(Notice, 1);
  job->notice = n;
  n->app = g_strdup(app);
  n->id = g_strdup(id);
  n->owner = g_strdup(p->notification_owner);
  n->actions = g_hash_table_new_full(g_str_hash, g_str_equal, g_free,
                                     (GDestroyNotify)g_variant_unref);
  g_autofree char *icon = icon_name(call, values, &job->icon_fd);
  if (!icon) {
    portal_error(call, "InvalidArgument", "Invalid notification icon");
    job_free(job);
    return;
  }
  GVariantBuilder actions, hints;
  g_variant_builder_init(&actions, G_VARIANT_TYPE("as"));
  g_variant_builder_init(&hints, G_VARIANT_TYPE_VARDICT);
  const char *default_action = portal_string(values, "default-action", "");
  g_autoptr(GVariant) default_target =
      g_variant_lookup_value(values, "default-action-target", NULL);
  g_autofree char *display = portal_app_name(app);
  g_autoptr(GVariant) buttons = portal_option(values, "buttons", "aa{sv}");
  if (!action(n, &actions, "default", "Open", default_action, default_target))
    goto invalid;
  if (buttons) {
    if (g_variant_n_children(buttons) > 7)
      goto invalid;
    for (guint i = 0; i < g_variant_n_children(buttons); i++) {
      g_autoptr(GVariant) button = g_variant_get_child_value(buttons, i);
      g_autoptr(GVariant) target =
          g_variant_lookup_value(button, "target", NULL);
      const char *caption = portal_string(button, "label", "");
      if (!*caption)
        continue;
      g_autofree char *action_key = g_strdup_printf("button-%u", i);
      if (!action(n, &actions, action_key, caption,
                  portal_string(button, "action", ""), target))
        goto invalid;
    }
  }
  const char *priority = portal_string(values, "priority", "normal");
  guchar urgency = !strcmp(priority, "low")      ? 0
                   : !strcmp(priority, "urgent") ? 2
                                                 : 1;
  g_variant_builder_add(&hints, "{sv}", "desktop-entry",
                        g_variant_new_string(app));
  g_variant_builder_add(&hints, "{sv}", "urgency", g_variant_new_byte(urgency));
  const char *category = portal_string(values, "category", "");
  if (*category)
    g_variant_builder_add(&hints, "{sv}", "category",
                          g_variant_new_string(category));
  g_dbus_connection_call(
      p->bus, job->owner, NOTIFY_PATH, NOTIFY_NAME, "Notify",
      g_variant_new(
          "(susss@as@a{sv}i)", display, old ? old->native_id : 0, icon,
          portal_string(values, "title", ""), portal_string(values, "body", ""),
          g_variant_builder_end(&actions), g_variant_builder_end(&hints), -1),
      G_VARIANT_TYPE("(u)"), G_DBUS_CALL_FLAGS_NO_AUTO_START, 5000, NULL, sent,
      job);
  return;
invalid:
  g_variant_builder_clear(&actions);
  g_variant_builder_clear(&hints);
  portal_error(call, "InvalidArgument", "Invalid notification actions");
  job_free(job);
}
static void signal_received(GDBusConnection *bus, const char *sender,
                            const char *path, const char *interface,
                            const char *member, GVariant *params,
                            gpointer data) {
  (void)path;
  (void)interface;
  Portal *p = data;
  if (g_strcmp0(sender, p->notification_owner))
    return;
  if ((!strcmp(member, "NotificationClosed") &&
       !g_variant_is_of_type(params, G_VARIANT_TYPE("(uu)"))) ||
      ((!strcmp(member, "ActionInvoked") ||
        !strcmp(member, "ActivationToken")) &&
       !g_variant_is_of_type(params, G_VARIANT_TYPE("(us)"))) ||
      (strcmp(member, "NotificationClosed") &&
       strcmp(member, "ActionInvoked") && strcmp(member, "ActivationToken")))
    return;
  guint id;
  g_variant_get_child(params, 0, "u", &id);
  GHashTableIter iter;
  gpointer value;
  g_hash_table_iter_init(&iter, p->notifications);
  while (g_hash_table_iter_next(&iter, NULL, &value)) {
    Notice *n = value;
    if (n->native_id != id)
      continue;
    if (!strcmp(member, "NotificationClosed")) {
      g_hash_table_iter_remove(&iter);
      save_state(p);
      return;
    }
    const char *key;
    g_variant_get_child(params, 1, "&s", &key);
    if (!strcmp(member, "ActivationToken")) {
      g_free(n->token);
      n->token = g_strdup(key);
      return;
    }
    if (strcmp(member, "ActionInvoked"))
      return;
    GVariant *stored = g_hash_table_lookup(n->actions, key);
    if (!stored)
      return;
    const char *name;
    GVariant *arguments;
    g_variant_get(stored, "(&s@av)", &name, &arguments);
    g_autoptr(GVariant) args = arguments;
    GVariantBuilder platform;
    g_variant_builder_init(&platform, G_VARIANT_TYPE_VARDICT);
    if (n->token)
      g_variant_builder_add(&platform, "{sv}", "activation-token",
                            g_variant_new_string(n->token));
    if (!*name) {
      g_autofree char *desktop = g_strconcat(n->app, ".desktop", NULL);
      g_autoptr(GDesktopAppInfo) app = g_desktop_app_info_new(desktop);
      g_autoptr(GAppLaunchContext) context = g_app_launch_context_new();
      if (n->token)
        g_app_launch_context_setenv(context, "XDG_ACTIVATION_TOKEN", n->token);
      if (app)
        g_app_info_launch(G_APP_INFO(app), NULL, context, NULL);
      g_variant_builder_clear(&platform);
    } else if (g_str_has_prefix(name, "app.") && g_dbus_is_name(n->app)) {
      g_autofree char *object_path = g_strdup_printf("/%s", n->app);
      for (char *c = object_path; *c; c++) {
        if (*c == '.')
          *c = '/';
        else if (*c == '-')
          *c = '_';
      }
      if (g_variant_is_object_path(object_path))
        g_dbus_connection_call(
            bus, n->app, object_path, "org.freedesktop.Application",
            "ActivateAction",
            g_variant_new("(s@av@a{sv})", name + 4, g_variant_ref(args),
                          g_variant_builder_end(&platform)),
            NULL, G_DBUS_CALL_FLAGS_NONE, 5000, NULL, NULL, NULL);
      else
        g_variant_builder_clear(&platform);
    } else {
      GVariantBuilder parameters;
      g_variant_builder_init(&parameters, G_VARIANT_TYPE("av"));
      for (guint i = 0; i < g_variant_n_children(args); i++) {
        g_autoptr(GVariant) item = g_variant_get_child_value(args, i);
        g_variant_builder_add_value(&parameters, item);
      }
      g_variant_builder_add(&parameters, "v", g_variant_builder_end(&platform));
      g_dbus_connection_emit_signal(
          bus, p->owner, PORTAL_PATH, IMPL "Notification", "ActionInvoked",
          g_variant_new("(sss@av)", n->app, n->id, name,
                        g_variant_builder_end(&parameters)),
          NULL);
    }
    g_clear_pointer(&n->token, g_free);
    return;
  }
}
static void owner_ready(GDBusConnection *bus, const char *name,
                        const char *owner, gpointer data) {
  (void)bus;
  (void)name;
  Portal *p = data;
  g_hash_table_remove_all(p->notifications);
  g_free(p->notification_owner);
  p->notification_owner = g_strdup(owner);
  load_state(p);
  save_state(p);
}
static void owner_gone(GDBusConnection *bus, const char *name, gpointer data) {
  (void)bus;
  (void)name;
  Portal *p = data;
  g_clear_pointer(&p->notification_owner, g_free);
  g_hash_table_remove_all(p->notifications);
  save_state(p);
}
void portal_notifications_init(Portal *p) {
  p->notifications =
      g_hash_table_new_full(g_str_hash, g_str_equal, g_free, notice_free);
  p->notification_busy =
      g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
  p->notification_watch = g_bus_watch_name_on_connection(
      p->bus, NOTIFY_NAME, G_BUS_NAME_WATCHER_FLAGS_NONE, owner_ready,
      owner_gone, p, NULL);
  p->notification_signal = g_dbus_connection_signal_subscribe(
      p->bus, NULL, NOTIFY_NAME, NULL, NOTIFY_PATH, NULL,
      G_DBUS_SIGNAL_FLAGS_NONE, signal_received, p, NULL);
}
void portal_notifications_stop(Portal *p) {
  g_bus_unwatch_name(p->notification_watch);
  g_dbus_connection_signal_unsubscribe(p->bus, p->notification_signal);
  g_clear_pointer(&p->notification_owner, g_free);
  g_hash_table_unref(p->notifications);
  g_hash_table_unref(p->notification_busy);
}
