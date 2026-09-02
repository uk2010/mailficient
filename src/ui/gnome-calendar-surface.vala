namespace Mailficient {
    [CCode (cname = "mailficient_gnome_calendar_new")]
    private extern Gtk.Widget? mailficient_gnome_calendar_new ();
    [CCode (cname = "mailficient_gnome_calendar_set_host")]
    private extern void mailficient_gnome_calendar_set_host (Gtk.Widget content, Gtk.Widget host);

    // Hosts the actual GNOME Calendar workspace (month/week/agenda views,
    // calendar list, event editor, and EDS timeline) inside Mailficient.
    public class GnomeCalendarSurface : Gtk.Box {
        public GnomeCalendarSurface () {
            Object (orientation: Gtk.Orientation.VERTICAL, hexpand: true, vexpand: true);
            add_css_class ("gnome-calendar-surface");
            var calendar_provider = new Gtk.CssProvider ();
            calendar_provider.load_from_string ("""
                .gnome-calendar-surface .mailficient-calendar-sidebar,
                .gnome-calendar-surface .mailficient-calendar-sidebar > box,
                .gnome-calendar-surface .mailficient-calendar-sidebar > box > * {
                    color: var(--sidebar-fg-color);
                    background-color: var(--sidebar-bg-color);
                    background-image: none;
                }
                .gnome-calendar-surface .mailficient-calendar-main,
                .gnome-calendar-surface .mailficient-calendar-main > box,
                .gnome-calendar-surface .mailficient-calendar-main > box > * {
                    color: var(--view-fg-color);
                    background-color: var(--view-bg-color);
                    background-image: none;
                }
                """);
            Gtk.StyleContext.add_provider_for_display (
                Gdk.Display.get_default (), calendar_provider,
                Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 20);
            var calendar = mailficient_gnome_calendar_new ();
            if (calendar != null) {
                append (calendar);
                /* The Calendar window is hidden while embedded.  Once this
                 * surface is realized, redirect dialogs/popovers to the
                 * actual Mailficient native window. */
                realize.connect (() => {
                    var root = get_root ();
                    if (root is Gtk.Window)
                        mailficient_gnome_calendar_set_host (calendar, root);
                });
            }
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
