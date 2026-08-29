namespace Mailficient {
public class ProviderChooserDialog : Adw.PreferencesDialog {
    public signal void provider_selected (MailProvider provider);

    public ProviderChooserDialog () {
        title = "Add Mail Account";
        content_width = 640; content_height = 390;
        var page = new Adw.PreferencesPage ();
        page.title = "Provider"; page.icon_name = "mail-unread-symbolic";
        page.add_css_class ("provider-chooser-page");
        var group = new Adw.PreferencesGroup ();
        group.add_css_class ("provider-chooser-group");
        group.title = "Choose your mail provider";
        group.description = "We’ll use the provider’s recommended secure connection. You can review technical details before anything is saved.";
        var providers = new Gtk.FlowBox ();
        providers.add_css_class ("provider-card-grid");
        providers.selection_mode = Gtk.SelectionMode.NONE; providers.homogeneous = true;
        providers.min_children_per_line = 1; providers.max_children_per_line = 2;
        providers.column_spacing = 10; providers.row_spacing = 10;
        add_provider (providers, MailProvider.ICLOUD, "iCloud",
            "Your Apple mail account", "folder-remote-symbolic");
        add_provider (providers, MailProvider.MICROSOFT, "Microsoft 365 or Outlook",
            "Outlook.com, Hotmail, and Microsoft 365", "network-server-symbolic");
        add_provider (providers, MailProvider.GOOGLE, "Google",
            "Gmail or Google Workspace", "web-browser-symbolic");
        add_provider (providers, MailProvider.YAHOO, "Yahoo",
            "Yahoo Mail", "mail-unread-symbolic");
        add_provider (providers, MailProvider.AOL, "AOL",
            "AOL Mail", "mail-unread-symbolic");
        add_provider (providers, MailProvider.OTHER, "Other account",
            "Any account that supports secure standard mail", "preferences-system-symbolic");
        group.add (providers); page.add (group);
        add (page);
    }

    private void add_provider (Gtk.FlowBox providers, MailProvider provider,
                               string title, string subtitle, string icon_name) {
        var button = new Gtk.Button ();
        button.add_css_class ("provider-card"); button.hexpand = true;
        button.set_size_request (230, -1);
        var content = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
        content.add_css_class ("provider-card-content");
        var badge = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        badge.add_css_class ("provider-card-icon-badge"); badge.valign = Gtk.Align.CENTER;
        var icon = new Gtk.Image.from_icon_name (icon_name);
        icon.add_css_class ("provider-card-icon"); icon.halign = Gtk.Align.CENTER;
        icon.valign = Gtk.Align.CENTER; badge.append (icon); content.append (badge);
        var labels = new Gtk.Box (Gtk.Orientation.VERTICAL, 2); labels.hexpand = true;
        var heading = new Gtk.Label (title); heading.xalign = 0; heading.wrap = true;
        heading.max_width_chars = 22;
        heading.add_css_class ("provider-card-title");
        var detail = new Gtk.Label (subtitle); detail.xalign = 0; detail.wrap = true;
        detail.max_width_chars = 22;
        detail.add_css_class ("provider-card-description");
        labels.append (heading); labels.append (detail); content.append (labels);
        var next = new Gtk.Image.from_icon_name ("go-next-symbolic");
        next.valign = Gtk.Align.CENTER; next.add_css_class ("provider-card-chevron");
        content.append (next); button.child = content;
        Accessibility.label (button, "%s — %s".printf (title, subtitle));
        button.clicked.connect (() => {
            provider_selected (provider);
            close ();
        });
        providers.insert (button, -1);
    }
}
}
