namespace Mailficient {
public class MessageRow : Gtk.Box {
    public const string DRAG_PAYLOAD_PREFIX = "mailficient-message-ids:\n";
    public signal void reopen_requested (Message message);
    public Message message { get; construct; }
    private weak Gtk.SelectionModel? context_selection;
    // Gtk.ListView keeps a ListItem bound while rows before it are removed,
    // and updates ListItem.position in place.  Keeping a numeric copy here
    // leaves selection styling attached to the row's old position.
    private weak Gtk.ListItem? context_item;
    private ulong selection_handler;
    private ulong position_handler;
    private ulong unread_handler;
    private ulong flagged_handler;
    private ulong flag_color_handler;
    private MenuItem? read_menu_item;
    private Gtk.Widget? unread_dot;
    private Gtk.Image? flag_icon;
    private Gtk.CheckButton? selection_checkbox;
    private bool syncing_selection_checkbox;

    public MessageRow (Message message, Gtk.SelectionModel? context_selection = null,
                       Gtk.ListItem? context_item = null, bool multiple = false) {
        Object (message: message, orientation: Gtk.Orientation.VERTICAL);
        this.context_selection = context_selection;
        this.context_item = context_item;
        add_css_class ("message-row");
        unread_handler = message.notify["unread"].connect (update_unread_style);
        flagged_handler = message.notify["flagged"].connect (update_flag_style);
        flag_color_handler = message.notify["flag-color"].connect (update_flag_style);
        update_unread_style ();
        accessible_role = Gtk.AccessibleRole.LIST_ITEM;

        var outer = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10);
        outer.add_css_class ("message-row-shell");
        outer.valign = Gtk.Align.CENTER;
        if (multiple && context_selection != null) {
            var selector = new Gtk.CheckButton ();
            selection_checkbox = selector;
            selector.valign = Gtk.Align.CENTER;
            selector.active = context_selection.is_selected (current_position ());
            selector.tooltip_text = "Select this message";
            Accessibility.label (selector, "Select %s".printf (message.subject));
            weak Gtk.SelectionModel? row_selection = context_selection;
            weak Gtk.CheckButton weak_selector = selector;
            weak MessageRow weak_row = this;
            selector.toggled.connect (() => {
                if (weak_row == null || weak_row.syncing_selection_checkbox ||
                    row_selection == null || weak_selector == null) return;
                uint row_position = weak_row.current_position ();
                if (row_position == Gtk.INVALID_LIST_POSITION) return;
                var selected = new Gtk.Bitset.empty ();
                var mask = new Gtk.Bitset.range (row_position, 1);
                if (weak_selector.active) selected.add (row_position);
                row_selection.set_selection (selected, mask);
            });
            outer.append (selector);
        }

        if (context_selection != null) {
            weak MessageRow weak_row = this;
            selection_handler = context_selection.selection_changed.connect ((position, count) => {
                if (weak_row == null) return;
                uint row_position = weak_row.current_position ();
                if (position <= row_position && row_position < position + count)
                    weak_row.sync_selection_style ();
            });
        }
        if (context_item != null) {
            weak MessageRow weak_row = this;
            position_handler = context_item.notify["position"].connect (() => {
                if (weak_row != null) weak_row.sync_selection_style ();
            });
        }

