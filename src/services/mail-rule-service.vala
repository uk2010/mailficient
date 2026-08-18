namespace Mailficient {
public class MailRuleService : Object {
    private CacheDatabase cache;
    public MailRuleService (CacheDatabase cache) { this.cache = cache; }

    public int apply (MailSyncResult snapshot) throws MailError {
        var rules = cache.list_mail_rules (); if (rules.size == 0) return 0; int applied = 0;
        foreach (var incoming in snapshot.messages) {
            var current = cache.find_cached_message (incoming.id); if (current == null) continue;
            foreach (var rule in rules) {
                if (!rule.matches (incoming)) continue;
                switch (rule.action) {
                case MailRuleAction.MARK_READ: cache.set_cached_read (incoming.id, true); break;
                case MailRuleAction.MARK_UNREAD: cache.set_cached_read (incoming.id, false); break;
                case MailRuleAction.FLAG: cache.set_cached_flagged (incoming.id, true); break;
                case MailRuleAction.UNFLAG: cache.set_cached_flagged (incoming.id, false); break;
                case MailRuleAction.ARCHIVE: cache.queue_message_transfer (incoming.id, MailboxRole.ARCHIVE, false); break;
                case MailRuleAction.TRASH: cache.queue_message_transfer (incoming.id, MailboxRole.TRASH, false); break;
                case MailRuleAction.MOVE:
                    if (rule.value.strip () != "") cache.queue_message_transfer_to (incoming.id, rule.value.strip (), false);
                    break;
                case MailRuleAction.LABEL:
                    var label = cache.create_mail_label (rule.value);
                    cache.set_message_label (incoming.id, label.id, true); break;
                }
                applied++;
            }
        }
        return applied;
    }
}
}
