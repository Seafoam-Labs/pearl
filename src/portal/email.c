#include "portal.h"
#include <string.h>
typedef struct {
  Request *request;
  GAppInfo *app;
  GPtrArray *apps;
  GtkWidget *select;
  GSubprocess *process;
  char *uri;
} Mail;
static void mail_cancelled(GCancellable *cancel, gpointer data) {
  (void)cancel;
  Mail *m = data;
  if (m->process)
    g_subprocess_force_exit(m->process);
}
static void mail_free(gpointer data) {
  Mail *m = data;
  if (m->process)
    g_subprocess_force_exit(m->process);
  g_clear_object(&m->process);
  g_clear_object(&m->app);
  g_clear_pointer(&m->apps, g_ptr_array_unref);
  g_free(m->uri);
  g_free(m);
}
static void field(GString *uri, const char *name, const char *value) {
  g_autofree char *escaped = g_uri_escape_string(value, NULL, FALSE);
  g_string_append_printf(uri, "%s%s=%s", strchr(uri->str, '?') ? "&" : "?",
                         name, escaped);
}
static gboolean array_fields(GString *uri, GVariant *options, const char *key) {
  g_autoptr(GVariant) values = portal_option(options, key, "as");
  if (!values)
    return TRUE;
  if (g_variant_n_children(values) > 128)
    return FALSE;
  GString *combined = g_string_new(NULL);
  GVariantIter iter;
  const char *value;
  g_variant_iter_init(&iter, values);
  while (g_variant_iter_next(&iter, "&s", &value)) {
    if (strlen(value) > 4096 || strchr(value, '\n') || strchr(value, '\r')) {
      g_string_free(combined, TRUE);
      return FALSE;
    }
    if (combined->len)
      g_string_append_c(combined, ',');
    g_string_append(combined, value);
  }
  if (combined->len)
    field(uri, !strcmp(key, "addresses") ? "to" : key, combined->str);
  g_string_free(combined, TRUE);
  return TRUE;
}
static void launch_done(GObject *source, GAsyncResult *result, gpointer data) {
  Request *r = data;
  gboolean ok = g_app_info_launch_uris_finish(G_APP_INFO(source), result, NULL);
  if (!r->finished)
    portal_complete(r, ok ? 0 : 2, NULL);
  portal_request_unref(r);
}
static void helper_done(GObject *source, GAsyncResult *result, gpointer data) {
  Request *r = data;
  gboolean ok =
      g_subprocess_wait_check_finish(G_SUBPROCESS(source), result, NULL);
  if (!r->finished) {
    Mail *m = r->data;
    g_clear_object(&m->process);
    portal_complete(r, ok ? 0 : 2, NULL);
  }
  portal_request_unref(r);
}
static void compose(Request *r) {
  Mail *m = r->data;
  if (portal_restricted(r->portal, "disable-application-handlers")) {
    portal_complete(r, 2, NULL);
    return;
  }
  g_autoptr(GVariant) attachments =
      portal_option(r->options, "attachments", "as");
  const char *executable = g_app_info_get_executable(m->app);
  g_autofree char *base = executable ? g_path_get_basename(executable) : NULL;
  gboolean thunderbird =
      base && (!strcmp(base, "thunderbird") || !strcmp(base, "icedove"));
  gboolean attachment_uri =
      base && (!strcmp(base, "evolution") || !strcmp(base, "kmail") ||
               !strcmp(base, "kmail2"));
  if (attachments && g_variant_n_children(attachments)) {
    if (g_variant_n_children(attachments) > 128 ||
        (!thunderbird && !attachment_uri)) {
      portal_complete(r, 2, NULL);
      return;
    }
    if (thunderbird) {
      // xdg-email has a dedicated Thunderbird compose adapter. It selects
      // the configured default; never change associations for this request.
      g_autoptr(GAppInfo) def = g_app_info_get_default_for_uri_scheme("mailto");
      if (!def || !g_app_info_equal(def, m->app)) {
        portal_complete(r, 2, NULL);
        return;
      }
      GPtrArray *argv = g_ptr_array_new_with_free_func(g_free);
      g_ptr_array_add(argv, g_strdup("/usr/bin/xdg-email"));
      g_ptr_array_add(argv, g_strdup("--utf8"));
      GVariantIter iter;
      const char *uri;
      g_variant_iter_init(&iter, attachments);
      while (g_variant_iter_next(&iter, "&s", &uri)) {
        g_autoptr(GFile) file = g_file_new_for_uri(uri);
        char *path = g_file_get_path(file);
        if (!path || strchr(path, '\n') || strchr(path, '\r') ||
            strchr(path, '\'') || strchr(path, ',')) {
          g_free(path);
          g_ptr_array_unref(argv);
          portal_complete(r, 2, NULL);
          return;
        }
        g_ptr_array_add(argv, g_strdup("--attach"));
        g_ptr_array_add(argv, path);
      }
      g_ptr_array_add(argv, g_strdup(m->uri));
      g_ptr_array_add(argv, NULL);
      g_autoptr(GSubprocessLauncher) launcher =
          g_subprocess_launcher_new(G_SUBPROCESS_FLAGS_STDOUT_SILENCE |
                                    G_SUBPROCESS_FLAGS_STDERR_SILENCE);
      g_subprocess_launcher_unsetenv(launcher, "MAILER");
      g_subprocess_launcher_setenv(launcher, "XDG_CURRENT_DESKTOP", "Aqueous",
                                   TRUE);
      const char *token = portal_string(r->options, "activation_token", "");
      if (*token)
        g_subprocess_launcher_setenv(launcher, "XDG_ACTIVATION_TOKEN", token,
                                     TRUE);
      m->process = g_subprocess_launcher_spawnv(
          launcher, (const char *const *)argv->pdata, NULL);
      g_ptr_array_unref(argv);
      if (!m->process) {
        portal_complete(r, 2, NULL);
        return;
      }
      g_subprocess_wait_check_async(m->process, r->cancel, helper_done,
                                    portal_request_ref(r));
      return;
    }
    GString *uri = g_string_new(m->uri);
    GVariantIter iter;
    const char *attachment;
    g_variant_iter_init(&iter, attachments);
    while (g_variant_iter_next(&iter, "&s", &attachment)) {
      g_autoptr(GFile) file = g_file_new_for_uri(attachment);
      g_autofree char *path = g_file_get_path(file);
      if (!path) {
        g_string_free(uri, TRUE);
        portal_complete(r, 2, NULL);
        return;
      }
      field(uri, "attach", path);
    }
    g_free(m->uri);
    m->uri = g_string_free(uri, FALSE);
  }
  g_autoptr(GAppLaunchContext) context = g_app_launch_context_new();
  const char *token = portal_string(r->options, "activation_token", "");
  if (*token)
    g_app_launch_context_setenv(context, "XDG_ACTIVATION_TOKEN", token);
  GList item = {.data = m->uri};
  g_app_info_launch_uris_async(m->app, &item, context, r->cancel, launch_done,
                               portal_request_ref(r));
}
static void selected(GtkDialog *dialog, int response, gpointer data) {
  (void)dialog;
  Request *r = data;
  Mail *m = r->data;
  if (response != GTK_RESPONSE_ACCEPT) {
    portal_complete(r, 1, NULL);
    return;
  }
  guint index = gtk_drop_down_get_selected(GTK_DROP_DOWN(m->select));
  if (index >= m->apps->len) {
    portal_complete(r, 2, NULL);
    return;
  }
  g_set_object(&m->app, g_ptr_array_index(m->apps, index));
  gtk_widget_set_sensitive(GTK_WIDGET(r->dialog), FALSE);
  compose(r);
}
void portal_email(Request *r) {
  Mail *m = g_new0(Mail, 1);
  m->request = r;
  r->data = m;
  r->destroy_data = mail_free;
  g_signal_connect(r->cancel, "cancelled", G_CALLBACK(mail_cancelled), m);
  GString *uri = g_string_new("mailto:");
  const char *address = portal_string(r->options, "address", "");
  if (strchr(address, '\r') || strchr(address, '\n')) {
    g_string_free(uri, TRUE);
    portal_complete(r, 2, NULL);
    return;
  }
  if (*address)
    field(uri, "to", address);
  if (!array_fields(uri, r->options, "addresses") ||
      !array_fields(uri, r->options, "cc") ||
      !array_fields(uri, r->options, "bcc")) {
    g_string_free(uri, TRUE);
    portal_complete(r, 2, NULL);
    return;
  }
  for (guint i = 0; i < 2; i++) {
    const char *key = i ? "body" : "subject";
    const char *value = portal_string(r->options, key, "");
    if (*value)
      field(uri, key, value);
  }
  m->uri = g_string_free(uri, FALSE);
  m->app = g_app_info_get_default_for_uri_scheme("mailto");
  if (m->app) {
    compose(r);
    return;
  }
  portal_dialog(r, "Choose an email application", "Cancel", "Open composer");
  GtkBox *body = GTK_BOX(gtk_dialog_get_content_area(r->dialog));
  gtk_box_append(body, portal_label("Review and send your message in the "
                                    "selected application's composer."));
  m->apps = g_ptr_array_new_with_free_func(g_object_unref);
  GtkStringList *names = gtk_string_list_new(NULL);
  GList *apps = g_app_info_get_all_for_type("x-scheme-handler/mailto");
  for (GList *l = apps; l; l = l->next)
    if (g_app_info_should_show(l->data)) {
      g_ptr_array_add(m->apps, g_object_ref(l->data));
      gtk_string_list_append(names, g_app_info_get_display_name(l->data));
    }
  g_list_free_full(apps, g_object_unref);
  m->select = gtk_drop_down_new(G_LIST_MODEL(names), NULL);
  gtk_box_append(body, m->select);
  if (!m->apps->len) {
    gtk_box_append(body,
                   portal_label("No email application is installed. Install a "
                                "mail application and try again."));
    gtk_dialog_set_response_sensitive(r->dialog, GTK_RESPONSE_ACCEPT, FALSE);
  }
  g_signal_connect(r->dialog, "response", G_CALLBACK(selected), r);
  portal_present(r);
}
