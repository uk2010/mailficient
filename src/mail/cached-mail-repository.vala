namespace Mailficient {
public class CachedMailRepository : Object, MailRepository {
    public const string LOCAL_DRAFTS_ID = "local-drafts";
    public const string DRAFT_PREFIX = "local-draft:";
    public const string LOCAL_OUTBOX_ID = "local-outbox";
    public const string OUTBOX_PREFIX = "local-outbox:";
    public const string SMART_MAILBOX_PREFIX = "smart:";
    // Calendar is provided by GNOME Calendar.  Keep the synthetic mailbox
    // entry here so it can live in Favorites without pretending to contain
    // messages in Mailficient's cache.
    public const string GNOME_CALENDAR_ID = "gnome-calendar";
    public const string TASK_TODAY_ID = "local-tasks-today";
    public const string TASK_PLANNED_ID = "local-tasks-planned";
    private CacheDatabase cache;
    private DemoMailRepository demo;
    private bool demo_mode;
    private int batch_depth;
    private bool batch_changed;

    public CachedMailRepository (CacheDatabase cache, DemoMailRepository demo, bool demo_mode = false) {
        this.cache = cache;
        this.demo = demo;
        this.demo_mode = demo_mode;
        demo.changed.connect (() => {
            if (is_demo_mode ()) notify_changed ();
        });
    }

    private void notify_changed () {
        if (batch_depth > 0) { batch_changed = true; return; }
        changed ();
    }

    public void begin_batch () { batch_depth++; }

    public void end_batch () {
        if (batch_depth == 0) return;
        batch_depth--;
        if (batch_depth == 0 && batch_changed) {
            batch_changed = false;
            changed ();
        }
    }

    private bool is_demo_mode () {
        if (!demo_mode) return false;
        try { return cache.list_accounts ().size == 0; }
        catch (Error error) { warning ("Could not determine account mode: %s", error.message); return false; }
    }

    public Gee.List<Mailbox> list_mailboxes () {
        int64 started = DebugTrace.mark ();
        DebugTrace.log ("repository", "list_mailboxes begin");
        if (is_demo_mode ()) {
            var result = new Gee.ArrayList<Mailbox> (); result.add_all (demo.list_mailboxes ());
            try {
                foreach (var mailbox in result)
                    if (mailbox.role == MailboxRole.DRAFTS)
                        mailbox.unread_count = (uint) cache.saved_draft_count ();
                result.insert (4, new Mailbox (LOCAL_OUTBOX_ID, "Outbox", "mail-send-symbolic", MailboxRole.CUSTOM, (uint) cache.outbox_count ()));
            }
            catch (Error error) { warning ("Could not count queued messages: %s", error.message); }
            append_smart_mailboxes (result);
            prepend_productivity_views (result);
            DebugTrace.duration ("repository", "list_mailboxes demo complete count=%d".printf (result.size), started);
            return result;
        }
        try {
            var result = new Gee.ArrayList<Mailbox> ();
            if (cache.list_accounts ().size == 0) {
                prepend_productivity_views (result);
                DebugTrace.duration ("repository", "list_mailboxes no-accounts complete", started);
                return result;
            }
            result.add (new Mailbox ("unified-inbox", "Inbox", "mail-inbox-symbolic", MailboxRole.INBOX, cache.unified_unread_count ()));
            result.add (new Mailbox ("unified-vip", "VIP", "starred-symbolic", MailboxRole.VIP, cache.smart_unread_count ("unified-vip")));
            result.add (new Mailbox ("unified-flagged", "Flagged", "mailficient-flag-symbolic", MailboxRole.FLAGGED, cache.smart_unread_count ("unified-flagged")));
            result.add (new Mailbox (LOCAL_DRAFTS_ID, "Drafts", "document-edit-symbolic", MailboxRole.DRAFTS, (uint) cache.saved_draft_count ()));
            result.add (new Mailbox (LOCAL_OUTBOX_ID, "Outbox", "mail-send-symbolic", MailboxRole.CUSTOM, (uint) cache.outbox_count ()));
            result.add (new Mailbox ("unified-sent", "Sent", "mail-sent-symbolic", MailboxRole.SENT,
                cache.unified_unread_count (MailboxRole.SENT)));
            result.add (new Mailbox ("unified-archive", "Archive", "package-x-generic-symbolic", MailboxRole.ARCHIVE,
                cache.archive_unread_count ()));
            result.add (new Mailbox ("unified-junk", "Junk", "dialog-warning-symbolic", MailboxRole.JUNK,
                cache.unified_unread_count (MailboxRole.JUNK)));
            result.add (new Mailbox ("unified-trash", "Trash", "user-trash-symbolic", MailboxRole.TRASH,
                cache.unified_unread_count (MailboxRole.TRASH)));
            result.add (new Mailbox ("unified-snoozed", "Snoozed", "alarm-symbolic", MailboxRole.SNOOZED,
                (uint) cache.count_cached_messages ("unified-snoozed", true)));
            result.add_all (cache.list_cached_mailboxes ());
            append_smart_mailboxes (result);
            prepend_productivity_views (result);
            DebugTrace.duration ("repository", "list_mailboxes complete count=%d".printf (result.size), started);
            return result;
        } catch (Error error) {
            warning ("Could not load cached mailboxes: %s", error.message);
            return new Gee.ArrayList<Mailbox> ();
        }
    }

    public Gee.List<Message> list_messages (string mailbox_id, string query = "",
                                            int limit = CacheDatabase.DEFAULT_MESSAGE_PAGE_SIZE,
                                            int offset = 0,
                                            bool unread_only = false,
                                            MessageSortMode sort_mode = MessageSortMode.NEWEST) {
        if (mailbox_id == LOCAL_DRAFTS_ID || (is_demo_mode () && mailbox_id == "drafts")) return draft_messages ();
        if (mailbox_id == LOCAL_OUTBOX_ID) return outbox_messages ();
        var smart = smart_mailbox_for (mailbox_id);
        if (smart != null && !is_demo_mode ()) {
            try {
                var smart_query = SearchQuery.parse (smart.query + " " + query);
                if (unread_only) smart_query.unread = true;
                return cache.search_messages (smart_query, limit, offset, sort_mode);
            } catch (Error error) { warning ("Could not load Smart Mailbox: %s", error.message); }
        }
        if (is_demo_mode ()) return demo.list_messages (mailbox_id, query, limit, offset,
            unread_only, sort_mode);
        try { return cache.list_cached_messages (mailbox_id, limit, offset, unread_only, sort_mode); }
        catch (Error error) { warning ("Could not load cached messages: %s", error.message); return new Gee.ArrayList<Message> (); }
    }

    public int message_count (string mailbox_id, string query = "", bool unread_only = false) {
        int64 started = DebugTrace.mark ();
        DebugTrace.log ("repository", "message_count begin mailbox=%s unread=%s".printf (
            mailbox_id, unread_only.to_string ()));
        if (mailbox_id == LOCAL_DRAFTS_ID || (is_demo_mode () && mailbox_id == "drafts"))
            return draft_messages ().size;
        if (mailbox_id == LOCAL_OUTBOX_ID) return outbox_messages ().size;
        var smart = smart_mailbox_for (mailbox_id);
        if (smart != null && !is_demo_mode ()) {
            try {
                var smart_query = SearchQuery.parse (smart.query + " " + query);
                if (unread_only) smart_query.unread = true;
                return cache.count_search_messages (smart_query);
            } catch (Error error) { warning ("Could not count Smart Mailbox: %s", error.message); return 0; }
        }
        if (is_demo_mode ()) return demo.message_count (mailbox_id, query, unread_only);
        try {
            int count = cache.count_cached_messages (mailbox_id, unread_only);
            DebugTrace.duration ("repository", "message_count complete count=%d".printf (count), started);
            return count;
        }
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

    private SmartMailbox? smart_mailbox_for (string mailbox_id) {
        if (!mailbox_id.has_prefix (SMART_MAILBOX_PREFIX)) return null;
        try { return cache.find_smart_mailbox (int64.parse (mailbox_id.substring (SMART_MAILBOX_PREFIX.length))); }
        catch (Error error) { warning ("Could not resolve Smart Mailbox: %s", error.message); return null; }
    }

    private void append_smart_mailboxes (Gee.ArrayList<Mailbox> result) {
        try {
            foreach (var smart in cache.list_smart_mailboxes ()) {
                var unread = SearchQuery.parse (smart.query); unread.unread = true;
                result.add (new Mailbox (SMART_MAILBOX_PREFIX + smart.id.to_string (), smart.name,
                    "view-filter-symbolic", MailboxRole.CUSTOM, (uint) cache.count_search_messages (unread)));
            }
        } catch (Error error) { warning ("Could not load Smart Mailboxes: %s", error.message); }
    }

    private void prepend_productivity_views (Gee.ArrayList<Mailbox> result) {
        uint today_count = 0; uint planned_count = 0;
        try {
            today_count = (uint) cache.mail_task_count (true);
            planned_count = (uint) cache.mail_task_count ();
        } catch (Error error) {
            warning ("Could not count tasks: %s", error.message);
        }
        result.insert (0, new Mailbox (GNOME_CALENDAR_ID, "Calendar",
            "x-office-calendar-symbolic", MailboxRole.CUSTOM));
        result.insert (0, new Mailbox (TASK_PLANNED_ID, "Planned",
            "checkbox-symbolic", MailboxRole.CUSTOM, planned_count));
        result.insert (0, new Mailbox (TASK_TODAY_ID, "Today",
            "task-due-symbolic", MailboxRole.CUSTOM, today_count));
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
            // The cache update already reads only the small state columns and
            // is idempotent. Do not load the complete body, HTML, or
            // attachments merely to decide whether a read notification is
            // needed.
            if (cache.set_cached_read (id, read)) notify_changed ();
        }
        catch (Error error) { warning ("Could not update read state: %s", error.message); }
    }

    public void set_flagged (string id, bool flagged) {
        if (id.has_prefix (DRAFT_PREFIX) || id.has_prefix (OUTBOX_PREFIX)) return;
        if (is_demo_mode ()) { demo.set_flagged (id, flagged); return; }
        try { if (cache.set_cached_flagged (id, flagged)) notify_changed (); }
        catch (Error error) { warning ("Could not update flag state: %s", error.message); }
    }
    public void set_flag_color (string id, string color) {
        if (id.has_prefix (DRAFT_PREFIX) || id.has_prefix (OUTBOX_PREFIX)) return;
        if (is_demo_mode ()) { demo.set_flag_color (id, color); return; }
        try { if (cache.set_cached_flag_color (id, color)) notify_changed (); }
        catch (Error error) { warning ("Could not update flag color: %s", error.message); }
    }
    public bool sender_is_vip (Message message) {
        if (is_demo_mode ()) return demo.sender_is_vip (message);
        try { return cache.is_vip_sender (message.sender_address); }
        catch (Error error) { warning ("Could not inspect VIP sender: %s", error.message); return false; }
    }
    public void set_sender_vip (Message message, bool vip) throws MailError {
        if (is_demo_mode ()) demo.set_sender_vip (message, vip);
        else { cache.set_vip_sender (message.sender_address, vip); notify_changed (); }
    }

    public void reload () { notify_changed (); }
    public void move_to_role (string id, MailboxRole role) throws MailError {
        if (is_demo_mode ()) { demo.move_to_role (id, role); return; }
        cache.queue_message_transfer (id, role, false); notify_changed ();
    }
    public void classify_junk (string id, bool junk) throws MailError {
        if (is_demo_mode ()) { demo.classify_junk (id, junk); return; }
        cache.queue_junk_classification (id, junk); notify_changed ();
    }
    public void transfer_to_mailbox (string id, string mailbox_id, bool copy) throws MailError {
        if (is_demo_mode ()) { demo.transfer_to_mailbox (id, mailbox_id, copy); return; }
        cache.queue_message_transfer_to (id, mailbox_id, copy); notify_changed ();
    }
    public void undo_transfer (string id, string original_mailbox_id) throws MailError {
        if (is_demo_mode ()) { demo.undo_transfer (id, original_mailbox_id); return; }
        cache.undo_queued_transfer (id, original_mailbox_id); notify_changed ();
    }
    public void permanently_delete (string id) throws MailError {
        if (is_demo_mode ()) { demo.permanently_delete (id); return; }
        cache.queue_permanent_delete (id); notify_changed ();
    }
    public void empty_role (MailboxRole role) throws MailError {
        if (is_demo_mode ()) { demo.empty_role (role); return; }
        cache.queue_role_purge (role); notify_changed ();
    }
    public void empty_mailbox (Mailbox mailbox) throws MailError {
        if (is_demo_mode ()) { demo.empty_mailbox (mailbox); return; }
        cache.queue_mailbox_purge (mailbox.id); notify_changed ();
    }
    public Gee.List<MailLabel> list_labels () throws MailError { return cache.list_mail_labels (); }
    public MailLabel create_label (string name, string color = "#3584e4") throws MailError {
        var label = cache.create_mail_label (name, color); notify_changed (); return label;
    }
    public void delete_label (int64 id) throws MailError { cache.delete_mail_label (id); notify_changed (); }
    public Gee.List<MailLabel> labels_for (string message_id) throws MailError {
        return cache.labels_for_message (message_id);
    }
    public void set_label (string message_id, int64 label_id, bool enabled) throws MailError {
        cache.set_message_label (message_id, label_id, enabled); notify_changed ();
    }
    public void snooze (string message_id, int64 until_unix) throws MailError {
        cache.snooze_message (message_id, until_unix); notify_changed ();
    }
    public void unsnooze (string message_id) throws MailError { cache.unsnooze_message (message_id); notify_changed (); }
    public bool is_snoozed (string message_id) throws MailError { return cache.message_is_snoozed (message_id); }

    private Gee.ArrayList<Message> draft_messages () {
        try { return cache.list_saved_draft_messages (); }
        catch (Error error) { warning ("Could not load saved drafts: %s", error.message); }
        return new Gee.ArrayList<Message> ();
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
        try { return cache.list_outbox_messages (); }
        catch (Error error) { warning ("Could not load Outbox: %s", error.message); }
        return new Gee.ArrayList<Message> ();
    }

    private static Message outbox_message (OutboxItem item) {
        var draft = item.draft;
        string preview;
        if (item.is_actively_sending ())
            preview = "Sending now…";
        else if (item.delivery_state == OutboxDeliveryState.SENDING)
            preview = "Delivery status uncertain — this message will not resend automatically";
        else if (item.delivery_state == OutboxDeliveryState.ACCEPTED)
            preview = "Sent — waiting for local Outbox cleanup";
        else if (item.delivery_state == OutboxDeliveryState.REJECTED)
            preview = "Rejected by the mail server — review and correct before trying again";
        else if (item.delivery_state == OutboxDeliveryState.PREPARING)
            preview = "Sending in background — editing paused";
        else
            preview = item.attempts > 0 ? "Send failed — Mailficient will retry automatically" : "Waiting to send";
        return new Message (OUTBOX_PREFIX + draft.id, LOCAL_OUTBOX_ID, "Outbox", "", draft.to,
            draft.subject.strip () == "" ? "(No Subject)" : draft.subject, preview, draft.body_text, "Queued",
            false, false, draft.attachments.size > 0, 1, false, draft.account_id);
    }
}
}
