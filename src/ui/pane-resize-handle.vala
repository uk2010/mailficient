namespace Mailficient {
public class PaneResizeHandle : Gtk.Box {
    public signal void drag_started (double surface_x);
    public signal void dragged (double surface_x);
    public signal void drag_finished ();
    private double fallback_start_x;

    public PaneResizeHandle (string accessible_name) {
        Object (orientation: Gtk.Orientation.VERTICAL);
        set_size_request (7, -1); add_css_class ("pane-resize-handle");
        tooltip_text = "Drag to resize panes"; Accessibility.label (this, accessible_name);
        accessible_role = Gtk.AccessibleRole.SEPARATOR; set_cursor_from_name ("col-resize");
        var separator = new Gtk.Separator (Gtk.Orientation.VERTICAL); separator.vexpand = true;
        separator.halign = Gtk.Align.CENTER; append (separator);
        var drag = new Gtk.GestureDrag ();
        drag.drag_begin.connect ((x, y) => {
            fallback_start_x = x;
            double surface_x = event_surface_x (drag, x);
            drag_started (surface_x);
        });
        drag.drag_update.connect ((offset_x, offset_y) =>
            dragged (event_surface_x (drag, fallback_start_x + offset_x)));
        drag.drag_end.connect ((offset_x, offset_y) => drag_finished ());
        add_controller (drag);
    }

    private static double event_surface_x (Gtk.Gesture gesture, double fallback) {
        var event = gesture.get_current_event ();
        if (event == null) return fallback;
        double x; double y;
        return event.get_position (out x, out y) ? x : fallback;
    }
}
}
