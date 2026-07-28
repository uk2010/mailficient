namespace Mailficient {
public enum SendDisposition { SENT, QUEUED }

public class OutboundService : Object {
    public signal void delivered (string draft_id);
    public signal void delivery_failed (string draft_id, UserFacingError error);
    public signal void sent_filing_failed (string draft_id, string detail);
    private CacheDatabase cache;
    private MailEngine? engine;
    private AttachmentService attachment_service;
    private bool scheduler_started;
    private Gee.HashMap<string, uint> scheduled_sources = new Gee.HashMap<string, uint> ();
    private Gee.HashSet<string> retrying_accounts = new Gee.HashSet<string> ();

    public OutboundService (CacheDatabase cache, MailEngine? engine, AttachmentService attachment_service) {
        this.cache = cache; this.engine = engine; this.attachment_service = attachment_service;
    }

    public async SendDisposition deliver (Draft draft, Cancellable? cancellable = null) throws Error {
        draft.validate_for_send ();
        // Durability precedes all network activity. A crash or connection failure
        // after this point leaves an explicit retryable outbox record.
        cache.queue_for_sending (draft);
        try { attachment_service.validate_draft_attachments (draft); }
        catch (Error error) {
            cache.record_send_failure (draft.id, error.message);
            if (error is MailError.ATTACHMENT) throw error;
            throw new MailError.ATTACHMENT (error.message);
        }
        if (engine == null || draft.account_id == "demo-account") return SendDisposition.QUEUED;
        var account = cache.find_account (draft.account_id);
        if (account == null) return SendDisposition.QUEUED;
        try { yield engine.connect_account (account, cancellable); }
        catch (Error error) {
            cache.record_send_failure (draft.id, error.message);
            if (error is MailError.AUTHENTICATION || error is MailError.TLS || error is MailError.OFFLINE ||
                error is MailError.TIMEOUT || error is MailError.RATE_LIMITED ||
                error is MailError.CANCELLED)
                throw error;
            throw new MailError.SEND_FAILED (error.message);
        }
        cache.mark_send_started (draft.id);
        SendResult result;
        try { result = yield engine.send (draft, cancellable); }
        catch (Error error) {
            // Protocol rejection, authentication, TLS, and local attachment
            // failures prove SMTP did not accept the message. Keep the normal
            // retryable queue. Lost transport, timeout, and cancellation after
            // SMTP ownership remain uncertain to avoid duplicate mail.
            if (error is MailError.SEND_REJECTED) {
                cache.record_send_rejection (draft.id, error.message);
                throw error;
            }
            if (error is MailError.SEND_FAILED || error is MailError.RATE_LIMITED ||
                error is MailError.AUTHENTICATION || error is MailError.TLS ||
                error is MailError.ATTACHMENT || error is MailError.INVALID_MESSAGE) {
                cache.record_send_failure (draft.id, error.message);
                throw error;
            }
            // Once SMTP transmission begins, a lost response can mean either
            // failure or acceptance. Automatic retry could duplicate mail.
            cache.record_send_uncertain (draft.id, error.message);
            throw new MailError.DELIVERY_UNCERTAIN (error.message);
        }
        try { cache.mark_send_accepted (draft.id); }
        catch (Error error) { warning ("Could not persist confirmed delivery state: %s", error.message); }
        finalize_accepted_draft (draft);
        if (!result.filed_to_sent) sent_filing_failed (draft.id, result.filing_warning);
        delivered (draft.id);
        return SendDisposition.SENT;
    }

    public void schedule (Draft draft, int64 not_before) throws Error {
        draft.validate_for_send ();
        if (not_before <= new DateTime.now_utc ().to_unix ())
            throw new MailError.INVALID_MESSAGE ("Choose a future delivery time");
        attachment_service.validate_draft_attachments (draft);
        cache.queue_for_sending (draft, not_before);
        if (scheduler_started) arm_account (draft.account_id);
    }

    public async void retry_pending (string account_id, bool due_only = true,
                                     Cancellable? cancellable = null) throws Error {
        if (engine == null) return;
        if (retrying_accounts.contains (account_id)) return;
        retrying_accounts.add (account_id);
        try {
            finalize_confirmed (account_id, cancellable);
            foreach (var draft in cache.list_pending_sends (account_id, due_only)) {
                if (cancellable != null) cancellable.set_error_if_cancelled ();
                try {
                    yield deliver (draft, cancellable);
                } catch (Error error) {
                    delivery_failed (draft.id, UserFacingError.from_error (error));
                }
            }
        } finally {
            retrying_accounts.remove (account_id);
            if (scheduler_started) arm_account (account_id);
        }
    }

    public void start_scheduler () {
        if (scheduler_started) return;
        scheduler_started = true;
        try {
            foreach (var account in cache.list_accounts ()) arm_account (account.id);
        } catch (Error error) {
            warning ("Could not start scheduled-send service: %s", error.message);
        }
    }

    public void stop_scheduler () {
        scheduler_started = false;
        foreach (uint source in scheduled_sources.values)
            if (source != 0) Source.remove (source);
        scheduled_sources.clear ();
    }

    public void outbox_changed (string account_id) {
        if (scheduler_started) arm_account (account_id);
    }

    private void arm_account (string account_id) {
        if (!scheduler_started || engine == null) return;
        uint existing = scheduled_sources.has_key (account_id) ? scheduled_sources[account_id] : 0;
        if (existing != 0) Source.remove (existing);
        scheduled_sources.unset (account_id);
        try {
            int64 now = new DateTime.now_utc ().to_unix ();
            int64 earliest = int64.MAX;
            foreach (var item in cache.list_outbox_items ()) {
                if (item.draft.account_id != account_id ||
                    item.delivery_state != OutboxDeliveryState.QUEUED) continue;
                earliest = int64.min (earliest, item.next_attempt_at);
            }
            if (earliest == int64.MAX) return;
            uint delay = (uint) int64.max (1, int64.min (86400, earliest - now));
            scheduled_sources[account_id] = Timeout.add_seconds (delay, () => {
                scheduled_sources.unset (account_id);
                retry_pending.begin (account_id, true);
                return Source.REMOVE;
            });
        } catch (Error error) {
            warning ("Could not schedule Outbox delivery: %s", error.message);
        }
    }

    public void finalize_confirmed (string account_id, Cancellable? cancellable = null) throws Error {
        foreach (var accepted in cache.list_accepted_sends (account_id)) {
            if (cancellable != null) cancellable.set_error_if_cancelled ();
            finalize_accepted_draft (accepted); delivered (accepted.id);
        }
    }

    private void finalize_accepted_draft (Draft draft) {
        foreach (var attachment in draft.attachments) {
            try { attachment_service.remove_private_copy (attachment); }
            catch (Error cleanup_error) { warning ("Could not remove a delivered attachment copy: %s", cleanup_error.message); }
        }
        try { cache.complete_send (draft.id); }
        catch (Error cleanup_error) {
            // The accepted state prevents another SMTP attempt. A later sync
            // retries this local-only cleanup.
            warning ("Could not remove a confirmed message from Outbox: %s", cleanup_error.message);
        }
    }
}
}
