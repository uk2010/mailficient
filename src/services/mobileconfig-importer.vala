namespace Mailficient {
public class MobileConfigAccount : Object {
    public AccountSettings settings { get; construct; }
    public string incoming_password { get; construct; default = ""; }
    public string outgoing_password { get; construct; default = ""; }

    public MobileConfigAccount (AccountSettings settings, string incoming_password = "",
                                string outgoing_password = "") {
        Object (settings: settings, incoming_password: incoming_password,
                outgoing_password: outgoing_password);
    }
}

public class MobileConfigImporter : Object {
    public const int64 MAX_PROFILE_BYTES = 5 * 1024 * 1024;

    [CCode (cname = "mailficient_mobileconfig_decode",
            cheader_filename = "services/mobileconfig-decoder.h")]
    private static extern string decode_profile (
        [CCode (array_length_type = "gsize")] uint8[] data) throws Error;

    public static Gee.List<MobileConfigAccount> parse (uint8[] data) throws Error {
        string xml = decode_profile (data);
        if (xml.length == 0 || xml.length > MAX_PROFILE_BYTES)
            throw new MailError.INVALID_ACCOUNT ("The configuration profile is empty or too large");

        int options = Xml.ParserOption.NONET | Xml.ParserOption.NOERROR |
            Xml.ParserOption.NOWARNING | Xml.ParserOption.NOBLANKS | Xml.ParserOption.COMPACT;
        Xml.Doc* document = Xml.Parser.read_memory (xml, xml.length,
            "mobileconfig.xml", "UTF-8", options);
        if (document == null)
            throw new MailError.INVALID_ACCOUNT ("The configuration profile contains invalid XML");

        var accounts = new Gee.ArrayList<MobileConfigAccount> ();
        Xml.Node* root = document->get_root_element ();
        Xml.Node* top_dict = root == null ? null : first_child_named (root, "dict");
        Xml.Node* payloads = top_dict == null ? null : dict_value (top_dict, "PayloadContent");
        if (payloads != null && node_name (payloads) == "array") {
            for (Xml.Node* payload = first_element (payloads); payload != null;
                 payload = next_element (payload)) {
                if (node_name (payload) != "dict" ||
                    string_value (dict_value (payload, "PayloadType")) != "com.apple.mail.managed")
                    continue;
                accounts.add (parse_mail_payload (payload));
            }
        }
        delete document;

        if (accounts.size == 0)
            throw new MailError.INVALID_ACCOUNT ("This profile does not contain an Apple Mail account");
        return accounts;
    }

    private static MobileConfigAccount parse_mail_payload (Xml.Node* payload) throws MailError {
        string account_type = string_value (dict_value (payload, "EmailAccountType"));
        if (account_type != "EmailTypeIMAP")
            throw new MailError.INVALID_ACCOUNT ("Only IMAP accounts can be imported from configuration profiles");

        string incoming_auth = string_value (dict_value (payload, "IncomingMailServerAuthentication"));
        string outgoing_auth = string_value (dict_value (payload, "OutgoingMailServerAuthentication"));
        if ((incoming_auth != "" && incoming_auth != "EmailAuthPassword") ||
            (outgoing_auth != "" && outgoing_auth != "EmailAuthPassword"))
            throw new MailError.INVALID_ACCOUNT ("The profile uses an unsupported mail authentication method");

        var settings = new AccountSettings ();
        settings.display_name = first_nonempty (
            string_value (dict_value (payload, "EmailAccountName")),
            string_value (dict_value (payload, "EmailAccountDescription")));
        settings.email = string_value (dict_value (payload, "EmailAddress"));
        if (settings.display_name == "") settings.display_name = settings.email;
        settings.incoming_host = string_value (dict_value (payload, "IncomingMailServerHostName"));
        settings.outgoing_host = string_value (dict_value (payload, "OutgoingMailServerHostName"));
        settings.incoming_username = first_nonempty (
            string_value (dict_value (payload, "IncomingMailServerUsername")), settings.email);
        settings.outgoing_username = first_nonempty (
            string_value (dict_value (payload, "OutgoingMailServerUsername")), settings.email);

        bool incoming_ssl = bool_value (dict_value (payload, "IncomingMailServerUseSSL"), true);
        bool outgoing_ssl = bool_value (dict_value (payload, "OutgoingMailServerUseSSL"), true);
        settings.incoming_encryption = incoming_ssl ? EncryptionMode.TLS : EncryptionMode.STARTTLS;
        settings.outgoing_encryption = outgoing_ssl ? EncryptionMode.TLS : EncryptionMode.STARTTLS;
        settings.incoming_port = port_value (dict_value (payload, "IncomingMailServerPortNumber"),
            incoming_ssl ? 993 : 143, "incoming");
        settings.outgoing_port = port_value (dict_value (payload, "OutgoingMailServerPortNumber"),
            outgoing_ssl ? 465 : 587, "outgoing");
        settings.validate ();

        string incoming_password = string_value (
            dict_value (payload, "IncomingMailServerPassword"));
        string outgoing_password = string_value (
            dict_value (payload, "OutgoingMailServerPassword"));
        if (outgoing_password == "" &&
            bool_value (dict_value (payload, "OutgoingPasswordSameAsIncomingPassword"), false))
            outgoing_password = incoming_password;
        return new MobileConfigAccount (settings, incoming_password, outgoing_password);
    }

    private static uint port_value (Xml.Node* node, uint fallback, string label) throws MailError {
        if (node == null) return fallback;
        uint value = 0;
        if (!uint.try_parse (string_value (node), out value) || value == 0 || value > 65535)
            throw new MailError.INVALID_ACCOUNT ("The profile's %s server port is invalid".printf (label));
        return value;
    }

    private static string first_nonempty (string first, string second) {
        return first.strip () == "" ? second.strip () : first.strip ();
    }

    private static bool bool_value (Xml.Node* node, bool fallback) {
        if (node == null) return fallback;
        if (node_name (node) == "true") return true;
        if (node_name (node) == "false") return false;
        return fallback;
    }

    private static string string_value (Xml.Node* node) {
        if (node == null) return "";
        for (Xml.Node* child = node->children; child != null; child = child->next) {
            if (child->type == Xml.ElementType.TEXT_NODE ||
                child->type == Xml.ElementType.CDATA_SECTION_NODE)
                return ((string) (child->content ?? "")).strip ();
        }
        return "";
    }

    private static Xml.Node* dict_value (Xml.Node* dict, string wanted_key) {
        for (Xml.Node* key = first_element (dict); key != null; key = next_element (key)) {
            if (node_name (key) != "key" || string_value (key) != wanted_key) continue;
            return next_element (key);
        }
        return null;
    }

    private static Xml.Node* first_child_named (Xml.Node* parent, string wanted_name) {
        for (Xml.Node* child = first_element (parent); child != null; child = next_element (child))
            if (node_name (child) == wanted_name) return child;
        return null;
    }

    private static Xml.Node* first_element (Xml.Node* parent) {
        if (parent == null) return null;
        Xml.Node* child = parent->children;
        while (child != null && child->type != Xml.ElementType.ELEMENT_NODE) child = child->next;
        return child;
    }

    private static Xml.Node* next_element (Xml.Node* node) {
        if (node == null) return null;
        Xml.Node* next = node->next;
        while (next != null && next->type != Xml.ElementType.ELEMENT_NODE) next = next->next;
        return next;
    }

    private static string node_name (Xml.Node* node) {
        return node == null ? "" : ((string) node->name).down ();
    }
}
}
