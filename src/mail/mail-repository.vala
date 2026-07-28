namespace Mailficient {
public interface MailRepository : Object {
    public signal void changed ();
    public abstract Gee.List<Mailbox> list_mailboxes ();
    public abstract Gee.List<Message> list_messages (string mailbox_id, string query = "",
                                                     int limit = 500, int offset = 0,
                                                     bool unread_only = false,
                                                     MessageSortMode sort_mode = MessageSortMode.NEWEST);
    public abstract int message_count (string mailbox_id, string query = "",
                                       bool unread_only = false);
    public abstract Message? find_message (string id);
    public abstract Gee.List<Message> conversation_for (Message message);
    public abstract void mark_read (string id, bool read);
    public abstract void set_flagged (string id, bool flagged);
    public abstract bool sender_is_vip (Message message);
    public abstract void set_sender_vip (Message message, bool vip) throws MailError;
    public abstract void reload ();
    public abstract void move_to_role (string id, MailboxRole role) throws MailError;
    public abstract void classify_junk (string id, bool junk) throws MailError;
    public abstract void transfer_to_mailbox (string id, string mailbox_id, bool copy) throws MailError;
    public abstract void undo_transfer (string id, string original_mailbox_id) throws MailError;
    public abstract void permanently_delete (string id) throws MailError;
    public abstract void empty_role (MailboxRole role) throws MailError;
    public abstract Gee.List<MailLabel> list_labels () throws MailError;
    public abstract MailLabel create_label (string name, string color = "#3584e4") throws MailError;
    public abstract void delete_label (int64 id) throws MailError;
    public abstract Gee.List<MailLabel> labels_for (string message_id) throws MailError;
    public abstract void set_label (string message_id, int64 label_id, bool enabled) throws MailError;
    public abstract void snooze (string message_id, int64 until_unix) throws MailError;
    public abstract void unsnooze (string message_id) throws MailError;
    public abstract bool is_snoozed (string message_id) throws MailError;
}
}
