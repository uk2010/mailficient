namespace Mailficient {
public class JunkFilterService : Object {
    private CacheDatabase cache;

    public JunkFilterService (CacheDatabase cache) { this.cache = cache; }

    public int apply (MailSyncResult snapshot) throws MailError {
        var inbox_ids = new Gee.HashSet<string> ();
        foreach (var mailbox in snapshot.mailboxes)
            if (mailbox.role == MailboxRole.INBOX) inbox_ids.add (mailbox.id);
        if (inbox_ids.size == 0) return 0;
        var rules = cache.list_junk_rules ();
        if (rules.size == 0) return 0;
        int classified = 0;
        foreach (var message in snapshot.messages) {
            if (!inbox_ids.contains (message.mailbox_id)) continue;
            var current = cache.find_cached_message (message.id);
            if (current == null || !inbox_ids.contains (current.mailbox_id)) continue;
            foreach (var rule in rules) {
                if (!rule.matches (message.sender_address)) continue;
                cache.queue_junk_classification (message.id, true, false);
                classified++; break;
            }
        }
        return classified;
    }
}
}
