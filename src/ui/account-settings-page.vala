namespace Mailficient {
public class AccountSettingsPage : Adw.PreferencesPage {
    public signal void account_saved (AccountSettings account);
    public signal void accounts_changed ();

    private CacheDatabase cache;
    private MailSettingsStore settings;
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
        this.settings = new MailSettingsStore (cache);
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
        var icloud_row = new Adw.ActionRow ();
        icloud_row.title = "iCloud Mail";
        icloud_row.subtitle = "Connect using your Apple Account email and an app-specific password";
        icloud_row.add_prefix (new Gtk.Image.from_icon_name ("folder-remote-symbolic"));
        icloud_row.activatable = true;
        icloud_row.activated.connect (open_icloud_dialog);
        var icloud_button = new Gtk.Button.with_label ("Add iCloud");
        icloud_button.valign = Gtk.Align.CENTER;
        icloud_button.add_css_class ("suggested-action");
        icloud_button.clicked.connect (open_icloud_dialog);
        icloud_row.add_suffix (icloud_button);
        add_group.add (icloud_row);

        var add_row = new Adw.ActionRow ();
        add_row.title = "Other Mail Provider";
        add_row.subtitle = "Google, Microsoft, Yahoo, AOL, or custom IMAP/SMTP";
        add_row.add_prefix (new Gtk.Image.from_icon_name ("list-add-symbolic"));
        add_row.activatable = true;
        add_row.activated.connect (open_add_dialog);
        var add_button = new Gtk.Button.with_label ("Choose Provider");
        add_button.valign = Gtk.Align.CENTER;
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

        var profile_row = new Adw.ActionRow ();
        profile_row.title = "Import Apple Configuration Profile";
        profile_row.subtitle = "Use mail settings from a downloaded .mobileconfig file";
        profile_row.add_prefix (new Gtk.Image.from_icon_name ("document-open-symbolic"));
        profile_row.activatable = true;
        profile_row.activated.connect (() => import_profile.begin ());
        var profile_button = new Gtk.Button.with_label ("Import Profile");
        profile_button.valign = Gtk.Align.CENTER;
        profile_button.clicked.connect (() => import_profile.begin ());
        profile_row.add_suffix (profile_button);
        add_group.add (profile_row);

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
        var dialog = new ProviderChooserDialog ();
        dialog.provider_selected.connect (open_provider);
        dialog.present (this);
    }

    private void open_icloud_dialog () {
        open_provider (MailProvider.ICLOUD);
    }

    private void open_provider (MailProvider provider) {
        if (provider == MailProvider.GOOGLE || provider == MailProvider.MICROSOFT) {
            var online = new OnlineAccountDialog (cache, account_provisioner, online_accounts, provider);
            online.account_saved.connect ((account) => {
                reload ();
                account_saved (account);
            });
            online.present ((Gtk.Widget) get_root ());
            return;
        }
        var manual = new AccountDialog (account_provisioner, null, provider);
        manual.account_saved.connect ((account) => {
            reload ();
            account_saved (account);
        });
        manual.present ((Gtk.Widget) get_root ());
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

    private async void import_profile () {
        var dialog = new Gtk.FileDialog ();
        dialog.title = "Import Apple Mail Configuration";
        dialog.accept_label = "Import";
        var filter = new Gtk.FileFilter ();
        filter.name = "Apple configuration profiles";
        filter.add_pattern ("*.mobileconfig");
        var filters = new ListStore (typeof (Gtk.FileFilter));
        filters.append (filter);
        dialog.filters = filters;
        dialog.default_filter = filter;
        dialog.initial_folder = settings.file_dialog_initial_folder ();
        try {
            var root_window = get_root () as Gtk.Window;
            if (root_window == null) return;
            var file = yield dialog.open (root_window, null);
            settings.remember_file_dialog_selection (file);
            var info = yield file.query_info_async (
                FileAttribute.STANDARD_SIZE + "," + FileAttribute.STANDARD_TYPE,
                FileQueryInfoFlags.NOFOLLOW_SYMLINKS, Priority.DEFAULT, null);
            if (info.get_file_type () != FileType.REGULAR)
                throw new MailError.INVALID_ACCOUNT ("Choose a regular .mobileconfig file");
            if ((int64) info.get_size () > MobileConfigImporter.MAX_PROFILE_BYTES)
                throw new MailError.INVALID_ACCOUNT ("Configuration profiles are limited to 5 MB");
            uint8[] contents; string etag;
            yield file.load_contents_async (null, out contents, out etag);
            var imported = MobileConfigImporter.parse (contents);
            MobileConfigAccount? selected = yield choose_imported_account (imported);
            if (selected == null) return;
            var account_dialog = new AccountDialog (
                account_provisioner, null, MailProvider.OTHER, selected);
            account_dialog.account_saved.connect ((account) => {
                reload ();
                account_saved (account);
            });
            account_dialog.present (this);
            status.visible = false;
        } catch (Error error) {
            if (!DialogErrors.was_cancelled (error)) show_profile_error (error);
        }
    }

    private async MobileConfigAccount? choose_imported_account (
        Gee.List<MobileConfigAccount> imported) {
        if (imported.size == 1) return imported[0];
        var choices = new Gtk.StringList (null);
        foreach (var account in imported)
            choices.append ("%s — %s".printf (
                account.settings.display_name, account.settings.email));
        var selection = new Adw.ComboRow ();
        selection.title = "Mail account";
        selection.model = choices;
        var chooser = new Adw.AlertDialog ("Choose an account",
            "This configuration profile contains more than one mail account.");
        chooser.extra_child = selection;
        chooser.add_response ("cancel", "Cancel");
        chooser.add_response ("import", "Review Account");
        chooser.default_response = "import";
        chooser.close_response = "cancel";
        if ((yield chooser.choose (this, null)) != "import") return null;
        return imported[(int) selection.selected];
    }

    private void show_profile_error (Error error) {
        status.title = "Could not import configuration profile";
        status.subtitle = error.message;
        status.visible = true;
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
        OutboundAccountSessionLease? outbound_lease = null;
        try {
            if (sync_service != null)
                yield sync_service.quiesce_account (account.id);
            // Wait for active delivery and close both SMTP and any IMAP store
            // retained by the dedicated outbound session before deleting the
            // account and credentials it depends on. Retain the lane through
            // credential cleanup so a waiting send cannot restart midway.
            if (account_provisioner != null)
                outbound_lease = yield account_provisioner.acquire_outbound_account_lease (
                    account.id);
            if (engine != null) {
                try { yield engine.disconnect_account (account.id); }
                catch (Error disconnect_error) {
                    debug ("Account session did not disconnect cleanly: %s", disconnect_error.message);
                }
            }
            if (outbound_lease != null) outbound_lease.ensure_valid ();
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
        } finally {
            if (outbound_lease != null) outbound_lease.release ();
        }
    }

    private void show_error (UserFacingError error) {
        status.title = error.title;
        status.subtitle = "%s %s".printf (error.description, error.suggestion);
        status.visible = true;
    }
}
}
