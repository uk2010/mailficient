namespace Mailficient {
public class CachedMailRepository : Object, MailRepository {
    public const string LOCAL_DRAFTS_ID = "local-drafts";
    public const string DRAFT_PREFIX = "local-draft:";
    public const string LOCAL_OUTBOX_ID = "local-outbox";
    public const string OUTBOX_PREFIX = "local-outbox:";
    private CacheDatabase cache;
    private DemoMailRepository demo;
    private bool demo_mode;

    public CachedMailRepository (CacheDatabase cache, DemoMailRepository demo, bool demo_mode = false) {
        this.cache = cache;
        this.demo = demo;
        this.demo_mode = demo_mode;
        demo.changed.connect (() => {
            if (is_demo_mode ()) changed ();
        });
    }

    private bool is_demo_mode () {
        if (!demo_mode) return false;
        try { return cache.list_accounts ().size == 0; }
        catch (Error error) { warning ("Could not determine account mode: %s", error.message); return false; }
    }

    public Gee.List<Mailbox> list_mailboxes () {
        if (is_demo_mode ()) {
            var result = new Gee.ArrayList<Mailbox> (); result.add_all (demo.list_mailboxes ());
            try {
                foreach (var mailbox in result)
                    if (mailbox.role == MailboxRole.DRAFTS)
                        mailbox.unread_count = (uint) cache.saved_draft_count ();
                result.insert (4, new Mailbox (LOCAL_OUTBOX_ID, "Outbox", "mail-send-symbolic", MailboxRole.CUSTOM, (uint) cache.outbox_count ()));
            }
            catch (Error error) { warning ("Could not count queued messages: %s", error.message); }
            return result;
        }
        try {
            var result = new Gee.ArrayList<Mailbox> ();
            if (cache.list_accounts ().size == 0) return result;
            result.add (new Mailbox ("unified-inbox", "Inbox", "mail-inbox-symbolic", MailboxRole.INBOX, cache.unified_unread_count ()));
            result.add (new Mailbox ("unified-vip", "VIP", "starred-symbolic", MailboxRole.VIP, cache.smart_unread_count ("unified-vip")));
            result.add (new Mailbox ("unified-flagged", "Flagged", "flag-symbolic", MailboxRole.FLAGGED, cache.smart_unread_count ("unified-flagged")));
            result.add (new Mailbox (LOCAL_DRAFTS_ID, "Drafts", "document-edit-symbolic", MailboxRole.DRAFTS, (uint) cache.saved_draft_count ()));
            result.add (new Mailbox (LOCAL_OUTBOX_ID, "Outbox", "mail-send-symbolic", MailboxRole.CUSTOM, (uint) cache.outbox_count ()));
            result.add (new Mailbox ("unified-sent", "Sent", "mail-sent-symbolic", MailboxRole.SENT));
            result.add (new Mailbox ("unified-archive", "Archive", "package-x-generic-symbolic", MailboxRole.ARCHIVE));
            result.add (new Mailbox ("unified-junk", "Junk", "dialog-warning-symbolic", MailboxRole.JUNK));
            result.add (new Mailbox ("unified-trash", "Trash", "user-trash-symbolic", MailboxRole.TRASH));
            result.add (new Mailbox ("unified-snoozed", "Snoozed", "alarm-symbolic", MailboxRole.SNOOZED));
            result.add_all (cache.list_cached_mailboxes ());
            return result;
        } catch (Error error) {
            warning ("Could not load cached mailboxes: %s", error.message);
            return new Gee.ArrayList<Mailbox> ();
        }
    }

    public Gee.List<Message> list_messages (string mailbox_id, string query = "",
                                            int limit = 500, int offset = 0,
                                            bool unread_only = false,
                                            MessageSortMode sort_mode = MessageSortMode.NEWEST) {
        if (mailbox_id == LOCAL_DRAFTS_ID || (is_demo_mode () && mailbox_id == "drafts")) return draft_messages ();
        if (mailbox_id == LOCAL_OUTBOX_ID) return outbox_messages ();
        if (is_demo_mode ()) return demo.list_messages (mailbox_id, query, limit, offset,
            unread_only, sort_mode);
        try { return cache.list_cached_messages (mailbox_id, limit, offset, unread_only, sort_mode); }
        catch (Error error) { warning ("Could not load cached messages: %s", error.message); return new Gee.ArrayList<Message> (); }
    }

    public int message_count (string mailbox_id, string query = "", bool unread_only = false) {
        if (mailbox_id == LOCAL_DRAFTS_ID || (is_demo_mode () && mailbox_id == "drafts"))
            return draft_messages ().size;
        if (mailbox_id == LOCAL_OUTBOX_ID) return outbox_messages ().size;
        if (is_demo_mode ()) return demo.message_count (mailbox_id, query, unread_only);
        try { return cache.count_cached_messages (mailbox_id, unread_only); }
        catch (Error error) { warning ("Could not count cached messages: %s", error.message); return 0; }
    }

    public Message? find_message (string id) {
        if (id.has_prefix (DRAFT_PREFIX)) {
            try { var draft = cache.load_draft (id.substring (DRAFT_PREFIX.length)); return draft == null ? null : draft_message (draft); }
            catch (Error error) { warning ("Could not load local draft: %s", error.message); return null; }
        }
        if (id.has_prefix (OUTBOX_PREFIX)) {
            try { var draft = cache.load_draft (id.substring (OUTBOX_PREFIX.length)); return draft == null ? null : outbox_message (new OutboxItem (draft, 0, 0, "")); }
            catch (Error error) { warning ("Could not load queued message: %s", error.message); return null; }
        }
        if (is_demo_mode ()) return demo.find_message (id);
        try { return cache.find_cached_message (id); }
        catch (Error error) { warning ("Could not load cached message: %s", error.message); return null; }
    }

    public Gee.List<Message> conversation_for (Message message) {
        if (message.id.has_prefix (DRAFT_PREFIX) || message.id.has_prefix (OUTBOX_PREFIX)) { var draft_thread = new Gee.ArrayList<Message> (); draft_thread.add (message); return draft_thread; }
        if (is_demo_mode ()) return demo.conversation_for (message);
        try { return cache.conversation_for (message); }
        catch (Error error) {
            warning ("Could not reconstruct the conversation: %s", error.message);
            var fallback = new Gee.ArrayList<Message> (); fallback.add (message); return fallback;
        }
    }

    public void mark_read (string id, bool read) {
        if (id.has_prefix (DRAFT_PREFIX) || id.has_prefix (OUTBOX_PREFIX)) return;
        if (is_demo_mode ()) { demo.mark_read (id, read); return; }
        try {
            // Selecting a mailbox selects its first message.  Reloading the
            // sidebar then restores that mailbox selection, so emitting a
            // change for an already-read message creates a selection/reload
            // loop.  Treat an idempotent read request as the no-op it is.
            var message = cache.find_cached_message (id);
            if (message == null || message.unread == !read) return;
            cache.set_cached_read (id, read); changed ();
        }
        catch (Error error) { warning ("Could not update read state: %s", error.message); }
    }

    public void set_flagged (string id, bool flagged) {
        if (id.has_prefix (DRAFT_PREFIX) || id.has_prefix (OUTBOX_PREFIX)) return;
        if (is_demo_mode ()) { demo.set_flagged (id, flagged); return; }
        try { cache.set_cached_flagged (id, flagged); changed (); }
        catch (Error error) { warning ("Could not update flag state: %s", error.message); }
    }
    public bool sender_is_vip (Message message) {
        if (is_demo_mode ()) return demo.sender_is_vip (message);
        try { return cache.is_vip_sender (message.sender_address); }
        catch (Error error) { warning ("Could not inspect VIP sender: %s", error.message); return false; }
    }
    public void set_sender_vip (Message message, bool vip) throws MailError {
        if (is_demo_mode ()) demo.set_sender_vip (message, vip);
        else { cache.set_vip_sender (message.sender_address, vip); changed (); }
    }

    public void reload () { changed (); }
    public void move_to_role (string id, MailboxRole role) throws MailError {
        if (is_demo_mode ()) { demo.move_to_role (id, role); return; }
        cache.queue_message_transfer (id, role, false); changed ();
    }
    public void classify_junk (string id, bool junk) throws MailError {
        if (is_demo_mode ()) { demo.classify_junk (id, junk); return; }
        cache.queue_junk_classification (id, junk); changed ();
    }
    public void transfer_to_mailbox (string id, string mailbox_id, bool copy) throws MailError {
        if (is_demo_mode ()) { demo.transfer_to_mailbox (id, mailbox_id, copy); return; }
        cache.queue_message_transfer_to (id, mailbox_id, copy); changed ();
    }
    public void undo_transfer (string id, string original_mailbox_id) throws MailError {
        if (is_demo_mode ()) { demo.undo_transfer (id, original_mailbox_id); return; }
        cache.undo_queued_transfer (id, original_mailbox_id); changed ();
    }
    public void permanently_delete (string id) throws MailError {
        if (is_demo_mode ()) { demo.permanently_delete (id); return; }
        cache.queue_permanent_delete (id); changed ();
    }
    public void empty_role (MailboxRole role) throws MailError {
        if (is_demo_mode ()) { demo.empty_role (role); return; }
        cache.queue_role_purge (role); changed ();
    }
    public Gee.List<MailLabel> list_labels () throws MailError { return cache.list_mail_labels (); }
    public MailLabel create_label (string name, string color = "#3584e4") throws MailError {
        var label = cache.create_mail_label (name, color); changed (); return label;
    }
    public void delete_label (int64 id) throws MailError { cache.delete_mail_label (id); changed (); }
    public Gee.List<MailLabel> labels_for (string message_id) throws MailError {
        return cache.labels_for_message (message_id);
    }
    public void set_label (string message_id, int64 label_id, bool enabled) throws MailError {
        cache.set_message_label (message_id, label_id, enabled); changed ();
    }
    public void snooze (string message_id, int64 until_unix) throws MailError {
        cache.snooze_message (message_id, until_unix); changed ();
    }
    public void unsnooze (string message_id) throws MailError { cache.unsnooze_message (message_id); changed (); }
    public bool is_snoozed (string message_id) throws MailError { return cache.message_is_snoozed (message_id); }

    private Gee.ArrayList<Message> draft_messages () {
        var result = new Gee.ArrayList<Message> ();
        try { foreach (var draft in cache.list_saved_drafts ()) result.add (draft_message (draft)); }
        catch (Error error) { warning ("Could not load saved drafts: %s", error.message); }
        return result;
    }

    private static Message draft_message (Draft draft) {
        string preview = draft.body_text.replace ("\n", " ").strip ();
        string timestamp = "Draft";
        var date = new DateTime.from_unix_local (draft.modified_at);
        if (date != null) timestamp = date.format ("%b %e").strip ();
        return new Message (DRAFT_PREFIX + draft.id, LOCAL_DRAFTS_ID, "Draft", "", draft.to,
            draft.subject.strip () == "" ? "(No Subject)" : draft.subject, preview, draft.body_text, timestamp,
            false, false, draft.attachments.size > 0, 1, false, draft.account_id);
    }

    private Gee.ArrayList<Message> outbox_messages () {
        var result = new Gee.ArrayList<Message> ();
        try { foreach (var item in cache.list_outbox_items ()) result.add (outbox_message (item)); }
        catch (Error error) { warning ("Could not load Outbox: %s", error.message); }
        return result;
    }

    private static Message outbox_message (OutboxItem item) {
        var draft = item.draft;
        string preview;
        if (item.delivery_state == OutboxDeliveryState.SENDING)
            preview = "Delivery status uncertain — this message will not resend automatically";
        else if (item.delivery_state == OutboxDeliveryState.ACCEPTED)
            preview = "Sent — waiting for local Outbox cleanup";
        else if (item.delivery_state == OutboxDeliveryState.REJECTED)
            preview = "Rejected by the mail server — review and correct before trying again";
        else
            preview = item.attempts > 0 ? "Send failed — Mailficient will retry automatically" : "Waiting to send";
        return new Message (OUTBOX_PREFIX + draft.id, LOCAL_OUTBOX_ID, "Outbox", "", draft.to,
            draft.subject.strip () == "" ? "(No Subject)" : draft.subject, preview, draft.body_text, "Queued",
            false, false, draft.attachments.size > 0, 1, false, draft.account_id);
    }
}
}
