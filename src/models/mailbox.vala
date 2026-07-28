namespace Mailficient {
public enum MailboxRole { INBOX, VIP, FLAGGED, DRAFTS, SENT, JUNK, TRASH, ARCHIVE, CUSTOM, SNOOZED }

public class Mailbox : Object {
    public string id { get; construct; }
    public string name { get; construct; }
    public string icon_name { get; construct; }
    public MailboxRole role { get; construct; }
    public uint unread_count { get; set; }
    public string account_id { get; construct; }
    public string remote_name { get; construct; }

    public Mailbox (string id, string name, string icon_name, MailboxRole role, uint unread_count = 0,
                    string account_id = "", string remote_name = "") {
        Object (id: id, name: name, icon_name: icon_name, role: role, unread_count: unread_count,
                account_id: account_id, remote_name: remote_name);
    }
}
}
