namespace Mailficient {
/*
 * This is deliberately a widget rather than a dialog.  The mail window keeps
 * the real toolbar visible while this sheet is open, so palette items can be
 * dragged straight into it and toolbar items can be dragged back over the
 * sheet to remove them.
 */
public class ToolbarCustomizationDialog : Gtk.Box {
    public signal void layout_changed (string layout);
    public signal void display_mode_changed (string mode);
    public signal void close_requested ();
    public signal void drag_activity_changed (bool active);

    public string display_mode { get; private set; default = "icons"; }

    private Gee.ArrayList<string> items;
    private Gtk.FlowBox palette = new Gtk.FlowBox ();
    private Gtk.DropDown display_mode_selector;
    private Gtk.Button done_button;
    private bool syncing_display_mode = false;
    private Gtk.DragSource? active_drag_source;
    private bool suppress_toolbar_removal;

    public ToolbarCustomizationDialog (string serialized_layout,
                                       string initial_display_mode = "icons") {
        Object (orientation: Gtk.Orientation.VERTICAL, spacing: 0);

        hexpand = true;
        vexpand = false;
        width_request = 360;
        add_css_class ("toolbar-customization-dialog");
        add_css_class ("toolbar-customization-sheet");
        sync_theme_class ();
        // Do not connect this short-lived sheet directly to the process-wide
        // StyleManager. That signal retained every closed customization tree,
        // including its native popovers and drag controllers; repeated opens
        // then left stale Wayland accessibility objects alive. Appearance is
        // chosen outside this sheet, so sampling it when the sheet is created
        // keeps the lifecycle ownership-safe.

        items = ToolbarLayout.parse (serialized_layout);
        if (items.size == 0)
            items = ToolbarLayout.parse (ToolbarLayout.DEFAULT_LAYOUT);

        var page = new Gtk.Box (Gtk.Orientation.VERTICAL, 5);
        page.hexpand = true;
        page.add_css_class ("toolbar-customization-content");
        page.add_css_class ("toolbar-customization-surface");

        var intro = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10);
        intro.add_css_class ("toolbar-customization-intro-row");

        var heading = new Gtk.Label ("Drag your favorite items into the toolbar…");
        heading.xalign = 0;
        heading.ellipsize = Pango.EllipsizeMode.END;
        heading.add_css_class ("toolbar-customization-heading");
        Accessibility.label (heading, "Drag your favorite items into the toolbar");
        intro.append (heading);

        var instructions = new Gtk.Label (
            "Drag toolbar items down here to remove them.");
        instructions.xalign = 1;
        instructions.hexpand = true;
        instructions.ellipsize = Pango.EllipsizeMode.END;
        instructions.add_css_class ("dim-label");
        instructions.add_css_class ("toolbar-customization-intro-description");
        intro.append (instructions);
        page.append (intro);

        palette.selection_mode = Gtk.SelectionMode.NONE;
        palette.activate_on_single_click = false;
        palette.homogeneous = true;
        palette.min_children_per_line = 4;
        palette.max_children_per_line = 7;
        palette.row_spacing = 2;
        palette.column_spacing = 2;
        palette.hexpand = true;
        palette.add_css_class ("toolbar-palette");
        palette.add_css_class ("toolbar-customization-palette");
        Accessibility.label (palette, "Available toolbar items");
        page.append (palette);

        var default_heading = new Gtk.Label (
            "…or drag the default set into the toolbar.");
        default_heading.xalign = 0;
        default_heading.wrap = true;
        default_heading.add_css_class ("heading");
        default_heading.add_css_class ("toolbar-customization-default-label");
        page.append (default_heading);
        page.append (build_default_set ());

        var footer = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10);
        footer.margin_top = 0;
        footer.add_css_class ("toolbar-customization-footer");

        var show_label = new Gtk.Label.with_mnemonic ("_Show:");
        show_label.valign = Gtk.Align.CENTER;
        footer.append (show_label);

        display_mode_selector = new Gtk.DropDown.from_strings ({
            "Icon Only", "Icon and Text", "Text Only"
        });
        display_mode_selector.valign = Gtk.Align.CENTER;
        display_mode_selector.add_css_class ("toolbar-customization-show");
        display_mode_selector.tooltip_text = "Choose how toolbar items are displayed";
        Accessibility.label (display_mode_selector, "Toolbar item display style");
        show_label.mnemonic_widget = display_mode_selector;
        footer.append (display_mode_selector);

        var footer_space = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        footer_space.hexpand = true;
        footer.append (footer_space);

