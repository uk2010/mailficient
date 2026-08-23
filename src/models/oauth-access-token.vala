namespace Mailficient {
public class OAuthAccessToken : Object {
    public string value { get; construct; }
    public int expires_in { get; construct; }

    public OAuthAccessToken (string value, int expires_in) throws MailError {
        if (value == "" || expires_in <= 0)
            throw new MailError.AUTHENTICATION ("GNOME Online Accounts returned an invalid access token");
        Object (value: value, expires_in: expires_in);
    }
}
}
