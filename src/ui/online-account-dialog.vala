namespace Mailficient {
public class OnlineAccountDialog : Adw.PreferencesDialog {
    public signal void account_saved (AccountSettings account);

    private CacheDatabase cache;
    private AccountProvisioningService? account_provisioner;
    private OnlineAccountService online_accounts;
    private Adw.PreferencesGroup accounts_group = new Adw.PreferencesGroup ();
    private Adw.ActionRow status = new Adw.ActionRow ();
    private Gee.ArrayList<Gtk.Button> connect_buttons = new Gee.ArrayList<Gtk.Button> ();
    private Gtk.Spinner spinner = new Gtk.Spinner ();
    private bool connecting;

    public OnlineAccountDialog (CacheDatabase cache, AccountProvisioningService? account_provisioner,
                                OnlineAccountService online_accounts) {
        this.cache = cache; this.account_provisioner = account_provisioner; this.online_accounts = online_accounts;
        title = "GNOME Online Accounts"; content_width = 620; content_height = 320;
        var page = new Adw.PreferencesPage (); page.title = "Online Accounts";
        page.icon_name = "network-server-symbolic";
        accounts_group.title = "Available Mail Accounts";
        accounts_group.description = "Mailficient requests short-lived OAuth tokens from GNOME and never stores them in its database.";
        var loading = new Adw.ActionRow (); loading.title = "Looking for authorized accounts…";
        spinner.spinning = true; spinner.valign = Gtk.Align.CENTER; loading.add_prefix (spinner);
        accounts_group.add (loading); page.add (accounts_group);
        status.visible = false; var status_group = new Adw.PreferencesGroup ();
        status.add_prefix (new Gtk.Image.from_icon_name ("dialog-warning-symbolic"));
        status_group.add (status); page.add (status_group); add (page);
        Idle.add (() => { load_accounts.begin (loading); return Source.REMOVE; });
    }

    private async void load_accounts (Gtk.Widget loading) {
        try {
            var accounts = yield online_accounts.list_mail_accounts ();
            accounts_group.remove (loading); spinner.spinning = false;
            if (accounts.size == 0) {
                var empty = new Adw.ActionRow (); empty.title = "No OAuth mail accounts are available";
                empty.subtitle = "Add Google or Microsoft in Settings → Online Accounts and enable Mail, then try again.";
                empty.add_prefix (new Gtk.Image.from_icon_name ("dialog-information-symbolic"));
                accounts_group.add (empty); return;
            }
            foreach (var account in accounts) accounts_group.add (account_row (account));
        } catch (Error error) {
            accounts_group.remove (loading); spinner.spinning = false;
            show_error (UserFacingError.from_error (error));
        }
    }

    private Adw.ActionRow account_row (OnlineMailAccount account) {
        var row = new Adw.ActionRow (); row.title = account.display_name;
        row.subtitle = "%s · %s".printf (account.email,
            account.provider_name == "" ? "Online Account" : account.provider_name);
        row.add_prefix (new Gtk.Image.from_icon_name ("avatar-default-symbolic"));
        var connect = new Gtk.Button.with_label ("Connect"); connect.valign = Gtk.Align.CENTER;
        connect.add_css_class ("suggested-action"); connect.clicked.connect (() => connect_account.begin (account));
        if (account_provisioner == null) {
            connect.sensitive = false;
            connect.tooltip_text = "Live account support is available in the Flatpak build";
        }
        connect_buttons.add (connect); row.add_suffix (connect); return row;
    }

    private async void connect_account (OnlineMailAccount online) {
        if (connecting || account_provisioner == null) return;
        connecting = true; set_buttons_sensitive (false);
        status.visible = true; status.title = "Connecting securely…";
        status.subtitle = "GNOME Online Accounts may ask you to renew authorization.";
        AccountSettings? settings = null;
        try {
            settings = online.to_settings ();
            foreach (var existing in cache.list_accounts ())
                if (existing.email.down () == settings.email.down () && existing.id != settings.id)
                    throw new MailError.INVALID_ACCOUNT ("That email address is already configured. Remove the existing account before importing it from GNOME Online Accounts.");
            yield account_provisioner.provision (settings);
            status.title = "Account connected"; status.subtitle = "%s is ready to synchronize.".printf (settings.email);
            account_saved (settings); close ();
        } catch (Error error) {
            show_error (UserFacingError.from_error (error));
            connecting = false; set_buttons_sensitive (true);
        }
    }

    private void set_buttons_sensitive (bool sensitive) {
        foreach (var button in connect_buttons) button.sensitive = sensitive;
    }

    private void show_error (UserFacingError error) {
        status.title = error.title; status.subtitle = "%s %s".printf (error.description, error.suggestion);
        status.visible = true;
    }
}
}
