namespace Mailficient {
// A provider Drafts message converted into editable compose data. Attachment
// paths still point at the bounded received-message cache; DraftSyncService
// copies only safe regular files into private draft storage before persistence.
public class RemoteDraftSnapshot : Object {
    public Draft draft { get; construct; }
    public string mailbox_name { get; construct; }
    public string remote_uid { get; construct; }
    public string internet_message_id { get; construct; }
    public bool managed_by_mailficient { get; construct; }
    public string content_fingerprint { get; construct; }

    public RemoteDraftSnapshot (Draft draft, string mailbox_name, string remote_uid,
                                string internet_message_id,
                                bool managed_by_mailficient = false,
                                string content_fingerprint = "") {
        Object (draft: draft, mailbox_name: mailbox_name, remote_uid: remote_uid,
                internet_message_id: internet_message_id,
                managed_by_mailficient: managed_by_mailficient,
                content_fingerprint: content_fingerprint);
    }
}
}
