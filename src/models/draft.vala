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
    public int64 modified_at { get; set; default = 0; }
    // Revision is monotonic even when several autosaves happen within the same
    // second.  Remote Drafts use it as an idempotency key; modified_at remains
    // the human-facing sort timestamp.
    public int64 revision { get; set; default = 1; }
    public string remote_mailbox { get; set; default = ""; }
    public string remote_uid { get; set; default = ""; }
    public int64 remote_revision { get; set; default = 0; }
    public string remote_internet_message_id { get; set; default = ""; }
    public string remote_content_fingerprint { get; set; default = ""; }
    // Third-party drafts discovered on the provider stay non-owned until the
    // user edits or sends them. Only owned copies participate in remote delete.
    public bool remote_owned { get; set; default = false; }
    public bool dirty { get; private set; default = true; }
    public Gee.ArrayList<Attachment> attachments { get; private set; default = new Gee.ArrayList<Attachment> (); }

    public Draft (string account_id, string? id = null) {
        Object (account_id: account_id, id: id ?? Uuid.string_random ());
        // Dynamic object-valued property defaults are initialized once by
        // Vala's class machinery and retain their temporary DateTime. Set the
        // per-instance scalar explicitly instead.
        modified_at = GLib.get_real_time () / TimeSpan.SECOND;
    }
    public void touch () {
        modified_at = GLib.get_real_time () / TimeSpan.SECOND;
        revision = int64.max (1, revision + 1);
        dirty = true;
    }
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

    public string remote_message_id () {
        return remote_message_id_for (id, revision);
    }

    public static string remote_message_id_for (string draft_id, int64 revision) {
        return "mailficient-draft-%s-%s@mailficient.local".printf (
            draft_id, int64.max (1, revision).to_string ());
    }
}
}
