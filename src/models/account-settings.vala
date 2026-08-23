namespace Mailficient {
public enum EncryptionMode { TLS, STARTTLS, NONE }
public enum AuthenticationMode { PASSWORD, GNOME_ONLINE_ACCOUNTS }
public enum MailProvider { OTHER, ICLOUD, MICROSOFT, GOOGLE, YAHOO, AOL }

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
        string domain = email.contains ("@") ? email.substring (email.last_index_of_char ('@') + 1).down () : "";
        MailProvider provider = MailProvider.OTHER;
        if (domain == "gmail.com" || domain == "googlemail.com") provider = MailProvider.GOOGLE;
        else if (domain == "outlook.com" || domain == "hotmail.com" || domain == "live.com" ||
                 domain == "msn.com") provider = MailProvider.MICROSOFT;
        else if (domain == "icloud.com" || domain == "me.com" || domain == "mac.com")
            provider = MailProvider.ICLOUD;
        else if (domain == "yahoo.com" || domain == "ymail.com" || domain == "rocketmail.com")
            provider = MailProvider.YAHOO;
        else if (domain == "aol.com") provider = MailProvider.AOL;
        return for_provider (provider, display_name, email);
    }

    public static AccountSettings for_provider (MailProvider provider, string display_name, string email) {
        var value = new AccountSettings (); value.display_name = display_name; value.email = email;
        value.incoming_username = email; value.outgoing_username = email;
        switch (provider) {
        case MailProvider.ICLOUD:
            value.incoming_host = "imap.mail.me.com"; value.incoming_port = 993;
            value.outgoing_host = "smtp.mail.me.com"; value.outgoing_port = 587;
            value.outgoing_encryption = EncryptionMode.STARTTLS;
            if (email.contains ("@"))
                value.incoming_username = email.substring (0, email.last_index_of_char ('@'));
            break;
        case MailProvider.MICROSOFT:
            value.incoming_host = "outlook.office365.com"; value.incoming_port = 993;
            value.outgoing_host = "smtp.office365.com"; value.outgoing_port = 587;
            value.outgoing_encryption = EncryptionMode.STARTTLS;
            break;
        case MailProvider.GOOGLE:
            value.incoming_host = "imap.gmail.com"; value.incoming_port = 993;
            value.outgoing_host = "smtp.gmail.com"; value.outgoing_port = 465;
            break;
        case MailProvider.YAHOO:
            value.incoming_host = "imap.mail.yahoo.com"; value.incoming_port = 993;
            value.outgoing_host = "smtp.mail.yahoo.com"; value.outgoing_port = 465;
            break;
        case MailProvider.AOL:
            value.incoming_host = "imap.aol.com"; value.incoming_port = 993;
            value.outgoing_host = "smtp.aol.com"; value.outgoing_port = 465;
            break;
        default:
            break;
        }
        return value;
    }
}
}
