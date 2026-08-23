namespace Mailficient {
public class PendingDeletion : Object {
    public string message_id { get; construct; }
    public string account_id { get; construct; }
    public string mailbox_name { get; construct; }
    public string remote_uid { get; construct; }

    public PendingDeletion (string message_id, string account_id, string mailbox_name,
                            string remote_uid) {
        Object (message_id: message_id, account_id: account_id,
                mailbox_name: mailbox_name, remote_uid: remote_uid);
    }
}
}
