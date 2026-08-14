namespace Mailficient {
internal class SyncPassOutcome : Object {
    public bool completed { get; set; default = false; }
    public bool cancelled { get; set; default = false; }
    public bool more_messages_available { get; set; default = false; }
    public int messages_downloaded { get; set; default = 0; }
    public UserFacingError? warning { get; set; }
}

internal class SyncProgressContext : Object {
    public int messages_total { get; set; default = 0; }
    public int messages_completed { get; set; default = 0; }
}

public class AccountSyncService : Object {
    public signal void synchronized (string account_id);
    public signal void failed (string account_id, UserFacingError error);
    public signal void cancelled (string account_id);
    public signal void new_message (Message message);
    public signal void mail_available (string account_id);
    public signal void pass_completed (string account_id);
    public signal void progress_changed (string account_id, double fraction, string detail);
    private signal void pending_flush_finished (string account_id);
    private signal void account_sync_finished (string account_id);

    private CacheDatabase cache;
    private MailEngine engine;
    private OutboundService outbound;
    private JunkFilterService junk_filter;
    private MailRuleService mail_rules;
    private VacationResponderService vacation_responder;
    private Cancellable? active;
    private Gee.HashSet<string> suppressed_accounts = new Gee.HashSet<string> ();
    private Gee.HashSet<string> flushing_accounts = new Gee.HashSet<string> ();
    private Gee.HashSet<string> flush_again = new Gee.HashSet<string> ();
    private Gee.HashSet<string> syncing_accounts = new Gee.HashSet<string> ();
    private Gee.HashMap<string, Cancellable> sync_cancellables = new Gee.HashMap<string, Cancellable> ();
    private Gee.HashSet<string> sync_again = new Gee.HashSet<string> ();
    private Gee.HashMap<string, uint> queued_flush_sources = new Gee.HashMap<string, uint> ();

    public AccountSyncService (CacheDatabase cache, MailEngine engine, OutboundService outbound,
                               JunkFilterService junk_filter) {
        this.cache = cache;
        this.engine = engine;
        this.outbound = outbound;
        this.junk_filter = junk_filter;
        this.mail_rules = new MailRuleService (cache);
        this.vacation_responder = new VacationResponderService (cache, outbound);
        cache.mutation_queued.connect (schedule_pending_flush);
    }

    private void schedule_pending_flush (string account_id) {
        uint existing = queued_flush_sources.has_key (account_id) ? queued_flush_sources[account_id] : 0;
        if (existing != 0) Source.remove (existing);
        queued_flush_sources[account_id] = Timeout.add_seconds (5, () => {
            queued_flush_sources.unset (account_id);
            flush_pending.begin (account_id);
            return Source.REMOVE;
        });
    }

    public async void sync_account (AccountSettings account, Cancellable? cancellable = null) {
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
        var effective_cancellable = cancellable ?? new Cancellable ();
        sync_cancellables[account.id] = effective_cancellable;
        SyncPassOutcome? last_outcome = null;
        var progress_context = new SyncProgressContext ();
        bool allow_notifications = true;
        do {
            sync_again.remove (account.id);
            last_outcome = new SyncPassOutcome ();
            yield perform_sync (account, effective_cancellable, allow_notifications,
                progress_context, last_outcome);
            progress_context.messages_completed += last_outcome.messages_downloaded;
            if (last_outcome.more_messages_available) {
                // A bounded pass keeps Get Mail responsive. Older history is
                // picked up by a later scheduled or manual check instead of
                // chaining dozens of MIME-download passes into one operation.
                pass_completed (account.id);
                double fraction = progress_context.messages_total > 0 ?
                    progress_context.messages_completed / (double) progress_context.messages_total : 0;
                progress_changed (account.id, fraction,
                    "Downloaded %d of %d messages — older history will continue later".printf (
                        progress_context.messages_completed, progress_context.messages_total));
            }
        } while (!suppressed_accounts.contains (account.id) && sync_again.contains (account.id));
        if (!suppressed_accounts.contains (account.id) && last_outcome != null && last_outcome.completed) {
            synchronized (account.id);
            if (last_outcome.warning != null) failed (account.id, last_outcome.warning);
        } else if (!suppressed_accounts.contains (account.id) && last_outcome != null &&
                   last_outcome.cancelled) {
            cancelled (account.id);
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
        int announced = 0;
        var announced_ids = new Gee.HashSet<string> ();
        ulong batch_handler = engine.sync_batch_ready.connect ((batch) => {
            if (batch.account_id != account.id || suppressed_accounts.contains (account.id) || batch_error != null)
                return;
            try {
                cache.store_sync_result (batch);
                junk_filter.apply (batch);
                mail_rules.apply (batch);
                mail_available (account.id);
                if (allow_notifications && established_cache && known_ids != null && announced < 5) {
                    var inbox_ids = new Gee.HashSet<string> ();
                    foreach (var mailbox in batch.mailboxes)
                        if (mailbox.role == MailboxRole.INBOX) inbox_ids.add (mailbox.id);
                    foreach (var message in batch.messages) {
                        if (announced >= 5) break;
                        if (message.unread && inbox_ids.contains (message.mailbox_id) &&
                            !known_ids.contains (message.id)) {
                            new_message (message); announced++;
                            announced_ids.add (message.id);
                        }
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
            if (progress_state.messages_to_download > 0) {
                int candidate_total = progress_context.messages_completed +
                    progress_state.messages_to_download;
                progress_context.messages_total = int.max (
                    progress_context.messages_total, candidate_total);
                int completed = progress_context.messages_completed +
                    progress_state.messages_downloaded;
                double fraction = completed / (double) progress_context.messages_total;
                progress_changed (account.id, fraction,
                    "Downloaded %d of %d messages".printf (
                        completed, progress_context.messages_total));
            } else if (progress_context.messages_total > 0) {
                double fraction = progress_context.messages_completed /
                    (double) progress_context.messages_total;
                progress_changed (account.id, fraction,
                    "Downloaded %d of %d messages — checking messages…".printf (
                        progress_context.messages_completed, progress_context.messages_total));
            } else {
                progress_changed (account.id, progress_state.progress, progress_state.detail);
            }
        });
        progress_changed (account.id, progress_state.progress, progress_state.detail);
        try {
            // Confirmed SMTP deliveries only need local cleanup and must not
            // wait for a network connection to return.
            outbound.finalize_confirmed (account.id, cancellable);
            // Mail checks only need the incoming IMAP service. SMTP is opened
            // lazily by outbound delivery instead of delaying every refresh.
            yield engine.connect_incoming_account (account, cancellable);
            yield outbound.retry_pending (account.id, true, cancellable);
            yield flush_pending (account.id, cancellable);
            int cached_before = cache.cached_message_count (account.id);
            established_cache = cached_before > 0;
            known_ids = established_cache ? cache.cached_message_ids (account.id) : new Gee.HashSet<string> ();
            var extracted_ids = established_cache ?
                cache.cached_extracted_message_ids (account.id) : new Gee.HashSet<string> ();
            var snapshot = yield engine.synchronize (account.id, extracted_ids, cancellable);
            if (suppressed_accounts.contains (account.id)) return;
            if (batch_error != null) throw batch_error;
            cache.store_sync_result (snapshot);
            junk_filter.apply (snapshot);
            mail_rules.apply (snapshot);
            yield vacation_responder.respond (snapshot, cancellable);
            yield flush_pending (account.id, cancellable);
            int cached_after = cache.cached_message_count (account.id);
            outcome.messages_downloaded = int.max (
                int.max (0, cached_after - cached_before), progress_state.messages_downloaded);
            if (allow_notifications && established_cache && known_ids != null && announced < 5) {
                var inbox_ids = new Gee.HashSet<string> ();
                foreach (var mailbox in snapshot.mailboxes)
                    if (mailbox.role == MailboxRole.INBOX) inbox_ids.add (mailbox.id);
                foreach (var message in snapshot.messages) {
                    if (announced >= 5) break;
                    if (message.unread && inbox_ids.contains (message.mailbox_id) &&
                        !known_ids.contains (message.id) && !announced_ids.contains (message.id)) {
                        new_message (message); announced++;
                        announced_ids.add (message.id);
                    }
                }
            }
            outcome.completed = true;
            if (snapshot.more_messages_available && snapshot.issues.size == 0 &&
                snapshot.terminal_error == null) {
                if (outcome.messages_downloaded > 0) outcome.more_messages_available = true;
                else outcome.warning = UserFacingError.from_error (new MailError.PARTIAL_SYNC (
                    "The server reported more mail, but this pass could not save another message. Automatic backfill stopped to avoid an endless retry."));
            }
            if (snapshot.issues.size > 0) {
                Error issue_error;
                if (snapshot.terminal_error != null) issue_error = snapshot.terminal_error;
                else issue_error = new MailError.PARTIAL_SYNC (snapshot.issue_summary ());
                outcome.warning = UserFacingError.from_error (issue_error);
            }
        } catch (Error error) {
            if (error is IOError.CANCELLED) outcome.cancelled = true;
            else failed (account.id, UserFacingError.from_error (error));
        } finally {
            engine.disconnect (batch_handler);
            progress_state.disconnect (progress_handler);
        }
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
    }

    public void suppress_account (string account_id) {
        suppressed_accounts.add (account_id);
        var cancellable = sync_cancellables[account_id];
        if (cancellable != null) cancellable.cancel ();
    }

    public void resume_account (string account_id) {
        suppressed_accounts.remove (account_id);
    }

    private async void flush_pending (string account_id, Cancellable? cancellable = null) {
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
