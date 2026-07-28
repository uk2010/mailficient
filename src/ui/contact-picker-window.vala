namespace Mailficient {
public class ContactPickerWindow : Adw.Window {
    public signal void recipient_selected (Recipient recipient);
    private ContactSuggestionProvider provider;
    private Gtk.SearchEntry search = new Gtk.SearchEntry ();
    private Gtk.ListBox results = new Gtk.ListBox ();
    private Gtk.Label status = new Gtk.Label ("Loading contacts…");
    private uint search_source;
    private uint search_generation;
    private Cancellable? search_cancellable;

    public ContactPickerWindow (Gtk.Window parent, ContactSuggestionProvider provider) {
        Object (title: "GNOME Contacts", transient_for: parent, modal: true,
            default_width: 480, default_height: 520);
        this.provider = provider;
        var toolbar = new Adw.ToolbarView ();
        var header = new Adw.HeaderBar (); header.title_widget = new Gtk.Label ("Choose a Contact");
        toolbar.add_top_bar (header);
        var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 10);
        content.set_margin_top (12); content.set_margin_bottom (12);
        content.set_margin_start (12); content.set_margin_end (12);
        search.placeholder_text = "Search names or email addresses";
        Accessibility.label (search, "Search GNOME Contacts"); content.append (search);
        status.wrap = true; status.add_css_class ("dim-label"); status.set_margin_top (18);
        content.append (status);
        results.add_css_class ("boxed-list"); results.selection_mode = Gtk.SelectionMode.SINGLE;
        results.row_activated.connect ((row) => {
            var recipient = row.get_data<Recipient> ("recipient");
            if (recipient == null) return;
            recipient_selected (recipient); close ();
        });
        var scroller = new Gtk.ScrolledWindow (); scroller.vexpand = true; scroller.child = results;
        content.append (scroller); toolbar.set_content (content);
        set_content (toolbar);
        search.search_changed.connect (schedule_search);
        Idle.add (() => { search.grab_focus (); schedule_search (); return Source.REMOVE; });
    }

    private void schedule_search () {
        search_generation++;
        if (search_source != 0) { Source.remove (search_source); search_source = 0; }
        if (search_cancellable != null) search_cancellable.cancel ();
        clear_results ();
        string query = search.text.strip ();
        if (query.length == 1) {
            status.label = "Type at least two characters to search GNOME Contacts.";
            status.visible = true; return;
        }
        status.label = query == "" ? "Loading contacts…" : "Searching contacts…";
        status.visible = true;
        uint generation = search_generation; search_cancellable = new Cancellable ();
        var cancellable = search_cancellable;
        search_source = Timeout.add (150, () => {
            search_source = 0; perform_search.begin (query, generation, cancellable);
            return Source.REMOVE;
        });
    }

    private async void perform_search (string query, uint generation, Cancellable cancellable) {
        try {
            var contacts = yield provider.suggest (query, 50, cancellable);
            if (generation != search_generation || cancellable.is_cancelled ()) return;
            render (contacts);
        } catch (Error error) {
            if (error is IOError.CANCELLED) return;
            if (generation == search_generation) {
                status.label = "GNOME Contacts could not be searched."; status.visible = true;
            }
            warning ("Could not search GNOME Contacts picker: %s", error.message);
        }
    }

    private void render (Gee.List<Recipient> contacts) {
        clear_results ();
        status.label = contacts.size == 0 ? "No matching contacts." :
            (contacts.size == 1 ? "1 contact" : "%d contacts".printf (contacts.size));
        status.visible = true;
        foreach (var recipient in contacts) {
            var row = new Gtk.ListBoxRow (); row.set_data<Recipient> ("recipient", recipient);
            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
            box.set_margin_top (8); box.set_margin_bottom (8);
            box.set_margin_start (10); box.set_margin_end (10);
            var name = new Gtk.Label (recipient.name == "" ? recipient.address : recipient.name);
            name.xalign = 0; name.ellipsize = Pango.EllipsizeMode.END; box.append (name);
            if (recipient.name != "") {
                var address = new Gtk.Label (recipient.address); address.xalign = 0;
                address.add_css_class ("dim-label"); address.ellipsize = Pango.EllipsizeMode.END;
                box.append (address);
            }
            row.child = box; Accessibility.label (row, "Choose %s".printf (recipient.formatted ()));
            results.append (row);
        }
    }

    private void clear_results () {
        Gtk.ListBoxRow? row;
        while ((row = results.get_row_at_index (0)) != null) results.remove (row);
    }

    ~ContactPickerWindow () {
        if (search_source != 0) Source.remove (search_source);
        if (search_cancellable != null) search_cancellable.cancel ();
    }
}
}
