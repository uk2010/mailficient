namespace Mailficient {
public class AccountProvisioningService : Object {
    private AccountStore accounts;
    private CredentialStore credentials;
    private CredentialCleanupService credential_cleanup;
    private MailEngine engine;

    public AccountProvisioningService (AccountStore accounts, CredentialStore credentials,
                                       CredentialCleanupService credential_cleanup,
                                       MailEngine engine) {
        this.accounts = accounts; this.credentials = credentials;
        this.credential_cleanup = credential_cleanup; this.engine = engine;
    }

    public async void provision (AccountSettings account, string? incoming_password = null,
                                 string? outgoing_password = null,
                                 AccountSettings? existing = null,
                                 Cancellable? cancellable = null) throws Error {
        account.validate ();
        string? old_imap = null; string? old_smtp = null;
        string? candidate_id = null;
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

                candidate_id = "candidate-" + Uuid.string_random ();
                yield credentials.store_password (candidate_id, "imap", incoming, cancellable);
                yield credentials.store_password (candidate_id, "smtp", outgoing, cancellable);
                var candidate = copy_with_id (account, candidate_id);
                candidate_connection_attempted = true;
                yield engine.connect_account (candidate, cancellable);
                yield engine.disconnect_account (candidate_id, cancellable);
                candidate_connection_attempted = false;
                yield credential_cleanup.schedule_cleanup (candidate_id);
                candidate_id = null;

                yield credentials.store_password (account.id, "imap", incoming, cancellable);
                actual_credentials_changed = true;
                yield credentials.store_password (account.id, "smtp", outgoing, cancellable);
            }

            // GOA credentials are short-lived and never persisted by us, so a
            // separate candidate connection provides no rollback protection.
            // Connect the real account once below and save it only after both
            // IMAP and SMTP have authenticated successfully.

            if (existing != null) {
                existing_disconnect_attempted = true;
                yield engine.disconnect_account (existing.id, cancellable);
            }
            actual_connection_attempted = true;
            yield engine.connect_account (account, cancellable);
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
        }
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