        done_button = new Gtk.Button.with_mnemonic ("_Done");
        done_button.valign = Gtk.Align.CENTER;
        done_button.add_css_class ("suggested-action");
        done_button.add_css_class ("toolbar-customization-done");
        done_button.tooltip_text = "Finish customizing the toolbar";
        Accessibility.label (done_button, "Finish customizing the toolbar");
        done_button.clicked.connect (() => close_requested ());
        footer.append (done_button);
        page.append (footer);

        append (page);

        display_mode_selector.notify["selected"].connect (() => {
            if (syncing_display_mode) return;
            string next = mode_for_index (display_mode_selector.selected);
            if (display_mode == next) return;
            display_mode = next;
            display_mode_changed (next);
        });
        sync_display_mode (initial_display_mode);

        // Dropping a live-toolbar item anywhere over the sheet removes it.
        // Palette and default-set payloads intentionally return false here;
        // their destination is the live toolbar owned by the window.
        add_removal_drop_target (this, this);
        rebuild_palette ();
    }

    /* Refresh installed-state dimming after the live toolbar accepts a drop. */
    public void sync_layout (string serialized_layout) {
        var next = ToolbarLayout.parse (serialized_layout);
        string current_serialized = ToolbarLayout.serialize (items);
        string next_serialized = ToolbarLayout.serialize (next);
        if (current_serialized == next_serialized) return;
        items = next;
        rebuild_palette ();
    }

    /* External settings changes update the menu without feeding a signal back. */
    public void sync_display_mode (string mode) {
        string normalized = normalize_display_mode (mode);
        display_mode = normalized;
        if (display_mode_selector == null) return;

        uint selected = index_for_mode (normalized);
        if (display_mode_selector.selected == selected) return;
        syncing_display_mode = true;
        display_mode_selector.selected = selected;
        syncing_display_mode = false;
    }

    public void focus_done_button () {
        done_button.grab_focus ();
    }

    public void refresh_theme () {
        sync_theme_class ();
    }

    /* Escape should cancel an in-flight palette/default drag without closing
     * the customization sheet. */
    public bool cancel_active_drag () {
        var source = active_drag_source;
        if (source == null) return false;
        source.cancel ();
        return true;
    }

    public void begin_live_toolbar_drag () {
        suppress_toolbar_removal = false;
    }

    public void suppress_live_toolbar_removal () {
        suppress_toolbar_removal = true;
    }

    private void sync_theme_class () {
        if (Adw.StyleManager.get_default ().dark)
            add_css_class ("toolbar-customization-dark");
        else
            remove_css_class ("toolbar-customization-dark");
    }

    private void rebuild_palette () {
        Gtk.Widget? child = palette.get_first_child ();
        while (child != null) {
            Gtk.Widget? next = child.get_next_sibling ();
            palette.remove (child);
            child = next;
        }

        foreach (var raw_id in ToolbarLayout.palette_items ()) {
            string id = raw_id;
            bool available = ToolbarLayout.is_repeatable (id) || !items.contains (id);
            palette.insert (build_palette_item (id, available), -1);
        }
    }

    private Gtk.Widget build_palette_item (string id, bool available) {
        var tile = new Gtk.Box (Gtk.Orientation.VERTICAL, 4);
        tile.halign = Gtk.Align.FILL;
        tile.valign = Gtk.Align.CENTER;
        tile.set_size_request (68, 42);
        tile.add_css_class ("toolbar-palette-item");
        tile.add_css_class ("toolbar-customization-tile");

        var badge = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        badge.halign = Gtk.Align.CENTER;
        badge.valign = Gtk.Align.CENTER;
        badge.add_css_class ("toolbar-palette-icon-badge");
        badge.add_css_class ("toolbar-customization-tile-icon");
        var icon = new Gtk.Image.from_icon_name (ToolbarLayout.icon_name (id));
        icon.pixel_size = 16;
        icon.halign = Gtk.Align.CENTER;
        icon.valign = Gtk.Align.CENTER;
        icon.add_css_class ("toolbar-palette-icon");
        badge.append (icon);
        tile.append (badge);

        var label = new Gtk.Label (ToolbarLayout.label (id));
        label.ellipsize = Pango.EllipsizeMode.END;
        label.width_chars = 8;
        label.max_width_chars = 8;
        label.halign = Gtk.Align.CENTER;
        label.add_css_class ("caption");
        tile.append (label);

        if (available) {
            tile.focusable = true;
            tile.tooltip_text = "Drag %s into the toolbar, or press Enter to add it".printf (
                ToolbarLayout.label (id));
            Accessibility.label (tile, "Drag %s into the toolbar, or press Enter to add it".printf (
                ToolbarLayout.label (id)));
            add_drag_source (this, tile, "palette|" + id, Gdk.DragAction.COPY,
                ToolbarLayout.icon_name (id));
            add_keyboard_activation (this, tile, "palette|" + id);
        } else {
            tile.sensitive = false;
            tile.opacity = 0.38;
            tile.add_css_class ("dim-label");
            tile.add_css_class ("toolbar-customization-tile-installed");
            tile.tooltip_text = "%s is already in the toolbar".printf (
                ToolbarLayout.label (id));
            Accessibility.label (tile, "%s is already in the toolbar".printf (
                ToolbarLayout.label (id)));
        }

        return tile;
    }

    private Gtk.Widget build_default_set () {
        string default_layout = ToolbarLayout.serialize (
            ToolbarLayout.parse (ToolbarLayout.DEFAULT_LAYOUT));

        var preview = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 3);
        preview.hexpand = true;
        preview.add_css_class ("toolbar-customization-default-strip");
        preview.focusable = true;
        preview.tooltip_text =
            "Drag the complete default set into the toolbar, or press Enter to restore it";
        Accessibility.label (preview,
            "Drag the complete default toolbar set, or press Enter to restore it");
        foreach (var id in ToolbarLayout.parse (default_layout))
            preview.append (build_default_preview_item (id));

        var scroller = new Gtk.ScrolledWindow ();
        scroller.set_policy (Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.NEVER);
        scroller.set_min_content_height (38);
        scroller.add_css_class ("toolbar-customization-default-scroller");
        scroller.child = preview;

        add_drag_source (this, preview, "default|" + default_layout,
            Gdk.DragAction.COPY);
        add_keyboard_activation (this, preview, "default|" + default_layout);
        return scroller;
    }

    private Gtk.Widget build_default_preview_item (string id) {
        var item = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        item.halign = Gtk.Align.CENTER;
        item.valign = Gtk.Align.CENTER;
        item.add_css_class ("toolbar-customization-default-item");
        item.tooltip_text = ToolbarLayout.label (id);
        Accessibility.label (item, ToolbarLayout.label (id));

        if (ToolbarLayout.is_flexible_space (id) || id == "space")
            item.set_size_request (id == "space" ? 26 : 40, -1);

        var icon = new Gtk.Image.from_icon_name (ToolbarLayout.icon_name (id));
        icon.pixel_size = 13;
        icon.halign = Gtk.Align.CENTER;
        icon.valign = Gtk.Align.CENTER;
        item.append (icon);
        return item;
    }

    private static void add_drag_source (ToolbarCustomizationDialog dialog,
                                         Gtk.Widget widget, string payload,
                                         Gdk.DragAction action,
                                         string? drag_icon_name = null) {
        var source = new Gtk.DragSource ();
        source.actions = action;
        source.propagation_phase = Gtk.PropagationPhase.CAPTURE;
        // The tile owns this source, and the source owns these closures. Weak
        // return edges let a palette rebuild release both immediately.
        weak ToolbarCustomizationDialog weak_dialog = dialog;
        weak Gtk.Widget weak_widget = widget;
        weak Gtk.DragSource weak_source = source;
        source.prepare.connect ((x, y) => {
            if (weak_widget == null || weak_source == null) return null;
            if (drag_icon_name != null) {
                var icon_theme = Gtk.IconTheme.get_for_display (
                    weak_widget.get_display ());
                var icon = icon_theme.lookup_icon (drag_icon_name, null, 24,
                    weak_widget.get_scale_factor (), weak_widget.get_direction (),
                    Gtk.IconLookupFlags.FORCE_SYMBOLIC);
                weak_source.set_icon (icon, 12, 12);
            } else {
                // The default set remains a compact preview of the complete
                // arrangement instead of being represented by one arbitrary
                // action icon.
                var paintable = new Gtk.WidgetPaintable (weak_widget);
                weak_source.set_icon (
                    paintable.get_current_image (), (int) x, (int) y);
            }
            Value value = Value (typeof (string));
            value.set_string (payload);
            return new Gdk.ContentProvider.for_value (value);
        });
        source.drag_begin.connect ((drag) => {
            if (weak_dialog == null || weak_widget == null || weak_source == null)
                return;
            weak_widget.add_css_class ("toolbar-dragging");
            weak_dialog.active_drag_source = weak_source;
            weak_dialog.drag_activity_changed (true);
        });
        source.drag_end.connect ((drag, delete_data) => {
            if (weak_widget != null)
                weak_widget.remove_css_class ("toolbar-dragging");
            if (weak_dialog == null) return;
            if (weak_dialog.active_drag_source == weak_source)
                weak_dialog.active_drag_source = null;
            weak_dialog.drag_activity_changed (false);
        });
        source.drag_cancel.connect ((drag, reason) => {
            // Gtk emits drag-end after this failure notification. Cleanup on
            // that single terminal edge so Done cannot destroy the source in
            // the interval between drag-cancel and drag-end.
            return false;
        });
        widget.add_controller (source);
    }

    private static void add_keyboard_activation (
            ToolbarCustomizationDialog dialog, Gtk.Widget widget,
            string payload) {
        var keys = new Gtk.EventControllerKey ();
        weak ToolbarCustomizationDialog weak_dialog = dialog;
        keys.key_pressed.connect ((keyval, keycode, state) => {
            if (keyval != Gdk.Key.Return && keyval != Gdk.Key.KP_Enter &&
                keyval != Gdk.Key.space) return false;
            Idle.add (() => {
                if (weak_dialog == null) return Source.REMOVE;
                string current = ToolbarLayout.serialize (weak_dialog.items);
                string next = current;
                if (payload.has_prefix ("palette|")) {
                    next = ToolbarLayout.insert_item (
                        current, payload.substring (8), weak_dialog.items.size);
                } else if (payload.has_prefix ("default|")) {
                    next = ToolbarLayout.serialize (ToolbarLayout.parse (
                        payload.substring (8)));
                }
                if (next != "" && next != current) {
                    weak_dialog.items = ToolbarLayout.parse (next);
                    weak_dialog.layout_changed (next);
                    weak_dialog.rebuild_palette ();
                }
                return Source.REMOVE;
            });
            return true;
        });
        widget.add_controller (keys);
    }

    private static void add_removal_drop_target (
            ToolbarCustomizationDialog dialog, Gtk.Widget widget) {
        var target = new Gtk.DropTarget (typeof (string), Gdk.DragAction.MOVE);
        target.preload = true;
        target.propagation_phase = Gtk.PropagationPhase.BUBBLE;
        weak ToolbarCustomizationDialog weak_dialog = dialog;
        weak Gtk.DropTarget weak_target = target;
        target.enter.connect ((x, y) => weak_target == null ?
            (Gdk.DragAction) 0 : removal_drop_action (weak_target));
        target.motion.connect ((x, y) => weak_target == null ?
            (Gdk.DragAction) 0 : removal_drop_action (weak_target));
        target.drop.connect ((value, x, y) => {
            if (weak_dialog == null) return false;
            string? payload = value.get_string ();
            if (payload == null) return false;
            string[] parts = payload.split ("|");
            if (parts.length < 3 || parts[0] != "toolbar") return false;
            if (weak_dialog.suppress_toolbar_removal) {
                weak_dialog.suppress_toolbar_removal = false;
                return true;
            }

            int index;
            if (!int.try_parse (parts[1], out index)) return false;
            if (index < 0 || index >= weak_dialog.items.size) return false;
            if (weak_dialog.items[index] != parts[2]) return false;
            if (weak_dialog.items.size <= 1) return false;

            weak_dialog.items.remove_at (index);
            weak_dialog.layout_changed (
                ToolbarLayout.serialize (weak_dialog.items));
            weak_dialog.rebuild_palette ();
            return true;
        });
        widget.add_controller (target);
    }

    private static Gdk.DragAction removal_drop_action (Gtk.DropTarget target) {
        unowned Value? value = target.get_value ();
        if (value == null) return (Gdk.DragAction) 0;
        string? payload = value.get_string ();
        return payload != null && payload.has_prefix ("toolbar|") ?
            Gdk.DragAction.MOVE : (Gdk.DragAction) 0;
    }

    private string normalize_display_mode (string mode) {
        switch (mode) {
        case "icons-text":
        case "text":
        case "icons": return mode;
        default: return "icons";
        }
    }

    private uint index_for_mode (string mode) {
        switch (mode) {
        case "icons-text": return 1;
        case "text": return 2;
        default: return 0;
        }
    }

    private string mode_for_index (uint index) {
        switch (index) {
        case 1: return "icons-text";
        case 2: return "text";
        default: return "icons";
        }
    }
}
}
