namespace Mailficient {
private class MailboxRowContent : Gtk.Box {
    private Gtk.Image mailbox_icon = new Gtk.Image ();
    private Gtk.Label mailbox_label = new Gtk.Label ("");
    private Gtk.Label count_label = new Gtk.Label ("");

    public MailboxRowContent (Mailbox mailbox) {
        Object (orientation: Gtk.Orientation.HORIZONTAL, spacing: 9);
        set_margin_start (8); set_margin_end (8);
        set_margin_top (6); set_margin_bottom (6);
        append (mailbox_icon);
        mailbox_label.xalign = 0; mailbox_label.hexpand = true;
        append (mailbox_label);
        count_label.add_css_class ("mailbox-count");
        append (count_label);
        update (mailbox);
    }

    public void update (Mailbox mailbox) {
        mailbox_icon.icon_name = mailbox.icon_name;
        mailbox_label.label = mailbox.name;
        count_label.label = mailbox.unread_count.to_string ();
        count_label.visible = mailbox.unread_count > 0;
        if (mailbox.unread_count == 0) {
            count_label.tooltip_text = null;
            return;
        }
        string unit = mailbox.role == MailboxRole.DRAFTS ? "draft" :
            (mailbox.id == CachedMailRepository.TASK_TODAY_ID ||
             mailbox.id == CachedMailRepository.TASK_PLANNED_ID) ? "open task" :
            mailbox.id == CachedMailRepository.LOCAL_OUTBOX_ID ? "queued message" :
            "unread message";
        count_label.tooltip_text = "%u %s%s".printf (mailbox.unread_count, unit,
            mailbox.unread_count == 1 ? "" : "s");
    }
}

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
    private Gee.HashMap<string, Gee.ArrayList<Gtk.ListBoxRow>> mailbox_row_copies =
        new Gee.HashMap<string, Gee.ArrayList<Gtk.ListBoxRow>> ();
    private Gee.HashMap<string, Gtk.ListBox> mailbox_owners = new Gee.HashMap<string, Gtk.ListBox> ();
    private Gee.ArrayList<Gtk.ListBox> account_lists = new Gee.ArrayList<Gtk.ListBox> ();
    private Gee.HashSet<string> collapsed_accounts = new Gee.HashSet<string> ();
    private Gee.HashSet<string> expanded_accounts = new Gee.HashSet<string> ();
    private Gee.HashMap<string, Mailbox> known_mailboxes = new Gee.HashMap<string, Mailbox> ();
    private Gee.ArrayList<Mailbox> known_mailbox_order = new Gee.ArrayList<Mailbox> ();
    private string selected_mailbox_id = "";
    private weak Gtk.ListBoxRow? active_row;
    private bool suppress_announcement;
    private uint smart_count_refresh_source;

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
                    mark_active_row (row);
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

    private Gtk.ListBoxRow create_row (Mailbox mailbox) {
        var row = new Gtk.ListBoxRow ();
        row.set_data<Mailbox> ("mailbox", mailbox);
        row.set_child (new MailboxRowContent (mailbox));
        if (mailbox.account_id != "" || mailbox.role == MailboxRole.TRASH ||
            mailbox.role == MailboxRole.JUNK) {
            var context_click = new Gtk.GestureClick (); context_click.button = Gdk.BUTTON_SECONDARY;
            context_click.pressed.connect ((count, x, y) => {
                // Count refreshes replace the row's Mailbox snapshot. Resolve
                // it at click time so folder actions never use stale names or
                // provider paths captured by the original closure.
                var current = row.get_data<Mailbox> ("mailbox");
                if (current != null) show_folder_menu (row, current);
            });
            row.add_controller (context_click);
        }
        return row;
    }

