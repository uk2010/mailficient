namespace Mailficient {
public class DialogErrors : Object {
    public static bool was_cancelled (Error error) {
        return error is IOError.CANCELLED ||
            error is Gtk.DialogError.CANCELLED ||
            error is Gtk.DialogError.DISMISSED;
    }
}
}
