namespace Mailficient {
public class MailRuleRunResult : Object {
    public int inspected { get; construct; }
    public int matched { get; construct; }
    public bool truncated { get; construct; }

    public MailRuleRunResult (int inspected, int matched, bool truncated) {
        Object (inspected: inspected, matched: matched, truncated: truncated);
    }
}

public class MailRuleService : Object {
    public signal void run_progress (int inspected, int matched);

    private CacheDatabase cache;
    public MailRuleService (CacheDatabase cache) { this.cache = cache; }

    public int apply (MailSyncResult snapshot) throws MailError {
        var rules = cache.list_mail_rules (); if (rules.size == 0) return 0;
        int applied = 0;
        foreach (var incoming in snapshot.messages) {
            var current = cache.find_cached_message (incoming.id); if (current == null) continue;
            foreach (var rule in rules) {
                if (!rule.matches (current)) continue;
                if (!destinations_available (cache, current, rule.operations)) {
                    debug ("Skipped rule “%s”: its destination folder is no longer available for this account",
                        rule.name);
                    continue;
                }
                apply_operations (cache, current, rule.operations); applied++;
                if (rule.stop_processing) break;
            }
        }
        return applied;
    }

    public int run_now (MailRule rule, int maximum_messages = 10000) throws MailError {
        if (maximum_messages <= 0) return 0;
        int applied = 0; int offset = 0;
        var query = new SearchQuery (); query.account = rule.account_id == "" ? null : rule.account_id;
        // Collect a stable candidate set before applying anything. Move,
        // Archive, Trash, and Junk can remove a message from the query while
        // it is running; mutating an offset-paged result would otherwise skip
        // the page that shifted into the just-processed offset.
        var candidates = new Gee.ArrayList<Message> ();
        while (candidates.size < maximum_messages) {
            int batch_size = int.min (CacheDatabase.DEFAULT_MESSAGE_PAGE_SIZE,
                maximum_messages - candidates.size);
            var summaries = cache.search_messages (query, batch_size, offset);
            if (summaries.size == 0) break;
            candidates.add_all (summaries);
            if (summaries.size < batch_size) break;
            offset += summaries.size;
        }
        foreach (var summary in candidates) {
            var message = cache.find_cached_message (summary.id) ?? summary;
            if (rule.matches (message, true)) {
                apply_operations (cache, message, rule.operations); applied++;
            }
        }
        return applied;
    }

    // Preview and explicit runs use the same ordered, bounded traversal. The
    // preview never invokes an operation, so the Rules window can show the
    // exact local scope before a user authorizes any mailbox changes.
    public async MailRuleRunResult preview_run (MailRule rule, int maximum_messages = 10000,
                                                 Cancellable? cancellable = null,
                                                 string mailbox_id = "") throws Error {
        return yield process_explicit_run (
            rule, false, maximum_messages, cancellable, mailbox_id);
    }

    public async MailRuleRunResult run_now_async (MailRule rule, int maximum_messages = 10000,
                                                   Cancellable? cancellable = null,
                                                   string mailbox_id = "") throws Error {
        return yield process_explicit_run (
            rule, true, maximum_messages, cancellable, mailbox_id);
    }

