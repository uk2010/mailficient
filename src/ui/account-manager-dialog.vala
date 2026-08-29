namespace Mailficient {
public class AccountManagerDialog : Adw.PreferencesDialog {
    public signal void account_saved (AccountSettings account);
    public signal void accounts_changed ();
    public signal void setup_completed (AccountSettings account);
    public signal void setup_deferred ();

    private CacheDatabase cache;
    private MailSettingsStore settings;
    private CredentialStore credentials;
    private CredentialCleanupService credential_cleanup;
    private AccountProvisioningService? account_provisioner;
    private MailEngine? engine;
    private AccountSyncService? sync_service;
    private OnlineAccountService online_accounts;
    private Adw.PreferencesGroup accounts_group = new Adw.PreferencesGroup ();
    private Adw.PreferencesGroup status_group = new Adw.PreferencesGroup ();
    private Adw.ActionRow status = new Adw.ActionRow ();
    private Gee.ArrayList<Gtk.Widget> account_rows = new Gee.ArrayList<Gtk.Widget> ();
    private bool onboarding;

    public AccountManagerDialog (CacheDatabase cache, CredentialStore credentials,
                                 CredentialCleanupService credential_cleanup,
                                 AccountProvisioningService? account_provisioner, MailEngine? engine,
                                 AccountSyncService? sync_service,
                                 OnlineAccountService online_accounts, bool onboarding = false) {
        this.cache = cache; this.settings = new MailSettingsStore (cache);
        this.credentials = credentials; this.credential_cleanup = credential_cleanup;
        this.account_provisioner = account_provisioner;
        this.engine = engine; this.sync_service = sync_service;
        this.online_accounts = online_accounts;
        this.onboarding = onboarding;
        title = onboarding ? "Welcome to Mailficient" : "Mail Accounts";
        content_width = onboarding ? 660 : 640; content_height = onboarding ? 520 : 400;
        var page = new Adw.PreferencesPage ();
        page.title = "Accounts"; page.icon_name = "avatar-default-symbolic";

        if (onboarding) {
            var welcome_group = new Adw.PreferencesGroup ();
            var welcome = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            welcome.add_css_class ("account-onboarding");

            var icon_badge = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
            icon_badge.add_css_class ("account-onboarding-icon-badge");
            icon_badge.halign = Gtk.Align.CENTER;
            var welcome_icon = new Gtk.Image.from_icon_name ("mail-unread-symbolic");
            welcome_icon.add_css_class ("account-onboarding-icon");
            welcome_icon.pixel_size = 42;
            welcome_icon.halign = Gtk.Align.CENTER; welcome_icon.valign = Gtk.Align.CENTER;
            icon_badge.append (welcome_icon); welcome.append (icon_badge);

            var eyebrow = new Gtk.Label ("WELCOME TO MAILFICIENT");
            eyebrow.add_css_class ("account-onboarding-eyebrow");
            eyebrow.halign = Gtk.Align.CENTER; welcome.append (eyebrow);

            var welcome_title = new Gtk.Label ("Your inbox, made calmer.");
            welcome_title.add_css_class ("account-onboarding-title");
            welcome_title.wrap = true; welcome_title.justify = Gtk.Justification.CENTER;
            welcome.append (welcome_title);

            var welcome_description = new Gtk.Label (
                "Bring every account, folder, and rule into one focused place—without giving up control of how your mail works.");
            welcome_description.add_css_class ("account-onboarding-description");
            welcome_description.wrap = true; welcome_description.justify = Gtk.Justification.CENTER;
            welcome_description.max_width_chars = 52; welcome_description.halign = Gtk.Align.CENTER;
            welcome.append (welcome_description);

            var values = new Gtk.FlowBox ();
            values.add_css_class ("account-onboarding-values");
            values.selection_mode = Gtk.SelectionMode.NONE; values.homogeneous = true;
            values.min_children_per_line = 1; values.max_children_per_line = 3;
            values.column_spacing = 8; values.row_spacing = 8;
            values.insert (welcome_value ("mail-unread-symbolic", "Every inbox",
                "See accounts together or keep them separate."), -1);
            values.insert (welcome_value ("security-high-symbolic", "Private by design",
                "Credentials stay protected on this device."), -1);
            values.insert (welcome_value ("folder-symbolic", "Folders and rules",
                "Organize mail your way from the start."), -1);
            welcome.append (values);

            var welcome_actions = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);
            welcome_actions.add_css_class ("account-onboarding-actions");
            welcome_actions.halign = Gtk.Align.CENTER;
            var begin = new Gtk.Button.with_label ("Add Mail Account");
            begin.add_css_class ("suggested-action"); begin.add_css_class ("pill");
            begin.clicked.connect (open_add_dialog);
            var later = new Gtk.Button.with_label ("Not Now"); later.add_css_class ("flat");
            later.clicked.connect (() => { setup_deferred (); close (); });
            welcome_actions.append (begin); welcome_actions.append (later);
            welcome.append (welcome_actions);

            var privacy_note = new Gtk.Label ("Setup takes about a minute · Nothing changes until the account connects");
            privacy_note.add_css_class ("account-onboarding-note");
            privacy_note.wrap = true; privacy_note.justify = Gtk.Justification.CENTER;
            welcome.append (privacy_note);
            welcome_group.add (welcome); page.add (welcome_group);
        } else {
            accounts_group.title = "Mail Accounts";
            accounts_group.description = "Choose an account to review its connection or remove it from this device.";
            page.add (accounts_group);

            var add_group = new Adw.PreferencesGroup (); add_group.title = "Add an Account";
            var add_row = new Adw.ActionRow ();
            add_row.title = "Add Mail Account";
            add_row.subtitle = "iCloud, Google, Microsoft, Yahoo, AOL, or another provider";
            add_row.add_prefix (new Gtk.Image.from_icon_name ("list-add-symbolic"));
            add_row.add_suffix (new Gtk.Image.from_icon_name ("go-next-symbolic"));
            add_row.activatable = true; add_row.activated.connect (open_add_dialog);
            add_group.add (add_row);
            page.add (add_group);
        }

        status.add_prefix (new Gtk.Image.from_icon_name ("dialog-warning-symbolic"));
        status.visible = false; status.accessible_role = Gtk.AccessibleRole.ALERT;
        status_group.visible = false; status_group.add (status); page.add (status_group); add (page);
        reload ();
    }

    private static Gtk.Widget welcome_value (string icon_name, string title, string description) {
        var card = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
        card.add_css_class ("account-onboarding-value");
        card.set_size_request (140, -1);
        var icon = new Gtk.Image.from_icon_name (icon_name);
        icon.add_css_class ("account-onboarding-value-icon"); icon.halign = Gtk.Align.CENTER;
        var heading = new Gtk.Label (title); heading.wrap = true;
        heading.max_width_chars = 18;
        heading.justify = Gtk.Justification.CENTER; heading.add_css_class ("account-onboarding-value-title");
        var detail = new Gtk.Label (description); detail.wrap = true;
        detail.max_width_chars = 16;
        detail.justify = Gtk.Justification.CENTER; detail.add_css_class ("account-onboarding-value-description");
        card.append (icon); card.append (heading); card.append (detail);
        Accessibility.label (card, "%s. %s".printf (title, description));
        return card;
    }

    private void reload () {
        foreach (var row in account_rows) accounts_group.remove (row);
        account_rows.clear ();
        try {
            var accounts = cache.list_accounts ();
            if (accounts.size == 0) {
                var empty = new Adw.ActionRow ();
                empty.title = "No connected accounts";
                empty.subtitle = "Add an account to start receiving and sending mail.";
                empty.add_prefix (new Gtk.Image.from_icon_name ("mail-unread-symbolic"));
                accounts_group.add (empty); account_rows.add (empty);
            } else {
                foreach (var account in accounts) {
                    var row = account_row (account); accounts_group.add (row); account_rows.add (row);
                }
            }
        } catch (Error error) {
            show_error (UserFacingError.from_error (error));
        }
    }

    private Adw.ActionRow account_row (AccountSettings account) {
        var row = new Adw.ActionRow ();
        row.title = account.display_name;
        string authentication = account.authentication == AuthenticationMode.GNOME_ONLINE_ACCOUNTS ?
            "Secure sign-in" : "Password protected";
        row.subtitle = "%s · %s".printf (account.email, authentication);
        row.add_prefix (new Gtk.Image.from_icon_name ("avatar-default-symbolic"));
        var edit = new Gtk.Button.from_icon_name ("document-edit-symbolic");
        edit.valign = Gtk.Align.CENTER; edit.add_css_class ("flat"); edit.tooltip_text = "Edit account";
        Accessibility.label (edit, "Edit %s".printf (account.display_name));
        edit.clicked.connect (() => open_edit_dialog (account)); row.add_suffix (edit);
        var remove = new Gtk.Button.from_icon_name ("user-trash-symbolic");
        remove.valign = Gtk.Align.CENTER; remove.add_css_class ("flat"); remove.tooltip_text = "Remove account";
        Accessibility.label (remove, "Remove %s".printf (account.display_name));
        remove.clicked.connect (() => remove_account.begin (account)); row.add_suffix (remove);
        return row;
    }

    private void open_add_dialog () {
        var dialog = new AccountSetupDialog (cache, account_provisioner, online_accounts);
        dialog.account_saved.connect (finish_account_setup);
        dialog.import_requested.connect (() => import_profile.begin ());
        dialog.present (this);
    }

    private void finish_account_setup (AccountSettings account) {
        reload (); account_saved (account);
        if (onboarding) { setup_completed (account); close (); }
    }

    private void open_edit_dialog (AccountSettings account) {
        var dialog = new AccountDialog (account_provisioner, account);
        dialog.account_saved.connect ((saved) => { reload (); account_saved (saved); });
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
        selection.title = "Mail account"; selection.model = choices;
        var chooser = new Adw.AlertDialog ("Choose an account",
            "This configuration profile contains more than one mail account.");
        chooser.extra_child = selection;
        chooser.add_response ("cancel", "Cancel"); chooser.add_response ("import", "Review Account");
        chooser.default_response = "import"; chooser.close_response = "cancel";
        if ((yield chooser.choose (this, null)) != "import") return null;
        return imported[(int) selection.selected];
    }

    private void show_profile_error (Error error) {
        status.title = "Could not import configuration profile";
        status.subtitle = error.message;
        status.visible = true; status_group.visible = true;
    }

    private async void remove_account (AccountSettings account) {
        var confirmation = new Adw.AlertDialog ("Remove %s?".printf (account.display_name),
            "This removes its cached messages, pending changes, unsent drafts, and securely stored credentials from this device. Messages on the server are not deleted.");
        confirmation.add_response ("cancel", "Cancel"); confirmation.add_response ("remove", "Remove Account");
        confirmation.default_response = "cancel"; confirmation.close_response = "cancel";
        confirmation.set_response_appearance ("remove", Adw.ResponseAppearance.DESTRUCTIVE);
        if ((yield confirmation.choose (this, null)) != "remove") return;
        OutboundAccountSessionLease? outbound_lease = null;
        try {
            if (sync_service != null)
                yield sync_service.quiesce_account (account.id);
            if (account_provisioner != null)
                outbound_lease = yield account_provisioner.acquire_outbound_account_lease (
                    account.id);
            if (engine != null) {
                try { yield engine.disconnect_account (account.id); }
                catch (Error disconnect_error) { debug ("Account session did not disconnect cleanly: %s", disconnect_error.message); }
            }
            if (outbound_lease != null) outbound_lease.ensure_valid ();
            cache.delete_account (account.id);
            status.visible = false; reload (); accounts_changed ();
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
        status.visible = true; status_group.visible = true;
    }
}
}
