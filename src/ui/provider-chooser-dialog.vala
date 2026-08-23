namespace Mailficient {
public class ProviderChooserDialog : Adw.PreferencesDialog {
    public signal void provider_selected (MailProvider provider);

    public ProviderChooserDialog () {
        title = "Add Mail Account";
        content_width = 620; content_height = 560;
        var page = new Adw.PreferencesPage ();
        page.title = "Provider"; page.icon_name = "mail-unread-symbolic";
        var group = new Adw.PreferencesGroup ();
        group.title = "Choose Your Provider";
        group.description = "Secure sign-in is used where the provider supports it.";
        add_provider (group, MailProvider.ICLOUD, "iCloud",
            "IMAP and SMTP with an Apple app-specific password", "folder-remote-symbolic");
        add_provider (group, MailProvider.MICROSOFT, "Microsoft Exchange",
            "Microsoft 365 or Exchange Online through GNOME OAuth", "network-server-symbolic");
        add_provider (group, MailProvider.GOOGLE, "Google",
            "Gmail or Google Workspace through GNOME OAuth", "web-browser-symbolic");
        add_provider (group, MailProvider.YAHOO, "Yahoo",
            "IMAP and SMTP with a Yahoo app password", "mail-unread-symbolic");
        add_provider (group, MailProvider.AOL, "AOL",
            "IMAP and SMTP with an AOL password or app password", "mail-unread-symbolic");
        add_provider (group, MailProvider.OTHER, "Other Account",
            "Enter secure IMAP and SMTP settings manually", "preferences-system-symbolic");
        page.add (group);
        var note_group = new Adw.PreferencesGroup ();
        var note = new Adw.ActionRow ();
        note.title = "Exchange compatibility";
        note.subtitle = "Exchange Online is supported through IMAP/SMTP OAuth. On-premises EWS and Exchange ActiveSync are not currently supported.";
        note.subtitle_lines = 3;
        note.add_prefix (new Gtk.Image.from_icon_name ("dialog-information-symbolic"));
        note_group.add (note); page.add (note_group);
        add (page);
    }

    private void add_provider (Adw.PreferencesGroup group, MailProvider provider,
                               string title, string subtitle, string icon_name) {
        var row = new Adw.ActionRow ();
        row.title = title; row.subtitle = subtitle;
        row.add_prefix (new Gtk.Image.from_icon_name (icon_name));
        row.add_suffix (new Gtk.Image.from_icon_name ("go-next-symbolic"));
        row.activatable = true;
        row.activated.connect (() => {
            provider_selected (provider);
            close ();
        });
        group.add (row);
    }
}
}
