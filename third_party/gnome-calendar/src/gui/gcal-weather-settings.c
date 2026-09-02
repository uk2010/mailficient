/* gcal-weather-settings.c
 *
 * Copyright © 2018 Georges Basile Stavracas Neto <georges.stavracas@gmail.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

#define G_LOG_DOMAIN "GcalWeatherSettings"

#include "gcal-context.h"
#include "gcal-debug.h"
#include "gcal-manager.h"
#include "gcal-utils.h"
#include "gcal-weather-service.h"
#include "gcal-weather-settings.h"

struct _GcalWeatherSettings
{
  GtkBox              parent;

  GtkSwitch          *show_weather_switch;
  GtkSwitch          *weather_auto_location_switch;
  GtkEditable        *weather_location_entry;
  GtkDropDown        *temperature_unit_dropdown;

  GWeatherLocation   *location;
};


static void          on_weather_location_searchbox_changed_cb    (GtkEntry            *entry,
                                                                  GcalWeatherSettings *self);

static void          on_show_weather_changed_cb                  (GtkSwitch           *wswitch,
                                                                  GParamSpec          *pspec,
                                                                  GcalWeatherSettings *self);

static void          on_weather_auto_location_changed_cb         (GtkSwitch           *lswitch,
                                                                  GParamSpec          *pspec,
                                                                  GcalWeatherSettings *self);

static void          on_temperature_unit_changed_cb              (GtkDropDown         *dropdown,
                                                                  GParamSpec          *pspec,
                                                                  GcalWeatherSettings *self);

G_DEFINE_TYPE (GcalWeatherSettings, gcal_weather_settings, GTK_TYPE_BOX)


/*
 * Auxiliary methods
 */

static void
load_weather_settings (GcalWeatherSettings *self)
{
  g_autoptr (GVariant) location = NULL;
  g_autoptr (GVariant) value = NULL;
  g_autofree gchar *location_name = NULL;
  GSettings *settings;
  GSettings *weather_settings;
  gboolean show_weather;
  gboolean auto_location;
  g_autofree gchar *temperature_unit = NULL;
  GcalContext *context;

  GCAL_ENTRY;

  context = gcal_application_get_context (GCAL_DEFAULT_APPLICATION);
  settings = gcal_context_get_settings (context);
  weather_settings = g_settings_new ("org.gnome.GWeather4");
  temperature_unit = g_settings_get_string (weather_settings, "temperature-unit");

  value = g_settings_get_value (settings, "weather-settings");

  g_variant_get (value, "(bbsmv)",
                 &show_weather,
                 &auto_location,
                 &location_name,
                 &location);

  g_signal_handlers_block_by_func (self->show_weather_switch, on_show_weather_changed_cb, self);
  g_signal_handlers_block_by_func (self->weather_auto_location_switch, on_weather_auto_location_changed_cb, self);
  g_signal_handlers_block_by_func (self->weather_location_entry, on_weather_location_searchbox_changed_cb, self);
  g_signal_handlers_block_by_func (self->temperature_unit_dropdown, on_temperature_unit_changed_cb, self);

  gtk_switch_set_active (self->show_weather_switch, show_weather);
  gtk_switch_set_active (self->weather_auto_location_switch, auto_location);
  gtk_drop_down_set_selected (self->temperature_unit_dropdown,
                              g_strcmp0 (temperature_unit, "fahrenheit") == 0 ? 1 :
                              g_strcmp0 (temperature_unit, "centigrade") == 0 ? 2 : 0);

  if (!location && !auto_location)
    {
      gtk_editable_set_text (self->weather_location_entry, location_name);
      gtk_widget_add_css_class (GTK_WIDGET (self->weather_location_entry), "error");
    }
  else
    {
      g_autoptr (GWeatherLocation) weather_location = NULL;
      GWeatherLocation *world;

      world = gweather_location_get_world ();
      weather_location = location ? gweather_location_deserialize (world, location) : NULL;

      self->location = weather_location ? g_object_ref (weather_location) : NULL;
      gtk_editable_set_text (self->weather_location_entry,
                             self->location ? gweather_location_get_name (self->location) : "");
    }

  g_signal_handlers_unblock_by_func (self->show_weather_switch, on_show_weather_changed_cb, self);
  g_signal_handlers_unblock_by_func (self->weather_auto_location_switch, on_weather_auto_location_changed_cb, self);
  g_signal_handlers_unblock_by_func (self->weather_location_entry, on_weather_location_searchbox_changed_cb, self);
  g_signal_handlers_unblock_by_func (self->temperature_unit_dropdown, on_temperature_unit_changed_cb, self);

  g_object_unref (weather_settings);

  GCAL_EXIT;
}