        // Keep the unread marker attached to the sender identity instead of
        // spending a permanent column on an empty dot for every read message.
        var avatar_overlay = new Gtk.Overlay ();
        avatar_overlay.valign = Gtk.Align.CENTER;
        var avatar = new Gtk.Button.with_label (message.initials ());
        avatar.set_size_request (34, 34);
        avatar.halign = Gtk.Align.CENTER;
        avatar.valign = Gtk.Align.CENTER;
        avatar.focusable = false;
        avatar.can_target = false;
        avatar.add_css_class ("sender-avatar");
        avatar.add_css_class ("circular");
        avatar.add_css_class ("avatar-tone-%u".printf (
            str_hash (message.sender_address) % 6));
        avatar_overlay.child = avatar;
        unread_dot = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        unread_dot.add_css_class ("unread-indicator-dot");
        unread_dot.halign = Gtk.Align.START;
        unread_dot.valign = Gtk.Align.START;
        unread_dot.tooltip_text = "Unread message";
        unread_dot.visible = message.unread;
        avatar_overlay.add_overlay (unread_dot);
        outer.append (avatar_overlay);
        var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 3);
        content.hexpand = true;
        content.add_css_class ("message-row-content");
        var top = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
        top.add_css_class ("message-sender-line");
        var sender = new Gtk.Label (message.sender_name);
        sender.xalign = 0; sender.hexpand = true;
        sender.ellipsize = Pango.EllipsizeMode.END;
        sender.tooltip_text = "%s <%s>".printf (message.sender_name, message.sender_address);
        sender.add_css_class ("sender"); top.append (sender);
        flag_icon = new Gtk.Image.from_icon_name ("mailficient-flag-symbolic");
        top.append (flag_icon);
        update_flag_style ();
        var time = new Gtk.Label (message.timestamp); time.add_css_class ("timestamp");
        time.set_size_request (62, -1); time.xalign = 1;
        top.append (time);
        content.append (top);
        var subject_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 5);
        subject_box.add_css_class ("message-subject-line");
        string subject_text = message.subject.strip () == "" ? "(No Subject)" : message.subject;
        var subject = new Gtk.Label (subject_text);
        subject.xalign = 0; subject.hexpand = true;
        subject.ellipsize = Pango.EllipsizeMode.END;
        subject.tooltip_text = subject_text;
        subject.add_css_class ("subject"); subject_box.append (subject);
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
        sync_selection_style ();
        tooltip_text = "%s — %s".printf (message.sender_name, message.subject);
        update_accessible_label ();

        var menu = new Menu ();
        var replies = new Menu ();
        replies.append ("Reply", "win.reply");
        replies.append ("Reply All", "win.reply-all");
        replies.append ("Forward", "win.forward");
        menu.append_section (null, replies);

        var filing = new Menu ();
        filing.append ("Archive", "win.archive");
        filing.append ("Delete", "win.trash");
        filing.append ("Junk or Not Junk", "win.junk");
        filing.append ("Move or Copy…", "win.show-move");
        menu.append_section (null, filing);

        var state = new Menu ();
        read_menu_item = new MenuItem (message.unread ? "Mark as Read" : "Mark as Unread", "win.toggle-read");
        state.append_item (read_menu_item);
        state.append ("Flag or Unflag", "win.flag");
        var flag_colors = new Menu ();
        flag_colors.append ("Orange", "win.set-flag-color::orange");
        flag_colors.append ("Red", "win.set-flag-color::red");
        flag_colors.append ("Purple", "win.set-flag-color::purple");
        flag_colors.append ("Blue", "win.set-flag-color::blue");
        flag_colors.append ("Yellow", "win.set-flag-color::yellow");
        flag_colors.append ("Green", "win.set-flag-color::green");
        flag_colors.append ("Gray", "win.set-flag-color::gray");
        flag_colors.append ("Clear Flag", "win.clear-flag");
        state.append_submenu ("Flag Color", flag_colors);
        state.append ("Labels…", "win.labels");
        state.append ("Snooze…", "win.snooze");
        menu.append_section (null, state);

        var automation = new Menu ();
        automation.append ("Create Rule from Sender…", "win.create-rule-from-message");
        automation.append ("Apply Rules", "win.apply-rules");
        menu.append_section (null, automation);

        var output = new Menu ();
        output.append ("Export Message…", "win.export-message");
        output.append ("Print…", "win.print-message");
        menu.append_section (null, output);
        var popover = new Gtk.PopoverMenu.from_model (menu); popover.set_parent (this); popover.has_arrow = false;
        var context_click = new Gtk.GestureClick (); context_click.button = Gdk.BUTTON_SECONDARY;
        weak Gtk.SelectionModel? row_selection = context_selection;
        weak MessageRow weak_row = this;
        context_click.pressed.connect ((count, x, y) => {
            // Right-clicking anywhere inside an existing range must preserve
            // the range so the chosen action applies to every selected item.
            uint row_position = weak_row == null ? Gtk.INVALID_LIST_POSITION :
                weak_row.current_position ();
            if (row_position != Gtk.INVALID_LIST_POSITION && row_selection != null &&
                !row_selection.is_selected (row_position))
                row_selection.select_item (row_position, true);
            // Refresh the action label from the row's current state before
            // showing the menu. This also covers a row whose read state was
            // changed while its popover was not open.
            update_unread_style ();
            popover.pointing_to = { (int) x, (int) y, 1, 1 }; popover.popup ();
        });
        add_controller (context_click);

        var drag_source = new Gtk.DragSource ();
        drag_source.actions = Gdk.DragAction.MOVE | Gdk.DragAction.COPY;
        drag_source.propagation_phase = Gtk.PropagationPhase.CAPTURE;
        drag_source.prepare.connect ((x, y) => {
            uint row_position = weak_row == null ? Gtk.INVALID_LIST_POSITION :
                weak_row.current_position ();
            if (row_position != Gtk.INVALID_LIST_POSITION && row_selection != null &&
                !row_selection.is_selected (row_position))
                row_selection.select_item (row_position, true);

            var payload = new StringBuilder (DRAG_PAYLOAD_PREFIX);
            int included = 0;
            if (row_selection != null) {
                var selected = row_selection.get_selection ();
                Gtk.BitsetIter iterator = Gtk.BitsetIter ();
                uint position;
                if (iterator.init_first (selected, out position)) {
                    do {
                        var selected_message = row_selection.get_item (position) as Message;
                        if (selected_message == null) continue;
                        if (included++ > 0) payload.append_c ('\n');
                        payload.append (selected_message.id);
                    } while (iterator.next (out position));
                }
            }
            if (included == 0) payload.append (message.id);
            Value value = Value (typeof (string));
            value.set_string (payload.str);
            return new Gdk.ContentProvider.for_value (value);
        });
        add_controller (drag_source);

        var primary_click = new Gtk.GestureClick (); primary_click.button = Gdk.BUTTON_PRIMARY;
        primary_click.released.connect ((count, x, y) => {
            // Gtk does not emit selection-changed when the already-selected
            // row is clicked again. That is the normal way to reopen a
            // message that was manually marked unread.
            uint row_position = weak_row == null ? Gtk.INVALID_LIST_POSITION :
                weak_row.current_position ();
            if (!multiple && context_selection != null &&
                row_position != Gtk.INVALID_LIST_POSITION &&
                context_selection.is_selected (row_position))
                reopen_requested (message);
        });
        add_controller (primary_click);
    }

    public void unbind_selection () {
        if (selection_handler != 0 && context_selection != null)
            context_selection.disconnect (selection_handler);
        selection_handler = 0;
        if (position_handler != 0 && context_item != null)
            context_item.disconnect (position_handler);
        position_handler = 0;
        context_selection = null;
        context_item = null;
        selection_checkbox = null;
        remove_css_class ("selected-message");
        unset_state_flags (Gtk.StateFlags.SELECTED);
        if (unread_handler != 0) message.disconnect (unread_handler);
        unread_handler = 0;
        if (flagged_handler != 0) message.disconnect (flagged_handler);
        flagged_handler = 0;
        if (flag_color_handler != 0) message.disconnect (flag_color_handler);
        flag_color_handler = 0;
    }

    // The repository may hand the window a separate Message instance from
    // the one currently bound to this row. Keep the visible indicator
    // authoritative when the message is opened.
    public void set_read_in_place (bool read) {
        message.unread = !read;
        update_unread_style ();
    }

    public void set_flag_in_place (bool flagged, string color = "") {
        message.flagged = flagged;
        if (color != "") message.flag_color = color;
        update_flag_style ();
    }

    ~MessageRow () {
        if (position_handler != 0 && context_item != null)
            context_item.disconnect (position_handler);
        if (unread_handler != 0) message.disconnect (unread_handler);
        if (flagged_handler != 0) message.disconnect (flagged_handler);
        if (flag_color_handler != 0) message.disconnect (flag_color_handler);
    }

    private void update_unread_style () {
        if (message.unread) add_css_class ("unread");
        else remove_css_class ("unread");
        if (unread_dot != null) unread_dot.visible = message.unread;
        if (read_menu_item != null) read_menu_item.set_label (message.unread ? "Mark as Read" : "Mark as Unread");
        update_accessible_label ();
    }

    private void sync_selection_style () {
        uint model_position = current_position ();
        bool selected = context_selection != null &&
            model_position != Gtk.INVALID_LIST_POSITION &&
            context_selection.is_selected (model_position);
        if (selected) {
            add_css_class ("selected-message");
            set_state_flags (Gtk.StateFlags.SELECTED, false);
        } else {
            remove_css_class ("selected-message");
            unset_state_flags (Gtk.StateFlags.SELECTED);
        }
        if (selection_checkbox != null && selection_checkbox.active != selected) {
            syncing_selection_checkbox = true;
            selection_checkbox.active = selected;
            syncing_selection_checkbox = false;
        }
    }

    private uint current_position () {
        return context_item == null ? Gtk.INVALID_LIST_POSITION : context_item.position;
    }

    internal bool qa_selection_style_matches () {
        uint position = current_position ();
        bool selected = context_selection != null &&
            position != Gtk.INVALID_LIST_POSITION &&
            context_selection.is_selected (position);
        return selected == has_css_class ("selected-message");
    }

    internal bool qa_has_selection_style () {
        return has_css_class ("selected-message");
    }

    private void update_flag_style () {
        if (flag_icon == null) return;
        foreach (var color in new string[] { "orange", "red", "purple", "blue", "yellow", "green", "gray" })
            flag_icon.remove_css_class ("flag-" + color);
        flag_icon.add_css_class ("flag-" + message.flag_color);
        flag_icon.visible = message.flagged;
        flag_icon.tooltip_text = "%s flag".printf (flag_color_label (message.flag_color));
        update_accessible_label ();
    }

    private void update_accessible_label () {
        var accessible = new StringBuilder (message.unread ? "Unread message" : "Read message");
        accessible.append (" from ").append (message.sender_name).append (", subject ").append (message.subject);
        if (message.timestamp != "") accessible.append (", ").append (message.timestamp);
        if (message.flagged) accessible.append_printf (", %s flag", flag_color_label (message.flag_color).down ());
        if (message.has_attachment) accessible.append (", has attachment");
        if (message.conversation_count > 1)
            accessible.append_printf (", %u messages in conversation", message.conversation_count);
        Accessibility.label (this, accessible.str);
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
