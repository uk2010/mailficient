namespace Mailficient {
public class StartupErrorWindow : Adw.ApplicationWindow {
    public signal void retry_requested ();
    public signal void quit_requested ();

    public StartupErrorWindow (Gtk.Application application, UserFacingError error) {
        Object (application: application, title: "Mailficient",
            default_width: 620, default_height: 430);

        var toolbar = new Adw.ToolbarView ();
        toolbar.add_top_bar (new Adw.HeaderBar ());
        var status = new Adw.StatusPage ();
        status.icon_name = "dialog-warning-symbolic";
        status.title = error.title;
        status.description = "%s\n\n%s\n\nMailficient has not changed or deleted the existing mail database."
            .printf (error.description, error.suggestion);

        var controls = new Gtk.Box (Gtk.Orientation.VERTICAL, 14);
        controls.halign = Gtk.Align.CENTER;
        if (error.technical_detail.strip () != "") {
            var details = new Gtk.Expander ("Technical Details");
            details.set_size_request (460, -1);
            var detail = new Gtk.Label (error.technical_detail);
            detail.xalign = 0; detail.wrap = true; detail.selectable = true;
            detail.add_css_class ("dim-label"); details.child = detail;
            controls.append (details);
        }
        var actions = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        actions.halign = Gtk.Align.CENTER;
        var quit = new Gtk.Button.with_label ("Quit");
        quit.clicked.connect (() => quit_requested ());
        var retry = new Gtk.Button.with_label ("Try Again");
        retry.add_css_class ("suggested-action"); retry.clicked.connect (() => retry_requested ());
        actions.append (quit); actions.append (retry); controls.append (actions);
        status.child = controls; toolbar.content = status; content = toolbar;
        Accessibility.label (retry, "Try opening Mailficient's local mail data again");
        Accessibility.label (quit, "Quit Mailficient without changing local mail data");
    }
}
}
