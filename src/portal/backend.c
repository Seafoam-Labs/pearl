#include "contracts.h"
#include "portal.h"
#include <gdk/wayland/gdkwayland.h>
#include <glib-unix.h>
#include <string.h>
static GDBusNodeInfo *request_node;
extern void pearl_portal_appearance_start(void);
extern void pearl_portal_appearance_stop(void);
static const char *implemented[] = {
    "FileChooser",     "AppChooser", "Access",   "Account",
    "DynamicLauncher", "Settings",   "Lockdown", "Email",
    "Notification",    "Print",      "Inhibit",  NULL};
GVariant *portal_empty(void) {
  return g_variant_new_array(G_VARIANT_TYPE("{sv}"), NULL, 0);
}
void portal_error(GDBusMethodInvocation *call, const char *code,
                  const char *message) {
  g_autofree char *name =
      g_strconcat("org.freedesktop.portal.Error.", code, NULL);
  g_dbus_method_invocation_return_dbus_error(call, name, message);
}
GVariant *portal_option(GVariant *options, const char *key, const char *type) {
  return g_variant_lookup_value(options, key, G_VARIANT_TYPE(type));
}
const char *portal_string(GVariant *options, const char *key,
                          const char *fallback) {
  const char *value;
  return g_variant_lookup(options, key, "&s", &value) ? value : fallback;
}
gboolean portal_boolean(GVariant *options, const char *key, gboolean fallback) {
  gboolean v;
  return g_variant_lookup(options, key, "b", &v) ? v : fallback;
}
gboolean portal_authorized(Portal *p, const char *sender) {
  return sender && p->owner && !strcmp(sender, p->owner);
}
char *portal_app_name(const char *id) {
  if (!id || !*id)
    return g_strdup("Application");
  if (strchr(id, '/') || strlen(id) > 255)
    return g_strdup("Application");
  g_autofree char *desktop = g_str_has_suffix(id, ".desktop")
                                 ? g_strdup(id)
                                 : g_strconcat(id, ".desktop", NULL);
  g_autoptr(GDesktopAppInfo) app = g_desktop_app_info_new(desktop);
  return g_strdup(app ? g_app_info_get_display_name(G_APP_INFO(app))
                      : "Application");
}
GtkWidget *portal_label(const char *text) {
  GtkWidget *label = gtk_label_new(text);
  gtk_label_set_wrap(GTK_LABEL(label), TRUE);
  gtk_label_set_xalign(GTK_LABEL(label), 0);
  gtk_label_set_max_width_chars(GTK_LABEL(label), 65);
  return label;
}
Request *portal_request_ref(Request *r) {
  r->refs++;
  return r;
}
void portal_request_unref(Request *r) {
  if (--r->refs)
    return;
  if (r->destroy_data)
    r->destroy_data(r->data);
  g_clear_object(&r->invocation);
  g_clear_object(&r->cancel);
  g_clear_pointer(&r->options, g_variant_unref);
  g_free(r->handle);
  g_free(r->sender);
  g_free(r->app_id);
  g_free(r->parent);
  g_free(r->method);
  g_free(r);
}
void portal_complete(Request *r, guint response, GVariant *results) {
  if (r->finished) {
    if (results)
      g_variant_unref(g_variant_ref_sink(results));
    return;
  }
  r->finished = TRUE;
  g_cancellable_cancel(r->cancel);
  if (r->dialog) {
    g_signal_handlers_disconnect_by_data(r->dialog, r);
    gtk_window_destroy(GTK_WINDOW(r->dialog));
    g_clear_object(&r->dialog);
  }
  if (r->registration) {
    g_dbus_connection_unregister_object(r->portal->bus, r->registration);
    r->registration = 0;
  }
  if (r->invocation) {
    g_dbus_method_invocation_return_value(
        r->invocation, g_variant_new("(u@a{sv})", response,
                                     results ? results : portal_empty()));
    g_clear_object(&r->invocation);
  }
  g_hash_table_remove(r->portal->requests, r->handle);
}
static void close_request(GDBusConnection *c, const char *sender,
                          const char *path, const char *iface,
                          const char *method, GVariant *params,
                          GDBusMethodInvocation *call, gpointer data) {
  (void)c;
  (void)path;
  (void)iface;
  (void)method;
  (void)params;
  Request *r = data;
  if (strcmp(sender, r->sender)) {
    portal_error(call, "NotAllowed", "Request belongs to another sender");
    return;
  }
  g_dbus_method_invocation_return_value(call, NULL);
  portal_complete(r, 1, NULL);
}
static const GDBusInterfaceVTable request_vtable = {.method_call =
                                                        close_request};
