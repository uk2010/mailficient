namespace Mailficient {
public class MailRuleService : Object {
    private CacheDatabase cache;
    public MailRuleService (CacheDatabase cache) { this.cache = cache; }

    public int apply (MailSyncResult snapshot) throws MailError {
        var rules = cache.list_mail_rules (); if (rules.size == 0) return 0;
        int applied = 0;
        foreach (var incoming in snapshot.messages) {
            var current = cache.find_cached_message (incoming.id); if (current == null) continue;
            foreach (var rule in rules) {
                if (!rule.matches (current)) continue;
                apply_operations (cache, current, rule.operations); applied++;
                if (rule.stop_processing) break;
            }
        }
        return applied;
    }

    public int run_now (MailRule rule, int maximum_messages = 10000) throws MailError {
        int inspected = 0; int applied = 0; int offset = 0;
        var query = new SearchQuery (); query.account = rule.account_id == "" ? null : rule.account_id;
        while (inspected < maximum_messages) {
            int batch_size = int.min (CacheDatabase.MESSAGE_LIST_LIMIT, maximum_messages - inspected);
            var summaries = cache.search_messages (query, batch_size, offset);
            if (summaries.size == 0) break;
            foreach (var summary in summaries) {
                var message = cache.find_cached_message (summary.id) ?? summary;
                inspected++;
                if (rule.matches (message)) { apply_operations (cache, message, rule.operations); applied++; }
            }
            if (summaries.size < batch_size) break;
            offset += summaries.size;
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
            }
        }
    }
}
}
