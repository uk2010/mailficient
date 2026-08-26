namespace Mailficient {
internal class DecodedMimeContent : Object {
    public Camel.DataWrapper content { get; construct; }
    public string status { get; construct; }
    public DecodedMimeContent (Camel.DataWrapper content, string status = "") {
        Object (content: content, status: status);
    }
}

internal class ConvertedCamelMessage : Object {
    public Message message { get; construct; }
    public string mime_plain { get; construct; }
    public string mime_html { get; construct; }

    public ConvertedCamelMessage (Message message, string mime_plain, string mime_html) {
        Object (message: message, mime_plain: mime_plain, mime_html: mime_html);
    }
}

internal class FolderDownloadPlan : Object {
    public Mailbox mailbox;
    public Camel.Folder folder;
    public Gee.ArrayList<string> unseen_uids = new Gee.ArrayList<string> ();
    // Provider drafts are mutable even when their IMAP UID does not change.
    // Re-read cached Drafts messages after genuinely new mail so an edit made
    // by another client is reconciled by its content fingerprint.
    public Gee.ArrayList<string> draft_refresh_uids = new Gee.ArrayList<string> ();

    public FolderDownloadPlan (Mailbox mailbox, Camel.Folder folder) {
        this.mailbox = mailbox; this.folder = folder;
    }
}

// A Drafts message can change in place while keeping the same IMAP UID. The
// MIME cap therefore applies to both new mail and cached-draft revalidation.
// This tracker carries only UIDs between the fresh Camel sessions used by a
// bounded account check, so every cached draft converges instead of repeatedly
// selecting the first 250.
internal class DraftRefreshTracker : Object {
    private Gee.HashMap<string, Gee.HashSet<string>> remaining =
        new Gee.HashMap<string, Gee.HashSet<string>> ();

    public Gee.ArrayList<string> plan (string mailbox_id,
                                       Gee.Iterable<string> current_cached_uids) {
        var ordered = new Gee.ArrayList<string> ();
        var current = new Gee.HashSet<string> ();
        foreach (var uid in current_cached_uids) {
            if (current.add (uid)) ordered.add (uid);
        }
        var pending = remaining[mailbox_id];
        if (pending == null) {
            if (ordered.size == 0) return ordered;
            pending = new Gee.HashSet<string> ();
            pending.add_all (ordered);
            remaining[mailbox_id] = pending;
        } else {
            var removed = new Gee.ArrayList<string> ();
            foreach (var uid in pending)
                if (!current.contains (uid)) removed.add (uid);
            foreach (var uid in removed) pending.remove (uid);
            if (pending.size == 0) {
                remaining.unset (mailbox_id);
                return new Gee.ArrayList<string> ();
            }
        }
        var result = new Gee.ArrayList<string> ();
        foreach (var uid in ordered)
            if (pending.contains (uid)) result.add (uid);
        return result;
    }

    public void complete (string mailbox_id, string uid) {
        var pending = remaining[mailbox_id];
        if (pending == null) return;
        pending.remove (uid);
        if (pending.size == 0) remaining.unset (mailbox_id);
    }

    public int remaining_count (string mailbox_id) {
        var pending = remaining[mailbox_id];
        return pending == null ? 0 : pending.size;
    }

    public void retain_account_mailboxes (string account_id,
                                           Gee.Set<string> advertised_drafts) {
        var stale = new Gee.ArrayList<string> ();
        string prefix = account_id + ":";
        foreach (var mailbox_id in remaining.keys)
            if (mailbox_id.has_prefix (prefix) && !advertised_drafts.contains (mailbox_id))
                stale.add (mailbox_id);
        foreach (var mailbox_id in stale) remaining.unset (mailbox_id);
    }
}

internal class PersonalCamelSession : Camel.Session {
    private Gee.HashMap<string, uint> rejected_certificates = new Gee.HashMap<string, uint> ();
    private Gee.HashMap<string, OAuthAccessToken> oauth_tokens = new Gee.HashMap<string, OAuthAccessToken> ();

    public PersonalCamelSession (string data_dir, string cache_dir) {
        Object (user_data_dir: data_dir, user_cache_dir: cache_dir, online: true);
    }

    internal unowned Camel.FilterDriver? client_filter_driver_for_testing () {
        return null;
    }

    public override unowned Camel.FilterDriver get_filter_driver (string type,
                                                                   Camel.Folder? for_folder) throws Error {
        // Mailficient has no client-side Camel filter rules. Returning an empty
        // driver makes Camel treat every new Inbox UID as filtering work: it
        // freezes the folder, stops the original changed signal, and later
        // owns/unrefs the driver from a worker. Null skips that unnecessary
        // interception so the live Inbox observer receives the provider event.
        return client_filter_driver_for_testing ();
    }

    public override string get_password (Camel.Service service, string prompt, string item, uint32 flags) throws Error {
        return service.dup_password ();
    }

    public override bool get_oauth2_access_token_sync (Camel.Service service,
                                                        out string? out_access_token,
                                                        out int out_expires_in,
                                                        Cancellable? cancellable = null) throws Error {
        if (cancellable != null) cancellable.set_error_if_cancelled ();
        // Camel's XOAUTH2 SASL implementation deliberately obtains its bearer
        // token through this session vfunc, not through get_password().  The
        // engine puts the freshly issued, short-lived GOA token on the service
        // immediately before connecting; return it without persisting it.
        var token = oauth_tokens[service.get_uid ()];
        out_access_token = token == null ? null : token.value;
        out_expires_in = token == null ? 0 : token.expires_in;
        if (out_access_token == null || out_access_token == "")
            throw new MailError.AUTHENTICATION ("No OAuth access token is available");
        return true;
    }

    public void cache_oauth_token (Camel.Service service, OAuthAccessToken token) {
        oauth_tokens[service.get_uid ()] = token;
    }

    public void clear_oauth_token (Camel.Service service) {
        oauth_tokens.unset (service.get_uid ());
    }

    public override bool forget_password (Camel.Service service, string item) throws Error {
        service.set_password (""); return true;
    }

    public override bool authenticate_sync (Camel.Service service, string? mechanism,
                                             Cancellable? cancellable = null) throws Error {
        // Credentials have already been obtained from libsecret or GOA before
        // a connection starts. Make exactly one provider authentication attempt
        // and convert a clean rejection into Camel's authentication error; the
        // stock CamelSession implementation is a warning-only test stub.
        var result = service.authenticate_sync (mechanism, cancellable);
        if (result == Camel.AuthenticationResult.ACCEPTED) return true;
        if (result == Camel.AuthenticationResult.REJECTED)
            throw new Camel.ServiceError.CANT_AUTHENTICATE ("The mail server rejected the account authorization");
        throw new Camel.ServiceError.CANT_AUTHENTICATE ("The mail server could not verify the account authorization");
    }

    public override Camel.CertTrust trust_prompt (Camel.Service service, TlsCertificate certificate, TlsCertificateFlags errors) {
        // Camel reports certificate validation through this callback before the
        // connection attempt itself fails. Preserve the reason long enough for
        // the account engine to convert an otherwise generic service error into
        // an actionable TLS warning. Returning UNKNOWN deliberately provides no
        // insecure click-through or permanent trust exception.
        rejected_certificates[service.get_uid ()] = (uint) errors;
        return Camel.CertTrust.UNKNOWN;
    }

    public void clear_rejected_certificate (string service_uid) {
        rejected_certificates.unset (service_uid);
    }

    public bool take_rejected_certificate (string service_uid, out uint errors) {
        if (!rejected_certificates.has_key (service_uid)) {
            errors = 0;
            return false;
        }
        errors = rejected_certificates[service_uid];
        rejected_certificates.unset (service_uid);
        return true;
    }
}

public class CamelMailEngine : Object, MailEngine, RemoteMailSearchProvider {
    private const int64 MAX_RECEIVED_MESSAGE_ATTACHMENT_BYTES = 100 * 1024 * 1024;
    private const int64 MAX_EXPLICIT_ATTACHMENT_DOWNLOAD_BYTES = (int64) 2 * 1024 * 1024 * 1024;
    internal const int64 MAX_RECEIVED_TEXT_PART_BYTES = 10 * 1024 * 1024;
    internal const int MAX_MESSAGES_PER_SYNC_SESSION = 250;
    // Message bodies are streamed in small batches and the main context is
    // yielded between downloads, so a large mailbox does not monopolize GTK
    // or require building one giant in-memory result.
    internal const int SYNC_BATCH_SIZE = 5;
    internal const int UID_SCAN_YIELD_INTERVAL = 50;
    private signal void account_connection_finished (string account_id);
    private static bool camel_initialized;
    private PersonalCamelSession session;
    private CredentialStore credentials;
    private OnlineAccountService online_accounts;
    private Gee.HashMap<string, Camel.Store> stores = new Gee.HashMap<string, Camel.Store> ();
    private Gee.HashMap<string, Camel.Transport> transports = new Gee.HashMap<string, Camel.Transport> ();
    private Gee.HashMap<string, CamelLiveMailWatch> live_watches =
        new Gee.HashMap<string, CamelLiveMailWatch> ();
    private Gee.HashMap<string, AccountSettings> accounts = new Gee.HashMap<string, AccountSettings> ();
    private Gee.HashMap<string, SyncState> states = new Gee.HashMap<string, SyncState> ();
    private Gee.HashSet<string> connecting_accounts = new Gee.HashSet<string> ();
    private Gee.HashMap<string, Cancellable> connection_cancellables = new Gee.HashMap<string, Cancellable> ();
    private Gee.HashMap<string, bool> connection_requirements = new Gee.HashMap<string, bool> ();
    private ReceivedAttachmentStore received_attachments;
    private DraftRefreshTracker draft_refreshes = new DraftRefreshTracker ();

    public CamelMailEngine (CredentialStore credentials, string data_dir, string cache_dir,
                            string received_attachment_dir,
                            OnlineAccountService? online_accounts = null) {
        this.credentials = credentials;
        this.online_accounts = online_accounts ?? new GnomeOnlineAccountService ();
        received_attachments = new ReceivedAttachmentStore (received_attachment_dir);
        if (!camel_initialized) {
            string certificate_dir = Path.build_filename (data_dir, "certificates");
            DirUtils.create_with_parents (certificate_dir, 0700);
            if (Camel.init (certificate_dir, true) != 0)
                warning ("Camel initialization reported a failure");
            else {
                Camel.Provider.init ();
                camel_initialized = true;
            }
        }
        session = new PersonalCamelSession (data_dir, cache_dir);
    }

    // Narrow injection seam for the separately built loopback GreenMail test.
    // Production always uses the rejecting PersonalCamelSession above.
    internal void replace_session_for_testing (PersonalCamelSession replacement) {
        assert (stores.size == 0 && transports.size == 0 && connecting_accounts.size == 0);
        session = replacement;
    }

    public SyncState state_for (string account_id) {
        if (!states.has_key (account_id)) states[account_id] = new SyncState ();
        return states[account_id];
    }

    public async void connect_account (AccountSettings settings, Cancellable? cancellable = null) throws Error {
        yield ensure_account_connection (settings, true, cancellable);
    }

    public async void connect_incoming_account (AccountSettings settings,
                                                 Cancellable? cancellable = null) throws Error {
        yield ensure_account_connection (settings, false, cancellable);
    }

    private async void ensure_account_connection (AccountSettings settings, bool require_transport,
                                                   Cancellable? cancellable) throws Error {
        settings.validate ();
        if (connection_satisfies (settings.id, require_transport)) {
            var connected_store = stores[settings.id];
            if (connected_store != null)
                yield ensure_live_watch (settings.id, connected_store, cancellable);
            return;
        }
        if (connecting_accounts.contains (settings.id)) {
            bool owner_requires_transport = connection_requirements.has_key (settings.id) &&
                connection_requirements[settings.id];
            ulong handler_id = 0;
            handler_id = account_connection_finished.connect ((finished_id) => {
                if (finished_id != settings.id) return;
                disconnect (handler_id); ensure_account_connection.callback ();
            });
            yield;
            if (cancellable != null) cancellable.set_error_if_cancelled ();
            if (connection_satisfies (settings.id, require_transport)) {
                var connected_store = stores[settings.id];
                if (connected_store != null)
                    yield ensure_live_watch (settings.id, connected_store, cancellable);
                return;
            }
            // An incoming-only caller may have won the connection race while
            // this caller still needs SMTP. Continue with the missing half.
            if (!require_transport || owner_requires_transport)
                throw new MailError.CONNECTION (state_for (settings.id).detail);
            yield ensure_account_connection (settings, require_transport, cancellable);
            return;
        }
        connecting_accounts.add (settings.id);
        var attempt_cancellable = new Cancellable ();
        connection_cancellables[settings.id] = attempt_cancellable;
        connection_requirements[settings.id] = require_transport;
        ulong cancellation_handler = 0;
        if (cancellable != null) {
            cancellation_handler = cancellable.cancelled.connect (() => attempt_cancellable.cancel ());
            if (cancellable.is_cancelled ()) attempt_cancellable.cancel ();
        }
        try {
            yield establish_account_connection (settings, attempt_cancellable, require_transport);
        } finally {
            if (cancellable != null && cancellation_handler != 0)
                cancellable.disconnect (cancellation_handler);
            connection_cancellables.unset (settings.id);
            connecting_accounts.remove (settings.id);
            account_connection_finished (settings.id);
            connection_requirements.unset (settings.id);
        }
    }

    private bool incoming_service_is_connected (string account_id) {
        var store = stores[account_id];
        return store != null && store.get_connection_status () == Camel.ServiceConnectionStatus.CONNECTED;
    }

    private bool connection_satisfies (string account_id, bool require_transport) {
        if (!incoming_service_is_connected (account_id)) return false;
        if (!require_transport) return true;
        var transport = transports[account_id];
        return transport != null &&
            transport.get_connection_status () == Camel.ServiceConnectionStatus.CONNECTED;
    }

    private async void establish_account_connection (AccountSettings settings,
                                                      Cancellable? cancellable,
                                                      bool require_transport) throws Error {
        var state = state_for (settings.id); state.phase = SyncPhase.CONNECTING;
        state.detail = "Connecting securely…"; state.progress = 0;
        Camel.Store? store = stores[settings.id];
        Camel.Transport? transport = transports[settings.id];
        try {
            // Keep the IMAP service and its summaries alive between checks. A
            // missing service is the only case that requires a new Camel
            // object; a disconnected service can reconnect in place.
            if (store == null) {
                store = (Camel.Store) session.add_service (settings.id + "-imap", "imapx", Camel.ProviderType.STORE);
            }
            configure_network (store, settings.incoming_host, settings.incoming_port,
                settings.incoming_username, settings.incoming_encryption,
                settings.authentication, true);
            // IMAPX reads this setting when its connection manager comes
            // online. Set it before the first connection as well as when the
            // Inbox watch is attached.
            CamelLiveMailWatch.enable_idle (store);
            session.clear_rejected_certificate (store.get_uid ());
            string? incoming_password;
            OAuthAccessToken? incoming_oauth = null;
            if (settings.authentication == AuthenticationMode.GNOME_ONLINE_ACCOUNTS) {
                incoming_oauth = yield online_accounts.request_access_token (settings.online_account_path, cancellable);
                incoming_password = incoming_oauth.value;
            } else
                incoming_password = yield credentials.lookup_password (settings.id, "imap", cancellable);
            if (incoming_password == null) throw new MailError.AUTHENTICATION ("No incoming-mail credential is stored");
            store.set_password (incoming_password);
            if (settings.authentication == AuthenticationMode.GNOME_ONLINE_ACCOUNTS)
                session.cache_oauth_token (store, incoming_oauth);
            var offline_store = store as Camel.OfflineStore;
            if (offline_store != null && !offline_store.get_online ()) {
                // IMAPX is an OfflineStore and starts in offline mode even when
                // its owning Camel session is online. Merely calling connect()
                // leaves it offline and fails immediately without touching the
                // server. Transitioning it online is the supported operation;
                // it establishes the underlying connection as part of the move.
                bool online = yield offline_store.set_online (true, Priority.DEFAULT, cancellable);
                if (!online) throw new MailError.CONNECTION ("The incoming-mail service could not go online");
            } else if (store.get_connection_status () != Camel.ServiceConnectionStatus.CONNECTED) {
                bool connected = yield store.connect (Priority.DEFAULT, cancellable);
                if (!connected) throw new MailError.CONNECTION ("The incoming-mail server rejected the connection");
            }

            if (require_transport) {
                if (transport == null)
                    transport = (Camel.Transport) session.add_service (settings.id + "-smtp", "smtp", Camel.ProviderType.TRANSPORT);
                configure_network (transport, settings.outgoing_host, settings.outgoing_port,
                    settings.outgoing_username, settings.outgoing_encryption,
                    settings.authentication, false);
                session.clear_rejected_certificate (transport.get_uid ());
                string? outgoing_password;
                if (settings.authentication == AuthenticationMode.GNOME_ONLINE_ACCOUNTS)
                    outgoing_password = incoming_password;
                else {
                    outgoing_password = yield credentials.lookup_password (settings.id, "smtp", cancellable);
                    if (outgoing_password == null) outgoing_password = incoming_password;
                }
                transport.set_password (outgoing_password);
                if (settings.authentication == AuthenticationMode.GNOME_ONLINE_ACCOUNTS)
                    session.cache_oauth_token (transport, incoming_oauth);
                if (transport.get_connection_status () != Camel.ServiceConnectionStatus.CONNECTED) {
                    bool connected = yield transport.connect (Priority.DEFAULT, cancellable);
                    if (!connected) throw new MailError.CONNECTION ("The outgoing-mail server rejected the connection");
                }
            }

            yield ensure_live_watch (settings.id, store, cancellable);
            stores[settings.id] = store;
            if (transport != null) transports[settings.id] = transport;
            accounts[settings.id] = settings;
            state.phase = SyncPhase.IDLE; state.detail = "Connected"; state.progress = 1;
        } catch (Error error) {
            // Camel registers services with the session before connecting them. A
            // failed test must remove both partial services or a corrected retry
            // can collide with their stable UIDs.
            detach_live_watch (settings.id);
            if (transport != null) {
                session.clear_oauth_token (transport);
                try { yield transport.disconnect (false, Priority.DEFAULT, cancellable); } catch (Error ignored) { }
                session.remove_service (transport);
            }
            if (store != null) {
                session.clear_oauth_token (store);
                try { yield store.disconnect (false, Priority.DEFAULT, cancellable); } catch (Error ignored) { }
                session.remove_service (store);
            }
            transports.unset (settings.id); stores.unset (settings.id); accounts.unset (settings.id);
            uint certificate_errors = 0;
            string? certificate_host = null;
            uint service_certificate_errors = 0;
            if (store != null && session.take_rejected_certificate (store.get_uid (), out service_certificate_errors)) {
                certificate_errors |= service_certificate_errors;
                certificate_host = settings.incoming_host;
            }
            if (transport != null && session.take_rejected_certificate (transport.get_uid (), out service_certificate_errors)) {
                certificate_errors |= service_certificate_errors;
                certificate_host = settings.outgoing_host;
            }
            Error normalized = certificate_host == null ? normalize_error (error) :
                new MailError.TLS (certificate_failure_detail (certificate_host, (TlsCertificateFlags) certificate_errors));
            state.phase = SyncPhase.FAILED; state.detail = normalized.message; throw normalized;
        }
    }

    internal static string certificate_failure_detail (string host, TlsCertificateFlags errors) {
        var reasons = new Gee.ArrayList<string> ();
        if ((errors & TlsCertificateFlags.UNKNOWN_CA) != 0) reasons.add ("its issuer is not trusted");
        if ((errors & TlsCertificateFlags.BAD_IDENTITY) != 0) reasons.add ("it does not match the server name");
        if ((errors & TlsCertificateFlags.NOT_ACTIVATED) != 0) reasons.add ("it is not valid yet");
        if ((errors & TlsCertificateFlags.EXPIRED) != 0) reasons.add ("it has expired");
        if ((errors & TlsCertificateFlags.REVOKED) != 0) reasons.add ("it has been revoked");
        if ((errors & TlsCertificateFlags.INSECURE) != 0) reasons.add ("it uses an insecure algorithm");
        if ((errors & TlsCertificateFlags.GENERIC_ERROR) != 0) reasons.add ("certificate validation failed");
        var joined = new StringBuilder ();
        foreach (var item in reasons) {
            if (joined.len > 0) joined.append (", ");
            joined.append (item);
        }
        string reason = joined.len == 0 ? "certificate validation failed" : joined.str;
        return "The certificate presented by %s was rejected because %s.".printf (host, reason);
    }

    public async void disconnect_account (string account_id, Cancellable? cancellable = null) throws Error {
        if (connecting_accounts.contains (account_id)) {
            var pending = connection_cancellables[account_id];
            if (pending != null) pending.cancel ();
            ulong handler_id = 0;
            handler_id = account_connection_finished.connect ((finished_id) => {
                if (finished_id != account_id) return;
                disconnect (handler_id); disconnect_account.callback ();
            });
            yield;
        }
        if (cancellable != null) cancellable.set_error_if_cancelled ();
        // Detach first so an intentional service removal cannot be mistaken for
        // a dropped IDLE connection and schedule a reconnect behind the caller.
        detach_live_watch (account_id);
        var transport = transports[account_id];
        if (transport != null) {
            session.clear_oauth_token (transport);
            // Removing the service closes its socket without waiting for a
            // provider logout round-trip. Gmail can leave Camel's disconnect
            // operation pending indefinitely after successful OAuth login.
            session.remove_service (transport);
        }
        var store = stores[account_id];
        if (store != null) {
            session.clear_oauth_token (store);
            session.remove_service (store);
        }
        transports.unset (account_id); stores.unset (account_id);
        accounts.unset (account_id); states.unset (account_id);
    }

    private async void ensure_live_watch (string account_id, Camel.Store store,
                                          Cancellable? cancellable) throws Error {
        if (live_watches.has_key (account_id)) return;
        try {
            var watch = yield CamelLiveMailWatch.create (account_id, store, cancellable);
            // A second caller may have finished while this Inbox was opening.
            if (live_watches.has_key (account_id)) {
                watch.detach ();
                return;
            }
            weak CamelMailEngine weak_engine = this;
            watch.mail_changed.connect (() => {
                if (weak_engine != null) weak_engine.live_mail_changed (account_id);
            });
            watch.unavailable.connect (() => {
                if (weak_engine != null) weak_engine.live_mail_unavailable (account_id);
            });
            live_watches[account_id] = watch;
        } catch (Error error) {
            if (error is IOError.CANCELLED) throw error;
            // Opening a push watch is optional. The regular configured mail
            // interval remains active and a bounded reconnect attempt will try
            // to install the watch again without making this connection fail.
            warning ("Live mail is unavailable for account %s: %s", account_id, error.message);
            live_mail_unavailable (account_id);
        }
    }

    private void detach_live_watch (string account_id) {
        var watch = live_watches[account_id];
        if (watch != null) watch.detach ();
        live_watches.unset (account_id);
    }

    private static void configure_network (Camel.Service service, string host, uint port, string user,
                                           EncryptionMode encryption, AuthenticationMode authentication,
                                           bool incoming) throws MailError {
        var network = service.ref_settings () as Camel.NetworkSettings;
        if (network == null) throw new MailError.CONNECTION ("The selected Camel provider has no network settings");
        network.set_host (host); network.set_port ((uint16) port); network.set_user (user);
        network.set_security_method (encryption == EncryptionMode.TLS ? Camel.NetworkSecurityMethod.SSL_ON_ALTERNATE_PORT : Camel.NetworkSecurityMethod.STARTTLS_ON_STANDARD_PORT);
        network.set_auth_mechanism (authentication_mechanism (authentication, incoming));
    }

    internal static string? authentication_mechanism (AuthenticationMode authentication,
                                                       bool incoming = false) {
        // A null SMTP mechanism means "do not authenticate" to Camel. That can
        // make connection testing appear successful while MAIL FROM is rejected
        // later, so SMTP password accounts explicitly use SASL PLAIN inside the
        // configured TLS/STARTTLS channel. IMAP authentication is mandatory;
        // leaving its mechanism automatic allows both protocol LOGIN and SASL
        // PLAIN providers. Brokered accounts always use explicit OAuth.
        if (authentication == AuthenticationMode.GNOME_ONLINE_ACCOUNTS) return "XOAUTH2";
        return incoming ? null : "PLAIN";
    }

#if EDS_LEGACY
    [CCode (cname = "camel_folder_search_free", cheader_filename = "camel/camel.h")]
    private static extern void free_legacy_search_results (
        Camel.Folder folder, owned GenericArray<string> results);
#endif

    // Camel changed its folder-search ownership contract in EDS 3.58. Copy
    // provider-owned/pstring UIDs into normal strings before any async work,
    // then release the legacy result through Camel's required search_free
    // vfunc. Modern EDS transfers only the nullable result container.
    private static Gee.ArrayList<string> search_folder_uids (
        Camel.Folder folder, string expression,
        Cancellable? cancellable = null) throws Error {
        var copied = new Gee.ArrayList<string> ();
#if EDS_LEGACY
        var matches = folder.search_by_expression (expression, cancellable);
        for (uint index = 0; index < matches.length; index++)
            copied.add (matches[index]);
        free_legacy_search_results (folder, (owned) matches);
#else
        GenericArray<weak string>? matches = null;
        if (!folder.search_sync (expression, out matches, cancellable))
            throw new MailError.CONNECTION ("The server could not complete this search");
        if (matches != null)
            for (uint index = 0; index < matches.length; index++)
                copied.add (matches[index]);
#endif
        return copied;
    }

    public async Gee.List<Message> search_remote (Mailbox mailbox, string expression,
                                                   int limit,
                                                   Cancellable? cancellable = null) throws Error {
        var store = stores[mailbox.account_id];
        if (store == null) throw new MailError.CONNECTION ("Connect this account before searching the server");
        int bounded_limit = int.max (1, int.min (200, limit));
        try {
            var folder = yield store.get_folder (mailbox.remote_name,
                Camel.StoreGetFolderFlags.NONE, Priority.DEFAULT, cancellable);
            if (folder == null) throw new MailError.CONNECTION ("The selected search folder is unavailable");
            yield folder.refresh_info (Priority.DEFAULT, cancellable);
            var matches = search_folder_uids (folder, expression, cancellable);
            var result = new Gee.ArrayList<Message> ();
            // IMAP providers normally return UID order. Read from the newest
            // end and enforce a hard MIME-download cap for interactive search.
            for (int index = matches.size - 1; index >= 0 && result.size < bounded_limit; index--) {
                if (cancellable != null) cancellable.set_error_if_cancelled ();
                string uid = matches[index]; if (uid == "") continue;
                var info = folder.get_message_info (uid); if (info == null) continue;
                var mime = yield folder.get_message (uid, Priority.DEFAULT, cancellable);
                if (mime == null) continue;
                var converted = yield message_from_camel (mailbox.account_id, mailbox, uid,
                    info, mime, cancellable);
                result.add (converted.message);
            }
            return result;
        } catch (Error error) { throw normalize_error (error); }
    }

    public async MailSyncResult synchronize (string account_id, Gee.Set<string>? cached_message_ids = null,
                                              Cancellable? cancellable = null) throws Error {
        var store = stores[account_id]; if (store == null) throw new MailError.CONNECTION ("The account is not connected");
        var state = state_for (account_id); state.phase = SyncPhase.SYNCHRONIZING;
        state.messages_to_download = 0; state.messages_downloaded = 0;
        state.detail = "Checking messages…"; state.progress = 0.02;
        try {
            var result = new MailSyncResult (account_id);
            var root = yield store.get_folder_info (null,
                Camel.StoreGetFolderInfoFlags.RECURSIVE | Camel.StoreGetFolderInfoFlags.SUBSCRIBED | Camel.StoreGetFolderInfoFlags.REFRESH,
                Priority.DEFAULT, cancellable);
            collect_mailboxes (root, account_id, result.mailboxes);
            result.folder_inventory_complete = true;
            var advertised_drafts = new Gee.HashSet<string> ();
            foreach (var mailbox in result.mailboxes)
                if (mailbox.role == MailboxRole.DRAFTS) advertised_drafts.add (mailbox.id);
            draft_refreshes.retain_account_mailboxes (account_id, advertised_drafts);
            // Publish the folder tree immediately. Message batches below then
            // become visible without waiting for every subscribed folder.
            var inventory = new MailSyncResult (account_id);
            inventory.folder_inventory_complete = true;
            inventory.mailboxes.add_all (result.mailboxes);
            sync_batch_ready (inventory);
            int folder_index = 0;
            int folder_total = int.max (1, result.mailboxes.size);
            int total_unseen = 0;
            var plans = new Gee.ArrayList<FolderDownloadPlan> ();

            // Inventory every subscribed folder before retrieving any MIME
            // content. This gives the UI a real total before the first message
            // download and keeps folder scanning separate from MIME work.
            foreach (var mailbox in result.mailboxes) {
                if (cancellable != null) cancellable.set_error_if_cancelled ();
                state.detail = "Checking messages…";
                state.progress = 0.03 + (0.17 * folder_index / folder_total);
                try {
                    var folder = yield store.get_folder (mailbox.remote_name,
                        Camel.StoreGetFolderFlags.NONE, Priority.DEFAULT, cancellable);
                    if (folder == null)
                        throw new MailError.CONNECTION ("The folder is not currently available");
                    // can_refresh_folder() answers whether a folder should be
                    // polled for new-mail notifications; Camel's default is
                    // Inbox-only. A full sync must refresh every selectable
                    // folder so Junk, Trash, and custom folders expose their
                    // current UID lists too.
                    yield folder.refresh_info (Priority.DEFAULT, cancellable);
#if EDS_LEGACY
                    var uids = folder.get_uids ();
#else
                    var uids = folder.dup_uids ();
#endif
                    var plan = new FolderDownloadPlan (mailbox, folder);
                    result.begin_remote_inventory (mailbox.id);
                    int unread_count = 0;
                    for (int index = 0; index < (int) uids.length; index++) {
                        string uid = uids[index];
                        string message_id = "%s:%s".printf (mailbox.id, uid);
                        var info = folder.get_message_info (uid);
                        if (info == null) continue;
                        uint32 flags = info.get_flags ();
                        // Draft cleanup uses a precise \Deleted flag without a
                        // folder-wide expunge. Treat those copies as absent so
                        // they cannot be re-imported while awaiting server purge.
                        if ((flags & Camel.MessageFlags.DELETED) != 0) continue;
                        result.record_remote_uid (mailbox.id, uid);
                        if ((flags & Camel.MessageFlags.SEEN) == 0)
                            unread_count++;
                        if (cached_message_ids != null && cached_message_ids.contains (message_id)) {
                            result.states.add (new RemoteMessageState (message_id,
                                (flags & Camel.MessageFlags.SEEN) == 0,
                                (flags & Camel.MessageFlags.FLAGGED) != 0));
                            if (mailbox.role == MailboxRole.DRAFTS)
                                plan.draft_refresh_uids.add (uid);
                        } else plan.unseen_uids.add (uid);
                        // Camel's folder summary traversal is synchronous. Give
                        // GTK a chance to paint and dispatch input on large folders.
                        if ((index + 1) % UID_SCAN_YIELD_INTERVAL == 0)
                            yield yield_to_main_context (cancellable);
                    }
                    // FolderInfo is read before refresh_info() and can still
                    // contain the previous unread total. We have just scanned
                    // every refreshed message summary, so use that authoritative
                    // count for this sync pass. Otherwise the sidebar catches
                    // up only on the following mail check.
                    mailbox.unread_count = (uint) unread_count;
                    if (mailbox.role == MailboxRole.DRAFTS) {
                        var tracked = draft_refreshes.plan (
                            mailbox.id, plan.draft_refresh_uids);
                        plan.draft_refresh_uids.clear ();
                        plan.draft_refresh_uids.add_all (tracked);
                    }
                    total_unseen += plan.unseen_uids.size;
                    plans.add (plan);
                } catch (Error folder_error) {
                    if (folder_error is IOError.CANCELLED) throw folder_error;
                    var normalized = normalize_error (folder_error);
                    result.record_issue (mailbox.name, normalized);
                    if (normalized is MailError.AUTHENTICATION || normalized is MailError.TLS ||
                        normalized is MailError.OFFLINE || normalized is MailError.TIMEOUT ||
                        normalized is MailError.RATE_LIMITED ||
                        (normalized is MailError.CONNECTION &&
                         store.get_connection_status () != Camel.ServiceConnectionStatus.CONNECTED)) {
                        result.terminal_error = normalized;
                        break;
                    }
                }
                folder_index++;
                state.progress = 0.03 + (0.17 * folder_index / folder_total);
            }

            int refreshable_drafts = 0;
            foreach (var plan in plans)
                refreshable_drafts += plan.draft_refresh_uids.size;
            configure_download_budget (result, total_unseen);
            int download_target = int.min (MAX_MESSAGES_PER_SYNC_SESSION,
                total_unseen + refreshable_drafts);
            state.messages_to_download = total_unseen;
            state.messages_downloaded = 0;
            state.detail = total_unseen == 0 ? "Mail is up to date" :
                "Downloaded 0 of %d messages".printf (total_unseen);
            state.progress = total_unseen == 0 ? 0.95 : 0.20;

            int processed = 0;
            int downloaded = 0;
            int maintenance_processed = 0;
            // New messages always consume the account-wide budget first. A
            // second phase uses any remainder to revalidate cached Draft UIDs.
            // This prevents a large Drafts folder from starving Inbox history.
            if (result.terminal_error == null) for (int phase = 0; phase < 2; phase++) {
              foreach (var plan in plans) {
                var candidates = phase == 0 ? plan.unseen_uids : plan.draft_refresh_uids;
                int folder_download_target = bounded_folder_download_count (
                    candidates.size, processed);
                if (folder_download_target == 0) {
                    // An empty folder does not mean the account-wide budget is
                    // exhausted; later folders may still contain work.
                    if (processed >= MAX_MESSAGES_PER_SYNC_SESSION) break;
                    continue;
                }
                var batch = new MailSyncResult (account_id);
                batch.mailboxes.add (plan.mailbox);
                for (int index = 0; index < folder_download_target; index++) {
                    if (cancellable != null) cancellable.set_error_if_cancelled ();
                    string uid = candidates[index];
                    var info = plan.folder.get_message_info (uid);
                    if (info == null) continue;
                    state.detail = "Downloaded %d of %d messages — %s".printf (
                        downloaded, total_unseen, plan.mailbox.name);
                    state.progress = 0.20 + (0.75 * processed / (double) int.max (1, download_target));
                    try {
                        Camel.MimeMessage? mime = yield plan.folder.get_message (
                            uid, Priority.DEFAULT, cancellable);
                        if (mime == null)
                            throw new MailError.CONNECTION ("The server returned an empty message");
                        var conversion = yield message_from_camel (
                            account_id, plan.mailbox, uid, info, mime, cancellable);
                        batch.messages.add (conversion.message);
                        if (plan.mailbox.role == MailboxRole.DRAFTS)
                            batch.remote_drafts.add (remote_draft_from_camel (
                                account_id, plan.mailbox, uid, info, mime, conversion));
                        mime = null;
                        if (phase == 0) downloaded++;
                        else {
                            draft_refreshes.complete (plan.mailbox.id, uid);
                            maintenance_processed++;
                        }
                        state.messages_downloaded = downloaded;
                        state.detail = "Downloaded %d of %d messages — %s".printf (
                            downloaded, total_unseen, plan.mailbox.name);
                        if (batch.messages.size >= SYNC_BATCH_SIZE) {
                            sync_batch_ready (batch);
                            batch = new MailSyncResult (account_id);
                            batch.mailboxes.add (plan.mailbox);
                        }
                    } catch (Error message_error) {
                        if (message_error is IOError.CANCELLED) throw message_error;
                        result.record_issue (plan.mailbox.name, normalize_error (message_error));
                        warning ("Could not cache message metadata for %s/%s: %s",
                            plan.mailbox.remote_name, uid, message_error.message);
                    }
                    processed++;
                    state.progress = 0.20 + (0.75 * processed / (double) int.max (1, download_target));
                    yield yield_to_main_context (cancellable);
                }
                if (batch.messages.size > 0) sync_batch_ready (batch);
              }
            }
            // Failed or temporarily unavailable messages remain outstanding too.
            // AccountSyncService will stop automatic continuation when issues are
            // present, or when a pass makes no progress, avoiding an endless loop.
            int maintenance_remaining = 0;
            foreach (var plan in plans)
                maintenance_remaining += draft_refreshes.remaining_count (plan.mailbox.id);
            result.maintenance_items_processed = maintenance_processed;
            result.maintenance_items_remaining = maintenance_remaining;
            result.more_messages_available = total_unseen > downloaded || maintenance_remaining > 0;
            if (result.terminal_error == null) {
                state.detail = "Finishing mail update…"; state.progress = 0.98;
                try { yield store.synchronize (false, Priority.DEFAULT, cancellable); }
                catch (Error synchronize_error) {
                    if (synchronize_error is IOError.CANCELLED) throw synchronize_error;
                    var normalized = normalize_error (synchronize_error);
                    result.record_issue ("Account", normalized);
                    result.terminal_error = normalized;
                }
            }
            if (result.issues.size == 0) {
                if (result.more_messages_available) {
                    state.phase = SyncPhase.SYNCHRONIZING;
                    state.detail = "Continuing mail download…"; state.progress = 1;
                } else {
                    state.phase = SyncPhase.IDLE; state.detail = "Mail is up to date"; state.progress = 1;
                }
            } else if (result.terminal_error != null) {
                state.phase = SyncPhase.FAILED; state.detail = result.terminal_error.message;
            } else {
                state.phase = SyncPhase.PARTIAL;
                state.detail = "%d mail item%s could not be updated".printf (
                    result.issues.size, result.issues.size == 1 ? "" : "s");
            }
            return result;
        }
        catch (Error error) {
            var normalized = normalize_error (error);
            state.phase = SyncPhase.FAILED; state.detail = normalized.message; throw normalized;
        }
    }

    internal static int configure_download_budget (MailSyncResult result, int total_unseen) {
        int available = int.max (0, total_unseen);
        result.messages_to_download = available;
        int target = int.min (available, MAX_MESSAGES_PER_SYNC_SESSION);
        result.more_messages_available = available > target;
        return target;
    }

    internal static int bounded_folder_download_count (int folder_available, int already_processed) {
        int remaining = int.max (0, MAX_MESSAGES_PER_SYNC_SESSION - int.max (0, already_processed));
        return int.min (int.max (0, folder_available), remaining);
    }

    internal static async void yield_to_main_context (Cancellable? cancellable = null) throws Error {
        Idle.add (() => {
            yield_to_main_context.callback ();
            return Source.REMOVE;
        });
        yield;
        if (cancellable != null) cancellable.set_error_if_cancelled ();
    }

    private static void collect_mailboxes (Camel.FolderInfo? node, string account_id,
                                           Gee.ArrayList<Mailbox> output) {
        for (var current = node; current != null; current = current.next) {
            // Evolution exposes local search/vfolder aliases such as
            // .#evolution/Junk alongside the provider's real server folder.
            // They must not become transfer destinations.
            bool local_virtual = current.full_name != null &&
                current.full_name.has_prefix (".#evolution/");
            if (!local_virtual && (current.flags & Camel.FolderInfoFlags.NOSELECT) == 0) {
                var role = role_for_folder (current.flags, current.display_name, current.full_name);
                var mailbox = new Mailbox (mailbox_id (account_id, current.full_name), current.display_name,
                    icon_for_role (role), role, (uint) int.max (0, current.unread), account_id, current.full_name);
                output.add (mailbox);
            }
            if (current.child != null)
                collect_mailboxes (current.child, account_id, output);
        }
    }

    internal static MailboxRole role_for_folder (Camel.FolderInfoFlags flags,
                                                  string? display_name,
                                                  string? full_name) {
        // Camel stores the folder type in a masked numeric field. The TYPE_*
        // values are not independent flags, so testing them with "!= 0"
        // misclassifies types whose numeric values share bits.
        int folder_type = ((int) flags) & (0x3f << 10);
        if (folder_type == (int) Camel.FolderInfoFlags.TYPE_INBOX) return MailboxRole.INBOX;
        if (folder_type == (int) Camel.FolderInfoFlags.TYPE_DRAFTS) return MailboxRole.DRAFTS;
        if (folder_type == (int) Camel.FolderInfoFlags.TYPE_SENT) return MailboxRole.SENT;
        if (folder_type == (int) Camel.FolderInfoFlags.TYPE_JUNK) return MailboxRole.JUNK;
        if (folder_type == (int) Camel.FolderInfoFlags.TYPE_TRASH) return MailboxRole.TRASH;
        if (folder_type == (int) Camel.FolderInfoFlags.TYPE_ARCHIVE ||
            folder_type == (int) Camel.FolderInfoFlags.TYPE_ALL) return MailboxRole.ARCHIVE;

        // Only infer a role for an otherwise normal folder. Explicit provider
        // types (contacts, calendars, tasks, and so on) remain authoritative.
        if (folder_type != (int) Camel.FolderInfoFlags.TYPE_NORMAL) return MailboxRole.CUSTOM;
        var inferred = role_for_folder_name (display_name);
        if (inferred != MailboxRole.CUSTOM) return inferred;
        return role_for_folder_name (leaf_folder_name (full_name));
    }

    private static MailboxRole role_for_folder_name (string? name) {
        if (name == null) return MailboxRole.CUSTOM;
        string normalized = name.strip ().down ();
        switch (normalized) {
        case "inbox": return MailboxRole.INBOX;
        case "draft":
        case "drafts": return MailboxRole.DRAFTS;
        case "sent":
        case "sent mail":
        case "sent items":
        case "sent messages":
        case "sent email":
        case "sent e-mail": return MailboxRole.SENT;
        case "junk":
        case "junk mail":
        case "junk email":
        case "junk e-mail":
        case "spam":
        case "bulk":
        case "bulk mail": return MailboxRole.JUNK;
        case "trash":
        case "bin":
        case "deleted":
        case "deleted messages":
        case "deleted items": return MailboxRole.TRASH;
        case "archive":
        case "archives":
        case "all messages":
        case "all mail": return MailboxRole.ARCHIVE;
        default: return MailboxRole.CUSTOM;
        }
    }

    private static string? leaf_folder_name (string? full_name) {
        if (full_name == null) return null;
        int separator = int.max (full_name.last_index_of_char ('/'),
            int.max (full_name.last_index_of_char ('\\'), full_name.last_index_of_char ('.')));
        return separator >= 0 ? full_name.substring (separator + 1) : full_name;
    }

    private static string icon_for_role (MailboxRole role) {
        switch (role) {
        case MailboxRole.INBOX: return "mail-inbox-symbolic";
        case MailboxRole.DRAFTS: return "document-edit-symbolic";
        case MailboxRole.SENT: return "mail-sent-symbolic";
        case MailboxRole.JUNK: return "dialog-warning-symbolic";
        case MailboxRole.TRASH: return "user-trash-symbolic";
        case MailboxRole.ARCHIVE: return "package-x-generic-symbolic";
        default: return "folder-symbolic";
        }
    }

    private static string mailbox_id (string account_id, string remote_name) {
        string digest = Checksum.compute_for_string (ChecksumType.SHA256, remote_name);
        return "%s:%s".printf (account_id, digest.substring (0, 20));
    }

    private async ConvertedCamelMessage message_from_camel (
        string account_id, Mailbox mailbox, string uid, Camel.MessageInfo info,
        Camel.MimeMessage mime, Cancellable? cancellable) throws Error {
        string sender_name = "Unknown Sender"; string sender_address = "";
        var from = mime.get_from ();
        if (from != null && from.length () > 0) {
            unowned string? name; unowned string? address;
            if (from.get (0, out name, out address)) {
                sender_address = address ?? "";
                sender_name = name == null || name == "" ? sender_address : name;
            }
        }
        string recipients = "";
        var to = mime.get_recipients (Camel.RECIPIENT_TYPE_TO);
        if (to != null) {
            string? formatted_to = to.format ();
            recipients = formatted_to ?? "";
        }
        string cc_recipients = "";
        var cc = mime.get_recipients (Camel.RECIPIENT_TYPE_CC);
        if (cc != null) {
            // Camel represents a missing/empty address list with a null
            // formatted value even when the list object itself is present.
            // Message fields are deliberately non-null.
            string? formatted_cc = cc.format ();
            cc_recipients = formatted_cc ?? "";
        }
        string bcc_recipients = "";
        var bcc = mime.get_recipients (Camel.RECIPIENT_TYPE_BCC);
        if (bcc != null) bcc_recipients = bcc.format () ?? "";
        string reply_to = "";
        var reply = mime.get_reply_to ();
        if (reply != null) reply_to = reply.format () ?? "";
        string plain = ""; string html = ""; bool attachment = false; int attachment_index = 0;
        int64 remaining_attachment_bytes = MAX_RECEIVED_MESSAGE_ATTACHMENT_BYTES;
        var attachments = new Gee.ArrayList<Attachment> ();
        string message_key = "%s:%s".printf (mailbox.id, uid);
        var decoded = yield decode_secure_content (mime, cancellable);
        extract_content (decoded.content, ref plain, ref html, ref attachment, attachments, message_key,
            ref attachment_index, ref remaining_attachment_bytes, cancellable);
        // Preserve exact MIME bodies before the message-list preview fallback.
        // Provider drafts must never import a generated preview as editable text.
        string exact_mime_plain = plain;
        string exact_mime_html = html;
        string? summary_preview = info.dup_preview ();
        string preview = summary_preview == null ? "" : summary_preview;
        if (plain == "") plain = preview;
        bool remote_content = html.down ().contains ("src=\"http") || html.down ().contains ("src='http") || html.down ().contains ("url(http");
        uint32 flags = info.get_flags ();
        int64 received = info.get_date_received (); if (received <= 0) received = info.get_date_sent ();
        var message = new Message ("%s:%s".printf (mailbox.id, uid), mailbox.id, sender_name, sender_address, recipients,
            mime.get_subject () ?? "(No Subject)", preview, plain, format_timestamp (received),
            (flags & Camel.MessageFlags.SEEN) == 0, (flags & Camel.MessageFlags.FLAGGED) != 0,
            attachment || mime.has_attachment (), 1, remote_content, account_id, uid, mime.get_message_id () ?? "",
            mime.get_header ("In-Reply-To") ?? "", mime.get_header ("References") ?? "", received,
            cc_recipients);
        message.body_html = html; message.security_status = decoded.status;
        message.bcc_recipients = bcc_recipients; message.message_size = (int64) info.get_size ();
        message.reply_to = reply_to;
        message.authentication_results = mime.get_header ("Authentication-Results") ?? "";
        message.list_unsubscribe = mime.get_header ("List-Unsubscribe") ?? "";
        message.list_unsubscribe_post = mime.get_header ("List-Unsubscribe-Post") ?? "";
        message.raw_headers = bounded_headers_from_camel (mime);
        foreach (var item in attachments) message.add_attachment (item);
        return new ConvertedCamelMessage (
            message, exact_mime_plain, exact_mime_html);
    }

    private static string bounded_headers_from_camel (Camel.MimeMessage mime) {
        var result = new StringBuilder (); var headers = mime.get_headers ();
        uint maximum = uint.min (headers.get_length (), 512);
        for (uint index = 0; index < maximum; index++) {
            unowned string? name = headers.get_name (index);
            unowned string? value = headers.get_value (index);
            if (name == null || name == "" || value == null) continue;
            result.append (name); result.append (": "); result.append (value); result.append_c ('\n');
            if (result.len >= MessageSecurityService.MAX_RAW_HEADER_BYTES) break;
        }
        return MessageSecurityService.bounded_raw_headers (result.str);
    }

    private static RemoteDraftSnapshot remote_draft_from_camel (
        string account_id, Mailbox mailbox, string uid, Camel.MessageInfo info,
        Camel.MimeMessage mime, ConvertedCamelMessage conversion) {
        var converted = conversion.message;
        string internet_message_id = bare_message_id (mime.get_message_id () ?? "");
        string managed_id = (mime.get_header ("X-Mailficient-Draft-ID") ?? "").strip ();
        string revision_text = (mime.get_header ("X-Mailficient-Draft-Revision") ?? "").strip ();
        int64 managed_revision = 0;
        bool managed = Uuid.string_is_valid (managed_id) &&
            int64.try_parse (revision_text, out managed_revision) && managed_revision > 0 &&
            internet_message_id == Draft.remote_message_id_for (managed_id, managed_revision);
        string local_id;
        if (managed) local_id = managed_id;
        else {
            string remote_identity = internet_message_id == "" ? "uid:" + uid : internet_message_id;
            string digest = Checksum.compute_for_string (ChecksumType.SHA256,
                account_id + "\n" + mailbox.remote_name + "\n" + remote_identity);
            local_id = "remote-" + digest.substring (0, 32);
        }
        var draft = new Draft (account_id, local_id);
        draft.to = converted.recipients; draft.cc = converted.cc_recipients;
        var bcc = mime.get_recipients (Camel.RECIPIENT_TYPE_BCC);
        if (bcc != null) draft.bcc = bcc.format () ?? "";
        draft.subject = mime.get_subject () ?? "";
        draft.body_html = conversion.mime_html;
        draft.body_text = remote_draft_plain_body (
            conversion.mime_plain, conversion.mime_html);
        draft.in_reply_to = mime.get_header ("In-Reply-To") ?? "";
        draft.references = mime.get_header ("References") ?? "";
        int64 timestamp = info.get_date_received ();
        if (timestamp <= 0) timestamp = info.get_date_sent ();
        draft.modified_at = timestamp > 0 ? timestamp : new DateTime.now_utc ().to_unix ();
        draft.revision = managed ? managed_revision : 1;
        draft.remote_mailbox = mailbox.remote_name; draft.remote_uid = uid;
        draft.remote_revision = draft.revision;
        draft.remote_internet_message_id = internet_message_id;
        draft.remote_owned = managed;
        foreach (var attachment in converted.attachments) draft.attachments.add (attachment);
        draft.mark_saved ();
        return new RemoteDraftSnapshot (draft, mailbox.remote_name, uid,
            internet_message_id, managed, DraftFingerprint.calculate (draft, uid));
    }

    internal static string remote_draft_plain_body (string mime_plain, string mime_html) {
        if (mime_plain != "") return mime_plain;
        if (mime_html != "") return HtmlSanitizer.to_plain_text (mime_html);
        return "";
    }

    private static string bare_message_id (string value) {
        string result = value.strip ();
        if (result.length >= 2 && result.has_prefix ("<") && result.has_suffix (">"))
            result = result.substring (1, result.length - 2).strip ();
        return result;
    }

    private async DecodedMimeContent decode_secure_content (Camel.MimePart original,
                                                              Cancellable? cancellable) {
        Camel.MimePart current = original;
        string status = "";
        // A signed-and-encrypted message has nested MIME security layers. Two
        // passes are sufficient for the supported sign-then-encrypt composer.
        for (int layer = 0; layer < 2; layer++) {
            string description = current.get_content_type () == null ? "" :
                current.get_content_type ().format ().down ();
            bool encrypted = description.contains ("multipart/encrypted") ||
                description.contains ("enveloped-data");
            bool signed = description.contains ("multipart/signed") ||
                description.contains ("signed-data");
            if (!encrypted && !signed) break;
            bool openpgp = description.contains ("pgp-");
            Camel.CipherContext context = openpgp ?
                (Camel.CipherContext) new Camel.GpgContext (session) :
                (Camel.CipherContext) new Camel.SMIMEContext (session);
            string technology = openpgp ? "OpenPGP" : "S/MIME";
            try {
                if (encrypted) {
                    var clear = new Camel.MimePart ();
                    var validity = yield context.decrypt (current, clear, Priority.DEFAULT, cancellable);
                    string detail = validity.get_description () ?? "";
                    status = detail.strip () == "" ? "%s encrypted message — decrypted".printf (technology) :
                        "%s encrypted message — %s".printf (technology, detail);
                    current = clear;
                } else {
                    var validity = yield context.verify (current, Priority.DEFAULT, cancellable);
                    string detail = validity.get_description () ?? "";
                    if (validity.get_valid ()) status = detail.strip () == "" ?
                        "%s signature verified".printf (technology) :
                        "%s signature verified — %s".printf (technology, detail);
                    else status = detail.strip () == "" ? "%s signature could not be verified".printf (technology) :
                        "%s signature warning — %s".printf (technology, detail);
                    break;
                }
            } catch (Error error) {
                status = encrypted ? "%s encrypted message could not be decrypted: %s".printf (technology, error.message) :
                    "%s signature could not be verified: %s".printf (technology, error.message);
                break;
            }
        }
        var content = ((Camel.Medium) current).get_content ();
        if (content == null) return new DecodedMimeContent (current, status);
        return new DecodedMimeContent (content, status);
    }

    internal void extract_content (Camel.DataWrapper wrapper, ref string plain, ref string html, ref bool attachment,
                                   Gee.ArrayList<Attachment> attachments, string message_key, ref int attachment_index,
                                   ref int64 remaining_attachment_bytes,
                                   Cancellable? cancellable) throws Error {
        var multipart = wrapper as Camel.Multipart;
        if (multipart != null) {
            for (uint index = 0; index < multipart.get_number (); index++) {
                var part = multipart.get_part (index);
                if (part != null) extract_part (part, ref plain, ref html, ref attachment,
                    attachments, message_key, ref attachment_index, ref remaining_attachment_bytes, cancellable);
            }
            return;
        }
        var part = wrapper as Camel.MimePart;
        if (part != null) extract_part (part, ref plain, ref html, ref attachment,
            attachments, message_key, ref attachment_index, ref remaining_attachment_bytes, cancellable);
        else extract_leaf_text (wrapper, ref plain, ref html);
    }

    private void extract_part (Camel.MimePart part, ref string plain, ref string html, ref bool attachment,
                               Gee.ArrayList<Attachment> attachments, string message_key, ref int attachment_index,
                               ref int64 remaining_attachment_bytes,
                               Cancellable? cancellable) throws Error {
        string? filename = part.get_filename (); string? disposition = part.get_disposition ();
        string content_id = part.get_content_id () ?? "";
        var content = part.get_content (); if (content == null) return;
        string mime_type = part.get_content_type () == null ? content.get_mime_type () : part.get_content_type ().simple ();
        bool inline_image = content_id != "" && mime_type.down ().has_prefix ("image/");
        // Meeting requests commonly arrive as an inline text/calendar MIME
        // part with neither Content-Disposition nor a filename. Treat it as a
        // bounded attachment so it is never discarded as an unknown text body.
        bool calendar_invitation = mime_type.down ().split (";", 2)[0].strip () ==
            "text/calendar";
        if ((filename != null && filename != "") ||
            (disposition != null && disposition.down ().contains ("attachment")) ||
            inline_image || calendar_invitation) {
            attachment = true;
            attachment_index++;
            string? attachment_name = filename;
            if (calendar_invitation && (attachment_name == null || attachment_name == ""))
                attachment_name = "invitation.ics";
            var saved = received_attachments.save (content, attachment_name, mime_type,
                message_key, attachment_index, cancellable, content_id, remaining_attachment_bytes);
            if (saved != null) {
                attachments.add (saved);
                if (saved.is_downloaded ()) remaining_attachment_bytes -= saved.size;
            }
            return;
        }
        var multipart = content as Camel.Multipart;
        if (multipart != null) {
            extract_content (multipart, ref plain, ref html, ref attachment, attachments,
                message_key, ref attachment_index, ref remaining_attachment_bytes, cancellable);
            return;
        }
        extract_leaf_text (content, ref plain, ref html);
    }

    internal static void extract_leaf_text (Camel.DataWrapper content,
                                            ref string plain, ref string html) throws Error {
        string mime_type = content.get_mime_type ().down ();
        if (mime_type.has_prefix ("text/plain") && plain == "") plain = decode_text (content);
        else if (mime_type.has_prefix ("text/html") && html == "") html = decode_text (content);
    }

    internal static string decode_text (Camel.DataWrapper content,
                                        int64 maximum_bytes = MAX_RECEIVED_TEXT_PART_BYTES) throws Error {
        if (maximum_bytes <= 0)
            throw new IOError.MESSAGE_TOO_LARGE ("The message text exceeds the safe in-memory limit");
        normalize_text_charset (content);
        var output = new MemoryOutputStream.resizable ();
        var bounded = new BoundedAttachmentOutputStream (output, maximum_bytes);
        content.decode_to_output_stream_sync (bounded);
        output.close ();
        var bytes = output.steal_as_bytes ();
        unowned uint8[] data = bytes.get_data ();
        var text = new StringBuilder.sized (data.length + 1);
        text.append_len ((string) data, (ssize_t) data.length);
        return text.str.make_valid ();
    }

    internal static void normalize_text_charset (Camel.DataWrapper content) {
        unowned Camel.ContentType? content_type = content.get_mime_type_field ();
        if (content_type == null) return;
        unowned string? declared = content_type.param ("charset");
        if (declared == null || declared.strip () == "") return;

        string charset = declared.strip ();
        // Some broken bulk-mail generators leak quoted-printable's "=" as
        // "3D" into MIME parameters (for example charset=3DUTF-8).
        while (charset.length > 2 &&
               charset.substring (0, 2).ascii_casecmp ("3D") == 0)
            charset = charset.substring (2);

        bool supported = true;
        try {
            new CharsetConverter ("UTF-8", charset);
        } catch (Error error) {
            supported = false;
        }
        if (!supported) charset = "UTF-8";
        if (charset.ascii_casecmp (declared) != 0)
            content_type.set_param ("charset", charset);
    }

    private static string format_timestamp (int64 unix_time) {
        if (unix_time <= 0) return "";
        var value = new DateTime.from_unix_local (unix_time);
        var now = new DateTime.now_local ();
        if (value.get_year () == now.get_year () && value.get_day_of_year () == now.get_day_of_year ())
            return value.format ("%l:%M %p").strip ();
        if (value.get_year () == now.get_year ()) return value.format ("%b %e").strip ();
        return value.format ("%b %e, %Y").strip ();
    }

    public async SendResult send (Draft draft, Cancellable? cancellable = null) throws Error {
        var transport = transports[draft.account_id]; var settings = accounts[draft.account_id];
        if (transport == null || settings == null) throw new MailError.CONNECTION ("The account is not connected");
        var message = yield build_mime_message (draft, settings, cancellable);
        var from = new Camel.InternetAddress (); from.add (settings.display_name, settings.email);
        var all_recipients = new Camel.InternetAddress ();
        parse_addresses (draft.to, all_recipients);
        if (draft.cc.strip () != "") parse_addresses (draft.cc, all_recipients);
        if (draft.bcc.strip () != "") parse_addresses (draft.bcc, all_recipients);
        bool saved;
        bool submitted;
        try {
            submitted = yield transport.send_to (
                message, from, all_recipients, Priority.DEFAULT, cancellable, out saved);
        }
        catch (Error error) {
            throw normalize_send_error (error,
                transport.get_connection_status () == Camel.ServiceConnectionStatus.CONNECTED);
        }
        if (!submitted)
            throw new MailError.SEND_FAILED (
                "The SMTP server did not accept the message");
        if (saved || provider_files_sent_automatically (settings)) return new SendResult ();
        return yield file_in_sent (draft.account_id, message, cancellable);
    }

    public async RemoteDraftLocation? save_remote_draft (
        Draft draft, Cancellable? cancellable = null) throws Error {
        var store = stores[draft.account_id]; var settings = accounts[draft.account_id];
        if (store == null || settings == null)
            throw new MailError.CONNECTION ("The account is not connected");
        Camel.Folder? folder = yield find_remote_drafts_folder (store, cancellable);
        if (folder == null) return null;
        try {
            yield folder.refresh_info (Priority.DEFAULT, cancellable);
            string expected_id = draft.remote_message_id ();
            var matches = yield matching_remote_draft_uids (folder, expected_id, cancellable);
            if (matches.size == 0) {
                var message = yield build_mime_message_with_options (
                    draft, settings, true, cancellable);
                // EDS 3.56 documents append metadata as nullable, but its
                // asynchronous wrapper unconditionally g_object_ref()s it.
                // Provider-specific metadata also preserves the intended
                // summary implementation when the append completes.
                var append_info = folder.get_folder_summary ().info_new_from_message (message);
                string? appended_uid;
                bool appended = yield folder.append_message (message, append_info,
                    Priority.DEFAULT, cancellable, out appended_uid);
                if (!appended)
                    throw new MailError.CONNECTION ("The server rejected the Drafts copy");
                yield folder.synchronize (false, Priority.DEFAULT, cancellable);
                matches = yield matching_remote_draft_uids (folder, expected_id, cancellable);
                if (matches.size == 0 && appended_uid != null && appended_uid != "")
                    matches.add (appended_uid);
            }
            if (matches.size == 0)
                throw new MailError.CONNECTION ("The server did not return an identifier for the Drafts copy");
            string canonical_uid = canonical_remote_uid (matches);
            uint32 managed_mask = Camel.MessageFlags.DRAFT | Camel.MessageFlags.SEEN |
                Camel.MessageFlags.DELETED;
            uint32 managed_flags = Camel.MessageFlags.DRAFT | Camel.MessageFlags.SEEN;
            foreach (var uid in matches) {
                if (uid == canonical_uid)
                    folder.set_message_flags (uid, managed_mask, managed_flags);
                else
                    folder.set_message_flags (uid, Camel.MessageFlags.DELETED,
                        Camel.MessageFlags.DELETED);
            }
            yield folder.synchronize (false, Priority.DEFAULT, cancellable);
            return new RemoteDraftLocation (folder.get_full_name (), canonical_uid);
        } catch (MailError error) { throw error; }
        catch (Error error) { throw normalize_error (error); }
    }

    public async bool delete_remote_draft (PendingDraftDeletion deletion,
                                           Cancellable? cancellable = null) throws Error {
        var store = stores[deletion.account_id];
        if (store == null) throw new MailError.CONNECTION ("The account is not connected");
        try {
            var folder = yield store.get_folder (deletion.mailbox_name,
                Camel.StoreGetFolderFlags.NONE, Priority.DEFAULT, cancellable);
            if (folder == null) return true;
            yield folder.refresh_info (Priority.DEFAULT, cancellable);
            var info = folder.get_message_info (deletion.remote_uid);
            // Missing is successful idempotent cleanup. Never search for a
            // replacement by Message-ID here: concurrent, identical appends
            // deliberately share that ID, and a stale cleanup must not delete
            // the canonical copy adopted by another worker.
            if (info == null) return true;
            var candidate = yield folder.get_message (
                deletion.remote_uid, Priority.DEFAULT, cancellable);
            if (candidate == null || bare_message_id (candidate.get_message_id () ?? "") !=
                bare_message_id (deletion.expected_message_id))
                return false;
            folder.set_message_flags (deletion.remote_uid,
                Camel.MessageFlags.DELETED, Camel.MessageFlags.DELETED);
            yield folder.synchronize (false, Priority.DEFAULT, cancellable);
            return true;
        } catch (Error error) { throw normalize_error (error); }
    }

    private async Camel.Folder? find_remote_drafts_folder (
        Camel.Store store, Cancellable? cancellable) throws Error {
        var root = yield store.get_folder_info (null,
            Camel.StoreGetFolderInfoFlags.RECURSIVE |
            Camel.StoreGetFolderInfoFlags.SUBSCRIBED,
            Priority.DEFAULT, cancellable);
        string? drafts_name = find_role_folder (root, MailboxRole.DRAFTS);
        if (drafts_name == null) return null;
        return yield store.get_folder (drafts_name, Camel.StoreGetFolderFlags.NONE,
            Priority.DEFAULT, cancellable);
    }

    private async Gee.ArrayList<string> matching_remote_draft_uids (
        Camel.Folder folder, string expected_message_id,
        Cancellable? cancellable) throws Error {
        var result = new Gee.ArrayList<string> ();
        string exact_id = bare_message_id (expected_message_id);
        if (exact_id == "") return result;
        string escaped = exact_id.replace ("\\", "\\\\")
            .replace ("\"", "\\\"").replace ("\r", " ").replace ("\n", " ");
        var matches = search_folder_uids (folder,
            "(header-contains \"Message-ID\" \"%s\")".printf (escaped), cancellable);
        for (int index = 0; index < matches.size; index++) {
            string uid = matches[index];
            if (uid == "") continue;
            // Camel's folder search is only a candidate filter: header-contains
            // can also return a longer, attacker-controlled Message-ID. Fetch
            // and compare the normalized header before any flag is changed.
            var candidate = yield folder.get_message (uid, Priority.DEFAULT, cancellable);
            if (candidate != null && bare_message_id (candidate.get_message_id () ?? "") == exact_id)
                result.add (uid);
        }
        return result;
    }

    private static string canonical_remote_uid (Gee.List<string> uids) {
        string canonical = uids[0];
        foreach (var uid in uids) {
            uint64 candidate_number = 0; uint64 canonical_number = 0;
            bool candidate_numeric = uint64.try_parse (uid, out candidate_number);
            bool canonical_numeric = uint64.try_parse (canonical, out canonical_number);
            if ((candidate_numeric && canonical_numeric && candidate_number < canonical_number) ||
                (!(candidate_numeric && canonical_numeric) && strcmp (uid, canonical) < 0))
                canonical = uid;
        }
        return canonical;
    }

    public async void save_remote_attachment (string account_id, string mailbox_name,
                                              string remote_uid, int remote_part_index,
                                              File destination, int64 maximum_bytes,
                                              Cancellable? cancellable = null) throws Error {
        if (remote_part_index <= 0)
            throw new MailError.ATTACHMENT ("The server attachment identifier is unavailable");
        if (maximum_bytes <= 0)
            throw new MailError.ATTACHMENT ("The attachment download limit is invalid");
        int64 effective_limit = int64.min (maximum_bytes,
            MAX_EXPLICIT_ATTACHMENT_DOWNLOAD_BYTES);
        var store = stores[account_id];
        if (store == null) throw new MailError.CONNECTION ("The account is not connected");
        var folder = yield store.get_folder (mailbox_name, Camel.StoreGetFolderFlags.NONE,
            Priority.DEFAULT, cancellable);
        if (folder == null) throw new MailError.CONNECTION ("The message folder is unavailable");
        Camel.MimeMessage mime;
        try { mime = yield folder.get_message (remote_uid, Priority.DEFAULT, cancellable); }
        catch (Error error) { throw normalize_error (error); }
        int current_index = 0;
        var content = attachment_content_at (mime, remote_part_index, ref current_index);
        if (content == null)
            throw new MailError.ATTACHMENT ("The attachment is no longer present in the server message");
        int64 declared_size = (int64) content.calculate_decoded_size_sync (cancellable);
        if (declared_size > effective_limit)
            throw new MailError.ATTACHMENT ("The attachment exceeds the allowed download size");

        var parent = destination.get_parent ();
        string? basename = destination.get_basename ();
        if (parent == null || basename == null || basename == "")
            throw new MailError.ATTACHMENT ("Choose a normal destination filename");
        string staging_name = ".%s.mailficient-%s".printf (
            AttachmentSafety.safe_filename (basename), Uuid.string_random ());
        var staging = parent.get_child (staging_name);
        OutputStream? output = null;
        try {
            output = yield staging.replace_async (null, false, FileCreateFlags.PRIVATE,
                Priority.DEFAULT, cancellable);
            var bounded = new BoundedAttachmentOutputStream (output,
                effective_limit);
            content.decode_to_output_stream_sync (bounded, cancellable);
            yield output.close_async (Priority.DEFAULT, cancellable);
            output = null;
            yield staging.move_async (destination,
                FileCopyFlags.OVERWRITE | FileCopyFlags.NOFOLLOW_SYMLINKS,
                Priority.DEFAULT, cancellable, null);
        } catch (Error error) {
            if (output != null) {
                try { yield output.close_async (Priority.DEFAULT, null); } catch (Error ignored) { }
            }
            try { if (staging.query_exists ()) yield staging.delete_async (Priority.DEFAULT, null); }
            catch (Error ignored) { }
            if (error is IOError.MESSAGE_TOO_LARGE)
                throw new MailError.ATTACHMENT ("The attachment exceeds the allowed download size");
            if (error is IOError.CANCELLED)
                throw new MailError.CANCELLED (error.message);
            throw new MailError.ATTACHMENT (error.message);
        }
    }

    internal static Camel.DataWrapper? attachment_content_at (Camel.DataWrapper wrapper,
                                                               int target_index,
                                                               ref int current_index) {
        var multipart = wrapper as Camel.Multipart;
        if (multipart != null) {
            for (uint index = 0; index < multipart.get_number (); index++) {
                var part = multipart.get_part (index);
                if (part == null) continue;
                var found = attachment_content_at (part, target_index, ref current_index);
                if (found != null) return found;
            }
            return null;
        }
        var part = wrapper as Camel.MimePart;
        if (part == null) return null;
        var content = part.get_content ();
        if (content == null) return null;
        string? filename = part.get_filename ();
        string? disposition = part.get_disposition ();
        string content_id = part.get_content_id () ?? "";
        string mime_type = part.get_content_type () == null ?
            content.get_mime_type () : part.get_content_type ().simple ();
        bool inline_image = content_id != "" && mime_type.down ().has_prefix ("image/");
        if ((filename != null && filename != "") ||
            (disposition != null && disposition.down ().contains ("attachment")) || inline_image) {
            current_index++;
            return current_index == target_index ? content : null;
        }
        return attachment_content_at (content, target_index, ref current_index);
    }

    internal async Camel.MimeMessage build_mime_message (Draft draft, AccountSettings settings,
                                                          Cancellable? cancellable = null) throws Error {
        return yield build_mime_message_with_options (draft, settings, false, cancellable);
    }

    private async Camel.MimeMessage build_mime_message_with_options (
        Draft draft, AccountSettings settings, bool remote_draft,
        Cancellable? cancellable = null) throws Error {
        AttachmentService.validate_declared_total (draft.attachments);
        var message = new Camel.MimeMessage (); message.set_subject (draft.subject);
        message.set_message_id (remote_draft ? draft.remote_message_id () :
            Uuid.string_random () + "@mailficient.local");
        message.set_date ((time_t) new DateTime.now_utc ().to_unix (), 0);
        if (remote_draft) {
            message.set_header ("X-Mailficient-Draft-ID", draft.id);
            message.set_header ("X-Mailficient-Draft-Revision", draft.revision.to_string ());
        }
        if (draft.in_reply_to != "") {
            message.set_header ("In-Reply-To", draft.in_reply_to);
            message.set_header ("References", draft.references == "" ? draft.in_reply_to : draft.references);
        }
        var from = new Camel.InternetAddress (); from.add (settings.display_name, settings.email); message.set_from (from);
        var ignored_envelope = new Camel.InternetAddress ();
        var to = parse_addresses (draft.to, ignored_envelope); message.set_recipients (Camel.RECIPIENT_TYPE_TO, to);
        if (draft.cc.strip () != "") message.set_recipients (Camel.RECIPIENT_TYPE_CC, parse_addresses (draft.cc, ignored_envelope));
        // Bcc recipients belong in the SMTP envelope only and must not leak into message headers.
        if (remote_draft && draft.bcc.strip () != "")
            message.set_recipients (Camel.RECIPIENT_TYPE_BCC, parse_addresses (draft.bcc, ignored_envelope));

        uint8[] body_content = draft.body_text.data;
        Camel.Multipart? alternative = null;
        if (draft.body_html.strip () != "") {
            alternative = new Camel.Multipart (); alternative.set_mime_type ("multipart/alternative"); alternative.set_boundary (null);
            var plain_part = new Camel.MimePart (); plain_part.set_content (body_content, "text/plain; charset=utf-8");
            plain_part.set_encoding (Camel.TransferEncoding.ENCODING_QUOTEDPRINTABLE); alternative.add_part (plain_part);
            var html_part = new Camel.MimePart (); html_part.set_content (draft.body_html.data, "text/html; charset=utf-8");
            html_part.set_encoding (Camel.TransferEncoding.ENCODING_QUOTEDPRINTABLE); alternative.add_part (html_part);
        }
        if (draft.attachments.size == 0) {
            if (alternative != null) ((Camel.Medium) message).set_content (alternative);
            else message.set_content (body_content, "text/plain; charset=utf-8");
        } else {
            var multipart = new Camel.Multipart (); multipart.set_mime_type ("multipart/mixed"); multipart.set_boundary (null);
            if (alternative != null) {
                var body_part = new Camel.MimePart (); ((Camel.Medium) body_part).set_content (alternative); multipart.add_part (body_part);
            } else {
                var body_part = new Camel.MimePart (); body_part.set_content (body_content, "text/plain; charset=utf-8");
                body_part.set_encoding (Camel.TransferEncoding.ENCODING_QUOTEDPRINTABLE); multipart.add_part (body_part);
            }
            foreach (var attachment in draft.attachments) {
                uint8[] contents; string? etag;
                try {
                    yield File.new_for_path (attachment.path).load_contents_async (
                        cancellable, out contents, out etag);
                } catch (Error error) {
                    if (error is IOError.CANCELLED)
                        throw new MailError.SEND_FAILED (
                            "Message preparation was cancelled before it reached SMTP");
                    throw new MailError.ATTACHMENT (
                        "A draft attachment could not be read while preparing the message: %s".printf (
                            error.message));
                }
                var part = new Camel.MimePart (); part.set_content (contents, attachment.content_type);
                part.set_filename (attachment.name);
                if (attachment.content_id != "") {
                    part.set_content_id (attachment.content_id);
                    part.set_disposition ("inline");
                } else part.set_disposition ("attachment");
                part.set_encoding (Camel.TransferEncoding.ENCODING_BASE64); multipart.add_part (part);
            }
            ((Camel.Medium) message).set_content (multipart);
        }
        if (!remote_draft && (draft.sign_message || draft.encrypt_message))
            yield secure_mime_body (message, draft, settings, cancellable);
        return message;
    }

    private async void secure_mime_body (Camel.MimeMessage message, Draft draft,
                                         AccountSettings settings,
                                         Cancellable? cancellable) throws Error {
        if (draft.security_protocol == MessageSecurityProtocol.NONE)
            throw new MailError.INVALID_MESSAGE ("Choose OpenPGP or S/MIME before securing this message");
        Camel.CipherContext context;
        if (draft.security_protocol == MessageSecurityProtocol.OPENPGP) {
            var gpg = new Camel.GpgContext (session);
            // Never silently trust an unknown key. GnuPG's normal trust policy
            // remains authoritative and key discovery stays opt-in.
            gpg.set_always_trust (false); gpg.set_locate_keys (false);
            context = gpg;
        } else {
            var smime = new Camel.SMIMEContext (session);
            smime.set_sign_mode (Camel.SMIMESign.CLEARSIGN);
            context = smime;
        }
        string identity = draft.security_identity.strip ();
        if (identity == "") identity = settings.email;
        var source = new Camel.MimePart ();
        var message_content = ((Camel.Medium) message).get_content ();
        if (message_content == null)
            throw new MailError.SEND_FAILED ("The message body could not be prepared for cryptography");
        ((Camel.Medium) source).set_content (message_content);
        var message_type = message.get_content_type ();
        if (message_type != null) source.set_content_type (message_type.format ());
        Camel.MimePart current = source;
        try {
            if (draft.sign_message) {
                var signed_part = new Camel.MimePart ();
                if (!(yield context.sign (identity, Camel.CipherHash.SHA256, current,
                                           signed_part, Priority.DEFAULT, cancellable)))
                    throw new MailError.SEND_FAILED ("The cryptographic signature could not be created");
                current = signed_part;
            }
            if (draft.encrypt_message) {
                var recipients = new GenericArray<string> ();
                foreach (var address in draft.security_recipients (settings.email)) recipients.add (address);
                if (draft.security_protocol == MessageSecurityProtocol.SMIME)
                    ((Camel.SMIMEContext) context).set_encrypt_key (true, identity);
                var encrypted_part = new Camel.MimePart ();
                if (!(yield context.encrypt (identity, recipients, current, encrypted_part,
                                              Priority.DEFAULT, cancellable)))
                    throw new MailError.SEND_FAILED ("The message could not be encrypted");
                current = encrypted_part;
            }
        } catch (MailError error) { throw error; }
        catch (Error error) {
            string technology = draft.security_protocol == MessageSecurityProtocol.OPENPGP ? "OpenPGP" : "S/MIME";
            throw new MailError.SEND_FAILED ("%s security failed: %s".printf (technology, error.message));
        }
        var secured_content = ((Camel.Medium) current).get_content ();
        if (secured_content == null)
            throw new MailError.SEND_FAILED ("Cryptography returned an empty message body");
        ((Camel.Medium) message).set_content (secured_content);
        var secured_type = current.get_content_type ();
        if (secured_type != null) message.set_content_type (secured_type.format ());
        message.set_encoding (current.get_encoding ());
    }

    private async SendResult file_in_sent (string account_id, Camel.MimeMessage message,
                                           Cancellable? cancellable) {
        try {
            var store = stores[account_id];
            if (store == null) return new SendResult (false, "The account store is disconnected");
            var root = yield store.get_folder_info (null,
                Camel.StoreGetFolderInfoFlags.RECURSIVE | Camel.StoreGetFolderInfoFlags.SUBSCRIBED,
                Priority.DEFAULT, cancellable);
            string? sent_name = find_role_folder (root, MailboxRole.SENT);
            if (sent_name == null)
                return new SendResult (false, "No Sent mailbox was advertised by the server");
            var sent = yield store.get_folder (sent_name, Camel.StoreGetFolderFlags.NONE,
                Priority.DEFAULT, cancellable);
            if (sent == null) return new SendResult (false, "The Sent mailbox is unavailable");
            string? appended_uid;
            var append_info = sent.get_folder_summary ().info_new_from_message (message);
            bool appended = yield sent.append_message (message, append_info, Priority.DEFAULT,
                                                       cancellable, out appended_uid);
            if (!appended) return new SendResult (false, "The server rejected the Sent copy");
            yield sent.synchronize (false, Priority.DEFAULT, cancellable);
            return new SendResult ();
        } catch (Error error) {
            return new SendResult (false, error.message);
        }
    }

    private static string? find_role_folder (Camel.FolderInfo? node, MailboxRole role) {
        for (var current = node; current != null; current = current.next) {
            if (role_for_folder (current.flags, current.display_name, current.full_name) == role)
                return current.full_name;
            string? child = find_role_folder (current.child, role); if (child != null) return child;
        }
        return null;
    }

    private static bool provider_files_sent_automatically (AccountSettings settings) {
        string host = settings.outgoing_host.down ();
        return host == "smtp.gmail.com" || host == "smtp.office365.com" ||
            host == "smtp-mail.outlook.com";
    }

    public async void set_message_state (string account_id, string mailbox_name, string remote_uid,
                                         MessageStateField field, bool value,
                                         Cancellable? cancellable = null) throws Error {
        var store = stores[account_id]; if (store == null) throw new MailError.CONNECTION ("The account is not connected");
        var folder = yield store.get_folder (mailbox_name, Camel.StoreGetFolderFlags.NONE, Priority.DEFAULT, cancellable);
        if (folder == null) throw new MailError.CONNECTION ("The message folder is unavailable");
        uint32 mask = flags_for_state_field (field);
        folder.set_message_flags (remote_uid, mask, value ? mask : 0);
        yield folder.synchronize (false, Priority.DEFAULT, cancellable);
    }

    internal static uint32 flags_for_state_field (MessageStateField field) throws MailError {
        uint32 mask;
        switch (field) {
        case MessageStateField.READ: mask = Camel.MessageFlags.SEEN; break;
        case MessageStateField.FLAGGED: mask = Camel.MessageFlags.FLAGGED; break;
        case MessageStateField.JUNK: mask = Camel.MessageFlags.JUNK; break;
        case MessageStateField.NOT_JUNK: mask = Camel.MessageFlags.NOTJUNK; break;
        default: throw new MailError.INVALID_MESSAGE ("The requested message state is unsupported");
        }
        return mask;
    }

    public async string? transfer_message (string account_id, string source_mailbox, string remote_uid,
                                           string destination_mailbox, bool copy,
                                           Cancellable? cancellable = null) throws Error {
        var store = stores[account_id]; if (store == null) throw new MailError.CONNECTION ("The account is not connected");
        var source = yield store.get_folder (source_mailbox, Camel.StoreGetFolderFlags.NONE, Priority.DEFAULT, cancellable);
        var destination = yield store.get_folder (destination_mailbox, Camel.StoreGetFolderFlags.NONE, Priority.DEFAULT, cancellable);
        if (source == null || destination == null) throw new MailError.CONNECTION ("A message move folder is unavailable");
        uint64 source_message_id = 0;
        var source_info = source.get_message_info (remote_uid);
        if (source_info != null) source_message_id = source_info.get_message_id ();
        var destination_before = new Gee.HashSet<string> ();
#if EDS_LEGACY
        var prior_destination_uids = destination.get_uids ();
#else
        var prior_destination_uids = destination.dup_uids ();
#endif
        for (uint index = 0; index < prior_destination_uids.length; index++)
            destination_before.add (prior_destination_uids[index]);
        var uids = new GenericArray<string> (); uids.add (remote_uid);
#if EDS_LEGACY
        GenericArray<string>? transferred;
#else
        GenericArray<weak string>? transferred;
#endif
        bool accepted = yield source.transfer_messages_to (uids, destination, !copy,
            Priority.DEFAULT, cancellable, out transferred);
        if (!accepted) throw new MailError.CONNECTION (copy ?
            "The server rejected the message copy" : "The server rejected the message move");
        // A subsequent account sync reconciles both folders. Synchronizing here
        // would turn a post-accept refresh failure into a duplicate retry.
        if (transferred != null && transferred.length > 0) return transferred[0];
        // Servers without UIDPLUS may accept the move but omit the destination
        // UID. Recover it from the newly appeared destination summary entry so
        // chained offline moves and state changes do not keep using the old
        // source identity. Failure to refresh after acceptance is deliberately
        // non-fatal: the normal account refresh can still reconcile the move.
        try {
            yield destination.refresh_info (Priority.DEFAULT, cancellable);
            var destination_after = new Gee.HashMap<string, uint64?> ();
#if EDS_LEGACY
            var current_destination_uids = destination.get_uids ();
#else
            var current_destination_uids = destination.dup_uids ();
#endif
            for (uint index = 0; index < current_destination_uids.length; index++) {
                string uid = current_destination_uids[index];
                var info = destination.get_message_info (uid);
                destination_after[uid] = info == null ? 0 : info.get_message_id ();
            }
            return choose_recovered_destination_uid (
                destination_before, destination_after, source_message_id);
        } catch (Error ignored) { }
        return null;
    }

    internal static string? choose_recovered_destination_uid (Gee.Set<string> before,
                                                                Gee.Map<string, uint64?> after,
                                                                uint64 source_message_id) {
        string? candidate = null;
        foreach (var entry in after.entries) {
            if (before.contains (entry.key)) continue;
            if (source_message_id != 0 &&
                (entry.value == null || entry.value != source_message_id)) continue;
            if (candidate != null) return null;
            candidate = entry.key;
        }
        return candidate;
    }

    public async void create_folder (string account_id, string parent_name, string folder_name,
                                     Cancellable? cancellable = null) throws Error {
        var store = stores[account_id]; if (store == null) throw new MailError.CONNECTION ("The account is not connected");
        // Stop selecting Inbox while its store processes CREATE/LIST updates.
        // Older IMAPX releases can otherwise race folder construction against
        // an active IDLE watch and instantiate the wrong base folder type.
        detach_live_watch (account_id);
        try {
            // Do not use get_folder(CREATE) here. EDS 3.56 reserves the folder
            // name in CamelStore's object bag while IMAPX CREATE performs its
            // confirming LIST on another worker. The mailbox-created callback
            // can then observe that reservation as if it were a CamelFolder.
            var created = yield store.create_folder (parent_name, folder_name,
                Priority.DEFAULT, cancellable);
            if (created == null)
                throw new MailError.CONNECTION ("The server did not create the folder");
        } catch (Error error) {
            try { yield ensure_live_watch (account_id, store, cancellable); }
            catch (Error ignored) { }
            throw error;
        }
        yield ensure_live_watch (account_id, store, cancellable);
    }

    public async void rename_folder (string account_id, string old_name, string old_display_name,
                                     string new_display_name, Cancellable? cancellable = null) throws Error {
        var store = stores[account_id]; if (store == null) throw new MailError.CONNECTION ("The account is not connected");
        string new_name = new_display_name;
        if (old_display_name != "" && old_name.has_suffix (old_display_name))
            new_name = old_name.substring (0, old_name.length - old_display_name.length) + new_display_name;
        detach_live_watch (account_id);
        Camel.Folder? retained_folder = null;
        try {
            // EDS's IMAPX store keeps weak folder references in its object bag.
            // Retain the source until the provider's post-RENAME LIST callback
            // has re-keyed it; otherwise older releases can observe an object
            // whose finalizer is already running.
            retained_folder = yield store.get_folder (old_name,
                Camel.StoreGetFolderFlags.NONE, Priority.DEFAULT, cancellable);
            if (retained_folder == null ||
                !(yield store.rename_folder (old_name, new_name, Priority.DEFAULT, cancellable)))
                throw new MailError.CONNECTION ("The server did not rename the folder");
            // Keep the explicit reference live across the asynchronous rename.
            retained_folder.get_full_name ();
        } catch (Error error) {
            try { yield ensure_live_watch (account_id, store, cancellable); }
            catch (Error ignored) { }
            throw error;
        }
        yield ensure_live_watch (account_id, store, cancellable);
    }

    public async void delete_folder (string account_id, string folder_name,
                                     Cancellable? cancellable = null) throws Error {
        var store = stores[account_id]; if (store == null) throw new MailError.CONNECTION ("The account is not connected");
        detach_live_watch (account_id);
        Camel.Folder? retained_folder = null;
        try {
            // Retain the provider folder through the mailbox-deleted callback
            // for the same CamelObjectBag lifetime reason as rename_folder().
            retained_folder = yield store.get_folder (folder_name,
                Camel.StoreGetFolderFlags.NONE, Priority.DEFAULT, cancellable);
            if (retained_folder == null ||
                !(yield store.delete_folder (folder_name, Priority.DEFAULT, cancellable)))
                throw new MailError.CONNECTION ("The server did not delete the folder");
            retained_folder.get_full_name ();
        } catch (Error error) {
            try { yield ensure_live_watch (account_id, store, cancellable); }
            catch (Error ignored) { }
            throw error;
        }
        yield ensure_live_watch (account_id, store, cancellable);
    }

    public async void permanently_delete_message (string account_id, string mailbox_name,
                                                   string remote_uid,
                                                   Cancellable? cancellable = null) throws Error {
        var store = stores[account_id];
        if (store == null) throw new MailError.CONNECTION ("The account is not connected");
        var folder = yield store.get_folder (mailbox_name, Camel.StoreGetFolderFlags.NONE,
                                             Priority.DEFAULT, cancellable);
        if (folder == null) throw new MailError.CONNECTION ("The message folder is unavailable");
        uint32 deleted = Camel.MessageFlags.DELETED;
        folder.set_message_flags (remote_uid, deleted, deleted);
        yield folder.synchronize (true, Priority.DEFAULT, cancellable);
    }

    public async void empty_folder (string account_id, string folder_name,
                                    Cancellable? cancellable = null) throws Error {
        var store = stores[account_id];
        if (store == null) throw new MailError.CONNECTION ("The account is not connected");
        var folder = yield store.get_folder (folder_name, Camel.StoreGetFolderFlags.NONE,
                                             Priority.DEFAULT, cancellable);
        if (folder == null) throw new MailError.CONNECTION ("The folder is unavailable");
        uint32 deleted = Camel.MessageFlags.DELETED;
#if EDS_LEGACY
        var uids = folder.get_uids ();
#else
        var uids = folder.dup_uids ();
#endif
        for (uint index = 0; index < uids.length; index++)
            folder.set_message_flags (uids[index], deleted, deleted);
        yield folder.synchronize (true, Priority.DEFAULT, cancellable);
    }

    private static Camel.InternetAddress parse_addresses (string value, Camel.InternetAddress envelope) throws MailError {
        var result = new Camel.InternetAddress ();
        foreach (var recipient in RecipientParser.parse (value)) {
            result.add (recipient.name, recipient.address); envelope.add (recipient.name, recipient.address);
        }
        return result;
    }

    internal static Error normalize_error (Error error) {
        if (error is MailError) return error;
        if (is_rate_limit_error (error.message))
            return new MailError.RATE_LIMITED (error.message);
        if (error is Camel.ServiceError.CANT_AUTHENTICATE)
            return new MailError.AUTHENTICATION (error.message);
        if (error is IOError.CANCELLED)
            return new MailError.CANCELLED (error.message);
        if (error is IOError.TIMED_OUT)
            return new MailError.TIMEOUT (error.message);
        if (error is IOError.NETWORK_UNREACHABLE || error is IOError.HOST_UNREACHABLE ||
            error is IOError.HOST_NOT_FOUND || error is IOError.CONNECTION_REFUSED ||
            error is IOError.NOT_CONNECTED)
            return new MailError.OFFLINE (error.message);
        if (error is TlsError.BAD_CERTIFICATE || error is TlsError.CERTIFICATE_REQUIRED)
            return new MailError.TLS (error.message);
        return new MailError.CONNECTION (error.message);
    }

    internal static Error normalize_send_error (Error error, bool transport_still_connected) {
        var normalized = normalize_error (error);
        if (normalized is MailError.RATE_LIMITED || normalized is MailError.AUTHENTICATION ||
            normalized is MailError.TLS || normalized is MailError.OFFLINE ||
            normalized is MailError.TIMEOUT || normalized is MailError.CANCELLED)
            return normalized;
        // Camel's SMTP provider reports protocol rejections through the broad
        // service error domain. A connection that remains established proves
        // the server returned a response; a dropped connection cannot prove
        // whether DATA was accepted and must retain the duplicate-safe path.
        if (transport_still_connected) {
            if (is_permanent_smtp_rejection (error.message))
                return new MailError.SEND_REJECTED (error.message);
            return new MailError.SEND_FAILED (error.message);
        }
        return normalized;
    }

    internal static bool is_permanent_smtp_rejection (string? detail) {
        if (detail == null) return false;
        try {
            var code = new Regex ("(^|[^0-9])5[0-9]{2}([^0-9]|$)");
            return code.match (detail);
        } catch (RegexError error) { return false; }
    }

    internal static bool is_rate_limit_error (string? detail) {
        if (detail == null) return false;
        string normalized = detail.down ();
        return normalized.contains ("rate limit") ||
            normalized.contains ("rate-limit") ||
            normalized.contains ("too many requests") ||
            normalized.contains ("too many connections") ||
            normalized.contains ("throttl") ||
            normalized.contains ("temporarily deferred");
    }
}
}
