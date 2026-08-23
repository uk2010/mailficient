namespace Mailficient {
public class CredentialCleanupService : Object {
    private CacheDatabase cache;
    private CredentialStore credentials;

    public CredentialCleanupService (CacheDatabase cache, CredentialStore credentials) {
        this.cache = cache; this.credentials = credentials;
    }

    public async bool cleanup_account (string account_id, Cancellable? cancellable = null) {
        try {
            // A deterministic provider identity may have been re-imported
            // before a previous cleanup attempt ran. Never clear a live account.
            if (cache.find_account (account_id) != null) {
                cache.complete_credential_cleanup (account_id);
                return true;
            }
            yield credentials.clear_account (account_id, cancellable);
            cache.complete_credential_cleanup (account_id);
            return true;
        } catch (Error error) {
            debug ("Secure credential cleanup remains queued: %s", error.message);
            return false;
        }
    }

    public async bool schedule_cleanup (string account_id, Cancellable? cancellable = null) throws MailError {
        cache.queue_credential_cleanup (account_id);
        return yield cleanup_account (account_id, cancellable);
    }

    public async void retry_pending (Cancellable? cancellable = null) {
        try {
            foreach (var account_id in cache.list_pending_credential_cleanups ()) {
                if (cancellable != null && cancellable.is_cancelled ()) return;
                yield cleanup_account (account_id, cancellable);
            }
        } catch (Error error) {
            debug ("Could not inspect pending credential cleanup: %s", error.message);
        }
    }
}
}
