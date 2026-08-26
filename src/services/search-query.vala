namespace Mailficient {
public enum SearchField {
    ANY,
    SENDER,
    RECIPIENT,
    CC,
    BCC,
    SUBJECT,
    MAILBOX,
    ACCOUNT,
    LABEL,
    UNREAD,
    FLAGGED,
    HAS_ATTACHMENT,
    ATTACHMENT_NAME,
    ATTACHMENT_TYPE,
    AFTER,
    BEFORE,
    DATE_RANGE,
    MESSAGE_SIZE
}

public enum SearchComparison { CONTAINS, EQUALS, GREATER_THAN, LESS_THAN }

public class SearchTerm : Object {
    public SearchField field { get; construct; }
    public string value { get; construct; }
    public bool negated { get; construct; }
    public bool exact { get; construct; }
    public SearchComparison comparison { get; construct; }

    public SearchTerm (SearchField field, string value, bool negated = false,
                       bool exact = false,
                       SearchComparison comparison = SearchComparison.CONTAINS) {
        Object (field: field, value: value, negated: negated, exact: exact,
            comparison: comparison);
    }
}

public class SearchClause : Object {
    public Gee.ArrayList<SearchTerm> terms { get; private set; default = new Gee.ArrayList<SearchTerm> (); }
}

private class SearchToken : Object {
    public string value;
    public bool exact;
    public SearchToken (string value, bool exact) { this.value = value; this.exact = exact; }
}

public class SearchQuery : Object {
    public string text { get; set; default = ""; }
    public string? sender { get; set; }
    public string? recipient { get; set; }
    public string? cc { get; set; }
    public string? bcc { get; set; }
    public string? subject { get; set; }
    public string? mailbox { get; set; }
    public string? account { get; set; }
    public string? label { get; set; }
    public string? attachment_name { get; set; }
    public string? attachment_type { get; set; }
    public bool? unread;
    public bool? flagged;
    public bool? has_attachment;
    public int64? after_unix;
    public int64? before_unix;
    public int64? minimum_size;
    public int64? maximum_size;
    public Gee.ArrayList<SearchClause> clauses { get; private set; default = new Gee.ArrayList<SearchClause> (); }

    public void append_text (string value) {
        var clean = value.strip ();
        if (clean == "") return;
        text = text == "" ? clean : text + " " + clean;
    }

    public static SearchQuery parse (string input) {
        var query = new SearchQuery (); var clause = new SearchClause (); query.clauses.add (clause);
        var plain = new StringBuilder (); bool uses_or = false;
        foreach (var token_info in tokenize (input)) {
            string raw = token_info.value.strip ();
            if (raw == "") continue;
            if (!token_info.exact && raw == "OR") {
                if (clause.terms.size == 0) continue;
                clause = new SearchClause (); query.clauses.add (clause); uses_or = true; continue;
            }
            bool negated = raw.has_prefix ("-") && raw.length > 1;
            string token = negated ? raw.substring (1) : raw;
            var term = parse_term (query, token, negated, token_info.exact, plain);
            if (term != null) clause.terms.add (term);
        }
        while (query.clauses.size > 0 && query.clauses[query.clauses.size - 1].terms.size == 0)
            query.clauses.remove_at (query.clauses.size - 1);
        query.text = plain.str;
        // Legacy scalar properties cannot represent disjunction. Clauses stay
        // authoritative while these are cleared, avoiding an accidental AND.
        if (uses_or) query.clear_legacy_filters ();
        return query;
    }

    private void clear_legacy_filters () {
        text = ""; sender = null; recipient = null; cc = null; bcc = null; subject = null;
        mailbox = null; account = null; label = null; attachment_name = null; attachment_type = null;
        unread = null; flagged = null; has_attachment = null; after_unix = null; before_unix = null;
        minimum_size = null; maximum_size = null;
    }

    private static SearchTerm? parse_term (SearchQuery query, string token, bool negated,
                                           bool exact, StringBuilder plain) {
        int colon = token.index_of (":");
        string scope = colon > 0 ? token.substring (0, colon).down () : "";
        string value = colon > 0 ? token.substring (colon + 1).strip () : token;
        if (value == "") { append_plain (plain, (negated ? "-" : "") + token); return null; }
        switch (scope) {
        case "from": query.sender = value; return new SearchTerm (SearchField.SENDER, value, negated, exact);
        case "to": query.recipient = value; return new SearchTerm (SearchField.RECIPIENT, value, negated, exact);
        case "cc": query.cc = value; return new SearchTerm (SearchField.CC, value, negated, exact);
        case "bcc": query.bcc = value; return new SearchTerm (SearchField.BCC, value, negated, exact);
        case "subject": query.subject = value; return new SearchTerm (SearchField.SUBJECT, value, negated, exact);
        case "mailbox": case "folder": case "in":
            // These scalar hints are used only to reduce the folders contacted
            // by server search. A negative scope must not become a positive
            // folder restriction before the full query is evaluated locally.
            if (!negated) query.mailbox = value;
            return new SearchTerm (SearchField.MAILBOX, value, negated, exact, SearchComparison.EQUALS);
        case "account":
            if (!negated) query.account = value;
            return new SearchTerm (SearchField.ACCOUNT, value, negated, exact);
        case "label": query.label = value; return new SearchTerm (SearchField.LABEL, value, negated, exact, SearchComparison.EQUALS);
        case "attachment": case "filename":
            query.attachment_name = value; return new SearchTerm (SearchField.ATTACHMENT_NAME, value, negated, exact);
        case "type": case "attachment-type":
            query.attachment_type = value; return new SearchTerm (SearchField.ATTACHMENT_TYPE, value, negated, exact);
        case "is":
            if (value == "unread" || value == "read") {
                bool expected = value == "unread"; query.unread = negated ? !expected : expected;
                return new SearchTerm (SearchField.UNREAD, expected ? "1" : "0", negated);
            }
            if (value == "flagged" || value == "unflagged") {
                bool expected = value == "flagged"; query.flagged = negated ? !expected : expected;
                return new SearchTerm (SearchField.FLAGGED, expected ? "1" : "0", negated);
            }
            break;
        case "has":
            if (value == "attachment" || value == "no-attachment") {
                bool expected = value == "attachment"; query.has_attachment = negated ? !expected : expected;
                return new SearchTerm (SearchField.HAS_ATTACHMENT, expected ? "1" : "0", negated);
            }
            break;
        case "after": {
            var start = parse_day (value);
            if (start != null) { query.after_unix = start; return new SearchTerm (SearchField.AFTER, ((int64) start).to_string (), negated); }
            break;
        }
        case "before": {
            var start = parse_day (value);
            if (start != null) { query.before_unix = start; return new SearchTerm (SearchField.BEFORE, ((int64) start).to_string (), negated); }
            break;
        }
        case "date": {
            var start = parse_day (value);
            if (start != null) {
                int64 end = new DateTime.from_unix_local ((int64) start).add_days (1).to_unix ();
                query.after_unix = start; query.before_unix = end;
                // Keep the two bounds in one term. In particular, `-date:`
                // means NOT (after start AND before end); negating two
                // independent bounds would make the query impossible.
                return new SearchTerm (SearchField.DATE_RANGE,
                    "%s:%s".printf (((int64) start).to_string (), end.to_string ()),
                    negated);
            }
            break;
        }
        case "size": {
            SearchComparison comparison = SearchComparison.EQUALS; string amount = value;
            if (amount.has_prefix (">")) { comparison = SearchComparison.GREATER_THAN; amount = amount.substring (1); }
            else if (amount.has_prefix ("<")) { comparison = SearchComparison.LESS_THAN; amount = amount.substring (1); }
            int64? bytes = parse_size (amount);
            if (bytes != null) {
                if (comparison == SearchComparison.GREATER_THAN) query.minimum_size = bytes;
                else if (comparison == SearchComparison.LESS_THAN) query.maximum_size = bytes;
                return new SearchTerm (SearchField.MESSAGE_SIZE, ((int64) bytes).to_string (), negated, false, comparison);
            }
            break;
        }
        default:
            if (scope == "") {
                append_plain (plain, token);
                return new SearchTerm (SearchField.ANY, token, negated, exact);
            }
            break;
        }
        string original = (negated ? "-" : "") + token; append_plain (plain, original);
        return new SearchTerm (SearchField.ANY, original, false, exact);
    }

    private static Gee.ArrayList<SearchToken> tokenize (string input) {
        var result = new Gee.ArrayList<SearchToken> (); var current = new StringBuilder ();
        bool quoted = false; bool exact = false; bool escaped = false;
        for (int index = 0; index < input.length; index++) {
            char character = input[index];
            if (escaped) { current.append_c (character); escaped = false; continue; }
            if (character == '\\' && quoted) { escaped = true; continue; }
            if (character == '"') { quoted = !quoted; exact = true; continue; }
            if ((character == ' ' || character == '\t' || character == '\n') && !quoted) {
                if (current.len > 0) { result.add (new SearchToken (current.str, exact)); current = new StringBuilder (); exact = false; }
            } else current.append_c (character);
        }
        if (escaped) current.append_c ('\\');
        if (current.len > 0) result.add (new SearchToken (current.str, exact));
        return result;
    }

    private static int64? parse_day (string value) {
        if (value.length != 10) return null;
        var zone = new TimeZone.local ();
        var parsed = new DateTime.from_iso8601 (value + "T00:00:00", zone);
        if (parsed == null || parsed.format ("%F") != value) return null;
        return parsed.to_unix ();
    }

    private static int64? parse_size (string value) {
        string lower = value.strip ().down (); double multiplier = 1;
        if (lower.has_suffix ("kb")) { multiplier = 1024; lower = lower.substring (0, lower.length - 2); }
        else if (lower.has_suffix ("mb")) { multiplier = 1024 * 1024; lower = lower.substring (0, lower.length - 2); }
        else if (lower.has_suffix ("gb")) { multiplier = 1024.0 * 1024.0 * 1024.0; lower = lower.substring (0, lower.length - 2); }
        else if (lower.has_suffix ("b")) lower = lower.substring (0, lower.length - 1);
        double amount = 0; if (!double.try_parse (lower, out amount) || amount < 0) return null;
        double bytes = amount * multiplier;
        if (bytes > int64.MAX) return null;
        return (int64) bytes;
    }

    private static void append_plain (StringBuilder plain, string token) {
        if (plain.len > 0) plain.append_c (' ');
        plain.append (token);
    }
}
}
