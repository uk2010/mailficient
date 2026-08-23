namespace Mailficient {
public class MailboxSidebar : Gtk.Box {
    public signal void mailbox_selected (Mailbox mailbox);
    public signal void create_folder_requested (AccountSettings account, Mailbox? parent);
    public signal void rename_folder_requested (Mailbox mailbox);
    public signal void delete_folder_requested (Mailbox mailbox);
    public signal void empty_role_requested (MailboxRole role);
    public signal void empty_mailbox_requested (Mailbox mailbox);
    public signal void export_mailbox_requested (Mailbox mailbox);
    public signal void synchronize_account_requested (AccountSettings account);
    public signal void edit_account_requested (AccountSettings account);
    public signal void account_info_requested (AccountSettings account);
    private Gtk.ListBox list = new Gtk.ListBox ();
    private MailRepository repository;
    private CacheDatabase cache;
    private Gee.HashMap<string, Gtk.ListBoxRow> mailbox_rows = new Gee.HashMap<string, Gtk.ListBoxRow> ();
    private Gee.HashMap<string, Gtk.ListBox> mailbox_owners = new Gee.HashMap<string, Gtk.ListBox> ();
    private Gee.ArrayList<Gtk.ListBox> account_lists = new Gee.ArrayList<Gtk.ListBox> ();
    private Gee.HashSet<string> collapsed_accounts = new Gee.HashSet<string> ();
    private string selected_mailbox_id = "";
    private bool suppress_announcement;

    public MailboxSidebar (MailRepository repository, CacheDatabase cache) {
        Object (orientation: Gtk.Orientation.VERTICAL);
        this.repository = repository; this.cache = cache;
        load_collapsed_accounts ();
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
        var identity = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 9);
        identity.add_css_class ("sidebar-identity");
        identity.set_margin_start (14); identity.set_margin_end (14);
        identity.set_margin_top (12); identity.set_margin_bottom (5);
        var identity_icon = new Gtk.Image.from_icon_name ("mail-unread-symbolic");
        identity_icon.add_css_class ("sidebar-identity-icon");
        identity.append (identity_icon);
        var identity_label = new Gtk.Label ("Mailficient");
        identity_label.xalign = 0; identity_label.hexpand = true;
        identity_label.add_css_class ("sidebar-identity-title");
        identity.append (identity_label);
        append (identity);
        var scroller = new Gtk.ScrolledWindow ();
        scroller.hscrollbar_policy = Gtk.PolicyType.NEVER;
        scroller.set_child (list);
        append (scroller);
        scroller.vexpand = true;

        reload ();
    }

    private Gtk.Box row_content (Mailbox mailbox) {
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
        return box;
    }

    private Gtk.ListBoxRow create_row (Mailbox mailbox) {
        var row = new Gtk.ListBoxRow ();
        row.set_data<Mailbox> ("mailbox", mailbox);
        row.set_child (row_content (mailbox));
        if (mailbox.account_id != "" || mailbox.role == MailboxRole.TRASH ||
            mailbox.role == MailboxRole.JUNK) {
            var context_click = new Gtk.GestureClick (); context_click.button = Gdk.BUTTON_SECONDARY;
            context_click.pressed.connect ((count, x, y) => show_folder_menu (row, mailbox));
            row.add_controller (context_click);
        }
        return row;
    }

    private void append_mailbox (Gtk.ListBox owner, Mailbox mailbox) {
        var row = create_row (mailbox); owner.append (row);
        if (owner == list) add_favorite_drag_and_drop (row, mailbox.id);
        // Demo mode also mirrors its folders below Favorites. Prefer the first
        // visible occurrence so restoring Inbox selects the favorite row.
        if (!mailbox_rows.has_key (mailbox.id)) {
            mailbox_rows[mailbox.id] = row; mailbox_owners[mailbox.id] = owner;
        }
    }

    private void add_favorite_drag_and_drop (Gtk.ListBoxRow row, string mailbox_id) {
        var source = new Gtk.DragSource ();
        source.actions = Gdk.DragAction.MOVE;
        source.propagation_phase = Gtk.PropagationPhase.CAPTURE;
        source.prepare.connect ((x, y) => {
            Value value = Value (typeof (string));
            value.set_string (mailbox_id);
            return new Gdk.ContentProvider.for_value (value);
        });
        row.add_controller (source);

        var target = new Gtk.DropTarget (typeof (string), Gdk.DragAction.MOVE);
        target.propagation_phase = Gtk.PropagationPhase.CAPTURE;
        target.drop.connect ((value, x, y) => {
            string? dragged_id = value.get_string ();
            if (dragged_id == null || dragged_id == mailbox_id) return false;
            reorder_favorite (dragged_id, mailbox_id, y > row.get_height () / 2.0);
            return true;
        });
        row.add_controller (target);
    }

    private Gee.ArrayList<string> favorite_order () {
        var result = new Gee.ArrayList<string> ();
        try {
            foreach (var id in cache.preference ("favorite-mailbox-order", "").split ("\n")) {
                var cleaned = id.strip ();
                if (cleaned != "" && !result.contains (cleaned)) result.add (cleaned);
            }
        } catch (Error error) {
            warning ("Could not load favorite mailbox order: %s", error.message);
        }
        return result;
    }

    private void save_favorite_order (Gee.List<string> order) {
        var serialized = new StringBuilder ();
        foreach (var id in order) {
            if (serialized.len > 0) serialized.append_c ('\n');
            serialized.append (id);
        }
        try { cache.set_preference ("favorite-mailbox-order", serialized.str); }
        catch (Error error) { warning ("Could not save favorite mailbox order: %s", error.message); }
    }

    private Gee.ArrayList<string> visible_favorite_ids () {
        var result = new Gee.ArrayList<string> ();
        for (int index = 0; ; index++) {
            var row = list.get_row_at_index (index);
            if (row == null) break;
            var mailbox = row.get_data<Mailbox> ("mailbox");
            if (mailbox != null) result.add (mailbox.id);
        }
        return result;
    }

    private void reorder_favorite (string dragged_id, string target_id, bool after_target) {
        var ids = visible_favorite_ids ();
        int dragged_index = -1;
        int target_index = -1;
        for (int index = 0; index < ids.size; index++) {
            if (ids[index] == dragged_id) dragged_index = index;
            if (ids[index] == target_id) target_index = index;
        }
        if (dragged_index < 0 || target_index < 0 || dragged_index == target_index) return;

        var value = ids.remove_at (dragged_index);
        if (dragged_index < target_index) target_index--;
        int insertion_index = target_index + (after_target ? 1 : 0);
        insertion_index = int.max (0, int.min (insertion_index, ids.size));
        ids.insert (insertion_index, value);
        save_favorite_order (ids);
        reload (false);
    }

    private void announce_selection (Mailbox mailbox) {
        selected_mailbox_id = mailbox.id;
        if (!suppress_announcement) mailbox_selected (mailbox);
    }

    private void show_folder_menu (Gtk.Widget anchor, Mailbox mailbox) {
        var popover = new Gtk.Popover (); popover.set_parent (anchor); popover.autohide = true;
        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 2); box.set_margin_top (6); box.set_margin_bottom (6);
        box.set_margin_start (6); box.set_margin_end (6);
        AccountSettings? account = null;
        try { if (mailbox.account_id != "") account = cache.find_account (mailbox.account_id); }
        catch (Error error) { warning ("Could not resolve folder account: %s", error.message); }

        if (account != null) {
            var new_mailbox = menu_button ("New Mailbox…", "folder-new-symbolic");
            new_mailbox.clicked.connect (() => {
                popover.popdown (); create_folder_requested (account, null);
            });
            box.append (new_mailbox);
        }

        if (mailbox.account_id != "") {
            bool favorite = is_favorite (mailbox.id);
            var favorite_button = menu_button (
                favorite ? "Remove from Favorites" : "Add to Favorites",
                favorite ? "starred-symbolic" : "non-starred-symbolic");
            favorite_button.clicked.connect (() => {
                popover.popdown (); set_favorite (mailbox.id, !favorite);
            });
            box.append (favorite_button);
            box.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));
        }

        if (mailbox.role == MailboxRole.CUSTOM) {
            var rename = menu_button ("Rename Mailbox…", "document-edit-symbolic");
            rename.clicked.connect (() => { popover.popdown (); rename_folder_requested (mailbox); });
            var remove = menu_button ("Delete Mailbox…", "user-trash-symbolic");
            remove.add_css_class ("error");
            remove.clicked.connect (() => { popover.popdown (); delete_folder_requested (mailbox); });
            box.append (rename); box.append (remove);
        }

        if (mailbox.account_id != "") {
            var export = menu_button ("Export Mailbox…", "document-save-symbolic");
            export.clicked.connect (() => { popover.popdown (); export_mailbox_requested (mailbox); });
            box.append (export);
        }

        if (mailbox.role == MailboxRole.TRASH || mailbox.role == MailboxRole.JUNK) {
            var empty = menu_button (mailbox.role == MailboxRole.TRASH ? "Empty Trash…" : "Empty Junk…",
                "edit-delete-symbolic");
            empty.add_css_class ("error");
            empty.clicked.connect (() => {
                popover.popdown ();
                if (account != null) empty_mailbox_requested (mailbox);
                else empty_role_requested (mailbox.role);
            });
            box.append (empty);
        }

        if (account != null) {
            box.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));
            var sync = menu_button ("Synchronize “%s”".printf (account.display_name), "view-refresh-symbolic");
            sync.clicked.connect (() => { popover.popdown (); synchronize_account_requested (account); });
            var edit = menu_button ("Edit “%s”…".printf (account.display_name), "document-edit-symbolic");
            edit.clicked.connect (() => { popover.popdown (); edit_account_requested (account); });
            var info = menu_button ("Get Account Info", "dialog-information-symbolic");
            info.clicked.connect (() => { popover.popdown (); account_info_requested (account); });
            box.append (sync); box.append (edit); box.append (info);
        }

        popover.child = box;
        popover.closed.connect (() => popover.unparent ()); popover.popup ();
    }

    private static Gtk.Button menu_button (string label, string icon_name) {
        var button = new Gtk.Button ();
        var content = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 9);
        content.append (new Gtk.Image.from_icon_name (icon_name));
        var text = new Gtk.Label (label); text.xalign = 0; text.hexpand = true;
        content.append (text); button.child = content;
        button.has_frame = false; button.halign = Gtk.Align.FILL;
        Accessibility.label (button, label); return button;
    }

    private Gee.HashSet<string> favorite_ids () {
        var result = new Gee.HashSet<string> ();
        try {
            foreach (var id in cache.preference ("favorite-mailboxes", "").split ("\n"))
                if (id.strip () != "") result.add (id.strip ());
        } catch (Error error) { warning ("Could not load favorite mailboxes: %s", error.message); }
        return result;
    }

    private bool is_favorite (string id) { return favorite_ids ().contains (id); }

    private void set_favorite (string id, bool favorite) {
        var ids = favorite_ids ();
        if (favorite) ids.add (id); else ids.remove (id);
        var serialized = new StringBuilder ();
        foreach (var value in ids) {
            if (serialized.len > 0) serialized.append_c ('\n');
            serialized.append (value);
        }
        var order = favorite_order ();
        if (favorite && !order.contains (id)) order.add (id);
        if (!favorite) order.remove (id);
        try {
            cache.set_preference ("favorite-mailboxes", serialized.str);
            save_favorite_order (order);
            reload (false);
        }
        catch (Error error) { warning ("Could not save favorite mailboxes: %s", error.message); }
    }

    private void append_favorites (Gee.List<Mailbox> mailboxes, Gee.HashSet<string> favorites, bool demo) {
        var eligible = new Gee.HashMap<string, Mailbox> ();
        foreach (var mailbox in mailboxes)
            if (demo || mailbox.account_id == "" || favorites.contains (mailbox.id))
                eligible[mailbox.id] = mailbox;

        var appended = new Gee.HashSet<string> ();
        foreach (var id in favorite_order ()) {
            var mailbox = eligible[id];
            if (mailbox != null) {
                append_mailbox (list, mailbox);
                appended.add (id);
            }
        }
        foreach (var mailbox in mailboxes) {
            if (eligible.has_key (mailbox.id) && !appended.contains (mailbox.id))
                append_mailbox (list, mailbox);
        }
    }

    private void add_account_group (string account_id, string display_name, string email,
                                    Gee.List<Mailbox> mailboxes, bool allow_folder_creation) {
        var row = new Gtk.ListBoxRow (); row.selectable = false; row.activatable = false;
        var expander = new Gtk.Expander (null);
        expander.expanded = !collapsed_accounts.contains (account_id);
        expander.notify["expanded"].connect (() => {
            set_account_collapsed (account_id, !expander.expanded);
        });
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

    private void load_collapsed_accounts () {
        try {
            foreach (var id in cache.preference ("collapsed-sidebar-accounts", "").split ("\n"))
                if (id.strip () != "") collapsed_accounts.add (id.strip ());
        } catch (Error error) {
            warning ("Could not load collapsed sidebar accounts: %s", error.message);
        }
    }

    private void set_account_collapsed (string account_id, bool collapsed) {
        bool changed = collapsed ? collapsed_accounts.add (account_id) :
            collapsed_accounts.remove (account_id);
        if (!changed) return;
        var serialized = new StringBuilder ();
        foreach (var id in collapsed_accounts) {
            if (serialized.len > 0) serialized.append_c ('\n');
            serialized.append (id);
        }
        try { cache.set_preference ("collapsed-sidebar-accounts", serialized.str); }
        catch (Error error) { warning ("Could not save collapsed sidebar accounts: %s", error.message); }
    }

    public void reload (bool announce = true) {
        int64 started = DebugTrace.mark ();
        DebugTrace.log ("sidebar", "reload begin announce=%s selected=%s".printf (announce.to_string (), selected_mailbox_id));
        suppress_announcement = !announce;
        string restore_id = selected_mailbox_id;
        Gtk.ListBoxRow? existing;
        while ((existing = list.get_row_at_index (0)) != null) list.remove (existing);
        mailbox_rows.clear (); mailbox_owners.clear (); account_lists.clear ();
        var mailboxes = repository.list_mailboxes ();
        DebugTrace.log ("sidebar", "repository.list_mailboxes returned count=%d".printf (mailboxes.size));
        try {
            var accounts = cache.list_accounts ();
            var favorites = favorite_ids ();
            bool demo = accounts.size == 0 && Environment.get_variable ("MAILFICIENT_QA") == "1" &&
                Environment.get_variable ("MAILFICIENT_QA_NO_DEMO") != "1";
            append_favorites (mailboxes, favorites, demo);
            if (demo) add_account_group (DemoMailRepository.ACCOUNT_ID, "Demo Account", "alex@example.com", mailboxes, false);
            else foreach (var account in accounts)
                add_account_group (account.id, account.display_name, account.email, mailboxes, true);
        } catch (Error error) {
            warning ("Could not load account summaries: %s", error.message);
        }
        if (restore_id != "" && select_mailbox (restore_id)) {
            suppress_announcement = false;
            DebugTrace.duration ("sidebar", "reload restored complete", started);
            return;
        }
        var first = list.get_row_at_index (0); if (first != null) list.select_row (first);
        suppress_announcement = false;
        DebugTrace.duration ("sidebar", "reload complete", started);
    }

    // Repository changes usually alter unread totals, not the mailbox/favorite
    // layout. Update the existing favorite rows in place so unrelated views do
    // not disappear and get rebuilt after every message action.
    public void refresh_counts () {
        var current = new Gee.HashMap<string, Mailbox> ();
        foreach (var mailbox in repository.list_mailboxes ()) current[mailbox.id] = mailbox;
        foreach (var id in mailbox_rows.keys) {
            var mailbox = current[id];
            var row = mailbox_rows[id];
            if (mailbox != null && row != null) row.set_child (row_content (mailbox));
        }
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

    public void clear_selection () {
        selected_mailbox_id = "";
        list.unselect_all ();
        foreach (var account_list in account_lists) account_list.unselect_all ();
    }
}
}
