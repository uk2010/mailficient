namespace Mailficient {
public class PreferencesWindow : Adw.PreferencesDialog {
    public signal void account_saved (AccountSettings account);
    public signal void accounts_changed ();
    public signal void smart_mailboxes_changed ();
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
    private Adw.ComboRow junk_kind_row;
    private Adw.EntryRow junk_pattern_row;
    private Adw.PreferencesGroup junk_rules_group;
    private Adw.ActionRow junk_error_row;
    private Gee.ArrayList<Adw.ActionRow> junk_rule_rows = new Gee.ArrayList<Adw.ActionRow> ();
    private Adw.PreferencesGroup trusted_senders_group;
    private Gee.ArrayList<Adw.ActionRow> trusted_sender_rows = new Gee.ArrayList<Adw.ActionRow> ();
    private Adw.EntryRow rule_name_row;
    private Adw.EntryRow rule_pattern_row;
    private Adw.EntryRow rule_value_row;
    private Adw.ComboRow rule_field_row;
    private Adw.ComboRow rule_action_row;
    private Adw.PreferencesGroup rules_group;
    private Gee.ArrayList<Adw.ActionRow> rule_rows = new Gee.ArrayList<Adw.ActionRow> ();
    private Adw.EntryRow smart_name_row;
    private Adw.EntryRow smart_query_row;
    private Adw.PreferencesGroup smart_group;
    private Gee.ArrayList<Adw.ActionRow> smart_rows = new Gee.ArrayList<Adw.ActionRow> ();

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
        var junk_page = build_junk_page (); junk_page.name = "junk"; add (junk_page);
        var rules_page = build_rules_page (); rules_page.name = "rules"; add (rules_page);
        var smart_page = build_smart_mailboxes_page (); smart_page.name = "smart-mailboxes"; add (smart_page);
        var vacation_page = build_vacation_page (); vacation_page.name = "vacation"; add (vacation_page);
        var privacy_page = build_privacy_page (); privacy_page.name = "privacy"; add (privacy_page);
        load_identities ();
        notify["visible-page-name"].connect (() => {
            string? page_name = get_visible_page_name ();
            if (page_name != null && page_name != "") settings.preferences_page = page_name;
        });
        string? qa_page = Environment.get_variable ("MAILFICIENT_QA_PREFERENCES");
        if (qa_page == "accounts" || qa_page == "composing" || qa_page == "junk" || qa_page == "rules" || qa_page == "smart-mailboxes" || qa_page == "vacation" || qa_page == "privacy")
            set_visible_page_name (qa_page);
        else
            set_visible_page_name (settings.preferences_page);
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
        intervals.append ("Manually"); intervals.append ("Every 5 minutes");
        intervals.append ("Every 15 minutes"); intervals.append ("Every 30 minutes");
        intervals.append ("Every hour");
        var interval = new Adw.ComboRow (); interval.title = "Check for new mail"; interval.model = intervals;
        interval.subtitle = "Changes take effect immediately";
        switch (settings.sync_interval_minutes) {
        case 0: interval.selected = 0; break;
        case 15: interval.selected = 2; break;
        case 30: interval.selected = 3; break;
        case 60: interval.selected = 4; break;
        default: interval.selected = 1; break;
        }
        interval.notify["selected"].connect (() => {
            switch (interval.selected) {
            case 0: settings.sync_interval_minutes = 0; break;
            case 2: settings.sync_interval_minutes = 15; break;
            case 3: settings.sync_interval_minutes = 30; break;
            case 4: settings.sync_interval_minutes = 60; break;
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
        var page = new Adw.PreferencesPage (); page.title = "Composing"; page.icon_name = "document-edit-symbolic";
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
        group.add (scroller); page.add (group); return page;
    }

    private Adw.PreferencesPage build_privacy_page () {
        var page = new Adw.PreferencesPage (); page.title = "Privacy"; page.icon_name = "security-high-symbolic";
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
        trusted_senders_group = new Adw.PreferencesGroup (); trusted_senders_group.title = "Trusted Senders";
        trusted_senders_group.description = "Remote images load automatically only for senders listed here. You can trust a sender from the blocked-content notice in a message.";
        page.add (trusted_senders_group); reload_trusted_senders (); return page;
    }

    private void reload_trusted_senders () {
        foreach (var row in trusted_sender_rows) trusted_senders_group.remove (row);
        trusted_sender_rows.clear ();
        try {
            var senders = remote_content_policy.trusted_senders ();
            if (senders.size == 0) {
                var empty = new Adw.ActionRow (); empty.title = "No trusted senders";
                empty.subtitle = "Remote images remain blocked by default";
                empty.add_prefix (new Gtk.Image.from_icon_name ("network-offline-symbolic"));
                trusted_senders_group.add (empty); trusted_sender_rows.add (empty); return;
            }
            foreach (var address in senders) {
                var row = new Adw.ActionRow (); row.title = address;
                row.subtitle = "Remote images allowed";
                var remove = new Gtk.Button.from_icon_name ("user-trash-symbolic");
                remove.valign = Gtk.Align.CENTER; remove.tooltip_text = "Stop trusting this sender";
                Accessibility.label (remove, "Stop loading remote images from " + address);
                remove.clicked.connect (() => {
                    try { remote_content_policy.forget_sender (address); reload_trusted_senders (); }
                    catch (Error error) { warning ("Could not remove trusted sender: %s", error.message); }
                });
                row.add_suffix (remove); trusted_senders_group.add (row); trusted_sender_rows.add (row);
            }
        } catch (Error error) {
            var failed = new Adw.ActionRow (); failed.title = "Trusted senders unavailable";
            failed.subtitle = error.message; trusted_senders_group.add (failed); trusted_sender_rows.add (failed);
        }
    }

    private Adw.PreferencesPage build_junk_page () {
        var page = new Adw.PreferencesPage (); page.title = "Junk"; page.icon_name = "dialog-warning-symbolic";
        var add_group = new Adw.PreferencesGroup (); add_group.title = "Block a Sender";
        add_group.description = "New Inbox messages matching these addresses or domains are marked as junk on the server and moved to Junk.";
        var kinds = new Gtk.StringList (null); kinds.append ("Email address"); kinds.append ("Domain");
        junk_kind_row = new Adw.ComboRow (); junk_kind_row.title = "Match"; junk_kind_row.model = kinds;
        add_group.add (junk_kind_row);
        junk_pattern_row = new Adw.EntryRow (); junk_pattern_row.title = "Address or domain";
        junk_pattern_row.show_apply_button = true; junk_pattern_row.apply.connect (add_junk_rule);
        add_group.add (junk_pattern_row);
        junk_error_row = new Adw.ActionRow (); junk_error_row.add_prefix (new Gtk.Image.from_icon_name ("dialog-warning-symbolic"));
        junk_error_row.visible = false; junk_error_row.add_css_class ("error"); add_group.add (junk_error_row);
        page.add (add_group);
        junk_rules_group = new Adw.PreferencesGroup (); junk_rules_group.title = "Blocked Senders";
        junk_rules_group.description = "Rules are stored locally. Removing a rule does not restore mail already classified as junk.";
        page.add (junk_rules_group); reload_junk_rules ();
        return page;
    }

    private void add_junk_rule () {
        try {
            var kind = junk_kind_row.selected == 1 ? JunkRuleKind.DOMAIN : JunkRuleKind.ADDRESS;
            cache.add_junk_rule (kind, junk_pattern_row.text);
            junk_pattern_row.text = ""; junk_error_row.visible = false; reload_junk_rules ();
        } catch (Error error) {
            junk_error_row.title = error.message; junk_error_row.visible = true;
        }
    }

    private void reload_junk_rules () {
        foreach (var row in junk_rule_rows) junk_rules_group.remove (row);
        junk_rule_rows.clear ();
        try {
            foreach (var rule in cache.list_junk_rules ()) {
                var row = new Adw.ActionRow (); row.title = rule.kind == JunkRuleKind.DOMAIN ?
                    "@" + rule.pattern : rule.pattern;
                row.subtitle = rule.kind == JunkRuleKind.DOMAIN ? "Entire domain" : "Email address";
                var remove = new Gtk.Button.from_icon_name ("user-trash-symbolic");
                remove.valign = Gtk.Align.CENTER; remove.tooltip_text = "Remove junk rule";
                Accessibility.label (remove, "Remove junk rule for " + rule.pattern);
                remove.clicked.connect (() => {
                    try { cache.remove_junk_rule (rule.id); reload_junk_rules (); }
                    catch (Error error) { junk_error_row.title = error.message; junk_error_row.visible = true; }
                });
                row.add_suffix (remove); junk_rules_group.add (row); junk_rule_rows.add (row);
            }
        } catch (Error error) { junk_error_row.title = error.message; junk_error_row.visible = true; }
    }

    private Adw.PreferencesPage build_rules_page () {
        var page = new Adw.PreferencesPage (); page.title = "Rules"; page.icon_name = "system-run-symbolic";
        var add = new Adw.PreferencesGroup (); add.title = "New Mail Rule";
        add.description = "Rules run locally as new messages are synchronized.";
        rule_name_row = new Adw.EntryRow (); rule_name_row.title = "Rule name"; add.add (rule_name_row);
        var fields = new Gtk.StringList (null); fields.append ("Sender contains"); fields.append ("Recipient contains"); fields.append ("Subject contains");
        fields.append ("Message body contains"); fields.append ("Has attachment"); fields.append ("Is unread"); fields.append ("Is flagged");
        rule_field_row = new Adw.ComboRow (); rule_field_row.title = "Match"; rule_field_row.model = fields; add.add (rule_field_row);
        rule_pattern_row = new Adw.EntryRow (); rule_pattern_row.title = "Text to match"; add.add (rule_pattern_row);
        var actions = new Gtk.StringList (null); actions.append ("Mark as read"); actions.append ("Flag");
        actions.append ("Move to Archive"); actions.append ("Move to Trash"); actions.append ("Apply label");
        actions.append ("Mark as unread"); actions.append ("Unflag"); actions.append ("Move to mailbox ID");
        rule_action_row = new Adw.ComboRow (); rule_action_row.title = "Action"; rule_action_row.model = actions; add.add (rule_action_row);
        rule_value_row = new Adw.EntryRow (); rule_value_row.title = "Label name or mailbox ID (when required)"; add.add (rule_value_row);
        var create = new Gtk.Button.with_label ("Add Rule"); create.halign = Gtk.Align.END;
        create.add_css_class ("suggested-action"); create.clicked.connect (add_mail_rule); add.add (create);
        page.add (add);
        rules_group = new Adw.PreferencesGroup (); rules_group.title = "Active Rules"; page.add (rules_group);
        reload_mail_rules (); return page;
    }

    private void add_mail_rule () {
        try {
            cache.add_mail_rule (rule_name_row.text, "", (MailRuleField) rule_field_row.selected,
                rule_pattern_row.text, (MailRuleAction) rule_action_row.selected, rule_value_row.text);
            rule_name_row.text = ""; rule_pattern_row.text = ""; rule_value_row.text = ""; reload_mail_rules ();
        } catch (Error error) { warning ("Could not add mail rule: %s", error.message); }
    }

    private void reload_mail_rules () {
        foreach (var row in rule_rows) rules_group.remove (row); rule_rows.clear ();
        try {
            foreach (var rule in cache.list_mail_rules ()) {
                var row = new Adw.ActionRow (); row.title = rule.name;
                string[] actions = { "Mark read", "Flag", "Archive", "Trash", "Label " + rule.value, "Mark unread", "Unflag", "Move to " + rule.value };
                row.subtitle = "%s matches “%s” → %s".printf (rule.field.to_string ().replace ("MAIL_RULE_FIELD_", "").down (),
                    rule.pattern, actions[(int) rule.action]);
                var remove = new Gtk.Button.from_icon_name ("user-trash-symbolic"); remove.valign = Gtk.Align.CENTER;
                Accessibility.label (remove, "Delete rule " + rule.name);
                remove.clicked.connect (() => { try { cache.remove_mail_rule (rule.id); reload_mail_rules (); }
                    catch (Error error) { warning ("Could not remove mail rule: %s", error.message); } });
                row.add_suffix (remove); rules_group.add (row); rule_rows.add (row);
            }
        } catch (Error error) { warning ("Could not load mail rules: %s", error.message); }
    }

    private Adw.PreferencesPage build_smart_mailboxes_page () {
        var page = new Adw.PreferencesPage (); page.title = "Smart Mailboxes"; page.icon_name = "view-filter-symbolic";
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
        reload_smart_mailboxes (); return page;
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

    private Adw.PreferencesPage build_vacation_page () {
        var page = new Adw.PreferencesPage (); page.title = "Vacation"; page.icon_name = "weather-clear-symbolic";
        var group = new Adw.PreferencesGroup (); group.title = "Automatic Vacation Reply";
        group.description = "Mailficient replies once to each sender while it is running and checking mail.";
        var accounts = new Gtk.StringList (null); var ids = new Gee.ArrayList<string> ();
        try { foreach (var account in cache.list_accounts ()) { accounts.append (account.email); ids.add (account.id); } }
        catch (Error error) { warning ("Could not load vacation identities: %s", error.message); }
        var identity = new Adw.ComboRow (); identity.title = "Account"; identity.model = accounts; group.add (identity);
        var enabled = new Adw.SwitchRow (); enabled.title = "Send vacation replies"; group.add (enabled);
        var starts = new Adw.EntryRow (); starts.title = "Starts (YYYY-MM-DD, optional)"; group.add (starts);
        var ends = new Adw.EntryRow (); ends.title = "Ends (YYYY-MM-DD, optional)"; group.add (ends);
        var subject = new Adw.EntryRow (); subject.title = "Reply subject"; group.add (subject);
        var body = new Gtk.TextView (); body.wrap_mode = Gtk.WrapMode.WORD_CHAR; body.set_size_request (-1, 140);
        Accessibility.label (body, "Vacation reply message"); var body_scroll = new Gtk.ScrolledWindow ();
        body_scroll.child = body; body_scroll.add_css_class ("card"); group.add (body_scroll);
        bool loading_vacation = false;
        SourceFunc load = () => {
            if (ids.size == 0 || identity.selected >= ids.size) return Source.REMOVE;
            loading_vacation = true;
            try {
                var value = cache.vacation_settings (ids[(int) identity.selected]);
                enabled.active = value != null && value.enabled;
                starts.text = value == null || value.starts_at == 0 ? "" : new DateTime.from_unix_local (value.starts_at).format ("%F");
                ends.text = value == null || value.ends_at == 0 ? "" : new DateTime.from_unix_local (value.ends_at).format ("%F");
                subject.text = value == null ? "Out of office" : value.subject; body.buffer.text = value == null ? "" : value.body;
            } catch (Error error) { warning ("Could not load vacation settings: %s", error.message); }
            loading_vacation = false; return Source.REMOVE;
        };
        identity.notify["selected"].connect (() => load ());
        var save = new Gtk.Button.with_label ("Save Vacation Reply"); save.halign = Gtk.Align.END;
        save.add_css_class ("suggested-action"); save.clicked.connect (() => {
            if (loading_vacation || ids.size == 0 || identity.selected >= ids.size) return;
            try {
                var value = new VacationSettings (ids[(int) identity.selected]); value.enabled = enabled.active;
                value.starts_at = parse_optional_day (starts.text, false); value.ends_at = parse_optional_day (ends.text, true);
                value.subject = subject.text; value.body = body.buffer.text; cache.save_vacation_settings (value);
            } catch (Error error) { warning ("Could not save vacation settings: %s", error.message); }
        }); group.add (save); page.add (group); load (); return page;
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
