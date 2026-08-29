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
    private Adw.PreferencesGroup status_group = new Adw.PreferencesGroup ();
    private Adw.ActionRow status = new Adw.ActionRow ();
    private Gee.ArrayList<Gtk.Widget> account_rows = new Gee.ArrayList<Gtk.Widget> ();
    private Gtk.Label account_summary_title = new Gtk.Label ("");
    private Gtk.Label account_summary_detail = new Gtk.Label ("");

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
        add_css_class ("account-settings-page");
        add_css_class ("settings-page-frame");

        var summary_group = new Adw.PreferencesGroup ();
        summary_group.add_css_class ("account-summary-group");
        var summary = new Adw.WrapBox ();
        summary.add_css_class ("account-summary-card");
        summary.orientation = Gtk.Orientation.HORIZONTAL;
        summary.child_spacing = 12; summary.line_spacing = 10;
        summary.natural_line_length = 440;
        summary.wrap_policy = Adw.WrapPolicy.NATURAL;
        summary.justify = Adw.JustifyMode.FILL;
        summary.justify_last_line = true;
        var summary_identity = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 11);
        summary_identity.add_css_class ("account-summary-identity");
        summary_identity.hexpand = true;
        var summary_icon_badge = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        summary_icon_badge.add_css_class ("account-summary-icon-badge");
        summary_icon_badge.valign = Gtk.Align.CENTER;
        var summary_icon = new Gtk.Image.from_icon_name ("avatar-default-symbolic");
        summary_icon.add_css_class ("account-summary-icon");
        summary_icon_badge.append (summary_icon); summary_identity.append (summary_icon_badge);
        var summary_copy = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
        summary_copy.add_css_class ("account-summary-copy"); summary_copy.hexpand = true;
        account_summary_title.xalign = 0;
        account_summary_title.add_css_class ("account-summary-title");
        account_summary_detail.xalign = 0; account_summary_detail.wrap = true;
        account_summary_detail.add_css_class ("account-summary-detail");
        summary_copy.append (account_summary_title); summary_copy.append (account_summary_detail);
        summary_identity.append (summary_copy); summary.append (summary_identity);
        var add_account = new Gtk.Button ();
        var add_content = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
        add_content.append (new Gtk.Image.from_icon_name ("list-add-symbolic"));
        add_content.append (new Gtk.Label ("Add Account"));
        add_account.child = add_content;
        add_account.add_css_class ("suggested-action");
        add_account.add_css_class ("account-summary-add");
        add_account.valign = Gtk.Align.CENTER;
        add_account.clicked.connect (open_add_dialog);
        Accessibility.label (add_account, "Add mail account");
        summary.append (add_account); summary_group.add (summary); add (summary_group);

        accounts_group.add_css_class ("account-settings-list");
        accounts_group.add_css_class ("settings-section");
        accounts_group.add_css_class ("settings-section-card");
        accounts_group.title = "Connected Accounts";
        accounts_group.description = "Edit sign-in details or remove an account from this device.";
        add (accounts_group);

        status_group.add_css_class ("settings-section");
        status_group.add_css_class ("settings-section-card");
        status_group.visible = false;
        status.add_css_class ("account-settings-status");
        status.add_css_class ("settings-state-row");
        var status_icon = new Gtk.Image.from_icon_name ("dialog-warning-symbolic");
        status_icon.add_css_class ("settings-control-icon"); status.add_prefix (status_icon);
        status.visible = false; status.accessible_role = Gtk.AccessibleRole.ALERT;
        status_group.add (status);
        add (status_group);
        reload ();
    }

    private void reload () {
        foreach (var row in account_rows) accounts_group.remove (row);
        account_rows.clear ();
        try {
            var accounts = cache.list_accounts ();
            // Keep each label assignment in its own branch.  valac can release
            // the owned result of a nested conditional expression before
            // gtk_label_set_label() consumes it, which showed up as corrupt
            // account-summary text for the one-account case.
            int account_count = accounts.size;
            if (account_count == 0)
                account_summary_title.label = "No accounts connected";
            else if (account_count == 1)
                account_summary_title.label = "1 account connected";
            else
                account_summary_title.label = "%d accounts connected".printf (account_count);
            account_summary_detail.label = accounts.size == 0 ?
                "Add an account to start sending and receiving mail." :
                "Sign-in details are protected by the system keyring.";
            if (accounts.size == 0) {
                var empty = new Adw.ActionRow ();
                empty.title = "Account details will appear here";
                empty.subtitle = "Each account keeps its own folders, identity, and sign-in settings.";
                empty.add_css_class ("account-settings-empty");
                empty.add_css_class ("settings-empty-row");
                var empty_icon = new Gtk.Image.from_icon_name ("channel-secure-symbolic");
                empty_icon.add_css_class ("settings-control-icon"); empty.add_prefix (empty_icon);
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
            account_summary_title.label = "Accounts unavailable";
            account_summary_detail.label = "Try again, or review the recovery details below.";
            show_error (UserFacingError.from_error (error));
        }
    }

    private Adw.ActionRow account_row (AccountSettings account) {
        var row = new Adw.ActionRow ();
        row.add_css_class ("account-settings-row");
        row.add_css_class ("settings-control-row");
        row.title = account.display_name;
        string authentication = account.authentication == AuthenticationMode.GNOME_ONLINE_ACCOUNTS ?
            "Secure sign-in" : "Protected password";
        row.subtitle = account.email;
        var account_icon = new Gtk.Image.from_icon_name ("avatar-default-symbolic");
        account_icon.add_css_class ("settings-control-icon"); row.add_prefix (account_icon);
        var authentication_badge = new Gtk.Label (authentication);
        authentication_badge.add_css_class ("account-auth-badge");
        authentication_badge.valign = Gtk.Align.CENTER; row.add_suffix (authentication_badge);
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
        var dialog = new AccountSetupDialog (cache, account_provisioner, online_accounts);
        dialog.account_saved.connect (finish_account_setup);
        dialog.import_requested.connect (() => import_profile.begin ());
        dialog.present (this);
    }

    private void finish_account_setup (AccountSettings account) {
        status.visible = false; status_group.visible = false;
        reload (); account_saved (account);
    }

    private void open_edit_dialog (AccountSettings account) {
        var dialog = new AccountDialog (account_provisioner, account);
        dialog.account_saved.connect ((saved) => {
            reload ();
            account_saved (saved);
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
            account_dialog.account_saved.connect (finish_account_setup);
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
        status.visible = true; status_group.visible = true;
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
            status.visible = false; status_group.visible = false;
            reload ();
            accounts_changed ();
            if (!(yield credential_cleanup.cleanup_account (account.id))) {
                status.title = "Account removed";
                status.subtitle = "Secure credential cleanup will retry automatically.";
                status.visible = true; status_group.visible = true;
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
        status.visible = true; status_group.visible = true;
    }
}
}
