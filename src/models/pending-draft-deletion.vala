namespace Mailficient {
public class PendingDraftDeletion : Object {
    public int64 id { get; construct; }
    public string account_id { get; construct; }
    public string mailbox_name { get; construct; }
    public string remote_uid { get; construct; }
    public string expected_message_id { get; construct; }

    public PendingDraftDeletion (int64 id, string account_id, string mailbox_name,
                                 string remote_uid, string expected_message_id) {
        Object (id: id, account_id: account_id, mailbox_name: mailbox_name,
                remote_uid: remote_uid, expected_message_id: expected_message_id);
    }
}
}
