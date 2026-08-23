namespace Mailficient {
public class MessageRow : Gtk.Box {
    public Message message { get; construct; }
    private weak Gtk.SelectionModel? context_selection;
    private uint model_position;
    private ulong selection_handler;
    private MenuItem? read_menu_item;
    private Gtk.Widget? unread_dot;

    public MessageRow (Message message, Gtk.SelectionModel? context_selection = null,
                       uint model_position = 0, bool multiple = false) {
        Object (message: message, orientation: Gtk.Orientation.VERTICAL);
        this.context_selection = context_selection;
        this.model_position = model_position;
        add_css_class ("message-row");
        message.notify["unread"].connect (update_unread_style);
        update_unread_style ();
        accessible_role = Gtk.AccessibleRole.LIST_ITEM;

        var outer = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        if (multiple && context_selection != null) {
            var selector = new Gtk.CheckButton ();
            selector.valign = Gtk.Align.CENTER;
            selector.active = context_selection.is_selected (model_position);
            selector.tooltip_text = "Select this message";
            Accessibility.label (selector, "Select %s".printf (message.subject));
            weak Gtk.SelectionModel? row_selection = context_selection;
            weak Gtk.CheckButton weak_selector = selector;
            uint row_position = model_position;
            bool syncing_selector = false;
            selector.toggled.connect (() => {
                if (syncing_selector || row_selection == null || weak_selector == null) return;
                var selected = new Gtk.Bitset.empty ();
                var mask = new Gtk.Bitset.range (row_position, 1);
                if (weak_selector.active) selected.add (row_position);
                row_selection.set_selection (selected, mask);
            });
            selection_handler = context_selection.selection_changed.connect ((position, count) => {
                if (weak_selector != null && position <= row_position &&
                    row_position < position + count && row_selection != null) {
                    syncing_selector = true;
                    weak_selector.active = row_selection.is_selected (row_position);
                    syncing_selector = false;
                }
            });
            outer.append (selector);
        }
        var unread_indicator = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        unread_indicator.add_css_class ("unread-indicator-slot");
        unread_dot = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        unread_dot.add_css_class ("unread-indicator-dot");
        unread_dot.valign = Gtk.Align.CENTER;
        unread_dot.visible = message.unread;
        unread_indicator.append (unread_dot);
        outer.append (unread_indicator);
        var avatar = new Adw.Avatar (32, message.initials (), false); avatar.add_css_class ("sender-avatar"); outer.append (avatar);
        var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 2); content.hexpand = true;
        var top = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
        var sender = new Gtk.Label (message.sender_name); sender.xalign = 0; sender.hexpand = true; sender.ellipsize = Pango.EllipsizeMode.END; sender.add_css_class ("sender"); top.append (sender);
        if (message.flagged) {
            var flag = new Gtk.Image.from_icon_name ("mailficient-flag-symbolic");
            flag.add_css_class ("flag-" + message.flag_color);
            flag.tooltip_text = "%s flag".printf (flag_color_label (message.flag_color));
            top.append (flag);
        }
        var time = new Gtk.Label (message.timestamp); time.add_css_class ("timestamp");
        time.set_size_request (68, -1); time.xalign = 1;
        top.append (time);
        content.append (top);
        var subject_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 5);
        var subject = new Gtk.Label (message.subject); subject.xalign = 0; subject.hexpand = true; subject.ellipsize = Pango.EllipsizeMode.END; subject.add_css_class ("subject"); subject_box.append (subject);
        if (message.conversation_count > 1) { var count = new Gtk.Label (message.conversation_count.to_string ()); count.add_css_class ("dim-label"); count.add_css_class ("conversation-count"); subject_box.append (count); }
        if (message.has_attachment) {
            var attachment = new Gtk.Image.from_icon_name ("mail-attachment-symbolic");
            attachment.add_css_class ("message-meta-icon");
            attachment.tooltip_text = "Has attachment";
            subject_box.append (attachment);
        }
        content.append (subject_box);
        var preview = new Gtk.Label (message.preview); preview.xalign = 0; preview.ellipsize = Pango.EllipsizeMode.END; preview.add_css_class ("preview"); content.append (preview);
        outer.append (content);
        append (outer);
        tooltip_text = "%s — %s".printf (message.sender_name, message.subject);
        var accessible = new StringBuilder (message.unread ? "Unread message" : "Read message");
        accessible.append (" from ").append (message.sender_name).append (", subject ").append (message.subject);
        if (message.timestamp != "") accessible.append (", ").append (message.timestamp);
        if (message.flagged) accessible.append_printf (", %s flag", flag_color_label (message.flag_color).down ());
        if (message.has_attachment) accessible.append (", has attachment");
        if (message.conversation_count > 1) accessible.append_printf (", %u messages in conversation", message.conversation_count);
        Accessibility.label (this, accessible.str);

        var menu = new Menu (); menu.append ("Reply", "win.reply"); menu.append ("Reply All", "win.reply-all");
        menu.append ("Forward", "win.forward"); menu.append ("Archive", "win.archive");
        menu.append ("Move or Copy…", "win.show-move");
        read_menu_item = new MenuItem (message.unread ? "Mark as Read" : "Mark as Unread", "win.toggle-read");
        menu.append_item (read_menu_item);
        menu.append ("Flag or Unflag", "win.flag");
        var flag_colors = new Menu ();
        flag_colors.append ("Orange", "win.set-flag-color::orange");
        flag_colors.append ("Red", "win.set-flag-color::red");
        flag_colors.append ("Purple", "win.set-flag-color::purple");
        flag_colors.append ("Blue", "win.set-flag-color::blue");
        flag_colors.append ("Yellow", "win.set-flag-color::yellow");
        flag_colors.append ("Green", "win.set-flag-color::green");
        flag_colors.append ("Gray", "win.set-flag-color::gray");
        flag_colors.append ("Clear Flag", "win.clear-flag");
        menu.append_submenu ("Flag Color", flag_colors);
        menu.append ("Labels…", "win.labels");
        menu.append ("Snooze…", "win.snooze");
        menu.append ("Export Message…", "win.export-message"); menu.append ("Print…", "win.print-message");
        var popover = new Gtk.PopoverMenu.from_model (menu); popover.set_parent (this); popover.has_arrow = false;
        var context_click = new Gtk.GestureClick (); context_click.button = Gdk.BUTTON_SECONDARY;
        weak Gtk.SelectionModel? row_selection = context_selection;
        uint row_position = model_position;
        context_click.pressed.connect ((count, x, y) => {
            // Right-clicking anywhere inside an existing range must preserve
            // the range so the chosen action applies to every selected item.
            if (row_selection != null && !row_selection.is_selected (row_position))
                row_selection.select_item (row_position, true);
            popover.pointing_to = { (int) x, (int) y, 1, 1 }; popover.popup ();
        });
        add_controller (context_click);
    }

    public void unbind_selection () {
        if (selection_handler != 0 && context_selection != null)
            context_selection.disconnect (selection_handler);
        selection_handler = 0;
        context_selection = null;
    }

    private void update_unread_style () {
        if (message.unread) add_css_class ("unread");
        else remove_css_class ("unread");
        if (unread_dot != null) unread_dot.visible = message.unread;
        if (read_menu_item != null) read_menu_item.set_label (message.unread ? "Mark as Read" : "Mark as Unread");
    }

    private static string flag_color_label (string color) {
        switch (color) {
        case "orange": return "Orange";
        case "purple": return "Purple";
        case "blue": return "Blue";
        case "yellow": return "Yellow";
        case "green": return "Green";
        case "gray": return "Gray";
        default: return "Red";
        }
    }
}
}
