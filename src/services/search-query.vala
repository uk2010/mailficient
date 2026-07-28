namespace Mailficient {
public class SearchQuery : Object {
    public string text { get; private set; default = ""; }
    public string? sender { get; private set; }
    public string? recipient { get; private set; }
    public string? mailbox { get; private set; }
    public string? label { get; private set; }
    public bool? unread;
    public bool? flagged;
    public bool? has_attachment;
    public int64? after_unix;
    public int64? before_unix;

    public static SearchQuery parse (string input) {
        var query = new SearchQuery ();
        var plain = new StringBuilder ();
        foreach (var token in input.strip ().split (" ")) {
            if (token.has_prefix ("from:")) query.sender = token.substring (5);
            else if (token.has_prefix ("to:")) query.recipient = token.substring (3);
            else if (token.has_prefix ("mailbox:")) query.mailbox = token.substring (8);
            else if (token.has_prefix ("label:")) query.label = token.substring (6);
            else if (token == "is:unread") query.unread = true;
            else if (token == "is:read") query.unread = false;
            else if (token == "is:flagged") query.flagged = true;
            else if (token == "has:attachment") query.has_attachment = true;
            else if (token == "has:no-attachment") query.has_attachment = false;
            else if (token.has_prefix ("after:")) {
                var start = parse_day (token.substring (6));
                if (start != null) query.after_unix = start;
                else append_plain (plain, token);
            }
            else if (token.has_prefix ("before:")) {
                var start = parse_day (token.substring (7));
                if (start != null) query.before_unix = start;
                else append_plain (plain, token);
            }
            else if (token.has_prefix ("date:")) {
                var start = parse_day (token.substring (5));
                if (start != null) {
                    query.after_unix = start;
                    query.before_unix = new DateTime.from_unix_local ((int64) start).add_days (1).to_unix ();
                }
                else append_plain (plain, token);
            }
            else { if (plain.len > 0) plain.append_c (' '); plain.append (token); }
        }
        query.text = plain.str;
        return query;
    }

    private static int64? parse_day (string value) {
        if (value.length != 10) return null;
        var zone = new TimeZone.local ();
        var parsed = new DateTime.from_iso8601 (value + "T00:00:00", zone);
        if (parsed == null || parsed.format ("%F") != value) return null;
        return parsed.to_unix ();
    }

    private static void append_plain (StringBuilder plain, string token) {
        if (plain.len > 0) plain.append_c (' ');
        plain.append (token);
    }
}
}
