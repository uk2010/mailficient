namespace Mailficient {
public enum EncryptionMode { TLS, STARTTLS, NONE }
public enum AuthenticationMode { PASSWORD, GNOME_ONLINE_ACCOUNTS }

public class AccountSettings : Object {
    public string id { get; set; default = Uuid.string_random (); }
    public string display_name { get; set; default = ""; }
    public string email { get; set; default = ""; }
    public string incoming_host { get; set; default = ""; }
    public uint incoming_port { get; set; default = 993; }
    public EncryptionMode incoming_encryption { get; set; default = EncryptionMode.TLS; }
    public string incoming_username { get; set; default = ""; }
    public string outgoing_host { get; set; default = ""; }
    public uint outgoing_port { get; set; default = 465; }
    public EncryptionMode outgoing_encryption { get; set; default = EncryptionMode.TLS; }
    public string outgoing_username { get; set; default = ""; }
    public AuthenticationMode authentication { get; set; default = AuthenticationMode.PASSWORD; }
    public string online_account_path { get; set; default = ""; }

    public void validate () throws MailError {
        if (display_name.strip () == "") throw new MailError.INVALID_ACCOUNT ("A display name is required");
        if (!RecipientParser.is_valid_address (email)) throw new MailError.INVALID_ACCOUNT ("Enter a valid email address");
        validate_endpoint (incoming_host, incoming_port, "incoming");
        validate_endpoint (outgoing_host, outgoing_port, "outgoing");
        if (incoming_username.strip () == "" || outgoing_username.strip () == "")
            throw new MailError.INVALID_ACCOUNT ("Both server usernames are required");
        if (incoming_encryption == EncryptionMode.NONE || outgoing_encryption == EncryptionMode.NONE)
            throw new MailError.INVALID_ACCOUNT ("Unencrypted mail connections are not supported");
        if (authentication == AuthenticationMode.GNOME_ONLINE_ACCOUNTS &&
            !online_account_path.has_prefix ("/org/gnome/OnlineAccounts/Accounts/"))
            throw new MailError.INVALID_ACCOUNT ("Select a valid GNOME Online Account");
    }

    private static void validate_endpoint (string host, uint port, string label) throws MailError {
        if (host.strip () == "" || host.contains (" ") || !host.contains ("."))
            throw new MailError.INVALID_ACCOUNT ("The %s server address is invalid".printf (label));
        if (port == 0 || port > 65535)
            throw new MailError.INVALID_ACCOUNT ("The %s server port is invalid".printf (label));
    }

    public static AccountSettings for_email (string display_name, string email) {
        var value = new AccountSettings (); value.display_name = display_name; value.email = email;
        value.incoming_username = email; value.outgoing_username = email;
        string domain = email.contains ("@") ? email.substring (email.last_index_of_char ('@') + 1).down () : "";
        if (domain == "gmail.com") { value.incoming_host = "imap.gmail.com"; value.outgoing_host = "smtp.gmail.com"; value.outgoing_port = 465; }
        else if (domain == "outlook.com" || domain == "hotmail.com" || domain == "live.com") { value.incoming_host = "outlook.office365.com"; value.outgoing_host = "smtp.office365.com"; value.outgoing_port = 587; value.outgoing_encryption = EncryptionMode.STARTTLS; }
        return value;
    }
}
}
