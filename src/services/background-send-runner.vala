namespace Mailficient {
// A session-bus name is an OS-released process lease: it prevents an autostart
// worker and a manually launched one-shot from opening the same Camel cache at
// once, without leaving a stale lock after a crash.
[DBus (name = "org.freedesktop.DBus")]
private interface SessionBusDaemon : Object {
    public abstract uint request_name (string name, uint flags) throws Error;
}

private class BackgroundProcessLease : Object {
    private SessionBusDaemon daemon;

    private BackgroundProcessLease (SessionBusDaemon daemon) {
        this.daemon = daemon;
    }

    public static BackgroundProcessLease? try_acquire () throws Error {
        var daemon = Bus.get_proxy_sync<SessionBusDaemon> (BusType.SESSION,
            "org.freedesktop.DBus", "/org/freedesktop/DBus");
        // DO_NOT_QUEUE: another worker will run its next pass within 30s.
        uint result = daemon.request_name ("com.local.Mailficient.BackgroundWorker", 4);
        if (result != 1 && result != 4) return null;
        return new BackgroundProcessLease (daemon);
    }
}

public class BackgroundSendRunner : Object {
    public const uint POLL_SECONDS = 30;
    private CacheDatabase cache;
    private CredentialStore credentials;
    private OnlineAccountService online_accounts;
    private AttachmentService attachments;
    private MailEngine? engine;
    private OutboundService outbound;
    private DraftSyncService? draft_sync;
    private bool pass_active;
    private BackgroundProcessLease lease;

    private BackgroundSendRunner (BackgroundProcessLease lease) throws Error {
        this.lease = lease;
        string directory = LocalDataMigration.prepare (Environment.get_user_data_dir ());
        cache = new CacheDatabase (Path.build_filename (directory, "mail.db"));
        credentials = new LibsecretCredentialStore ();
        online_accounts = new GnomeOnlineAccountService ();
        attachments = new AttachmentService (Path.build_filename (directory, "attachments"));
#if HAVE_CAMEL
        var camel_engine = new CamelMailEngine (credentials,
            background_path (directory, "camel-data"),
            background_path (directory, "camel-cache-v3"),
            background_path (directory, "received-attachments"), online_accounts);
        engine = camel_engine;
        draft_sync = new DraftSyncService (cache, camel_engine, attachments);
#endif
        outbound = new OutboundService (cache, engine, attachments);
    }

    public static int run_once_command () {
        try {
            var lease = BackgroundProcessLease.try_acquire ();
            if (lease == null) return 0;
            var runner = new BackgroundSendRunner (lease);
            var loop = new MainLoop ();
            Error? failure = null;
            runner.run_once.begin (null, (object, result) => {
                try { runner.run_once.end (result); }
                catch (Error error) { failure = error; }
                loop.quit ();
            });
            loop.run ();
            if (failure != null) {
                warning ("Background mail delivery failed: %s", failure.message);
                return 1;
            }
            return 0;
        } catch (Error error) {
            warning ("Background mail delivery could not start: %s", error.message);
            return 1;
        }
    }

    public static int run_resident_command () {
        try {
            var lease = BackgroundProcessLease.try_acquire ();
            if (lease == null) return 0;
            var runner = new BackgroundSendRunner (lease);
            var loop = new MainLoop ();
            runner.kick ();
            Timeout.add_seconds (POLL_SECONDS, () => {
                runner.kick ();
                return Source.CONTINUE;
            });
            NetworkMonitor.get_default ().network_changed.connect ((available) => {
                if (available) runner.kick ();
            });
            loop.run ();
            return 0;
        } catch (Error error) {
            warning ("Background mail service could not start: %s", error.message);
            return 1;
        }
    }

    internal static string background_path (string data_directory, string leaf) {
        return Path.build_filename (data_directory, "background", leaf);
    }

    private void kick () {
        if (pass_active || !NetworkMonitor.get_default ().network_available) return;
        pass_active = true;
        run_once.begin (null, (object, result) => {
            try { run_once.end (result); }
            catch (Error error) { warning ("Background mail pass failed: %s", error.message); }
            pass_active = false;
        });
    }

    public async void run_once (Cancellable? cancellable = null) throws Error {
        if (engine == null)
            throw new MailError.CONNECTION ("This build has no IMAP/SMTP backend");
        Error? first_error = null;
        foreach (var account in cache.list_accounts ()) {
            if (cancellable != null) cancellable.set_error_if_cancelled ();
            try {
                // Outbox goes first so a temporarily unavailable IMAP Drafts
                // folder cannot delay a due SMTP delivery.
                yield outbound.retry_pending (account.id, true, cancellable);
                if (draft_sync != null && cache.has_pending_remote_draft_work (account.id)) {
                    yield engine.connect_incoming_account (account, cancellable);
                    yield draft_sync.synchronize_account (account.id, cancellable);
                }
            } catch (Error error) {
                if (first_error == null) first_error = error;
                warning ("Background work for account %s failed: %s", account.id, error.message);
            } finally {
                try { yield engine.disconnect_account (account.id, cancellable); }
                catch (Error error) {
                    if (first_error == null) first_error = error;
                }
            }
        }
        if (first_error != null) throw first_error;
    }
}
}
