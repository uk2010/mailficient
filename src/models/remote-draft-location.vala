namespace Mailficient {
public class RemoteDraftLocation : Object {
    public string mailbox_name { get; construct; }
    public string remote_uid { get; construct; }

    public RemoteDraftLocation (string mailbox_name, string remote_uid) {
        Object (mailbox_name: mailbox_name, remote_uid: remote_uid);
    }
}
}
