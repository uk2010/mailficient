namespace Mailficient {
public class Accessibility : Object {
    public static void label (Gtk.Accessible target, string value) {
        target.update_property (Gtk.AccessibleProperty.LABEL, value, -1);
    }

    public static void description (Gtk.Accessible target, string value) {
        target.update_property (Gtk.AccessibleProperty.DESCRIPTION, value, -1);
    }
}
}