static void
save_weather_settings (GcalWeatherSettings *self)
{
  GcalContext *context;
  GSettings *settings;
  GVariant *value;
  GVariant *vlocation;
  gboolean res;

  GCAL_ENTRY;

  context = gcal_application_get_context (GCAL_DEFAULT_APPLICATION);

  vlocation = self->location ? gweather_location_serialize (self->location) : NULL;

  settings = gcal_context_get_settings (context);
  value = g_variant_new ("(bbsmv)",
                         gtk_switch_get_active (self->show_weather_switch),
                         gtk_switch_get_active (self->weather_auto_location_switch),
                         gtk_editable_get_text (self->weather_location_entry),
                         vlocation);

  res = g_settings_set_value (settings, "weather-settings", value);

  if (!res)
    g_warning ("Could not persist weather settings");

  GCAL_EXIT;
}

static void
update_menu_weather_sensitivity (GcalWeatherSettings *self)
{
  gboolean weather_enabled;
  gboolean autoloc_enabled;

  weather_enabled = gtk_switch_get_active (self->show_weather_switch);
  autoloc_enabled = gtk_switch_get_active (self->weather_auto_location_switch);

  gtk_widget_set_sensitive (GTK_WIDGET (self->weather_auto_location_switch), weather_enabled);
  gtk_widget_set_sensitive (GTK_WIDGET (self->weather_location_entry), weather_enabled && !autoloc_enabled);
}


static GWeatherLocation*
get_checked_fixed_location (GcalWeatherSettings *self)
{
  /*
   * NOTE: This check feels shabby. However, I couldn't find a better
   * one without iterating the model. has-custom-text does not work
   * properly. Lets go with it for now.
   */
  if (self->location && gweather_location_get_name (self->location))
    return g_object_ref (self->location);

  return NULL;
}

/* Find a city/station in libgweather's real location database.  The old
 * entry only accepted locations selected by a completion widget, but the
 * embedded settings popover has a plain Entry, so typed locations were
 * always rejected. */
static GWeatherLocation *
find_location_by_text (GWeatherLocation *parent,
                       const gchar      *query)
{
  GWeatherLocation *child;
  g_autofree gchar *needle = g_ascii_strdown (query, -1);

  if (needle == NULL || *needle == '\0')
    return NULL;

  for (child = gweather_location_next_child (parent, NULL);
       child != NULL;
       child = gweather_location_next_child (parent, child))
    {
      const gchar *name = gweather_location_get_name (child);
      const gchar *english_name = gweather_location_get_english_name (child);
      g_autofree gchar *city_name = gweather_location_get_city_name (child);
      g_autofree gchar *name_lc = name ? g_ascii_strdown (name, -1) : NULL;
      g_autofree gchar *english_lc = english_name ? g_ascii_strdown (english_name, -1) : NULL;
      g_autofree gchar *city_lc = city_name ? g_ascii_strdown (city_name, -1) : NULL;
      gboolean match = (name_lc && (g_strrstr (name_lc, needle) || g_strrstr (needle, name_lc))) ||
                       (english_lc && (g_strrstr (english_lc, needle) || g_strrstr (needle, english_lc))) ||
                       (city_lc && (g_strrstr (city_lc, needle) || g_strrstr (needle, city_lc)));

      if (match && (gweather_location_get_level (child) == GWEATHER_LOCATION_CITY ||
                    gweather_location_get_level (child) == GWEATHER_LOCATION_WEATHER_STATION))
        return g_object_ref (child);

      if (gweather_location_get_level (child) < GWEATHER_LOCATION_CITY)
        {
          GWeatherLocation *found = find_location_by_text (child, query);
          if (found != NULL)
            return found;
        }
    }

  return NULL;
}

static void
manage_weather_service (GcalWeatherSettings *self)
{
  GcalWeatherService *weather_service;
  GcalContext *context;

  GCAL_ENTRY;

  context = gcal_application_get_context (GCAL_DEFAULT_APPLICATION);

  weather_service = gcal_context_get_weather_service (context);

  if (gtk_switch_get_active (self->show_weather_switch))
    {
      g_autoptr (GWeatherLocation) location = NULL;

      if (!gtk_switch_get_active (self->weather_auto_location_switch))
        {
          location = get_checked_fixed_location (self);

          if (!location)
            g_warning ("Unknown location '%s' selected", gtk_editable_get_text (self->weather_location_entry));
        }

      gcal_weather_service_set_location (weather_service, location);
      gcal_weather_service_activate (weather_service);
    }
  else
    {
      gcal_weather_service_deactivate (weather_service);
    }

  GCAL_EXIT;
}


