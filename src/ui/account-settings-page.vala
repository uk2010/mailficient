namespace Mailficient {
public class AccountSettingsPage : Adw.PreferencesPage {
    public signal void account_saved (AccountSettings account);
    public signal void accounts_changed ();

    private CacheDatabase cache;
    private CredentialCleanupService credential_cleanup;
    private AccountProvisioningService? account_provisioner;
    private MailEngine? engine;
    private AccountSyncService? sync_service;
    private OnlineAccountService online_accounts;
    private Adw.PreferencesGroup accounts_group = new Adw.PreferencesGroup ();
    private Adw.ActionRow status = new Adw.ActionRow ();
    private Gee.ArrayList<Gtk.Widget> account_rows = new Gee.ArrayList<Gtk.Widget> ();

    public AccountSettingsPage (CacheDatabase cache,
                                CredentialCleanupService credential_cleanup,
                                AccountProvisioningService? account_provisioner,
                                MailEngine? engine,
                                AccountSyncService? sync_service,
                                OnlineAccountService online_accounts) {
        this.cache = cache;
        this.credential_cleanup = credential_cleanup;
        this.account_provisioner = account_provisioner;
        this.engine = engine;
        this.sync_service = sync_service;
        this.online_accounts = online_accounts;
        name = "accounts";
        title = "Accounts";
        icon_name = "avatar-default-symbolic";

        accounts_group.title = "Mail Accounts";
        accounts_group.description = "Manage connected accounts, authentication, and server settings.";
        add (accounts_group);

        var add_group = new Adw.PreferencesGroup ();
        add_group.title = "Add an Account";
        var add_row = new Adw.ActionRow ();
        add_row.title = "Standard Mail Account";
        add_row.subtitle = "Connect an IMAP and SMTP account";
        add_row.add_prefix (new Gtk.Image.from_icon_name ("list-add-symbolic"));
        add_row.activatable = true;
        add_row.activated.connect (open_add_dialog);
        var add_button = new Gtk.Button.with_label ("Add Account");
        add_button.valign = Gtk.Align.CENTER;
        add_button.add_css_class ("suggested-action");
        add_button.clicked.connect (open_add_dialog);
        add_row.add_suffix (add_button);
        add_group.add (add_row);

        var online_row = new Adw.ActionRow ();
        online_row.title = "GNOME Online Account";
        online_row.subtitle = "Use an existing Google or Microsoft OAuth authorization";
        online_row.add_prefix (new Gtk.Image.from_icon_name ("network-server-symbolic"));
        online_row.activatable = true;
        online_row.activated.connect (open_online_dialog);
        var online_button = new Gtk.Button.with_label ("Choose Account");
        online_button.valign = Gtk.Align.CENTER;
        online_button.clicked.connect (open_online_dialog);
        online_row.add_suffix (online_button);
        add_group.add (online_row);

        status.add_prefix (new Gtk.Image.from_icon_name ("dialog-warning-symbolic"));
        status.visible = false;
        add_group.add (status);
        add (add_group);
        reload ();
    }

    private void reload () {
        foreach (var row in account_rows) accounts_group.remove (row);
        account_rows.clear ();
        try {
            var accounts = cache.list_accounts ();
            if (accounts.size == 0) {
                var empty = new Adw.ActionRow ();
                empty.title = "No connected accounts";
                empty.subtitle = "Add a standard mail account or choose a GNOME Online Account.";
                empty.add_prefix (new Gtk.Image.from_icon_name ("mail-unread-symbolic"));
                accounts_group.add (empty);
                account_rows.add (empty);
                return;
            }
            foreach (var account in accounts) {
                var row = account_row (account);
                accounts_group.add (row);
                account_rows.add (row);
            }
        } catch (Error error) {
            show_error (UserFacingError.from_error (error));
        }
    }

    private Adw.ActionRow account_row (AccountSettings account) {
        var row = new Adw.ActionRow ();
        row.title = account.display_name;
        string authentication = account.authentication == AuthenticationMode.GNOME_ONLINE_ACCOUNTS ?
            "GNOME Online Accounts OAuth" : "Password / app password";
        row.subtitle = "%s\n%s · IMAP %s · SMTP %s".printf (
            account.email, authentication, account.incoming_host, account.outgoing_host);
        row.subtitle_lines = 2;
        row.add_prefix (new Gtk.Image.from_icon_name ("avatar-default-symbolic"));
        var edit = new Gtk.Button.from_icon_name ("document-edit-symbolic");
        edit.valign = Gtk.Align.CENTER;
        edit.add_css_class ("flat");
        edit.tooltip_text = "Edit account";
        Accessibility.label (edit, "Edit %s".printf (account.display_name));
        edit.clicked.connect (() => open_edit_dialog (account));
        row.add_suffix (edit);
        var remove = new Gtk.Button.from_icon_name ("user-trash-symbolic");
        remove.valign = Gtk.Align.CENTER;
        remove.add_css_class ("flat");
        remove.tooltip_text = "Remove account";
        Accessibility.label (remove, "Remove %s".printf (account.display_name));
        remove.clicked.connect (() => remove_account.begin (account));
        row.add_suffix (remove);
        return row;
    }

    private void open_add_dialog () {
        var dialog = new AccountDialog (account_provisioner);
        dialog.account_saved.connect ((account) => {
            reload ();
            account_saved (account);
        });
        dialog.present (this);
    }

    private void open_edit_dialog (AccountSettings account) {
        var dialog = new AccountDialog (account_provisioner, account);
        dialog.account_saved.connect ((saved) => {
            reload ();
            account_saved (saved);
        });
        dialog.present (this);
    }

    private void open_online_dialog () {
        var dialog = new OnlineAccountDialog (cache, account_provisioner, online_accounts);
        dialog.account_saved.connect ((account) => {
            reload ();
            account_saved (account);
        });
        dialog.present (this);
    }

    private async void remove_account (AccountSettings account) {
        var confirmation = new Adw.AlertDialog (
            "Remove %s?".printf (account.display_name),
            "This removes cached messages, pending changes, unsent drafts, and stored credentials from this device. Messages on the server are not deleted.");
        confirmation.add_response ("cancel", "Cancel");
        confirmation.add_response ("remove", "Remove Account");
        confirmation.default_response = "cancel";
        confirmation.close_response = "cancel";
        confirmation.set_response_appearance ("remove", Adw.ResponseAppearance.DESTRUCTIVE);
        if ((yield confirmation.choose (this, null)) != "remove") return;
        if (sync_service != null) sync_service.suppress_account (account.id);
        try {
            if (engine != null) {
                try { yield engine.disconnect_account (account.id); }
                catch (Error disconnect_error) {
                    debug ("Account session did not disconnect cleanly: %s", disconnect_error.message);
                }
            }
            cache.delete_account (account.id);
            status.visible = false;
            reload ();
            accounts_changed ();
            if (!(yield credential_cleanup.cleanup_account (account.id))) {
                status.title = "Account removed";
                status.subtitle = "Secure credential cleanup will retry automatically.";
                status.visible = true;
            }
        } catch (Error error) {
            if (sync_service != null) sync_service.resume_account (account.id);
            show_error (UserFacingError.from_error (error));
        }
    }

    private void show_error (UserFacingError error) {
        status.title = error.title;
        status.subtitle = "%s %s".printf (error.description, error.suggestion);
        status.visible = true;
    }
}
}
