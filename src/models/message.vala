namespace Mailficient {
public class Message : Object {
    public string id { get; construct; }
    public string mailbox_id { get; set; }
    public string sender_name { get; construct; }
    public string sender_address { get; construct; }
    public string recipients { get; construct; }
    public string cc_recipients { get; set; default = ""; }
    public string subject { get; construct; }
    public string preview { get; construct; }
    public string body { get; construct; }
    public string timestamp { get; construct; }
    public bool unread { get; set; }
    public bool flagged { get; set; }
    // IMAP exposes a single flagged bit. Keep the chosen display color as
    // local metadata while continuing to synchronize the standard flag.
    public string flag_color { get; set; default = "red"; }
    public bool has_attachment { get; construct; }
    public uint conversation_count { get; construct; default = 1; }
    public bool has_remote_content { get; construct; }
    public string body_html { get; set; default = ""; }
    public string account_id { get; construct; }
    public string remote_uid { get; construct; }
    public string internet_message_id { get; construct; }
    public string in_reply_to { get; construct; }
    public string references { get; construct; }
    public int64 date_unix { get; set; }
    public string security_status { get; set; default = ""; }
    public Gee.ArrayList<Attachment> attachments { get; private set; default = new Gee.ArrayList<Attachment> (); }
    public Gee.ArrayList<MailLabel> labels { get; private set; default = new Gee.ArrayList<MailLabel> (); }

    public Message (string id, string mailbox_id, string sender_name, string sender_address,
                    string recipients, string subject, string preview, string body, string timestamp,
                    bool unread = false, bool flagged = false, bool has_attachment = false,
                    uint conversation_count = 1, bool has_remote_content = false,
                    string account_id = "", string remote_uid = "", string internet_message_id = "",
                    string in_reply_to = "", string references = "", int64 date_unix = 0,
                    string cc_recipients = "", string flag_color = "red") {
        Object (id: id, mailbox_id: mailbox_id, sender_name: sender_name,
                sender_address: sender_address, recipients: recipients, cc_recipients: cc_recipients, subject: subject,
                preview: preview, body: body, timestamp: timestamp, unread: unread,
                flagged: flagged, flag_color: flag_color, has_attachment: has_attachment,
                conversation_count: conversation_count, has_remote_content: has_remote_content,
                account_id: account_id, remote_uid: remote_uid, internet_message_id: internet_message_id,
                in_reply_to: in_reply_to, references: references, date_unix: date_unix);
    }

    public string initials () {
        var parts = sender_name.split (" ");
        if (parts.length > 1) return "%c%c".printf (parts[0][0], parts[parts.length - 1][0]).up ();
        return sender_name.substring (0, int.min (2, sender_name.length)).up ();
    }

    public void add_attachment (Attachment attachment) { attachments.add (attachment); }
}
}
