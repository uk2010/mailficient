namespace Mailficient {
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
        append (field_row ("To:", to_entry, recipient_buttons));
        append_separator ();

        cc_row = field_row ("Cc:", cc_entry, contact_button (cc_entry, "Choose a contact for Cc")); cc_row.visible = false; append (cc_row);
        var cc_separator = append_separator (); cc_separator.visible = false;
        cc_row.notify["visible"].connect (() => cc_separator.visible = cc_row.visible);

        bcc_row = field_row ("Bcc:", bcc_entry, contact_button (bcc_entry, "Choose a contact for Bcc")); bcc_row.visible = false; append (bcc_row);
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
