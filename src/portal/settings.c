#include "portal.h"
#include <glib/gstdio.h>
#include <string.h>
#include <sys/stat.h>
static Portal *active;
static GtkCssProvider *style;
static char *pending_css;
static void portal_style_display(GdkDisplay *display) {
  if (style && !g_object_get_data(G_OBJECT(display), "pearl-portal-style")) {
    gtk_style_context_add_provider_for_display(
        display, GTK_STYLE_PROVIDER(style),
        GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_set_data(G_OBJECT(display), "pearl-portal-style",
                      GINT_TO_POINTER(1));
  }
  if (active) {
    GVariant *font = g_hash_table_lookup(
        active->settings, "org.gnome.desktop.interface/font-name");
    GVariant *motion = g_hash_table_lookup(
        active->settings, "org.gnome.desktop.interface/enable-animations");
    if (font && motion)
      g_object_set(gtk_settings_get_for_display(display), "gtk-font-name",
                   g_variant_get_string(font, NULL), "gtk-enable-animations",
                   g_variant_get_boolean(motion), NULL);
  }
}
static const char *keys[] = {"disable-printing",
                             "disable-save-to-disk",
                             "disable-application-handlers",
                             "disable-location",
                             "disable-camera",
                             "disable-microphone",
                             "disable-sound-output",
                             NULL};
static void setting(Portal *p, const char *space, const char *key,
                    GVariant *value) {
  g_autofree char *id = g_strconcat(space, "/", key, NULL);
  value = g_variant_ref_sink(value);
  GVariant *old = g_hash_table_lookup(p->settings, id);
  gboolean changed = !old || !g_variant_equal(old, value);
  if (changed) {
    g_hash_table_replace(p->settings, g_strdup(id), value);
    g_dbus_connection_emit_signal(
        p->bus, NULL, PORTAL_PATH, IMPL "Settings", "SettingChanged",
        g_variant_new("(ssv)", space, key, value), NULL);
  } else
    g_variant_unref(value);
}
void portal_appearance(guint scheme, double r, double g, double b,
                       gboolean reduced, const char *font, const char *css) {
  if (!active)
    return;
  setting(active, "org.freedesktop.appearance", "color-scheme",
          g_variant_new_uint32(scheme));
  setting(active, "org.freedesktop.appearance", "accent-color",
          g_variant_new("(ddd)", r, g, b));
  setting(active, "org.freedesktop.appearance", "contrast",
          g_variant_new_uint32(0));
  setting(active, "org.freedesktop.appearance", "reduced-motion",
          g_variant_new_uint32(reduced ? 1 : 0));
  setting(active, "org.gnome.desktop.interface", "color-scheme",
          g_variant_new_string(scheme == 1 ? "prefer-dark" : "prefer-light"));
  setting(active, "org.gnome.desktop.interface", "font-name",
          g_variant_new_string(font));
  setting(active, "org.gnome.desktop.interface", "enable-animations",
          g_variant_new_boolean(!reduced));
  g_free(pending_css);
  pending_css = g_strdup(css);
  if (gdk_display_get_default()) {
    if (!style) {
      style = gtk_css_provider_new();
    }
    gtk_css_provider_load_from_string(style, pending_css);
    portal_style_display(gdk_display_get_default());
    g_object_set(gtk_settings_get_default(), "gtk-enable-animations", !reduced,
                 "gtk-font-name", font, NULL);
  }
}
static gboolean known(const char *key) {
  for (guint i = 0; keys[i]; i++)
    if (!strcmp(key, keys[i]))
      return TRUE;
  return FALSE;
}
gboolean portal_restricted(Portal *p, const char *key) {
  gboolean restricted =
      g_key_file_get_boolean(p->policy, "Restrictions", key, NULL);
  if (p->managed_policy) {
    GSettingsSchemaSource *source = g_settings_schema_source_get_default();
    g_autoptr(GSettingsSchema) schema = g_settings_schema_source_lookup(
        source, "org.gnome.desktop.lockdown", TRUE);
    if (schema && g_settings_schema_has_key(schema, key))
      restricted |= g_settings_get_boolean(p->managed_policy, key);
  }
  return restricted;
}
GVariant *portal_settings_property(Portal *p, const char *name,
                                   GError **error) {
  if (known(name))
    return g_variant_new_boolean(portal_restricted(p, name));
  g_set_error_literal(error, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_PROPERTY,
                      "Unknown restriction");
  return NULL;
}
static void emit_policy(Portal *p) {
  GVariantBuilder changes;
  g_variant_builder_init(&changes, G_VARIANT_TYPE_VARDICT);
  for (guint i = 0; keys[i]; i++)
    g_variant_builder_add(&changes, "{sv}", keys[i],
                          g_variant_new_boolean(portal_restricted(p, keys[i])));
  g_dbus_connection_emit_signal(p->bus, NULL, PORTAL_PATH,
                                "org.freedesktop.DBus.Properties",
                                "PropertiesChanged",
                                g_variant_new("(s@a{sv}@as)", IMPL "Lockdown",
                                              g_variant_builder_end(&changes),
                                              g_variant_new_strv(NULL, 0)),
                                NULL);
}
static void read_policy(Portal *p, gboolean initial) {
  const char *path = PEARL_PORTAL_POLICY;
  GStatBuf st;
  GKeyFile *next = g_key_file_new();
  g_autoptr(GError) error = NULL;
  gboolean absent = g_stat(path, &st) != 0 && errno == ENOENT;
  gboolean valid =
      absent ||
      (g_stat(path, &st) == 0 && S_ISREG(st.st_mode) && st.st_uid == 0 &&
       !(st.st_mode & 0022) && st.st_size <= 65536 &&
       g_key_file_load_from_file(next, path, G_KEY_FILE_NONE, &error));
  if (valid && !absent) {
    gsize count;
    g_auto(GStrv) present =
        g_key_file_get_keys(next, "Restrictions", &count, &error);
    if (!present)
      valid = FALSE;
    for (gsize i = 0; present && i < count; i++) {
      if (!known(present[i])) {
        valid = FALSE;
        break;
      }
      g_key_file_get_boolean(next, "Restrictions", present[i], &error);
      if (error) {
        valid = FALSE;
        break;
      }
    }
  }
  if (!valid) {
    g_key_file_unref(next);
    if (!initial) {
      g_printerr(
          "Portal policy update rejected; retaining last valid restrictions\n");
      return;
    }
    next = g_key_file_new();
    for (guint i = 0; keys[i]; i++)
      g_key_file_set_boolean(next, "Restrictions", keys[i], TRUE);
    g_printerr("Portal policy invalid at startup; restricting operations until "
               "corrected\n");
  }
  g_clear_pointer(&p->policy, g_key_file_unref);
  p->policy = next;
  emit_policy(p);
}
static void policy_changed(GFileMonitor *monitor, GFile *file, GFile *other,
                           GFileMonitorEvent event, gpointer data) {
  (void)monitor;
  (void)file;
  (void)other;
  (void)event;
  read_policy(data, FALSE);
}
static void managed_changed(GSettings *settings, const char *key,
                            gpointer data) {
  (void)settings;
  (void)key;
  emit_policy(data);
}
void portal_settings_init(Portal *p) {
  active = p;
  p->settings = g_hash_table_new_full(g_str_hash, g_str_equal, g_free,
                                      (GDestroyNotify)g_variant_unref);
  portal_appearance(1, 208. / 255., 188. / 255., 1, FALSE, "Sans 14", "");
  read_policy(p, TRUE);
  g_autoptr(GFile) file = g_file_new_for_path(PEARL_PORTAL_POLICY);
  p->policy_monitor =
      g_file_monitor_file(file, G_FILE_MONITOR_WATCH_MOVES, NULL, NULL);
  if (p->policy_monitor)
    g_signal_connect(p->policy_monitor, "changed", G_CALLBACK(policy_changed),
                     p);
  GSettingsSchemaSource *source = g_settings_schema_source_get_default();
  g_autoptr(GSettingsSchema) schema =
      source ? g_settings_schema_source_lookup(
                   source, "org.gnome.desktop.lockdown", TRUE)
             : NULL;
  if (schema) {
    p->managed_policy = g_settings_new_full(schema, NULL, NULL);
    g_signal_connect(p->managed_policy, "changed", G_CALLBACK(managed_changed),
                     p);
  }
}
void portal_settings_stop(Portal *p) {
  active = NULL;
  if (style && gdk_display_get_default())
    gtk_style_context_remove_provider_for_display(gdk_display_get_default(),
                                                  GTK_STYLE_PROVIDER(style));
  g_clear_object(&style);
  g_clear_pointer(&pending_css, g_free);
  g_clear_object(&p->policy_monitor);
  g_clear_object(&p->managed_policy);
  g_clear_pointer(&p->policy, g_key_file_unref);
  g_clear_pointer(&p->settings, g_hash_table_unref);
}
static gboolean namespace_matches(GVariant *patterns, const char *space) {
  if (!g_variant_n_children(patterns))
    return TRUE;
  GVariantIter iter;
  const char *pattern;
  g_variant_iter_init(&iter, patterns);
  while (g_variant_iter_next(&iter, "&s", &pattern)) {
    if (!*pattern || !strcmp(pattern, space))
      return TRUE;
    gsize n = strlen(pattern);
    if (n >= 2 && pattern[n - 1] == '*' && pattern[n - 2] == '.' &&
        !strncmp(pattern, space, n - 1))
      return TRUE;
  }
  return FALSE;
}
void portal_settings_call(Portal *p, const char *method, GVariant *params,
                          GDBusMethodInvocation *call) {
  if (!strcmp(method, "Read")) {
    const char *space, *key;
    g_variant_get(params, "(&s&s)", &space, &key);
    g_autofree char *id = g_strconcat(space, "/", key, NULL);
    GVariant *v = g_hash_table_lookup(p->settings, id);
    if (v)
      g_dbus_method_invocation_return_value(call, g_variant_new("(v)", v));
    else
      portal_error(call, "NotFound", "Unknown setting");
    return;
  }
  g_autoptr(GVariant) patterns = g_variant_get_child_value(params, 0);
  GVariantBuilder result;
  g_variant_builder_init(&result, G_VARIANT_TYPE("a{sa{sv}}"));
  const char *spaces[] = {"org.freedesktop.appearance",
                          "org.gnome.desktop.interface", NULL};
  for (guint i = 0; spaces[i]; i++)
    if (namespace_matches(patterns, spaces[i])) {
      GVariantBuilder values;
      g_variant_builder_init(&values, G_VARIANT_TYPE_VARDICT);
      GHashTableIter iter;
      gpointer key, value;
      g_hash_table_iter_init(&iter, p->settings);
      while (g_hash_table_iter_next(&iter, &key, &value)) {
        const char *sep = strchr(key, '/');
        if (sep && (gsize)(sep - (char *)key) == strlen(spaces[i]) &&
            !strncmp(key, spaces[i], strlen(spaces[i])))
          g_variant_builder_add(&values, "{sv}", sep + 1, (GVariant *)value);
      }
      g_variant_builder_add(&result, "{s@a{sv}}", spaces[i],
                            g_variant_builder_end(&values));
    }
  g_dbus_method_invocation_return_value(
      call, g_variant_new("(@a{sa{sv}})", g_variant_builder_end(&result)));
}
