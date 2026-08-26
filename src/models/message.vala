namespace Mailficient {
public class Message : Object {
    public string id { get; construct; }
    public string mailbox_id { get; set; }
    public string sender_name { get; construct; }
    public string sender_address { get; construct; }
    public string recipients { get; construct; }
    public string cc_recipients { get; set; default = ""; }
    public string bcc_recipients { get; set; default = ""; }
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
    public int64 message_size { get; set; }
    public string security_status { get; set; default = ""; }
    // Security and list-management metadata is intentionally separate from
    // the rendered body. Raw headers are bounded by the mail engine before
    // they reach this model and are displayed as plain, selectable text.
    public string reply_to { get; set; default = ""; }
    public string authentication_results { get; set; default = ""; }
    public string list_unsubscribe { get; set; default = ""; }
    public string list_unsubscribe_post { get; set; default = ""; }
    public string raw_headers { get; set; default = ""; }
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
        string name = sender_name.strip ();
        if (name == "") return "?";

        // Vala string indexes and substring lengths are byte based. Taking
        // name[0] (or the first two bytes) can therefore split a multi-byte
        // character and hand invalid UTF-8 to GtkLabel/GtkAccessible. Build
        // the avatar text from complete Unicode code points instead.
        var words = new Gee.ArrayList<string> ();
        foreach (var part in name.split (" ")) {
            string word = part.strip ();
            if (word != "") words.add (word);
        }
        var result = new StringBuilder ();
        if (words.size > 1) {
            result.append_unichar (words[0].get_char ());
            result.append_unichar (words[words.size - 1].get_char ());
        } else {
            int byte_offset = 0;
            for (int count = 0; count < 2 && byte_offset < name.length; count++) {
                unichar character = name.get_char (byte_offset);
                result.append_unichar (character);
                byte_offset += character.to_utf8 (null);
            }
        }
        return result.str.up ();
    }

    public void add_attachment (Attachment attachment) { attachments.add (attachment); }
}
}
