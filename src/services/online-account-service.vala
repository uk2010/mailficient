namespace Mailficient {
public interface OnlineAccountService : Object {
    public abstract async Gee.List<OnlineMailAccount> list_mail_accounts (Cancellable? cancellable = null) throws Error;
    public abstract async OAuthAccessToken request_access_token (string object_path, Cancellable? cancellable = null) throws Error;
}

public class GnomeOnlineAccountService : Object, OnlineAccountService {
    private const string BUS_NAME = "org.gnome.OnlineAccounts";
    private const string ROOT_PATH = "/org/gnome/OnlineAccounts";
    private const string ACCOUNT_IFACE = "org.gnome.OnlineAccounts.Account";
    private const string MAIL_IFACE = "org.gnome.OnlineAccounts.Mail";
    private const string OAUTH_IFACE = "org.gnome.OnlineAccounts.OAuth2Based";

    public async Gee.List<OnlineMailAccount> list_mail_accounts (Cancellable? cancellable = null) throws Error {
        try {
            var connection = yield Bus.get (BusType.SESSION, cancellable);
            var response = yield connection.call (BUS_NAME, ROOT_PATH,
                "org.freedesktop.DBus.ObjectManager", "GetManagedObjects", null,
                new VariantType ("(a{oa{sa{sv}}})"), DBusCallFlags.NONE, -1, cancellable);
            Variant objects;
            response.get ("(@a{oa{sa{sv}}})", out objects);
            return parse_accounts (objects);
        } catch (Error error) {
            throw normalize_error (error, "GNOME Online Accounts could not be reached");
        }
    }

    public async OAuthAccessToken request_access_token (string object_path,
                                                        Cancellable? cancellable = null) throws Error {
        if (!object_path.has_prefix ("/org/gnome/OnlineAccounts/Accounts/"))
            throw new MailError.AUTHENTICATION ("The GNOME Online Account reference is invalid");
        try {
            var connection = yield Bus.get (BusType.SESSION, cancellable);
            // Refresh expired authorization before requesting the short-lived token.
            yield connection.call (BUS_NAME, object_path, ACCOUNT_IFACE, "EnsureCredentials",
                null, new VariantType ("(i)"), DBusCallFlags.NONE, -1, cancellable);
            var response = yield connection.call (BUS_NAME, object_path, OAUTH_IFACE,
                "GetAccessToken", null, new VariantType ("(si)"),
                DBusCallFlags.NONE, -1, cancellable);
            string token; int expires_in;
            response.get ("(si)", out token, out expires_in);
            return new OAuthAccessToken (token, expires_in);
        } catch (Error error) {
            throw normalize_error (error, "The online account needs authorization");
        }
    }

    internal static Gee.List<OnlineMailAccount> parse_accounts (Variant objects) {
        var result = new Gee.ArrayList<OnlineMailAccount> ();
        var iterator = objects.iterator (); string object_path; Variant interfaces;
        while (iterator.next ("{o@a{sa{sv}}}", out object_path, out interfaces)) {
            var account = account_from_interfaces (object_path, interfaces);
            if (account != null) result.add (account);
        }
        return result;
    }

    internal static OnlineMailAccount? account_from_interfaces (string object_path,
                                                                 Variant interfaces) {
        Variant? account = interfaces.lookup_value (ACCOUNT_IFACE, new VariantType ("a{sv}"));
        Variant? mail = interfaces.lookup_value (MAIL_IFACE, new VariantType ("a{sv}"));
        Variant? oauth = interfaces.lookup_value (OAUTH_IFACE, new VariantType ("a{sv}"));
        if (account == null || mail == null || oauth == null || bool_property (account, "MailDisabled")) return null;
        if (!bool_property (mail, "ImapSupported") || !bool_property (mail, "SmtpSupported")) return null;
        // Camel authenticates imported OAuth accounts with XOAUTH2. Do not present
        // accounts whose SMTP backend explicitly cannot use that mechanism.
        if (!bool_property (mail, "SmtpAuthXoauth2")) return null;
        return new OnlineMailAccount (object_path,
            string_property (account, "ProviderName"), string_property (mail, "Name"),
            string_property (mail, "EmailAddress"), string_property (mail, "ImapHost"),
            string_property (mail, "ImapUserName"), bool_property (mail, "ImapUseSsl"),
            bool_property (mail, "ImapUseTls"), string_property (mail, "SmtpHost"),
            string_property (mail, "SmtpUserName"), bool_property (mail, "SmtpUseSsl"),
            bool_property (mail, "SmtpUseTls"));
    }

    private static string string_property (Variant properties, string name) {
        Variant? value = properties.lookup_value (name, VariantType.STRING);
        return value == null ? "" : value.get_string ();
    }

    private static bool bool_property (Variant properties, string name) {
        Variant? value = properties.lookup_value (name, VariantType.BOOLEAN);
        return value != null && value.get_boolean ();
    }

    private static Error normalize_error (Error error, string fallback) {
        if (error is MailError || error is IOError.CANCELLED) return error;
        if (error is DBusError.SERVICE_UNKNOWN || error is DBusError.NAME_HAS_NO_OWNER)
            return new MailError.CONNECTION ("GNOME Online Accounts is not available. Open Settings → Online Accounts first.");
        if (error is DBusError.ACCESS_DENIED || error is DBusError.AUTH_FAILED)
            return new MailError.AUTHENTICATION ("GNOME Online Accounts denied access. Reconnect the account in Settings.");
        return new MailError.AUTHENTICATION ("%s: %s".printf (fallback, error.message));
    }
}
}
