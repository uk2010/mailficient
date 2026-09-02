#include <gtk/gtk.h>

#ifndef MAILFICIENT_EMBEDDED_GCAL
GtkWidget *
mailficient_gnome_calendar_new (void)
{
  return NULL;
}

void
mailficient_gnome_calendar_set_host (GtkWidget *content,
                                     GtkWidget *host)
{
  (void) content;
  (void) host;
}
#else

typedef struct _GcalApplication GcalApplication;
typedef struct _GcalWindow GcalWindow;

GcalApplication *gcal_application_new (void);
gboolean g_application_register (GApplication *, GCancellable *, GError **);
GtkWidget *gcal_window_new_with_date (GcalApplication *, GDateTime *);
GtkWidget *gcal_window_take_content (GcalWindow *);
void gcal_window_set_embedded_host (GcalWindow *, GtkWidget *);

static GcalApplication *calendar_application;
static GtkWidget *calendar_window;

GtkWidget *
mailficient_gnome_calendar_new (void)
{
  g_autoptr (GDateTime) date = g_date_time_new_now_local ();

  if (calendar_application == NULL)
    {
      calendar_application = gcal_application_new ();
      /* Startup initializes the EDS manager used by every GNOME Calendar
       * widget.  The application remains owned for the Mailficient process. */
      g_application_register (G_APPLICATION (calendar_application), NULL, NULL);
    }

  if (calendar_window == NULL)
    {
      calendar_window = gcal_window_new_with_date (calendar_application, date);
    }

  return gcal_window_take_content ((GcalWindow *) calendar_window);
}

void
mailficient_gnome_calendar_set_host (GtkWidget *content,
                                     GtkWidget *host)
{
  GcalWindow *window;

  g_return_if_fail (GTK_IS_WIDGET (content));
  g_return_if_fail (GTK_IS_WIDGET (host));

  window = g_object_get_data (G_OBJECT (content), "mailficient-gcal-window");
  if (window != NULL)
    gcal_window_set_embedded_host (window, host);
}
#endif
