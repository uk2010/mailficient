namespace Mailficient {
internal class SyncPassOutcome : Object {
    public bool completed { get; set; default = false; }
    public bool cancelled { get; set; default = false; }
    public bool more_messages_available { get; set; default = false; }
    // Preserve the server's raw continuation state even when an issue stops
    // automatic retries for this check. Initial-import notification suppression
    // must remain active until a later authoritative pass says history is done.
    public bool history_incomplete { get; set; default = false; }
    public int messages_downloaded { get; set; default = 0; }
    public int maintenance_items_processed { get; set; default = 0; }
    public bool retryable_failure { get; set; default = false; }
    public UserFacingError? warning { get; set; }
    public NewMailSummary? new_mail { get; set; }
}

internal class SyncProgressContext : Object {
    public int messages_total { get; set; default = 0; }
    public int messages_completed { get; set; default = 0; }
    public double last_fraction { get; set; default = 0; }
}

public class AccountSyncService : Object {
    public signal void synchronized (string account_id);
    public signal void failed (string account_id, UserFacingError error);
    public signal void cancelled (string account_id);
    public signal void new_message (Message message);
    public signal void new_mail_summary (NewMailSummary summary);
    public signal void mail_available (string account_id);
    public signal void pass_completed (string account_id);
    public signal void mail_check_completed (string account_id, int messages_downloaded);
    public signal void progress_changed (string account_id, double fraction, string detail);
    private signal void pending_flush_finished (string account_id);
    private signal void account_sync_finished (string account_id);

    private CacheDatabase cache;
    private MailEngine engine;
    private OutboundService outbound;
    private JunkFilterService junk_filter;
    private MailRuleService mail_rules;
    private VacationResponderService vacation_responder;
    private DraftSyncService draft_sync;
    private LiveMailCoordinator live_mail = new LiveMailCoordinator ();
    private Cancellable? active;
    private Gee.HashSet<string> suppressed_accounts = new Gee.HashSet<string> ();
    private Gee.HashSet<string> flushing_accounts = new Gee.HashSet<string> ();
    private Gee.HashSet<string> flush_again = new Gee.HashSet<string> ();
    private Gee.HashSet<string> syncing_accounts = new Gee.HashSet<string> ();
    private Gee.HashMap<string, Cancellable> sync_cancellables = new Gee.HashMap<string, Cancellable> ();
    private Gee.HashSet<string> sync_again = new Gee.HashSet<string> ();
    private Gee.HashMap<string, uint> queued_flush_sources = new Gee.HashMap<string, uint> ();
    private Gee.HashMap<string, uint> queued_history_sources = new Gee.HashMap<string, uint> ();
    // Scheduled bounded passes are one logical mail check. Retain their
    // counters so the next fresh backend session cannot restart progress at
    // zero or report its per-session completion as logical completion.
    private Gee.HashMap<string, SyncProgressContext> progress_contexts =
        new Gee.HashMap<string, SyncProgressContext> ();
    // Keep user actions responsive while coalescing repeated flag/move events.
    // Tests use a shorter interval to exercise the same scheduling path
    // deterministically without adding five seconds to the suite.
    internal uint pending_flush_delay_milliseconds = 5000;
    // A bounded account check may span several fresh Camel sessions. Keep only
    // the small NewMailSummary sample here and publish once when that logical
    // backfill finishes, instead of notifying five times per 250-message pass.
    private Gee.HashMap<string, NewMailSummary> pending_new_mail =
        new Gee.HashMap<string, NewMailSummary> ();
    // The first account import is not an arrival event. Keep suppression across
    // all fresh sessions needed to drain it, even though pass two has a cache.
    private Gee.HashSet<string> initial_backfill_accounts = new Gee.HashSet<string> ();

    public AccountSyncService (CacheDatabase cache, MailEngine engine, OutboundService outbound,
                               JunkFilterService junk_filter,
                               AttachmentService? attachment_service = null) {
        this.cache = cache;
        this.engine = engine;
        this.outbound = outbound;
        this.junk_filter = junk_filter;
        this.mail_rules = new MailRuleService (cache);
        this.vacation_responder = new VacationResponderService (cache, outbound);
        this.draft_sync = new DraftSyncService (cache, engine, attachment_service);
        cache.mutation_queued.connect (schedule_pending_flush);
        weak AccountSyncService weak_service = this;
        engine.live_mail_changed.connect ((account_id) => {
            if (weak_service != null) weak_service.live_mail.live_mail_changed (account_id);
        });
        engine.live_mail_unavailable.connect ((account_id) => {
            if (weak_service != null) weak_service.live_mail.live_mail_unavailable (account_id);
        });
        live_mail.sync_requested.connect ((account_id, reason) => {
            if (weak_service != null) weak_service.handle_live_sync_request (account_id);
        });
    }

    private void handle_live_sync_request (string account_id) {
        try {
            var account = cache.find_account (account_id);
            if (account == null) {
                live_mail.suppress_account (account_id);
                return;
            }
            sync_account.begin (account);
        } catch (Error error) {
            live_mail.sync_failed (account_id, false);
            failed (account_id, UserFacingError.from_error (error));
        }
    }

    private void schedule_pending_flush (string account_id) {
        if (suppressed_accounts.contains (account_id)) return;
        uint existing = queued_flush_sources.has_key (account_id) ? queued_flush_sources[account_id] : 0;
        if (existing != 0) Source.remove (existing);
        queued_flush_sources[account_id] = Timeout.add (
            uint.max (1, pending_flush_delay_milliseconds), () => {
            queued_flush_sources.unset (account_id);
            // A sync pass and a standalone mutation flush both use the same
            // account-scoped Camel store. Running an Empty Junk/Trash request
            // beside synchronize() can make provider callbacks race folder
            // teardown, a lifecycle hazard consistent with native allocator
            // corruption. The active sync flushes this durable queue itself;
            // retain a delayed wake-up only as a fallback if that pass fails
            // before doing so.
            if (syncing_accounts.contains (account_id)) {
                schedule_pending_flush (account_id);
                return Source.REMOVE;
            }
            flush_pending.begin (account_id);
            return Source.REMOVE;
        });
    }

    private async void wait_for_active_flush (string account_id) {
        if (!flushing_accounts.contains (account_id)) return;
        ulong handler_id = 0;
        handler_id = pending_flush_finished.connect ((finished_account_id) => {
            if (finished_account_id != account_id) return;
            disconnect (handler_id);
            wait_for_active_flush.callback ();
        });
        yield;
    }

    public async void sync_account (AccountSettings account, Cancellable? cancellable = null) {
        if (suppressed_accounts.contains (account.id)) return;
        // The timeout callback checks syncing_accounts before it starts a
        // standalone flush. Complete the opposite half of that exclusion here
        // so a sync cannot begin while an already-started remote mutation is
        // still using the account's Camel objects.
        yield wait_for_active_flush (account.id);
        if (suppressed_accounts.contains (account.id)) return;
        if (syncing_accounts.contains (account.id)) {
            sync_again.add (account.id);
            ulong handler_id = 0;
            handler_id = account_sync_finished.connect ((finished_account_id) => {
                if (finished_account_id != account.id) return;
                disconnect (handler_id); sync_account.callback ();
            });
            yield;
            return;
        }
        syncing_accounts.add (account.id);
        if (!initial_backfill_accounts.contains (account.id)) {
            try {
                if (cache.cached_message_count (account.id) == 0)
                    initial_backfill_accounts.add (account.id);
            } catch (Error error) {
                syncing_accounts.remove (account.id);
                failed (account.id, UserFacingError.from_error (error));
                account_sync_finished (account.id);
                return;
            }
        }
        var effective_cancellable = cancellable ?? new Cancellable ();
        sync_cancellables[account.id] = effective_cancellable;
        SyncPassOutcome? last_outcome = null;
        var progress_context = progress_contexts[account.id];
        if (progress_context == null) {
            progress_context = new SyncProgressContext ();
            progress_contexts[account.id] = progress_context;
        }
        bool allow_notifications = !initial_backfill_accounts.contains (account.id);
        do {
            sync_again.remove (account.id);
            last_outcome = new SyncPassOutcome ();
            yield perform_sync (account, effective_cancellable, allow_notifications,
                progress_context, last_outcome);
            accumulate_new_mail (account, last_outcome.new_mail);
            progress_context.messages_completed += last_outcome.messages_downloaded;
            progress_context.messages_total = int.max (progress_context.messages_total,
                progress_context.messages_completed);
            if (last_outcome.more_messages_available) {
                // The cache is checkpointed before perform_sync returns. Remove
                // the account's Camel services now so the next bounded pass owns
                // a fresh backend session instead of retaining the prior MIME and
                // folder-summary object graph across the whole history import.
                try {
                    yield engine.disconnect_account (account.id, effective_cancellable);
                } catch (Error error) {
                    last_outcome.more_messages_available = false;
                    last_outcome.completed = false;
                    if (error is IOError.CANCELLED) last_outcome.cancelled = true;
                    else {
                        last_outcome.retryable_failure = is_retryable_live_error (error);
                        failed (account.id, UserFacingError.from_error (error));
                    }
                    break;
                }
                // A bounded pass keeps Get Mail responsive. Continue older
                // history in the background so a single check still drains
                // every message instead of stopping at the per-pass limit.
                pass_completed (account.id);
                double fraction = progress_context.messages_total > 0 ?
                    progress_context.messages_completed / (double) progress_context.messages_total : 0;
                string continuation_detail = progress_context.messages_total > 0 ?
                    "Downloaded %d of %d messages — continuing in background".printf (
                        progress_context.messages_completed, progress_context.messages_total) :
                    "Refreshing synchronized drafts — continuing in background";
                report_progress (account.id, progress_context, fraction,
                    continuation_detail);
                if (!sync_again.contains (account.id)) schedule_history_continuation (account);
            }
        } while (!suppressed_accounts.contains (account.id) && sync_again.contains (account.id));
        bool logical_completion = !suppressed_accounts.contains (account.id) &&
            last_outcome != null && last_outcome.completed &&
            !last_outcome.more_messages_available;
        if (logical_completion) {
            report_progress (account.id, progress_context, 1, "Mail is up to date", true);
            progress_contexts.unset (account.id);
        } else if (last_outcome == null || !last_outcome.completed) {
            progress_contexts.unset (account.id);
        }
        if (logical_completion) {
            synchronized (account.id);
            mail_check_completed (account.id, progress_context.messages_completed);
            if (last_outcome.warning != null) failed (account.id, last_outcome.warning);
        } else if (!suppressed_accounts.contains (account.id) && last_outcome != null &&
                   last_outcome.cancelled) {
            cancelled (account.id);
        }
        if (!suppressed_accounts.contains (account.id) && last_outcome != null &&
            last_outcome.completed && !last_outcome.more_messages_available) {
            publish_new_mail (account.id);
            if (!last_outcome.history_incomplete)
                initial_backfill_accounts.remove (account.id);
        }
        else if (last_outcome == null || !last_outcome.completed)
            pending_new_mail.unset (account.id);
        if (last_outcome != null) {
            if (last_outcome.retryable_failure)
                live_mail.sync_failed (account.id, true);
            else if (last_outcome.completed)
                live_mail.sync_succeeded (account.id);
            else if (!last_outcome.cancelled)
                live_mail.sync_failed (account.id, false);
        }
        if (sync_cancellables[account.id] == effective_cancellable)
            sync_cancellables.unset (account.id);
        sync_again.remove (account.id); syncing_accounts.remove (account.id);
        account_sync_finished (account.id);
    }

    private async void perform_sync (AccountSettings account, Cancellable? cancellable,
                                     bool allow_notifications,
                                     SyncProgressContext progress_context,
                                     SyncPassOutcome outcome) {
        var progress_state = engine.state_for (account.id);
        Error? batch_error = null;
        bool established_cache = false;
        Gee.Set<string>? known_ids = null;
        var new_mail = new NewMailSummary (account.id, account.email);
        var remote_drafts = new Gee.ArrayList<RemoteDraftSnapshot> ();
        ulong batch_handler = engine.sync_batch_ready.connect ((batch) => {
            if (batch.account_id != account.id || suppressed_accounts.contains (account.id) || batch_error != null)
                return;
            try {
                cache.store_sync_result (batch);
                foreach (var remote_draft in batch.remote_drafts)
                    remote_drafts.add (remote_draft);
                junk_filter.apply (batch);
                // Adding an account imports history; it is not an arrival
                // event. Never let a newly configured on-device rule move or
                // trash that history without the explicit previewed Run Now
                // flow in the Rules window.
                if (allow_notifications && established_cache)
                    mail_rules.apply (batch);
                // Camel publishes the complete folder inventory before it
                // starts fetching messages. Persist that metadata immediately,
                // but do not wake the message list for an inventory-only batch.
                // The synchronized edge reconciles mailbox structure and
                // counts once the authoritative snapshot is stored.
                if (batch.messages.size > 0) mail_available (account.id);
                if (allow_notifications && established_cache && known_ids != null) {
                    var inbox_ids = new Gee.HashSet<string> ();
                    foreach (var mailbox in batch.mailboxes)
                        if (mailbox.role == MailboxRole.INBOX) inbox_ids.add (mailbox.id);
                    foreach (var message in batch.messages) {
                        if (message.unread && inbox_ids.contains (message.mailbox_id) &&
                            !known_ids.contains (message.id)) new_mail.add (message);
                    }
                }
            } catch (Error error) {
                batch_error = error;
            }
        });
        ulong progress_handler = progress_state.notify.connect ((property) => {
            if (property.name != "progress" && property.name != "detail" &&
                property.name != "messages-to-download" && property.name != "messages-downloaded")
                return;
            // connect_incoming_account() reuses this SyncState and changes its
            // connection detail before synchronize() clears the prior pass's
            // message counters. Do not fold those stale counters into the
            // logical total for the next bounded pass.
            if (progress_state.phase != SyncPhase.SYNCHRONIZING) {
                report_progress (account.id, progress_context,
                    progress_context.last_fraction, progress_state.detail);
                return;
            }
            if (progress_state.messages_to_download > 0) {
                int candidate_total = progress_context.messages_completed +
                    progress_state.messages_to_download;
                progress_context.messages_total = int.max (
                    progress_context.messages_total, candidate_total);
                int completed = progress_context.messages_completed +
                    progress_state.messages_downloaded;
                double fraction = completed / (double) progress_context.messages_total;
                report_progress (account.id, progress_context, fraction,
                    "Downloaded %d of %d messages".printf (
                        completed, progress_context.messages_total));
            } else if (progress_context.messages_total > 0) {
                double fraction = progress_context.messages_completed /
                    (double) progress_context.messages_total;
                report_progress (account.id, progress_context, fraction,
                    "Downloaded %d of %d messages — checking messages…".printf (
                        progress_context.messages_completed, progress_context.messages_total));
            } else if (property.name == "progress") {
                report_progress (account.id, progress_context,
                    progress_state.progress, progress_state.detail);
            } else {
                // At synchronize() entry Camel clears counters and detail
                // before lowering a stale per-session progress value. Preserve
                // the logical fraction until that progress notification lands.
                report_progress (account.id, progress_context,
                    progress_context.last_fraction, progress_state.detail);
            }
        });
        string initial_detail = progress_context.messages_total > 0 ?
            "Downloaded %d of %d messages — checking messages…".printf (
                progress_context.messages_completed, progress_context.messages_total) :
            "Checking messages…";
        report_progress (account.id, progress_context,
            progress_context.last_fraction, initial_detail);
        try {
            // Confirmed SMTP deliveries only need local cleanup and must not
            // wait for a network connection to return.
            outbound.finalize_confirmed (account.id, cancellable);
            // Mail checks only need the incoming IMAP service. SMTP is opened
            // lazily by outbound delivery instead of delaying every refresh.
            yield engine.connect_incoming_account (account, cancellable);
            // SMTP has its own connection lane and lifetime. Canceling Get
            // Mail must never cancel a Send after the user has committed it.
            yield outbound.retry_pending (account.id, true, null);
            yield flush_pending (account.id, cancellable);
            int cached_before = cache.cached_message_count (account.id);
            established_cache = cached_before > 0;
            known_ids = established_cache ? cache.cached_message_ids (account.id) : new Gee.HashSet<string> ();
            var extracted_ids = established_cache ?
                cache.cached_extracted_message_ids (account.id) : new Gee.HashSet<string> ();
            var snapshot = yield engine.synchronize (account.id, extracted_ids, cancellable);
            if (suppressed_accounts.contains (account.id)) return;
            outcome.history_incomplete = snapshot.more_messages_available;
            if (batch_error != null) throw batch_error;
            cache.store_sync_result (snapshot);
            foreach (var remote_draft in snapshot.remote_drafts)
                remote_drafts.add (remote_draft);
            junk_filter.apply (snapshot);
            if (allow_notifications && established_cache)
                mail_rules.apply (snapshot);
            try {
                // Import while the received-attachment cache paths emitted by
                // Camel are still referenced by this completed sync pass.
                draft_sync.reconcile_remote_deletions (snapshot);
                yield draft_sync.import_remote_drafts (remote_drafts, cancellable);
            } catch (Error draft_error) {
                snapshot.record_issue ("Drafts", draft_error);
            }
            try { yield draft_sync.synchronize_account (account.id, cancellable); }
            catch (Error draft_error) { snapshot.record_issue ("Drafts", draft_error); }
            yield vacation_responder.respond (snapshot, cancellable);
            yield flush_pending (account.id, cancellable);
            int cached_after = cache.cached_message_count (account.id);
            outcome.messages_downloaded = int.max (
                int.max (0, cached_after - cached_before), progress_state.messages_downloaded);
            outcome.maintenance_items_processed = snapshot.maintenance_items_processed;
            if (allow_notifications && established_cache && known_ids != null) {
                var inbox_ids = new Gee.HashSet<string> ();
                foreach (var mailbox in snapshot.mailboxes)
                    if (mailbox.role == MailboxRole.INBOX) inbox_ids.add (mailbox.id);
                foreach (var message in snapshot.messages) {
                    if (message.unread && inbox_ids.contains (message.mailbox_id) &&
                        !known_ids.contains (message.id)) new_mail.add (message);
                }
            }
            outcome.completed = true;
            if (snapshot.more_messages_available && snapshot.issues.size == 0 &&
                snapshot.terminal_error == null) {
                if (outcome.messages_downloaded > 0 || outcome.maintenance_items_processed > 0)
                    outcome.more_messages_available = true;
                else outcome.warning = UserFacingError.from_error (new MailError.PARTIAL_SYNC (
                    "The server reported more mail, but this pass could not save another message. Automatic backfill stopped to avoid an endless retry."));
            }
            if (snapshot.issues.size > 0) {
                Error issue_error;
                if (snapshot.terminal_error != null) issue_error = snapshot.terminal_error;
                else issue_error = new MailError.PARTIAL_SYNC (snapshot.issue_summary ());
                outcome.warning = UserFacingError.from_error (issue_error);
            }
            if (snapshot.terminal_error != null)
                outcome.retryable_failure = is_retryable_live_error (snapshot.terminal_error);
        } catch (Error error) {
            if (error is IOError.CANCELLED) outcome.cancelled = true;
            else {
                outcome.retryable_failure = is_retryable_live_error (error);
                failed (account.id, UserFacingError.from_error (error));
            }
        } finally {
            engine.disconnect (batch_handler);
            progress_state.disconnect (progress_handler);
            outcome.new_mail = new_mail;
        }
    }

    private void report_progress (string account_id, SyncProgressContext context,
                                  double fraction, string detail,
                                  bool logical_completion = false) {
        // Backend progress is scoped to one Camel session. A bounded history
        // import may need several such sessions, so never expose a session's
        // 100% until the returned snapshot confirms there is no continuation.
        // MailWindow rounds the fraction to a whole-number percentage. Keep a
        // non-final session at 99% or below so it cannot visibly claim 100%.
        double bounded = logical_completion ? 1 : double.min (fraction, 0.99);
        bounded = double.max (0, bounded);
        bounded = double.max (context.last_fraction, bounded);
        context.last_fraction = bounded;
        progress_changed (account_id, bounded, detail);
    }

    private void accumulate_new_mail (AccountSettings account, NewMailSummary? addition) {
        if (addition == null || addition.total == 0 ||
            suppressed_accounts.contains (account.id)) return;
        var aggregate = pending_new_mail[account.id];
        if (aggregate == null) {
            aggregate = new NewMailSummary (account.id, account.email);
            pending_new_mail[account.id] = aggregate;
        }
        aggregate.merge (addition);
    }

    private void publish_new_mail (string account_id) {
        var summary = pending_new_mail[account_id];
        pending_new_mail.unset (account_id);
        if (summary == null || summary.total == 0) return;
        foreach (var message in summary.samples) new_message (message);
        new_mail_summary (summary);
    }

    public async void sync_all () {
        if (active != null) return;
        active = new Cancellable ();
        try {
            foreach (var account in cache.list_accounts ())
                yield sync_account (account, active);
        } catch (Error error) {
            failed ("", UserFacingError.from_error (error));
        }
        active = null;
    }

    public void cancel () {
        if (active != null) active.cancel ();
        foreach (var cancellable in sync_cancellables.values) cancellable.cancel ();
        // A logical backfill remains active during its 250 ms inter-pass gap,
        // but has no Cancellable that can later publish a terminal edge. Tell
        // the UI about those stopped checks before discarding their contexts.
        var stopped_accounts = new Gee.HashSet<string> ();
        foreach (var account_id in progress_contexts.keys)
            if (!syncing_accounts.contains (account_id)) stopped_accounts.add (account_id);
        foreach (var account_id in queued_history_sources.keys)
            if (!syncing_accounts.contains (account_id)) stopped_accounts.add (account_id);
        foreach (var source in queued_history_sources.values)
            if (source != 0) Source.remove (source);
        queued_history_sources.clear ();
        progress_contexts.clear ();
        pending_new_mail.clear ();
        // Cancellation pauses a bounded initial import; it does not turn the
        // remaining server history into a live arrival. Retain this marker so
        // an in-process resume remains silent until a no-more-work pass.
        live_mail.cancel_all ();
        foreach (var account_id in stopped_accounts) cancelled (account_id);
    }

    public void suppress_account (string account_id) {
        bool stopped_active_sync = progress_contexts.has_key (account_id) ||
            queued_history_sources.has_key (account_id);
        suppressed_accounts.add (account_id);
        live_mail.suppress_account (account_id);
        uint history_source = queued_history_sources.has_key (account_id) ?
            queued_history_sources[account_id] : 0;
        if (history_source != 0) Source.remove (history_source);
        queued_history_sources.unset (account_id);
        uint flush_source = queued_flush_sources.has_key (account_id) ?
            queued_flush_sources[account_id] : 0;
        if (flush_source != 0) Source.remove (flush_source);
        queued_flush_sources.unset (account_id);
        flush_again.remove (account_id);
        progress_contexts.unset (account_id);
        pending_new_mail.unset (account_id);
        initial_backfill_accounts.remove (account_id);
        var cancellable = sync_cancellables[account_id];
        if (cancellable != null) cancellable.cancel ();
        // sync_account deliberately suppresses its later terminal signals once
        // this account is hidden. Publish exactly one edge here so a window
        // that already saw progress can retire its account-scoped UI state.
        if (stopped_active_sync) cancelled (account_id);
    }

    // Account settings and removal may replace the Camel services and the
    // server identity behind an existing account id. Suppress new work,
    // cancel the current sync, and do not return until every account-scoped
    // sync/mutation operation has stopped touching the engine or cache.
    public async void quiesce_account (string account_id) {
        suppress_account (account_id);
        while (syncing_accounts.contains (account_id) ||
               flushing_accounts.contains (account_id)) {
            bool resumed = false;
            ulong sync_handler = 0;
            ulong flush_handler = 0;
            sync_handler = account_sync_finished.connect ((finished_id) => {
                if (finished_id != account_id || resumed) return;
                resumed = true;
                disconnect (sync_handler);
                disconnect (flush_handler);
                quiesce_account.callback ();
            });
            flush_handler = pending_flush_finished.connect ((finished_id) => {
                if (finished_id != account_id || resumed) return;
                resumed = true;
                disconnect (sync_handler);
                disconnect (flush_handler);
                quiesce_account.callback ();
            });
            yield;
        }
    }

    public void resume_account (string account_id) {
        suppressed_accounts.remove (account_id);
        live_mail.resume_account (account_id);
    }

    internal static bool is_retryable_live_error (Error error) {
        return error is MailError.CONNECTION || error is MailError.OFFLINE ||
            error is MailError.TIMEOUT || error is MailError.RATE_LIMITED;
    }

    private void schedule_history_continuation (AccountSettings account) {
        if (suppressed_accounts.contains (account.id) || queued_history_sources.has_key (account.id)) return;
        queued_history_sources[account.id] = Timeout.add (250, () => {
            queued_history_sources.unset (account.id);
            if (!suppressed_accounts.contains (account.id)) sync_account.begin (account);
            return Source.REMOVE;
        });
    }

    private async void flush_pending (string account_id, Cancellable? cancellable = null) {
        if (suppressed_accounts.contains (account_id)) return;
        if (queued_flush_sources.has_key (account_id)) {
            uint source = queued_flush_sources[account_id]; queued_flush_sources.unset (account_id);
            if (source != 0) Source.remove (source);
        }
        if (flushing_accounts.contains (account_id)) {
            flush_again.add (account_id);
            ulong handler_id = 0;
            handler_id = pending_flush_finished.connect ((finished_account_id) => {
                if (finished_account_id != account_id) return;
                disconnect (handler_id);
                flush_pending.callback ();
            });
            yield;
            return;
        }
        flushing_accounts.add (account_id);
        bool succeeded = true;
        do {
            flush_again.remove (account_id);
            succeeded = true;
            try {
                foreach (var transfer in cache.list_pending_transfers (account_id)) {
                    // Apply the desired final flags to the source before moving.
                    // IMAP transfers preserve flags, and this also handles a
                    // flag/read change made after the optimistic local move.
                    foreach (var mutation in cache.list_pending_mutations (account_id)) {
                        if (mutation.message_id != transfer.message_id) continue;
                        yield engine.set_message_state (mutation.account_id, transfer.source_mailbox,
                            transfer.remote_uid, mutation.field, mutation.value, cancellable);
                        cache.complete_pending_mutation (mutation);
                    }
                    string? destination_uid = yield engine.transfer_message (transfer.account_id,
                        transfer.source_mailbox, transfer.remote_uid,
                        transfer.destination_mailbox, transfer.copy, cancellable);
                    cache.complete_pending_transfer (transfer, destination_uid);
                }
                foreach (var mutation in cache.list_pending_mutations (account_id)) {
                    yield engine.set_message_state (mutation.account_id, mutation.mailbox_name, mutation.remote_uid,
                        mutation.field, mutation.value, cancellable);
                    cache.complete_pending_mutation (mutation);
                }
                foreach (var deletion in cache.list_pending_deletions (account_id)) {
                    yield engine.permanently_delete_message (deletion.account_id, deletion.mailbox_name,
                        deletion.remote_uid, cancellable);
                    cache.complete_pending_deletion (deletion);
                }
                foreach (var purge in cache.list_pending_folder_purges (account_id)) {
                    yield engine.empty_folder (purge.account_id, purge.mailbox_name, cancellable);
                    cache.complete_pending_folder_purge (purge);
                }
            } catch (Error error) {
                succeeded = false;
                // The queue is intentionally retained. The next successful refresh retries it.
                debug ("Pending mail changes remain queued for retry: %s", error.message);
            }
        } while (succeeded && flush_again.contains (account_id));
        flush_again.remove (account_id);
        flushing_accounts.remove (account_id);
        pending_flush_finished (account_id);
    }
}
}