Request *portal_request(Portal *p, GDBusMethodInvocation *call,
                        GVariant *params, const char *method,
                        guint options_index) {
  const char *handle, *app, *parent;
  g_variant_get_child(params, 0, "&o", &handle);
  g_variant_get_child(params, 1, "&s", &app);
  g_variant_get_child(params, 2, "&s", &parent);
  if (strlen(handle) > 1024 || strlen(app) > 255 || strlen(parent) > 4096 ||
      !g_str_has_prefix(handle, "/org/freedesktop/portal/desktop/request/") ||
      g_hash_table_contains(p->requests, handle)) {
    portal_error(call, "InvalidArgument",
                 "Invalid or duplicate request handle");
    return NULL;
  }
  if (g_hash_table_size(p->requests) >= 8) {
    portal_error(call, "Failed", "Too many active dialogs");
    return NULL;
  }
  GHashTableIter iter;
  gpointer value;
  g_hash_table_iter_init(&iter, p->requests);
  while (g_hash_table_iter_next(&iter, NULL, &value)) {
    Request *old = value;
    if (*parent && !strcmp(old->app_id, app) && !strcmp(old->parent, parent)) {
      portal_error(
          call, "Failed",
          "This application already has an active dialog for that window");
      return NULL;
    }
  }
  if (!gtk_init_check()) {
    portal_error(call, "Failed", "No graphical display is available");
    return NULL;
  }
  Request *r = g_new0(Request, 1);
  r->refs = 1;
  r->portal = p;
  r->handle = g_strdup(handle);
  r->sender = g_strdup(g_dbus_method_invocation_get_sender(call));
  r->app_id = g_strdup(app);
  r->parent = g_strdup(parent);
  r->method = g_strdup(method);
  r->invocation = g_object_ref(call);
  r->cancel = g_cancellable_new();
  r->options = g_variant_get_child_value(params, options_index);
  g_autoptr(GError) error = NULL;
  r->registration = g_dbus_connection_register_object(
      p->bus, handle, request_node->interfaces[0], &request_vtable, r, NULL,
      &error);
  if (!r->registration) {
    portal_error(call, "Failed", "Could not register request");
    portal_request_unref(r);
    return NULL;
  }
  g_hash_table_insert(p->requests, r->handle, r);
  return r;
}
static gboolean close_window(GtkWindow *w, gpointer data) {
  (void)w;
  portal_complete(data, 1, NULL);
  return TRUE;
}
static gboolean escape(GtkEventControllerKey *controller, guint key, guint code,
                       GdkModifierType mods, gpointer data) {
  (void)controller;
  (void)code;
  (void)mods;
  if (key != GDK_KEY_Escape)
    return FALSE;
  Request *r = data;
  GtkWidget *focus = gtk_window_get_focus(GTK_WINDOW(r->dialog));
  GtkWidget *popup =
      focus ? gtk_widget_get_ancestor(focus, GTK_TYPE_POPOVER) : NULL;
  if (popup) {
    gtk_popover_popdown(GTK_POPOVER(popup));
    return TRUE;
  }
  portal_complete(data, 1, NULL);
  return TRUE;
}
void portal_present(Request *r) {
  gtk_window_set_modal(GTK_WINDOW(r->dialog),
                       portal_boolean(r->options, "modal", TRUE));
  gtk_widget_realize(GTK_WIDGET(r->dialog));
  GdkSurface *surface = gtk_native_get_surface(GTK_NATIVE(r->dialog));
  if (g_str_has_prefix(r->parent, "wayland:") &&
      GDK_IS_WAYLAND_TOPLEVEL(surface))
    gdk_wayland_toplevel_set_transient_for_exported(GDK_TOPLEVEL(surface),
                                                    r->parent + 8);
  const char *token = portal_string(r->options, "activation_token", "");
  if (*token && GDK_IS_TOPLEVEL(surface))
    gdk_toplevel_set_startup_id(GDK_TOPLEVEL(surface), token);
  g_signal_connect(r->dialog, "close-request", G_CALLBACK(close_window), r);
  GtkEventController *keys = gtk_event_controller_key_new();
  gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE);
  g_signal_connect(keys, "key-pressed", G_CALLBACK(escape), r);
  gtk_widget_add_controller(GTK_WIDGET(r->dialog), keys);
  gtk_window_present(GTK_WINDOW(r->dialog));
}
GtkDialog *portal_dialog(Request *r, const char *title, const char *negative,
                         const char *positive) {
  r->dialog = GTK_DIALOG(gtk_dialog_new());
  g_object_ref_sink(r->dialog);
  gtk_window_set_title(GTK_WINDOW(r->dialog), title);
  gtk_window_set_default_size(GTK_WINDOW(r->dialog), 560, -1);
  gtk_widget_add_css_class(GTK_WIDGET(r->dialog), "pearl-portal");
  pearl_file_style(GTK_WINDOW(r->dialog));
  GtkWidget *body = gtk_dialog_get_content_area(r->dialog);
  gtk_box_set_spacing(GTK_BOX(body), 16);
  gtk_widget_set_margin_start(body, 24);
  gtk_widget_set_margin_end(body, 24);
  gtk_widget_set_margin_top(body, 24);
  gtk_widget_set_margin_bottom(body, 24);
  g_autofree char *name = portal_app_name(r->app_id);
  g_autofree char *caller = g_strdup_printf("Requested by %s", name);
  GtkWidget *identity = portal_label(caller);
  gtk_widget_add_css_class(identity, "dim-label");
  gtk_box_append(GTK_BOX(body), identity);
  GtkWidget *cancel =
      gtk_dialog_add_button(r->dialog, negative, GTK_RESPONSE_CANCEL);
  if (positive) {
    GtkWidget *yes =
        gtk_dialog_add_button(r->dialog, positive, GTK_RESPONSE_ACCEPT);
    gtk_widget_add_css_class(yes, "suggested-action");
  }
  gtk_window_set_focus(GTK_WINDOW(r->dialog), cancel);
  gtk_dialog_set_default_response(r->dialog, GTK_RESPONSE_CANCEL);
  return r->dialog;
}
static void method(GDBusConnection *c, const char *sender, const char *path,
                   const char *iface, const char *member, GVariant *params,
                   GDBusMethodInvocation *call, gpointer data) {
  (void)c;
  (void)path;
  Portal *p = data;
  if (!portal_authorized(p, sender)) {
    portal_error(
        call, "NotAllowed",
        "Only the current desktop portal frontend may call this backend");
    return;
  }
  if (g_variant_get_size(params) > 1024 * 1024) {
    portal_error(call, "InvalidArgument", "Request exceeds resource limits");
    return;
  }
  if (!strcmp(iface, IMPL "Settings")) {
    portal_settings_call(p, member, params, call);
    return;
  }
  if (!strcmp(iface, IMPL "Inhibit")) {
    portal_inhibit(p, member, params, call);
    return;
  }
  if (!strcmp(iface, IMPL "Notification")) {
    portal_notification(p, member, params, call);
    return;
  }
  if (!strcmp(member, "RequestInstallToken")) {
    g_dbus_method_invocation_return_value(call, g_variant_new("(u)", 2));
    return;
  }
  if (!strcmp(member, "UpdateChoices")) {
    const char *handle;
    g_variant_get_child(params, 0, "&o", &handle);
    Request *r = g_hash_table_lookup(p->requests, handle);
    if (!r || strcmp(r->sender, sender) ||
        strcmp(r->method, "ChooseApplication")) {
      portal_error(call, "InvalidArgument",
                   "Unknown application-choice request");
      return;
    }
    g_autoptr(GVariant) choices = g_variant_get_child_value(params, 1);
    portal_update_choices(r, choices);
    g_dbus_method_invocation_return_value(call, NULL);
    return;
  }
  guint n = g_variant_n_children(params);
  Request *r = portal_request(p, call, params, member, n - 1);
  if (!r)
    return;
  if (!strcmp(iface, IMPL "FileChooser"))
    portal_files(r, params);
  else if (!strcmp(iface, IMPL "Email"))
    portal_email(r);
  else if (!strcmp(iface, IMPL "Print"))
    portal_print(r, params);
  else
    portal_dialogs(r, params);
}
static GVariant *property(GDBusConnection *c, const char *sender,
                          const char *path, const char *iface, const char *name,
                          GError **error, gpointer data) {
  (void)c;
  (void)sender;
  (void)path;
  Portal *p = data;
  if (!strcmp(iface, IMPL "Lockdown"))
    return portal_settings_property(p, name, error);
  if (!strcmp(name, "SupportedLauncherTypes"))
    return g_variant_new_uint32(3);
  if (!strcmp(name, "SupportedOptions"))
    return portal_empty();
  if (!strcmp(iface, IMPL "Notification") && !strcmp(name, "version"))
    return g_variant_new_uint32(2);
  if (!strcmp(name, "version"))
    return g_variant_new_uint32(1);
  g_set_error_literal(error, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_PROPERTY,
                      "Unknown property");
  return NULL;
}
static gboolean set_property(GDBusConnection *c, const char *sender,
                             const char *path, const char *iface,
                             const char *name, GVariant *value, GError **error,
                             gpointer data) {
  (void)c;
  (void)sender;
  (void)path;
  (void)iface;
  (void)name;
  (void)value;
  (void)data;
  g_set_error_literal(error, G_DBUS_ERROR, G_DBUS_ERROR_ACCESS_DENIED,
                      "Desktop restrictions are administrator-owned");
  return FALSE;
}
static const GDBusInterfaceVTable vtable = {.method_call = method,
                                            .get_property = property,
                                            .set_property = set_property};
