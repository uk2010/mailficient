namespace Mailficient {
public class PaneResizeHandle : Gtk.Box {
    public signal void drag_started (double surface_x);
    public signal void dragged (double surface_x);
    public signal void drag_finished ();
    private double fallback_start_x;

    public PaneResizeHandle (string accessible_name) {
        Object (orientation: Gtk.Orientation.VERTICAL);
        set_size_request (12, -1); add_css_class ("pane-resize-handle");
        tooltip_text = "Drag to resize panes"; Accessibility.label (this, accessible_name);
        accessible_role = Gtk.AccessibleRole.SEPARATOR; set_cursor_from_name ("col-resize");
        var separator = new Gtk.Separator (Gtk.Orientation.VERTICAL); separator.vexpand = true;
        separator.halign = Gtk.Align.CENTER; append (separator);
    }

    public void bind_drag_to (Gtk.Widget coordinate_widget) {
        var drag = new Gtk.GestureDrag ();
        drag.propagation_phase = Gtk.PropagationPhase.BUBBLE;
        bool active = false;
        drag.drag_begin.connect ((x, y) => {
            // The controller lives on the stable sidebar container, so its
            // coordinates do not move when the divider is resized. Only claim
            // drags that begin on the visible handle at the container edge.
            if (coordinate_widget.get_width () <= 0 ||
                x < coordinate_widget.get_width () - get_width () - 8) {
                active = false;
                drag.set_state (Gtk.EventSequenceState.DENIED);
                return;
            }
            active = true;
            fallback_start_x = x;
            drag_started (fallback_start_x);
        });
        drag.drag_update.connect ((offset_x, offset_y) =>
            { if (active) dragged (fallback_start_x + offset_x); });
        drag.drag_end.connect ((offset_x, offset_y) => {
            if (active) drag_finished ();
            active = false;
        });
        coordinate_widget.add_controller (drag);
    }
}
}
