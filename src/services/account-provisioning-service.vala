namespace Mailficient {
public class AccountProvisioningService : Object {
    private AccountStore accounts;
    private CredentialStore credentials;
    private CredentialCleanupService credential_cleanup;
    private MailEngine engine;
    private OutboundService? outbound_service;
    private AccountSyncService? sync_service;

    public AccountProvisioningService (AccountStore accounts, CredentialStore credentials,
                                       CredentialCleanupService credential_cleanup,
                                       MailEngine engine,
                                       OutboundService? outbound_service = null,
                                       AccountSyncService? sync_service = null) {
        this.accounts = accounts; this.credentials = credentials;
        this.credential_cleanup = credential_cleanup; this.engine = engine;
        this.outbound_service = outbound_service;
        this.sync_service = sync_service;
    }

    public async void provision (AccountSettings account, string? incoming_password = null,
                                 string? outgoing_password = null,
                                 AccountSettings? existing = null,
                                 Cancellable? cancellable = null) throws Error {
        account.validate ();
        string? old_imap = null; string? old_smtp = null;
        string? candidate_id = null;
        string replacement_imap = "";
        string replacement_smtp = "";
        OutboundAccountSessionLease? outbound_lease = null;
        bool sync_quiesced = false;
        bool candidate_connection_attempted = false;
        bool actual_connection_attempted = false;
        bool existing_disconnect_attempted = false;
        bool actual_credentials_changed = false;

        try {
            if (account.authentication == AuthenticationMode.PASSWORD) {
                if (existing != null) {
                    old_imap = yield credentials.lookup_password (account.id, "imap", cancellable);
                    old_smtp = yield credentials.lookup_password (account.id, "smtp", cancellable);
                }
                string? incoming = nonempty (incoming_password) ? incoming_password : old_imap;
                string? outgoing = nonempty (outgoing_password) ? outgoing_password :
                    (nonempty (incoming_password) ? incoming_password : (old_smtp ?? incoming));
                if (!nonempty (incoming))
                    throw new MailError.AUTHENTICATION ("Enter a password or app password");
                if (!nonempty (outgoing)) outgoing = incoming;
                replacement_imap = incoming ?? "";
                replacement_smtp = outgoing ?? replacement_imap;

                candidate_id = "candidate-" + Uuid.string_random ();
                yield credentials.store_password (candidate_id, "imap",
                    replacement_imap, cancellable);
                yield credentials.store_password (candidate_id, "smtp",
                    replacement_smtp, cancellable);
                var candidate = copy_with_id (account, candidate_id);
                candidate_connection_attempted = true;
                yield engine.connect_account (candidate, cancellable);
                yield engine.disconnect_account (candidate_id, cancellable);
                candidate_connection_attempted = false;
                yield credential_cleanup.schedule_cleanup (candidate_id);
                candidate_id = null;
            }

            // GOA credentials are short-lived and never persisted by us, so a
            // separate candidate connection provides no rollback protection.
            // Connect the real account once below and save it only after both
            // IMAP and SMTP have authenticated successfully.

            // Main-account sync and mutation flushing use the other Camel
            // session. Stop them before replacing credentials or services and
            // keep them suppressed through either commit or rollback. This
            // must happen before taking the outbound lane: an in-flight sync
            // can itself be finishing an Outbox retry on that lane.
            if (sync_service != null) {
                yield sync_service.quiesce_account (account.id);
                sync_quiesced = true;
            }
            // Acquire and invalidate before replacing real credentials. Keep
            // the lane until settings are committed (or fully rolled back), so
            // no PREPARING send can combine an old cached account with the new
            // password in the gap between a disconnect and the database save.
            outbound_lease = yield acquire_outbound_account_lease (
                account.id, cancellable);
            if (outbound_lease != null) outbound_lease.ensure_valid ();
            if (account.authentication == AuthenticationMode.PASSWORD) {
                yield credentials.store_password (account.id, "imap",
                    replacement_imap, cancellable);
                actual_credentials_changed = true;
                if (outbound_lease != null) outbound_lease.ensure_valid ();
                yield credentials.store_password (account.id, "smtp",
                    replacement_smtp, cancellable);
                if (outbound_lease != null) outbound_lease.ensure_valid ();
            }

            if (existing != null) {
                existing_disconnect_attempted = true;
                yield engine.disconnect_account (existing.id, cancellable);
                if (outbound_lease != null) outbound_lease.ensure_valid ();
            }
            actual_connection_attempted = true;
            yield engine.connect_account (account, cancellable);
            if (outbound_lease != null) outbound_lease.ensure_valid ();
            accounts.save_account (account);
        } catch (Error error) {
            if (candidate_connection_attempted && candidate_id != null) {
                try { yield engine.disconnect_account (candidate_id); }
                catch (Error disconnect_error) { debug ("Failed account candidate will be discarded later: %s", disconnect_error.message); }
            }
            if (candidate_id != null && account.authentication == AuthenticationMode.PASSWORD) {
                try { yield credential_cleanup.schedule_cleanup (candidate_id); }
                catch (Error cleanup_error) { warning ("Could not queue candidate credential cleanup: %s", cleanup_error.message); }
            }
            if (actual_connection_attempted) {
                try { yield engine.disconnect_account (account.id); }
                catch (Error disconnect_error) { debug ("Failed account connection will be discarded later: %s", disconnect_error.message); }
            }
            Error? rollback_error = null;
            if (actual_credentials_changed) {
                try {
                    yield credentials.clear_account (account.id);
                    if (old_imap != null) yield credentials.store_password (account.id, "imap", old_imap);
                    if (old_smtp != null) yield credentials.store_password (account.id, "smtp", old_smtp);
                } catch (Error restore_error) { rollback_error = restore_error; }
            }
            if (existing != null && existing_disconnect_attempted) {
                try { yield engine.connect_account (existing); }
                catch (Error reconnect_error) { if (rollback_error == null) rollback_error = reconnect_error; }
            }
            if (rollback_error != null)
                throw new MailError.STORAGE ("The account change failed and the previous connection could not be fully restored: " + rollback_error.message);
            throw error;
        } finally {
            if (outbound_lease != null) outbound_lease.release ();
            if (sync_quiesced && sync_service != null)
                sync_service.resume_account (account.id);
        }
    }

    internal async OutboundAccountSessionLease? acquire_outbound_account_lease (
        string account_id, Cancellable? cancellable = null) throws Error {
        if (outbound_service == null) return null;
        return yield outbound_service.acquire_account_session_lease (
            account_id, cancellable);
    }

    private static bool nonempty (string? value) {
        return value != null && value.strip () != "";
    }

    private static AccountSettings copy_with_id (AccountSettings source, string id) {
        var copy = new AccountSettings (); copy.id = id;
        copy.display_name = source.display_name; copy.email = source.email;
        copy.incoming_host = source.incoming_host; copy.incoming_port = source.incoming_port;
        copy.incoming_encryption = source.incoming_encryption; copy.incoming_username = source.incoming_username;
        copy.outgoing_host = source.outgoing_host; copy.outgoing_port = source.outgoing_port;
        copy.outgoing_encryption = source.outgoing_encryption; copy.outgoing_username = source.outgoing_username;
        copy.authentication = source.authentication; copy.online_account_path = source.online_account_path;
        return copy;
    }
}
}
