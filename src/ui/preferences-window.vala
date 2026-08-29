namespace Mailficient {
public class PreferencesWindow : Adw.Dialog {
    public signal void account_saved (AccountSettings account);
    public signal void accounts_changed ();
    public signal void smart_mailboxes_changed ();
    public signal void automation_changed ();
    public signal void rules_requested ();
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
    private Adw.PreferencesGroup quick_steps_group;
    private Gee.ArrayList<Adw.ActionRow> quick_step_rows = new Gee.ArrayList<Adw.ActionRow> ();
    private Adw.ActionRow automation_status_row;
    private Adw.EntryRow smart_name_row;
    private Adw.EntryRow smart_query_row;
    private Adw.PreferencesGroup smart_group;
    private Gee.ArrayList<Adw.ActionRow> smart_rows = new Gee.ArrayList<Adw.ActionRow> ();
    private Adw.ComboRow vacation_identity_row;
    private Gtk.Widget? vacation_search_target;
    private Gtk.Stack settings_stack = new Gtk.Stack ();
    private Gtk.ListBox settings_navigation = new Gtk.ListBox ();
    private Adw.OverlaySplitView settings_split = new Adw.OverlaySplitView ();
    private Gtk.Button navigation_button = new Gtk.Button.from_icon_name ("sidebar-show-symbolic");
    private Gtk.Label settings_page_title = new Gtk.Label ("");
    private Gtk.SearchEntry settings_search = new Gtk.SearchEntry ();
    private Gee.HashMap<string, Gtk.ListBoxRow> settings_navigation_rows =
        new Gee.HashMap<string, Gtk.ListBoxRow> ();
    private Gee.HashMap<string, string> settings_search_terms =
        new Gee.HashMap<string, string> ();
    private Gee.ArrayList<string> settings_navigation_order = new Gee.ArrayList<string> ();
    private Adw.ActionRow quick_step_add_row;

    public PreferencesWindow (CacheDatabase cache, MailSettingsStore settings,
                              RemoteContentPolicy remote_content_policy,
                              CredentialCleanupService credential_cleanup,
                              AccountProvisioningService? account_provisioner,
                              MailEngine? engine, AccountSyncService? sync_service,
                              OnlineAccountService online_accounts) {
        title = "Settings"; content_width = 860; content_height = 600;
        width_request = 360; height_request = 480;
        this.cache = cache; this.settings = settings; this.remote_content_policy = remote_content_policy;
        build_settings_shell ();
        var accounts_page = new AccountSettingsPage (cache, credential_cleanup, account_provisioner,
            engine, sync_service, online_accounts);
        accounts_page.account_saved.connect ((account) => account_saved (account));
        accounts_page.accounts_changed.connect (() => accounts_changed ());
        add_settings_page (accounts_page, "accounts", "Accounts",
            "Connected mail and sign-in", "avatar-default-symbolic");
        var general_page = build_general_page ();
        add_settings_page (general_page, "general", "General",
            "Appearance and mail checks", "preferences-system-symbolic");
        var composing_page = build_composing_page ();
        add_settings_page (composing_page, "composing", "Compose",
            "Writing, signatures, and replies", "document-edit-symbolic");
        var rules_page = build_rules_page ();
        add_settings_page (rules_page, "rules", "Automation",
            "Rules, quick steps, and smart folders", "system-run-symbolic");
        var privacy_page = build_privacy_page ();
        add_settings_page (privacy_page, "privacy", "Safety",
            "Privacy, junk, and remote content", "security-high-symbolic");
        load_identities ();
        settings_stack.notify["visible-child-name"].connect (() => {
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
            requested_page = "composing"; requested_focus = vacation_search_target; break;
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
                    focus_and_reveal (focus_target);
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

    private void build_settings_shell () {
        add_css_class ("settings-dialog");
        settings_stack.add_css_class ("settings-content");
        settings_stack.transition_type = Gtk.StackTransitionType.CROSSFADE;
        settings_stack.transition_duration = 180;

        var sidebar = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        sidebar.add_css_class ("settings-sidebar");
        var sidebar_heading = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
        sidebar_heading.add_css_class ("settings-sidebar-heading");
        var eyebrow = new Gtk.Label ("MAILFICIENT");
        eyebrow.xalign = 0; eyebrow.add_css_class ("settings-sidebar-eyebrow");
        var sidebar_title = new Gtk.Label ("Settings");
        sidebar_title.xalign = 0; sidebar_title.add_css_class ("settings-sidebar-title");
        var sidebar_description = new Gtk.Label ("Make mail work the way you do.");
        sidebar_description.xalign = 0; sidebar_description.wrap = true;
        sidebar_description.add_css_class ("settings-sidebar-description");
        sidebar_heading.append (eyebrow); sidebar_heading.append (sidebar_title);
        sidebar_heading.append (sidebar_description); sidebar.append (sidebar_heading);

        settings_search.add_css_class ("settings-search");
        settings_search.placeholder_text = "Search settings";
        Accessibility.label (settings_search, "Search settings categories");
        settings_search.search_changed.connect (() => settings_navigation.invalidate_filter ());
        settings_search.activate.connect (() => select_first_search_result ());
        sidebar.append (settings_search);

        settings_navigation.add_css_class ("settings-navigation");
        settings_navigation.vexpand = true;
        settings_navigation.selection_mode = Gtk.SelectionMode.SINGLE;
        settings_navigation.activate_on_single_click = true;
        settings_navigation.row_activated.connect ((row) => {
            foreach (var entry in settings_navigation_rows.entries)
                if (entry.value == row) {
                    set_visible_page_name (entry.key);
                    break;
                }
        });
        settings_navigation.set_filter_func ((row) => navigation_row_matches_search (row));
        sidebar.append (settings_navigation);

        var sidebar_footer = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        sidebar_footer.add_css_class ("settings-sidebar-footer");
        sidebar_footer.append (new Gtk.Image.from_icon_name ("security-high-symbolic"));
        var footer_text = new Gtk.Label ("Private settings, stored on this device");
        footer_text.xalign = 0; footer_text.wrap = true; footer_text.add_css_class ("caption");
        sidebar_footer.append (footer_text); sidebar.append (sidebar_footer);

        settings_split.sidebar = sidebar; settings_split.content = settings_stack;
        settings_split.sidebar_position = Gtk.PackType.START;
        settings_split.min_sidebar_width = 210; settings_split.max_sidebar_width = 250;
        settings_split.sidebar_width_fraction = 0.27;
        settings_split.pin_sidebar = true; settings_split.show_sidebar = true;
        settings_split.add_css_class ("settings-split-view");

        var toolbar = new Adw.ToolbarView ();
        toolbar.add_css_class ("settings-toolbar");
        var header = new Adw.HeaderBar ();
        header.add_css_class ("settings-headerbar");
        navigation_button.add_css_class ("flat"); navigation_button.visible = false;
        navigation_button.tooltip_text = "Show settings categories";
        Accessibility.label (navigation_button, "Show settings categories");
        navigation_button.clicked.connect (() =>
            settings_split.show_sidebar = !settings_split.show_sidebar);
        header.pack_start (navigation_button);
        settings_page_title.add_css_class ("settings-current-title");
        header.title_widget = settings_page_title;
        toolbar.add_top_bar (header); toolbar.content = settings_split; child = toolbar;

        var compact = new Adw.Breakpoint (
            new Adw.BreakpointCondition.length (
                Adw.BreakpointConditionLengthType.MAX_WIDTH, 720, Adw.LengthUnit.PX));
        compact.apply.connect (() => {
            settings_split.collapsed = true; settings_split.pin_sidebar = false;
            settings_split.show_sidebar = false; navigation_button.visible = true;
        });
        compact.unapply.connect (() => {
            settings_split.collapsed = false; settings_split.pin_sidebar = true;
            settings_split.show_sidebar = true; navigation_button.visible = false;
        });
        add_breakpoint (compact);
    }

    private void add_settings_page (Adw.PreferencesPage page, string name,
                                    string label, string description, string icon_name) {
        page.add_css_class ("settings-page");
        page.add_css_class ("settings-page-frame");
        page.add_css_class ("settings-page-" + name);
        settings_stack.add_named (page, name);
        var row = new Gtk.ListBoxRow (); row.add_css_class ("settings-nav-row");
        row.activatable = true;
        var row_content = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
        row_content.add_css_class ("settings-nav-content");
        var icon = new Gtk.Image.from_icon_name (icon_name);
        icon.add_css_class ("settings-nav-icon"); icon.valign = Gtk.Align.CENTER;
        row_content.append (icon);
        var labels = new Gtk.Box (Gtk.Orientation.VERTICAL, 1); labels.hexpand = true;
        var title_label = new Gtk.Label (label); title_label.xalign = 0;
        title_label.add_css_class ("settings-nav-title");
        var description_label = new Gtk.Label (description); description_label.xalign = 0;
        description_label.ellipsize = Pango.EllipsizeMode.END;
        description_label.add_css_class ("settings-nav-description");
        labels.append (title_label); labels.append (description_label); row_content.append (labels);
        row.child = row_content; settings_navigation.append (row);
        settings_navigation_rows.set (name, row);
        settings_navigation_order.add (name);
        settings_search_terms.set (name, search_terms_for_page (name, label, description));
        Accessibility.label (row, "%s — %s".printf (label, description));
    }

    private bool navigation_row_matches_search (Gtk.ListBoxRow row) {
        string query = settings_search.text.strip ().down ();
        if (query == "") return true;
        foreach (var entry in settings_navigation_rows.entries)
            if (entry.value == row) {
                string? terms = settings_search_terms.get (entry.key);
                return terms != null && terms.contains (query);
            }
        return false;
    }

    private void select_first_search_result () {
        string query = settings_search.text.strip ().down ();
        if (query == "") return;
        if (query.contains ("vacation") || query.contains ("out of office") ||
            query.contains ("automatic reply")) {
            show_search_route ("composing", vacation_search_target); return;
        }
        if (query.contains ("signature") || query.contains ("identity")) {
            show_search_route ("composing", identity_row); return;
        }
        if (query.contains ("smart mailbox") || query.contains ("saved search")) {
            show_search_route ("rules", smart_name_row); return;
        }
        if (query.contains ("quick step")) {
            show_search_route ("rules", quick_step_add_row); return;
        }
        if (query.contains ("blocked") || query.contains ("junk")) {
            show_search_route ("privacy", blocked_senders_row); return;
        }
        if (query.contains ("safe sender")) {
            show_search_route ("privacy", safe_senders_row); return;
        }
        if (query.contains ("remote image") || query.contains ("trusted sender")) {
            show_search_route ("privacy", remote_image_senders_row); return;
        }
        foreach (string page_name in settings_navigation_order) {
            string? terms = settings_search_terms.get (page_name);
            if (terms != null && terms.contains (query)) {
                set_visible_page_name (page_name);
                return;
            }
        }
    }

    private void show_search_route (string page_name, Gtk.Widget? focus_target) {
        set_visible_page_name (page_name);
        if (focus_target == null) return;
        Gtk.Widget target = focus_target;
        Idle.add (() => {
            if (target.get_root () != null) focus_and_reveal (target);
            return Source.REMOVE;
        });
    }

    private static void focus_and_reveal (Gtk.Widget target) {
        target.grab_focus ();
        Gtk.Widget? ancestor = target.get_parent ();
        while (ancestor != null && !(ancestor is Gtk.ScrolledWindow))
            ancestor = ancestor.get_parent ();
        var scroller = ancestor as Gtk.ScrolledWindow;
        if (scroller == null) return;
        Graphene.Rect bounds;
        if (!target.compute_bounds (scroller, out bounds)) return;
        var adjustment = scroller.vadjustment;
        double viewport_height = scroller.get_height ();
        double margin = 18;
        double delta = 0;
        if (bounds.get_y () < margin)
            delta = bounds.get_y () - margin;
        else if (bounds.get_y () + bounds.get_height () > viewport_height - margin)
            delta = bounds.get_y () + bounds.get_height () - viewport_height + margin;
        double value = adjustment.value + delta;
        double maximum = adjustment.upper - adjustment.page_size;
        if (value < adjustment.lower) value = adjustment.lower;
        if (value > maximum) value = maximum;
        adjustment.value = value;
    }

    private static string search_terms_for_page (string name, string label, string description) {
        string details;
        switch (name) {
        case "accounts":
            details = "add remove provider password oauth server connection identity"; break;
        case "composing":
            details = "writing sending spellcheck undo send signature vacation reply subject"; break;
        case "rules":
            details = "filter rules quick steps smart mailboxes saved search automation"; break;
        case "privacy":
            details = "privacy safety junk blocked safe senders remote images tracking"; break;
        default:
            details = "appearance color theme checking sync interval notifications reading conversations"; break;
        }
        return "%s %s %s %s".printf (name, label, description, details).down ();
    }

    public void set_visible_page_name (string page_name) {
        Gtk.Widget? page = settings_stack.get_child_by_name (page_name);
        string target = page == null ? "general" : page_name;
        settings_stack.visible_child_name = target;
        var row = settings_navigation_rows.get (target);
        if (row != null) settings_navigation.select_row (row);
        switch (target) {
        case "accounts": settings_page_title.label = "Accounts"; break;
        case "composing": settings_page_title.label = "Compose"; break;
        case "rules": settings_page_title.label = "Automation"; break;
        case "privacy": settings_page_title.label = "Safety"; break;
        default: settings_page_title.label = "General"; break;
        }
        if (settings_split.collapsed) settings_split.show_sidebar = false;
    }

    public string? get_visible_page_name () {
        return settings_stack.visible_child_name;
    }

    public void show_smart_mailbox_creation () {
        set_visible_page_name ("rules");
        Idle.add (() => {
            if (smart_name_row.get_root () != null)
                smart_name_row.grab_focus ();
            return Source.REMOVE;
        });
    }

    private void add_page_intro (Adw.PreferencesPage page, string kicker,
                                 string title, string description,
                                 string icon_name, string status) {
        var group = new Adw.PreferencesGroup ();
        group.add_css_class ("settings-intro-group");
        var intro = new SettingsPageIntro (kicker, title, description, icon_name, status);
        group.add (intro); page.add (group);
    }

    private static Adw.PreferencesGroup settings_section (string title,
                                                          string description,
                                                          string section_name) {
        var group = new Adw.PreferencesGroup ();
        group.title = title;
        if (description != "") group.description = description;
        group.add_css_class ("settings-section");
        group.add_css_class ("settings-section-card");
        group.add_css_class ("settings-section-" + section_name);
        return group;
    }

    private static void style_control_row (Adw.ActionRow row, string icon_name = "") {
        row.add_css_class ("settings-control-row");
        if (icon_name == "") return;
        var icon = new Gtk.Image.from_icon_name (icon_name);
        icon.add_css_class ("settings-control-icon");
        row.add_prefix (icon);
    }

    private static void style_entry_row (Adw.PreferencesRow row) {
        row.add_css_class ("settings-control-row");
    }

    private static Gtk.Image action_chevron () {
        var arrow = new Gtk.Image.from_icon_name ("go-next-symbolic");
        arrow.valign = Gtk.Align.CENTER;
        arrow.add_css_class ("settings-action-chevron");
        return arrow;
    }

    private static Gtk.ToggleButton appearance_option (string name, string title,
                                                        string description) {
        var button = new Gtk.ToggleButton ();
        button.add_css_class ("appearance-option");
        button.add_css_class ("appearance-option-" + name);
        button.hexpand = true;
        button.tooltip_text = "%s — %s".printf (title, description);
        Accessibility.label (button, title + " appearance");
        Accessibility.description (button, description);

        var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
        content.add_css_class ("appearance-option-content");
        var preview = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        preview.add_css_class ("appearance-option-preview");
        var preview_header = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        preview_header.add_css_class ("appearance-preview-header");
        var preview_body = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        preview_body.add_css_class ("appearance-preview-body");
        var preview_sidebar = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        preview_sidebar.add_css_class ("appearance-preview-sidebar");
        var preview_canvas = new Gtk.Box (Gtk.Orientation.VERTICAL, 4);
        preview_canvas.add_css_class ("appearance-preview-canvas");
        preview_canvas.hexpand = true;
        var line_one = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        line_one.add_css_class ("appearance-preview-line");
        line_one.add_css_class ("appearance-preview-line-primary");
        var line_two = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        line_two.add_css_class ("appearance-preview-line");
        preview_canvas.append (line_one); preview_canvas.append (line_two);
        preview_body.append (preview_sidebar); preview_body.append (preview_canvas);
        preview.append (preview_header); preview.append (preview_body);

        var title_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 4);
        var title_label = new Gtk.Label (title);
        title_label.xalign = 0; title_label.hexpand = true;
        title_label.add_css_class ("appearance-option-title");
        var check = new Gtk.Image.from_icon_name ("object-select-symbolic");
        check.add_css_class ("appearance-option-check");
        title_row.append (title_label); title_row.append (check);
        var description_label = new Gtk.Label (description);
        description_label.xalign = 0;
        description_label.ellipsize = Pango.EllipsizeMode.END;
        description_label.add_css_class ("appearance-option-description");
        content.append (preview); content.append (title_row); content.append (description_label);
        button.child = content;
        return button;
    }

    private Adw.PreferencesPage build_general_page () {
        var page = new Adw.PreferencesPage (); page.title = "General"; page.icon_name = "preferences-system-symbolic";
        add_page_intro (page, "EVERYDAY MAIL", "Set your rhythm",
            "Choose how Mailficient looks, checks for messages, and gets your attention.",
            "preferences-system-symbolic", "Changes save automatically");

        var appearance_group = settings_section ("Look &amp; Feel",
            "Keep Mailficient in step with your desktop or choose a fixed appearance.",
            "appearance");
        var appearance_chooser = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);
        appearance_chooser.add_css_class ("appearance-chooser");
        var options = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        options.add_css_class ("appearance-options");
        options.homogeneous = true;
        var system_option = appearance_option ("system", "System", "Follows desktop");
        var light_option = appearance_option ("light", "Light", "Always light");
        var dark_option = appearance_option ("dark", "Dark", "Always dark");
        light_option.set_group (system_option); dark_option.set_group (system_option);
        options.accessible_role = Gtk.AccessibleRole.RADIO_GROUP;
        Accessibility.label (options, "Appearance");
        system_option.accessible_role = Gtk.AccessibleRole.RADIO;
        light_option.accessible_role = Gtk.AccessibleRole.RADIO;
        dark_option.accessible_role = Gtk.AccessibleRole.RADIO;
        options.append (system_option); options.append (light_option); options.append (dark_option);
        system_option.toggled.connect (() => {
            if (!system_option.active) return;
            settings.appearance = "system";
        });
        light_option.toggled.connect (() => {
            if (!light_option.active) return;
            settings.appearance = "light";
        });
        dark_option.toggled.connect (() => {
            if (!dark_option.active) return;
            settings.appearance = "dark";
        });
        string current_appearance = settings.appearance;
        if (current_appearance != "light" && current_appearance != "dark")
            current_appearance = "system";
        if (current_appearance == "light") light_option.active = true;
        else if (current_appearance == "dark") dark_option.active = true;
        else system_option.active = true;
        appearance_chooser.append (options);
        appearance_group.add (appearance_chooser); page.add (appearance_group);

        var checking = settings_section ("Mail Delivery",
            "Control when new messages arrive and when Mailficient lets you know.",
            "delivery");
        var intervals = new Gtk.StringList (null);
        intervals.append ("Manually"); intervals.append ("Every minute");
        intervals.append ("Every 5 minutes"); intervals.append ("Every 15 minutes");
        intervals.append ("Every 30 minutes"); intervals.append ("Every hour");
        var interval = new Adw.ComboRow (); interval.title = "Check for new mail"; interval.model = intervals;
        interval.subtitle = "The schedule changes immediately";
        style_control_row (interval, "view-refresh-symbolic");
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
        startup.subtitle = "Bring every account up to date when the app opens";
        style_control_row (startup, "system-run-symbolic");
        startup.active = settings.sync_on_startup;
        startup.notify["active"].connect (() => settings.sync_on_startup = startup.active);
        checking.add (startup);
        var notifications = new Adw.SwitchRow (); notifications.title = "Desktop notifications";
        notifications.subtitle = "Show the sender and subject for new mail";
        style_control_row (notifications, "mail-unread-symbolic");
        notifications.active = settings.notifications_enabled;
        notifications.notify["active"].connect (() => settings.notifications_enabled = notifications.active);
        checking.add (notifications); page.add (checking);

        var reading = settings_section ("Conversations", "Choose how related messages read together.",
            "reading");
        var conversations = new Adw.SwitchRow ();
        conversations.title = "Group related messages";
        conversations.subtitle = "Show the full thread when you open a message";
        style_control_row (conversations, "view-list-symbolic");
        conversations.active = settings.group_messages;
        conversations.notify["active"].connect (() => settings.group_messages = conversations.active);
        reading.add (conversations); page.add (reading); return page;
    }

    private Adw.PreferencesPage build_composing_page () {
        var page = new Adw.PreferencesPage (); page.title = "Compose"; page.icon_name = "document-edit-symbolic";
        add_page_intro (page, "WRITING", "Send with confidence",
            "Keep writing private, make sends recoverable, and give each identity its own voice.",
            "document-edit-symbolic", "Local-first writing tools");

        var safety = settings_section ("Writing &amp; Sending",
            "Small safeguards that stay out of the way until you need them.", "writing");
        var spellcheck = new Adw.SwitchRow (); spellcheck.title = "Check spelling while typing";
        spellcheck.subtitle = "Uses your local dictionary; message text stays on this device";
        style_control_row (spellcheck, "tools-check-spelling-symbolic");
        spellcheck.active = settings.spellcheck_enabled;
        spellcheck.notify["active"].connect (() => settings.spellcheck_enabled = spellcheck.active);
        safety.add (spellcheck);
        var undo_send_enabled = new Adw.SwitchRow ();
        undo_send_enabled.title = "Undo Send";
        undo_send_enabled.subtitle = "Hold a message briefly so you can take it back";
        style_control_row (undo_send_enabled, "edit-undo-symbolic");
        undo_send_enabled.active = settings.undo_send_enabled;
        safety.add (undo_send_enabled);
        var undo_send_window = new Adw.SpinRow.with_range (5, 30, 1);
        undo_send_window.title = "Undo time";
        undo_send_window.subtitle = "Seconds before a queued message is released";
        style_control_row (undo_send_window, "preferences-system-time-symbolic");
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

        var group = settings_section ("Signature",
            "Choose a separate plain-text signature for each sending identity.", "signature");
        identity_row = new Adw.ComboRow (); identity_row.title = "Identity"; identity_row.model = identity_labels;
        style_control_row (identity_row, "avatar-default-symbolic");
        identity_row.notify["selected"].connect (() => identity_changed ()); group.add (identity_row);
        signature_enabled_row = new Adw.ActionRow (); signature_enabled_row.title = "Add signature automatically";
        signature_enabled_row.subtitle = "Insert it when composing from this identity";
        style_control_row (signature_enabled_row, "document-edit-symbolic");
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
        signature_editor.add_css_class ("settings-editor");
        signature_editor.buffer.changed.connect (() => { if (!loading) save_signature (); });
        var scroller = new Gtk.ScrolledWindow (); scroller.set_policy (Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC);
        scroller.set_min_content_height (100); scroller.set_child (signature_editor);
        var editor_card = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
        editor_card.add_css_class ("settings-editor-card");
        editor_card.add_css_class ("signature-editor-card");
        var editor_heading = new Gtk.Label ("Signature text");
        editor_heading.xalign = 0; editor_heading.add_css_class ("settings-editor-heading");
        var editor_note = new Gtk.Label ("Saved automatically for the selected identity");
        editor_note.xalign = 0; editor_note.wrap = true; editor_note.add_css_class ("settings-editor-note");
        editor_card.append (editor_heading); editor_card.append (scroller); editor_card.append (editor_note);
        group.add (editor_card); page.add (group);
        add_vacation_settings (page);
        return page;
    }

    private Adw.PreferencesPage build_privacy_page () {
        var page = new Adw.PreferencesPage (); page.title = "Safety"; page.icon_name = "security-high-symbolic";
        add_page_intro (page, "PRIVACY", "Open mail on your terms",
            "Control outside content, preserve trusted formatting, and manage sender exceptions in one place.",
            "security-high-symbolic", "Scripts stay blocked");

        var group = settings_section ("Message Privacy",
            "Safer defaults reduce tracking without making trusted mail harder to read.",
            "message-content");
        var images = new Adw.SwitchRow (); images.title = "Always show remote images";
        images.subtitle = "Allow external images from every sender without asking";
        style_control_row (images, "image-x-generic-symbolic");
        images.active = settings.always_show_images;
        images.notify["active"].connect (() => settings.always_show_images = images.active);
        group.add (images);
        var full_html = new Adw.SwitchRow (); full_html.title = "Use original message formatting";
        full_html.subtitle = "Preserve the sender’s HTML styles and layout";
        style_control_row (full_html, "text-html-symbolic");
        full_html.active = settings.full_html_formatting;
        full_html.notify["active"].connect (() => settings.full_html_formatting = full_html.active);
        group.add (full_html);
        var remote = new Adw.ActionRow (); remote.title = "Remote content protection";
        remote.subtitle = "External images can reveal when and where mail is opened";
        remote.add_css_class ("settings-state-row");
        style_control_row (remote, "network-offline-symbolic");
        var remote_state = new Gtk.Label ("Per sender");
        remote_state.add_css_class ("settings-state-badge"); remote_state.valign = Gtk.Align.CENTER;
        remote.add_suffix (remote_state); group.add (remote);
        var scripts = new Adw.ActionRow (); scripts.title = "Scripts and privileged access";
        scripts.subtitle = "Never run, even when original formatting is enabled";
        scripts.add_css_class ("settings-state-row");
        style_control_row (scripts, "channel-secure-symbolic");
        var scripts_state = new Gtk.Label ("Always blocked");
        scripts_state.add_css_class ("settings-state-badge"); scripts_state.valign = Gtk.Align.CENTER;
        scripts.add_suffix (scripts_state); group.add (scripts);
        page.add (group);
        add_sender_list_settings (page);
        return page;
    }

    private void add_sender_list_settings (Adw.PreferencesPage page) {
        var lists = settings_section ("Sender Exceptions",
            "Review the people and domains that receive different privacy or junk treatment.",
            "sender-lists");
        safe_senders_row = sender_list_row ("Safe Senders", "security-medium-symbolic", "safe");
        blocked_senders_row = sender_list_row ("Blocked Senders", "mail-mark-junk-symbolic", "blocked");
        remote_image_senders_row = sender_list_row ("Remote Image Senders", "image-x-generic-symbolic", "remote-images");
        lists.add (remote_image_senders_row);
        lists.add (safe_senders_row);
        lists.add (blocked_senders_row);
        page.add (lists);
        reload_sender_list_summaries ();
    }

    private Adw.ActionRow sender_list_row (string title, string icon_name, string page_name) {
        var row = new Adw.ActionRow ();
        row.title = title;
        row.add_css_class ("settings-action-row");
        style_control_row (row, icon_name);
        row.add_suffix (action_chevron ());
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
            if (count == 0) safe_senders_row.subtitle = "No senders";
            else if (count == 1) safe_senders_row.subtitle = "1 sender";
            else safe_senders_row.subtitle = "%d senders".printf (count);
        } catch (Error error) {
            safe_senders_row.subtitle = "List unavailable";
        }
        try {
            int count = cache.list_junk_rules ().size;
            if (count == 0) blocked_senders_row.subtitle = "No sender or domain rules";
            else if (count == 1) blocked_senders_row.subtitle = "1 sender or domain rule";
            else blocked_senders_row.subtitle = "%d sender or domain rules".printf (count);
        } catch (Error error) {
            blocked_senders_row.subtitle = "List unavailable";
        }
        try {
            int count = remote_content_policy.trusted_senders ().size;
            if (count == 0) remote_image_senders_row.subtitle = "No senders";
            else if (count == 1) remote_image_senders_row.subtitle = "1 sender";
            else remote_image_senders_row.subtitle = "%d senders".printf (count);
        } catch (Error error) {
            remote_image_senders_row.subtitle = "List unavailable";
        }
    }

    private Adw.PreferencesPage build_rules_page () {
        var page = new Adw.PreferencesPage (); page.title = "Automation"; page.icon_name = "system-run-symbolic";
        add_page_intro (page, "AUTOMATION", "Let routine mail handle itself",
            "Build rules, save multi-action shortcuts, and keep useful searches in the sidebar.",
            "system-run-symbolic", "You stay in control");

        var add = settings_section ("Mail Rules",
            "Create precise multi-condition workflows in the dedicated Rules window.", "rules");
        var feature = new Gtk.Box (Gtk.Orientation.VERTICAL, 10);
        feature.add_css_class ("settings-feature-card");
        var feature_top = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
        var badge = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        badge.add_css_class ("settings-feature-card-icon-badge");
        badge.valign = Gtk.Align.CENTER;
        var feature_icon = new Gtk.Image.from_icon_name ("system-run-symbolic");
        feature_icon.add_css_class ("settings-feature-card-icon");
        feature_icon.halign = Gtk.Align.CENTER; feature_icon.valign = Gtk.Align.CENTER;
        badge.append (feature_icon); feature_top.append (badge);
        var feature_copy = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
        feature_copy.add_css_class ("settings-feature-card-copy"); feature_copy.hexpand = true;
        var feature_title = new Gtk.Label ("Build powerful mail rules");
        feature_title.xalign = 0; feature_title.add_css_class ("settings-feature-card-title");
        var feature_description = new Gtk.Label (
            "Match senders, subjects, folders, dates, labels, and security details—then run one or many actions.");
        feature_description.xalign = 0; feature_description.wrap = true;
        feature_description.add_css_class ("settings-feature-card-description");
        feature_copy.append (feature_title); feature_copy.append (feature_description);
        feature_top.append (feature_copy); feature.append (feature_top);
        var create = new Gtk.Button.with_label ("Open Rules…"); create.halign = Gtk.Align.START;
        create.add_css_class ("suggested-action"); create.add_css_class ("settings-feature-card-action");
        create.clicked.connect (open_rules_window); feature.append (create); add.add (feature);
        page.add (add);
        automation_status_row = new Adw.ActionRow (); automation_status_row.visible = false;
        automation_status_row.add_css_class ("automation-status");
        automation_status_row.add_css_class ("settings-state-row");
        style_control_row (automation_status_row, "emblem-ok-symbolic"); add.add (automation_status_row);
        quick_steps_group = settings_section ("Quick Steps",
            "Apply a reusable sequence of actions to selected messages from More → Quick Steps.",
            "quick-steps");
        quick_step_add_row = new Adw.ActionRow ();
        quick_step_add_row.title = "Create a Quick Step";
        quick_step_add_row.subtitle = "Combine several message actions into one command";
        quick_step_add_row.add_css_class ("settings-action-row");
        style_control_row (quick_step_add_row, "list-add-symbolic");
        quick_step_add_row.add_suffix (action_chevron ());
        quick_step_add_row.activatable = true;
        quick_step_add_row.activated.connect (() => add_quick_step.begin ());
        quick_steps_group.add (quick_step_add_row);
        page.add (quick_steps_group);
        reload_quick_steps ();
        add_smart_mailbox_settings (page);
        return page;
    }

    private void open_rules_window () {
        rules_requested ();
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

    private void reload_quick_steps () {
        foreach (var row in quick_step_rows) quick_steps_group.remove (row); quick_step_rows.clear ();
        try {
            var steps = cache.list_quick_steps ();
            if (steps.size == 0) {
                var empty = new Adw.ActionRow ();
                empty.title = "No Quick Steps yet";
                empty.subtitle = "Your saved shortcuts will appear here.";
                empty.add_css_class ("settings-empty-row");
                style_control_row (empty, "media-playlist-consecutive-symbolic");
                quick_steps_group.add (empty); quick_step_rows.add (empty);
                return;
            }
            foreach (var step in steps) {
                var row = new Adw.ActionRow (); row.title = step.name;
                row.add_css_class ("quick-step-row");
                style_control_row (row, "media-playlist-consecutive-symbolic");
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
        var add = settings_section ("Smart Folders",
            "Save a search in the sidebar and let its results update as mail changes.",
            "smart-mailboxes");
        add.add_css_class ("smart-mailbox-editor");
        smart_name_row = new Adw.EntryRow (); smart_name_row.title = "Name";
        style_entry_row (smart_name_row); add.add (smart_name_row);
        smart_query_row = new Adw.EntryRow (); smart_query_row.title = "Search";
        smart_query_row.text = "is:unread"; style_entry_row (smart_query_row); add.add (smart_query_row);
        var smart_actions = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        smart_actions.add_css_class ("settings-inline-actions");
        smart_actions.add_css_class ("smart-mailbox-actions"); smart_actions.halign = Gtk.Align.END;
        var create = new Gtk.Button.with_label ("Add Smart Folder");
        create.add_css_class ("suggested-action"); create.clicked.connect (() => {
            try {
                cache.add_smart_mailbox (smart_name_row.text, smart_query_row.text);
                smart_name_row.text = ""; smart_query_row.text = "is:unread"; reload_smart_mailboxes (); smart_mailboxes_changed ();
            } catch (Error error) { show_automation_status (error.message, true); }
        }); create.add_css_class ("settings-primary-action"); smart_actions.append (create);
        add.add (smart_actions); page.add (add);
        smart_group = settings_section ("Saved Searches",
            "These Smart Folders appear below your regular folders.", "saved-searches");
        page.add (smart_group);
        reload_smart_mailboxes ();
    }

    private void reload_smart_mailboxes () {
        foreach (var row in smart_rows) smart_group.remove (row); smart_rows.clear ();
        try {
            var mailboxes = cache.list_smart_mailboxes ();
            if (mailboxes.size == 0) {
                var empty = new Adw.ActionRow ();
                empty.title = "No Smart Folders yet";
                empty.subtitle = "Create one above to keep a useful search close by.";
                empty.add_css_class ("settings-empty-row");
                style_control_row (empty, "folder-saved-search-symbolic");
                smart_group.add (empty); smart_rows.add (empty); return;
            }
            foreach (var smart in mailboxes) {
                var row = new Adw.ActionRow (); row.title = smart.name; row.subtitle = smart.query;
                row.add_css_class ("smart-mailbox-row");
                style_control_row (row, "folder-saved-search-symbolic");
                var remove = new Gtk.Button.from_icon_name ("user-trash-symbolic"); remove.valign = Gtk.Align.CENTER;
                Accessibility.label (remove, "Delete Smart Folder " + smart.name);
                remove.clicked.connect (() => { try { cache.remove_smart_mailbox (smart.id); reload_smart_mailboxes (); smart_mailboxes_changed (); }
                    catch (Error error) { show_automation_status (error.message, true); } });
                row.add_suffix (remove); smart_group.add (row); smart_rows.add (row);
            }
        } catch (Error error) { show_automation_status (error.message, true); }
    }

    private void add_vacation_settings (Adw.PreferencesPage page) {
        var group = settings_section ("Vacation Reply",
            "Reply once to each sender while Mailficient is running and checking mail.",
            "vacation");
        group.add_css_class ("vacation-editor");
        var accounts = new Gtk.StringList (null); var ids = new Gee.ArrayList<string> ();
        try { foreach (var account in cache.list_accounts ()) { accounts.append (account.email); ids.add (account.id); } }
        catch (Error error) { warning ("Could not load vacation identities: %s", error.message); }
        vacation_identity_row = new Adw.ComboRow (); vacation_identity_row.title = "Account";
        vacation_identity_row.model = accounts;
        style_control_row (vacation_identity_row, "avatar-default-symbolic"); group.add (vacation_identity_row);
        vacation_search_target = vacation_identity_row;
        var enabled = new Adw.SwitchRow (); enabled.title = "Send vacation replies";
        enabled.subtitle = "Turn this reply schedule on for the selected account";
        style_control_row (enabled, "mail-send-symbolic"); group.add (enabled);
        var starts = new OptionalDateRow ("Starts"); style_control_row (starts, "x-office-calendar-symbolic"); group.add (starts);
        var ends = new OptionalDateRow ("Ends"); style_control_row (ends, "x-office-calendar-symbolic"); group.add (ends);
        var subject = new Adw.EntryRow (); subject.title = "Reply subject";
        style_entry_row (subject); group.add (subject);
        var body = new Gtk.TextView (); body.wrap_mode = Gtk.WrapMode.WORD_CHAR; body.set_size_request (-1, 96);
        body.add_css_class ("settings-editor");
        Accessibility.label (body, "Vacation reply message"); var body_scroll = new Gtk.ScrolledWindow ();
        body_scroll.child = body;
        var body_card = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
        body_card.add_css_class ("settings-editor-card");
        var body_heading = new Gtk.Label ("Reply message");
        body_heading.xalign = 0; body_heading.add_css_class ("settings-editor-heading");
        var body_note = new Gtk.Label ("Sent at most once to each sender during this schedule");
        body_note.xalign = 0; body_note.wrap = true; body_note.add_css_class ("settings-editor-note");
        body_card.append (body_heading); body_card.append (body_scroll); body_card.append (body_note);
        group.add (body_card);
        var vacation_status = new Adw.ActionRow (); vacation_status.visible = false;
        vacation_status.add_css_class ("vacation-status");
        vacation_status.add_css_class ("settings-state-row");
        vacation_status.accessible_role = Gtk.AccessibleRole.STATUS;
        style_control_row (vacation_status, "emblem-ok-symbolic");
        group.add (vacation_status);
        bool loading_vacation = false;
        SourceFunc load = () => {
            if (ids.size == 0 || vacation_identity_row.selected >= ids.size) return Source.REMOVE;
            loading_vacation = true;
            try {
                var value = cache.vacation_settings (ids[(int) vacation_identity_row.selected]);
                enabled.active = value != null && value.enabled;
                starts.set_timestamp (value == null ? 0 : value.starts_at);
                ends.set_timestamp (value == null ? 0 : value.ends_at);
                subject.text = value == null ? "Out of office" : value.subject; body.buffer.text = value == null ? "" : value.body;
                bool fields_enabled = enabled.active;
                starts.sensitive = fields_enabled; ends.sensitive = fields_enabled;
                subject.sensitive = fields_enabled; body.sensitive = fields_enabled;
            } catch (Error error) {
                vacation_status.title = "Vacation reply settings are unavailable";
                vacation_status.subtitle = error.message; vacation_status.accessible_role = Gtk.AccessibleRole.ALERT;
                vacation_status.visible = true;
            }
            loading_vacation = false; return Source.REMOVE;
        };
        vacation_identity_row.notify["selected"].connect (() => load ());
        enabled.notify["active"].connect (() => {
            if (loading_vacation) return;
            starts.sensitive = enabled.active; ends.sensitive = enabled.active;
            subject.sensitive = enabled.active; body.sensitive = enabled.active;
        });
        var vacation_actions = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        vacation_actions.add_css_class ("settings-inline-actions");
        vacation_actions.add_css_class ("vacation-editor-actions"); vacation_actions.halign = Gtk.Align.END;
        var save = new Gtk.Button.with_label ("Save Vacation Reply");
        save.add_css_class ("suggested-action"); save.clicked.connect (() => {
            if (loading_vacation || ids.size == 0 || vacation_identity_row.selected >= ids.size) return;
            try {
                var value = new VacationSettings (ids[(int) vacation_identity_row.selected]); value.enabled = enabled.active;
                value.starts_at = parse_optional_day (starts.iso_date, false);
                value.ends_at = parse_optional_day (ends.iso_date, true);
                value.subject = subject.text; value.body = body.buffer.text; cache.save_vacation_settings (value);
                vacation_status.title = "Vacation Reply Saved";
                vacation_status.subtitle = enabled.active ? "Automatic replies are on." : "Automatic replies are off.";
                vacation_status.accessible_role = Gtk.AccessibleRole.STATUS; vacation_status.visible = true;
            } catch (Error error) {
                vacation_status.title = "Vacation reply could not be saved";
                vacation_status.subtitle = error.message; vacation_status.accessible_role = Gtk.AccessibleRole.ALERT;
                vacation_status.visible = true;
            }
        }); save.add_css_class ("settings-primary-action"); vacation_actions.append (save);
        group.add (vacation_actions);
        if (ids.size == 0) {
            group.description = "Add a mail account before setting an automatic vacation reply.";
            vacation_identity_row.visible = false; enabled.visible = false;
            starts.visible = false; ends.visible = false; subject.visible = false;
            body_card.visible = false; vacation_actions.visible = false;
            var empty = new Adw.ActionRow ();
            empty.title = "Connect an account to schedule replies";
            empty.subtitle = "Account settings will guide you through secure sign-in.";
            empty.add_css_class ("settings-empty-row");
            empty.add_css_class ("vacation-empty-row");
            style_control_row (empty, "avatar-default-symbolic");
            var open_accounts = new Gtk.Button.with_label ("Open Accounts");
            open_accounts.valign = Gtk.Align.CENTER;
            open_accounts.add_css_class ("settings-empty-action");
            open_accounts.clicked.connect (() => set_visible_page_name ("accounts"));
            empty.add_suffix (open_accounts);
            empty.activatable = true;
            empty.activatable_widget = open_accounts;
            group.add (empty);
            vacation_search_target = open_accounts;
        }
        if (ids.size == 0)
            page.insert (group, 2);
        else
            page.add (group);
        load ();
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

internal class SettingsPageIntro : Gtk.Box {
    private Gtk.Label status_label = new Gtk.Label ("");

    public SettingsPageIntro (string kicker, string title, string description,
                              string icon_name, string status) {
        Object (orientation: Gtk.Orientation.HORIZONTAL, spacing: 14);
        add_css_class ("settings-page-intro");

        var badge = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        badge.add_css_class ("settings-page-intro-icon-badge");
        badge.valign = Gtk.Align.START;
        var icon = new Gtk.Image.from_icon_name (icon_name);
        icon.add_css_class ("settings-page-intro-icon");
        icon.pixel_size = 24; icon.halign = Gtk.Align.CENTER; icon.valign = Gtk.Align.CENTER;
        badge.append (icon); append (badge);

        var copy = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
        copy.add_css_class ("settings-page-intro-copy"); copy.hexpand = true;
        var kicker_label = new Gtk.Label (kicker);
        kicker_label.xalign = 0; kicker_label.add_css_class ("settings-page-intro-kicker");
        var title_label = new Gtk.Label (title);
        title_label.xalign = 0; title_label.wrap = true;
        title_label.add_css_class ("settings-page-intro-title");
        var description_label = new Gtk.Label (description);
        description_label.xalign = 0; description_label.wrap = true;
        description_label.max_width_chars = 62;
        description_label.add_css_class ("settings-page-intro-description");
        status_label.xalign = 0;
        status_label.halign = Gtk.Align.START;
        status_label.wrap = false;
        status_label.add_css_class ("settings-page-intro-status");
        copy.append (kicker_label); copy.append (title_label);
        copy.append (description_label); copy.append (status_label); append (copy);
        set_status (status);
        Accessibility.label (this, "%s. %s. %s".printf (title, description, status));
    }

    public void set_status (string status) {
        status_label.label = status;
        status_label.visible = status != "";
    }
}

private class OptionalDateRow : Adw.ActionRow {
    public string iso_date { get; private set; default = ""; }
    private Gtk.Button choose_button = new Gtk.Button.with_label ("Choose…");
    private Gtk.Button clear_button = new Gtk.Button.from_icon_name ("edit-clear-symbolic");

    public OptionalDateRow (string title) {
        this.title = title; subtitle = "Not set";
        choose_button.valign = Gtk.Align.CENTER; choose_button.clicked.connect (() => choose_date.begin ());
        clear_button.valign = Gtk.Align.CENTER; clear_button.add_css_class ("flat");
        clear_button.tooltip_text = "Clear date"; Accessibility.label (clear_button, "Clear " + title.down () + " date");
        clear_button.clicked.connect (() => set_date ("")); clear_button.visible = false;
        add_suffix (choose_button); add_suffix (clear_button);
    }

    public void set_timestamp (int64 timestamp) {
        set_date (timestamp == 0 ? "" : new DateTime.from_unix_local (timestamp).format ("%F"));
    }

    private async void choose_date () {
        var calendar = new Gtk.Calendar (); calendar.show_day_names = true; calendar.show_heading = true;
        if (iso_date != "") {
            var selected = new DateTime.from_iso8601 (iso_date + "T12:00:00", new TimeZone.local ());
            if (selected != null) calendar.select_day (selected);
        }
        var dialog = new Adw.AlertDialog ("Choose " + title.down () + " date", null);
        dialog.extra_child = calendar; dialog.add_response ("cancel", "Cancel");
        dialog.add_response ("choose", "Choose Date"); dialog.default_response = "choose";
        dialog.close_response = "cancel";
        if ((yield dialog.choose (this, null)) != "choose") return;
        set_date (calendar.get_date ().format ("%F"));
    }

    private void set_date (string value) {
        iso_date = value;
        if (value == "") {
            subtitle = "Not set"; choose_button.label = "Choose…"; clear_button.visible = false; return;
        }
        var date = new DateTime.from_iso8601 (value + "T12:00:00", new TimeZone.local ());
        subtitle = date == null ? value : date.format ("%B %e, %Y");
        choose_button.label = "Change…"; clear_button.visible = true;
    }
}
}
