namespace Mailficient {
public class RecipientCompletionController : Object {
    public string account_id { get; set; default = ""; }
    private Gtk.Entry entry;
    private RecipientCompletionService service;
    private Gtk.Popover popover = new Gtk.Popover ();
    private Gtk.ListBox list = new Gtk.ListBox ();
    private bool applying;
    private uint lookup_generation;
    private uint lookup_source;
    private Cancellable? lookup_cancellable;

    public RecipientCompletionController (Gtk.Entry entry, RecipientCompletionService service,
                                          string account_id) {
        this.entry = entry; this.service = service; this.account_id = account_id;
        popover.set_parent (entry); popover.has_arrow = false; popover.autohide = false;
        popover.add_css_class ("recipient-popover");
        popover.position = Gtk.PositionType.BOTTOM;
        list.selection_mode = Gtk.SelectionMode.SINGLE; list.add_css_class ("recipient-suggestions");
        list.row_activated.connect ((row) => activate_row (row)); popover.child = list;
        entry.changed.connect (update_suggestions);
        entry.notify["has-focus"].connect (() => {
            if (entry.has_focus) update_suggestions ();
            else Idle.add (() => {
                var root = entry.get_root (); var focused = root == null ? null : root.get_focus ();
                if (focused == null || (!focused.is_ancestor (popover) && focused != entry)) popover.popdown ();
                return Source.REMOVE;
            });
        });
        var keys = new Gtk.EventControllerKey ();
        keys.key_pressed.connect ((keyval, keycode, state) => {
            if (keyval == Gdk.Key.Down && popover.visible) {
                var first = list.get_row_at_index (0);
                if (first != null) { list.select_row (first); first.grab_focus (); }
                return true;
            }
            if (keyval == Gdk.Key.Escape && popover.visible) { popover.popdown (); return true; }
            return false;
        });
        entry.add_controller (keys);
        var list_keys = new Gtk.EventControllerKey ();
        list_keys.key_pressed.connect ((keyval, keycode, state) => {
            if (keyval == Gdk.Key.Escape) {
                popover.popdown (); entry.grab_focus (); return true;
            }
            return false;
        });
        list.add_controller (list_keys);
    }

    public void refresh () { update_suggestions (); }

    private void update_suggestions () {
        if (applying || !entry.get_mapped ()) return;
        lookup_generation++;
        if (lookup_source != 0) { Source.remove (lookup_source); lookup_source = 0; }
        if (lookup_cancellable != null) lookup_cancellable.cancel ();
        render_suggestions (service.suggest (entry.text, entry.get_position (), account_id));
        if (!service.has_address_book ||
            RecipientCompletionService.fragment (entry.text, entry.get_position ()).length < 2) return;
        uint generation = lookup_generation;
        lookup_cancellable = new Cancellable ();
        var cancellable = lookup_cancellable;
        lookup_source = Timeout.add (150, () => {
            lookup_source = 0;
            update_contact_suggestions.begin (generation, cancellable);
            return Source.REMOVE;
        });
    }

    private async void update_contact_suggestions (uint generation, Cancellable cancellable) {
        try {
            var suggestions = yield service.suggest_with_contacts (entry.text,
                entry.get_position (), account_id, 6, cancellable);
            if (generation != lookup_generation || cancellable.is_cancelled () || !entry.has_focus) return;
            render_suggestions (suggestions);
        } catch (Error error) {
            if (!(error is IOError.CANCELLED))
                warning ("Could not load GNOME contact suggestions: %s", error.message);
        }
    }

    private void render_suggestions (Gee.List<Recipient> suggestions) {
        Gtk.ListBoxRow? existing;
        while ((existing = list.get_row_at_index (0)) != null) list.remove (existing);
        if (suggestions.size == 0) { popover.popdown (); return; }
        foreach (var recipient in suggestions) list.append (suggestion_row (recipient));
        popover.set_size_request (entry.get_width (), -1); popover.popup ();
    }

    private Gtk.ListBoxRow suggestion_row (Recipient recipient) {
        var row = new Gtk.ListBoxRow (); row.set_data<Recipient> ("recipient", recipient);
        var content = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10);
        content.set_margin_top (7); content.set_margin_bottom (7); content.set_margin_start (10); content.set_margin_end (10);
        content.append (new Adw.Avatar (30, initials (recipient), false));
        var labels = new Gtk.Box (Gtk.Orientation.VERTICAL, 1); labels.hexpand = true;
        var name = new Gtk.Label (recipient.name == "" ? recipient.address : recipient.name);
        name.xalign = 0; name.ellipsize = Pango.EllipsizeMode.END; labels.append (name);
        if (recipient.name != "") {
            var address = new Gtk.Label (recipient.address); address.xalign = 0;
            address.add_css_class ("dim-label"); address.ellipsize = Pango.EllipsizeMode.END; labels.append (address);
        }
        content.append (labels); row.child = content;
        Accessibility.label (row, "Complete recipient %s".printf (recipient.formatted ()));
        return row;
    }

    private void activate_row (Gtk.ListBoxRow row) {
        var recipient = row.get_data<Recipient> ("recipient"); if (recipient == null) return;
        applying = true; int position;
        entry.text = RecipientCompletionService.complete (entry.text, entry.get_position (), recipient, out position);
        entry.set_position (position); applying = false; popover.popdown (); entry.grab_focus ();
    }

    private static string initials (Recipient recipient) {
        string source = recipient.name == "" ? recipient.address : recipient.name;
        var result = new StringBuilder (); int count = 0;
        foreach (var part in source.split (" ")) {
            string clean = part.strip (); if (clean == "") continue;
            result.append_unichar (clean.get_char ());
            if (++count >= 2) break;
        }
        return result.str.up ();
    }

    ~RecipientCompletionController () {
        if (lookup_source != 0) Source.remove (lookup_source);
        if (lookup_cancellable != null) lookup_cancellable.cancel ();
        if (popover.get_parent () != null) popover.unparent ();
    }
}
}
