namespace Mailficient {
public class DebugTrace : Object {
    public static bool enabled () {
        return Environment.get_variable ("MAILFICIENT_SWITCH_DEBUG") == "1";
    }

    public static int64 mark () {
        return GLib.get_monotonic_time ();
    }

    public static void log (string scope, string detail) {
        if (!enabled ()) return;
        stderr.printf ("[mailficient-debug %lld] %s: %s\n",
            GLib.get_monotonic_time (), scope, detail);
        stderr.flush ();
    }

    public static void duration (string scope, string detail, int64 started) {
        log (scope, "%s duration_us=%lld".printf (detail, GLib.get_monotonic_time () - started));
    }
}
}
