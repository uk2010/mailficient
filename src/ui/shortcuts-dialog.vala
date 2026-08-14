namespace Mailficient {
public class ShortcutsDialog : Adw.PreferencesDialog {
    public ShortcutsDialog () {
        title = "Keyboard Shortcuts"; content_width = 560; content_height = 600; search_enabled = false;
        var page = new Adw.PreferencesPage (); page.title = "Shortcuts"; page.icon_name = "preferences-desktop-keyboard-shortcuts-symbolic";
        var mail = new Adw.PreferencesGroup (); mail.title = "Mail";
        add_shortcut_row (mail, "New Message", "Ctrl+N"); add_shortcut_row (mail, "Reply", "Ctrl+R");
        add_shortcut_row (mail, "Reply All", "Ctrl+Shift+R"); add_shortcut_row (mail, "Forward", "Ctrl+L");
        add_shortcut_row (mail, "Archive", "Ctrl+Shift+A / E"); add_shortcut_row (mail, "Move to Trash", "Delete");
        add_shortcut_row (mail, "Flag or Unflag", "Ctrl+Shift+L"); add_shortcut_row (mail, "Mark Read or Unread", "Ctrl+Shift+U / I");
        add_shortcut_row (mail, "Reply / Forward", "Ctrl+R / R, Ctrl+L / F");
        add_shortcut_row (mail, "Select All / Clear Selection", "Ctrl+A / Escape");
        add_shortcut_row (mail, "Select a Range", "Shift-click");
        var navigation = new Adw.PreferencesGroup (); navigation.title = "Navigation";
        add_shortcut_row (navigation, "Search Mail", "Ctrl+F"); add_shortcut_row (navigation, "Get Mail", "F9");
        add_shortcut_row (navigation, "Next Message", "Alt+Down / J"); add_shortcut_row (navigation, "Previous Message", "Alt+Up / K");
        add_shortcut_row (navigation, "Snooze", "S");
        var compose = new Adw.PreferencesGroup (); compose.title = "Composing";
        add_shortcut_row (compose, "Send", "Ctrl+Enter"); add_shortcut_row (compose, "Save Draft", "Ctrl+S");
        add_shortcut_row (compose, "Attach Files", "Ctrl+Shift+A");
        page.add (mail); page.add (navigation); page.add (compose); add (page);
    }

    private static void add_shortcut_row (Adw.PreferencesGroup group, string title, string keys) {
        var row = new Adw.ActionRow (); row.title = title;
        var label = new Gtk.Label (keys); label.valign = Gtk.Align.CENTER; label.add_css_class ("keycap");
        Accessibility.label (label, keys); row.add_suffix (label); group.add (row);
    }
}
}
