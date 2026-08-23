namespace Mailficient {
public class RemoteMessageState : Object {
    public string message_id { get; construct; }
    public bool unread { get; construct; }
    public bool flagged { get; construct; }

    public RemoteMessageState (string message_id, bool unread, bool flagged) {
        Object (message_id: message_id, unread: unread, flagged: flagged);
    }
}
}
