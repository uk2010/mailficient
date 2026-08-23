namespace Mailficient {
public class GnomeCalendarLauncher : Object {
    public const string DESKTOP_ID = "org.gnome.Calendar.desktop";

    public static void launch () throws Error {
        AppInfo? calendar = null;
        foreach (var app in AppInfo.get_all ()) {
            var id = app.get_id ();
            if (id == DESKTOP_ID || id == "org.gnome.Calendar") {
                calendar = app;
                break;
            }
        }

        if (calendar == null)
            throw new IOError.NOT_FOUND (
                "GNOME Calendar is required. Install GNOME Calendar, then try again.");

        if (!calendar.launch (null, null))
            throw new IOError.FAILED ("Could not open GNOME Calendar");
    }
}
}
