namespace Mailficient {
    [CCode (cname = "mailficient_gnome_calendar_new")]
    private extern Gtk.Widget? mailficient_gnome_calendar_new ();

    // Hosts the actual GNOME Calendar workspace (month/week/agenda views,
    // calendar list, event editor, and EDS timeline) inside Mailficient.
    public class GnomeCalendarSurface : Gtk.Box {
        public GnomeCalendarSurface () {
            Object (orientation: Gtk.Orientation.VERTICAL, hexpand: true, vexpand: true);
            add_css_class ("gnome-calendar-surface");
            var calendar = mailficient_gnome_calendar_new ();
            if (calendar != null) append (calendar);
            else {
                var error = new Gtk.Label ("GNOME Calendar could not be loaded");
                error.add_css_class ("dim-label");
                set_valign (Gtk.Align.CENTER);
                set_halign (Gtk.Align.CENTER);
                append (error);
            }
        }
    }
}
