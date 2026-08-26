namespace Mailficient {
internal class RecipientChipField : Gtk.Box {
    private Gtk.Entry entry;
    private Gtk.Box chips = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 4);

    public RecipientChipField (Gtk.Entry entry) {
        Object (orientation: Gtk.Orientation.HORIZONTAL, spacing: 0);
        this.entry = entry;
        hexpand = true;
        add_css_class ("recipient-chip-field");
        var overlay = new Gtk.Overlay ();
        overlay.hexpand = true;
        overlay.set_child (entry);
        chips.hexpand = true;
        chips.valign = Gtk.Align.CENTER;
        chips.set_margin_start (4);
        chips.set_margin_end (4);
        chips.overflow = Gtk.Overflow.HIDDEN;
        chips.add_css_class ("recipient-chip-strip");
        overlay.add_overlay (chips);
        append (overlay);

        var click = new Gtk.GestureClick ();
        click.released.connect ((presses, x, y) => {
            entry.grab_focus ();
            entry.set_position (-1);
        });
        chips.add_controller (click);
        entry.changed.connect (refresh);
        entry.notify["has-focus"].connect (refresh);
        refresh ();
    }

    private void refresh () {
        while (chips.get_first_child () != null)
            chips.remove ((Gtk.Widget) chips.get_first_child ());
        bool show_chips = !entry.has_focus && entry.text.strip () != "";
        Gee.List<Recipient>? recipients = null;
        if (show_chips) {
            try { recipients = RecipientParser.parse (entry.text); }
            catch (Error error) { show_chips = false; }
        }
        if (show_chips && recipients != null) {
            int visible_count = int.min (2, recipients.size);
            for (int index = 0; index < visible_count; index++)
                chips.append (recipient_chip (recipients[index]));
            if (recipients.size > visible_count) {
                var more = new Gtk.Label ("+%d".printf (recipients.size - visible_count));
                more.tooltip_text = "%d more recipients".printf (recipients.size - visible_count);
                more.add_css_class ("recipient-chip-more");
                chips.append (more);
            }
        }
        chips.visible = show_chips;
        entry.opacity = show_chips ? 0 : 1;
    }

    private Gtk.Widget recipient_chip (Recipient recipient) {
        var chip = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 3);
        chip.add_css_class ("recipient-chip");
        chip.tooltip_text = recipient.formatted ();
        var label = new Gtk.Label (recipient.name == "" ? recipient.address : recipient.name);
        label.max_width_chars = 18;
        label.ellipsize = Pango.EllipsizeMode.END;
        chip.append (label);
        var remove = new Gtk.Button.from_icon_name ("window-close-symbolic");
        remove.add_css_class ("flat");
        remove.add_css_class ("recipient-chip-remove");
        remove.tooltip_text = "Remove " + recipient.formatted ();
        Accessibility.label (remove, "Remove recipient " + recipient.formatted ());
        string address = recipient.address;
        remove.clicked.connect (() => remove_recipient (address));
        chip.append (remove);
        return chip;
    }

    private void remove_recipient (string address) {
        try {
            var recipients = RecipientParser.parse (entry.text);
            var remaining = new StringBuilder ();
            bool removed = false;
            foreach (var recipient in recipients) {
                if (!removed && recipient.address == address) {
                    removed = true;
                    continue;
                }
                if (remaining.len > 0) remaining.append (", ");
                remaining.append (recipient.formatted ());
            }
            string next = remaining.str;
            Idle.add (() => {
                entry.text = next;
                return Source.REMOVE;
            });
        } catch (Error error) {
            entry.grab_focus ();
        }
    }
}

internal class ComposeHeader : Gtk.Box {
    public signal void contacts_requested (Gtk.Entry entry);
    private Gtk.Entry cc_entry;
    private Gtk.Entry bcc_entry;
    private Gtk.Widget cc_row;
    private Gtk.Widget bcc_row;
    private Gtk.Button cc_button = new Gtk.Button.with_label ("Cc");
    private Gtk.Button bcc_button = new Gtk.Button.with_label ("Bcc");

