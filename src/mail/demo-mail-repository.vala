namespace Mailficient {
public class DemoMailRepository : Object, MailRepository {
    public const string ACCOUNT_ID = "demo-account";
    private Gee.ArrayList<Mailbox> mailboxes = new Gee.ArrayList<Mailbox> ();
    private Gee.ArrayList<Message> messages = new Gee.ArrayList<Message> ();
    private Gee.HashSet<string> vip_senders = new Gee.HashSet<string> ();
    private Gee.ArrayList<MailLabel> mail_labels = new Gee.ArrayList<MailLabel> ();
    private Gee.HashMap<string, Gee.HashSet<int64?>> message_label_ids = new Gee.HashMap<string, Gee.HashSet<int64?>> ();
    private Gee.HashMap<string, int64?> snoozed = new Gee.HashMap<string, int64?> ();

    public DemoMailRepository () {
        vip_senders.add ("maya@example.net");
        mailboxes.add (new Mailbox ("inbox", "Inbox", "mail-inbox-symbolic", MailboxRole.INBOX, 0, ACCOUNT_ID, "INBOX"));
        mailboxes.add (new Mailbox ("vip", "VIP", "starred-symbolic", MailboxRole.VIP, 0, ACCOUNT_ID, "VIP"));
        mailboxes.add (new Mailbox ("flagged", "Flagged", "mailficient-flag-symbolic", MailboxRole.FLAGGED, 0, ACCOUNT_ID, "Flagged"));
        mailboxes.add (new Mailbox ("drafts", "Drafts", "document-edit-symbolic", MailboxRole.DRAFTS, 0, ACCOUNT_ID, "Drafts"));
        mailboxes.add (new Mailbox ("sent", "Sent", "mail-sent-symbolic", MailboxRole.SENT, 0, ACCOUNT_ID, "Sent"));
        mailboxes.add (new Mailbox ("archive", "Archive", "package-x-generic-symbolic", MailboxRole.ARCHIVE, 0, ACCOUNT_ID, "Archive"));
        mailboxes.add (new Mailbox ("junk", "Junk", "dialog-warning-symbolic", MailboxRole.JUNK, 0, ACCOUNT_ID, "Junk"));
        mailboxes.add (new Mailbox ("trash", "Trash", "user-trash-symbolic", MailboxRole.TRASH, 0, ACCOUNT_ID, "Trash"));
        mailboxes.add (new Mailbox ("snoozed", "Snoozed", "alarm-symbolic", MailboxRole.SNOOZED, 0, ACCOUNT_ID, "Snoozed"));

        messages.add (new Message ("design-history-1", "conversation-history", "Alex Morgan", "alex@example.com", "Maya Chen <maya@example.net>",
            "Design review — final details", "Initial review notes", "Hi Maya,\n\nHere are the first review notes. The overall direction is strong.\n\nAlex", "Friday", false, false, false, 1, false,
            ACCOUNT_ID, "history-1", "<design-1@example.net>"));
        messages.add (new Message ("design-history-2", "conversation-history", "Maya Chen", "maya@example.net", "Alex Morgan <alex@example.com>",
            "Re: Design review — final details", "I’ll incorporate these", "Thanks Alex,\n\nI’ll incorporate these and send a final pass.\n\nMaya", "Friday", false, false, false, 1, false,
            ACCOUNT_ID, "history-2", "<design-2@example.net>", "<design-1@example.net>", "<design-1@example.net>"));
        var design_review = new Message ("1", "inbox", "Maya Chen", "maya@example.net", "Alex Morgan <alex@example.com>",
            "Design review — final details", "I’ve incorporated the notes from Friday. The spacing now feels much calmer…",
            "Hi Alex,\n\nI’ve incorporated the notes from Friday. The spacing now feels much calmer, and the narrow layout is ready for another look.\n\nI attached the review notes. Let me know what you think.\n\nBest,\nMaya", "10:42 AM", true, true, true, 3, false,
            ACCOUNT_ID, "1", "<design-3@example.net>", "<design-2@example.net>", "<design-1@example.net> <design-2@example.net>");
        design_review.add_attachment (new Attachment ("demo-design-review",
            "resource:///com/local/Mailficient/sample-data/design-review-notes.txt",
            "design-review-notes.txt", 177, "text/plain"));
        design_review.add_attachment (new Attachment ("demo-design-preview",
            "resource:///com/local/Mailficient/sample-data/mailficient-preview.png",
            "mailficient-preview.png", 60594, "image/png"));
        messages.add (design_review);
        messages.add (new Message ("2", "inbox", "Noah Williams", "noah@example.org", "Alex Morgan <alex@example.com>",
            "Dinner next week?", "How does Thursday sound? There’s a quiet place near the park…",
            "Hey Alex,\n\nHow does Thursday sound? There’s a quiet place near the park I think you’d like. Seven-ish?\n\nNoah", "9:18 AM", true,
            false, false, 1, false, ACCOUNT_ID, "2"));
        var digest = new Message ("3", "inbox", "Lina from Northstar", "lina@northstar.test", "Alex Morgan <alex@example.com>",
            "Your July project digest", "A concise summary of milestones, decisions, and what comes next.",
            "Hello Alex,\n\nHere is your July project digest. Three milestones shipped, two decisions remain open, and the team is on schedule.\n\nView the full report when you’re ready.", "Yesterday", false, false, true, 1, true,
            ACCOUNT_ID, "3");
        digest.body_html = "<main><p>Hello Alex,</p><p>Here is your <strong>July project digest</strong>.</p><ul><li>Three milestones shipped</li><li>Two decisions remain open</li><li>The team is on schedule</li></ul><img alt='Mailficient layout preview' width='640' src='cid:mailficient-preview@example.net'><img alt='Northstar report' src='https://northstar.test/report.png'><p>View the full report when you’re ready.</p></main>";
        digest.add_attachment (new Attachment ("demo-inline-preview",
            "resource:///com/local/Mailficient/sample-data/mailficient-preview.png",
            "mailficient-preview.png", 60594, "image/png", "<mailficient-preview@example.net>"));
        messages.add (digest);
        messages.add (new Message ("4", "inbox", "Fedora Community", "updates@fedoraproject.org", "Alex Morgan <alex@example.com>",
            "This week in Fedora Workstation", "Desktop updates, community news, and upcoming test days…",
            "This week: a smoother desktop, accessibility improvements, and upcoming community test days. Thanks for being part of Fedora.", "Saturday", false,
            false, false, 1, false, ACCOUNT_ID, "4"));
        var photographs = new Message ("5", "inbox", "Priya Raman", "priya@example.com", "Alex Morgan <alex@example.com>",
            "Re: Weekend photographs", "These are wonderful — especially the one by the lake.",
            "These are wonderful — especially the one by the lake. I’ve saved a few favorites.\n\nOn Sunday, Alex wrote:\n> Here are the photographs I promised.", "Friday", true, false, true, 5, false,
            ACCOUNT_ID, "5");
        photographs.add_attachment (new Attachment ("demo-large-photo", "", "lake-original.tiff",
            78 * 1024 * 1024, "image/tiff", "", 1));
        messages.add (photographs);
    }

    public Gee.List<Mailbox> list_mailboxes () {
        foreach (var mailbox in mailboxes) {
            uint count = 0;
            foreach (var message in messages) {
                if (!message.unread) continue;
                bool belongs = mailbox.role == MailboxRole.VIP ?
                    vip_senders.contains (message.sender_address.down ()) :
                    mailbox.role == MailboxRole.FLAGGED ? message.flagged :
                    message.mailbox_id == mailbox.id;
                if (belongs) count++;
            }
            mailbox.unread_count = count;
        }
        return mailboxes;
    }

    public Gee.List<Message> list_messages (string mailbox_id, string query = "",
                                            int limit = 500, int offset = 0,
                                            bool unread_only = false,
                                            MessageSortMode sort_mode = MessageSortMode.NEWEST) {
        var matches = new Gee.ArrayList<Message> ();
        string needle = query.down ();
        foreach (var message in messages) {
            bool active_snooze = is_snoozed_local (message.id);
            bool folder_match = mailbox_id == "inbox" ? message.mailbox_id == "inbox" :
                (mailbox_id == "flagged" ? message.flagged :
                (mailbox_id == "vip" ? vip_senders.contains (message.sender_address.down ()) :
                (mailbox_id == "snoozed" ? active_snooze : message.mailbox_id == mailbox_id)));
            if (mailbox_id != "snoozed" && active_snooze) folder_match = false;
            bool search_match = needle == "" || message.sender_name.down ().contains (needle) ||
                message.subject.down ().contains (needle) || message.body.down ().contains (needle);
            if (folder_match && search_match && (!unread_only || message.unread)) matches.add (message);
        }
        matches = new MessageSorter ().sort (matches, sort_mode);
        var result = new Gee.ArrayList<Message> ();
        int start = int.max (0, offset);
        int end = int.min (matches.size, start + int.max (0, limit));
        for (int index = start; index < end; index++) result.add (matches[index]);
        return result;
    }

    public int message_count (string mailbox_id, string query = "", bool unread_only = false) {
        return list_messages (mailbox_id, query, int.MAX, 0, unread_only).size;
    }

    public Message? find_message (string id) {
        foreach (var message in messages) if (message.id == id) return message;
        return null;
    }
    public Gee.List<Message> conversation_for (Message message) {
        return new ConversationBuilder ().build (messages, message);
    }
    public void mark_read (string id, bool read) {
        var message = find_message (id);
        if (message != null && message.unread == read) {
            message.unread = !read; changed ();
        }
    }
    public void set_flagged (string id, bool flagged) {
        var message = find_message (id);
        if (message != null && message.flagged != flagged) {
            message.flagged = flagged; changed ();
        }
    }
    public bool sender_is_vip (Message message) { return vip_senders.contains (message.sender_address.down ()); }
    public void set_sender_vip (Message message, bool vip) throws MailError {
        if (vip) vip_senders.add (message.sender_address.down ()); else vip_senders.remove (message.sender_address.down ());
        changed ();
    }
    public void reload () { changed (); }
    public void move_to_role (string id, MailboxRole role) throws MailError {
        foreach (var mailbox in mailboxes)
            if (mailbox.role == role) { transfer_to_mailbox (id, mailbox.id, false); return; }
        throw new MailError.STORAGE ("That demo mailbox is unavailable");
    }
    public void classify_junk (string id, bool junk) throws MailError {
        move_to_role (id, junk ? MailboxRole.JUNK : MailboxRole.INBOX);
    }
    public void transfer_to_mailbox (string id, string mailbox_id, bool copy) throws MailError {
        var source = find_message (id);
        if (source == null) throw new MailError.STORAGE ("The demo message is no longer available");
        if (copy) messages.add (copy_message (source, mailbox_id));
        else source.mailbox_id = mailbox_id;
        changed ();
    }
    public void undo_transfer (string id, string original_mailbox_id) throws MailError {
        var message = find_message (id);
        if (message == null) throw new MailError.STORAGE ("The demo message is no longer available");
        message.mailbox_id = original_mailbox_id; changed ();
    }
    public void permanently_delete (string id) throws MailError {
        var message = find_message (id);
        if (message == null || !messages.remove (message))
            throw new MailError.STORAGE ("The demo message is no longer available");
        changed ();
    }
    public void empty_role (MailboxRole role) throws MailError {
        string mailbox_id = "";
        foreach (var mailbox in mailboxes) if (mailbox.role == role) mailbox_id = mailbox.id;
        if (mailbox_id == "") throw new MailError.STORAGE ("That demo mailbox is unavailable");
        for (int index = messages.size - 1; index >= 0; index--)
            if (messages[index].mailbox_id == mailbox_id) messages.remove_at (index);
        changed ();
    }
    public Gee.List<MailLabel> list_labels () throws MailError { return mail_labels; }
    public MailLabel create_label (string name, string color = "#3584e4") throws MailError {
        var label = new MailLabel (mail_labels.size + 1, name.strip (), color); mail_labels.add (label); changed (); return label;
    }
    public void delete_label (int64 id) throws MailError {
        for (int index = mail_labels.size - 1; index >= 0; index--)
            if (mail_labels[index].id == id) mail_labels.remove_at (index);
        foreach (var ids in message_label_ids.values) ids.remove (id); changed ();
    }
    public Gee.List<MailLabel> labels_for (string message_id) throws MailError {
        var result = new Gee.ArrayList<MailLabel> (); var ids = message_label_ids[message_id];
        if (ids != null) foreach (var label in mail_labels) if (ids.contains (label.id)) result.add (label);
        return result;
    }
    public void set_label (string message_id, int64 label_id, bool enabled) throws MailError {
        if (!message_label_ids.has_key (message_id)) message_label_ids[message_id] = new Gee.HashSet<int64?> ();
        if (enabled) message_label_ids[message_id].add (label_id); else message_label_ids[message_id].remove (label_id);
        changed ();
    }
    public void snooze (string message_id, int64 until_unix) throws MailError { snoozed[message_id] = until_unix; changed (); }
    public void unsnooze (string message_id) throws MailError { snoozed.unset (message_id); changed (); }
    public bool is_snoozed (string message_id) throws MailError { return is_snoozed_local (message_id); }
    private bool is_snoozed_local (string message_id) {
        return snoozed.has_key (message_id) && snoozed[message_id] > new DateTime.now_utc ().to_unix ();
    }

    private static Message copy_message (Message source, string mailbox_id) {
        var result = new Message ("demo-copy-" + Uuid.string_random (), mailbox_id,
            source.sender_name, source.sender_address, source.recipients, source.subject,
            source.preview, source.body, source.timestamp, source.unread, source.flagged,
            source.has_attachment, source.conversation_count, source.has_remote_content,
            source.account_id, source.remote_uid, source.internet_message_id,
            source.in_reply_to, source.references, source.date_unix);
        result.body_html = source.body_html;
        foreach (var attachment in source.attachments) result.add_attachment (attachment);
        return result;
    }
}
}
