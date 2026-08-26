namespace Mailficient {
public class MessageSecurityService : Object {
    public const int MAX_RAW_HEADER_BYTES = 64 * 1024;
    private const int MAX_UNSUBSCRIBE_URI_BYTES = 2048;

    public MessageSecurityAssessment assess (Message message, bool sender_is_safe = false) {
        var assessment = new MessageSecurityAssessment (sender_is_safe);
        string sender_domain = address_domain (message.sender_address);
        string reply_domain = address_domain (message.reply_to);
        string display_domain = display_name_domain (message.sender_name);
        string auth = unfold (message.authentication_results).down ();

        if (auth != "") {
            assessment.authentication_reported = true;
            if (has_auth_result (auth, "dmarc", "fail"))
                assessment.add (MessageThreatLevel.DANGER,
                    "Your mail server reports that DMARC authentication failed.");
            if (has_auth_result (auth, "spf", "fail") || has_auth_result (auth, "spf", "softfail"))
                assessment.add (MessageThreatLevel.CAUTION,
                    "Your mail server reports that SPF did not pass.");
            if (has_auth_result (auth, "dkim", "fail"))
                assessment.add (MessageThreatLevel.CAUTION,
                    "Your mail server reports that the DKIM signature failed.");
            if (!auth_failure (auth) && (has_auth_result (auth, "dmarc", "pass") ||
                has_auth_result (auth, "spf", "pass") || has_auth_result (auth, "dkim", "pass")))
                assessment.add (MessageThreatLevel.NOTICE,
                    "Your mail server reports at least one passing authentication check.");
        }

        if (sender_domain.has_prefix ("xn--") || sender_domain.contains (".xn--"))
            assessment.add (MessageThreatLevel.CAUTION,
                "The sender uses an internationalized (punycode) domain. Check it carefully.");

        if (reply_domain != "" && sender_domain != "" && !domains_related (reply_domain, sender_domain)) {
            var mismatch_level = (!sender_is_safe || auth_failure (auth)) ?
                MessageThreatLevel.CAUTION : MessageThreatLevel.NOTICE;
            assessment.add (mismatch_level,
                "Replies go to %s, not the sender domain %s.".printf (reply_domain, sender_domain));
        }

        if (display_domain != "" && sender_domain != "" && !domains_related (display_domain, sender_domain))
            assessment.add (sender_is_safe ? MessageThreatLevel.NOTICE : MessageThreatLevel.CAUTION,
                "The displayed sender name mentions %s, but the address uses %s.".printf (
                    display_domain, sender_domain));

        // Safe Senders is an identity preference, not a trust decision for a
        // message's links. A familiar address can still be compromised, so a
        // misleading link destination must always remain visible.
        foreach (var mismatch in suspicious_link_domains (message.body_html))
            assessment.add (MessageThreatLevel.CAUTION, mismatch);

        if (sender_is_safe && assessment.level <= MessageThreatLevel.NOTICE)
            assessment.title = "Sender is on your Safe Senders list";
        else {
            switch (assessment.level) {
            case MessageThreatLevel.DANGER: assessment.title = "Authentication failed — use caution"; break;
            case MessageThreatLevel.CAUTION: assessment.title = "Check this message before acting"; break;
            case MessageThreatLevel.NOTICE: assessment.title = "Sender and authentication details"; break;
            default: assessment.title = "No obvious warning signs"; break;
            }
        }
        return assessment;
    }

    public Gee.ArrayList<UnsubscribeTarget> unsubscribe_targets (Message message) {
        var result = new Gee.ArrayList<UnsubscribeTarget> ();
        string header = unfold (message.list_unsubscribe);
        if (header == "") return result;
        bool one_click = unfold (message.list_unsubscribe_post).down ().contains (
            "list-unsubscribe=one-click");
        try {
            var angle_target = new Regex ("<([^>]+)>");
            MatchInfo matches;
            if (angle_target.match (header, 0, out matches)) {
                do { add_unsubscribe_target (result, matches.fetch (1), one_click); }
                while (matches.next ());
            }
        } catch (RegexError error) {
            warning ("Could not parse List-Unsubscribe: %s", error.message);
        }
        if (result.size == 0)
            foreach (var part in header.split (",")) add_unsubscribe_target (result, part, one_click);
        return result;
    }

    public static string bounded_raw_headers (string input) {
        if (input.length <= MAX_RAW_HEADER_BYTES) return input;
        int boundary = MAX_RAW_HEADER_BYTES;
        while (boundary > 0 && ((((uint8) input[boundary]) & 0xc0) == 0x80)) boundary--;
        return input.substring (0, boundary) + "\n… headers truncated by Mailficient …";
    }

    public static string headers_for_display (Message message) {
        if (message.raw_headers.strip () != "") return bounded_raw_headers (message.raw_headers);
        var fallback = new StringBuilder ();
        append_header (fallback, "From", "%s <%s>".printf (message.sender_name, message.sender_address));
        append_header (fallback, "To", message.recipients);
        append_header (fallback, "Cc", message.cc_recipients);
        append_header (fallback, "Reply-To", message.reply_to);
        append_header (fallback, "Subject", message.subject);
        append_header (fallback, "Message-ID", message.internet_message_id);
        append_header (fallback, "Authentication-Results", message.authentication_results);
        append_header (fallback, "List-Unsubscribe", message.list_unsubscribe);
        append_header (fallback, "List-Unsubscribe-Post", message.list_unsubscribe_post);
        return fallback.str;
    }

    public static string normalize_sender (string address) {
        return address.strip ().down ();
    }

    public static string sanitize_unsubscribe_subject (string candidate) {
        const int MAX_SUBJECT_BYTES = 255;
        string clean = candidate.strip ();
        if (clean == "" || has_control (clean)) return "Unsubscribe";
        if (clean.length <= MAX_SUBJECT_BYTES) return clean;
        int boundary = MAX_SUBJECT_BYTES;
        while (boundary > 0 && ((((uint8) clean[boundary]) & 0xc0) == 0x80)) boundary--;
        clean = clean.substring (0, boundary).strip ();
        return clean == "" ? "Unsubscribe" : clean;
    }

    private static void append_header (StringBuilder builder, string name, string value) {
        string clean = unfold (value).strip ();
        if (clean == "") return;
        builder.append_printf ("%s: %s\n", name, clean);
    }

    private static void add_unsubscribe_target (Gee.ArrayList<UnsubscribeTarget> result,
                                                string candidate, bool one_click) {
        string uri = candidate.strip ();
        if (uri.has_prefix ("<") && uri.has_suffix (">") && uri.length > 2)
            uri = uri.substring (1, uri.length - 2).strip ();
        if (uri == "" || uri.length > MAX_UNSUBSCRIBE_URI_BYTES || has_control (uri)) return;
        string lower = uri.down ();
        bool email = lower.has_prefix ("mailto:");
        bool web = lower.has_prefix ("https://");
        if (!email && !web) return;
        foreach (var existing in result) if (existing.uri.down () == lower) return;
        string label = email ? "Email the list owner" : "Open the subscription page";
        result.add (new UnsubscribeTarget (uri, label, email, web && one_click));
    }

    private static bool has_control (string value) {
        for (int index = 0; index < value.length;) {
            unichar current = value.get_char (index);
            if (current.iscntrl () || current == 0x2028 || current == 0x2029) return true;
            index += current.to_utf8 (null);
        }
        return false;
    }

    private static bool auth_failure (string auth) {
        return has_auth_result (auth, "dmarc", "fail") ||
            has_auth_result (auth, "spf", "fail") || has_auth_result (auth, "spf", "softfail") ||
            has_auth_result (auth, "dkim", "fail");
    }

    private static bool has_auth_result (string auth, string mechanism, string result) {
        try {
            var expression = new Regex ("(?:^|[;\\s])" + Regex.escape_string (mechanism) +
                "\\s*=\\s*" + Regex.escape_string (result) + "(?:[;\\s(]|$)",
                RegexCompileFlags.CASELESS);
            return expression.match (auth);
        } catch (RegexError error) { return false; }
    }

    private static string unfold (string value) {
        return value.replace ("\r\n", "\n").replace ("\n\t", " ").replace ("\n ", " ")
            .replace ("\r", " ").replace ("\n", " ");
    }

    private static string address_domain (string address) {
        string clean = address.strip ().down ();
        int open = clean.last_index_of ("<");
        int close = clean.last_index_of (">");
        if (open >= 0 && close > open) clean = clean.substring (open + 1, close - open - 1);
        int at = clean.last_index_of ("@");
        if (at < 0 || at + 1 >= clean.length) return "";
        string domain = clean.substring (at + 1).strip ();
        while (domain.has_suffix (".") || domain.has_suffix (">") || domain.has_suffix (",") || domain.has_suffix (";"))
            domain = domain.substring (0, domain.length - 1);
        return domain;
    }

    private static string display_name_domain (string display_name) {
        string lower = display_name.strip ().down ();
        try {
            var domain = new Regex ("(?:^|[^a-z0-9-])((?:xn--)?[a-z0-9][a-z0-9-]*(?:\\.[a-z0-9][a-z0-9-]*)+)(?:$|[^a-z0-9-])");
            MatchInfo match;
            if (domain.match (lower, 0, out match)) return match.fetch (1);
        } catch (RegexError error) { }
        return "";
    }

    private static bool domains_related (string first, string second) {
        string a = first.down (); string b = second.down ();
        return a == b || a.has_suffix ("." + b) || b.has_suffix ("." + a);
    }

    private static Gee.ArrayList<string> suspicious_link_domains (string html) {
        var result = new Gee.ArrayList<string> ();
        if (html.strip () == "") return result;
        try {
            var link = new Regex ("<a\\s+[^>]*href\\s*=\\s*['\\\"]https://([^/'\\\"?#:]+)[^'\\\"]*['\\\"][^>]*>([^<]{1,160})</a>",
                RegexCompileFlags.CASELESS | RegexCompileFlags.DOTALL);
            MatchInfo matches;
            if (!link.match (html, 0, out matches)) return result;
            do {
                string destination = matches.fetch (1).down ();
                string label_domain = display_name_domain (matches.fetch (2));
                if (label_domain != "" && !domains_related (destination, label_domain))
                    result.add ("A link labeled %s opens %s instead.".printf (label_domain, destination));
            } while (matches.next () && result.size < 3);
        } catch (RegexError error) { }
        return result;
    }
}
}
