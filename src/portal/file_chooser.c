#include "portal.h"
#include <string.h>
static gboolean bytes_path(GVariant *value, char **path) {
  gsize n = 0;
  const char *bytes = g_variant_get_fixed_array(value, &n, 1);
  if (!n || n > 4096 || bytes[n - 1] || strlen(bytes) != n - 1 ||
      !g_path_is_absolute(bytes))
    return FALSE;
  *path = g_memdup2(bytes, n);
  return TRUE;
}
static GtkFileFilter *make_filter(GVariant *value) {
  const char *name;
  GVariant *rules;
  g_variant_get(value, "(&s@a(us))", &name, &rules);
  g_autoptr(GVariant) owned = rules;
  if (strlen(name) > 512 || g_variant_n_children(rules) > 128)
    return NULL;
  GtkFileFilter *filter = gtk_file_filter_new();
  gtk_file_filter_set_name(filter, name);
  GVariantIter iter;
  g_variant_iter_init(&iter, rules);
  guint type;
  const char *pattern;
  while (g_variant_iter_next(&iter, "(u&s)", &type, &pattern)) {
    if (strlen(pattern) > 1024 || type > 1) {
      g_object_unref(filter);
      return NULL;
    }
    if (type == 0)
      gtk_file_filter_add_pattern(filter, pattern);
    else
      gtk_file_filter_add_mime_type(filter, pattern);
  }
  g_object_set_data_full(G_OBJECT(filter), "portal-filter",
                         g_variant_ref(value), (GDestroyNotify)g_variant_unref);
  return filter;
}
static void response(GtkDialog *dialog, int code, gpointer data) {
  Request *r = data;
  if (code != GTK_RESPONSE_ACCEPT) {
    portal_complete(r, 1, NULL);
    return;
  }
  if ((strcmp(r->method, "OpenFile") &&
       portal_restricted(r->portal, "disable-save-to-disk"))) {
    portal_complete(r, 2, NULL);
    return;
  }
  g_autoptr(GListModel) files = pearl_file_chooser_get_files(dialog);
  if (!files) {
    portal_complete(r, 2, NULL);
    return;
  }
  GVariantBuilder uris, result;
  g_variant_builder_init(&uris, G_VARIANT_TYPE("as"));
  g_variant_builder_init(&result, G_VARIANT_TYPE_VARDICT);
  for (guint i = 0; i < g_list_model_get_n_items(files); i++) {
    g_autoptr(GFile) file = g_list_model_get_item(files, i);
    g_autofree char *path = g_file_get_path(file);
    if (!path) {
      g_variant_builder_clear(&uris);
      g_variant_builder_clear(&result);
      portal_complete(r, 2, NULL);
      return;
    }
    g_autoptr(GFile) local = g_file_new_for_path(path);
    g_autofree char *uri = g_file_get_uri(local);
    g_variant_builder_add(&uris, "s", uri);
  }
  g_variant_builder_add(&result, "{sv}", "uris", g_variant_builder_end(&uris));
  g_variant_builder_add(&result, "{sv}", "choices",
                        pearl_file_chooser_get_choices(dialog));
  GtkFileFilter *filter = pearl_file_chooser_get_filter(dialog);
  if (filter) {
    GVariant *original = g_object_get_data(G_OBJECT(filter), "portal-filter");
    if (original)
      g_variant_builder_add(&result, "{sv}", "current_filter", original);
  }
  portal_complete(r, 0, g_variant_builder_end(&result));
}
void portal_files(Request *r, GVariant *params) {
  gboolean open = !strcmp(r->method, "OpenFile"),
           batch = !strcmp(r->method, "SaveFiles");
  if (!open && portal_restricted(r->portal, "disable-save-to-disk")) {
    portal_complete(r, 2, NULL);
    return;
  }
  const char *title;
  g_variant_get_child(params, 3, "&s", &title);
  if (strlen(title) > 4096) {
    portal_complete(r, 2, NULL);
    return;
  }
  GtkFileChooserAction action =
      open    ? (portal_boolean(r->options, "directory", FALSE)
                     ? GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER
                     : GTK_FILE_CHOOSER_ACTION_OPEN)
      : batch ? GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER
              : GTK_FILE_CHOOSER_ACTION_SAVE;
  r->dialog = pearl_file_chooser_new(title, action);
  g_object_ref_sink(r->dialog);
  g_autofree char *state_key = g_strdup_printf("portal/%s/%s", r->app_id, r->method);
  pearl_file_chooser_set_state_key(r->dialog, state_key);
  pearl_file_chooser_set_multiple(
      r->dialog, open && portal_boolean(r->options, "multiple", FALSE));
  g_autofree char *name = portal_app_name(r->app_id);
  g_autofree char *caller = g_strdup_printf("Requested by %s", name);
  pearl_file_chooser_set_caller(r->dialog, caller);
  pearl_file_chooser_set_accept_label(
      r->dialog,
      portal_string(r->options, "accept_label", open ? "Open" : "Save"));
  pearl_file_chooser_set_name(
      r->dialog, portal_string(r->options, "current_name", "Untitled"));
  g_autoptr(GVariant) filters =
      portal_option(r->options, "filters", "a(sa(us))");
  g_autoptr(GVariant) current =
      portal_option(r->options, "current_filter", "(sa(us))");
  gboolean selected = FALSE;
  if (filters) {
    if (g_variant_n_children(filters) > 64) {
      portal_complete(r, 2, NULL);
      return;
    }
    for (guint i = 0; i < g_variant_n_children(filters); i++) {
      g_autoptr(GVariant) raw = g_variant_get_child_value(filters, i);
      g_autoptr(GtkFileFilter) f = make_filter(raw);
      if (!f) {
        portal_complete(r, 2, NULL);
        return;
      }
      pearl_file_chooser_add_filter(r->dialog, f);
      if (current && g_variant_equal(current, raw)) {
        pearl_file_chooser_set_filter(r->dialog, f);
        selected = TRUE;
      }
    }
  }
  if (current && !selected) {
    g_autoptr(GtkFileFilter) f = make_filter(current);
    if (!f) {
      portal_complete(r, 2, NULL);
      return;
    }
    pearl_file_chooser_add_filter(r->dialog, f);
    pearl_file_chooser_set_filter(r->dialog, f);
  }
  g_autoptr(GVariant) folder =
      portal_option(r->options, "current_folder", "ay");
  if (folder) {
    g_autofree char *path = NULL;
    if (!bytes_path(folder, &path)) {
      portal_complete(r, 2, NULL);
      return;
    }
    g_autoptr(GFile) file = g_file_new_for_path(path);
    pearl_file_chooser_set_folder(r->dialog, file);
  }
  g_autoptr(GVariant) current_file =
      portal_option(r->options, "current_file", "ay");
  if (current_file) {
    g_autofree char *path = NULL;
    if (!bytes_path(current_file, &path)) {
      portal_complete(r, 2, NULL);
      return;
    }
    g_autoptr(GFile) file = g_file_new_for_path(path);
    pearl_file_chooser_set_file(r->dialog, file);
  }
  g_autoptr(GVariant) choices =
      portal_option(r->options, "choices", "a(ssa(ss)s)");
  if (choices && !pearl_file_chooser_set_choices(r->dialog, choices, NULL)) {
    portal_complete(r, 2, NULL);
    return;
  }
  if (batch) {
    g_autoptr(GVariant) names = portal_option(r->options, "files", "aay");
    if (!names || !pearl_file_chooser_set_batch(r->dialog, names, NULL)) {
      portal_complete(r, 2, NULL);
      return;
    }
  }
  g_signal_connect(r->dialog, "response", G_CALLBACK(response), r);
  portal_present(r);
}
