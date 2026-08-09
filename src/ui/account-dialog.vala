namespace Mailficient {
public class AccountDialog : Adw.PreferencesDialog {
    public signal void account_saved (AccountSettings account);

    private AccountProvisioningService? provisioner;
    private Adw.EntryRow display_name_row = field ("Name", "Your display name");
    private Adw.EntryRow email = field ("Email", "you@example.com");
    private Adw.EntryRow incoming_host = field ("Server", "imap.example.com");
    private Adw.EntryRow incoming_user = field ("Username", "you@example.com");
    private Adw.EntryRow incoming_port = field ("Port", "993");
    private Adw.ComboRow incoming_security = security_row ();
    private Adw.EntryRow outgoing_host = field ("Server", "smtp.example.com");
    private Adw.EntryRow outgoing_user = field ("Username", "you@example.com");
    private Adw.EntryRow outgoing_port = field ("Port", "465");
    private Adw.ComboRow outgoing_security = security_row ();
    private Adw.ComboRow authentication = authentication_row ();
    private Adw.PasswordEntryRow password = new Adw.PasswordEntryRow ();
    private Adw.PasswordEntryRow outgoing_password = new Adw.PasswordEntryRow ();
    private Adw.ActionRow status = new Adw.ActionRow ();
    private Gtk.Button save = new Gtk.Button.with_label ("Test and Add Account");
    private bool applied_defaults;
    private AccountSettings? existing;
    private MailProvider provider;

    public AccountDialog (AccountProvisioningService? provisioner, AccountSettings? existing = null,
                          MailProvider provider = MailProvider.OTHER,
                          MobileConfigAccount? imported = null) {
        this.provisioner = provisioner;
        this.existing = existing;
        this.provider = provider;
        title = imported != null ? "Review Imported Mail Account" :
            (existing == null ? provider_title (provider) : "Edit Mail Account");
        content_width = 680; content_height = 760;
        var page = new Adw.PreferencesPage (); page.title = "Account"; page.icon_name = "avatar-default-symbolic";
        var identity = new Adw.PreferencesGroup (); identity.title = "Identity";
        string guidance = provider_guidance (provider);
        if (existing == null && guidance != "") identity.description = guidance;
        identity.add (display_name_row); identity.add (email);
        var incoming = new Adw.PreferencesGroup (); incoming.title = "Incoming Mail (IMAP)";
        incoming.add (incoming_host); incoming.add (incoming_user); incoming.add (incoming_port); incoming.add (incoming_security); incoming.add (authentication);
        password.title = "Password or app password"; password.show_apply_button = false; incoming.add (password);
        var outgoing = new Adw.PreferencesGroup (); outgoing.title = "Outgoing Mail (SMTP)";
        outgoing.add (outgoing_host); outgoing.add (outgoing_user); outgoing.add (outgoing_port); outgoing.add (outgoing_security);
        outgoing_password.title = "Outgoing password (optional)"; outgoing.add (outgoing_password);
        var actions = new Adw.PreferencesGroup (); actions.title = "Connection";
        status.title = provisioner == null ? "Live account support is unavailable in this build" : "Ready to test secure connections";
        status.subtitle = provisioner == null ? "Install Evolution Data Server development support or use the Flatpak build." : "Credentials are stored only in Secret Service after validation.";
        save.add_css_class ("suggested-action"); save.valign = Gtk.Align.CENTER; save.sensitive = provisioner != null; save.clicked.connect (() => save_account.begin ()); status.add_suffix (save); actions.add (status);
        page.add (identity); page.add (incoming); page.add (outgoing); page.add (actions); add (page);
        email.changed.connect (apply_provider_defaults);
        if (existing != null) populate (existing);
        else if (imported != null) populate_import (imported);
        else if (provider != MailProvider.OTHER) {
            apply_preset (AccountSettings.for_provider (provider, "", ""));
            applied_defaults = true;
            password.title = "App-specific password";
        }
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
            authentication.selected = 1; password.visible = false; outgoing_password.visible = false;
            status.subtitle = "OAuth authorization is provided by GNOME Online Accounts.";
        }
        save.label = "Test and Save Changes";
        applied_defaults = true;
    }

    private static Adw.EntryRow field (string title, string placeholder) {
        var row = new Adw.EntryRow (); row.title = title; row.text = ""; row.input_hints = Gtk.InputHints.NO_EMOJI; return row;
    }

    private static Adw.ComboRow security_row () {
        var choices = new Gtk.StringList (null); choices.append ("TLS"); choices.append ("STARTTLS");
        var row = new Adw.ComboRow (); row.title = "Encryption"; row.model = choices; return row;
    }

    private static Adw.ComboRow authentication_row () {
        var choices = new Gtk.StringList (null); choices.append ("Password / app password");
        choices.append ("GNOME Online Accounts (OAuth)");
        var row = new Adw.ComboRow (); row.title = "Authentication"; row.model = choices;
        row.sensitive = false;
        return row;
    }

    private void apply_provider_defaults () {
        if (!RecipientParser.is_valid_address (email.text)) return;
        var preset = provider == MailProvider.OTHER ?
            AccountSettings.for_email (display_name_row.text, email.text) :
            AccountSettings.for_provider (provider, display_name_row.text, email.text);
        if (preset.incoming_host == "") return;
        if (provider == MailProvider.OTHER && applied_defaults) return;
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
        if (provisioner == null) return;
        save.sensitive = false; save.label = "Testing…"; status.title = "Connecting securely…"; status.subtitle = "Checking IMAP and SMTP settings.";
        try {
            var account = settings_from_form ();
            yield provisioner.provision (account, password.text, outgoing_password.text, existing);
            password.text = ""; outgoing_password.text = "";
            status.title = "Account connected"; status.subtitle = "%s is ready to synchronize.".printf (account.email);
            account_saved (account); close ();
        } catch (Error error) {
            show_connection_error (error, true);
            save.label = "Try Again"; save.sensitive = true;
        }
    }

    private void show_connection_error (Error error, bool present_details = false) {
        var friendly = UserFacingError.from_error (error);
        status.title = friendly.title;
        status.subtitle = "%s %s".printf (friendly.description, friendly.suggestion);
        status.subtitle_lines = 2;
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
}
}
