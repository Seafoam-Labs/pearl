/* A real third-party GtkFileDialog consumer; production Pearl never wraps it. */
#include <gtk/gtk.h>
static GMainLoop *loop;
static int status = 1;
static void opened(GObject *source, GAsyncResult *result, gpointer data) {
  (void)data;
  GError *error = NULL;
  GFile *file = gtk_file_dialog_open_finish(GTK_FILE_DIALOG(source), result, &error);
  if (file) {
    char *uri = g_file_get_uri(file);
    g_print("SELECTED %s\n", uri);
    g_free(uri);
    g_object_unref(file);
    status = 0;
  } else {
    g_printerr("%s\n", error ? error->message : "Missing result");
    g_clear_error(&error);
  }
  g_main_loop_quit(loop);
}
int main(int argc, char **argv) {
  if (argc != 2) return 2;
  gtk_init();
  loop = g_main_loop_new(NULL, FALSE);
  GtkWindow *window = GTK_WINDOW(gtk_window_new());
  gtk_window_set_title(window, "GTK portal consumer");
  gtk_window_present(window);
  GtkFileDialog *dialog = gtk_file_dialog_new();
  GFile *file = g_file_new_for_path(argv[1]);
  gtk_file_dialog_set_initial_file(dialog, file);
  g_object_unref(file);
  gtk_file_dialog_open(dialog, window, NULL, opened, NULL);
  g_main_loop_run(loop);
  g_object_unref(dialog);
  gtk_window_destroy(window);
  g_main_loop_unref(loop);
  return status;
}
