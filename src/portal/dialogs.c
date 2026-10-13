#include "portal.h"
#include <glib/gstdio.h>
#include <string.h>
#include <unistd.h>
typedef struct {
  char *id;
  GtkWidget *widget;
  char **values;
} DialogChoice;
typedef struct {
  GtkWidget *entry, *apps, *search, *picture, *profile;
  GPtrArray *ids, *choices;
  GVariant *icon;
  char *name, *user, *image, *pending_image;
  void *preview;
  char *temporary_icon;
  gboolean icon_valid;
  guint icon_generation;
} DialogData;
typedef struct {
  Request *request;
  guint generation;
} IconQuery;
static void choice_free(gpointer data) {
  DialogChoice *c = data;
  g_free(c->id);
  g_strfreev(c->values);
  g_free(c);
}
static void data_free(gpointer data) {
  DialogData *d = data;
  g_clear_pointer(&d->ids, g_ptr_array_unref);
  g_clear_pointer(&d->choices, g_ptr_array_unref);
  g_clear_pointer(&d->icon, g_variant_unref);
  pearl_preview_unwatch(d->preview);
  g_free(d->name);
  g_free(d->user);
  g_free(d->image);
  g_free(d->pending_image);
  if (d->temporary_icon) {
    g_unlink(d->temporary_icon);
    g_free(d->temporary_icon);
  }
  g_free(d);
}
static gboolean add_choices(Request *r, GVariant *raw) {
  DialogData *d = r->data;
  GtkBox *body = GTK_BOX(gtk_dialog_get_content_area(r->dialog));
  if (g_variant_n_children(raw) > 32)
    return FALSE;
  GVariantIter iter;
  g_variant_iter_init(&iter, raw);
  const char *id, *title, *selected;
  GVariant *options;
  while (g_variant_iter_next(&iter, "(&s&s@a(ss)&s)", &id, &title, &options,
                             &selected)) {
    g_autoptr(GVariant) owned = options;
    if (!*id || strlen(title) > 512 || g_variant_n_children(options) > 128)
      return FALSE;
    for (guint i = 0; i < d->choices->len; i++)
      if (!strcmp(((DialogChoice *)g_ptr_array_index(d->choices, i))->id, id))
        return FALSE;
    DialogChoice *c = g_new0(DialogChoice, 1);
    c->id = g_strdup(id);
    g_ptr_array_add(d->choices, c);
    guint n = g_variant_n_children(options);
    if (!n) {
      if (strcmp(selected, "true") && strcmp(selected, "false"))
        return FALSE;
      c->widget = gtk_check_button_new_with_label(title);
      gtk_check_button_set_active(GTK_CHECK_BUTTON(c->widget),
                                  !strcmp(selected, "true"));
    } else {
      GtkStringList *labels = gtk_string_list_new(NULL);
      c->values = g_new0(char *, n + 1);
      guint index = GTK_INVALID_LIST_POSITION;
      for (guint i = 0; i < n; i++) {
        const char *value, *caption;
        g_variant_get_child(options, i, "(&s&s)", &value, &caption);
        c->values[i] = g_strdup(value);
        gtk_string_list_append(labels, caption);
        if (!strcmp(value, selected))
          index = i;
      }
      if (index == GTK_INVALID_LIST_POSITION && *selected) {
        g_object_unref(labels);
        return FALSE;
      }
      c->widget = gtk_drop_down_new(G_LIST_MODEL(labels), NULL);
      gtk_drop_down_set_selected(GTK_DROP_DOWN(c->widget),
                                 index == GTK_INVALID_LIST_POSITION ? 0
                                                                    : index);
      gtk_box_append(body, portal_label(title));
    }
    gtk_box_append(body, c->widget);
  }
  return TRUE;
}
static GVariant *get_choices(DialogData *d) {
  GVariantBuilder b;
  g_variant_builder_init(&b, G_VARIANT_TYPE("a(ss)"));
  for (guint i = 0; i < d->choices->len; i++) {
    DialogChoice *c = g_ptr_array_index(d->choices, i);
    const char *value =
        c->values
            ? c->values[gtk_drop_down_get_selected(GTK_DROP_DOWN(c->widget))]
        : gtk_check_button_get_active(GTK_CHECK_BUTTON(c->widget)) ? "true"
                                                                   : "false";
    g_variant_builder_add(&b, "(ss)", c->id, value);
  }
  return g_variant_builder_end(&b);
}
static void name_changed(GtkEditable *entry, gpointer data) {
  Request *r = data;
  const char *name = gtk_editable_get_text(entry);
  DialogData *d = r->data;
  gtk_dialog_set_response_sensitive(r->dialog, GTK_RESPONSE_ACCEPT,
                                    *name && strlen(name) <= 255 &&
                                        d->icon_valid);
}
static void app_selection(GObject *object, GParamSpec *property,
                          gpointer data) {
  (void)object;
  (void)property;
  Request *r = data;
  DialogData *d = r->data;
  gtk_dialog_set_response_sensitive(
      r->dialog, GTK_RESPONSE_ACCEPT,
      gtk_drop_down_get_selected(GTK_DROP_DOWN(d->apps)) < d->ids->len);
}
void portal_update_choices(Request *r, GVariant *choices) {
  DialogData *d = r->data;
  g_autofree char *previous = NULL;
  guint selected = gtk_drop_down_get_selected(GTK_DROP_DOWN(d->apps));
  if (selected < d->ids->len)
    previous = g_strdup(g_ptr_array_index(d->ids, selected));
  g_ptr_array_set_size(d->ids, 0);
  GtkStringList *labels = gtk_string_list_new(NULL);
  guint chosen = GTK_INVALID_LIST_POSITION;
  const char *last =
      previous ? previous : portal_string(r->options, "last_choice", "");
  GVariantIter iter;
  const char *id;
  g_variant_iter_init(&iter, choices);
  while (g_variant_iter_next(&iter, "&s", &id)) {
    if (d->ids->len >= 256 || strchr(id, '/') || strlen(id) > 255)
      continue;
    g_autofree char *desktop = g_str_has_suffix(id, ".desktop")
                                   ? g_strdup(id)
                                   : g_strconcat(id, ".desktop", NULL);
    g_autoptr(GDesktopAppInfo) app = g_desktop_app_info_new(desktop);
    if (!app || !g_app_info_should_show(G_APP_INFO(app)))
      continue;
    if (!strcmp(id, last))
      chosen = d->ids->len;
    g_ptr_array_add(d->ids, g_strdup(id));
    gtk_string_list_append(labels,
                           g_app_info_get_display_name(G_APP_INFO(app)));
  }
  gtk_drop_down_set_model(GTK_DROP_DOWN(d->apps), G_LIST_MODEL(labels));
  g_object_unref(labels);
  gtk_drop_down_set_selected(
      GTK_DROP_DOWN(d->apps),
      chosen == GTK_INVALID_LIST_POSITION && d->ids->len ? 0 : chosen);
  app_selection(NULL, NULL, r);
}
static void responded(GtkDialog *dialog, int code, gpointer data) {
  Request *r = data;
  DialogData *d = r->data;
  if (code != GTK_RESPONSE_ACCEPT) {
    portal_complete(r, 1, NULL);
    return;
  }
  GVariantBuilder result;
  g_variant_builder_init(&result, G_VARIANT_TYPE_VARDICT);
  if (!strcmp(r->method, "ChooseApplication")) {
    if (portal_restricted(r->portal, "disable-application-handlers"))
      goto denied;
    guint index = gtk_drop_down_get_selected(GTK_DROP_DOWN(d->apps));
    if (index >= d->ids->len)
      goto denied;
    const char *id = g_ptr_array_index(d->ids, index);
    g_autofree char *desktop = g_str_has_suffix(id, ".desktop")
                                   ? g_strdup(id)
                                   : g_strconcat(id, ".desktop", NULL);
    g_autoptr(GDesktopAppInfo) app = g_desktop_app_info_new(desktop);
    if (!app)
      goto denied;
    g_variant_builder_add(&result, "{sv}", "choice", g_variant_new_string(id));
    const char *token = portal_string(r->options, "activation_token", "");
    if (*token)
      g_variant_builder_add(&result, "{sv}", "activation_token",
                            g_variant_new_string(token));
  } else if (!strcmp(r->method, "AccessDialog"))
    g_variant_builder_add(&result, "{sv}", "choices", get_choices(d));
  else if (!strcmp(r->method, "GetUserInformation")) {
    g_variant_builder_add(&result, "{sv}", "id", g_variant_new_string(d->user));
    g_variant_builder_add(&result, "{sv}", "name",
                          g_variant_new_string(d->name));
    g_variant_builder_add(&result, "{sv}", "image",
                          g_variant_new_string(d->image ? d->image : ""));
  } else if (!strcmp(r->method, "PrepareInstall")) {
    const char *name = gtk_editable_get_text(GTK_EDITABLE(d->entry));
    if (!d->icon_valid || !*name || strlen(name) > 255 ||
        portal_restricted(r->portal, "disable-application-handlers"))
      goto denied;
    g_variant_builder_add(&result, "{sv}", "name", g_variant_new_string(name));
    g_variant_builder_add(&result, "{sv}", "icon",
                          g_variant_new_variant(d->icon));
  }
  (void)dialog;
  portal_complete(r, 0, g_variant_builder_end(&result));
  return;
denied:
  g_variant_builder_clear(&result);
  portal_complete(r, 2, NULL);
}
static void account_preview(GdkTexture *texture, const char *caption,
                            gpointer data) {
  (void)caption;
  Request *r = data;
  DialogData *d = r->data;
  if (r->finished)
    return;
  if (texture) {
    gtk_picture_set_paintable(GTK_PICTURE(d->picture), GDK_PAINTABLE(texture));
    g_free(d->image);
    d->image = g_steal_pointer(&d->pending_image);
  } else
    g_clear_pointer(&d->image, g_free);
}
static void avatar_info(GObject *source, GAsyncResult *result, gpointer data) {
  Request *r = data;
  DialogData *d = r->data;
  g_autoptr(GFileInfo) info =
      g_file_query_info_finish(G_FILE(source), result, NULL);
  if (!r->finished && info) {
    g_file_info_set_attribute_object(info, "standard::file", source);
    d->preview = pearl_preview_watch(info, 256, account_preview, r);
    if (!d->preview)
      g_clear_pointer(&d->image, g_free);
  }
  portal_request_unref(r);
}
static void account_data(GObject *source, GAsyncResult *result, gpointer data) {
  Request *r = data;
  DialogData *d = r->data;
  g_autoptr(GVariant) reply =
      g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, NULL);
  if (!r->finished) {
    if (reply) {
      g_autoptr(GVariant) values = g_variant_get_child_value(reply, 0);
      char *name = g_strdup(portal_string(values, "RealName", d->name));
      g_free(d->name);
      d->name = name;
      gtk_label_set_text(GTK_LABEL(d->profile), d->name);
      const char *icon = portal_string(values, "IconFile", "");
      if (g_path_is_absolute(icon)) {
        g_autoptr(GFile) file = g_file_new_for_path(icon);
        d->pending_image = g_file_get_uri(file);
        g_file_query_info_async(
            file,
            "standard::*,access::can-read,time::modified,time::modified-usec",
            G_FILE_QUERY_INFO_NOFOLLOW_SYMLINKS, G_PRIORITY_DEFAULT, r->cancel,
            avatar_info, portal_request_ref(r));
      }
    }
    gtk_dialog_set_response_sensitive(r->dialog, GTK_RESPONSE_ACCEPT, TRUE);
  }
  portal_request_unref(r);
}
static void account_bus(GObject *source, GAsyncResult *result, gpointer data) {
  (void)source;
  Request *r = data;
  g_autoptr(GDBusConnection) bus = g_bus_get_finish(result, NULL);
  if (!r->finished) {
    if (bus) {
      g_autofree char *path =
          g_strdup_printf("/org/freedesktop/Accounts/User%u", (guint)getuid());
      g_dbus_connection_call(
          bus, "org.freedesktop.Accounts", path,
          "org.freedesktop.DBus.Properties", "GetAll",
          g_variant_new("(s)", "org.freedesktop.Accounts.User"),
          G_VARIANT_TYPE("(a{sv})"), G_DBUS_CALL_FLAGS_NO_AUTO_START, 2000,
          r->cancel, account_data, portal_request_ref(r));
    } else
      gtk_dialog_set_response_sensitive(r->dialog, GTK_RESPONSE_ACCEPT, TRUE);
  }
  portal_request_unref(r);
}
static void launcher_preview(GdkTexture *texture, const char *caption,
                             gpointer data) {
  (void)caption;
  Request *r = data;
  if (r->finished)
    return;
  DialogData *d = r->data;
  d->icon_valid = texture != NULL;
  if (texture)
    gtk_picture_set_paintable(GTK_PICTURE(d->picture), GDK_PAINTABLE(texture));
  name_changed(GTK_EDITABLE(d->entry), r);
}
static void launcher_info(GObject *source, GAsyncResult *result,
                          gpointer data) {
  IconQuery *query = data;
  Request *r = query->request;
  DialogData *d = r->data;
  g_autoptr(GFileInfo) info =
      g_file_query_info_finish(G_FILE(source), result, NULL);
  if (!r->finished && info && d->icon_generation == query->generation) {
    g_file_info_set_attribute_object(info, "standard::file", source);
    d->preview = pearl_preview_watch(info, 256, launcher_preview, r);
  }
  portal_request_unref(r);
  g_free(query);
}
static gboolean launcher_icon(Request *r, GIcon *icon) {
  DialogData *d = r->data;
  d->icon_generation++;
  pearl_preview_unwatch(d->preview);
  d->preview = NULL;
  d->icon_valid = FALSE;
  gtk_picture_set_paintable(GTK_PICTURE(d->picture), NULL);
  gtk_widget_set_visible(d->profile, G_IS_THEMED_ICON(icon));
  gtk_widget_set_visible(d->picture, !G_IS_THEMED_ICON(icon));
  if (G_IS_THEMED_ICON(icon)) {
    gtk_image_set_from_gicon(GTK_IMAGE(d->profile), icon);
    d->icon_valid = TRUE;
    return TRUE;
  }
  g_autoptr(GFile) file = NULL;
  if (G_IS_FILE_ICON(icon))
    file = g_object_ref(g_file_icon_get_file(G_FILE_ICON(icon)));
  else if (G_IS_BYTES_ICON(icon)) {
    gsize length;
    const char *bytes =
        g_bytes_get_data(g_bytes_icon_get_bytes(G_BYTES_ICON(icon)), &length);
    if (!length || length > 4 * 1024 * 1024)
      return FALSE;
    if (d->temporary_icon) {
      g_unlink(d->temporary_icon);
      g_clear_pointer(&d->temporary_icon, g_free);
    }
    int fd = g_file_open_tmp("pearl-launcher-XXXXXX", &d->temporary_icon, NULL);
    if (fd < 0)
      return FALSE;
    gsize offset = 0;
    while (offset < length) {
      ssize_t n = write(fd, bytes + offset, length - offset);
      if (n <= 0) {
        close(fd);
        return FALSE;
      }
      offset += (gsize)n;
    }
    close(fd);
    file = g_file_new_for_path(d->temporary_icon);
  }
  if (!file || !g_file_is_native(file))
    return FALSE;
  IconQuery *query = g_new0(IconQuery, 1);
  query->request = portal_request_ref(r);
  query->generation = d->icon_generation;
  g_file_query_info_async(
      file, "standard::*,access::can-read,time::modified,time::modified-usec",
      G_FILE_QUERY_INFO_NOFOLLOW_SYMLINKS, G_PRIORITY_DEFAULT, r->cancel,
      launcher_info, query);
  return TRUE;
}
static void icon_chosen(GObject *source, GAsyncResult *result, gpointer data) {
  (void)source;
  Request *r = data;
  DialogData *d = r->data;
  g_autoptr(GListModel) files = pearl_file_chooser_open_finish(result, NULL);
  if (!r->finished && files && g_list_model_get_n_items(files)) {
    g_autoptr(GFile) file = g_list_model_get_item(files, 0);
    g_autoptr(GIcon) icon = g_file_icon_new(file);
    if (launcher_icon(r, icon)) {
      g_clear_pointer(&d->icon, g_variant_unref);
      d->icon = g_variant_ref_sink(g_icon_serialize(icon));
    }
    name_changed(GTK_EDITABLE(d->entry), r);
  }
  portal_request_unref(r);
}
static void change_icon(GtkButton *button, gpointer data) {
  (void)button;
  Request *r = data;
  pearl_file_chooser_open_async(GTK_WINDOW(r->dialog), FALSE, icon_chosen,
                                portal_request_ref(r));
}
void portal_dialogs(Request *r, GVariant *params) {
  DialogData *d = g_new0(DialogData, 1);
  d->ids = g_ptr_array_new_with_free_func(g_free);
  d->choices = g_ptr_array_new_with_free_func(choice_free);
  r->data = d;
  r->destroy_data = data_free;
  if (!strcmp(r->method, "AccessDialog")) {
    const char *title, *subtitle, *text;
    g_variant_get_child(params, 3, "&s", &title);
    g_variant_get_child(params, 4, "&s", &subtitle);
    g_variant_get_child(params, 5, "&s", &text);
    portal_dialog(r, title, portal_string(r->options, "deny_label", "Deny"),
                  portal_string(r->options, "grant_label", "Allow"));
    GtkBox *body = GTK_BOX(gtk_dialog_get_content_area(r->dialog));
    gtk_box_append(body, portal_label(subtitle));
    gtk_box_append(body, portal_label(text));
    const char *icon = portal_string(r->options, "icon", "");
    if (*icon && strlen(icon) < 256 && !strchr(icon, '/'))
      gtk_box_prepend(body, gtk_image_new_from_icon_name(icon));
    g_autoptr(GVariant) choices =
        portal_option(r->options, "choices", "a(ssa(ss)s)");
    if (choices && !add_choices(r, choices)) {
      portal_complete(r, 2, NULL);
      return;
    }
  } else if (!strcmp(r->method, "ChooseApplication")) {
    if (portal_restricted(r->portal, "disable-application-handlers")) {
      portal_complete(r, 2, NULL);
      return;
    }
    portal_dialog(r, "Choose an application", "Cancel", "Open");
    GtkBox *body = GTK_BOX(gtk_dialog_get_content_area(r->dialog));
    gtk_box_append(body,
                   portal_label(portal_string(
                       r->options, "filename",
                       "Choose an installed application to open this item.")));
    d->apps = gtk_drop_down_new(NULL, NULL);
    gtk_drop_down_set_enable_search(GTK_DROP_DOWN(d->apps), TRUE);
    gtk_box_append(body, d->apps);
    g_signal_connect(d->apps, "notify::selected", G_CALLBACK(app_selection), r);
    g_autoptr(GVariant) choices = g_variant_get_child_value(params, 3);
    portal_update_choices(r, choices);
  } else if (!strcmp(r->method, "GetUserInformation")) {
    portal_dialog(r, "Share your profile?", "Cancel", "Share profile");
    GtkBox *body = GTK_BOX(gtk_dialog_get_content_area(r->dialog));
    gtk_box_append(
        body,
        portal_label(portal_string(
            r->options, "reason",
            "Share your profile name and picture with this application.")));
    d->user = g_strdup(g_get_user_name());
    d->name = g_strdup(g_get_real_name());
    d->profile = portal_label(d->name);
    d->picture = gtk_picture_new();
    gtk_widget_set_size_request(d->picture, 96, 96);
    gtk_picture_set_content_fit(GTK_PICTURE(d->picture),
                                GTK_CONTENT_FIT_CONTAIN);
    gtk_box_append(body, d->picture);
    gtk_box_append(body, d->profile);
    gtk_box_append(body, portal_label(d->user));
    gtk_dialog_set_response_sensitive(r->dialog, GTK_RESPONSE_ACCEPT, FALSE);
    g_bus_get(G_BUS_TYPE_SYSTEM, r->cancel, account_bus, portal_request_ref(r));
  } else if (!strcmp(r->method, "PrepareInstall")) {
    if (portal_restricted(r->portal, "disable-application-handlers")) {
      portal_complete(r, 2, NULL);
      return;
    }
    guint type = 1;
    g_variant_lookup(r->options, "launcher_type", "u", &type);
    if (type != 1 && type != 2) {
      portal_complete(r, 2, NULL);
      return;
    }
    g_autoptr(GVariant) wrapped = g_variant_get_child_value(params, 4);
    d->icon = g_variant_get_variant(wrapped);
    g_autoptr(GIcon) icon = g_icon_deserialize(d->icon);
    if (!icon) {
      portal_complete(r, 2, NULL);
      return;
    }
    const char *name;
    g_variant_get_child(params, 3, "&s", &name);
    portal_dialog(r, "Add application", "Cancel", "Add application");
    GtkBox *body = GTK_BOX(gtk_dialog_get_content_area(r->dialog));
    d->profile = gtk_image_new();
    gtk_image_set_pixel_size(GTK_IMAGE(d->profile), 64);
    gtk_box_append(body, d->profile);
    d->picture = gtk_picture_new();
    gtk_widget_set_size_request(d->picture, 96, 96);
    gtk_picture_set_content_fit(GTK_PICTURE(d->picture),
                                GTK_CONTENT_FIT_CONTAIN);
    gtk_box_append(body, d->picture);
    if (portal_boolean(r->options, "editable_icon", TRUE)) {
      GtkWidget *button = gtk_button_new_with_label("Choose icon…");
      gtk_box_append(body, button);
      g_signal_connect(button, "clicked", G_CALLBACK(change_icon), r);
    }
    d->entry = gtk_entry_new();
    gtk_editable_set_text(GTK_EDITABLE(d->entry), name);
    gtk_editable_set_editable(
        GTK_EDITABLE(d->entry),
        portal_boolean(r->options, "editable_name", TRUE));
    gtk_box_append(body, d->entry);
    g_signal_connect(d->entry, "changed", G_CALLBACK(name_changed), r);
    if (!launcher_icon(r, icon)) {
      portal_complete(r, 2, NULL);
      return;
    }
    name_changed(GTK_EDITABLE(d->entry), r);
    if (type == 2) {
      const char *target = portal_string(r->options, "target", "");
      g_autoptr(GUri) uri = g_uri_parse(target, G_URI_FLAGS_NONE, NULL);
      if (!uri || !g_uri_get_scheme(uri)) {
        portal_complete(r, 2, NULL);
        return;
      }
      gtk_box_append(body, portal_label(target));
    }
  } else {
    portal_complete(r, 2, NULL);
    return;
  }
  g_signal_connect(r->dialog, "response", G_CALLBACK(responded), r);
  portal_present(r);
}
