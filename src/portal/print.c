#include "portal.h"
#include <gio/gunixfdlist.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
typedef struct {
  char *sender, *app, *printer, *uri, *etag;
  gint64 expires;
  GVariant *settings, *page;
} PrintToken;
typedef struct {
  GtkWidget *printers, *copies, *duplex, *color, *ranges, *orientation, *paper,
      *status;
  GPtrArray *ids, *page_modes;
  GtkWidget *page_mode;
  char *output_format;
  GVariant *initial, *page, *capabilities;
  GSubprocess *worker;
  guint timeout;
  int fd;
  PrintToken *token;
} PrintData;
/* Portal page ranges are zero based; UI and CUPS ranges are one based. */
static char *shift_ranges(const char *text, int shift) {
  GString *out = g_string_new(NULL);
  const char *p = text;
  while (*p) {
    char *end;
    guint64 start = g_ascii_strtoull(p, &end, 10);
    if (end == p || start > 1000000 || (shift < 0 && start == 0))
      goto invalid;
    g_string_append_printf(out, "%u", (guint)((gint64)start + shift));
    p = end;
    if (*p == '-') {
      p++;
      guint64 last = g_ascii_strtoull(p, &end, 10);
      if (end == p || last < start || last > 1000000)
        goto invalid;
      g_string_append_printf(out, "-%u", (guint)((gint64)last + shift));
      p = end;
    }
    if (!*p)
      break;
    if (*p != ',' || !p[1])
      goto invalid;
    g_string_append_c(out, ',');
    p++;
  }
  return g_string_free(out, FALSE);
invalid:
  g_string_free(out, TRUE);
  return NULL;
}
static void token_free(gpointer data) {
  PrintToken *t = data;
  g_free(t->sender);
  g_free(t->app);
  g_free(t->printer);
  g_free(t->uri);
  g_free(t->etag);
  g_clear_pointer(&t->settings, g_variant_unref);
  g_clear_pointer(&t->page, g_variant_unref);
  g_free(t);
}
void portal_print_clear(Portal *p) {
  if (p->print_tokens)
    g_hash_table_remove_all(p->print_tokens);
}
void portal_print_init(Portal *p) {
  p->print_tokens =
      g_hash_table_new_full(g_direct_hash, g_direct_equal, NULL, token_free);
}
void portal_print_stop(Portal *p) { g_hash_table_unref(p->print_tokens); }
static void data_free(gpointer data) {
  PrintData *d = data;
  if (d->timeout)
    g_source_remove(d->timeout);
  if (d->worker) {
    g_subprocess_force_exit(d->worker);
    g_object_unref(d->worker);
  }
  if (d->fd >= 0)
    close(d->fd);
  g_clear_pointer(&d->ids, g_ptr_array_unref);
  g_clear_pointer(&d->page_modes, g_ptr_array_unref);
  g_free(d->output_format);
  g_clear_pointer(&d->initial, g_variant_unref);
  g_clear_pointer(&d->page, g_variant_unref);
  g_clear_pointer(&d->capabilities, g_variant_unref);
  if (d->token)
    token_free(d->token);
  g_free(d);
}
static gboolean expired(gpointer data) {
  Request *r = data;
  PrintData *d = r->data;
  d->timeout = 0;
  if (d->worker)
    g_subprocess_force_exit(d->worker);
  portal_complete(r, 2, NULL);
  return G_SOURCE_REMOVE;
}
static void stopped(GCancellable *cancel, gpointer data) {
  (void)cancel;
  PrintData *d = data;
  if (d->worker)
    g_subprocess_force_exit(d->worker);
}
static GSubprocess *worker(Request *r, const char *const *args,
                           gboolean pass_fd) {
  PrintData *d = r->data;
  g_autoptr(GSubprocessLauncher) launcher = g_subprocess_launcher_new(
      G_SUBPROCESS_FLAGS_STDOUT_PIPE | G_SUBPROCESS_FLAGS_STDERR_SILENCE);
  if (pass_fd) {
    int fd = dup(d->fd);
    if (fd < 0)
      return NULL;
    g_subprocess_launcher_take_fd(launcher, fd, 3);
  }
  if (d->timeout) {
    g_source_remove(d->timeout);
    d->timeout = 0;
  }
  if (d->worker)
    g_subprocess_force_exit(d->worker);
  g_clear_object(&d->worker);
  d->worker = g_subprocess_launcher_spawnv(launcher, args, NULL);
  if (d->worker)
    d->timeout = g_timeout_add_seconds(65, expired, r);
  return d->worker;
}
static void printed(GObject *source, GAsyncResult *result, gpointer data) {
  Request *r = data;
  gboolean ok =
      g_subprocess_wait_check_finish(G_SUBPROCESS(source), result, NULL);
  if (!r->finished)
    portal_complete(r, ok ? 0 : 2, NULL);
  portal_request_unref(r);
}
static void submit(Request *r) {
  PrintData *d = r->data;
  PrintToken *t = d->token;
  if (portal_restricted(r->portal, "disable-printing") ||
      (t->uri && portal_restricted(r->portal, "disable-save-to-disk"))) {
    portal_complete(r, 2, NULL);
    return;
  }
  GVariantBuilder b;
  g_variant_builder_init(&b, G_VARIANT_TYPE("a{ss}"));
  const char *keys[] = {"n-copies",    "duplex",      "use-color",
                        "page-ranges", "orientation", "paper-format"};
  const char *cups[] = {"copies",
                        "sides",
                        "print-color-mode",
                        "page-ranges",
                        "orientation-requested",
                        "media"};
  for (guint i = 0; i < G_N_ELEMENTS(keys); i++) {
    const char *v = portal_string(t->settings, keys[i], "");
    if (!*v)
      continue;
    if (i == 1)
      v = !strcmp(v, "simplex")      ? "one-sided"
          : !strcmp(v, "horizontal") ? "two-sided-short-edge"
                                     : "two-sided-long-edge";
    if (i == 2)
      v = !strcmp(v, "true") ? "color" : "monochrome";
    if (i == 4)
      v = !strcmp(v, "landscape") ? "4" : "3";
    if (i == 3) {
      g_autofree char *ranges = shift_ranges(v, 1);
      if (!ranges) {
        g_variant_builder_clear(&b);
        portal_complete(r, 2, NULL);
        return;
      }
      g_variant_builder_add(&b, "{ss}", cups[i], ranges);
    } else
      g_variant_builder_add(&b, "{ss}", cups[i], v);
  }
  g_autoptr(GVariant) values = g_variant_ref_sink(g_variant_builder_end(&b));
  g_autofree char *options = g_variant_print(values, TRUE);
  const char *args_file[] = {
      "/proc/self/exe",
      "--print-worker",
      "file",
      t->uri,
      t->etag,
      portal_string(t->settings, "output-file-format", "pdf"),
      NULL};
  const char *args_cups[] = {"/proc/self/exe",
                             "--print-worker",
                             "submit",
                             t->printer,
                             portal_string(t->settings, "job-name", "Document"),
                             options,
                             "1",
                             NULL};
  if (!worker(r, t->uri ? args_file : args_cups, TRUE)) {
    portal_complete(r, 2, NULL);
    return;
  }
  if (r->dialog)
    gtk_widget_set_sensitive(GTK_WIDGET(r->dialog), FALSE);
  g_subprocess_wait_check_async(d->worker, r->cancel, printed,
                                portal_request_ref(r));
}
static void ready(Request *r) {
  PrintData *d = r->data;
  PrintToken *t = d->token;
  if (!strcmp(r->method, "Print")) {
    submit(r);
    return;
  }
  if (g_hash_table_size(r->portal->print_tokens) >= 128) {
    portal_complete(r, 2, NULL);
    return;
  }
  guint token;
  do {
    token = g_random_int();
  } while (!token || g_hash_table_contains(r->portal->print_tokens,
                                           GUINT_TO_POINTER(token)));
  t->expires = g_get_monotonic_time() + 5 * 60 * G_USEC_PER_SEC;
  g_hash_table_insert(r->portal->print_tokens, GUINT_TO_POINTER(token), t);
  d->token = NULL;
  GVariantBuilder result;
  g_variant_builder_init(&result, G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(&result, "{sv}", "token", g_variant_new_uint32(token));
  g_variant_builder_add(&result, "{sv}", "settings", t->settings);
  g_variant_builder_add(&result, "{sv}", "page-setup", t->page);
  portal_complete(r, 0, g_variant_builder_end(&result));
}
static void destination_chosen(GtkDialog *dialog, int response, gpointer data) {
  Request *r = data;
  PrintData *d = r->data;
  if (response != GTK_RESPONSE_ACCEPT) {
    portal_complete(r, 1, NULL);
    return;
  }
  g_autoptr(GFile) file = pearl_file_chooser_get_file(dialog);
  if (!file) {
    portal_complete(r, 2, NULL);
    return;
  }
  d->token->uri = g_file_get_uri(file);
  GVariantDict settings;
  g_variant_dict_init(&settings, d->token->settings);
  g_variant_dict_insert(&settings, "output-uri", "s", d->token->uri);
  g_variant_dict_insert(&settings, "output-file-format", "s", d->output_format);
  g_variant_dict_insert(&settings, "printer", "s", "Print to File");
  g_variant_unref(d->token->settings);
  d->token->settings = g_variant_ref_sink(g_variant_dict_end(&settings));
  g_autoptr(GError) error = NULL;
  g_autoptr(GFileInfo) info = g_file_query_info(
      file, "etag::value", G_FILE_QUERY_INFO_NONE, NULL, &error);
  const char *etag = info ? g_file_info_get_etag(info) : NULL;
  if (!etag && !g_error_matches(error, G_IO_ERROR, G_IO_ERROR_NOT_FOUND)) {
    portal_complete(r, 2, NULL);
    return;
  }
  d->token->etag = etag ? g_strconcat("etag:", etag, NULL) : g_strdup("new");
  ready(r);
}
static void response(GtkDialog *dialog, int response_id, gpointer data) {
  Request *r = data;
  PrintData *d = r->data;
  (void)dialog;
  if (response_id != GTK_RESPONSE_ACCEPT) {
    portal_complete(r, 1, NULL);
    return;
  }
  guint index = gtk_drop_down_get_selected(GTK_DROP_DOWN(d->printers));
  if (index >= d->ids->len)
    return;
  const char *mode = g_ptr_array_index(
      d->page_modes, gtk_drop_down_get_selected(GTK_DROP_DOWN(d->page_mode)));
  const char *range = !strcmp(mode, "ranges")
                          ? gtk_editable_get_text(GTK_EDITABLE(d->ranges))
                          : "";
  g_autofree char *zero_ranges = shift_ranges(range, -1);
  if (!zero_ranges) {
    gtk_label_set_text(GTK_LABEL(d->status),
                       "Use ascending page ranges, such as 1-3,5.");
    return;
  }
  PrintToken *t = g_new0(PrintToken, 1);
  d->token = t;
  t->sender = g_strdup(r->sender);
  t->app = g_strdup(r->app_id);
  t->printer = g_strdup(g_ptr_array_index(d->ids, index));
  GVariantDict settings;
  g_variant_dict_init(&settings, d->initial);
  char copies[16];
  g_snprintf(copies, sizeof copies, "%d",
             gtk_spin_button_get_value_as_int(GTK_SPIN_BUTTON(d->copies)));
  const char *duplex[] = {"simplex", "vertical", "horizontal"};
  const char *papers[] = {"iso_a4", "na_letter", "na_legal"};
  guint selected_paper = gtk_drop_down_get_selected(GTK_DROP_DOWN(d->paper));
  const char *paper_name =
      selected_paper < 3 ? papers[selected_paper] : papers[0];
  double width = 210, height = 297, margin_top = 12.7, margin_bottom = 12.7,
         margin_left = 12.7, margin_right = 12.7;
  g_autoptr(GVariant) media =
      d->capabilities ? portal_option(d->capabilities, "papers", "a(sdddddd)")
                      : NULL;
  if (media && selected_paper < g_variant_n_children(media))
    g_variant_get_child(media, selected_paper, "(&sdddddd)", &paper_name,
                        &width, &height, &margin_top, &margin_bottom,
                        &margin_left, &margin_right);
  else {
    const double widths[] = {210, 215.9, 215.9},
                 heights[] = {297, 279.4, 355.6};
    if (selected_paper < 3) {
      width = widths[selected_paper];
      height = heights[selected_paper];
    }
  }

  g_variant_dict_insert(&settings, "n-copies", "s", copies);
  g_variant_dict_insert(
      &settings, "duplex", "s",
      duplex[gtk_drop_down_get_selected(GTK_DROP_DOWN(d->duplex))]);
  g_variant_dict_insert(&settings, "use-color", "s",
                        gtk_check_button_get_active(GTK_CHECK_BUTTON(d->color))
                            ? "true"
                            : "false");
  g_variant_dict_insert(&settings, "page-ranges", "s", zero_ranges);
  g_variant_dict_insert(&settings, "print-pages", "s", mode);
  g_variant_dict_insert(
      &settings, "orientation", "s",
      gtk_drop_down_get_selected(GTK_DROP_DOWN(d->orientation)) ? "landscape"
                                                                : "portrait");
  g_variant_dict_insert(&settings, "paper-format", "s", paper_name);
  g_variant_dict_insert(&settings, "printer", "s", t->printer);
  t->settings = g_variant_ref_sink(g_variant_dict_end(&settings));
  GVariantDict page;
  g_variant_dict_init(&page, d->page);
  g_variant_dict_insert(&page, "Name", "s", paper_name);
  g_variant_dict_insert(&page, "DisplayName", "s", paper_name);
  g_variant_dict_insert(&page, "Width", "d", width);
  g_variant_dict_insert(&page, "Height", "d", height);
  g_variant_dict_insert(
      &page, "Orientation", "s",
      gtk_drop_down_get_selected(GTK_DROP_DOWN(d->orientation)) ? "landscape"
                                                                : "portrait");
  g_variant_dict_insert(&page, "MarginTop", "d", margin_top);
  g_variant_dict_insert(&page, "MarginBottom", "d", margin_bottom);
  g_variant_dict_insert(&page, "MarginLeft", "d", margin_left);
  g_variant_dict_insert(&page, "MarginRight", "d", margin_right);
  t->page = g_variant_ref_sink(g_variant_dict_end(&page));
  if (!*t->printer) {
    if (portal_restricted(r->portal, "disable-save-to-disk")) {
      portal_complete(r, 2, NULL);
      return;
    }
    g_signal_handlers_disconnect_by_data(r->dialog, r);
    gtk_window_destroy(GTK_WINDOW(r->dialog));
    g_clear_object(&r->dialog);
    r->dialog = pearl_file_chooser_new("Save printed document",
                                       GTK_FILE_CHOOSER_ACTION_SAVE);
    g_object_ref_sink(r->dialog);
    pearl_file_chooser_set_local_only(r->dialog, TRUE);
    g_autofree char *output_name =
        g_strdup_printf("Document.%s", d->output_format);
    pearl_file_chooser_set_name(r->dialog, output_name);
    g_signal_connect(r->dialog, "response", G_CALLBACK(destination_chosen), r);
    portal_present(r);
  } else
    ready(r);
}
static gboolean supports(GVariant *caps, const char *key, const char *wanted) {
  g_autoptr(GVariant) values = portal_option(caps, key, "as");
  if (!values)
    return FALSE;
  GVariantIter it;
  const char *value;
  g_variant_iter_init(&it, values);
  while (g_variant_iter_next(&it, "&s", &value))
    if (!strcmp(value, wanted))
      return TRUE;
  return FALSE;
}
static void capability_reply(GObject *source, GAsyncResult *result,
                             gpointer data) {
  Request *r = data;
  PrintData *d = r->data;
  g_autofree char *output = NULL;
  gboolean ok = g_subprocess_communicate_utf8_finish(
      G_SUBPROCESS(source), result, &output, NULL, NULL);
  if (!r->finished && G_SUBPROCESS(source) == d->worker) {
    if (d->timeout) {
      g_source_remove(d->timeout);
      d->timeout = 0;
    }
    g_clear_pointer(&d->capabilities, g_variant_unref);
    d->capabilities =
        ok && output && strlen(output) < 262144
            ? g_variant_parse(G_VARIANT_TYPE_VARDICT, output, NULL, NULL, NULL)
            : NULL;
    g_autoptr(GVariant) media =
        d->capabilities ? portal_option(d->capabilities, "papers", "a(sdddddd)")
                        : NULL;
    if (!media || !g_variant_n_children(media))
      gtk_label_set_text(
          GTK_LABEL(d->status),
          "Printer capabilities are unavailable. Choose another destination.");
    else {
      GtkStringList *labels = gtk_string_list_new(NULL);
      for (guint i = 0; i < g_variant_n_children(media); i++) {
        const char *name;
        g_variant_get_child(media, i, "(&sdddddd)", &name, NULL, NULL, NULL,
                            NULL, NULL, NULL);
        gtk_string_list_append(labels, name);
      }
      gtk_drop_down_set_model(GTK_DROP_DOWN(d->paper), G_LIST_MODEL(labels));
      g_object_unref(labels);
      gtk_drop_down_set_selected(GTK_DROP_DOWN(d->paper), 0);
      guint copies = 1;
      g_variant_lookup(d->capabilities, "copies", "u", &copies);
      gtk_spin_button_set_range(GTK_SPIN_BUTTON(d->copies), 1, MAX(1, copies));
      gboolean color = supports(d->capabilities, "print-color-mode", "color");
      gtk_check_button_set_active(GTK_CHECK_BUTTON(d->color), color);
      gtk_widget_set_sensitive(d->color, color);
      gboolean duplex =
          supports(d->capabilities, "sides", "two-sided-long-edge") &&
          supports(d->capabilities, "sides", "two-sided-short-edge");
      gtk_widget_set_sensitive(d->duplex, duplex);
      if (!duplex)
        gtk_drop_down_set_selected(GTK_DROP_DOWN(d->duplex), 0);
      gtk_label_set_text(GTK_LABEL(d->status), "");
      gtk_dialog_set_response_sensitive(r->dialog, GTK_RESPONSE_ACCEPT, TRUE);
    }
  }
  portal_request_unref(r);
}
static void printer_changed(GObject *object, GParamSpec *property,
                            gpointer data) {
  (void)object;
  (void)property;
  Request *r = data;
  PrintData *d = r->data;
  guint selected = gtk_drop_down_get_selected(GTK_DROP_DOWN(d->printers));
  if (selected >= d->ids->len)
    return;
  const char *id = g_ptr_array_index(d->ids, selected);
  g_clear_pointer(&d->capabilities, g_variant_unref);
  if (d->timeout) {
    g_source_remove(d->timeout);
    d->timeout = 0;
  }
  if (d->worker) {
    g_subprocess_force_exit(d->worker);
    g_clear_object(&d->worker);
  }
  if (!*id) {
    const char *papers[] = {"A4", "Letter", "Legal", NULL};
    GtkStringList *model = gtk_string_list_new(papers);
    gtk_drop_down_set_model(GTK_DROP_DOWN(d->paper), G_LIST_MODEL(model));
    g_object_unref(model);
    gtk_drop_down_set_selected(GTK_DROP_DOWN(d->paper), 0);
    gtk_spin_button_set_range(GTK_SPIN_BUTTON(d->copies), 1, 999);
    gtk_widget_set_sensitive(d->color, TRUE);
    gtk_widget_set_sensitive(d->duplex, TRUE);
    gtk_label_set_text(GTK_LABEL(d->status), "");
    gtk_dialog_set_response_sensitive(r->dialog, GTK_RESPONSE_ACCEPT, TRUE);
    return;
  }
  gtk_dialog_set_response_sensitive(r->dialog, GTK_RESPONSE_ACCEPT, FALSE);
  gtk_label_set_text(GTK_LABEL(d->status), "Reading printer capabilities…");
  const char *args[] = {"/proc/self/exe", "--print-worker", "capabilities", id,
                        NULL};
  if (!worker(r, args, FALSE)) {
    portal_complete(r, 2, NULL);
    return;
  }
  g_subprocess_communicate_utf8_async(d->worker, NULL, r->cancel,
                                      capability_reply, portal_request_ref(r));
}
static void enumerated(GObject *source, GAsyncResult *result, gpointer data) {
  Request *r = data;
  PrintData *d = r->data;
  g_autofree char *output = NULL;
  gboolean ok = g_subprocess_communicate_utf8_finish(
      G_SUBPROCESS(source), result, &output, NULL, NULL);
  if (!r->finished) {
    if (d->timeout) {
      g_source_remove(d->timeout);
      d->timeout = 0;
    }
    GtkStringList *labels = gtk_string_list_new(NULL);
    if (d->output_format &&
        !portal_restricted(r->portal, "disable-save-to-disk")) {
      gtk_string_list_append(labels, "Print to file…");
      g_ptr_array_add(d->ids, g_strdup(""));
    }
    g_autoptr(GVariant) printers =
        ok && output && strlen(output) < 65536
            ? g_variant_parse(G_VARIANT_TYPE("a(ss)"), output, NULL, NULL, NULL)
            : NULL;
    if (printers) {
      GVariantIter it;
      const char *id, *name;
      g_variant_iter_init(&it, printers);
      while (d->ids->len < 128 &&
             g_variant_iter_next(&it, "(&s&s)", &id, &name)) {
        g_ptr_array_add(d->ids, g_strdup(id));
        gtk_string_list_append(labels, name);
      }
    }
    gtk_drop_down_set_model(GTK_DROP_DOWN(d->printers), G_LIST_MODEL(labels));
    g_object_unref(labels);
    gtk_drop_down_set_selected(GTK_DROP_DOWN(d->printers), 0);
    gtk_label_set_text(GTK_LABEL(d->status),
                       d->ids->len > 1 ? ""
                                       : "No printers found. Check the printer "
                                         "connection and CUPS service.");
    gtk_dialog_set_response_sensitive(r->dialog, GTK_RESPONSE_ACCEPT,
                                      d->ids->len > 0);
    g_signal_connect(d->printers, "notify::selected",
                     G_CALLBACK(printer_changed), r);
    printer_changed(NULL, NULL, r);
  }
  portal_request_unref(r);
}
static void page_mode_changed(GObject *object, GParamSpec *property,
                              gpointer data) {
  (void)object;
  (void)property;
  PrintData *d = data;
  guint index = gtk_drop_down_get_selected(GTK_DROP_DOWN(d->page_mode));
  gtk_widget_set_sensitive(
      d->ranges,
      index < d->page_modes->len &&
          !strcmp(g_ptr_array_index(d->page_modes, index), "ranges"));
}
static void field(GtkBox *body, const char *name, GtkWidget *widget) {
  gtk_box_append(body, portal_label(name));
  gtk_box_append(body, widget);
}
void portal_print(Request *r, GVariant *params) {
  if (portal_restricted(r->portal, "disable-printing")) {
    portal_complete(r, 2, NULL);
    return;
  }
  PrintData *d = g_new0(PrintData, 1);
  d->fd = -1;
  r->data = d;
  r->destroy_data = data_free;
  g_signal_connect(r->cancel, "cancelled", G_CALLBACK(stopped), d);
  d->ids = g_ptr_array_new_with_free_func(g_free);
  d->page_modes = g_ptr_array_new_with_free_func(g_free);
  d->output_format = g_strdup("pdf");
  g_autoptr(GVariant) formats =
      portal_option(r->options, "supported_output_file_formats", "as");
  if (formats) {
    g_clear_pointer(&d->output_format, g_free);
    GVariantIter it;
    const char *format;
    g_variant_iter_init(&it, formats);
    while (g_variant_iter_next(&it, "&s", &format)) {
      if (!strcmp(format, "pdf")) {
        g_free(d->output_format);
        d->output_format = g_strdup(format);
        break;
      }
      if ((!strcmp(format, "ps") || !strcmp(format, "svg")) &&
          !d->output_format)
        d->output_format = g_strdup(format);
    }
  }

  GHashTableIter it;
  gpointer value;
  g_hash_table_iter_init(&it, r->portal->print_tokens);
  while (g_hash_table_iter_next(&it, NULL, &value))
    if (((PrintToken *)value)->expires < g_get_monotonic_time())
      g_hash_table_iter_remove(&it);
  if (!strcmp(r->method, "Print")) {
    gint handle;
    g_variant_get_child(params, 4, "h", &handle);
    GUnixFDList *fds = g_dbus_message_get_unix_fd_list(
        g_dbus_method_invocation_get_message(r->invocation));
    if (fds)
      d->fd = g_unix_fd_list_get(fds, handle, NULL);
    struct stat st;
    if (d->fd < 0 || fstat(d->fd, &st) || !S_ISREG(st.st_mode) ||
        st.st_size > 256 * 1024 * 1024) {
      portal_complete(r, 2, NULL);
      return;
    }
    guint token = 0;
    g_variant_lookup(r->options, "token", "u", &token);
    if (token) {
      PrintToken *t =
          g_hash_table_lookup(r->portal->print_tokens, GUINT_TO_POINTER(token));
      if (!t || strcmp(t->app, r->app_id) || strcmp(t->sender, r->sender)) {
        portal_complete(r, 2, NULL);
        return;
      }
      g_hash_table_steal(r->portal->print_tokens, GUINT_TO_POINTER(token));
      d->token = t;
      submit(r);
      return;
    }
    d->initial = g_variant_ref_sink(portal_empty());
    d->page = g_variant_ref_sink(portal_empty());
  } else {
    d->initial = g_variant_get_child_value(params, 4);
    d->page = g_variant_get_child_value(params, 5);
  }
  const char *title;
  g_variant_get_child(params, 3, "&s", &title);
  portal_dialog(r, *title ? title : "Print", "Cancel",
                portal_string(r->options, "accept_label", "Print"));
  GtkBox *body = GTK_BOX(gtk_dialog_get_content_area(r->dialog));
  d->printers = gtk_drop_down_new(NULL, NULL);
  field(body, "Printer", d->printers);
  d->copies = gtk_spin_button_new_with_range(1, 999, 1);
  gtk_spin_button_set_value(
      GTK_SPIN_BUTTON(d->copies),
      MAX(1, atoi(portal_string(d->initial, "n-copies", "1"))));
  field(body, "Copies", d->copies);
  const char *duplex[] = {"One sided", "Two sided · long edge",
                          "Two sided · short edge", NULL};
  d->duplex = gtk_drop_down_new_from_strings(duplex);
  const char *initial_duplex = portal_string(d->initial, "duplex", "simplex");
  gtk_drop_down_set_selected(GTK_DROP_DOWN(d->duplex),
                             !strcmp(initial_duplex, "vertical")     ? 1
                             : !strcmp(initial_duplex, "horizontal") ? 2
                                                                     : 0);
  field(body, "Sides", d->duplex);
  d->color = gtk_check_button_new_with_label("Print in color");
  gtk_check_button_set_active(
      GTK_CHECK_BUTTON(d->color),
      strcmp(portal_string(d->initial, "use-color", "true"), "false") != 0);
  gtk_box_append(body, d->color);
  const char *orientation[] = {"Portrait", "Landscape", NULL};
  d->orientation = gtk_drop_down_new_from_strings(orientation);
  gtk_drop_down_set_selected(
      GTK_DROP_DOWN(d->orientation),
      !strcmp(portal_string(d->initial, "orientation", "portrait"),
              "landscape"));
  field(body, "Orientation", d->orientation);
  const char *paper[] = {"A4", "Letter", "Legal", NULL};
  d->paper = gtk_drop_down_new_from_strings(paper);
  field(body, "Paper", d->paper);
  d->ranges = gtk_entry_new();
  gtk_entry_set_placeholder_text(GTK_ENTRY(d->ranges), "All pages, or 1-3,5");
  g_autofree char *initial_ranges =
      shift_ranges(portal_string(d->initial, "page-ranges", ""), 1);
  if (initial_ranges)
    gtk_editable_set_text(GTK_EDITABLE(d->ranges), initial_ranges);
  GtkStringList *modes = gtk_string_list_new(NULL);
  gtk_string_list_append(modes, "All pages");
  g_ptr_array_add(d->page_modes, g_strdup("all"));
  gtk_string_list_append(modes, "Page ranges");
  g_ptr_array_add(d->page_modes, g_strdup("ranges"));
  if (portal_boolean(r->options, "has_current_page", FALSE)) {
    gtk_string_list_append(modes, "Current page");
    g_ptr_array_add(d->page_modes, g_strdup("current"));
  }
  if (portal_boolean(r->options, "has_selected_pages", FALSE)) {
    gtk_string_list_append(modes, "Selection");
    g_ptr_array_add(d->page_modes, g_strdup("selection"));
  }
  d->page_mode = gtk_drop_down_new(G_LIST_MODEL(modes), NULL);
  field(body, "Pages", d->page_mode);
  const char *initial_mode = portal_string(d->initial, "print-pages", "all");
  for (guint i = 0; i < d->page_modes->len; i++)
    if (!strcmp(initial_mode, g_ptr_array_index(d->page_modes, i)))
      gtk_drop_down_set_selected(GTK_DROP_DOWN(d->page_mode), i);
  g_signal_connect(d->page_mode, "notify::selected",
                   G_CALLBACK(page_mode_changed), d);
  page_mode_changed(NULL, NULL, d);
  field(body, "Page ranges", d->ranges);
  d->status = portal_label("Finding printers…");
  gtk_box_append(body, d->status);
  gtk_dialog_set_response_sensitive(r->dialog, GTK_RESPONSE_ACCEPT, FALSE);
  g_signal_connect(r->dialog, "response", G_CALLBACK(response), r);
  portal_present(r);
  const char *args[] = {"/proc/self/exe", "--print-worker", "list", NULL};
  if (!worker(r, args, FALSE)) {
    portal_complete(r, 2, NULL);
    return;
  }
  g_subprocess_communicate_utf8_async(d->worker, NULL, r->cancel, enumerated,
                                      portal_request_ref(r));
}
