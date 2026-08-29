namespace Mailficient {
public class VacationResponderService : Object {
    private CacheDatabase cache; private OutboundService outbound;
    public VacationResponderService (CacheDatabase cache, OutboundService outbound) {
        this.cache = cache; this.outbound = outbound;
    }
    public async int respond (MailSyncResult snapshot, Cancellable? cancellable = null) throws Error {
        var settings = cache.vacation_settings (snapshot.account_id);
        int64 now = new DateTime.now_utc ().to_unix ();
        if (settings == null || !settings.active_at (now) || settings.body.strip () == "") return 0;
        var account = cache.find_account (snapshot.account_id); if (account == null) return 0;
        var inboxes = new Gee.HashSet<string> ();
        foreach (var mailbox in snapshot.mailboxes) if (mailbox.role == MailboxRole.INBOX) inboxes.add (mailbox.id);
        int sent = 0;
        foreach (var message in snapshot.messages) {
            string sender = message.sender_address.strip ().down ();
            if (!message.unread || !inboxes.contains (message.mailbox_id) || sender == account.email.down () ||
                sender.contains ("no-reply") || sender.contains ("noreply") || cache.vacation_replied_to (snapshot.account_id, sender)) continue;
            var draft = new Draft (snapshot.account_id); draft.to = sender;
            string configured_subject = settings.subject.strip ();
            if (configured_subject != "")
                draft.subject = settings.subject;
            else if (message.subject.has_prefix ("Re:"))
                draft.subject = message.subject;
            else
                draft.subject = "Re: " + message.subject;
            draft.body_text = settings.body;
            yield outbound.deliver (draft, cancellable);
            cache.record_vacation_reply (snapshot.account_id, sender); sent++;
        }
        return sent;
    }
}
}
