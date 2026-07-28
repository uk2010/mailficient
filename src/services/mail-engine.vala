namespace Mailficient {
public interface MailEngine : Object {
    public signal void sync_batch_ready (MailSyncResult batch);
    public abstract async void connect_account (AccountSettings settings, Cancellable? cancellable = null) throws Error;
    public abstract async void disconnect_account (string account_id, Cancellable? cancellable = null) throws Error;
    public abstract async MailSyncResult synchronize (string account_id, Gee.Set<string>? cached_message_ids = null,
                                                       Cancellable? cancellable = null) throws Error;
    public abstract async SendResult send (Draft draft, Cancellable? cancellable = null) throws Error;
    public abstract async void save_remote_attachment (string account_id, string mailbox_name,
                                                       string remote_uid, int remote_part_index,
                                                       File destination, int64 maximum_bytes,
                                                       Cancellable? cancellable = null) throws Error;
    public abstract async void set_message_state (string account_id, string mailbox_name, string remote_uid,
                                                  MessageStateField field, bool value,
                                                  Cancellable? cancellable = null) throws Error;
    public abstract async string? transfer_message (string account_id, string source_mailbox, string remote_uid,
                                                    string destination_mailbox, bool copy,
                                                    Cancellable? cancellable = null) throws Error;
    public abstract async void create_folder (string account_id, string parent_name, string folder_name,
                                              Cancellable? cancellable = null) throws Error;
    public abstract async void rename_folder (string account_id, string old_name, string old_display_name,
                                              string new_display_name, Cancellable? cancellable = null) throws Error;
    public abstract async void delete_folder (string account_id, string folder_name,
                                              Cancellable? cancellable = null) throws Error;
    public abstract async void permanently_delete_message (string account_id, string mailbox_name,
                                                           string remote_uid,
                                                           Cancellable? cancellable = null) throws Error;
    public abstract async void empty_folder (string account_id, string folder_name,
                                             Cancellable? cancellable = null) throws Error;
    public abstract SyncState state_for (string account_id);
}
}
