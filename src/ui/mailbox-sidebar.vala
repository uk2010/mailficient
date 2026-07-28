namespace Mailficient {
public class MailboxSidebar : Gtk.Box {
    public signal void mailbox_selected (Mailbox mailbox);
    public signal void create_folder_requested (AccountSettings account, Mailbox? parent);
    public signal void rename_folder_requested (Mailbox mailbox);
    public signal void delete_folder_requested (Mailbox mailbox);
    public signal void empty_role_requested (MailboxRole role);
    private Gtk.ListBox list = new Gtk.ListBox ();
    private MailRepository repository;
    private CacheDatabase cache;
    private Gee.HashMap<string, Gtk.ListBoxRow> mailbox_rows = new Gee.HashMap<string, Gtk.ListBoxRow> ();
    private Gee.HashMap<string, Gtk.ListBox> mailbox_owners = new Gee.HashMap<string, Gtk.ListBox> ();
    private Gee.ArrayList<Gtk.ListBox> account_lists = new Gee.ArrayList<Gtk.ListBox> ();
    private string selected_mailbox_id = "";
    private bool suppress_announcement;

    public MailboxSidebar (MailRepository repository, CacheDatabase cache) {
        Object (orientation: Gtk.Orientation.VERTICAL);
        this.repository = repository; this.cache = cache;
        add_css_class ("mail-sidebar");
        list.selection_mode = Gtk.SelectionMode.SINGLE;
        list.add_css_class ("navigation-sidebar");
        list.set_header_func ((row, before) => {
            if (row.get_index () == 0) {
                var title = new Gtk.Label ("Favorites");
                title.xalign = 0;
                title.add_css_class ("heading");
                title.set_margin_start (14); title.set_margin_top (14); title.set_margin_bottom (6);
                row.set_header (title);
            }
        });
        list.row_selected.connect ((row) => {
            if (row != null) {
                var mailbox = row.get_data<Mailbox> ("mailbox");
                if (mailbox != null) {
                    foreach (var account_list in account_lists) account_list.unselect_all ();
                    announce_selection (mailbox);
                }
            }
        });
        var scroller = new Gtk.ScrolledWindow ();
        scroller.hscrollbar_policy = Gtk.PolicyType.NEVER;
        scroller.set_child (list);
        append (scroller);
        scroller.vexpand = true;

        reload ();
    }

    private Gtk.ListBoxRow create_row (Mailbox mailbox) {
        var row = new Gtk.ListBoxRow ();
        row.set_data<Mailbox> ("mailbox", mailbox);
        var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 9);
        box.set_margin_start (8); box.set_margin_end (8); box.set_margin_top (6); box.set_margin_bottom (6);
        box.append (new Gtk.Image.from_icon_name (mailbox.icon_name));
        var label = new Gtk.Label (mailbox.name); label.xalign = 0; label.hexpand = true; box.append (label);
        if (mailbox.unread_count > 0) {
            var count = new Gtk.Label (mailbox.unread_count.to_string ());
            count.add_css_class ("mailbox-count");
            string unit = mailbox.role == MailboxRole.DRAFTS ? "draft" :
                mailbox.id == CachedMailRepository.LOCAL_OUTBOX_ID ? "queued message" : "unread message";
            count.tooltip_text = "%u %s%s".printf (mailbox.unread_count, unit,
                mailbox.unread_count == 1 ? "" : "s");
            box.append (count);
        }
        row.set_child (box);
        if ((mailbox.account_id != "" && mailbox.role == MailboxRole.CUSTOM) ||
            mailbox.role == MailboxRole.TRASH || mailbox.role == MailboxRole.JUNK) {
            var context_click = new Gtk.GestureClick (); context_click.button = Gdk.BUTTON_SECONDARY;
            context_click.pressed.connect ((count, x, y) => show_folder_menu (row, mailbox));
            row.add_controller (context_click);
        }
        return row;
    }

    private void append_mailbox (Gtk.ListBox owner, Mailbox mailbox) {
        var row = create_row (mailbox); owner.append (row);
        // Demo mode also mirrors its folders below Favorites. Prefer the first
        // visible occurrence so restoring Inbox selects the favorite row.
        if (!mailbox_rows.has_key (mailbox.id)) {
            mailbox_rows[mailbox.id] = row; mailbox_owners[mailbox.id] = owner;
        }
    }

    private void announce_selection (Mailbox mailbox) {
        selected_mailbox_id = mailbox.id;
        if (!suppress_announcement) mailbox_selected (mailbox);
    }

    private void show_folder_menu (Gtk.Widget anchor, Mailbox mailbox) {
        var popover = new Gtk.Popover (); popover.set_parent (anchor); popover.autohide = true;
        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 2); box.set_margin_top (6); box.set_margin_bottom (6);
        box.set_margin_start (6); box.set_margin_end (6);
        if (mailbox.role == MailboxRole.TRASH || mailbox.role == MailboxRole.JUNK) {
            var empty = menu_button (mailbox.role == MailboxRole.TRASH ? "Empty Trash…" : "Empty Junk…",
                "edit-delete-symbolic");
            empty.add_css_class ("error");
            empty.clicked.connect (() => { popover.popdown (); empty_role_requested (mailbox.role); });
            box.append (empty); popover.child = box;
            popover.closed.connect (() => popover.unparent ()); popover.popup (); return;
        }
        var subfolder = menu_button ("New Subfolder…", "folder-new-symbolic");
        subfolder.clicked.connect (() => {
            popover.popdown ();
            try { var account = cache.find_account (mailbox.account_id); if (account != null) create_folder_requested (account, mailbox); }
            catch (Error error) { warning ("Could not resolve folder account: %s", error.message); }
        });
        var rename = menu_button ("Rename…", "document-edit-symbolic");
        rename.clicked.connect (() => { popover.popdown (); rename_folder_requested (mailbox); });
        var remove = menu_button ("Delete…", "user-trash-symbolic");
        remove.add_css_class ("error"); remove.clicked.connect (() => { popover.popdown (); delete_folder_requested (mailbox); });
        box.append (subfolder); box.append (rename); box.append (remove); popover.child = box;
        popover.closed.connect (() => popover.unparent ()); popover.popup ();
    }

    private static Gtk.Button menu_button (string label, string icon_name) {
        var button = new Gtk.Button.with_label (label); button.icon_name = icon_name;
        button.has_frame = false; button.halign = Gtk.Align.FILL; return button;
    }

    private void add_account_group (string account_id, string display_name, string email,
                                    Gee.List<Mailbox> mailboxes, bool allow_folder_creation) {
        var row = new Gtk.ListBoxRow (); row.selectable = false; row.activatable = false;
        var expander = new Gtk.Expander (null); expander.expanded = true;
        expander.set_margin_start (12); expander.set_margin_end (10); expander.set_margin_top (8); expander.set_margin_bottom (6);
        var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 9);
        box.append (new Gtk.Image.from_icon_name ("avatar-default-symbolic"));
        var labels = new Gtk.Box (Gtk.Orientation.VERTICAL, 1); labels.hexpand = true;
        var title = new Gtk.Label (display_name); title.xalign = 0; title.add_css_class ("heading"); labels.append (title);
        var address = new Gtk.Label (email); address.xalign = 0; address.ellipsize = Pango.EllipsizeMode.END; address.add_css_class ("dim-label"); labels.append (address); box.append (labels);
        if (allow_folder_creation) {
            var add_folder = new Gtk.Button.from_icon_name ("folder-new-symbolic");
            add_folder.add_css_class ("flat"); add_folder.tooltip_text = "New folder for %s".printf (display_name);
            Accessibility.label (add_folder, add_folder.tooltip_text);
            add_folder.clicked.connect (() => {
                try { var account = cache.find_account (account_id); if (account != null) create_folder_requested (account, null); }
                catch (Error error) { warning ("Could not resolve folder account: %s", error.message); }
            });
            box.append (add_folder);
        }
        expander.label_widget = box;
        var folders = new Gtk.ListBox (); folders.selection_mode = Gtk.SelectionMode.SINGLE;
        account_lists.add (folders);
        folders.add_css_class ("navigation-sidebar"); folders.add_css_class ("account-folders");
        folders.row_selected.connect ((folder_row) => {
            if (folder_row == null) return;
            var mailbox = folder_row.get_data<Mailbox> ("mailbox");
            if (mailbox != null) {
                list.unselect_all ();
                foreach (var account_list in account_lists)
                    if (account_list != folders) account_list.unselect_all ();
                announce_selection (mailbox);
            }
        });
        foreach (var mailbox in mailboxes)
            if (mailbox.account_id == account_id && mailbox.role != MailboxRole.VIP && mailbox.role != MailboxRole.FLAGGED)
                append_mailbox (folders, mailbox);
        expander.child = folders; row.set_child (expander); list.append (row);
    }

    public void reload (bool announce = true) {
        suppress_announcement = !announce;
        string restore_id = selected_mailbox_id;
        Gtk.ListBoxRow? existing;
        while ((existing = list.get_row_at_index (0)) != null) list.remove (existing);
        mailbox_rows.clear (); mailbox_owners.clear (); account_lists.clear ();
        var mailboxes = repository.list_mailboxes ();
        try {
            var accounts = cache.list_accounts ();
            bool demo = accounts.size == 0 && Environment.get_variable ("MAILFICIENT_QA") == "1" &&
                Environment.get_variable ("MAILFICIENT_QA_NO_DEMO") != "1";
            foreach (var mailbox in mailboxes)
                if (demo || mailbox.account_id == "") append_mailbox (list, mailbox);
            if (demo) add_account_group (DemoMailRepository.ACCOUNT_ID, "Demo Account", "alex@example.com", mailboxes, false);
            else foreach (var account in accounts)
                add_account_group (account.id, account.display_name, account.email, mailboxes, true);
        } catch (Error error) {
            warning ("Could not load account summaries: %s", error.message);
        }
        if (restore_id != "" && select_mailbox (restore_id)) {
            suppress_announcement = false;
            return;
        }
        var first = list.get_row_at_index (0); if (first != null) list.select_row (first);
        suppress_announcement = false;
    }

    public bool select_mailbox (string id) {
        var row = mailbox_rows[id]; var owner = mailbox_owners[id];
        if (row == null || owner == null) return false;
        if (owner == list) {
            foreach (var account_list in account_lists) account_list.unselect_all ();
        } else {
            list.unselect_all ();
            foreach (var account_list in account_lists)
                if (account_list != owner) account_list.unselect_all ();
        }
        if (owner.get_selected_row () == row) {
            var mailbox = row.get_data<Mailbox> ("mailbox");
            if (mailbox != null) announce_selection (mailbox);
        } else owner.select_row (row);
        return true;
    }
}
}
