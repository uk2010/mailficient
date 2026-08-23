namespace Mailficient {
public class OnlineMailAccount : Object {
    public string object_path { get; construct; }
    public string provider_name { get; construct; }
    public string display_name { get; construct; }
    public string email { get; construct; }
    public string incoming_host { get; construct; }
    public string incoming_username { get; construct; }
    public bool incoming_ssl { get; construct; }
    public bool incoming_starttls { get; construct; }
    public string outgoing_host { get; construct; }
    public string outgoing_username { get; construct; }
    public bool outgoing_ssl { get; construct; }
    public bool outgoing_starttls { get; construct; }

    public OnlineMailAccount (string object_path, string provider_name, string display_name,
                              string email, string incoming_host, string incoming_username,
                              bool incoming_ssl, bool incoming_starttls, string outgoing_host,
                              string outgoing_username, bool outgoing_ssl, bool outgoing_starttls) {
        Object (object_path: object_path, provider_name: provider_name,
            display_name: display_name, email: email, incoming_host: incoming_host,
            incoming_username: incoming_username, incoming_ssl: incoming_ssl,
            incoming_starttls: incoming_starttls, outgoing_host: outgoing_host,
            outgoing_username: outgoing_username, outgoing_ssl: outgoing_ssl,
            outgoing_starttls: outgoing_starttls);
    }

    public AccountSettings to_settings () throws MailError {
        if (!incoming_ssl && !incoming_starttls)
            throw new MailError.INVALID_ACCOUNT (
                "GNOME Online Accounts did not provide secure incoming-mail settings");
        if (!outgoing_ssl && !outgoing_starttls)
            throw new MailError.INVALID_ACCOUNT (
                "GNOME Online Accounts did not provide secure outgoing-mail settings");
        string incoming_server; uint incoming_port;
        split_endpoint (incoming_host, incoming_ssl ? 993 : 143, out incoming_server, out incoming_port);
        string outgoing_server; uint outgoing_port;
        split_endpoint (outgoing_host, outgoing_ssl ? 465 : 587, out outgoing_server, out outgoing_port);
        var settings = new AccountSettings ();
        settings.id = "goa-" + object_path.substring (object_path.last_index_of_char ('/') + 1);
        settings.display_name = display_name.strip () == "" ? email : display_name.strip ();
        settings.email = email.strip ();
        settings.incoming_host = incoming_server; settings.incoming_port = incoming_port;
        settings.incoming_username = incoming_username.strip ();
        settings.incoming_encryption = incoming_ssl ? EncryptionMode.TLS : EncryptionMode.STARTTLS;
        settings.outgoing_host = outgoing_server; settings.outgoing_port = outgoing_port;
        settings.outgoing_username = outgoing_username.strip ();
        settings.outgoing_encryption = outgoing_ssl ? EncryptionMode.TLS : EncryptionMode.STARTTLS;
        settings.authentication = AuthenticationMode.GNOME_ONLINE_ACCOUNTS;
        settings.online_account_path = object_path;
        settings.validate ();
        return settings;
    }

    internal static void split_endpoint (string endpoint, uint fallback_port,
                                         out string host, out uint port) throws MailError {
        host = endpoint.strip (); port = fallback_port;
        int separator = host.last_index_of_char (':');
        if (separator > 0 && host.index_of_char (':') == separator) {
            uint parsed;
            if (uint.try_parse (host.substring (separator + 1), out parsed) && parsed > 0 && parsed <= 65535) {
                port = parsed; host = host.substring (0, separator);
            }
        }
        if (host == "") throw new MailError.INVALID_ACCOUNT ("GNOME Online Accounts did not provide a mail server");
    }
}
}
