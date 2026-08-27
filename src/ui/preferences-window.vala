namespace Mailficient {
public class PreferencesWindow : Adw.PreferencesDialog {
    public signal void account_saved (AccountSettings account);
    public signal void accounts_changed ();
    public signal void smart_mailboxes_changed ();
    public signal void automation_changed ();
    public signal void sender_safety_changed ();
    private CacheDatabase cache;
    private MailSettingsStore settings;
    private RemoteContentPolicy remote_content_policy;
    private Gtk.StringList identity_labels = new Gtk.StringList (null);
    private Gee.ArrayList<string> identity_ids = new Gee.ArrayList<string> ();
    private Adw.ComboRow identity_row;
    private Gtk.Switch signature_enabled_switch = new Gtk.Switch ();
    private Adw.ActionRow signature_enabled_row;
    private Gtk.TextView signature_editor = new Gtk.TextView ();
    private bool loading;
    private string current_identity = "";
    private Adw.ActionRow safe_senders_row;
    private Adw.ActionRow blocked_senders_row;
    private Adw.ActionRow remote_image_senders_row;
    private Adw.PreferencesGroup rules_group;
    private Gee.ArrayList<Adw.ActionRow> rule_rows = new Gee.ArrayList<Adw.ActionRow> ();
    private Adw.PreferencesGroup quick_steps_group;
    private Gee.ArrayList<Adw.ActionRow> quick_step_rows = new Gee.ArrayList<Adw.ActionRow> ();
    private Adw.ActionRow automation_status_row;
    private Adw.EntryRow smart_name_row;
    private Adw.EntryRow smart_query_row;
    private Adw.PreferencesGroup smart_group;
    private Gee.ArrayList<Adw.ActionRow> smart_rows = new Gee.ArrayList<Adw.ActionRow> ();
    private Adw.ComboRow vacation_identity_row;

    public PreferencesWindow (CacheDatabase cache, MailSettingsStore settings,
                              RemoteContentPolicy remote_content_policy,
                              CredentialCleanupService credential_cleanup,
                              AccountProvisioningService? account_provisioner,
                              MailEngine? engine, AccountSyncService? sync_service,
                              OnlineAccountService online_accounts) {
        title = "Settings"; content_width = 900; content_height = 680; search_enabled = true;
        this.cache = cache; this.settings = settings; this.remote_content_policy = remote_content_policy;
        var accounts_page = new AccountSettingsPage (cache, credential_cleanup, account_provisioner,
            engine, sync_service, online_accounts);
        accounts_page.account_saved.connect ((account) => account_saved (account));
        accounts_page.accounts_changed.connect (() => accounts_changed ());
        add (accounts_page);
        var general_page = build_general_page (); general_page.name = "general"; add (general_page);
        var composing_page = build_composing_page (); composing_page.name = "composing"; add (composing_page);
        var rules_page = build_rules_page (); rules_page.name = "rules"; add (rules_page);
        var privacy_page = build_privacy_page (); privacy_page.name = "privacy"; add (privacy_page);
        load_identities ();
        notify["visible-page-name"].connect (() => {
            string? page_name = get_visible_page_name ();
            if (page_name != null && page_name != "") settings.preferences_page = page_name;
        });
        string requested_page = Environment.get_variable ("MAILFICIENT_QA_PREFERENCES") ?? "";
        if (requested_page == "" || requested_page == "0")
            requested_page = settings.preferences_page;
        Gtk.Widget? requested_focus = null;
        string requested_sender_page = "";
        switch (requested_page) {
        case "junk":
            requested_page = "privacy"; requested_sender_page = "blocked"; break;
        case "smart-mailboxes":
            requested_page = "rules"; requested_focus = smart_name_row; break;
        case "vacation":
            requested_page = "composing"; requested_focus = vacation_identity_row; break;
        case "accounts": case "general": case "composing": case "rules": case "privacy":
            break;
        default:
            requested_page = "general"; break;
        }
        set_visible_page_name (requested_page);
        if (requested_focus != null) {
            Gtk.Widget focus_target = requested_focus;
            Idle.add (() => {
                if (focus_target.get_root () != null)
                    focus_target.grab_focus ();
                return Source.REMOVE;
            });
        }
        if (requested_sender_page != "") {
            string sender_page = requested_sender_page;
            Idle.add (() => {
                open_sender_lists (sender_page);
                return Source.REMOVE;
            });
        }
        if (Environment.get_variable ("MAILFICIENT_QA_CONFIGURE_SIGNATURE") == "1") Idle.add (() => {
            signature_editor.buffer.text = "Mailficient QA Signature";
            signature_enabled_switch.active = true;
            return Source.REMOVE;
        });
    }

    private Adw.PreferencesPage build_general_page () {
        var page = new Adw.PreferencesPage (); page.title = "General"; page.icon_name = "preferences-system-symbolic";
        var appearance_group = new Adw.PreferencesGroup (); appearance_group.title = "Appearance";
        var schemes = new Gtk.StringList (null);
        schemes.append ("System Default"); schemes.append ("Light"); schemes.append ("Dark");
        var appearance = new Adw.ComboRow (); appearance.title = "Color scheme";
        appearance.subtitle = "Choose how Mailficient’s interface is displayed";
        appearance.model = schemes;
        appearance.selected = settings.appearance == "light" ? 1 :
            settings.appearance == "dark" ? 2 : 0;
        appearance.notify["selected"].connect (() => {
            settings.appearance = appearance.selected == 1 ? "light" :
                appearance.selected == 2 ? "dark" : "system";
        });
        appearance_group.add (appearance); page.add (appearance_group);

        var checking = new Adw.PreferencesGroup (); checking.title = "Checking for Mail";
        var intervals = new Gtk.StringList (null);
        intervals.append ("Manually"); intervals.append ("Every minute");
        intervals.append ("Every 5 minutes"); intervals.append ("Every 15 minutes");
        intervals.append ("Every 30 minutes"); intervals.append ("Every hour");
        var interval = new Adw.ComboRow (); interval.title = "Check for new mail"; interval.model = intervals;
        interval.subtitle = "Changes take effect immediately";
        switch (settings.sync_interval_minutes) {
        case 0: interval.selected = 0; break;
        case 1: interval.selected = 1; break;
        case 15: interval.selected = 3; break;
        case 30: interval.selected = 4; break;
        case 60: interval.selected = 5; break;
        default: interval.selected = 2; break;
        }
        interval.notify["selected"].connect (() => {
            switch (interval.selected) {
            case 0: settings.sync_interval_minutes = 0; break;
            case 1: settings.sync_interval_minutes = 1; break;
            case 3: settings.sync_interval_minutes = 15; break;
            case 4: settings.sync_interval_minutes = 30; break;
            case 5: settings.sync_interval_minutes = 60; break;
            default: settings.sync_interval_minutes = 5; break;
            }
        });
        checking.add (interval);
        var startup = new Adw.SwitchRow (); startup.title = "Check when Mailficient starts";
        startup.subtitle = "Synchronize configured accounts after opening the application";
        startup.active = settings.sync_on_startup;
        startup.notify["active"].connect (() => settings.sync_on_startup = startup.active);
        checking.add (startup); page.add (checking);

        var reading = new Adw.PreferencesGroup (); reading.title = "Reading";
        var conversations = new Adw.SwitchRow ();
        conversations.title = "Group related messages";
        conversations.subtitle = "Show the complete conversation when reading a message";
        conversations.active = settings.group_messages;
        conversations.notify["active"].connect (() => settings.group_messages = conversations.active);
        reading.add (conversations); page.add (reading);

        var group = new Adw.PreferencesGroup (); group.title = "Notifications";
        var notifications = new Adw.SwitchRow (); notifications.title = "Desktop notifications";
        notifications.subtitle = "Show the sender and subject when new mail arrives";
        notifications.active = settings.notifications_enabled;
        notifications.notify["active"].connect (() => settings.notifications_enabled = notifications.active);
        group.add (notifications); page.add (group); return page;
    }

    private Adw.PreferencesPage build_composing_page () {
        var page = new Adw.PreferencesPage (); page.title = "Compose"; page.icon_name = "document-edit-symbolic";
        var safety = new Adw.PreferencesGroup (); safety.title = "Writing and Sending";
        var spellcheck = new Adw.SwitchRow (); spellcheck.title = "Check spelling while typing";
        spellcheck.subtitle = "Uses an installed local dictionary; message text never leaves this device";
        spellcheck.active = settings.spellcheck_enabled;
        spellcheck.notify["active"].connect (() => settings.spellcheck_enabled = spellcheck.active);
        safety.add (spellcheck);
        var undo_send_enabled = new Adw.SwitchRow ();
        undo_send_enabled.title = "Undo Send";
        undo_send_enabled.subtitle = "Show an Undo Send action at the bottom of the main window";
        undo_send_enabled.active = settings.undo_send_enabled;
        safety.add (undo_send_enabled);
        var undo_send_window = new Adw.SpinRow.with_range (5, 30, 1);
        undo_send_window.title = "Undo Send window";
        undo_send_window.subtitle = "How long the bottom action remains available (5–30 seconds)";
        undo_send_window.value = settings.undo_send_seconds;
        undo_send_window.numeric = true;
        undo_send_window.sensitive = undo_send_enabled.active;
        undo_send_window.notify["value"].connect (() =>
            settings.undo_send_seconds = (int) undo_send_window.value);
        undo_send_enabled.notify["active"].connect (() => {
            settings.undo_send_enabled = undo_send_enabled.active;
            undo_send_window.sensitive = undo_send_enabled.active;
        });
        safety.add (undo_send_window); page.add (safety);

        var group = new Adw.PreferencesGroup (); group.title = "Signature";
        group.description = "Choose a separate plain-text signature for each sending identity.";
        identity_row = new Adw.ComboRow (); identity_row.title = "Identity"; identity_row.model = identity_labels;
        identity_row.notify["selected"].connect (() => identity_changed ()); group.add (identity_row);
        signature_enabled_row = new Adw.ActionRow (); signature_enabled_row.title = "Add signature automatically";
        signature_enabled_switch.valign = Gtk.Align.CENTER;
        signature_enabled_row.add_suffix (signature_enabled_switch);
        signature_enabled_row.activatable_widget = signature_enabled_switch;
        signature_enabled_switch.notify["active"].connect (() => {
            if (!loading && current_identity != "") {
                save_signature ();
                settings.set_signature_enabled (current_identity, signature_enabled_switch.active);
            }
        });
        group.add (signature_enabled_row);
        signature_editor.wrap_mode = Gtk.WrapMode.WORD_CHAR; signature_editor.accepts_tab = false;
        signature_editor.tooltip_text = "Signature text"; Accessibility.label (signature_editor, "Signature text");
        signature_editor.buffer.changed.connect (() => { if (!loading) save_signature (); });
        var scroller = new Gtk.ScrolledWindow (); scroller.set_policy (Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC);
        scroller.set_min_content_height (150); scroller.set_child (signature_editor); scroller.add_css_class ("card");
        group.add (scroller); page.add (group);
        add_vacation_settings (page);
        return page;
    }

    private Adw.PreferencesPage build_privacy_page () {
        var page = new Adw.PreferencesPage (); page.title = "Safety"; page.icon_name = "security-high-symbolic";
        var group = new Adw.PreferencesGroup (); group.title = "Message Content";
        var images = new Adw.SwitchRow (); images.title = "Always show remote images";
        images.subtitle = "Load external images automatically for every sender";
        images.active = settings.always_show_images;
        images.notify["active"].connect (() => settings.always_show_images = images.active);
        group.add (images);
        var full_html = new Adw.SwitchRow (); full_html.title = "Display full HTML formatting";
        full_html.subtitle = "Preserve the message’s original HTML styles and layout";
        full_html.active = settings.full_html_formatting;
        full_html.notify["active"].connect (() => settings.full_html_formatting = full_html.active);
        group.add (full_html);
        var remote = new Adw.ActionRow (); remote.title = "Remote content";
        remote.subtitle = "External images can reveal when and where a message is opened";
        remote.add_prefix (new Gtk.Image.from_icon_name ("network-offline-symbolic")); group.add (remote);
        var scripts = new Adw.ActionRow (); scripts.title = "Scripts and privileged access";
        scripts.subtitle = "Remain disabled even when full HTML formatting is enabled";
        scripts.add_prefix (new Gtk.Image.from_icon_name ("channel-secure-symbolic")); group.add (scripts);
        page.add (group);
        add_sender_list_settings (page);
        return page;
    }

    private void add_sender_list_settings (Adw.PreferencesPage page) {
        var lists = new Adw.PreferencesGroup ();
        lists.title = "Sender Lists";
        lists.description = "Manage sender exceptions in a separate window so this page stays easy to scan.";
        safe_senders_row = sender_list_row ("Safe Senders", "security-medium-symbolic", "safe");
        blocked_senders_row = sender_list_row ("Blocked Senders", "mail-mark-junk-symbolic", "blocked");
        remote_image_senders_row = sender_list_row ("Remote Image Senders", "image-x-generic-symbolic", "remote-images");
        lists.add (safe_senders_row);
        lists.add (blocked_senders_row);
        lists.add (remote_image_senders_row);
        page.add (lists);
        reload_sender_list_summaries ();
    }

    private Adw.ActionRow sender_list_row (string title, string icon_name, string page_name) {
        var row = new Adw.ActionRow ();
        row.title = title;
        row.add_prefix (new Gtk.Image.from_icon_name (icon_name));
        var arrow = new Gtk.Image.from_icon_name ("go-next-symbolic");
        arrow.valign = Gtk.Align.CENTER;
        row.add_suffix (arrow);
        row.activatable = true;
        row.activated.connect (() => open_sender_lists (page_name));
        return row;
    }

    private void open_sender_lists (string page_name) {
        var dialog = new SenderListsDialog (cache, remote_content_policy, page_name);
        dialog.lists_changed.connect (reload_sender_list_summaries);
        dialog.sender_safety_changed.connect (() => sender_safety_changed ());
        dialog.present (this);
    }

    private void reload_sender_list_summaries () {
        try {
            int count = cache.list_safe_senders ().size;
            safe_senders_row.subtitle = count == 0 ? "No senders" :
                count == 1 ? "1 sender" : "%d senders".printf (count);
        } catch (Error error) {
            safe_senders_row.subtitle = "List unavailable";
        }
        try {
            int count = cache.list_junk_rules ().size;
            blocked_senders_row.subtitle = count == 0 ? "No sender or domain rules" :
                count == 1 ? "1 sender or domain rule" : "%d sender or domain rules".printf (count);
        } catch (Error error) {
            blocked_senders_row.subtitle = "List unavailable";
        }
        try {
            int count = remote_content_policy.trusted_senders ().size;
            remote_image_senders_row.subtitle = count == 0 ? "No senders" :
                count == 1 ? "1 sender" : "%d senders".printf (count);
        } catch (Error error) {
            remote_image_senders_row.subtitle = "List unavailable";
        }
    }

    private Adw.PreferencesPage build_rules_page () {
        var page = new Adw.PreferencesPage (); page.title = "Automation"; page.icon_name = "system-run-symbolic";
        var add = new Adw.PreferencesGroup (); add.title = "Automation";
        add.description = "Rules run in order as messages synchronize. Use multiple AND/OR conditions, exceptions, actions, account scope, and stop-processing.";
        var create = new Gtk.Button.with_label ("Add Mail Rule…"); create.halign = Gtk.Align.END;
        create.add_css_class ("suggested-action"); create.clicked.connect (() => add_advanced_rule.begin ()); add.add (create);
        page.add (add);
        automation_status_row = new Adw.ActionRow (); automation_status_row.visible = false;
        automation_status_row.add_prefix (new Gtk.Image.from_icon_name ("emblem-ok-symbolic")); add.add (automation_status_row);
        rules_group = new Adw.PreferencesGroup (); rules_group.title = "Mail Rules";
        rules_group.description = "Toggle, edit, reorder, or run a rule against the bounded local cache.";
        page.add (rules_group);
        quick_steps_group = new Adw.PreferencesGroup (); quick_steps_group.title = "Quick Steps";
        quick_steps_group.description = "Apply a reusable sequence of actions to selected messages from the More menu.";
        var add_quick = new Gtk.Button.with_label ("Add Quick Step…"); add_quick.halign = Gtk.Align.END;
        add_quick.clicked.connect (() => add_quick_step.begin ()); quick_steps_group.add (add_quick);
        page.add (quick_steps_group);
        reload_mail_rules (); reload_quick_steps ();
        add_smart_mailbox_settings (page);
        return page;
    }

    private async void add_advanced_rule () {
        var parent = get_root () as Gtk.Window; if (parent == null) return;
        try {
            var rule = yield RuleEditorDialog.choose (parent, cache);
            if (rule == null) return;
            cache.save_mail_rule (rule); reload_mail_rules (); automation_changed ();
        } catch (Error error) { show_automation_status (error.message, true); }
    }

    private async void edit_mail_rule (MailRule existing) {
        var parent = get_root () as Gtk.Window; if (parent == null) return;
        try {
            var rule = yield RuleEditorDialog.choose (parent, cache, existing);
            if (rule == null) return;
            cache.save_mail_rule (rule); reload_mail_rules (); automation_changed ();
        } catch (Error error) { show_automation_status (error.message, true); }
    }

    private async void add_quick_step () {
        var parent = get_root () as Gtk.Window; if (parent == null) return;
        try {
            var step = yield QuickStepEditorDialog.choose (parent, cache);
            if (step == null) return;
            reload_quick_steps (); automation_changed ();
        } catch (Error error) { show_automation_status (error.message, true); }
    }

    private void show_automation_status (string text, bool error = false) {
        automation_status_row.title = text; automation_status_row.visible = true;
        if (error) automation_status_row.add_css_class ("error");
        else automation_status_row.remove_css_class ("error");
    }

    private void reload_mail_rules () {
        foreach (var row in rule_rows) rules_group.remove (row); rule_rows.clear ();
        try {
            var rules = cache.list_mail_rules ();
            if (rules.size == 0) {
                var empty = new Adw.ActionRow ();
                empty.title = "No mail rules yet";
                empty.subtitle = "Create a rule to automate incoming mail.";
                empty.add_prefix (new Gtk.Image.from_icon_name ("system-run-symbolic"));
                rules_group.add (empty); rule_rows.add (empty);
                return;
            }
            int rule_index = 0;
            foreach (var rule in rules) {
                var row = new Adw.ActionRow (); row.title = rule.name;
                string scope = automation_scope_label (rule.account_id);
                row.subtitle = "%s • %d %s (%s) • %d %s%s".printf (scope, rule.conditions.size,
                    rule.conditions.size == 1 ? "condition" : "conditions",
                    rule.match_mode == MailRuleMatchMode.ALL ? "AND" : "OR", rule.operations.size,
                    rule.operations.size == 1 ? "action" : "actions",
                    rule.exceptions.size == 0 ? "" : " • %d exceptions".printf (rule.exceptions.size));
                var enabled = new Gtk.Switch (); enabled.valign = Gtk.Align.CENTER; enabled.active = rule.enabled;
                Accessibility.label (enabled, "Enable rule " + rule.name);
                enabled.notify["active"].connect (() => {
                    try { cache.set_mail_rule_enabled (rule.id, enabled.active); automation_changed (); }
                    catch (Error error) { show_automation_status (error.message, true); }
                });
                row.add_suffix (enabled);
                var controls = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 2); controls.add_css_class ("linked");
                var up = icon_button ("go-up-symbolic", "Move rule up");
                up.sensitive = rule_index > 0;
                up.clicked.connect (() => { try { cache.move_mail_rule (rule.id, -1); reload_mail_rules (); automation_changed (); }
                    catch (Error error) { show_automation_status (error.message, true); } }); controls.append (up);
                var down = icon_button ("go-down-symbolic", "Move rule down");
                down.sensitive = rule_index < rules.size - 1;
                down.clicked.connect (() => { try { cache.move_mail_rule (rule.id, 1); reload_mail_rules (); automation_changed (); }
                    catch (Error error) { show_automation_status (error.message, true); } }); controls.append (down);
                var run = icon_button ("media-playback-start-symbolic", "Run rule now");
                run.clicked.connect (() => {
                    try { int applied = new MailRuleService (cache).run_now (rule);
                        show_automation_status ("Rule “%s” applied to %d messages".printf (rule.name, applied)); automation_changed (); }
                    catch (Error error) { show_automation_status (error.message, true); }
                }); controls.append (run);
                var edit = icon_button ("document-edit-symbolic", "Edit rule");
                edit.clicked.connect (() => edit_mail_rule.begin (rule)); controls.append (edit);
                var remove = new Gtk.Button.from_icon_name ("user-trash-symbolic"); remove.valign = Gtk.Align.CENTER;
                Accessibility.label (remove, "Delete rule " + rule.name);
                remove.clicked.connect (() => {
                    try {
                        cache.remove_mail_rule (rule.id); reload_mail_rules (); automation_changed ();
                        show_automation_status ("Rule “%s” deleted".printf (rule.name));
                    } catch (Error error) { show_automation_status (error.message, true); }
                });
                controls.append (remove); row.add_suffix (controls); rules_group.add (row); rule_rows.add (row);
                rule_index++;
            }
        } catch (Error error) { warning ("Could not load mail rules: %s", error.message); }
    }

    private void reload_quick_steps () {
        foreach (var row in quick_step_rows) quick_steps_group.remove (row); quick_step_rows.clear ();
        try {
            var steps = cache.list_quick_steps ();
            if (steps.size == 0) {
                var empty = new Adw.ActionRow ();
                empty.title = "No Quick Steps yet";
                empty.subtitle = "Create one to apply several actions at once.";
                empty.add_prefix (new Gtk.Image.from_icon_name ("media-playlist-consecutive-symbolic"));
                quick_steps_group.add (empty); quick_step_rows.add (empty);
                return;
            }
            foreach (var step in steps) {
                var row = new Adw.ActionRow (); row.title = step.name;
                row.subtitle = "%s • %d %s • available from More → Quick Steps".printf (
                    automation_scope_label (step.account_id), step.operations.size,
                    step.operations.size == 1 ? "action" : "actions");
                var remove = icon_button ("user-trash-symbolic", "Delete Quick Step " + step.name);
                remove.clicked.connect (() => { try { cache.remove_quick_step (step.id); reload_quick_steps (); automation_changed (); }
                    catch (Error error) { show_automation_status (error.message, true); } });
                row.add_suffix (remove); quick_steps_group.add (row); quick_step_rows.add (row);
            }
        } catch (Error error) { show_automation_status (error.message, true); }
    }

    private string automation_scope_label (string account_id) {
        if (account_id == "") return "All accounts";
        try {
            var account = cache.find_account (account_id);
            if (account == null) return "Unavailable account";
            if (account.display_name.strip () == "" || account.display_name == account.email)
                return account.email;
            return "%s <%s>".printf (account.display_name, account.email);
        } catch (Error error) {
            warning ("Could not resolve automation account: %s", error.message);
            return "Unavailable account";
        }
    }

    private static Gtk.Button icon_button (string icon, string label) {
        var button = new Gtk.Button.from_icon_name (icon); button.valign = Gtk.Align.CENTER;
        button.add_css_class ("flat"); button.tooltip_text = label; Accessibility.label (button, label); return button;
    }

    private void add_smart_mailbox_settings (Adw.PreferencesPage page) {
        var add = new Adw.PreferencesGroup (); add.title = "New Smart Mailbox";
        add.description = "Saved searches appear in the left column and update as mail changes.";
        smart_name_row = new Adw.EntryRow (); smart_name_row.title = "Name"; add.add (smart_name_row);
        smart_query_row = new Adw.EntryRow (); smart_query_row.title = "Search";
        smart_query_row.text = "is:unread"; add.add (smart_query_row);
        var create = new Gtk.Button.with_label ("Add Smart Mailbox"); create.halign = Gtk.Align.END;
        create.add_css_class ("suggested-action"); create.clicked.connect (() => {
            try {
                cache.add_smart_mailbox (smart_name_row.text, smart_query_row.text);
                smart_name_row.text = ""; smart_query_row.text = "is:unread"; reload_smart_mailboxes (); smart_mailboxes_changed ();
            } catch (Error error) { warning ("Could not add Smart Mailbox: %s", error.message); }
        }); add.add (create); page.add (add);
        smart_group = new Adw.PreferencesGroup (); smart_group.title = "Saved Smart Mailboxes"; page.add (smart_group);
        reload_smart_mailboxes ();
    }

    private void reload_smart_mailboxes () {
        foreach (var row in smart_rows) smart_group.remove (row); smart_rows.clear ();
        try {
            foreach (var smart in cache.list_smart_mailboxes ()) {
                var row = new Adw.ActionRow (); row.title = smart.name; row.subtitle = smart.query;
                var remove = new Gtk.Button.from_icon_name ("user-trash-symbolic"); remove.valign = Gtk.Align.CENTER;
                Accessibility.label (remove, "Delete Smart Mailbox " + smart.name);
                remove.clicked.connect (() => { try { cache.remove_smart_mailbox (smart.id); reload_smart_mailboxes (); smart_mailboxes_changed (); }
                    catch (Error error) { warning ("Could not remove Smart Mailbox: %s", error.message); } });
                row.add_suffix (remove); smart_group.add (row); smart_rows.add (row);
            }
        } catch (Error error) { warning ("Could not load Smart Mailboxes: %s", error.message); }
    }

    private void add_vacation_settings (Adw.PreferencesPage page) {
        var group = new Adw.PreferencesGroup (); group.title = "Automatic Vacation Reply";
        group.description = "Mailficient replies once to each sender while it is running and checking mail.";
        var accounts = new Gtk.StringList (null); var ids = new Gee.ArrayList<string> ();
        try { foreach (var account in cache.list_accounts ()) { accounts.append (account.email); ids.add (account.id); } }
        catch (Error error) { warning ("Could not load vacation identities: %s", error.message); }
        vacation_identity_row = new Adw.ComboRow (); vacation_identity_row.title = "Account";
        vacation_identity_row.model = accounts; group.add (vacation_identity_row);
        var enabled = new Adw.SwitchRow (); enabled.title = "Send vacation replies"; group.add (enabled);
        var starts = new Adw.EntryRow (); starts.title = "Starts (YYYY-MM-DD, optional)"; group.add (starts);
        var ends = new Adw.EntryRow (); ends.title = "Ends (YYYY-MM-DD, optional)"; group.add (ends);
        var subject = new Adw.EntryRow (); subject.title = "Reply subject"; group.add (subject);
        var body = new Gtk.TextView (); body.wrap_mode = Gtk.WrapMode.WORD_CHAR; body.set_size_request (-1, 140);
        Accessibility.label (body, "Vacation reply message"); var body_scroll = new Gtk.ScrolledWindow ();
        body_scroll.child = body; body_scroll.add_css_class ("card"); group.add (body_scroll);
        bool loading_vacation = false;
        SourceFunc load = () => {
            if (ids.size == 0 || vacation_identity_row.selected >= ids.size) return Source.REMOVE;
            loading_vacation = true;
            try {
                var value = cache.vacation_settings (ids[(int) vacation_identity_row.selected]);
                enabled.active = value != null && value.enabled;
                starts.text = value == null || value.starts_at == 0 ? "" : new DateTime.from_unix_local (value.starts_at).format ("%F");
                ends.text = value == null || value.ends_at == 0 ? "" : new DateTime.from_unix_local (value.ends_at).format ("%F");
                subject.text = value == null ? "Out of office" : value.subject; body.buffer.text = value == null ? "" : value.body;
            } catch (Error error) { warning ("Could not load vacation settings: %s", error.message); }
            loading_vacation = false; return Source.REMOVE;
        };
        vacation_identity_row.notify["selected"].connect (() => load ());
        var save = new Gtk.Button.with_label ("Save Vacation Reply"); save.halign = Gtk.Align.END;
        save.add_css_class ("suggested-action"); save.clicked.connect (() => {
            if (loading_vacation || ids.size == 0 || vacation_identity_row.selected >= ids.size) return;
            try {
                var value = new VacationSettings (ids[(int) vacation_identity_row.selected]); value.enabled = enabled.active;
                value.starts_at = parse_optional_day (starts.text, false); value.ends_at = parse_optional_day (ends.text, true);
                value.subject = subject.text; value.body = body.buffer.text; cache.save_vacation_settings (value);
            } catch (Error error) { warning ("Could not save vacation settings: %s", error.message); }
        }); group.add (save); page.add (group); load ();
    }

    private static int64 parse_optional_day (string text, bool end_of_day) throws MailError {
        string clean = text.strip (); if (clean == "") return 0;
        var date = new DateTime.from_iso8601 (clean + "T00:00:00", new TimeZone.local ());
        if (date == null || date.format ("%F") != clean) throw new MailError.STORAGE ("Use dates in YYYY-MM-DD format");
        return (end_of_day ? date.add_days (1).add_seconds (-1) : date).to_unix ();
    }

    private void load_identities () {
        try {
            foreach (var account in cache.list_accounts ()) {
                identity_labels.append ("%s <%s>".printf (account.display_name, account.email));
                identity_ids.add (account.id);
            }
        } catch (Error error) { warning ("Could not load identities for preferences: %s", error.message); }
        if (identity_ids.size == 0) {
            identity_labels.append ("No accounts configured"); identity_ids.add (""); identity_row.sensitive = false;
        }
        identity_row.selected = 0; identity_changed ();
    }

    private string selected_identity () {
        uint selected = identity_row.selected;
        return selected < identity_ids.size ? identity_ids[(int) selected] : "";
    }

    private void identity_changed () {
        loading = true;
        current_identity = selected_identity ();
        if (current_identity == "") {
            signature_enabled_switch.active = false; signature_enabled_row.sensitive = false;
            signature_editor.buffer.text = ""; signature_editor.sensitive = false; loading = false; return;
        }
        signature_enabled_row.sensitive = true;
        signature_enabled_switch.active = settings.signature_enabled (current_identity);
        signature_editor.buffer.text = settings.signature (current_identity);
        // The signature text remains editable independently of whether
        // automatic insertion is enabled.
        signature_editor.sensitive = true;
        loading = false;
    }

    private void save_signature () {
        if (current_identity != "") settings.set_signature (current_identity, signature_editor.buffer.text);
    }

}
}
