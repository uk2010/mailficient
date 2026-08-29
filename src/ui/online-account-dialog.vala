namespace Mailficient {
public class OnlineAccountDialog : Adw.PreferencesDialog {
    public signal void account_saved (AccountSettings account);

    private CacheDatabase cache;
    private AccountProvisioningService? account_provisioner;
    private OnlineAccountService online_accounts;
    private Adw.PreferencesGroup accounts_group = new Adw.PreferencesGroup ();
    private Adw.PreferencesGroup status_group = new Adw.PreferencesGroup ();
    private Adw.ActionRow status = new Adw.ActionRow ();
    private Gee.ArrayList<Gtk.Button> connect_buttons = new Gee.ArrayList<Gtk.Button> ();
    private Gee.ArrayList<Gtk.Widget> dynamic_rows = new Gee.ArrayList<Gtk.Widget> ();
    private Gtk.Spinner spinner = new Gtk.Spinner ();
    private bool connecting;
    private MailProvider provider_filter;
    private string requested_email;

    public OnlineAccountDialog (CacheDatabase cache, AccountProvisioningService? account_provisioner,
                                OnlineAccountService online_accounts,
                                MailProvider provider_filter = MailProvider.OTHER,
                                string requested_email = "") {
        this.cache = cache; this.account_provisioner = account_provisioner; this.online_accounts = online_accounts;
        this.provider_filter = provider_filter;
        this.requested_email = requested_email.strip ();
        title = provider_filter == MailProvider.GOOGLE ? "Add Google Account" :
            provider_filter == MailProvider.MICROSOFT ? "Add Microsoft Account" :
            "Signed-In Mail Accounts";
        content_width = 620; content_height = 360;
        var page = new Adw.PreferencesPage (); page.title = "Secure Sign-In";
        page.icon_name = "network-server-symbolic";
        page.add_css_class ("online-account-page");
        var trust_group = new Adw.PreferencesGroup ();
        var trust = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 14);
        trust.add_css_class ("online-account-trust");
        var trust_badge = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        trust_badge.add_css_class ("online-account-trust-badge"); trust_badge.valign = Gtk.Align.CENTER;
        var trust_icon = new Gtk.Image.from_icon_name ("security-high-symbolic");
        trust_icon.pixel_size = 26; trust_icon.halign = Gtk.Align.CENTER;
        trust_icon.valign = Gtk.Align.CENTER; trust_badge.append (trust_icon); trust.append (trust_badge);
        var trust_copy = new Gtk.Box (Gtk.Orientation.VERTICAL, 2); trust_copy.hexpand = true;
        var trust_title = new Gtk.Label ("Sign in without sharing your password");
        trust_title.xalign = 0; trust_title.wrap = true; trust_title.add_css_class ("online-account-trust-title");
        var trust_description = new Gtk.Label (
            "Mailficient connects through your computer’s trusted Online Accounts service. You stay in control of access in System Settings.");
        trust_description.xalign = 0; trust_description.wrap = true;
        trust_description.add_css_class ("online-account-trust-description");
        trust_copy.append (trust_title); trust_copy.append (trust_description);
        trust.append (trust_copy); trust_group.add (trust); page.add (trust_group);

        accounts_group.add_css_class ("online-account-list");
        accounts_group.title = "Choose an account";
        accounts_group.description = "Choose an account already signed in through your computer’s Online Accounts settings.";
        var loading = new Adw.ActionRow (); loading.title = "Looking for signed-in accounts…";
        loading.add_css_class ("online-account-row");
        spinner.spinning = true; spinner.valign = Gtk.Align.CENTER; loading.add_prefix (spinner);
        add_dynamic_row (loading); accounts_group.update_state (Gtk.AccessibleState.BUSY, true, -1);
        page.add (accounts_group);
        status.visible = account_provisioner == null;
        status_group.visible = status.visible; status_group.add_css_class ("online-account-status");
        status.add_prefix (new Gtk.Image.from_icon_name ("dialog-warning-symbolic"));
        status.accessible_role = account_provisioner == null ? Gtk.AccessibleRole.ALERT : Gtk.AccessibleRole.STATUS;
        if (account_provisioner == null) {
            status.title = "Account connections are unavailable";
            status.subtitle = "Install a Mailficient build with live account support.";
        }
        status_group.add (status); page.add (status_group); add (page);
        Idle.add (() => { load_accounts.begin (loading); return Source.REMOVE; });
    }

    private async void load_accounts (Gtk.Widget loading) {
        try {
            var accounts = yield online_accounts.list_mail_accounts ();
            remove_dynamic_row (loading); spinner.spinning = false;
            accounts_group.update_state (Gtk.AccessibleState.BUSY, false, -1);
            if (accounts.size == 0) {
                add_empty_state ("No signed-in mail accounts",
                    "Add Google or Microsoft in System Settings, enable Mail, then try again.");
                return;
            }
            int shown = 0;
            foreach (var account in accounts) {
                if (!matches_filter (account)) continue;
                add_dynamic_row (account_row (account)); shown++;
            }
            if (shown == 0) {
                string missing_title = requested_email != "" ?
                    "%s isn’t signed in".printf (requested_email) :
                    (provider_filter == MailProvider.GOOGLE ?
                        "No Google account is signed in" :
                        "No Microsoft account is signed in");
                add_empty_state (missing_title,
                    "Add the account in System Settings, enable Mail, then try again.");
            }
        } catch (Error error) {
            remove_dynamic_row (loading); spinner.spinning = false;
            accounts_group.update_state (Gtk.AccessibleState.BUSY, false, -1);
            show_error (UserFacingError.from_error (error));
            add_retry_row ();
        }
    }

    private bool matches_filter (OnlineMailAccount account) {
        if (requested_email != "" && account.email.down () != requested_email.down ()) return false;
        if (provider_filter == MailProvider.OTHER) return true;
        string name = account.provider_name.down ();
        if (provider_filter == MailProvider.GOOGLE) return name.contains ("google");
        if (provider_filter == MailProvider.MICROSOFT)
            return name.contains ("microsoft") || name.contains ("windows") ||
                name.contains ("exchange") || name.contains ("office");
        return false;
    }

    private Adw.ActionRow account_row (OnlineMailAccount account) {
        var row = new Adw.ActionRow (); row.title = account.display_name;
        row.add_css_class ("online-account-row");
        row.subtitle = "%s · %s".printf (account.email,
            account.provider_name == "" ? "Online Account" : account.provider_name);
        row.add_prefix (new Gtk.Image.from_icon_name ("avatar-default-symbolic"));
        var connect = new Gtk.Button.with_label ("Connect"); connect.valign = Gtk.Align.CENTER;
        connect.add_css_class ("suggested-action"); connect.add_css_class ("online-account-connect");
        connect.clicked.connect (() => connect_account.begin (account));
        if (account_provisioner == null) {
            connect.sensitive = false;
            connect.tooltip_text = "Live account support is available in the Flatpak build";
        }
        connect_buttons.add (connect); row.add_suffix (connect); return row;
    }

    private void add_empty_state (string title, string subtitle) {
        var empty = new Adw.ActionRow (); empty.title = title; empty.subtitle = subtitle;
        empty.add_css_class ("online-account-empty");
        empty.subtitle_lines = 2;
        empty.add_prefix (new Gtk.Image.from_icon_name ("dialog-information-symbolic"));
        var settings_button = new Gtk.Button.with_label ("Open System Settings");
        settings_button.valign = Gtk.Align.CENTER; settings_button.clicked.connect (open_system_settings);
        var retry = new Gtk.Button.from_icon_name ("view-refresh-symbolic");
        retry.valign = Gtk.Align.CENTER; retry.tooltip_text = "Look for accounts again";
        Accessibility.label (retry, "Look for signed-in mail accounts again");
        retry.clicked.connect (retry_loading);
        empty.add_suffix (settings_button); empty.add_suffix (retry); add_dynamic_row (empty);
    }

    private void add_retry_row () {
        var retry_row = new Adw.ActionRow (); retry_row.title = "Try looking for accounts again";
        var retry = new Gtk.Button.with_label ("Try Again"); retry.valign = Gtk.Align.CENTER;
        retry.add_css_class ("suggested-action"); retry.clicked.connect (retry_loading);
        retry_row.add_suffix (retry); add_dynamic_row (retry_row);
    }

    private void retry_loading () {
        if (connecting) return;
        clear_dynamic_rows (); connect_buttons.clear ();
        var loading = new Adw.ActionRow (); loading.title = "Looking for signed-in accounts…";
        spinner.spinning = true; loading.add_prefix (spinner); add_dynamic_row (loading);
        accounts_group.update_state (Gtk.AccessibleState.BUSY, true, -1);
        if (account_provisioner != null) { status.visible = false; status_group.visible = false; }
        load_accounts.begin (loading);
    }

    private void open_system_settings () {
        try {
            new Subprocess.newv ({ "gnome-control-center", "online-accounts" },
                SubprocessFlags.NONE);
        } catch (Error error) {
            status.title = "Open Online Accounts in System Settings";
            status.subtitle = "Add Google or Microsoft there, enable Mail, then return and choose Try Again.";
            status.accessible_role = Gtk.AccessibleRole.ALERT;
            status.visible = true; status_group.visible = true;
        }
    }

    private void add_dynamic_row (Gtk.Widget row) {
        accounts_group.add (row); dynamic_rows.add (row);
    }

    private void remove_dynamic_row (Gtk.Widget row) {
        if (dynamic_rows.remove (row)) accounts_group.remove (row);
    }

    private void clear_dynamic_rows () {
        foreach (var row in dynamic_rows) accounts_group.remove (row);
        dynamic_rows.clear ();
    }

    private async void connect_account (OnlineMailAccount online) {
        if (connecting || account_provisioner == null) return;
        connecting = true; set_buttons_sensitive (false);
        status.visible = true; status_group.visible = true; status.title = "Connecting securely…";
        status.subtitle = "Your computer may ask you to renew the sign-in.";
        status.accessible_role = Gtk.AccessibleRole.STATUS;
        status.update_state (Gtk.AccessibleState.BUSY, true, -1);
        AccountSettings? settings = null;
        try {
            settings = online.to_settings ();
            foreach (var existing in cache.list_accounts ())
                if (existing.email.down () == settings.email.down () && existing.id != settings.id)
                    throw new MailError.INVALID_ACCOUNT ("That email address is already connected. Remove the existing account before adding this signed-in account.");
            yield account_provisioner.provision (settings);
            status.title = "Account connected"; status.subtitle = "%s is ready to synchronize.".printf (settings.email);
            account_saved (settings); close ();
        } catch (Error error) {
            show_error (UserFacingError.from_error (error));
            connecting = false; set_buttons_sensitive (true);
        } finally {
            status.update_state (Gtk.AccessibleState.BUSY, false, -1);
        }
    }

    private void set_buttons_sensitive (bool sensitive) {
        foreach (var button in connect_buttons) button.sensitive = sensitive;
    }

    private void show_error (UserFacingError error) {
        status.title = error.title; status.subtitle = "%s %s".printf (error.description, error.suggestion);
        status.accessible_role = Gtk.AccessibleRole.ALERT;
        status.visible = true; status_group.visible = true;
    }
}
}