    private async MailRuleRunResult process_explicit_run (
        MailRule rule, bool apply_operations_to_matches, int maximum_messages,
        Cancellable? cancellable, string mailbox_id) throws Error {
        int limit = int.max (1, maximum_messages);
        int inspected = 0;
        int matched = 0;
        int offset = 0;
        bool reached_end = false;
        var candidates = new Gee.ArrayList<Message> ();
        var query = new SearchQuery ();
        query.account = rule.account_id == "" ? null : rule.account_id;
        query.mailbox = mailbox_id == "" ? null : mailbox_id;

        // Snapshot the bounded local scope before applying any operations.
        // This keeps offset paging correct when a rule moves matching mail out
        // of the selected mailbox while Run Now is still in progress.
        while (candidates.size < limit) {
            if (cancellable != null) cancellable.set_error_if_cancelled ();
            int batch_size = int.min (CacheDatabase.DEFAULT_MESSAGE_PAGE_SIZE,
                limit - candidates.size);
            var summaries = cache.search_messages (query, batch_size, offset);
            if (summaries.size == 0) {
                reached_end = true;
                break;
            }
            candidates.add_all (summaries);
            offset += summaries.size;
            if (summaries.size < batch_size) {
                reached_end = true;
                break;
            }
            // Searching and applying rules is local SQLite work. Yield between
            // pages so the progress dialog can repaint and its Cancel button
            // remains responsive even for a large cache.
            Idle.add (() => {
                process_explicit_run.callback ();
                return Source.REMOVE;
            });
            yield;
        }

        bool truncated = !reached_end && candidates.size >= limit;
        if (truncated) {
            if (cancellable != null) cancellable.set_error_if_cancelled ();
            truncated = cache.search_messages (query, 1, offset).size > 0;
        }

        foreach (var summary in candidates) {
            if (cancellable != null) cancellable.set_error_if_cancelled ();
            var message = cache.find_cached_message (summary.id) ?? summary;
            inspected++;
            if (rule.matches (message, true)) {
                matched++;
                if (apply_operations_to_matches)
                    apply_operations (cache, message, rule.operations);
            }
            if (inspected % CacheDatabase.DEFAULT_MESSAGE_PAGE_SIZE == 0 &&
                inspected < candidates.size) {
                run_progress (inspected, matched);
                Idle.add (() => {
                    process_explicit_run.callback ();
                    return Source.REMOVE;
                });
                yield;
            }
        }
        run_progress (inspected, matched);
        return new MailRuleRunResult (inspected, matched, truncated);
    }

    public int apply_to_messages (Gee.Iterable<Message> messages) throws MailError {
        var rules = cache.list_mail_rules (); if (rules.size == 0) return 0;
        int applied = 0;
        foreach (var summary in messages) {
            var message = cache.find_cached_message (summary.id) ?? summary;
            foreach (var rule in rules) {
                if (!rule.matches (message)) continue;
                apply_operations (cache, message, rule.operations); applied++;
                if (rule.stop_processing) break;
            }
        }
        return applied;
    }

    public static void apply_operations (CacheDatabase cache, Message message,
                                         Gee.List<MailRuleOperation> operations) throws MailError {
        foreach (var operation in operations) {
            switch (operation.action) {
            case MailRuleAction.MARK_READ: cache.set_cached_read (message.id, true); message.unread = false; break;
            case MailRuleAction.MARK_UNREAD: cache.set_cached_read (message.id, false); message.unread = true; break;
            case MailRuleAction.FLAG: cache.set_cached_flagged (message.id, true); message.flagged = true; break;
            case MailRuleAction.UNFLAG: cache.set_cached_flagged (message.id, false); message.flagged = false; break;
            case MailRuleAction.ARCHIVE: cache.queue_message_transfer (message.id, MailboxRole.ARCHIVE, false); break;
            case MailRuleAction.TRASH: cache.queue_message_transfer (message.id, MailboxRole.TRASH, false); break;
            case MailRuleAction.MOVE:
                if (operation.value != "") cache.queue_message_transfer_to (message.id, operation.value, false);
                break;
            case MailRuleAction.COPY:
                if (operation.value != "") cache.queue_message_transfer_to (message.id, operation.value, true);
                break;
            case MailRuleAction.LABEL:
                if (operation.value != "") {
                    var label = cache.create_mail_label (operation.value);
                    cache.set_message_label (message.id, label.id, true);
                }
                break;
            case MailRuleAction.REMOVE_LABEL:
                if (operation.value != "") {
                    foreach (var label in cache.list_mail_labels ()) {
                        if (label.name.down () != operation.value.down ()) continue;
                        cache.set_message_label (message.id, label.id, false);
                        break;
                    }
                }
                break;
            case MailRuleAction.SET_FLAG_COLOR:
                if (operation.value != "") {
                    cache.set_cached_flag_color (message.id, operation.value);
                    message.flagged = true; message.flag_color = operation.value;
                }
                break;
            case MailRuleAction.MARK_JUNK:
                cache.queue_junk_classification (message.id, true, false);
                break;
            case MailRuleAction.MARK_NOT_JUNK:
                cache.queue_junk_classification (message.id, false, false);
                break;
            }
        }
    }

    private static bool destinations_available (
        CacheDatabase cache, Message message,
        Gee.List<MailRuleOperation> operations) throws MailError {
        foreach (var operation in operations) {
            if (operation.action != MailRuleAction.MOVE &&
                operation.action != MailRuleAction.COPY) continue;
            if (!cache.cached_folder_available (operation.value, message.account_id))
                return false;
        }
        return true;
    }
}
}
