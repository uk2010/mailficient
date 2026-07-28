namespace Mailficient {
public class PendingTransfer : Object {
    public string message_id { get; construct; }
    public string account_id { get; construct; }
    public string source_mailbox { get; construct; }
    public string destination_mailbox { get; construct; }
    public string remote_uid { get; construct; }
    public bool copy { get; construct; }

    public PendingTransfer (string message_id, string account_id, string source_mailbox,
                            string destination_mailbox, string remote_uid, bool copy) {
        Object (message_id: message_id, account_id: account_id, source_mailbox: source_mailbox,
                destination_mailbox: destination_mailbox, remote_uid: remote_uid, copy: copy);
    }
}
}