/*
 * Callbacks
 */

static void
on_show_weather_changed_cb (GtkSwitch           *wswitch,
                            GParamSpec          *pspec,
                            GcalWeatherSettings *self)
{
  save_weather_settings (self);
  update_menu_weather_sensitivity (self);
  manage_weather_service (self);
}


static void
on_weather_auto_location_changed_cb (GtkSwitch           *lswitch,
                                     GParamSpec          *pspec,
                                     GcalWeatherSettings *self)
{
  save_weather_settings (self);
  update_menu_weather_sensitivity (self);
  manage_weather_service (self);
}

static void
on_weather_location_searchbox_changed_cb (GtkEntry            *entry,
                                          GcalWeatherSettings *self)
{
  GWeatherLocation *location = NULL;
  GWeatherLocation *world;
  const gchar *text;
  gboolean auto_location;

  auto_location = gtk_switch_get_active (self->weather_auto_location_switch);
  text = gtk_editable_get_text (GTK_EDITABLE (entry));

  if (!auto_location && text != NULL && *text != '\0')
    {
      world = gweather_location_get_world ();
      location = find_location_by_text (world, text);
      g_clear_object (&self->location);
      self->location = location ? g_object_ref (location) : NULL;
    }
  else
    {
      g_clear_object (&self->location);
    }

  if (!location && !auto_location && gtk_entry_get_text_length (entry) > 0)
    {
      gtk_widget_add_css_class (GTK_WIDGET (self->weather_location_entry), "error");
    }
  else
    {
      gtk_widget_remove_css_class (GTK_WIDGET (self->weather_location_entry), "error");
      manage_weather_service (self);
    }

  g_clear_object (&location);
  save_weather_settings (self);
}

static void
on_temperature_unit_changed_cb (GtkDropDown         *dropdown,
                                 GParamSpec          *pspec,
                                 GcalWeatherSettings *self)
{
  GSettings *settings;
  const gchar *unit;

  settings = g_settings_new ("org.gnome.GWeather4");
  switch (gtk_drop_down_get_selected (dropdown))
    {
    case 1:
      unit = "fahrenheit";
      break;
    case 2:
      unit = "centigrade";
      break;
    default:
      unit = "default";
      break;
    }
  g_settings_set_string (settings, "temperature-unit", unit);
  g_object_unref (settings);
}


/*
 * GObject overrides
 */

static void
gcal_weather_settings_finalize (GObject *object)
{
  GcalWeatherSettings *self = (GcalWeatherSettings *)object;

  g_clear_object (&self->location);

  G_OBJECT_CLASS (gcal_weather_settings_parent_class)->finalize (object);
}

static void
gcal_weather_settings_class_init (GcalWeatherSettingsClass *klass)
{
  GObjectClass *object_class = G_OBJECT_CLASS (klass);
  GtkWidgetClass *widget_class = GTK_WIDGET_CLASS (klass);

  object_class->finalize = gcal_weather_settings_finalize;

  gtk_widget_class_set_template_from_resource (widget_class, "/org/gnome/calendar/ui/gui/gcal-weather-settings.ui");

  gtk_widget_class_bind_template_child (widget_class, GcalWeatherSettings, show_weather_switch);
  gtk_widget_class_bind_template_child (widget_class, GcalWeatherSettings, weather_auto_location_switch);
  gtk_widget_class_bind_template_child (widget_class, GcalWeatherSettings, weather_location_entry);
  gtk_widget_class_bind_template_child (widget_class, GcalWeatherSettings, temperature_unit_dropdown);

  gtk_widget_class_bind_template_callback (widget_class, on_show_weather_changed_cb);
  gtk_widget_class_bind_template_callback (widget_class, on_weather_auto_location_changed_cb);
  gtk_widget_class_bind_template_callback (widget_class, on_weather_location_searchbox_changed_cb);
  gtk_widget_class_bind_template_callback (widget_class, on_temperature_unit_changed_cb);
}

static void
gcal_weather_settings_init (GcalWeatherSettings *self)
{
  gtk_widget_init_template (GTK_WIDGET (self));

  gtk_drop_down_set_model (self->temperature_unit_dropdown,
                           G_LIST_MODEL (gtk_string_list_new ((const char * const[])
                                                              { "Automatic", "Fahrenheit", "Celsius", NULL })));

  load_weather_settings (self);
  update_menu_weather_sensitivity (self);
  manage_weather_service (self);
}
