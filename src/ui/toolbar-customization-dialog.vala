namespace Mailficient {
public class ToolbarCustomizationDialog : Adw.Dialog {
    public signal void layout_changed (string layout);

    private Gee.ArrayList<string> items;
    private string original_layout;
    private bool accepted = false;
    private Gtk.ListBox available_list = new Gtk.ListBox ();
    private Gtk.ListBox current_list = new Gtk.ListBox ();
    private Gtk.Label current_count = new Gtk.Label ("");

    public ToolbarCustomizationDialog (string serialized_layout) {
        title = "Customize Toolbar";
        content_width = 760;
        content_height = 570;
        width_request = 640;
        height_request = 480;
        presentation_mode = Adw.DialogPresentationMode.FLOATING;
        add_css_class ("toolbar-customization-dialog");
        sync_theme_class ();
        Adw.StyleManager.get_default ().notify["dark"].connect (sync_theme_class);

        items = ToolbarLayout.parse (serialized_layout);
        if (items.size == 0)
            items = ToolbarLayout.parse (ToolbarLayout.DEFAULT_LAYOUT);
        original_layout = ToolbarLayout.serialize (items);

        var toolbar = new Adw.ToolbarView ();
        var header = new Adw.HeaderBar ();
        header.show_start_title_buttons = false;
        header.show_end_title_buttons = false;

        var window_title = new Adw.WindowTitle ("Customize Toolbar", "Changes appear immediately");
        header.title_widget = window_title;

        var cancel = new Gtk.Button.with_mnemonic ("_Cancel");
        cancel.tooltip_text = "Discard toolbar changes";
        Accessibility.label (cancel, "Cancel toolbar customization");
        cancel.clicked.connect (() => close ());
        header.pack_start (cancel);

        var done = new Gtk.Button.with_mnemonic ("_Done");
        done.add_css_class ("suggested-action");
        done.tooltip_text = "Keep toolbar changes";
        Accessibility.label (done, "Finish customizing toolbar");
        done.clicked.connect (() => {
            accepted = true;
            close ();
        });
        header.pack_end (done);
        toolbar.add_top_bar (header);

        var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 14);
        content.margin_top = 16;
        content.margin_bottom = 16;
        content.margin_start = 18;
        content.margin_end = 18;
        content.add_css_class ("toolbar-editor-content");

        var explanation = new Gtk.Label (
            "Choose what appears in the main toolbar, then arrange it in the order you want.");
        explanation.xalign = 0;
        explanation.wrap = true;
        explanation.add_css_class ("toolbar-editor-explanation");
        content.append (explanation);

        var columns = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 16);
        columns.homogeneous = true;
        columns.vexpand = true;
        columns.add_css_class ("toolbar-editor-columns");
        columns.append (build_available_pane ());
        columns.append (build_current_pane ());
        content.append (columns);

        var footer = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10);
        footer.add_css_class ("toolbar-editor-footer");
        var reset = new Gtk.Button.with_label ("Restore Defaults");
        reset.add_css_class ("toolbar-editor-reset");
        reset.tooltip_text = "Restore the recommended Mailficient toolbar";
        Accessibility.label (reset, "Restore default toolbar arrangement");
        reset.clicked.connect (() => {
            items = ToolbarLayout.parse (ToolbarLayout.DEFAULT_LAYOUT);
            commit ();
        });
        footer.append (reset);
        var hint = new Gtk.Label ("Tip: drag rows, or use the arrow buttons for precise placement.");
        hint.xalign = 1;
        hint.hexpand = true;
        hint.wrap = true;
        hint.add_css_class ("dim-label");
        hint.add_css_class ("toolbar-editor-hint");
        footer.append (hint);
        content.append (footer);

        toolbar.content = content;
        child = toolbar;
        default_widget = done;

        closed.connect (() => {
            if (!accepted && ToolbarLayout.serialize (items) != original_layout)
                layout_changed (original_layout);
        });

        rebuild ();
    }

    private void sync_theme_class () {
        if (Adw.StyleManager.get_default ().dark)
            add_css_class ("toolbar-customization-dark");
        else
            remove_css_class ("toolbar-customization-dark");
    }

    private Gtk.Widget build_available_pane () {
        var pane = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        pane.add_css_class ("toolbar-editor-pane");

        var heading = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
        heading.add_css_class ("toolbar-editor-pane-heading");
        var title_label = new Gtk.Label ("Available Controls");
        title_label.xalign = 0;
        title_label.add_css_class ("heading");
        var subtitle = new Gtk.Label ("Select + to add a control");
        subtitle.xalign = 0;
        subtitle.add_css_class ("dim-label");
        subtitle.add_css_class ("caption");
        heading.append (title_label);
        heading.append (subtitle);
        pane.append (heading);

        available_list.selection_mode = Gtk.SelectionMode.NONE;
        available_list.add_css_class ("toolbar-editor-list");
        available_list.add_css_class ("navigation-sidebar");
        add_drop_target (available_list, -1, true);

        var scroller = new Gtk.ScrolledWindow ();
        scroller.set_policy (Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC);
        scroller.vexpand = true;
        scroller.child = available_list;
        scroller.add_css_class ("toolbar-editor-scroller");
        pane.append (scroller);
        return pane;
    }

    private Gtk.Widget build_current_pane () {
        var pane = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        pane.add_css_class ("toolbar-editor-pane");

        var heading = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        heading.add_css_class ("toolbar-editor-pane-heading");
        var heading_copy = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
        heading_copy.hexpand = true;
        var title_label = new Gtk.Label ("Current Toolbar");
        title_label.xalign = 0;
        title_label.add_css_class ("heading");
        var subtitle = new Gtk.Label ("Top to bottom becomes left to right");
        subtitle.xalign = 0;
        subtitle.add_css_class ("dim-label");
        subtitle.add_css_class ("caption");
        heading_copy.append (title_label);
        heading_copy.append (subtitle);
        heading.append (heading_copy);
        current_count.add_css_class ("toolbar-editor-count");
        current_count.valign = Gtk.Align.CENTER;
        heading.append (current_count);
        pane.append (heading);

        current_list.selection_mode = Gtk.SelectionMode.NONE;
        current_list.add_css_class ("toolbar-editor-list");
        current_list.add_css_class ("navigation-sidebar");
        add_drop_target (current_list, 10000, false);

        var scroller = new Gtk.ScrolledWindow ();
        scroller.set_policy (Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC);
        scroller.vexpand = true;
        scroller.child = current_list;
        scroller.add_css_class ("toolbar-editor-scroller");
        pane.append (scroller);
        return pane;
    }

    private void rebuild () {
        rebuild_available ();
        rebuild_current ();
        current_count.label = "%d item%s".printf (items.size, items.size == 1 ? "" : "s");
    }

    private void rebuild_available () {
        clear_list (available_list);
        foreach (var id in ToolbarLayout.palette_items ()) {
            string item_id = id;
            bool can_add = ToolbarLayout.is_repeatable (id) || !items.contains (id);
            var row = new Gtk.ListBoxRow ();
            row.activatable = false;
            row.selectable = false;
            row.add_css_class ("toolbar-editor-row");

            var content = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10);
            content.margin_top = 5;
            content.margin_bottom = 5;
            content.margin_start = 9;
            content.margin_end = 7;
            var palette_icon = build_icon (id);
            content.append (palette_icon);
            var copy = new Gtk.Box (Gtk.Orientation.VERTICAL, 1);
            copy.hexpand = true;
            copy.valign = Gtk.Align.CENTER;
            var label = new Gtk.Label (ToolbarLayout.label (id));
            label.xalign = 0;
            label.ellipsize = Pango.EllipsizeMode.END;
            var description = new Gtk.Label (action_description (id));
            description.xalign = 0;
            description.ellipsize = Pango.EllipsizeMode.END;
            description.add_css_class ("caption");
            description.add_css_class ("dim-label");
            copy.append (label);
            copy.append (description);
            content.append (copy);

            var add = new Gtk.Button.from_icon_name (
                can_add ? "list-add-symbolic" : "object-select-symbolic");
            add.valign = Gtk.Align.CENTER;
            add.has_frame = false;
            add.sensitive = can_add;
            add.add_css_class ("toolbar-editor-row-action");
            add.tooltip_text = can_add ?
                "Add %s".printf (ToolbarLayout.label (id)) : "Already in the toolbar";
            Accessibility.label (add, add.tooltip_text);
            add.clicked.connect (() => add_item (item_id, items.size));
            content.append (add);
            row.child = content;
            if (can_add)
                add_drag_source (palette_icon, "palette|" + item_id, Gdk.DragAction.COPY);
            available_list.append (row);
        }
    }

    private void rebuild_current () {
        clear_list (current_list);
        for (int index = 0; index < items.size; index++) {
            string id = items[index];
            int item_index = index;
            var row = new Gtk.ListBoxRow ();
            row.activatable = false;
            row.selectable = false;
            row.add_css_class ("toolbar-editor-row");

            var content = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 7);
            content.margin_top = 5;
            content.margin_bottom = 5;
            content.margin_start = 7;
            content.margin_end = 7;
            var handle = new Gtk.Image.from_icon_name ("list-drag-handle-symbolic");
            handle.add_css_class ("dim-label");
            handle.tooltip_text = "Drag to reorder";
            content.append (handle);
            content.append (build_icon (id));

            var label = new Gtk.Label (ToolbarLayout.label (id));
            label.xalign = 0;
            label.hexpand = true;
            label.ellipsize = Pango.EllipsizeMode.END;
            content.append (label);

            if (id == "flex") {
                var automatic = new Gtk.Label ("Auto");
                automatic.add_css_class ("caption");
                automatic.add_css_class ("dim-label");
                automatic.tooltip_text = "Automatically expands to fill available space";
                content.append (automatic);
            } else if (ToolbarLayout.is_flexible_space (id)) {
                var width = new Gtk.SpinButton.with_range (0, 100, 5);
                width.value = ToolbarLayout.flexible_space_percentage (id);
                width.numeric = true;
                width.digits = 0;
                width.width_chars = 3;
                width.max_width_chars = 3;
                width.tooltip_text = "Flexible space width percentage; 0 removes extra width";
                width.value_changed.connect (() =>
                    set_flexible_space_percentage (item_index, (int) width.value));
                content.append (width);
                var percent = new Gtk.Label ("%");
                percent.add_css_class ("dim-label");
                content.append (percent);
            }

            var controls = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
            controls.add_css_class ("linked");
            controls.add_css_class ("toolbar-editor-row-controls");
            var up = row_button ("go-up-symbolic", "Move up");
            up.sensitive = index > 0;
            up.clicked.connect (() => move_item (item_index, item_index - 1));
            var down = row_button ("go-down-symbolic", "Move down");
            down.sensitive = index + 1 < items.size;
            down.clicked.connect (() => move_item (item_index, item_index + 1));
            var remove = row_button ("list-remove-symbolic", "Remove from toolbar");
            remove.add_css_class ("destructive-action");
            remove.sensitive = items.size > 1;
            remove.clicked.connect (() => remove_item (item_index));
            controls.append (up);
            controls.append (down);
            controls.append (remove);
            content.append (controls);

            row.child = content;
            add_drag_source (handle, "current|%d|%s".printf (index, id), Gdk.DragAction.MOVE);
            add_drop_target (row, index, false);
            current_list.append (row);
        }

        if (items.size == 0) {
            var empty = new Gtk.ListBoxRow ();
            empty.activatable = false;
            empty.selectable = false;
            var label = new Gtk.Label ("Add a control from the left");
            label.margin_top = 30;
            label.margin_bottom = 30;
            label.add_css_class ("dim-label");
            empty.child = label;
            current_list.append (empty);
        }
    }

    private Gtk.Widget build_icon (string id) {
        var badge = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        badge.halign = Gtk.Align.CENTER;
        badge.valign = Gtk.Align.CENTER;
        badge.add_css_class ("toolbar-editor-icon");
        var icon = new Gtk.Image.from_icon_name (ToolbarLayout.icon_name (id));
        icon.pixel_size = 17;
        badge.append (icon);
        return badge;
    }

    private Gtk.Button row_button (string icon_name, string tooltip) {
        var button = new Gtk.Button.from_icon_name (icon_name);
        button.has_frame = false;
        button.tooltip_text = tooltip;
        button.add_css_class ("toolbar-editor-small-button");
        Accessibility.label (button, tooltip);
        return button;
    }

    private string action_description (string id) {
        switch (id) {
        case "reply-group": return "Reply, Reply All, and Forward";
        case "mail-actions": return "Archive, Delete, and Junk";
        case "toggle-read": return "Mark messages read or unread";
        case "flex":
        case "flex:0": return "Expands between groups";
        case "space": return "Adds a fixed visual gap";
        case "sidebar": return "Show or hide the sidebar";
        case "refresh": return "Check accounts for new mail";
        case "compose": return "Start a new message";
        default: return "Add to the main toolbar";
        }
    }

    private void clear_list (Gtk.ListBox list) {
        Gtk.Widget? child = list.get_first_child ();
        while (child != null) {
            Gtk.Widget? next = child.get_next_sibling ();
            list.remove (child);
            child = next;
        }
    }

    private void set_flexible_space_percentage (int index, int percentage) {
        if (index < 0 || index >= items.size ||
            !ToolbarLayout.is_flexible_space (items[index])) return;
        string next = ToolbarLayout.flexible_space_id (percentage);
        if (items[index] == next) return;
        items[index] = next;
        layout_changed (ToolbarLayout.serialize (items));
    }

    private void add_drag_source (Gtk.Widget widget, string payload, Gdk.DragAction action) {
        var source = new Gtk.DragSource ();
        source.actions = action;
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
                    if (old_index >= 0 && old_index < items.size)
                        remove_item (old_index);
                }
                return true;
            }
            int destination = insertion_index == 10000 ? items.size : insertion_index;
            if (insertion_index != 10000 && y > widget.get_height () / 2.0)
                destination++;
            if (parts[0] == "palette")
                add_item (parts[1], destination);
            else if (parts[0] == "current" && parts.length >= 3) {
                int old_index = int.parse (parts[1]);
                move_item (old_index, destination > old_index ? destination - 1 : destination);
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
        if (items.size <= 1 || index < 0 || index >= items.size) return;
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
        layout_changed (ToolbarLayout.serialize (items));
        rebuild ();
    }
}
}