    private void append_mailbox (Gtk.ListBox owner, Mailbox mailbox) {
        var row = create_row (mailbox); owner.append (row);
        if (owner == list) add_favorite_drag_and_drop (row, mailbox.id);
        var copies = mailbox_row_copies[mailbox.id];
        if (copies == null) {
            copies = new Gee.ArrayList<Gtk.ListBoxRow> ();
            mailbox_row_copies[mailbox.id] = copies;
        }
        copies.add (row);
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
        foreach (var mailbox in mailboxes) {
            // Provider Drafts are synchronized into the editable local Drafts
            // model. Never expose the raw cached MIME mailbox as a second,
            // read-only favorite beside that authoritative view.
            if (!demo && mailbox.account_id != "" && mailbox.role == MailboxRole.DRAFTS)
                continue;
            if (demo || mailbox.account_id == "" || favorites.contains (mailbox.id))
                eligible[mailbox.id] = mailbox;
        }

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
        bool first_account = account_lists.size == 0;
        var row = new Gtk.ListBoxRow (); row.selectable = false; row.activatable = false;
        var expander = new Gtk.Expander (null);
        // Account folders repeat several unified favorites. Keep them one
        // click away without making the default navigation unnecessarily
        // long; an explicitly expanded account remains expanded on restart.
        expander.expanded = expanded_accounts.contains (account_id) &&
            !collapsed_accounts.contains (account_id);
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
                mark_active_row (folder_row);
                announce_selection (mailbox);
            }
        });
        foreach (var mailbox in mailboxes) {
            if (mailbox.account_id != account_id || mailbox.role == MailboxRole.VIP ||
                mailbox.role == MailboxRole.FLAGGED) continue;
            if (mailbox.role == MailboxRole.DRAFTS) {
                // Provider Drafts are mirrored into the unified editable
                // Drafts favorite. Hiding the raw account folder avoids a
                // misleading duplicate row with read-only cached MIME mail.
                continue;
            }
            append_mailbox (folders, mailbox);
        }
        expander.child = folders; row.set_child (expander);
        if (first_account) {
            var section = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            var separator = new Gtk.Separator (Gtk.Orientation.HORIZONTAL);
            separator.set_margin_start (10); separator.set_margin_end (10);
            separator.set_margin_top (10); separator.set_margin_bottom (8);
            section.append (separator);
            var heading = new Gtk.Label ("Accounts");
            heading.xalign = 0; heading.add_css_class ("heading");
            heading.set_margin_start (14); heading.set_margin_bottom (2);
            section.append (heading);
            row.set_header (section);
        }
        list.append (row);
    }

    private void load_collapsed_accounts () {
        try {
            foreach (var id in cache.preference ("collapsed-sidebar-accounts", "").split ("\n"))
                if (id.strip () != "") collapsed_accounts.add (id.strip ());
            foreach (var id in cache.preference ("expanded-sidebar-accounts", "").split ("\n"))
                if (id.strip () != "") expanded_accounts.add (id.strip ());
        } catch (Error error) {
            warning ("Could not load sidebar account state: %s", error.message);
        }
    }

    private void set_account_collapsed (string account_id, bool collapsed) {
        bool collapsed_changed = collapsed ? collapsed_accounts.add (account_id) :
            collapsed_accounts.remove (account_id);
        bool expanded_changed = collapsed ? expanded_accounts.remove (account_id) :
            expanded_accounts.add (account_id);
        if (!collapsed_changed && !expanded_changed) return;
        var collapsed_serialized = new StringBuilder ();
        foreach (var id in collapsed_accounts) {
            if (collapsed_serialized.len > 0) collapsed_serialized.append_c ('\n');
            collapsed_serialized.append (id);
        }
        var expanded_serialized = new StringBuilder ();
        foreach (var id in expanded_accounts) {
            if (expanded_serialized.len > 0) expanded_serialized.append_c ('\n');
            expanded_serialized.append (id);
        }
        try {
            cache.set_preference ("collapsed-sidebar-accounts", collapsed_serialized.str);
            cache.set_preference ("expanded-sidebar-accounts", expanded_serialized.str);
        }
        catch (Error error) { warning ("Could not save collapsed sidebar accounts: %s", error.message); }
    }

    private void mark_active_row (Gtk.ListBoxRow? row) {
        if (active_row != null && active_row != row) {
            active_row.remove_css_class ("active-mailbox");
            active_row.unset_state_flags (Gtk.StateFlags.SELECTED);
        }
        active_row = row;
        if (active_row != null) {
            // GtkListBox owns selection, while the explicit state keeps the
            // custom rounded row selected after its count child changes.
            active_row.add_css_class ("active-mailbox");
            active_row.set_state_flags (Gtk.StateFlags.SELECTED, false);
        }
    }

    public void reload (bool announce = true) {
        int64 started = DebugTrace.mark ();
        DebugTrace.log ("sidebar", "reload begin announce=%s selected=%s".printf (announce.to_string (), selected_mailbox_id));
        suppress_announcement = !announce;
        string restore_id = selected_mailbox_id;
        mark_active_row (null);
        Gtk.ListBoxRow? existing;
        while ((existing = list.get_row_at_index (0)) != null) list.remove (existing);
        mailbox_rows.clear (); mailbox_row_copies.clear ();
        mailbox_owners.clear (); account_lists.clear ();
        known_mailboxes.clear ();
        known_mailbox_order.clear ();
        var mailboxes = repository.list_mailboxes ();
        foreach (var mailbox in mailboxes) {
            known_mailboxes[mailbox.id] = mailbox;
            known_mailbox_order.add (mailbox);
        }
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
        known_mailboxes.clear ();
        known_mailbox_order.clear ();
        foreach (var mailbox in repository.list_mailboxes ()) {
            current[mailbox.id] = mailbox;
            known_mailboxes[mailbox.id] = mailbox;
            known_mailbox_order.add (mailbox);
        }
        foreach (var id in mailbox_rows.keys) {
            var mailbox = current[id];
            if (mailbox != null) update_row_copies (id, mailbox);
        }
    }

    // State-only actions update visible folder badges in place. An
    // authoritative refresh is coalesced for provider duplicates and custom
    // smart folders, but the message list and reading pane are left intact.
    public void message_read_state_changed (Message message, bool unread) {
        int delta = unread ? 1 : -1;
        var affected = new Gee.HashSet<string> ();
        affected.add (message.mailbox_id);
        var source = known_mailboxes[message.mailbox_id];
        if (source != null) {
            switch (source.role) {
            case MailboxRole.INBOX: affected.add ("unified-inbox"); break;
            case MailboxRole.SENT: affected.add ("unified-sent"); break;
            case MailboxRole.ARCHIVE: affected.add ("unified-archive"); break;
            case MailboxRole.JUNK: affected.add ("unified-junk"); break;
            case MailboxRole.TRASH: affected.add ("unified-trash"); break;
            default: break;
            }
        }
        try {
            if (cache.message_is_snoozed (message.id)) affected.add ("unified-snoozed");
            if (message.flagged) affected.add (known_mailboxes.has_key ("unified-flagged") ?
                "unified-flagged" : "flagged");
            if (repository.sender_is_vip (message)) affected.add (known_mailboxes.has_key ("unified-vip") ?
                "unified-vip" : "vip");
        } catch (Error error) {
            // The message was already updated durably. A later sync will
            // refresh any count whose auxiliary lookup was unavailable.
            warning ("Could not update a derived mailbox count: %s", error.message);
        }
        foreach (var id in affected) adjust_count (id, delta);
        queue_smart_count_refresh ();
    }

    public void message_flag_state_changed (Message message, bool flagged) {
        if (message.unread)
            adjust_count (known_mailboxes.has_key ("unified-flagged") ?
                "unified-flagged" : "flagged", flagged ? 1 : -1);
        queue_smart_count_refresh ();
    }

    private void update_row_copies (string id, Mailbox mailbox) {
        var copies = mailbox_row_copies[id];
        if (copies == null) return;
        foreach (var row in copies) {
            row.set_data<Mailbox> ("mailbox", mailbox);
            var content = row.child as MailboxRowContent;
            if (content != null) content.update (mailbox);
        }
    }

    private void adjust_count (string id, int delta) {
        var mailbox = known_mailboxes[id];
        if (mailbox == null) return;
        int next = int.max (0, (int) mailbox.unread_count + delta);
        if (next == (int) mailbox.unread_count) return;
        mailbox.unread_count = (uint) next;
        update_row_copies (id, mailbox);
    }

    private void queue_smart_count_refresh () {
        if (smart_count_refresh_source != 0) return;
        smart_count_refresh_source = Timeout.add (750, () => {
            smart_count_refresh_source = 0;
            refresh_counts ();
            return Source.REMOVE;
        });
    }

    ~MailboxSidebar () {
        if (smart_count_refresh_source != 0) Source.remove (smart_count_refresh_source);
    }

    public bool select_mailbox (string id) {
        var row = mailbox_rows[id]; var owner = mailbox_owners[id];
        if (row == null || owner == null) return false;
        if (owner == list) {
            foreach (var account_list in account_lists) account_list.unselect_all ();
        } else {
            var expander = owner.get_ancestor (typeof (Gtk.Expander)) as Gtk.Expander;
            if (expander != null && !expander.expanded) expander.expanded = true;
            list.unselect_all ();
            foreach (var account_list in account_lists)
                if (account_list != owner) account_list.unselect_all ();
        }
        if (owner.get_selected_row () == row) {
            mark_active_row (row);
            var mailbox = row.get_data<Mailbox> ("mailbox");
            if (mailbox != null) announce_selection (mailbox);
        } else owner.select_row (row);
        return true;
    }

    public Mailbox? mailbox_for_id (string id) {
        return known_mailboxes[id];
    }

    public Gee.List<Mailbox> current_mailboxes () {
        var result = new Gee.ArrayList<Mailbox> ();
        result.add_all (known_mailbox_order);
        return result;
    }

    public void clear_selection () {
        selected_mailbox_id = "";
        list.unselect_all ();
        foreach (var account_list in account_lists) account_list.unselect_all ();
        mark_active_row (null);
    }
}
}
