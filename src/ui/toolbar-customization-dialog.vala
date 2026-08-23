namespace Mailficient {
public class ToolbarCustomizationDialog : Adw.PreferencesDialog {
    public signal void layout_changed (string layout);

    private Gee.ArrayList<string> items;
    private Gtk.FlowBox palette = new Gtk.FlowBox ();
    private Gtk.Box preview = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);

    public ToolbarCustomizationDialog (string serialized_layout) {
        title = "Customize Toolbar";
        content_width = 1040;
        content_height = 720;
        search_enabled = false;
        items = ToolbarLayout.parse (serialized_layout);
        if (items.size == 0) items = ToolbarLayout.parse (ToolbarLayout.DEFAULT_LAYOUT);

        var page = new Adw.PreferencesPage ();
        page.title = "Toolbar";
        page.icon_name = "applications-system-symbolic";

        var available = new Adw.PreferencesGroup ();
        available.title = "Drag your favorite items into the toolbar";
        available.description = "Drag controls below to add them. Drag controls in the current toolbar to move or remove them.";
        palette.selection_mode = Gtk.SelectionMode.NONE;
        palette.homogeneous = true;
        palette.min_children_per_line = 7;
        palette.max_children_per_line = 7;
        palette.row_spacing = 8;
        palette.column_spacing = 4;
        palette.add_css_class ("toolbar-palette");
        foreach (var id in ToolbarLayout.palette_items ())
            palette.insert (build_palette_item (id), -1);
        add_drop_target (palette, -1, true);
        available.add (palette);
        page.add (available);

        var current = new Adw.PreferencesGroup ();
        current.title = "Current Toolbar";
        current.description = "Drag to rearrange. Use the arrow buttons for precise placement.";
        preview.add_css_class ("toolbar-preview");
        preview.margin_top = 12;
        preview.margin_bottom = 12;
        preview.margin_start = 12;
        preview.margin_end = 12;
        var scroller = new Gtk.ScrolledWindow ();
        scroller.set_policy (Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.NEVER);
        scroller.set_min_content_height (116);
        scroller.child = preview;
        scroller.add_css_class ("toolbar-preview-scroller");
        current.add (scroller);

        var reset_row = new Adw.ActionRow ();
        reset_row.title = "Default Set";
        reset_row.subtitle = "Restore Apple Mail–style grouped controls and flexible spacing";
        var reset = new Gtk.Button.with_label ("Use Default Set");
        reset.valign = Gtk.Align.CENTER;
        reset.add_css_class ("suggested-action");
        reset.clicked.connect (() => {
            items = ToolbarLayout.parse (ToolbarLayout.DEFAULT_LAYOUT);
            commit ();
        });
        reset_row.add_suffix (reset);
        current.add (reset_row);
        page.add (current);
        add (page);
        rebuild_preview ();
    }

    private Gtk.Widget build_palette_item (string id) {
        var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
        content.halign = Gtk.Align.CENTER;
        content.add_css_class ("toolbar-palette-item");
        content.tooltip_text = "Drag to add " + ToolbarLayout.label (id);
        Accessibility.label (content, "Drag " + ToolbarLayout.label (id) + " into the toolbar");
        var icon = new Gtk.Image.from_icon_name (ToolbarLayout.icon_name (id));
        icon.pixel_size = 24;
        icon.add_css_class ("toolbar-palette-icon");
        var label = new Gtk.Label (ToolbarLayout.label (id));
        label.ellipsize = Pango.EllipsizeMode.END;
        label.max_width_chars = 12;
        label.add_css_class ("caption");
        content.append (icon);
        content.append (label);

        string item_id = id;
        var click = new Gtk.GestureClick ();
        click.released.connect ((presses, x, y) => add_item (item_id, items.size));
        content.add_controller (click);
        add_drag_source (content, "palette|" + item_id);
        return content;
    }

    private void rebuild_preview () {
        Gtk.Widget? child = preview.get_first_child ();
        while (child != null) {
            Gtk.Widget? next = child.get_next_sibling ();
            preview.remove (child);
            child = next;
        }

        for (int index = 0; index < items.size; index++) {
            string id = items[index];
            int item_index = index;
            var card = new Gtk.Box (Gtk.Orientation.VERTICAL, 5);
            card.add_css_class ("toolbar-preview-item");
            card.tooltip_text = "Drag to move " + ToolbarLayout.label (id);

            var icon = new Gtk.Image.from_icon_name (ToolbarLayout.icon_name (id));
            icon.pixel_size = 22;
            icon.halign = Gtk.Align.CENTER;
            var label = new Gtk.Label (ToolbarLayout.label (id));
            label.ellipsize = Pango.EllipsizeMode.END;
            label.max_width_chars = 15;
            label.add_css_class ("caption");
            var controls = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
            controls.halign = Gtk.Align.CENTER;
            controls.add_css_class ("linked");
            var left = new Gtk.Button.from_icon_name ("go-previous-symbolic");
            left.tooltip_text = "Move left";
            left.sensitive = index > 0;
            left.clicked.connect (() => move_item (item_index, item_index - 1));
            var remove = new Gtk.Button.from_icon_name ("list-remove-symbolic");
            remove.tooltip_text = "Remove from toolbar";
            remove.clicked.connect (() => remove_item (item_index));
            var right = new Gtk.Button.from_icon_name ("go-next-symbolic");
            right.tooltip_text = "Move right";
            right.sensitive = index + 1 < items.size;
            right.clicked.connect (() => move_item (item_index, item_index + 1));
            controls.append (left);
            controls.append (remove);
            controls.append (right);
            card.append (icon);
            card.append (label);
            card.append (controls);
            add_drag_source (card, "current|%d|%s".printf (index, id));
            add_drop_target (card, index, false);
            preview.append (card);
        }

        var end = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
        end.add_css_class ("toolbar-drop-end");
        var end_icon = new Gtk.Image.from_icon_name ("list-add-symbolic");
        var end_label = new Gtk.Label ("Drop here");
        end_label.add_css_class ("caption");
        end.append (end_icon);
        end.append (end_label);
        add_drop_target (end, items.size, false);
        preview.append (end);
    }

    private void add_drag_source (Gtk.Widget widget, string payload) {
        var source = new Gtk.DragSource ();
        source.actions = Gdk.DragAction.COPY | Gdk.DragAction.MOVE;
        source.propagation_phase = Gtk.PropagationPhase.CAPTURE;
        source.prepare.connect ((x, y) => {
            Value value = Value (typeof (string));
            value.set_string (payload);
            return new Gdk.ContentProvider.for_value (value);
        });
        widget.add_controller (source);
    }

    private void add_drop_target (Gtk.Widget widget, int insertion_index, bool remove) {
        var target = new Gtk.DropTarget (typeof (string),
            Gdk.DragAction.COPY | Gdk.DragAction.MOVE);
        target.propagation_phase = Gtk.PropagationPhase.CAPTURE;
        target.drop.connect ((value, x, y) => {
            string? payload = value.get_string ();
            if (payload == null) return false;
            string[] parts = payload.split ("|");
            if (parts.length < 2) return false;
            if (remove) {
                if (parts[0] == "current" && parts.length >= 3) {
                    int old_index = int.parse (parts[1]);
                    if (old_index >= 0 && old_index < items.size) remove_item (old_index);
                }
                return true;
            }
            if (parts[0] == "palette") add_item (parts[1], insertion_index);
            else if (parts[0] == "current" && parts.length >= 3) {
                int old_index = int.parse (parts[1]);
                move_item (old_index, insertion_index > old_index ?
                    insertion_index - 1 : insertion_index);
            }
            return true;
        });
        widget.add_controller (target);
    }

    private void add_item (string id, int index) {
        if (!ToolbarLayout.is_valid (id)) return;
        if (!ToolbarLayout.is_repeatable (id) && items.contains (id)) return;
        int safe_index = int.min (int.max (index, 0), items.size);
        items.insert (safe_index, id);
        commit ();
    }

    private void remove_item (int index) {
        if (index < 0 || index >= items.size) return;
        items.remove_at (index);
        commit ();
    }

    private void move_item (int old_index, int new_index) {
        if (old_index < 0 || old_index >= items.size) return;
        int safe_index = int.min (int.max (new_index, 0), items.size - 1);
        if (old_index == safe_index) return;
        string id = items.remove_at (old_index);
        items.insert (safe_index, id);
        commit ();
    }

    private void commit () {
        string serialized = ToolbarLayout.serialize (items);
        layout_changed (serialized);
        rebuild_preview ();
    }
}
}
