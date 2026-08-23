namespace Mailficient {
public enum ComposeMode { NEW, REPLY, REPLY_ALL, FORWARD }
public enum MessageSecurityProtocol { NONE, OPENPGP, SMIME }

public class Draft : Object {
    public string id { get; construct; default = Uuid.string_random (); }
    public string account_id { get; set; }
    public string to { get; set; default = ""; }
    public string cc { get; set; default = ""; }
    public string bcc { get; set; default = ""; }
    public string subject { get; set; default = ""; }
    public string body_text { get; set; default = ""; }
    public string body_html { get; set; default = ""; }
    public string body_format { get; set; default = ""; }
    public string in_reply_to { get; set; default = ""; }
    public string references { get; set; default = ""; }
    public MessageSecurityProtocol security_protocol { get; set; default = MessageSecurityProtocol.NONE; }
    public bool sign_message { get; set; default = false; }
    public bool encrypt_message { get; set; default = false; }
    public string security_identity { get; set; default = ""; }
    public int64 modified_at { get; set; default = new DateTime.now_utc ().to_unix (); }
    public bool dirty { get; private set; default = true; }
    public Gee.ArrayList<Attachment> attachments { get; private set; default = new Gee.ArrayList<Attachment> (); }

    public Draft (string account_id, string? id = null) { Object (account_id: account_id, id: id ?? Uuid.string_random ()); }
    public void touch () { modified_at = new DateTime.now_utc ().to_unix (); dirty = true; }
    public void mark_saved () { dirty = false; }
    public void add_attachment (Attachment attachment) { attachments.add (attachment); touch (); }
    public void remove_attachment (Attachment attachment) { attachments.remove (attachment); touch (); }
    public void validate_for_send () throws MailError {
        RecipientParser.parse (to);
        if (cc.strip () != "") RecipientParser.parse (cc);
        if (bcc.strip () != "") RecipientParser.parse (bcc);
        if ((sign_message || encrypt_message) && security_protocol == MessageSecurityProtocol.NONE)
            throw new MailError.INVALID_MESSAGE ("Choose OpenPGP or S/MIME for signing and encryption");
    }

    public Gee.ArrayList<string> security_recipients (string sender_address) throws MailError {
        var recipients = new Gee.ArrayList<string> ();
        var seen = new Gee.HashSet<string> ();
        foreach (var value in new string[] { to, cc, bcc, sender_address }) {
            if (value.strip () == "") continue;
            foreach (var recipient in RecipientParser.parse (value)) {
                string address = recipient.address.strip ().down ();
                if (seen.add (address)) recipients.add (address);
            }
        }
        return recipients;
    }

    public bool can_send () { try { validate_for_send (); return true; } catch (Error error) { return false; } }
}
}