    public ComposeHeader (Gtk.Widget from_selector, Gtk.Entry to_entry, Gtk.Entry cc_entry,
                          Gtk.Entry bcc_entry, Gtk.Entry subject_entry) {
        Object (orientation: Gtk.Orientation.VERTICAL, spacing: 0);
        this.cc_entry = cc_entry;
        this.bcc_entry = bcc_entry;
        add_css_class ("compose-header-fields");

        prepare_entry (to_entry, "Recipients");
        prepare_entry (cc_entry, "Carbon copy recipients");
        prepare_entry (bcc_entry, "Blind carbon copy recipients");
        prepare_entry (subject_entry, "Message subject");
        subject_entry.add_css_class ("compose-subject-entry");
        from_selector.hexpand = true;
        from_selector.add_css_class ("compose-from-selector");

        append (field_row ("From:", from_selector));
        append_separator ();

        var recipient_buttons = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        var contacts_button = new Gtk.Button.with_label ("Contacts");
        configure_reveal_button (contacts_button, "Choose a contact for To");
        contacts_button.clicked.connect (() => contacts_requested (to_entry));
        configure_reveal_button (cc_button, "Show Cc field");
        configure_reveal_button (bcc_button, "Show Bcc field");
        recipient_buttons.append (contacts_button); recipient_buttons.append (cc_button); recipient_buttons.append (bcc_button);
        append (field_row ("To:", new RecipientChipField (to_entry), recipient_buttons));
        append_separator ();

        cc_row = field_row ("Cc:", new RecipientChipField (cc_entry), contact_button (cc_entry, "Choose a contact for Cc")); cc_row.visible = false; append (cc_row);
        var cc_separator = append_separator (); cc_separator.visible = false;
        cc_row.notify["visible"].connect (() => cc_separator.visible = cc_row.visible);

        bcc_row = field_row ("Bcc:", new RecipientChipField (bcc_entry), contact_button (bcc_entry, "Choose a contact for Bcc")); bcc_row.visible = false; append (bcc_row);
        var bcc_separator = append_separator (); bcc_separator.visible = false;
        bcc_row.notify["visible"].connect (() => bcc_separator.visible = bcc_row.visible);

        append (field_row ("Subject:", subject_entry));

        cc_button.clicked.connect (() => reveal_cc (true));
        bcc_button.clicked.connect (() => reveal_bcc (true));
        cc_entry.changed.connect (() => { if (cc_entry.text != "") reveal_cc (false); });
        bcc_entry.changed.connect (() => { if (bcc_entry.text != "") reveal_bcc (false); });
    }

    private static void prepare_entry (Gtk.Entry entry, string accessible_name) {
        entry.has_frame = false;
        entry.hexpand = true;
        entry.add_css_class ("compose-line-entry");
        Accessibility.label (entry, accessible_name);
    }

    private static Gtk.Widget field_row (string title, Gtk.Widget field, Gtk.Widget? suffix = null) {
        var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        row.add_css_class ("compose-field-row");
        var label = new Gtk.Label (title);
        label.xalign = 0; label.valign = Gtk.Align.CENTER;
        label.width_chars = 8; label.add_css_class ("compose-field-label");
        row.append (label); row.append (field);
        if (suffix != null) row.append (suffix);
        return row;
    }

    private Gtk.Separator append_separator () {
        var separator = new Gtk.Separator (Gtk.Orientation.HORIZONTAL);
        separator.add_css_class ("compose-field-separator"); append (separator); return separator;
    }

    private static void configure_reveal_button (Gtk.Button button, string accessible_name) {
        button.add_css_class ("flat"); button.add_css_class ("compose-recipient-reveal");
        button.valign = Gtk.Align.CENTER; Accessibility.label (button, accessible_name);
    }

    private Gtk.Button contact_button (Gtk.Entry entry, string accessible_name) {
        var button = new Gtk.Button.from_icon_name ("contact-new-symbolic");
        button.tooltip_text = accessible_name; configure_reveal_button (button, accessible_name);
        button.clicked.connect (() => contacts_requested (entry)); return button;
    }

    private void reveal_cc (bool focus) {
        cc_row.visible = true; cc_button.visible = false;
        if (focus) cc_entry.grab_focus ();
    }

    private void reveal_bcc (bool focus) {
        bcc_row.visible = true; bcc_button.visible = false;
        if (focus) bcc_entry.grab_focus ();
    }
}
}
