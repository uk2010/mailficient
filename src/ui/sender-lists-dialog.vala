namespace Mailficient {
public class SenderListsDialog : Adw.PreferencesDialog {
    public signal void lists_changed ();
    public signal void sender_safety_changed ();

    private CacheDatabase cache;
    private RemoteContentPolicy remote_content_policy;

    private Adw.PreferencesGroup safe_senders_group = new Adw.PreferencesGroup ();
    private Gee.ArrayList<Adw.ActionRow> safe_sender_rows = new Gee.ArrayList<Adw.ActionRow> ();
    private Adw.PreferencesGroup trusted_senders_group = new Adw.PreferencesGroup ();
    private Gee.ArrayList<Adw.ActionRow> trusted_sender_rows = new Gee.ArrayList<Adw.ActionRow> ();
    private Adw.ComboRow junk_kind_row = new Adw.ComboRow ();
    private Adw.EntryRow junk_pattern_row = new Adw.EntryRow ();
    private Adw.ActionRow junk_error_row = new Adw.ActionRow ();
    private Adw.PreferencesGroup junk_rules_group = new Adw.PreferencesGroup ();
    private Gee.ArrayList<Adw.ActionRow> junk_rule_rows = new Gee.ArrayList<Adw.ActionRow> ();

    public SenderListsDialog (CacheDatabase cache, RemoteContentPolicy remote_content_policy,
                              string initial_page = "safe") {
        this.cache = cache;
        this.remote_content_policy = remote_content_policy;
        title = "Sender Lists";
        content_width = 720;
        content_height = 600;
        width_request = 360;
        height_request = 480;
        search_enabled = true;
        add_css_class ("sender-lists-dialog");

        add (build_safe_senders_page ());
        add (build_blocked_senders_page ());
        add (build_remote_images_page ());

        string page_name = initial_page == "blocked" || initial_page == "remote-images" ?
            initial_page : "safe";
        set_visible_page_name (page_name);
        if (page_name == "blocked") Idle.add (() => {
            if (junk_pattern_row.get_root () != null) junk_pattern_row.grab_focus ();
            return Source.REMOVE;
        });
    }

    private Adw.PreferencesPage build_safe_senders_page () {
        var page = new Adw.PreferencesPage ();
        page.name = "safe";
        page.title = "Safe Senders";
        page.icon_name = "security-medium-symbolic";
        style_page (page, "sender-lists-safe-page");
        add_intro (page, "TRUST", "Mail from people you know",
            "Allow familiar senders without weakening protection for anyone else.",
            "security-medium-symbolic", "You can revoke access anytime");
        style_group (safe_senders_group, "safe-senders");
        safe_senders_group.title = "Allowed Senders";
        safe_senders_group.description = "Remote images load automatically and routine sender warnings stay out of the way. Full findings remain in Security Details.";
        page.add (safe_senders_group);
        reload_safe_senders ();
        return page;
    }

    private Adw.PreferencesPage build_remote_images_page () {
        var page = new Adw.PreferencesPage ();
        page.name = "remote-images";
        page.title = "Remote Image Senders";
        page.icon_name = "image-x-generic-symbolic";
        style_page (page, "sender-lists-images-page");
        add_intro (page, "REMOTE CONTENT", "Choose who can load images",
            "Keep tracking protection on by default, with precise exceptions for senders you trust.",
            "image-x-generic-symbolic", "Blocked for everyone else");
        style_group (trusted_senders_group, "remote-image-senders");
        trusted_senders_group.title = "Automatic Image Loading";
        trusted_senders_group.description = "Safe Senders already receive this access and do not need to appear twice.";
        page.add (trusted_senders_group);
        reload_trusted_senders ();
        return page;
    }

    private Adw.PreferencesPage build_blocked_senders_page () {
        var page = new Adw.PreferencesPage ();
        page.name = "blocked";
        page.title = "Blocked Senders";
        page.icon_name = "mail-mark-junk-symbolic";
        style_page (page, "sender-lists-blocked-page");
        add_intro (page, "INBOX SAFETY", "Keep repeat junk out",
            "Block a single address or an entire domain with a rule you can remove at any time.",
            "mail-mark-junk-symbolic", "Rules stay on this device");

        var add_group = new Adw.PreferencesGroup ();
        style_group (add_group, "block-sender");
        add_group.title = "Add to Block List";
        add_group.description = "New Inbox messages matching an address or domain are marked as junk on the server and moved to Junk.";
        var kinds = new Gtk.StringList (null);
        kinds.append ("Email address");
        kinds.append ("Domain");
        junk_kind_row.title = "Match";
        junk_kind_row.model = kinds;
        style_row (junk_kind_row, "view-list-symbolic");
        add_group.add (junk_kind_row);
        junk_pattern_row.title = "Address or domain";
        junk_pattern_row.show_apply_button = true;
        junk_pattern_row.add_css_class ("settings-control-row");
        junk_pattern_row.add_css_class ("sender-list-entry-row");
        junk_pattern_row.apply.connect (add_junk_rule);
        add_group.add (junk_pattern_row);
        style_row (junk_error_row, "dialog-warning-symbolic");
        junk_error_row.visible = false;
        junk_error_row.add_css_class ("error");
        junk_error_row.add_css_class ("settings-state-row");
        add_group.add (junk_error_row);
        page.add (add_group);

        style_group (junk_rules_group, "blocked-senders");
        junk_rules_group.title = "Current Block List";
        junk_rules_group.description = "Rules are stored locally. Removing a rule does not restore mail already classified as junk.";
        page.add (junk_rules_group);
        reload_junk_rules ();
        return page;
    }

    private void reload_safe_senders () {
        foreach (var row in safe_sender_rows) safe_senders_group.remove (row);
        safe_sender_rows.clear ();
        try {
            var senders = cache.list_safe_senders ();
            if (senders.size == 0) {
                var empty = new Adw.ActionRow ();
                empty.title = "No Safe Senders";
                empty.subtitle = "Add a sender from the message Security Details";
                empty.add_css_class ("settings-empty-row");
                style_row (empty, "security-medium-symbolic");
                safe_senders_group.add (empty);
                safe_sender_rows.add (empty);
                return;
            }
            foreach (var address in senders) {
                var row = new Adw.ActionRow ();
                row.title = address;
                row.subtitle = "Remote images allowed; automatic sender warnings hidden";
                style_row (row, "avatar-default-symbolic");
                row.add_css_class ("sender-list-row");
                var remove = remove_button ("Remove from Safe Senders",
                    "Remove " + address + " from Safe Senders");
                remove.clicked.connect (() => {
                    try {
                        cache.set_safe_sender (address, false);
                        reload_safe_senders ();
                        lists_changed ();
                        sender_safety_changed ();
                    } catch (Error error) {
                        warning ("Could not remove Safe Sender: %s", error.message);
                    }
                });
                row.add_suffix (remove);
                safe_senders_group.add (row);
                safe_sender_rows.add (row);
            }
        } catch (Error error) {
            var failed = unavailable_row ("Safe Senders unavailable", error.message);
            safe_senders_group.add (failed);
            safe_sender_rows.add (failed);
        }
    }

    private void reload_trusted_senders () {
        foreach (var row in trusted_sender_rows) trusted_senders_group.remove (row);
        trusted_sender_rows.clear ();
        try {
            var senders = remote_content_policy.trusted_senders ();
            if (senders.size == 0) {
                var empty = new Adw.ActionRow ();
                empty.title = "No Remote Image Senders";
                empty.subtitle = "Remote images remain blocked by default";
                empty.add_css_class ("settings-empty-row");
                style_row (empty, "network-offline-symbolic");
                trusted_senders_group.add (empty);
                trusted_sender_rows.add (empty);
                return;
            }
            foreach (var address in senders) {
                var row = new Adw.ActionRow ();
                row.title = address;
                row.subtitle = "Remote images allowed";
                style_row (row, "avatar-default-symbolic");
                row.add_css_class ("sender-list-row");
                var remove = remove_button ("Stop trusting this sender",
                    "Stop loading remote images from " + address);
                remove.clicked.connect (() => {
                    try {
                        remote_content_policy.forget_sender (address);
                        reload_trusted_senders ();
                        lists_changed ();
                        sender_safety_changed ();
                    } catch (Error error) {
                        warning ("Could not remove remote image sender: %s", error.message);
                    }
                });
                row.add_suffix (remove);
                trusted_senders_group.add (row);
                trusted_sender_rows.add (row);
            }
        } catch (Error error) {
            var failed = unavailable_row ("Remote Image Senders unavailable", error.message);
            trusted_senders_group.add (failed);
            trusted_sender_rows.add (failed);
        }
    }

    private void add_junk_rule () {
        try {
            var kind = junk_kind_row.selected == 1 ? JunkRuleKind.DOMAIN : JunkRuleKind.ADDRESS;
            cache.add_junk_rule (kind, junk_pattern_row.text);
            junk_pattern_row.text = "";
            junk_error_row.visible = false;
            reload_junk_rules ();
            lists_changed ();
        } catch (Error error) {
            junk_error_row.title = error.message;
            junk_error_row.visible = true;
        }
    }

    private void reload_junk_rules () {
        foreach (var row in junk_rule_rows) junk_rules_group.remove (row);
        junk_rule_rows.clear ();
        try {
            var rules = cache.list_junk_rules ();
            if (rules.size == 0) {
                var empty = new Adw.ActionRow ();
                empty.title = "No Blocked Senders";
                empty.subtitle = "Messages are not moved to Junk by a local sender rule";
                empty.add_css_class ("settings-empty-row");
                style_row (empty, "mail-mark-junk-symbolic");
                junk_rules_group.add (empty);
                junk_rule_rows.add (empty);
                return;
            }
            foreach (var rule in rules) {
                var row = new Adw.ActionRow ();
                row.title = rule.kind == JunkRuleKind.DOMAIN ? "@" + rule.pattern : rule.pattern;
                row.subtitle = rule.kind == JunkRuleKind.DOMAIN ? "Entire domain" : "Email address";
                style_row (row, rule.kind == JunkRuleKind.DOMAIN ?
                    "network-workgroup-symbolic" : "avatar-default-symbolic");
                row.add_css_class ("sender-list-row");
                var remove = remove_button ("Remove blocked sender rule",
                    "Remove blocked sender rule for " + rule.pattern);
                remove.clicked.connect (() => {
                    try {
                        cache.remove_junk_rule (rule.id);
                        junk_error_row.visible = false;
                        reload_junk_rules ();
                        lists_changed ();
                    } catch (Error error) {
                        junk_error_row.title = error.message;
                        junk_error_row.visible = true;
                    }
                });
                row.add_suffix (remove);
                junk_rules_group.add (row);
                junk_rule_rows.add (row);
            }
        } catch (Error error) {
            junk_error_row.title = error.message;
            junk_error_row.visible = true;
        }
    }

    private static Gtk.Button remove_button (string tooltip, string accessible_label) {
        var button = new Gtk.Button.from_icon_name ("user-trash-symbolic");
        button.valign = Gtk.Align.CENTER;
        button.add_css_class ("flat");
        button.add_css_class ("sender-list-remove");
        button.tooltip_text = tooltip;
        Accessibility.label (button, accessible_label);
        return button;
    }

    private static Adw.ActionRow unavailable_row (string title, string detail) {
        var row = new Adw.ActionRow ();
        row.title = title;
        row.subtitle = detail;
        row.add_css_class ("settings-state-row");
        row.add_css_class ("error");
        style_row (row, "dialog-warning-symbolic");
        return row;
    }

    private static void style_page (Adw.PreferencesPage page, string page_class) {
        page.add_css_class ("settings-page-frame");
        page.add_css_class ("settings-subpage-frame");
        page.add_css_class (page_class);
    }

    private static void add_intro (Adw.PreferencesPage page, string kicker,
                                   string title, string description,
                                   string icon_name, string status) {
        var group = new Adw.PreferencesGroup ();
        group.add_css_class ("settings-intro-group");
        group.add_css_class ("settings-subpage-intro-group");
        group.add (new SettingsPageIntro (kicker, title, description, icon_name, status));
        page.add (group);
    }

    private static void style_group (Adw.PreferencesGroup group, string section_name) {
        group.add_css_class ("settings-section");
        group.add_css_class ("settings-section-card");
        group.add_css_class ("settings-section-" + section_name);
    }

    private static void style_row (Adw.ActionRow row, string icon_name) {
        row.add_css_class ("settings-control-row");
        var icon = new Gtk.Image.from_icon_name (icon_name);
        icon.add_css_class ("settings-control-icon");
        row.add_prefix (icon);
    }
}
}
