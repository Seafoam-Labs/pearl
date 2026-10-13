#ifndef PEARL_FILE_CHOOSER_H
#define PEARL_FILE_CHOOSER_H
#include <gtk/gtk.h>
G_BEGIN_DECLS
/* C ABI for the implementation in chooser.zig. Native Zig hosts import it.
 * A Pearl-owned GtkDialog, never a GtkFileChooser/Dialog or public portal call.
 * All functions run on the GTK main context. Callers own document operations.
 * Returned files/models are owned references. Destroy cancels outstanding work.
 */
GtkDialog *pearl_file_chooser_new(const char *title,
                                  GtkFileChooserAction action);
void pearl_file_chooser_set_file(GtkDialog *, GFile *);
void pearl_file_chooser_set_state_key(GtkDialog *, const char *);
void pearl_file_chooser_set_folder(GtkDialog *, GFile *);
void pearl_file_chooser_set_name(GtkDialog *, const char *);
void pearl_file_chooser_set_multiple(GtkDialog *, gboolean);
void pearl_file_chooser_add_filter(GtkDialog *, GtkFileFilter *);
void pearl_file_chooser_set_filter(GtkDialog *, GtkFileFilter *);
GtkFileFilter *pearl_file_chooser_get_filter(GtkDialog *); /* borrowed */
GFile *pearl_file_chooser_get_file(GtkDialog *);
GListModel *pearl_file_chooser_get_files(GtkDialog *);
void pearl_file_chooser_set_accept_label(GtkDialog *, const char *);
void pearl_file_chooser_set_local_only(GtkDialog *, gboolean);
gboolean pearl_file_chooser_set_batch(GtkDialog *, GVariant *names, GError **);
gboolean pearl_file_chooser_set_choices(GtkDialog *, GVariant *, GError **);
GVariant *pearl_file_chooser_get_choices(GtkDialog *); /* floating a(ss) */
void pearl_file_chooser_set_caller(GtkDialog *, const char *);
void pearl_file_previews_init(void);
void pearl_file_appearance(gboolean native);
void pearl_file_style(GtkWindow *);
/* Async adapter for the remaining C portal handlers; lifetime follows GTask.
 */
void pearl_file_chooser_open_async(GtkWindow *, gboolean multiple,
                                   GAsyncReadyCallback, gpointer);
void pearl_file_chooser_save_async(GtkWindow *, const char *,
                                   GAsyncReadyCallback, gpointer);
void pearl_file_chooser_folder_async(GtkWindow *, GAsyncReadyCallback,
                                     gpointer);
GListModel *pearl_file_chooser_open_finish(GAsyncResult *, GError **);
GFile *pearl_file_chooser_save_finish(GAsyncResult *, GError **);
/* Shared Zig preview service. Texture and caption are borrowed for the
 * callback. */
void pearl_preview_set_helper(const char *);
void *pearl_preview_watch(GFileInfo *, guint,
                          void (*)(GdkTexture *, const char *, gpointer),
                          gpointer);
void pearl_preview_unwatch(void *);
G_END_DECLS
#endif
