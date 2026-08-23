namespace Mailficient {
public class PendingFolderPurge : Object {
    public string account_id { get; construct; }
    public string mailbox_name { get; construct; }

    public PendingFolderPurge (string account_id, string mailbox_name) {
        Object (account_id: account_id, mailbox_name: mailbox_name);
    }
}
}
