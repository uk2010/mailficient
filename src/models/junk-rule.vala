namespace Mailficient {
public enum JunkRuleKind { ADDRESS, DOMAIN }

public class JunkRule : Object {
    public int64 id { get; construct; }
    public JunkRuleKind kind { get; construct; }
    public string pattern { get; construct; }

    public JunkRule (int64 id, JunkRuleKind kind, string pattern) {
        Object (id: id, kind: kind, pattern: pattern);
    }

    public bool matches (string sender_address) {
        string sender = sender_address.strip ().down ();
        if (kind == JunkRuleKind.ADDRESS) return sender == pattern;
        int at = sender.last_index_of_char ('@');
        return at >= 0 && at + 1 < sender.length && sender.substring (at + 1) == pattern;
    }

    public static string normalize (JunkRuleKind kind, string value) throws MailError {
        string pattern = value.strip ().down ();
        if (kind == JunkRuleKind.DOMAIN && pattern.has_prefix ("@")) pattern = pattern.substring (1);
        bool invalid = pattern == "" || pattern.contains (" ") || pattern.contains ("/");
        if (kind == JunkRuleKind.ADDRESS)
            invalid = invalid || pattern.index_of_char ('@') <= 0 || pattern.has_suffix ("@");
        else
            invalid = invalid || pattern.contains ("@") || pattern.has_prefix (".") || pattern.has_suffix (".");
        if (invalid) throw new MailError.INVALID_ACCOUNT (kind == JunkRuleKind.ADDRESS ?
            "Enter a complete sender email address" : "Enter a domain such as example.com");
        return pattern;
    }
}
}
