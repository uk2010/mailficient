namespace Mailficient {
public enum SendDisposition { SENT, QUEUED }

// ComposeWindow needs to distinguish a failed preflight from a delivery whose
// SMTP result may be ambiguous. Database absence alone cannot do that: account
// removal can delete a preserved Draft/Outbox row without sending it. Keep the
// stage on a caller-owned object so it remains available when an async method
// throws.
public enum OutboundSendStage {
    KNOWN_PRE_PUBLICATION,
    PUBLICATION_UNKNOWN,
    OUTBOX_PUBLICATION_UNKNOWN,
    DRAFT_PRESERVED,
    OUTBOX_PUBLISHED,
    SMTP_NOT_ACCEPTED,
    SMTP_ACCEPTANCE_POSSIBLE,
    SMTP_ACCEPTED
}

public class OutboundSendProgress : Object {
    public OutboundSendStage stage { get; private set;
        default = OutboundSendStage.KNOWN_PRE_PUBLICATION; }

    internal void publication_became_unknown () {
        stage = OutboundSendStage.PUBLICATION_UNKNOWN;
    }

    internal void outbox_publication_became_unknown () {
        stage = OutboundSendStage.OUTBOX_PUBLICATION_UNKNOWN;
    }

    internal void mark_known_pre_publication () {
        stage = OutboundSendStage.KNOWN_PRE_PUBLICATION;
    }

    internal void mark_draft_preserved () {
        stage = OutboundSendStage.DRAFT_PRESERVED;
    }

    internal void mark_outbox_published () {
        stage = OutboundSendStage.OUTBOX_PUBLISHED;
    }

    internal void mark_smtp_not_accepted () {
        stage = OutboundSendStage.SMTP_NOT_ACCEPTED;
    }

    internal void mark_smtp_acceptance_possible () {
        stage = OutboundSendStage.SMTP_ACCEPTANCE_POSSIBLE;
    }

    internal void mark_smtp_accepted () {
        stage = OutboundSendStage.SMTP_ACCEPTED;
    }

    public bool outbox_was_or_may_have_been_published () {
        return stage == OutboundSendStage.OUTBOX_PUBLICATION_UNKNOWN ||
            stage == OutboundSendStage.OUTBOX_PUBLISHED ||
            stage == OutboundSendStage.SMTP_NOT_ACCEPTED ||
            stage == OutboundSendStage.SMTP_ACCEPTANCE_POSSIBLE ||
            stage == OutboundSendStage.SMTP_ACCEPTED;
    }

    public bool smtp_may_have_accepted () {
        return stage == OutboundSendStage.SMTP_ACCEPTANCE_POSSIBLE ||
            stage == OutboundSendStage.SMTP_ACCEPTED;
    }

    public bool definitely_pre_publication () {
        return stage == OutboundSendStage.KNOWN_PRE_PUBLICATION ||
            stage == OutboundSendStage.DRAFT_PRESERVED;
    }
}

private class OperationDeadline : Object {
    public Cancellable cancellable { get; private set; }
    public bool timed_out { get; private set; }
    private Cancellable? parent;
    private ulong parent_handler;
    private uint timeout_source;

    public OperationDeadline (uint timeout_seconds, Cancellable? parent = null) {
        cancellable = new Cancellable ();
        this.parent = parent;
        if (parent != null) {
            parent_handler = parent.cancelled.connect (() => {
                if (timeout_source != 0) {
                    Source.remove (timeout_source);
                    timeout_source = 0;
                }
                cancellable.cancel ();
            });
            if (parent.is_cancelled ()) {
                cancellable.cancel ();
                return;
            }
        }
        timeout_source = Timeout.add_seconds (uint.max (1, timeout_seconds), () => {
            timeout_source = 0;
            timed_out = true;
            cancellable.cancel ();
            return Source.REMOVE;
        });
    }

    public void close () {
        if (timeout_source != 0) {
            Source.remove (timeout_source);
            timeout_source = 0;
        }
        if (parent != null && parent_handler != 0) {
            parent.disconnect (parent_handler);
            parent_handler = 0;
        }
        parent = null;
    }
}

// A caller which changes or removes an account keeps this lease across every
// local commit that SMTP/IMAP depends on. Explicit release in a finally block
// is the normal path; the destructor is only a last-resort safety net.
internal class OutboundAccountSessionLease : Object {
    private OutboundService? owner;
    private string account_id;
    private string fence_owner;
    private int64 fence_lease_until;
    private uint renewal_source;
    private bool fence_valid = true;

    internal OutboundAccountSessionLease (OutboundService owner,
                                           string account_id,
                                           string fence_owner,
                                           int64 fence_lease_until) {
        this.owner = owner;
        this.account_id = account_id;
        this.fence_owner = fence_owner;
        this.fence_lease_until = fence_lease_until;
        renewal_source = Timeout.add_seconds (
            OutboundService.ACCOUNT_FENCE_RENEW_SECONDS, renew_fence);
    }

    private bool renew_fence () {
        var current_owner = owner;
        if (current_owner == null) {
            renewal_source = 0;
            return Source.REMOVE;
        }
        int64 now = new DateTime.now_utc ().to_unix ();
        int64 renewed_until = now +
            OutboundService.ACCOUNT_FENCE_LEASE_SECONDS;
        try {
            if (current_owner.renew_account_session_lease (
                    account_id, fence_owner, renewed_until)) {
                fence_lease_until = renewed_until;
                return Source.CONTINUE;
            }
            fence_valid = false;
            warning ("Outbound account maintenance ownership was lost for %s",
                account_id);
        } catch (Error error) {
            // A transient SQLite error does not erase the existing fence. Keep
            // retrying while its last confirmed deadline remains live.
            warning ("Could not renew outbound account maintenance for %s: %s",
                account_id, error.message);
            if (now < fence_lease_until) return Source.CONTINUE;
            fence_valid = false;
        }
        renewal_source = 0;
        return Source.REMOVE;
    }

    internal void ensure_valid () throws MailError {
        if (!fence_valid ||
            new DateTime.now_utc ().to_unix () >= fence_lease_until)
            throw new MailError.STORAGE (
                "Outbound account maintenance expired before it completed");
    }

    internal void release () {
        var current_owner = owner;
        if (current_owner == null) return;
        owner = null;
        if (renewal_source != 0) {
            Source.remove (renewal_source);
            renewal_source = 0;
        }
        current_owner.release_account_session_lease (
            account_id, fence_owner);
    }

    ~OutboundAccountSessionLease () {
        release ();
    }
}

public class OutboundService : Object {
    public const uint DEFAULT_CONNECTION_TIMEOUT_SECONDS = 30;
    public const uint DEFAULT_DELIVERY_TIMEOUT_SECONDS = 120;
    public const uint PREPARATION_LEASE_GRACE_SECONDS = 60;
    internal const int64 ACCOUNT_FENCE_LEASE_SECONDS = 60;
    internal const uint ACCOUNT_FENCE_RENEW_SECONDS = 10;
    private const uint ACCOUNT_FENCE_POLL_MILLISECONDS = 100;
    // A foreground Send writes the durable Outbox row first, then claims it
    // itself. Keeping the row briefly non-due prevents an already-running
    // background worker from stealing that first attempt between those two
    // operations. A crash still leaves it eligible almost immediately.
    public const int64 FOREGROUND_CLAIM_GRACE_SECONDS = 5;
    public signal void delivered (string draft_id);
    public signal void delivery_failed (string draft_id, UserFacingError error);
    public signal void sent_filing_failed (string draft_id, string detail);
    public signal void background_delivery_needed (string account_id);
    public signal void undo_send_available (string draft_id, string account_id,
                                            int64 undo_until);
    private CacheDatabase cache;
    private MailEngine? engine;
    private AttachmentService attachment_service;
    private bool scheduler_started;
    private Gee.HashMap<string, uint> scheduled_sources = new Gee.HashMap<string, uint> ();
    private Gee.HashSet<string> retrying_accounts = new Gee.HashSet<string> ();
    private Gee.HashSet<string> active_delivery_accounts = new Gee.HashSet<string> ();
    private signal void delivery_lane_released (string account_id);
    private uint connection_timeout_seconds;
    private uint delivery_timeout_seconds;

    public OutboundService (CacheDatabase cache, MailEngine? engine, AttachmentService attachment_service,
                            uint connection_timeout_seconds = DEFAULT_CONNECTION_TIMEOUT_SECONDS,
                            uint delivery_timeout_seconds = DEFAULT_DELIVERY_TIMEOUT_SECONDS) {
        this.cache = cache; this.engine = engine; this.attachment_service = attachment_service;
        this.connection_timeout_seconds = uint.max (1, connection_timeout_seconds);
        this.delivery_timeout_seconds = uint.max (1, delivery_timeout_seconds);
    }

    public async SendDisposition deliver (Draft draft,
                                           Cancellable? cancellable = null) throws Error {
        return yield deliver_with_authorization (draft, false, cancellable,
            "", null);
    }

    public async SendDisposition deliver_from_editor (
        Draft draft, string editor_owner,
        OutboundSendProgress? progress = null,
        Cancellable? cancellable = null) throws Error {
        return yield deliver_with_authorization (draft, false, cancellable,
            editor_owner, progress);
    }

    public async SendDisposition deliver_confirmed_resend (
        Draft draft, Cancellable? cancellable = null) throws Error {
        return yield deliver_with_authorization (draft, true, cancellable,
            "", null);
    }

    public async SendDisposition deliver_confirmed_resend_from_editor (
        Draft draft, string editor_owner,
        OutboundSendProgress? progress = null,
        Cancellable? cancellable = null) throws Error {
        return yield deliver_with_authorization (draft, true, cancellable,
            editor_owner, progress);
    }

    // The Undo Send window is a durable Outbox deadline, not an in-memory UI
    // timer. Foreground and background workers both use next_attempt_at and
    // therefore cannot acquire the SMTP preparation lease before it expires.
    public int64 defer_for_undo (Draft draft, int seconds,
                                 bool allow_uncertain_resend = false,
                                 string editor_owner = "",
                                 OutboundSendProgress? progress = null) throws Error {
        draft.validate_for_send ();
        attachment_service.validate_draft_attachments (draft);
        int bounded_seconds = int.max (5, int.min (30, seconds));
        int64 undo_until = new DateTime.now_utc ().to_unix () + bounded_seconds;
        if (progress != null) progress.outbox_publication_became_unknown ();
        try {
            cache.queue_for_undo_send (draft, undo_until,
                allow_uncertain_resend, editor_owner);
        } catch (Error error) {
            // Account validation occurs before any row mutation in the same
            // transaction, so this result is unambiguously pre-publication.
            // Storage failures remain UNKNOWN because COMMIT errors can be
            // ambiguous to the caller.
            if (progress != null && error is MailError.INVALID_ACCOUNT)
                progress.mark_known_pre_publication ();
            throw error;
        }
        if (progress != null) progress.mark_outbox_published ();
        undo_send_available (draft.id, draft.account_id, undo_until);
        request_background_delivery (draft.account_id);
        if (scheduler_started) arm_account (draft.account_id);
        return undo_until;
    }

    public bool cancel_undo_send (string draft_id, string account_id) throws Error {
        bool cancelled = cache.cancel_undo_send (draft_id);
        if (cancelled) {
            outbox_changed (account_id);
            // A fresh send returns to Drafts and may still need its provider-side
            // draft synchronized. Wake the same durable worker that owns that
            // work instead of waiting for its next periodic pass.
            request_background_delivery (account_id);
        }
        return cancelled;
    }

    private async SendDisposition deliver_with_authorization (
        Draft draft, bool allow_uncertain_resend, Cancellable? cancellable,
        string editor_owner, OutboundSendProgress? progress) throws Error {
        draft.validate_for_send ();
        // The composer has frozen autosave and editing. Persist that exact
        // snapshot before an async wait for another message on this account;
        // a quit or crash during the wait must leave recoverable content. The
        // same database transaction classifies an existing queue retry, so a
        // cross-process worker cannot claim an older snapshot in between.
        if (progress != null) progress.publication_became_unknown ();
        bool claim_existing_queue;
        try {
            claim_existing_queue = cache.preserve_draft_for_send (draft,
                allow_uncertain_resend, editor_owner);
        } catch (Error error) {
            // ensure_sending_account_exists() is the first operation under the
            // transaction, so INVALID_ACCOUNT cannot have preserved a row.
            if (progress != null && error is MailError.INVALID_ACCOUNT)
                progress.mark_known_pre_publication ();
            throw error;
        }
        if (progress != null) {
            if (claim_existing_queue) progress.mark_outbox_published ();
            else progress.mark_draft_preserved ();
        }
        // Own the account's outgoing lane before publishing a due Outbox row.
        // Otherwise a second foreground Send could wait behind the first long
        // enough for the resident worker to take it before its composer does.
        yield acquire_delivery_lane (draft.account_id, cancellable);
        try {
            // Durability precedes all network activity. A crash or connection
            // failure after this point leaves an explicit retryable row.
            if (!claim_existing_queue) {
                int64 fallback_at = new DateTime.now_utc ().to_unix () +
                    FOREGROUND_CLAIM_GRACE_SECONDS;
                if (progress != null)
                    progress.outbox_publication_became_unknown ();
                try {
                    cache.queue_for_sending (draft, fallback_at,
                        allow_uncertain_resend, editor_owner);
                } catch (Error error) {
                    // Account validation precedes mutation, so the earlier
                    // preserved Draft is still the newest known durable stage.
                    if (progress != null &&
                        error is MailError.INVALID_ACCOUNT)
                        progress.mark_draft_preserved ();
                    throw error;
                }
                if (progress != null) progress.mark_outbox_published ();
            }
            // The same scheduler also owns recovery of an abandoned active
            // SMTP lease. Arm it before network work starts so even a backend
            // that ignores cancellation cannot leave "Sending" on screen
            // indefinitely while this process remains alive.
            if (scheduler_started) arm_account (draft.account_id);
            // This explicit user action owns the first SMTP attempt. It may
            // ignore the short fallback timestamp, but never an Undo Send
            // fence (claim_queued_send enforces that independently).
            var disposition = yield attempt_queued_in_lane (
                draft, false, cancellable, editor_owner, progress);
            if (disposition == SendDisposition.QUEUED && claim_existing_queue &&
                cache.find_outbox_item (draft.id) == null) {
                // The only normal remover of a frozen existing Outbox row is a
                // successful competing worker. Do not reconstruct and resend
                // it. Account deletion is kept distinct from delivery.
                if (cache.find_account (draft.account_id) == null)
                    throw new MailError.INVALID_ACCOUNT (
                        "The sending account was removed while this message waited");
                if (cache.load_draft (draft.id) != null)
                    throw new MailError.STORAGE (
                        "The Outbox row disappeared without completing its draft");
                disposition = SendDisposition.SENT;
                delivered (draft.id);
            }
            if (disposition == SendDisposition.QUEUED) {
                request_background_delivery (draft.account_id);
            }
            // Clear or replace the active-lease recovery timer after either a
            // completed send or a newly backed-off queue state.
            if (scheduler_started) arm_account (draft.account_id);
            return disposition;
        } catch (Error error) {
            // Retryable failures have already released the lease and assigned
            // backoff. Rejected or uncertain sends are non-due, so waking the
            // fallback is harmless and cannot duplicate them.
            request_background_delivery (draft.account_id);
            if (scheduler_started) arm_account (draft.account_id);
            throw error;
        } finally {
            release_delivery_lane (draft.account_id);
        }
    }

    internal async SendDisposition attempt_queued (Draft draft, bool due_only,
                                                    Cancellable? cancellable) throws Error {
        yield acquire_delivery_lane (draft.account_id, cancellable);
        try {
            return yield attempt_queued_in_lane (draft, due_only, cancellable,
                "", null);
        } finally {
            release_delivery_lane (draft.account_id);
        }
    }

    // Account edits and removals must retire every service in the dedicated
    // outbound Camel session. The returned lease continues to exclude SMTP
    // and Sent filing while the caller commits credentials/settings or deletes
    // them, closing the gap a one-shot disconnect would leave.
    internal async OutboundAccountSessionLease? acquire_account_session_lease (
        string account_id, Cancellable? cancellable = null) throws Error {
        if (engine == null) return null;
        yield acquire_delivery_lane (account_id, cancellable);
        OutboundAccountSessionLease? lease = null;
        try {
            string fence_owner = Uuid.string_random ();
            int64 fence_until = 0;
            while (true) {
                fence_until = new DateTime.now_utc ().to_unix () +
                    ACCOUNT_FENCE_LEASE_SECONDS;
                if (cache.acquire_outbound_account_fence (
                        account_id, fence_owner, fence_until))
                    break;
                yield wait_for_account_fence_retry (cancellable);
            }
            lease = new OutboundAccountSessionLease (this, account_id,
                fence_owner, fence_until);
            // The transaction which installed the fence serialized with every
            // claim. Any cross-process attempt now visible was already active;
            // let it finish (or recover its bounded lease) before credentials
            // and connected services can be changed.
            while (cache.account_has_active_outbound_attempt (account_id)) {
                lease.ensure_valid ();
                yield wait_for_account_fence_retry (cancellable);
            }
            yield engine.disconnect_account (account_id, cancellable);
            lease.ensure_valid ();
        } catch (Error error) {
            if (lease != null) lease.release ();
            else release_delivery_lane (account_id);
            throw error;
        }
        return lease;
    }

    public async void invalidate_account_session (
        string account_id, Cancellable? cancellable = null) throws Error {
        var lease = yield acquire_account_session_lease (
            account_id, cancellable);
        // The session is already invalidated; this public convenience
        // operation intentionally performs no wider account mutation.
        if (lease != null) lease.release ();
    }

    private async void wait_for_account_fence_retry (
        Cancellable? cancellable) throws Error {
        Timeout.add (ACCOUNT_FENCE_POLL_MILLISECONDS, () => {
            wait_for_account_fence_retry.callback ();
            return Source.REMOVE;
        });
        yield;
        if (cancellable != null) cancellable.set_error_if_cancelled ();
    }

    internal bool renew_account_session_lease (string account_id,
                                                string fence_owner,
                                                int64 fence_until) throws Error {
        return cache.renew_outbound_account_fence (
            account_id, fence_owner, fence_until);
    }

    internal void release_account_session_lease (string account_id,
                                                  string fence_owner) {
        // Publish the durable boundary first. A same-process waiter remains
        // blocked on the local lane until the fence deletion has committed.
        try {
            cache.release_outbound_account_fence (account_id, fence_owner);
        } catch (Error error) {
            // Owner-CAS plus expiry makes this recoverable. Never leak the
            // in-memory lane if local storage becomes unavailable.
            warning ("Could not release outbound account maintenance for %s: %s",
                account_id, error.message);
        }
        release_delivery_lane (account_id);
    }

    private async void acquire_delivery_lane (string account_id,
                                               Cancellable? cancellable) throws Error {
        while (active_delivery_accounts.contains (account_id)) {
            ulong handler_id = 0;
            handler_id = delivery_lane_released.connect ((released_account) => {
                if (released_account != account_id) return;
                disconnect (handler_id);
                acquire_delivery_lane.callback ();
            });
            yield;
            if (cancellable != null) cancellable.set_error_if_cancelled ();
        }
        active_delivery_accounts.add (account_id);
    }

    private void release_delivery_lane (string account_id) {
        active_delivery_accounts.remove (account_id);
        delivery_lane_released (account_id);
    }

    private async SendDisposition attempt_queued_in_lane (
        Draft draft, bool due_only, Cancellable? cancellable,
        string editor_owner,
        OutboundSendProgress? progress = null) throws Error {
        // Demo and queue-only builds still perform the same attachment preflight,
        // but do not take a lease that no SMTP worker can complete.
        if (engine == null || draft.account_id == "demo-account" ||
            cache.find_account (draft.account_id) == null) {
            try { attachment_service.validate_draft_attachments (draft); }
            catch (Error error) {
                cache.record_send_failure (draft.id, error.message);
                if (error is MailError.ATTACHMENT) throw error;
                throw new MailError.ATTACHMENT (error.message);
            }
            return SendDisposition.QUEUED;
        }

        string lease_owner = Uuid.string_random ();
        int64 lease_until = new DateTime.now_utc ().to_unix () +
            (int64) connection_timeout_seconds + (int64) PREPARATION_LEASE_GRACE_SECONDS;
        if (!cache.claim_queued_send (draft.id, lease_owner, lease_until,
                due_only, editor_owner))
            return SendDisposition.QUEUED;

        // list_pending_sends() and a foreground composer can race: the worker's
        // in-memory Draft may predate the autosave that committed immediately
        // before this claim. The PREPARING transition now excludes all writers,
        // so reload under the claim and use only that durable snapshot for MIME,
        // SMTP, and final cleanup.
        Draft? durable_draft;
        try { durable_draft = cache.load_draft (draft.id); }
        catch (Error error) {
            cache.record_preparation_failure (draft.id, lease_owner, error.message);
            throw error;
        }
        if (durable_draft == null) {
            var missing = new MailError.STORAGE ("The queued message disappeared before it could be prepared");
            cache.record_preparation_failure (draft.id, lease_owner, missing.message);
            throw missing;
        }
        draft = durable_draft;

        try { attachment_service.validate_draft_attachments (draft); }
        catch (Error error) {
            cache.record_preparation_failure (draft.id, lease_owner, error.message);
            if (error is MailError.ATTACHMENT) throw error;
            throw new MailError.ATTACHMENT (error.message);
        }
        var account = cache.find_account (draft.account_id);
        if (account == null) {
            cache.record_preparation_failure (draft.id, lease_owner, "The sending account is no longer available");
            return SendDisposition.QUEUED;
        }
        var connection_deadline = new OperationDeadline (connection_timeout_seconds, cancellable);
        try {
            try {
                var outgoing_engine = engine as OutgoingMailEngine;
                if (outgoing_engine != null)
                    yield outgoing_engine.connect_outgoing_account (
                        account, connection_deadline.cancellable);
                else
                    yield engine.connect_account (account,
                        connection_deadline.cancellable);
            }
            finally { connection_deadline.close (); }
        }
        catch (Error error) {
            Error effective_error = connection_deadline.timed_out ?
                new MailError.TIMEOUT ("The mail server did not finish connecting within %u seconds".printf (
                    connection_timeout_seconds)) : error;
            cache.record_preparation_failure (draft.id, lease_owner, effective_error.message);
            if (effective_error is MailError.AUTHENTICATION || effective_error is MailError.TLS ||
                effective_error is MailError.OFFLINE || effective_error is MailError.TIMEOUT ||
                effective_error is MailError.RATE_LIMITED || effective_error is MailError.CANCELLED)
                throw effective_error;
            throw new MailError.SEND_FAILED (effective_error.message);
        }
        // This conditional transition is the last local operation before SMTP.
        // If another process recovered an expired lease, we stop here and that
        // process remains the sole sender.
        cache.mark_send_started (draft.id, lease_owner,
            new DateTime.now_utc ().to_unix () +
            (int64) delivery_timeout_seconds +
            (int64) PREPARATION_LEASE_GRACE_SECONDS);
        if (progress != null) progress.mark_smtp_acceptance_possible ();
        SendResult result = new SendResult ();
        var delivery_deadline = new OperationDeadline (delivery_timeout_seconds, cancellable);
        try {
            try { result = yield engine.send (draft, delivery_deadline.cancellable); }
            finally { delivery_deadline.close (); }
        }
        catch (Error error) {
            Error effective_error = delivery_deadline.timed_out ?
                new MailError.TIMEOUT ("The mail server did not finish sending within %u seconds".printf (
                    delivery_timeout_seconds)) : error;
            // Protocol rejection, authentication, TLS, and local attachment
            // failures prove SMTP did not accept the message. Keep the normal
            // retryable queue. Lost transport, timeout, and cancellation after
            // SMTP ownership remain uncertain to avoid duplicate mail.
            if (effective_error is MailError.SEND_REJECTED) {
                if (!cache.record_send_rejection (draft.id,
                        effective_error.message, lease_owner))
                    throw stale_delivery_attempt ();
                if (progress != null) progress.mark_smtp_not_accepted ();
                throw effective_error;
            }
            if (effective_error is MailError.SEND_FAILED || effective_error is MailError.RATE_LIMITED ||
                effective_error is MailError.AUTHENTICATION || effective_error is MailError.TLS ||
                effective_error is MailError.ATTACHMENT || effective_error is MailError.INVALID_MESSAGE) {
                if (!cache.record_send_failure (draft.id,
                        effective_error.message, lease_owner))
                    throw stale_delivery_attempt ();
                if (progress != null) progress.mark_smtp_not_accepted ();
                throw effective_error;
            }
            // Once SMTP transmission begins, a lost response can mean either
            // failure or acceptance. Automatic retry could duplicate mail.
            cache.record_send_uncertain (draft.id, effective_error.message,
                lease_owner);
            throw new MailError.DELIVERY_UNCERTAIN (effective_error.message);
        }
        if (progress != null) progress.mark_smtp_accepted ();
        bool accepted;
        try { accepted = cache.mark_send_accepted (draft.id, lease_owner); }
        catch (Error error) {
            warning ("Could not persist confirmed delivery state: %s", error.message);
            throw new MailError.DELIVERY_UNCERTAIN (
                "The server accepted this message, but Mailficient could not preserve its final Outbox state: %s".printf (
                    error.message));
        }
        if (!accepted) throw stale_delivery_attempt ();
        finalize_accepted_draft (draft);
        if (!result.filed_to_sent) sent_filing_failed (draft.id, result.filing_warning);
        delivered (draft.id);
        return SendDisposition.SENT;
    }

    private static Error stale_delivery_attempt () {
        return new MailError.DELIVERY_UNCERTAIN (
            "This SMTP attempt finished after its Outbox lease was recovered; a newer Outbox state was left unchanged");
    }

    public void schedule (Draft draft, int64 not_before,
                          string editor_owner = "") throws Error {
        draft.validate_for_send ();
        if (not_before <= new DateTime.now_utc ().to_unix ())
            throw new MailError.INVALID_MESSAGE ("Choose a future delivery time");
        attachment_service.validate_draft_attachments (draft);
        cache.queue_for_sending (draft, not_before, false, editor_owner);
        request_background_delivery (draft.account_id);
        if (scheduler_started) arm_account (draft.account_id);
    }

    private void request_background_delivery (string account_id) {
        try {
            // Queue-only/demo identities remain fully testable, but they have
            // no provider work and must never spawn a resident process or ask
            // the Flatpak portal for background access.
            if (cache.find_account (account_id) != null)
                background_delivery_needed (account_id);
        } catch (MailError error) {
            warning ("Could not inspect background Outbox activation: %s", error.message);
        }
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
                    yield attempt_queued (draft, due_only, cancellable);
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
            int64? next = cache.next_outbox_attempt (account_id);
            if (next == null) return;
            int64 earliest = (int64) next;
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
