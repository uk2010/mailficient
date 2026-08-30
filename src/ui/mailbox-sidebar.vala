namespace Mailficient {
private class MailboxRowContent : Gtk.Box {
    public signal void expansion_requested ();

    private Gtk.Image mailbox_icon = new Gtk.Image ();
    private Gtk.Label mailbox_label = new Gtk.Label ("");
    private Gtk.Label count_label = new Gtk.Label ("");

    public MailboxRowContent (Mailbox mailbox, int depth = 0,
                              bool hierarchical = false,
                              bool has_children = false,
                              bool expanded = true) {
        Object (orientation: Gtk.Orientation.HORIZONTAL, spacing: 9);
        add_css_class ("mailbox-row-content");
        set_margin_start (hierarchical ? 4 + int.min (depth, 8) * 15 : 8);
        set_margin_end (8);
        set_margin_top (5); set_margin_bottom (5);
        if (hierarchical) {
            if (has_children) {
                var disclosure = new Gtk.Button.from_icon_name (
                    expanded ? "pan-down-symbolic" : "pan-end-symbolic");
                disclosure.add_css_class ("flat");
                disclosure.add_css_class ("mailbox-disclosure");
                disclosure.tooltip_text = expanded ? "Collapse folder" : "Expand folder";
                Accessibility.label (disclosure,
                    "%s %s".printf (expanded ? "Collapse" : "Expand", mailbox.name));
                disclosure.clicked.connect (() => expansion_requested ());
                append (disclosure);
            } else {
                var disclosure_slot = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
                disclosure_slot.set_size_request (20, -1);
                append (disclosure_slot);
            }
        }
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
    private const string FAVORITE_DRAG_PREFIX = "mailficient-favorite:";
    private const string MAILBOX_DRAG_PREFIX = "mailficient-mailbox:";
    public signal void mailbox_selected (Mailbox mailbox);
    public signal void create_folder_requested (AccountSettings account, Mailbox? parent);
    public signal void create_folder_any_requested ();
    public signal void create_rule_requested ();
    public signal void create_rule_for_mailbox_requested (AccountSettings? account,
                                                          Mailbox? mailbox);
    public signal void rules_requested ();
    public signal void create_smart_mailbox_requested ();
    public signal void accounts_requested ();
    public signal void messages_dropped (Mailbox mailbox, string[] message_ids, bool copy);
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
    private Gee.HashSet<string> collapsed_mailboxes = new Gee.HashSet<string> ();
    private Gee.HashMap<string, string> mailbox_parent_ids = new Gee.HashMap<string, string> ();
    private Gee.HashMap<string, Mailbox> known_mailboxes = new Gee.HashMap<string, Mailbox> ();
    private Gee.ArrayList<Mailbox> known_mailbox_order = new Gee.ArrayList<Mailbox> ();
    private string selected_mailbox_id = "";
    private weak Gtk.ListBoxRow? active_row;
    private bool suppress_announcement;
    private uint smart_count_refresh_source;
    private Gtk.Popover? context_menu;
    private SimpleActionGroup? context_actions;
    private weak Gtk.Widget? context_action_host;
    private weak Gtk.ListBoxRow? context_row;
    private Gtk.MenuButton add_menu_button = new Gtk.MenuButton ();
    private Gtk.Popover add_popover = new Gtk.Popover ();
    private Gtk.Button add_mailbox_button = new Gtk.Button ();
    private Gtk.Button add_subfolder_button = new Gtk.Button ();
    private bool follow_up_expanded;
    private int account_group_count;

    public MailboxSidebar (MailRepository repository, CacheDatabase cache) {
        Object (orientation: Gtk.Orientation.VERTICAL);
        this.repository = repository; this.cache = cache;
        load_sidebar_state ();
        add_css_class ("mail-sidebar");
        list.selection_mode = Gtk.SelectionMode.SINGLE;
        list.add_css_class ("navigation-sidebar");
        list.row_selected.connect ((row) => {
            if (row != null) {
                var mailbox = row.get_data<Mailbox> ("mailbox");
                if (mailbox != null) {
                    foreach (var account_list in account_lists) account_list.unselect_all ();
                    mark_active_row (row);
                    announce_selection (mailbox);
                    update_add_menu_context ();
                }
            }
        });
        var identity = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 9);
        identity.add_css_class ("sidebar-identity");
        identity.set_margin_start (14); identity.set_margin_end (14);
        identity.set_margin_top (12); identity.set_margin_bottom (5);
        var identity_badge = new Gtk.CenterBox ();
        identity_badge.add_css_class ("sidebar-identity-badge");
        identity_badge.set_size_request (30, 30);
        identity_badge.halign = Gtk.Align.CENTER; identity_badge.valign = Gtk.Align.CENTER;
        var identity_icon = new Gtk.Image.from_icon_name ("mail-unread-symbolic");
        identity_icon.halign = Gtk.Align.CENTER;
        identity_icon.valign = Gtk.Align.CENTER;
        identity_icon.add_css_class ("sidebar-identity-icon");
        identity_badge.center_widget = identity_icon;
        identity.append (identity_badge);
        var identity_label = new Gtk.Label ("Mailficient");
        identity_label.xalign = 0; identity_label.hexpand = true;
        identity_label.add_css_class ("sidebar-identity-title");
        identity.append (identity_label);
        append (identity);

        var favorites_header = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
        favorites_header.add_css_class ("favorites-header");
        favorites_header.set_margin_start (14); favorites_header.set_margin_end (10);
        favorites_header.set_margin_top (7); favorites_header.set_margin_bottom (3);
        var favorites_title = new Gtk.Label ("Favorites");
        favorites_title.xalign = 0; favorites_title.hexpand = true;
        favorites_title.add_css_class ("heading");
        favorites_title.add_css_class ("sidebar-section-title");
        favorites_header.append (favorites_title);
        add_menu_button.icon_name = "list-add-symbolic";
        add_menu_button.always_show_arrow = false;
        add_menu_button.add_css_class ("flat");
        add_menu_button.add_css_class ("sidebar-add-button");
        add_menu_button.tooltip_text = "Add folder, smart folder, rule, or account";
        Accessibility.label (add_menu_button, "Add mail item");
        add_popover = build_add_popover ();
        add_menu_button.popover = add_popover;
        favorites_header.append (add_menu_button);
        append (favorites_header);

        var scroller = new Gtk.ScrolledWindow ();
        scroller.hscrollbar_policy = Gtk.PolicyType.NEVER;
        scroller.set_child (list);
        append (scroller);
        scroller.vexpand = true;

        // A single capture-phase controller covers mailbox rows, account
        // headers, Favorites, and otherwise-empty sidebar space. Keeping the
        // controller on the stable sidebar also means a repository reload
        // cannot leave row-specific context-menu handlers behind.
        var context_click = new Gtk.GestureClick ();
        context_click.button = Gdk.BUTTON_SECONDARY;
        context_click.propagation_phase = Gtk.PropagationPhase.CAPTURE;
        context_click.pressed.connect ((presses, x, y) => {
            context_click.set_state (Gtk.EventSequenceState.CLAIMED);
            show_context_menu_at (x, y);
        });
        add_controller (context_click);

        reload ();

        if (Environment.get_variable ("MAILFICIENT_QA_SIDEBAR_MENU") == "1")
            Idle.add (() => { show_context_menu_at (96, 210); return Source.REMOVE; });
    }

    private Gtk.Popover build_add_popover () {
        var popover = new Gtk.Popover ();
        popover.has_arrow = false;
        popover.add_css_class ("sidebar-add-popover");
        var menu = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
        menu.add_css_class ("sidebar-add-menu");

        add_mailbox_button = make_add_menu_button (
            "folder-new-symbolic", "New Folder…");
        add_mailbox_button.clicked.connect (() => {
            add_menu_button.popdown ();
            request_new_mailbox ();
        });
        menu.append (add_mailbox_button);

        add_subfolder_button = make_add_menu_button (
            "folder-new-symbolic", "New Subfolder…");
        add_subfolder_button.clicked.connect (() => {
            add_menu_button.popdown ();
            request_new_subfolder ();
        });
        menu.append (add_subfolder_button);

        var automation_separator = new Gtk.Separator (Gtk.Orientation.HORIZONTAL);
        automation_separator.set_margin_top (3); automation_separator.set_margin_bottom (3);
        menu.append (automation_separator);

        var smart = make_add_menu_button ("view-filter-symbolic", "New Smart Folder…");
        smart.clicked.connect (() => {
            add_menu_button.popdown ();
            create_smart_mailbox_requested ();
        });
        menu.append (smart);

        var rule = make_add_menu_button ("system-run-symbolic", "New Rule…");
        rule.clicked.connect (() => {
            add_menu_button.popdown ();
            create_rule_requested ();
        });
        menu.append (rule);

        var account_separator = new Gtk.Separator (Gtk.Orientation.HORIZONTAL);
        account_separator.set_margin_top (3); account_separator.set_margin_bottom (3);
        menu.append (account_separator);

        var account = make_add_menu_button ("avatar-default-symbolic", "Add or Manage Accounts…");
        account.clicked.connect (() => {
            add_menu_button.popdown ();
            accounts_requested ();
        });
        menu.append (account);
        popover.child = menu;
        update_add_menu_context ();
        return popover;
    }

    private static Gtk.Button make_add_menu_button (string icon_name, string label_text) {
        var button = new Gtk.Button ();
        button.add_css_class ("flat");
        button.add_css_class ("sidebar-add-menu-item");
        var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 9);
        var icon = new Gtk.Image.from_icon_name (icon_name);
        icon.add_css_class ("dim-label");
        row.append (icon);
        var label = new Gtk.Label (label_text);
        label.xalign = 0; label.hexpand = true;
        row.append (label); button.child = row;
        Accessibility.label (button, label_text);
        return button;
    }

    private AccountSettings? account_for_mailbox (Mailbox? mailbox) {
        if (mailbox == null || mailbox.account_id == "") return null;
        try { return cache.find_account (mailbox.account_id); }
        catch (Error error) {
            warning ("Could not resolve folder account: %s", error.message);
            return null;
        }
    }

    private static bool is_productivity_mailbox (Mailbox mailbox) {
        return mailbox.id == CachedMailRepository.TASK_TODAY_ID ||
            mailbox.id == CachedMailRepository.TASK_PLANNED_ID ||
            mailbox.id == CachedMailRepository.GNOME_CALENDAR_ID;
    }

    private static bool is_mutable_folder (Mailbox mailbox) {
        return mailbox.account_id != "" && mailbox.remote_name != "" &&
            mailbox.role == MailboxRole.CUSTOM;
    }

    private Mailbox? selected_context_mailbox () {
        return selected_mailbox_id == "" ? null : known_mailboxes[selected_mailbox_id];
    }

    private void update_add_menu_context () {
        var mailbox = selected_context_mailbox ();
        var account = account_for_mailbox (mailbox);
        add_subfolder_button.visible = mailbox != null && account != null &&
            is_mutable_folder (mailbox);
        add_mailbox_button.tooltip_text = account == null ?
            "Choose an account and location" :
            "Create a top-level folder in %s".printf (account.display_name);
    }

    private void request_new_mailbox () {
        var account = account_for_mailbox (selected_context_mailbox ());
        if (account == null) create_folder_any_requested ();
        else create_folder_requested (account, null);
    }

    private void request_new_subfolder () {
        var mailbox = selected_context_mailbox ();
        var account = account_for_mailbox (mailbox);
        if (mailbox != null && account != null && is_mutable_folder (mailbox))
            create_folder_requested (account, mailbox);
    }

    private Gtk.ListBoxRow create_row (Mailbox mailbox, int depth = 0,
                                       bool hierarchical = false,
                                       bool has_children = false,
                                       bool expanded = true) {
        var row = new Gtk.ListBoxRow ();
        row.add_css_class ("mailbox-row");
        row.set_data<Mailbox> ("mailbox", mailbox);
        if (is_productivity_mailbox (mailbox)) row.add_css_class ("productivity-mailbox");
        else if (mailbox.account_id == "") row.add_css_class ("unified-mailbox");
        else row.add_css_class ("account-mailbox");
        var content = new MailboxRowContent (mailbox, depth, hierarchical,
            has_children, expanded);
        if (has_children) {
            content.expansion_requested.connect (() => {
                set_mailbox_collapsed (mailbox.id,
                    !collapsed_mailboxes.contains (mailbox.id));
                reload (false);
            });
        }
        row.set_child (content);
        return row;
    }

    private void append_mailbox (Gtk.ListBox owner, Mailbox mailbox,
                                 int depth = 0, bool hierarchical = false,
                                 bool has_children = false, bool expanded = true) {
        var row = create_row (mailbox, depth, hierarchical, has_children, expanded);
        owner.append (row);
        add_mailbox_drag_and_drop (row, mailbox, owner == list);
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

    private void add_mailbox_drag_and_drop (Gtk.ListBoxRow row, Mailbox mailbox,
                                            bool favorite_row) {
        // Local productivity rows are navigation destinations, not folders.
        // They must not present a drag affordance that suggests reordering or
        // accepting mail is possible.
        if (!favorite_row && mailbox.account_id == "") return;
        var source = new Gtk.DragSource ();
        source.actions = Gdk.DragAction.MOVE;
        source.propagation_phase = Gtk.PropagationPhase.CAPTURE;
        source.prepare.connect ((x, y) => {
            Value value = Value (typeof (string));
            value.set_string ((favorite_row ? FAVORITE_DRAG_PREFIX : MAILBOX_DRAG_PREFIX) +
                mailbox.id);
            return new Gdk.ContentProvider.for_value (value);
        });
        row.add_controller (source);

        var target = new Gtk.DropTarget (typeof (string),
            Gdk.DragAction.MOVE | Gdk.DragAction.COPY);
        target.preload = true;
        target.propagation_phase = Gtk.PropagationPhase.CAPTURE;
        target.enter.connect ((x, y) => {
            row.add_css_class ("mailbox-drop-target");
            return Gdk.DragAction.MOVE | Gdk.DragAction.COPY;
        });
        target.leave.connect (() => row.remove_css_class ("mailbox-drop-target"));
        target.drop.connect ((value, x, y) => {
            row.remove_css_class ("mailbox-drop-target");
            string? payload = value.get_string ();
            if (payload == null) return false;
            if (payload.has_prefix (FAVORITE_DRAG_PREFIX)) {
                if (!favorite_row) return false;
                string dragged_id = payload.substring (FAVORITE_DRAG_PREFIX.length);
                if (dragged_id == mailbox.id) return false;
                reorder_favorite (dragged_id, mailbox.id,
                    y > row.get_height () / 2.0);
                return true;
            }
            if (payload.has_prefix (MAILBOX_DRAG_PREFIX)) {
                if (favorite_row || mailbox.account_id == "") return false;
                string dragged_id = payload.substring (MAILBOX_DRAG_PREFIX.length);
                if (dragged_id == mailbox.id) return false;
                return reorder_account_mailbox (dragged_id, mailbox,
                    y > row.get_height () / 2.0);
            }
            if (payload.has_prefix (MessageRow.DRAG_PAYLOAD_PREFIX)) {
                if (mailbox.account_id == "" || mailbox.role == MailboxRole.VIP ||
                    mailbox.role == MailboxRole.FLAGGED) return false;
                var ids = parse_message_drag_payload (payload);
                if (ids.length == 0) return false;
                bool copy = false;
                var drop = target.current_drop;
                if (drop != null) {
                    var drag = drop.get_drag ();
                    copy = drag != null &&
                        drag.get_selected_action () == Gdk.DragAction.COPY;
                }
                messages_dropped (mailbox, ids, copy);
                return true;
            }
            return false;
        });
        row.add_controller (target);
    }

    private static string[] parse_message_drag_payload (string payload) {
        var result = new Gee.ArrayList<string> ();
        string body = payload.substring (MessageRow.DRAG_PAYLOAD_PREFIX.length);
        foreach (var raw in body.split ("\n")) {
            string id = raw.strip ();
            if (id != "" && !result.contains (id)) result.add (id);
        }
        string[] ids = new string[result.size];
        for (int index = 0; index < result.size; index++) ids[index] = result[index];
        return ids;
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

    private Gee.ArrayList<string> account_mailbox_order (string account_id) {
        var result = new Gee.ArrayList<string> ();
        try {
            foreach (var raw in cache.preference (
                "account-mailbox-order-" + account_id, "").split ("\n")) {
                string id = raw.strip ();
                if (id != "" && !result.contains (id)) result.add (id);
            }
        } catch (Error error) {
            warning ("Could not load mailbox order: %s", error.message);
        }
        return result;
    }

    private void save_account_mailbox_order (string account_id,
                                             Gee.List<string> order) {
        var serialized = new StringBuilder ();
        foreach (var id in order) {
            if (serialized.len > 0) serialized.append_c ('\n');
            serialized.append (id);
        }
        try {
            cache.set_preference ("account-mailbox-order-" + account_id,
                serialized.str);
        } catch (Error error) {
            warning ("Could not save mailbox order: %s", error.message);
        }
    }

    private bool reorder_account_mailbox (string dragged_id, Mailbox target,
                                          bool after_target) {
        var dragged = known_mailboxes[dragged_id];
        if (dragged == null || dragged.account_id == "" ||
            dragged.account_id != target.account_id) return false;
        string dragged_parent = mailbox_parent_ids[dragged.id] ?? "";
        string target_parent = mailbox_parent_ids[target.id] ?? "";
        // Reordering changes presentation only. Moving a mailbox under another
        // mailbox is a server operation and must stay in the explicit folder
        // workflow, so drops are accepted only between siblings.
        if (dragged_parent != target_parent) return false;

        var order = account_mailbox_order (target.account_id);
        foreach (var mailbox in known_mailbox_order) {
            if (mailbox.account_id == target.account_id &&
                mailbox_parent_ids.has_key (mailbox.id) &&
                !order.contains (mailbox.id)) order.add (mailbox.id);
        }
        int dragged_index = order.index_of (dragged.id);
        int target_index = order.index_of (target.id);
        if (dragged_index < 0 || target_index < 0) return false;
        order.remove_at (dragged_index);
        target_index = order.index_of (target.id);
        int insertion_index = target_index + (after_target ? 1 : 0);
        order.insert (int.max (0, int.min (insertion_index, order.size)),
            dragged.id);
        save_account_mailbox_order (target.account_id, order);
        reload (false);
        return true;
    }

    private void announce_selection (Mailbox mailbox) {
        selected_mailbox_id = mailbox.id;
        if (!suppress_announcement) mailbox_selected (mailbox);
    }

    private void show_context_menu_at (double x, double y) {
        Mailbox? mailbox = null;
        AccountSettings? clicked_account = null;
        Gtk.ListBoxRow? clicked_row = null;
        Gtk.Widget? target = pick (x, y, Gtk.PickFlags.DEFAULT);
        while (target != null && target != this) {
            var row = target as Gtk.ListBoxRow;
            if (row != null) {
                // Count refreshes replace the row's Mailbox snapshot. Resolve
                // it at click time so folder actions never use stale names or
                // provider paths captured by the original closure.
                mailbox = row.get_data<Mailbox> ("mailbox");
                clicked_account = row.get_data<AccountSettings> ("account");
                if (mailbox != null || clicked_account != null) {
                    clicked_row = row;
                    break;
                }
            }
            target = target.get_parent ();
        }
        show_sidebar_menu (x, y, mailbox, clicked_account, clicked_row);
    }

    private void show_sidebar_menu (double x, double y, Mailbox? mailbox,
                                    AccountSettings? clicked_account,
                                    Gtk.ListBoxRow? clicked_row = null) {
        clear_context_row ();
        context_row = clicked_row;
        if (context_row != null) context_row.add_css_class ("context-mailbox");
        var previous_menu = context_menu;
        context_menu = null;
        context_actions = null;
        var previous_action_host = context_action_host;
        context_action_host = null;
        if (previous_menu != null) {
            previous_menu.popdown ();
            if (previous_menu.get_parent () != null) previous_menu.unparent ();
        }
        if (previous_action_host != null)
            previous_action_host.insert_action_group ("sidebar-context", null);

        AccountSettings? account = clicked_account;
        try {
            if (account == null && mailbox != null && mailbox.account_id != "")
                account = cache.find_account (mailbox.account_id);
        }
        catch (Error error) { warning ("Could not resolve folder account: %s", error.message); }

        var model = new Menu ();
        var actions = new SimpleActionGroup ();
        context_actions = actions;
        // GtkPopover is a separate native surface. Its menu items reliably
        // inherit actions from the root window (as the message-row `win.*`
        // menus do), but not from an arbitrary sibling/anchor widget.
        var action_host = get_root () as Gtk.Widget;
        if (action_host == null) action_host = this;
        context_action_host = action_host;
        action_host.insert_action_group ("sidebar-context", actions);

        var creation = new Menu ();
        var new_mailbox = append_context_action (actions, creation, "new-mailbox", "New Folder…");
        if (account != null)
            new_mailbox.activate.connect (() => create_folder_requested (account, null));
        else
            new_mailbox.activate.connect (() => create_folder_any_requested ());

        if (mailbox != null && is_mutable_folder (mailbox)) {
            var subfolder = append_context_action (actions, creation, "new-subfolder",
                "New Subfolder of “%s”…".printf (mailbox.name));
            if (account != null)
                subfolder.activate.connect (() => create_folder_requested (account, mailbox));
            else subfolder.set_enabled (false);
        }
        model.append_section (null, creation);

        var mailbox_actions = new Menu ();
        if (mailbox != null && mailbox.account_id != "") {
            bool favorite = is_favorite (mailbox.id);
            var favorite_action = append_context_action (actions, mailbox_actions, "favorite",
                favorite ? "Remove from Favorites" : "Add to Favorites");
            favorite_action.activate.connect (() => set_favorite (mailbox.id, !favorite));
        }

        if (mailbox != null && is_mutable_folder (mailbox)) {
            var rename = append_context_action (actions, mailbox_actions, "rename",
                "Rename “%s”…".printf (mailbox.name));
            rename.activate.connect (() => rename_folder_requested (mailbox));
        }

        if (mailbox != null && mailbox.account_id != "") {
            var export = append_context_action (actions, mailbox_actions, "export",
                "Export “%s”…".printf (mailbox.name));
            export.activate.connect (() => export_mailbox_requested (mailbox));
        }

        if (mailbox != null && is_mutable_folder (mailbox)) {
            var remove = append_context_action (actions, mailbox_actions, "delete",
                "Delete “%s”…".printf (mailbox.name));
            remove.activate.connect (() => delete_folder_requested (mailbox));
        }

        if (mailbox != null && (mailbox.role == MailboxRole.TRASH || mailbox.role == MailboxRole.JUNK)) {
            var empty = append_context_action (actions, mailbox_actions, "empty",
                mailbox.role == MailboxRole.TRASH ? "Empty Trash…" : "Empty Junk…");
            empty.activate.connect (() => {
                if (account != null) empty_mailbox_requested (mailbox);
                else empty_role_requested (mailbox.role);
            });
        }
        if (mailbox_actions.get_n_items () > 0) model.append_section (null, mailbox_actions);

        if (account != null) {
            var account_actions = new Menu ();
            var sync = append_context_action (actions, account_actions, "synchronize",
                "Synchronize “%s”".printf (account.display_name));
            sync.activate.connect (() => synchronize_account_requested (account));
            var edit = append_context_action (actions, account_actions, "edit-account",
                "Edit “%s”…".printf (account.display_name));
            edit.activate.connect (() => edit_account_requested (account));
            var info = append_context_action (actions, account_actions, "account-info", "Get Account Info");
            info.activate.connect (() => account_info_requested (account));
            model.append_section (null, account_actions);
        }

        var rule_actions = new Menu ();
        var new_rule = append_context_action (actions, rule_actions, "new-rule", "New Rule…");
        new_rule.activate.connect (() =>
            create_rule_for_mailbox_requested (account, mailbox));
        rule_actions.append ("Manage Rules…", "win.rules");
        model.append_section (null, rule_actions);

        var popover = new Gtk.PopoverMenu.from_model (model);
        context_menu = popover;
        popover.set_parent (this); popover.autohide = true; popover.has_arrow = false;
        popover.pointing_to = { (int) x, (int) y, 1, 1 };
        popover.closed.connect (() => {
            if (context_menu == popover) {
                context_menu = null;
                // GtkPopoverMenu may close itself before it dispatches the
                // selected GAction. Keep the group alive briefly so the menu
                // item can still resolve and activate its action.
                Timeout.add (250, () => {
                    if (context_menu == null && context_actions == actions) {
                        context_actions = null;
                        var current_action_host = context_action_host;
                        context_action_host = null;
                        if (current_action_host != null)
                            current_action_host.insert_action_group ("sidebar-context", null);
                    }
                    if (popover.get_parent () != null) popover.unparent ();
                    clear_context_row ();
                    return Source.REMOVE;
                });
            }
        });
        popover.popup ();
    }

    private void clear_context_row () {
        if (context_row != null) context_row.remove_css_class ("context-mailbox");
        context_row = null;
    }

    private static SimpleAction append_context_action (SimpleActionGroup actions, Menu section,
                                                        string name, string label) {
        var action = new SimpleAction (name, null);
        actions.add_action (action);
        section.append (label, "sidebar-context.%s".printf (name));
        return action;
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
            if (is_productivity_mailbox (mailbox)) continue;
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

    private void append_follow_up (Gee.List<Mailbox> mailboxes) {
        var follow_up = new Gee.ArrayList<Mailbox> ();
        string[] follow_up_ids = { CachedMailRepository.TASK_TODAY_ID,
                                   CachedMailRepository.TASK_PLANNED_ID,
                                   CachedMailRepository.GNOME_CALENDAR_ID };
        foreach (var id in follow_up_ids) {
            foreach (var mailbox in mailboxes) {
                if (mailbox.id == id) {
                    follow_up.add (mailbox);
                    break;
                }
            }
        }
        if (follow_up.size == 0) return;

        var section_row = new Gtk.ListBoxRow ();
        section_row.selectable = false; section_row.activatable = false;
        section_row.add_css_class ("follow-up-section-row");
        var expander = new Gtk.Expander (null);
        expander.add_css_class ("follow-up-section");
        expander.expanded = follow_up_expanded;
        expander.set_margin_start (12); expander.set_margin_end (10);
        expander.set_margin_top (9); expander.set_margin_bottom (5);
        expander.notify["expanded"].connect (() => {
            follow_up_expanded = expander.expanded;
            try {
                cache.set_preference ("follow-up-sidebar-expanded",
                    follow_up_expanded ? "1" : "0");
            } catch (Error error) {
                warning ("Could not save Follow Up sidebar state: %s", error.message);
            }
        });
        var heading = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        var icon = new Gtk.Image.from_icon_name ("task-due-symbolic");
        icon.add_css_class ("dim-label");
        heading.append (icon);
        var label = new Gtk.Label ("Follow Up");
        label.xalign = 0; label.hexpand = true; label.add_css_class ("heading");
        label.add_css_class ("follow-up-title");
        heading.append (label);
        expander.label_widget = heading;

        var follow_up_list = new Gtk.ListBox ();
        follow_up_list.selection_mode = Gtk.SelectionMode.SINGLE;
        follow_up_list.add_css_class ("navigation-sidebar");
        follow_up_list.add_css_class ("follow-up-list");
        account_lists.add (follow_up_list);
        follow_up_list.row_selected.connect ((row) => {
            if (row == null) return;
            var mailbox = row.get_data<Mailbox> ("mailbox");
            if (mailbox == null) return;
            list.unselect_all ();
            foreach (var other_list in account_lists)
                if (other_list != follow_up_list) other_list.unselect_all ();
            mark_active_row (row);
            announce_selection (mailbox);
            update_add_menu_context ();
        });
        foreach (var mailbox in follow_up)
            append_mailbox (follow_up_list, mailbox);
        expander.child = follow_up_list;
        section_row.child = expander;
        list.append (section_row);
    }

    private static int last_folder_separator (string remote_name) {
        int separator = -1;
        for (int index = 0; index < remote_name.length; index++)
            if (remote_name[index] == '/' || remote_name[index] == '\\' ||
                remote_name[index] == '.')
                separator = index;
        return separator;
    }

    private static string parent_remote_name (Mailbox mailbox) {
        int separator = last_folder_separator (mailbox.remote_name);
        return separator < 0 ? "" : mailbox.remote_name.substring (0, separator);
    }

    private static bool account_folder_is_visible (Mailbox mailbox,
                                                   string account_id) {
        if (mailbox.account_id != account_id || mailbox.role == MailboxRole.VIP ||
            mailbox.role == MailboxRole.FLAGGED) return false;
        // Provider Drafts are mirrored into the editable unified Drafts view.
        return mailbox.role != MailboxRole.DRAFTS;
    }

    private void map_folder_parents (Gee.List<Mailbox> folders) {
        var by_remote_name = new Gee.HashMap<string, Mailbox> ();
        foreach (var mailbox in folders)
            if (mailbox.remote_name != "") by_remote_name[mailbox.remote_name] = mailbox;
        foreach (var mailbox in folders) {
            string parent_name = parent_remote_name (mailbox);
            var parent = parent_name == "" ? null : by_remote_name[parent_name];
            mailbox_parent_ids[mailbox.id] = parent == null ? "" : parent.id;
        }
    }

    private Gee.ArrayList<Mailbox> ordered_folder_children (
        Gee.List<Mailbox> folders, string parent_id, Gee.List<string> saved_order) {
        var result = new Gee.ArrayList<Mailbox> ();
        foreach (var id in saved_order) {
            foreach (var mailbox in folders) {
                if (mailbox.id == id && !result.contains (mailbox) &&
                    (mailbox_parent_ids[mailbox.id] ?? "") == parent_id)
                    result.add (mailbox);
            }
        }
        foreach (var mailbox in folders)
            if (!result.contains (mailbox) &&
                (mailbox_parent_ids[mailbox.id] ?? "") == parent_id)
                result.add (mailbox);
        return result;
    }

    private bool folder_has_children (Gee.List<Mailbox> folders, string parent_id) {
        foreach (var mailbox in folders)
            if ((mailbox_parent_ids[mailbox.id] ?? "") == parent_id) return true;
        return false;
    }

    private void append_folder_level (Gtk.ListBox owner, Gee.List<Mailbox> folders,
                                      string parent_id, Gee.List<string> saved_order,
                                      Gee.Set<string> appended, int depth) {
        foreach (var mailbox in ordered_folder_children (folders, parent_id, saved_order)) {
            if (!appended.add (mailbox.id)) continue;
            bool has_children = folder_has_children (folders, mailbox.id);
            bool expanded = !collapsed_mailboxes.contains (mailbox.id);
            append_mailbox (owner, mailbox, depth, true, has_children, expanded);
            if (has_children && expanded)
                append_folder_level (owner, folders, mailbox.id, saved_order,
                    appended, depth + 1);
        }
    }

    private void add_account_group (string account_id, string display_name, string email,
                                    Gee.List<Mailbox> mailboxes, bool allow_folder_creation,
                                    AccountSettings? context_account = null) {
        bool first_account = account_group_count++ == 0;
        var row = new Gtk.ListBoxRow (); row.selectable = false; row.activatable = false;
        if (context_account != null) row.set_data<AccountSettings> ("account", context_account);
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
                update_add_menu_context ();
            }
        });
        var account_folders = new Gee.ArrayList<Mailbox> ();
        foreach (var mailbox in mailboxes)
            if (account_folder_is_visible (mailbox, account_id))
                account_folders.add (mailbox);
        map_folder_parents (account_folders);
        var appended = new Gee.HashSet<string> ();
        var saved_order = account_mailbox_order (account_id);
        append_folder_level (folders, account_folders, "", saved_order,
            appended, 0);
        // A malformed or cyclic provider path must not make a mailbox vanish.
        foreach (var mailbox in account_folders) {
            if (appended.contains (mailbox.id)) continue;
            mailbox_parent_ids[mailbox.id] = "";
            append_mailbox (folders, mailbox, 0, true, false, true);
        }
        expander.child = folders;
        var account_section = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        if (first_account) {
            var section = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            var separator = new Gtk.Separator (Gtk.Orientation.HORIZONTAL);
            separator.set_margin_start (10); separator.set_margin_end (10);
            separator.set_margin_top (10); separator.set_margin_bottom (8);
            section.append (separator);
            var heading = new Gtk.Label ("Accounts");
            heading.xalign = 0; heading.add_css_class ("heading");
            heading.add_css_class ("sidebar-section-title");
            heading.set_margin_start (14); heading.set_margin_bottom (2);
            section.append (heading);
            account_section.append (section);
        }
        account_section.append (expander);
        row.set_child (account_section);
        list.append (row);
    }

    private void load_sidebar_state () {
        try {
            foreach (var id in cache.preference ("collapsed-sidebar-accounts", "").split ("\n"))
                if (id.strip () != "") collapsed_accounts.add (id.strip ());
            foreach (var id in cache.preference ("expanded-sidebar-accounts", "").split ("\n"))
                if (id.strip () != "") expanded_accounts.add (id.strip ());
            foreach (var id in cache.preference ("collapsed-sidebar-mailboxes", "").split ("\n"))
                if (id.strip () != "") collapsed_mailboxes.add (id.strip ());
            follow_up_expanded = cache.preference (
                "follow-up-sidebar-expanded", "0") == "1";
        } catch (Error error) {
            warning ("Could not load sidebar state: %s", error.message);
        }
    }

    private void set_mailbox_collapsed (string mailbox_id, bool collapsed) {
        bool changed = collapsed ? collapsed_mailboxes.add (mailbox_id) :
            collapsed_mailboxes.remove (mailbox_id);
        if (!changed) return;
        save_collapsed_mailboxes ();
    }

    private void save_collapsed_mailboxes () {
        var serialized = new StringBuilder ();
        foreach (var id in collapsed_mailboxes) {
            if (serialized.len > 0) serialized.append_c ('\n');
            serialized.append (id);
        }
        try { cache.set_preference ("collapsed-sidebar-mailboxes", serialized.str); }
        catch (Error error) {
            warning ("Could not save collapsed mailboxes: %s", error.message);
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
        clear_context_row ();
        mark_active_row (null);
        Gtk.ListBoxRow? existing;
        while ((existing = list.get_row_at_index (0)) != null) list.remove (existing);
        mailbox_rows.clear (); mailbox_row_copies.clear ();
        mailbox_owners.clear (); account_lists.clear ();
        account_group_count = 0;
        mailbox_parent_ids.clear ();
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
            append_follow_up (mailboxes);
            if (demo) add_account_group (DemoMailRepository.ACCOUNT_ID, "Demo Account", "alex@example.com", mailboxes, false);
            else foreach (var account in accounts)
                add_account_group (account.id, account.display_name, account.email, mailboxes, true, account);
        } catch (Error error) {
            warning ("Could not load account summaries: %s", error.message);
        }
        if (restore_id != "" && select_mailbox (restore_id)) {
            suppress_announcement = false;
            update_add_menu_context ();
            DebugTrace.duration ("sidebar", "reload restored complete", started);
            return;
        }
        var first = list.get_row_at_index (0); if (first != null) list.select_row (first);
        suppress_announcement = false;
        update_add_menu_context ();
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

    public bool reveal_mailbox (string id) {
        if (!known_mailboxes.has_key (id)) return false;
        bool changed = false;
        string parent_id = mailbox_parent_ids[id] ?? "";
        var visited = new Gee.HashSet<string> ();
        while (parent_id != "" && visited.add (parent_id)) {
            if (collapsed_mailboxes.remove (parent_id)) changed = true;
            parent_id = mailbox_parent_ids[parent_id] ?? "";
        }
        if (changed) {
            save_collapsed_mailboxes ();
            reload (false);
        }
        return select_mailbox (id);
    }

    // Folder creation is followed by an account sync, so the durable mailbox
    // already exists before this is called. Resolve it by location, pin it to
    // Favorites, and select the favorite copy instead of leaving a new folder
    // hidden inside a collapsed account tree.
    public bool select_new_mailbox (string account_id, string parent_remote,
                                    string name) {
        string clean_name = name.strip ();
        Mailbox? fallback = null;
        int fallback_count = 0;
        foreach (var mailbox in known_mailbox_order) {
            if (mailbox.account_id != account_id ||
                mailbox.role != MailboxRole.CUSTOM ||
                mailbox.name != clean_name) continue;
            fallback = mailbox; fallback_count++;
            if (parent_remote_name (mailbox) == parent_remote) {
                if (!is_favorite (mailbox.id)) set_favorite (mailbox.id, true);
                return select_mailbox (mailbox.id);
            }
        }
        // Some providers normalize the hierarchy delimiter returned after
        // CREATE. A name-only fallback is safe only when it is unambiguous.
        if (fallback == null || fallback_count != 1) return false;
        if (!is_favorite (fallback.id)) set_favorite (fallback.id, true);
        return select_mailbox (fallback.id);
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
        update_add_menu_context ();
    }
}
}
