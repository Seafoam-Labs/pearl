#ifndef PEARL_PORTAL_H
#define PEARL_PORTAL_H
#include "../files/chooser.h"
#include "identity.h"
#include <gio/gdesktopappinfo.h>
#include <gtk/gtk.h>
#define PORTAL_PATH "/org/freedesktop/portal/desktop"
#define IMPL "org.freedesktop.impl.portal."
typedef struct Portal Portal;
typedef struct Request Request;
struct Portal {
  GDBusConnection *bus;
  GMainLoop *loop;
  char *owner;
  GHashTable *requests;
  GHashTable *print_tokens;
  gpointer inhibitors;
  GHashTable *settings;
  GKeyFile *policy;
  GFileMonitor *policy_monitor;
  GSettings *managed_policy;
  guint owner_watch;
  gboolean stopping;
  GHashTable *notifications, *notification_busy;
  char *notification_owner;
  guint notification_watch, notification_signal;
};
struct Request {
  gint refs;
  Portal *portal;
  char *handle, *sender, *app_id, *parent, *method;
  GDBusMethodInvocation *invocation;
  GCancellable *cancel;
  GtkDialog *dialog;
  GVariant *options;
  guint registration;
  gboolean finished;
  gpointer data;
  GDestroyNotify destroy_data;
};
void portal_error(GDBusMethodInvocation *, const char *code,
                  const char *message);
GVariant *portal_empty(void);
GVariant *portal_option(GVariant *, const char *, const char *type);
const char *portal_string(GVariant *, const char *, const char *fallback);
gboolean portal_boolean(GVariant *, const char *, gboolean fallback);
gboolean portal_authorized(Portal *, const char *sender);
Request *portal_request(Portal *, GDBusMethodInvocation *, GVariant *,
                        const char *method, guint options_index);
Request *portal_request_ref(Request *);
void portal_request_unref(Request *);
void portal_complete(Request *, guint response, GVariant *results);
void portal_present(Request *);
GtkDialog *portal_dialog(Request *, const char *, const char *, const char *);
GtkWidget *portal_label(const char *);
char *portal_app_name(const char *);
void portal_inhibit(Portal *, const char *, GVariant *,
                    GDBusMethodInvocation *);
void portal_inhibit_init(Portal *);
void portal_inhibit_clear(Portal *);
void portal_inhibit_stop(Portal *);
int pearl_print_worker(int, char **);
void portal_print(Request *, GVariant *);
void portal_print_init(Portal *);
void portal_print_stop(Portal *);
void portal_print_clear(Portal *);
void portal_files(Request *, GVariant *);
void portal_email(Request *);
void portal_notification(Portal *, const char *, GVariant *,
                         GDBusMethodInvocation *);
void portal_notifications_init(Portal *);
void portal_notifications_stop(Portal *);
void portal_dialogs(Request *, GVariant *);
void portal_update_choices(Request *, GVariant *);
void portal_settings_init(Portal *);
void portal_settings_stop(Portal *);
void portal_settings_call(Portal *, const char *, GVariant *,
                          GDBusMethodInvocation *);
GVariant *portal_settings_property(Portal *, const char *, GError **);
gboolean portal_restricted(Portal *, const char *);
void portal_appearance(guint scheme, double r, double g, double b,
                       gboolean reduced, const char *font, const char *css);
#endif
