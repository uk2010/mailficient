namespace Mailficient {
// Flatpak cannot install a host XDG autostart entry. Ask the standard desktop
// portal when the user actually queues work. Native installs use the packaged
// XDG autostart file; Snap copies that entry into its revision-specific user
// data as required by snapd. Every path also starts one resident worker for the
// current login; its D-Bus lease prevents duplicate workers.
public class BackgroundAutostartService : Object {
    private bool requested;
    private bool portal_allowed;
    private Subprocess? worker;

    public async void ensure_available () {
        if (is_snap ()) {
            install_snap_autostart_entry ();
            launch_worker ();
            return;
        }
        if (!is_flatpak ()) {
            launch_worker ();
            return;
        }
        if (portal_allowed) {
            launch_worker ();
            return;
        }
        if (requested) return;
        requested = true;
        try {
            var portal = new DBusProxy.for_bus_sync (BusType.SESSION,
                DBusProxyFlags.NONE, null, "org.freedesktop.portal.Desktop",
                "/org/freedesktop/portal/desktop",
                "org.freedesktop.portal.Background");
            DBusConnection connection = portal.get_connection ();
            string? unique_name = connection.get_unique_name ();
            if (unique_name == null || unique_name.length < 2)
                throw new IOError.FAILED ("The session bus has no unique name");

            string token = "mailficient_" + Uuid.string_random ().replace ("-", "_");
            string sender = unique_name.substring (1).replace (".", "_");
            string request_path = "/org/freedesktop/portal/desktop/request/%s/%s".printf (
                sender, token);
            string accepted_path = request_path;
            uint subscription_id = 0;
            uint timeout_id = 0;
            subscription_id = connection.signal_subscribe (
                "org.freedesktop.portal.Desktop",
                "org.freedesktop.portal.Request", "Response", null, null,
                DBusSignalFlags.NONE,
                (bus, signal_sender, object_path, interface_name, signal_name, parameters) => {
                    if (object_path != accepted_path) return;
                    if (subscription_id != 0) {
                        bus.signal_unsubscribe (subscription_id);
                        subscription_id = 0;
                    }
                    if (timeout_id != 0) {
                        Source.remove (timeout_id);
                        timeout_id = 0;
                    }
                    uint32 response_code;
                    Variant results;
                    parameters.get ("(u@a{sv})", out response_code, out results);
                    if (response_allows_background (response_code, results)) {
                        portal_allowed = true;
                        launch_worker ();
                    } else {
                        warning ("Background delivery permission was not granted");
                    }
                });

            var options = new VariantBuilder (new VariantType ("a{sv}"));
            options.add ("{sv}", "reason", new Variant.string (
                "Synchronize drafts and send scheduled messages while Mailficient is closed."));
            options.add ("{sv}", "autostart", new Variant.boolean (true));
            options.add ("{sv}", "handle_token", new Variant.string (token));
            string[] commandline = { "mailficient", "--background" };
            options.add ("{sv}", "commandline", new Variant.strv (commandline));
            Variant reply;
            try {
                reply = yield portal.call ("RequestBackground",
                    new Variant ("(s@a{sv})", "", options.end ()),
                    DBusCallFlags.NONE, -1, null);
            } catch (Error error) {
                if (subscription_id != 0) {
                    connection.signal_unsubscribe (subscription_id);
                    subscription_id = 0;
                }
                throw error;
            }
            string returned_path;
            reply.get ("(o)", out returned_path);
            if (returned_path != request_path) {
                warning ("Background portal returned an unexpected request handle");
                accepted_path = returned_path;
            }
            if (subscription_id != 0) {
                timeout_id = Timeout.add_seconds (60, () => {
                    if (subscription_id != 0) {
                        connection.signal_unsubscribe (subscription_id);
                        subscription_id = 0;
                    }
                    timeout_id = 0;
                    warning ("Background delivery permission request timed out");
                    return Source.REMOVE;
                });
            }
        } catch (Error error) {
            // The foreground scheduler remains active and the durable Outbox
            // will retry next launch. A missing/denied portal must not undo the
            // user's scheduled message.
            warning ("Background delivery permission could not be requested: %s",
                error.message);
        }
    }

    private void install_snap_autostart_entry () {
        string? snap_root = Environment.get_variable ("SNAP");
        string? snap_user_data = Environment.get_variable ("SNAP_USER_DATA");
        if (snap_root == null || snap_root == "" ||
            snap_user_data == null || snap_user_data == "") return;

        string? failure_message;
        if (!install_snap_autostart_entry_for_paths (snap_root, snap_user_data,
                                                     out failure_message)) {
            // The current-session worker still runs and the durable Outbox is
            // retried on the next normal launch if snapd cannot autostart it.
            warning ("Snap background autostart entry could not be installed: %s",
                failure_message ?? "unknown error");
        }
    }

    internal static bool install_snap_autostart_entry_for_paths (
        string snap_root, string snap_user_data, out string? failure_message) {
        failure_message = null;
        var source = File.new_for_path (Path.build_filename (snap_root, "etc", "xdg",
            "autostart", "com.local.Mailficient.Background.desktop"));
        var destination_directory = File.new_for_path (Path.build_filename (
            snap_user_data, ".config", "autostart"));
        var destination = destination_directory.get_child (
            "com.local.Mailficient.Background.desktop");
        try {
            destination_directory.make_directory_with_parents (null);
        } catch (IOError.EXISTS error) {
            // The per-revision autostart directory is already ready.
        } catch (Error error) {
            failure_message = error.message;
            return false;
        }
        try {
            source.copy (destination, FileCopyFlags.OVERWRITE, null, null);
            destination.set_attribute_uint32 (FileAttribute.UNIX_MODE, 0600,
                FileQueryInfoFlags.NONE, null);
            return true;
        } catch (Error error) {
            failure_message = error.message;
            return false;
        }
    }

    private void launch_worker () {
        if (worker != null) return;
        try {
            string[] commandline = { "mailficient", "--background" };
            var process = new Subprocess.newv (commandline,
                SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_SILENCE);
            worker = process;
            watch_worker.begin (process);
        } catch (Error error) {
            warning ("Background delivery worker could not be started: %s", error.message);
        }
    }

    private async void watch_worker (Subprocess process) {
        try {
            yield process.wait_async ();
        } catch (Error error) {
            warning ("Background delivery worker could not be monitored: %s", error.message);
        }
        if (worker == process) worker = null;
    }

    internal static bool response_allows_background (uint32 response_code, Variant results) {
        if (response_code != 0) return false;
        Variant? allowed = results.lookup_value ("background", VariantType.BOOLEAN);
        return allowed != null && allowed.get_boolean ();
    }

    internal static bool is_flatpak () {
        string? flatpak_id = Environment.get_variable ("FLATPAK_ID");
        return flatpak_id != null && flatpak_id != "";
    }

    internal static bool is_snap () {
        return is_snap_environment (Environment.get_variable ("SNAP"),
            Environment.get_variable ("SNAP_USER_DATA"));
    }

    internal static bool is_snap_environment (string? snap,
                                               string? snap_user_data) {
        return snap != null && snap != "" &&
            snap_user_data != null && snap_user_data != "";
    }
}
}