static void cancel_all(Portal *p) {
  portal_print_clear(p);
  portal_inhibit_clear(p);
  while (g_hash_table_size(p->requests)) {
    GHashTableIter iter;
    gpointer r;
    g_hash_table_iter_init(&iter, p->requests);
    g_hash_table_iter_next(&iter, NULL, &r);
    portal_complete(r, 1, NULL);
  }
}
static void appeared(GDBusConnection *c, const char *name, const char *owner,
                     gpointer data) {
  (void)c;
  (void)name;
  Portal *p = data;
  if (g_strcmp0(p->owner, owner)) {
    cancel_all(p);
    g_free(p->owner);
    p->owner = g_strdup(owner);
  }
}
static void vanished(GDBusConnection *c, const char *name, gpointer data) {
  (void)c;
  (void)name;
  Portal *p = data;
  g_clear_pointer(&p->owner, g_free);
  cancel_all(p);
}
static gboolean stop(gpointer data) {
  Portal *p = data;
  p->stopping = TRUE;
  cancel_all(p);
  g_main_loop_quit(p->loop);
  return G_SOURCE_REMOVE;
}
static void disconnected(GDBusConnection *c, gboolean remote, GError *error,
                         gpointer data) {
  (void)c;
  (void)remote;
  (void)error;
  stop(data);
}
int pearl_portal_main(int argc, char **argv) {
  if (argc == 2 && !strcmp(argv[1], "--identity")) {
    g_print("%s\n", PEARL_PORTAL_BUS_NAME);
    return 0;
  }
  if (argc >= 3 && !strcmp(argv[1], "--print-worker"))
    return pearl_print_worker(argc, argv);
  if (argc == 2 && !strcmp(argv[1], "--interfaces")) {
    for (guint i = 0; implemented[i]; i++)
      g_print(IMPL "%s\n", implemented[i]);
    return 0;
  }
  if (argc != 1) {
    g_printerr("Usage: xdg-desktop-portal-pearl [--interfaces]\n");
    return 2;
  }
  gdk_set_allowed_backends("wayland");
  Portal p = {0};
  g_autoptr(GError) error = NULL;
  p.loop = g_main_loop_new(NULL, FALSE);
  p.requests = g_hash_table_new_full(g_str_hash, g_str_equal, NULL,
                                     (GDestroyNotify)portal_request_unref);
  p.bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &error);
  if (!p.bus) {
    g_printerr("Portal session bus unavailable\n");
    return 1;
  }
  g_dbus_connection_set_exit_on_close(p.bus, FALSE);
  g_signal_connect(p.bus, "closed", G_CALLBACK(disconnected), &p);
  request_node = g_dbus_node_info_new_for_xml(xml_Request, NULL);
  const char *xmls[] = {xml_FileChooser, xml_AppChooser,      xml_Access,
                        xml_Account,     xml_DynamicLauncher, xml_Settings,
                        xml_Lockdown,    xml_Email,           xml_Notification,
                        xml_Print,       xml_Inhibit};
  guint ids[G_N_ELEMENTS(xmls)] = {0};
  portal_print_init(&p);
  portal_inhibit_init(&p);
  portal_settings_init(&p);
  portal_notifications_init(&p);
  pearl_portal_appearance_start();
  for (guint i = 0; i < G_N_ELEMENTS(xmls); i++) {
    g_autoptr(GDBusNodeInfo) node =
        g_dbus_node_info_new_for_xml(xmls[i], &error);
    if (!node) {
      g_printerr("Invalid pinned portal contract\n");
      return 1;
    }
    ids[i] = g_dbus_connection_register_object(
        p.bus, PORTAL_PATH, node->interfaces[0], &vtable, &p, NULL, &error);
    if (!ids[i]) {
      g_printerr("Portal interface registration failed\n");
      return 1;
    }
  }
  p.owner_watch = g_bus_watch_name_on_connection(
      p.bus, "org.freedesktop.portal.Desktop", G_BUS_NAME_WATCHER_FLAGS_NONE,
      appeared, vanished, &p, NULL);
  g_autoptr(GVariant) claim = g_dbus_connection_call_sync(
      p.bus, "org.freedesktop.DBus", "/org/freedesktop/DBus",
      "org.freedesktop.DBus", "RequestName",
      g_variant_new("(su)", PEARL_PORTAL_BUS_NAME, 4u), G_VARIANT_TYPE("(u)"),
      G_DBUS_CALL_FLAGS_NONE, 5000, NULL, &error);
  guint status = 0;
  if (claim)
    g_variant_get(claim, "(u)", &status);
  if (status != 1) {
    g_printerr("Pearl portal name is already owned or unavailable\n");
    return 1;
  }
  guint term = g_unix_signal_add(SIGTERM, stop, &p),
        interrupt = g_unix_signal_add(SIGINT, stop, &p);
  g_print("Pearl portal ready\n");
  g_main_loop_run(p.loop);
  if (g_main_context_find_source_by_id(NULL, term))
    g_source_remove(term);
  if (g_main_context_find_source_by_id(NULL, interrupt))
    g_source_remove(interrupt);
  g_bus_unwatch_name(p.owner_watch);
  pearl_portal_appearance_stop();
  portal_settings_stop(&p);
  portal_print_stop(&p);
  portal_inhibit_stop(&p);
  portal_notifications_stop(&p);
  for (guint i = 0; i < G_N_ELEMENTS(ids); i++)
    g_dbus_connection_unregister_object(p.bus, ids[i]);
  g_dbus_node_info_unref(request_node);
  g_hash_table_unref(p.requests);
  g_free(p.owner);
  g_object_unref(p.bus);
  g_main_loop_unref(p.loop);
  return 0;
}
