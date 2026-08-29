namespace Mailficient {
public class AccountDialog : Adw.PreferencesDialog {
    public signal void account_saved (AccountSettings account);

    private AccountProvisioningService? provisioner;
    private Adw.EntryRow display_name_row = field ("Name", "Your display name");
    private Adw.EntryRow email = field ("Email", "you@example.com");
    private Adw.EntryRow incoming_host = field ("Incoming server", "imap.example.com");
    private Adw.EntryRow incoming_user = field ("Incoming username", "you@example.com");
    private Adw.EntryRow incoming_port = field ("Incoming port", "993");
    private Adw.ComboRow incoming_security = security_row ();
    private Adw.EntryRow outgoing_host = field ("Outgoing server", "smtp.example.com");
    private Adw.EntryRow outgoing_user = field ("Outgoing username", "you@example.com");
    private Adw.EntryRow outgoing_port = field ("Outgoing port", "465");
    private Adw.ComboRow outgoing_security = security_row ();
    private Adw.PasswordEntryRow password = new Adw.PasswordEntryRow ();
    private Adw.PasswordEntryRow outgoing_password = new Adw.PasswordEntryRow ();
    private Adw.ActionRow status = new Adw.ActionRow ();
    private Adw.ActionRow validation = new Adw.ActionRow ();
    private Adw.ExpanderRow server_settings = new Adw.ExpanderRow ();
    private Gtk.Button save = new Gtk.Button.with_label ("Add Account");
    private bool applied_defaults;
    private bool connecting;
    private AccountSettings? existing;
    private MailProvider provider;

    public AccountDialog (AccountProvisioningService? provisioner, AccountSettings? existing = null,
                          MailProvider provider = MailProvider.OTHER,
                          MobileConfigAccount? imported = null,
                          string initial_name = "", string initial_email = "") {
        this.provisioner = provisioner;
        this.existing = existing;
        this.provider = provider;
        if (imported != null)
            title = "Review Imported Mail Account";
        else if (existing != null)
            title = "Edit Mail Account";
        else
            title = provider_title (provider);
        content_width = 600; content_height = 470;
        var page = new Adw.PreferencesPage (); page.title = "Account"; page.icon_name = "avatar-default-symbolic";
        page.add_css_class ("account-dialog-page");
        var identity = new Adw.PreferencesGroup ();
        identity.add_css_class ("account-dialog-identity");
        identity.title = existing == null ? account_identity_title (provider) : "Account identity";
        string guidance = provider_guidance (provider);
        identity.description = guidance != "" ? guidance :
            "Enter the name people will see and the address you use for mail.";
        identity.add (display_name_row); identity.add (email);
        password.title = "Password or app-specific password"; password.show_apply_button = false;
        identity.add (password);

        var advanced = new Adw.PreferencesGroup ();
        advanced.add_css_class ("account-dialog-advanced");
        server_settings.title = "Server Settings";
        server_settings.subtitle = provider == MailProvider.OTHER ?
            "Standard secure settings are selected from your email address" :
            "Secure settings were selected automatically";
        server_settings.add_row (incoming_host); server_settings.add_row (incoming_user);
        server_settings.add_row (incoming_port); server_settings.add_row (incoming_security);
        server_settings.add_row (outgoing_host); server_settings.add_row (outgoing_user);
        server_settings.add_row (outgoing_port); server_settings.add_row (outgoing_security);
        outgoing_password.title = "Different outgoing password (optional)";
        server_settings.add_row (outgoing_password);
        server_settings.add_css_class ("account-server-settings");
        advanced.add (server_settings);

        var actions = new Adw.PreferencesGroup (); actions.title = "Connection";
        actions.add_css_class ("account-dialog-actions");
        status.add_css_class ("account-connection-status");
        status.add_prefix (new Gtk.Image.from_icon_name ("security-high-symbolic"));
        status.title = provisioner == null ? "Account connections are unavailable" : "Ready to connect";
        status.subtitle = provisioner == null ?
            "Install a Mailficient build with live account support." :
            "Your password is stored securely on this device after the connection succeeds.";
        status.accessible_role = Gtk.AccessibleRole.STATUS;
        validation.visible = false; validation.accessible_role = Gtk.AccessibleRole.ALERT;
        validation.add_css_class ("account-validation-message");
        validation.add_prefix (new Gtk.Image.from_icon_name ("dialog-warning-symbolic"));
        save.add_css_class ("suggested-action"); save.add_css_class ("account-primary-action");
        save.hexpand = true; save.halign = Gtk.Align.FILL; save.sensitive = provisioner != null;
        save.clicked.connect (() => save_account.begin ()); actions.add (status);
        actions.add (validation);
        var save_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        save_box.add_css_class ("account-primary-action-box"); save_box.append (save); actions.add (save_box);
        page.add (identity); page.add (advanced); page.add (actions); add (page);
        default_widget = save;
        email.changed.connect (apply_provider_defaults);
        display_name_row.text = initial_name;
        email.text = initial_email;
        if (existing != null) populate (existing);
        else if (imported != null) populate_import (imported);
        else if (provider != MailProvider.OTHER) {
            apply_preset (AccountSettings.for_provider (provider,
                display_name_row.text, email.text));
            applied_defaults = true;
            password.title = "App-specific password";
        }
        server_settings.expanded = existing != null || imported != null;
        connect_validation (display_name_row); connect_validation (email);
        connect_validation (incoming_host); connect_validation (incoming_user);
        connect_validation (incoming_port); connect_validation (outgoing_host);
        connect_validation (outgoing_user); connect_validation (outgoing_port);
        password.changed.connect (() => { clear_invalid (password); update_save_sensitivity (); });
        update_save_sensitivity ();
        Idle.add (() => {
            if (display_name_row.text.strip () == "") display_name_row.grab_focus ();
            else if (email.text.strip () == "") email.grab_focus ();
            else password.grab_focus ();
            return Source.REMOVE;
        });
        if (Environment.get_variable ("MAILFICIENT_QA_ACCOUNT_TLS_ERROR") == "1") {
            Idle.add (() => {
                show_connection_error (new MailError.TLS (
                    "The certificate presented by imap.example.net was rejected because it does not match the server name, it has expired."), true);
                return Source.REMOVE;
            });
        }
    }

    private void populate_import (MobileConfigAccount imported) {
        var account = imported.settings;
        display_name_row.text = account.display_name; email.text = account.email;
        apply_preset (account);
        password.text = imported.incoming_password;
        outgoing_password.text = imported.outgoing_password;
        status.title = "Imported settings ready to test";
        status.subtitle = imported.incoming_password == "" ?
            "Review the server settings and enter the account password." :
            "Review the server settings before connecting the imported account.";
        applied_defaults = true;
    }

    private void populate (AccountSettings account) {
        display_name_row.text = account.display_name; email.text = account.email;
        incoming_host.text = account.incoming_host; incoming_port.text = account.incoming_port.to_string ();
        incoming_user.text = account.incoming_username;
        incoming_security.selected = account.incoming_encryption == EncryptionMode.TLS ? 0 : 1;
        outgoing_host.text = account.outgoing_host; outgoing_port.text = account.outgoing_port.to_string ();
        outgoing_user.text = account.outgoing_username;
        outgoing_security.selected = account.outgoing_encryption == EncryptionMode.TLS ? 0 : 1;
        password.title = "New incoming password (leave blank to keep current)";
        outgoing_password.title = "New outgoing password (leave blank to keep current)";
        if (account.authentication == AuthenticationMode.GNOME_ONLINE_ACCOUNTS) {
            password.visible = false; outgoing_password.visible = false;
            status.subtitle = "Secure sign-in is managed by your computer.";
        }
        save.label = "Save Changes";
        applied_defaults = true;
    }

    private static Adw.EntryRow field (string title, string placeholder) {
        var row = new Adw.EntryRow (); row.title = title; row.text = "";
        row.input_hints = Gtk.InputHints.NO_EMOJI;
        row.update_property (Gtk.AccessibleProperty.PLACEHOLDER, placeholder, -1);
        if (title.down ().contains ("email") || title.down ().contains ("username"))
            row.input_purpose = Gtk.InputPurpose.EMAIL;
        else if (title.down ().contains ("port")) row.input_purpose = Gtk.InputPurpose.DIGITS;
        return row;
    }

    private static Adw.ComboRow security_row () {
        var choices = new Gtk.StringList (null); choices.append ("TLS"); choices.append ("STARTTLS");
        var row = new Adw.ComboRow (); row.title = "Encryption"; row.model = choices; return row;
    }

    private void apply_provider_defaults () {
        if (!RecipientParser.is_valid_address (email.text)) return;
        var preset = provider == MailProvider.OTHER ?
            AccountSettings.for_email (display_name_row.text, email.text) :
            AccountSettings.for_provider (provider, display_name_row.text, email.text);
        if (provider == MailProvider.OTHER && preset.incoming_host == "") {
            string address = email.text.strip ();
            int separator = address.last_index_of_char ('@');
            if (separator > 0 && separator + 1 < address.length) {
                string domain = address.substring (separator + 1).down ();
                preset.incoming_host = "imap." + domain;
                preset.incoming_port = 993;
                preset.incoming_encryption = EncryptionMode.TLS;
                preset.outgoing_host = "smtp." + domain;
                preset.outgoing_port = 587;
                preset.outgoing_encryption = EncryptionMode.STARTTLS;
                preset.incoming_username = address;
                preset.outgoing_username = address;
            }
        }
        if (preset.incoming_host == "") return;
        if (provider == MailProvider.OTHER && applied_defaults && server_settings.expanded) return;
        apply_preset (preset);
        applied_defaults = true;
    }

    private void apply_preset (AccountSettings preset) {
        incoming_host.text = preset.incoming_host; incoming_port.text = preset.incoming_port.to_string ();
        outgoing_host.text = preset.outgoing_host; outgoing_port.text = preset.outgoing_port.to_string ();
        incoming_user.text = preset.incoming_username;
        outgoing_user.text = preset.outgoing_username;
        incoming_security.selected = preset.incoming_encryption == EncryptionMode.TLS ? 0 : 1;
        outgoing_security.selected = preset.outgoing_encryption == EncryptionMode.TLS ? 0 : 1;
    }

    private static string provider_title (MailProvider provider) {
        switch (provider) {
        case MailProvider.ICLOUD: return "Add iCloud Account";
        case MailProvider.YAHOO: return "Add Yahoo Account";
        case MailProvider.AOL: return "Add AOL Account";
        default: return "Add Mail Account";
        }
    }

    private static string account_identity_title (MailProvider provider) {
        switch (provider) {
        case MailProvider.ICLOUD: return "Sign in to iCloud";
        case MailProvider.YAHOO: return "Sign in to Yahoo";
        case MailProvider.AOL: return "Sign in to AOL";
        default: return "Account details";
        }
    }

    private static string provider_guidance (MailProvider provider) {
        switch (provider) {
        case MailProvider.ICLOUD:
            return "Generate an app-specific password in your Apple Account, then enter it below.";
        case MailProvider.YAHOO:
            return "Generate a third-party app password in Yahoo Account Security, then enter it below.";
        case MailProvider.AOL:
            return "If AOL rejects your regular password, generate an app password in AOL Account Security.";
        default:
            return "";
        }
    }

    private AccountSettings settings_from_form () throws MailError {
        var account = new AccountSettings ();
        if (existing != null) account.id = existing.id;
        account.display_name = display_name_row.text.strip (); account.email = email.text.strip ();
        uint incoming_value = 0; uint outgoing_value = 0;
        if (!uint.try_parse (incoming_port.text.strip (), out incoming_value) ||
            !uint.try_parse (outgoing_port.text.strip (), out outgoing_value))
            throw new MailError.INVALID_ACCOUNT ("Enter valid numeric server ports");
        account.incoming_host = incoming_host.text.strip (); account.incoming_port = incoming_value; account.incoming_username = incoming_user.text.strip ();
        account.incoming_encryption = incoming_security.selected == 0 ? EncryptionMode.TLS : EncryptionMode.STARTTLS;
        account.outgoing_host = outgoing_host.text.strip (); account.outgoing_port = outgoing_value; account.outgoing_username = outgoing_user.text.strip ();
        account.outgoing_encryption = outgoing_security.selected == 0 ? EncryptionMode.TLS : EncryptionMode.STARTTLS;
        if (existing != null) {
            account.authentication = existing.authentication;
            account.online_account_path = existing.online_account_path;
        }
        return account;
    }

    private async void save_account () {
        if (provisioner == null || connecting) return;
        if (!validate_form ()) return;
        connecting = true;
        save.sensitive = false; save.label = "Connecting…"; status.title = "Connecting securely…";
        status.subtitle = "Checking the incoming and outgoing mail connection.";
        status.update_state (Gtk.AccessibleState.BUSY, true, -1);
        try {
            var account = settings_from_form ();
            yield provisioner.provision (account, password.text, outgoing_password.text, existing);
            password.text = ""; outgoing_password.text = "";
            status.title = "Account connected"; status.subtitle = "%s is ready to synchronize.".printf (account.email);
            account_saved (account); close ();
        } catch (Error error) {
            show_connection_error (error, true);
            save.label = "Try Again"; save.sensitive = true;
        } finally {
            connecting = false;
            status.update_state (Gtk.AccessibleState.BUSY, false, -1);
        }
    }

    private void show_connection_error (Error error, bool present_details = false) {
        var friendly = UserFacingError.from_error (error);
        server_settings.expanded = true;
        status.title = friendly.title;
        status.subtitle = "%s %s".printf (friendly.description, friendly.suggestion);
        status.subtitle_lines = 2;
        status.accessible_role = Gtk.AccessibleRole.ALERT;
        if (error is MailError.AUTHENTICATION && password.visible) {
            mark_invalid (password, "The password was not accepted.", true);
        } else if (error is MailError.INVALID_ACCOUNT) {
            validation.title = friendly.description;
            validation.subtitle = "Review the marked field and try again.";
            validation.visible = true;
        }
        if (!present_details || !(error is MailError.TLS)) return;

        var warning = new Adw.AlertDialog (friendly.title,
            "%s\n\n%s".printf (friendly.description, friendly.suggestion));
        warning.content_width = 500;
        if (friendly.technical_detail != "") {
            var details = new Gtk.Expander ("Certificate Details");
            details.expanded = true;
            var detail = new Gtk.Label (friendly.technical_detail);
            detail.wrap = true; detail.selectable = true; detail.max_width_chars = 58;
            detail.set_margin_top (8); detail.set_margin_bottom (12);
            details.child = detail; warning.extra_child = details;
        }
        warning.add_response ("review", "Review Settings");
        warning.default_response = "review"; warning.close_response = "review";
        warning.present (this);
    }

    private void connect_validation (Adw.EntryRow row) {
        row.changed.connect (() => { clear_invalid (row); update_save_sensitivity (); });
        row.entry_activated.connect (() => { if (save.sensitive) save_account.begin (); });
    }

    private void update_save_sensitivity () {
        if (provisioner == null) { save.sensitive = false; return; }
        bool identity_ready = display_name_row.text.strip () != "" &&
            RecipientParser.is_valid_address (email.text.strip ());
        bool password_ready = existing != null || !password.visible || password.text != "";
        bool servers_ready = incoming_host.text.strip () != "" && incoming_user.text.strip () != "" &&
            outgoing_host.text.strip () != "" && outgoing_user.text.strip () != "";
        uint incoming_value = 0; uint outgoing_value = 0;
        bool ports_ready = uint.try_parse (incoming_port.text.strip (), out incoming_value) &&
            incoming_value > 0 && incoming_value <= 65535 &&
            uint.try_parse (outgoing_port.text.strip (), out outgoing_value) &&
            outgoing_value > 0 && outgoing_value <= 65535;
        save.sensitive = identity_ready && password_ready && servers_ready && ports_ready;
        if (connecting) return;
        status.accessible_role = Gtk.AccessibleRole.STATUS;
        if (!identity_ready) {
            status.title = "Complete your account details";
            status.subtitle = "Enter your name and a complete email address.";
        } else if (!password_ready) {
            status.title = "Enter your password";
            status.subtitle = "Use an app-specific password when your provider requires one.";
        } else if (!servers_ready || !ports_ready) {
            status.title = "Review server settings";
            status.subtitle = "Open Server Settings and complete the connection details.";
        } else {
            status.title = existing == null ? "Ready to connect" : "Ready to save";
            status.subtitle = "Your password is stored securely only after the connection succeeds.";
        }
    }

    private bool validate_form () {
        validation.visible = false;
        if (display_name_row.text.strip () == "")
            return mark_invalid (display_name_row, "Enter the name recipients should see.", true);
        if (!RecipientParser.is_valid_address (email.text.strip ()))
            return mark_invalid (email, "Enter a complete email address, such as name@example.com.", true);
        if (incoming_host.text.strip () == "" || incoming_host.text.contains (" ") ||
            !incoming_host.text.contains (".")) {
            server_settings.expanded = true;
            return mark_invalid (incoming_host, "Enter a valid incoming server address.", true);
        }
        if (incoming_user.text.strip () == "") {
            server_settings.expanded = true;
            return mark_invalid (incoming_user, "Enter the incoming mail username.", true);
        }
        uint incoming_value;
        if (!uint.try_parse (incoming_port.text.strip (), out incoming_value) ||
            incoming_value == 0 || incoming_value > 65535) {
            server_settings.expanded = true;
            return mark_invalid (incoming_port, "Enter an incoming port between 1 and 65535.", true);
        }
        if (outgoing_host.text.strip () == "" || outgoing_host.text.contains (" ") ||
            !outgoing_host.text.contains (".")) {
            server_settings.expanded = true;
            return mark_invalid (outgoing_host, "Enter a valid outgoing server address.", true);
        }
        if (outgoing_user.text.strip () == "") {
            server_settings.expanded = true;
            return mark_invalid (outgoing_user, "Enter the outgoing mail username.", true);
        }
        uint outgoing_value;
        if (!uint.try_parse (outgoing_port.text.strip (), out outgoing_value) ||
            outgoing_value == 0 || outgoing_value > 65535) {
            server_settings.expanded = true;
            return mark_invalid (outgoing_port, "Enter an outgoing port between 1 and 65535.", true);
        }
        if (existing == null && password.visible && password.text == "")
            return mark_invalid (password, "Enter your password or app-specific password.", true);
        return true;
    }

    private bool mark_invalid (Gtk.Widget field, string message, bool focus) {
        field.add_css_class ("account-field-error");
        var accessible = field as Gtk.Accessible;
        if (accessible != null) {
            accessible.update_state (Gtk.AccessibleState.INVALID, true, -1);
            accessible.update_property (Gtk.AccessibleProperty.DESCRIPTION, message, -1);
        }
        validation.title = "Check your account details";
        validation.subtitle = message;
        validation.visible = true;
        if (focus) field.grab_focus ();
        return false;
    }

    private void clear_invalid (Gtk.Widget field) {
        field.remove_css_class ("account-field-error");
        var accessible = field as Gtk.Accessible;
        if (accessible != null) accessible.reset_state (Gtk.AccessibleState.INVALID);
        validation.visible = false;
    }
}

// The shared entry point for first run and Settings. It asks for only the two
// facts needed to identify the provider, then opens the appropriate secure
// sign-in or password sheet. Manual server fields stay one level deeper.
public class AccountSetupDialog : Adw.PreferencesDialog {
    public signal void account_saved (AccountSettings account);
    public signal void import_requested ();

    private CacheDatabase cache;
    private AccountProvisioningService? provisioner;
    private OnlineAccountService online_accounts;
    private Adw.EntryRow display_name = new Adw.EntryRow ();
    private Adw.EntryRow email = new Adw.EntryRow ();
    private Adw.ActionRow provider_hint = new Adw.ActionRow ();
    private Adw.ActionRow action_status = new Adw.ActionRow ();
    private Gtk.Button continue_button = new Gtk.Button.with_label ("Continue");

    public AccountSetupDialog (CacheDatabase cache, AccountProvisioningService? provisioner,
                               OnlineAccountService online_accounts) {
        this.cache = cache; this.provisioner = provisioner; this.online_accounts = online_accounts;
        // Leave enough room for the secondary setup choices below the primary
        // action. PreferencesDialog clamps to its parent and scrolls the page
        // on shorter displays, so every action remains reachable.
        title = "Add Mail Account"; content_width = 580; content_height = 560;
        var page = new Adw.PreferencesPage (); page.title = "Add Account";
        page.icon_name = "mail-unread-symbolic";
        page.add_css_class ("account-setup-page");

        var setup_intro_group = new Adw.PreferencesGroup ();
        var setup_intro = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 16);
        setup_intro.add_css_class ("account-setup-intro");
        var intro_badge = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        intro_badge.add_css_class ("account-setup-intro-badge");
        intro_badge.valign = Gtk.Align.CENTER;
        var intro_icon = new Gtk.Image.from_icon_name ("mail-unread-symbolic");
        intro_icon.pixel_size = 28; intro_icon.halign = Gtk.Align.CENTER;
        intro_icon.valign = Gtk.Align.CENTER; intro_badge.append (intro_icon);
        setup_intro.append (intro_badge);
        var intro_copy = new Gtk.Box (Gtk.Orientation.VERTICAL, 3); intro_copy.hexpand = true;
        var intro_title = new Gtk.Label ("Start with the essentials");
        intro_title.xalign = 0; intro_title.wrap = true; intro_title.add_css_class ("account-setup-intro-title");
        var intro_description = new Gtk.Label (
            "Enter the name recipients should see and your email address. We’ll handle the connection details.");
        intro_description.xalign = 0; intro_description.wrap = true;
        intro_description.add_css_class ("account-setup-intro-description");
        intro_copy.append (intro_title); intro_copy.append (intro_description);
        setup_intro.append (intro_copy); setup_intro_group.add (setup_intro); page.add (setup_intro_group);

        var intro = new Adw.PreferencesGroup ();
        intro.add_css_class ("account-setup-card");
        intro.title = "Account details";
        intro.description = "Your provider is detected securely from the address—no guesswork required.";
        display_name.title = "Name"; display_name.update_property (
            Gtk.AccessibleProperty.PLACEHOLDER, "The name recipients will see", -1);
        display_name.add_css_class ("account-setup-field");
        email.title = "Email address"; email.input_purpose = Gtk.InputPurpose.EMAIL;
        email.add_css_class ("account-setup-field");
        email.update_property (Gtk.AccessibleProperty.PLACEHOLDER, "name@example.com", -1);
        intro.add (display_name); intro.add (email);
        provider_hint.visible = false; provider_hint.accessible_role = Gtk.AccessibleRole.STATUS;
        provider_hint.add_css_class ("account-provider-hint");
        provider_hint.add_prefix (new Gtk.Image.from_icon_name ("emblem-ok-symbolic"));
        intro.add (provider_hint); page.add (intro);

        var actions = new Adw.PreferencesGroup ();
        actions.add_css_class ("account-setup-actions");
        action_status.add_css_class ("account-setup-status");
        action_status.add_prefix (new Gtk.Image.from_icon_name ("dialog-information-symbolic"));
        action_status.title = provisioner == null ? "Account connections are unavailable" : "Enter your account details";
        action_status.subtitle = provisioner == null ?
            "Install a Mailficient build with live account support." :
            "Your account isn’t changed until the connection succeeds.";
        if (provisioner == null) action_status.accessible_role = Gtk.AccessibleRole.ALERT;
        continue_button.add_css_class ("suggested-action");
        continue_button.add_css_class ("account-primary-action");
        continue_button.hexpand = true; continue_button.halign = Gtk.Align.FILL;
        continue_button.clicked.connect (continue_setup); actions.add (action_status);
        var primary_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        primary_box.add_css_class ("account-primary-action-box");
        primary_box.append (continue_button); actions.add (primary_box);
        var alternatives_label = new Gtk.Label ("Other setup options");
        alternatives_label.add_css_class ("account-setup-alternatives-label");
        alternatives_label.halign = Gtk.Align.CENTER; actions.add (alternatives_label);
        var alternatives = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8); alternatives.halign = Gtk.Align.CENTER;
        alternatives.add_css_class ("account-setup-alternatives");
        var choose = new Gtk.Button.with_label ("Choose a provider"); choose.add_css_class ("flat");
        choose.clicked.connect (choose_provider);
        var import = new Gtk.Button.with_label ("Import a configuration"); import.add_css_class ("flat");
        import.clicked.connect (() => { import_requested (); close (); });
        alternatives.append (choose); alternatives.append (import); actions.add (alternatives);
        page.add (actions); add (page);
        default_widget = continue_button;

        display_name.changed.connect (update_continue_state);
        email.changed.connect (update_continue_state);
        email.entry_activated.connect (() => { if (continue_button.sensitive) continue_setup (); });
        update_continue_state ();
        Idle.add (() => { display_name.grab_focus (); return Source.REMOVE; });
    }

    private void update_continue_state () {
        string address = email.text.strip ();
        continue_button.label = "Continue";
        continue_button.sensitive = provisioner != null && display_name.text.strip () != "" &&
            RecipientParser.is_valid_address (address);
        if (provisioner != null) {
            if (display_name.text.strip () == "") {
                action_status.title = "Enter your name";
                action_status.subtitle = "This is the name recipients will see.";
            } else if (address == "") {
                action_status.title = "Enter your email address";
                action_status.subtitle = "Mailficient uses it to find your provider.";
            } else if (!RecipientParser.is_valid_address (address)) {
                action_status.title = "Check your email address";
                action_status.subtitle = "Enter a complete address, such as name@example.com.";
            } else {
                action_status.title = "Ready to continue";
                action_status.subtitle = "Your account isn’t changed until the connection succeeds.";
            }
        }
        if (address == "") { provider_hint.visible = false; return; }
        if (!RecipientParser.is_valid_address (address)) {
            provider_hint.title = "Keep typing your complete email address";
            provider_hint.subtitle = "For example, name@example.com";
            provider_hint.visible = true; return;
        }
        MailProvider provider = provider_for_email (address);
        continue_button.label = provider == MailProvider.GOOGLE ? "Continue with Google" :
            (provider == MailProvider.MICROSOFT ? "Continue with Microsoft" : "Continue");
        provider_hint.title = provider_name (provider);
        provider_hint.subtitle = provider == MailProvider.GOOGLE || provider == MailProvider.MICROSOFT ?
            "You’ll continue with secure sign-in." :
            (provider == MailProvider.OTHER ? "Standard secure settings will be tried automatically." :
             "Secure server settings will be filled in automatically.");
        provider_hint.visible = true;
    }

    private void continue_setup () {
        if (!continue_button.sensitive) return;
        open_provider (provider_for_email (email.text), display_name.text.strip (), email.text.strip ());
    }

    private void choose_provider () {
        var chooser = new ProviderChooserDialog ();
        chooser.provider_selected.connect ((provider) =>
            open_provider (provider, display_name.text.strip (), email.text.strip ()));
        chooser.present (this);
    }

    private void open_provider (MailProvider provider, string name, string address) {
        if (provider == MailProvider.GOOGLE || provider == MailProvider.MICROSOFT) {
            var online = new OnlineAccountDialog (cache, provisioner, online_accounts, provider, address);
            online.account_saved.connect (complete);
            online.present (this); return;
        }
        var manual = new AccountDialog (provisioner, null, provider, null, name, address);
        manual.account_saved.connect (complete);
        manual.present (this);
    }

    private void complete (AccountSettings account) {
        account_saved (account); close ();
    }

    private static MailProvider provider_for_email (string address) {
        int separator = address.last_index_of_char ('@');
        string domain = separator < 0 ? "" : address.substring (separator + 1).down ();
        if (domain == "gmail.com" || domain == "googlemail.com") return MailProvider.GOOGLE;
        if (domain == "outlook.com" || domain == "hotmail.com" || domain == "live.com" ||
            domain == "msn.com") return MailProvider.MICROSOFT;
        if (domain == "icloud.com" || domain == "me.com" || domain == "mac.com")
            return MailProvider.ICLOUD;
        if (domain == "yahoo.com" || domain == "ymail.com" || domain == "rocketmail.com")
            return MailProvider.YAHOO;
        if (domain == "aol.com") return MailProvider.AOL;
        return MailProvider.OTHER;
    }

    private static string provider_name (MailProvider provider) {
        switch (provider) {
        case MailProvider.GOOGLE: return "Google account found";
        case MailProvider.MICROSOFT: return "Microsoft account found";
        case MailProvider.ICLOUD: return "iCloud account found";
        case MailProvider.YAHOO: return "Yahoo account found";
        case MailProvider.AOL: return "AOL account found";
        default: return "Standard mail account";
        }
    }
}
}
