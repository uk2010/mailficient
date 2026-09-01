namespace Mailficient {
public enum MailRuleField {
    SENDER,
    RECIPIENT,
    SUBJECT,
    BODY,
    HAS_ATTACHMENT,
    IS_UNREAD,
    IS_FLAGGED,
    CC,
    BCC,
    ATTACHMENT_NAME,
    MESSAGE_SIZE,
    MAILBOX,
    REPLY_TO,
    DATE_RECEIVED,
    LABEL,
    SECURITY_STATUS,
    MAILING_LIST,
    RAW_HEADERS
}

public enum MailRuleOperator {
    CONTAINS,
    DOES_NOT_CONTAIN,
    EQUALS,
    STARTS_WITH,
    ENDS_WITH,
    GREATER_THAN,
    LESS_THAN,
    AFTER,
    BEFORE
}

public enum MailRuleMatchMode { ALL, ANY }

public enum MailRuleAction {
    MARK_READ,
    FLAG,
    ARCHIVE,
    TRASH,
    LABEL,
    MARK_UNREAD,
    UNFLAG,
    MOVE,
    COPY,
    SET_FLAG_COLOR,
    MARK_JUNK,
    MARK_NOT_JUNK,
    REMOVE_LABEL
}

public class MailRuleCondition : Object {
    public MailRuleField field { get; construct; }
    public MailRuleOperator operator { get; construct; }
    public string pattern { get; construct; }

    public MailRuleCondition (MailRuleField field, string pattern,
                              MailRuleOperator operator = MailRuleOperator.CONTAINS) {
        Object (field: field, pattern: pattern.strip (), operator: operator);
    }

    public bool matches (Message message) {
        if (field == MailRuleField.HAS_ATTACHMENT)
            return compare_bool (message.has_attachment, pattern, operator, "attachment");
        if (field == MailRuleField.IS_UNREAD)
            return compare_bool (message.unread, pattern, operator, "unread");
        if (field == MailRuleField.IS_FLAGGED)
            return compare_bool (message.flagged, pattern, operator, "flagged");
        if (field == MailRuleField.MESSAGE_SIZE) {
            int64? parsed = parse_size (pattern);
            if (parsed == null) return false;
            int64 expected = (int64) parsed;
            switch (operator) {
            case MailRuleOperator.GREATER_THAN: return message.message_size > expected;
            case MailRuleOperator.LESS_THAN: return message.message_size < expected;
            default: return message.message_size == expected;
            }
        }
        if (field == MailRuleField.DATE_RECEIVED) {
            var expected = parse_date (pattern);
            if (expected == null || message.date_unix <= 0) return false;
            int64 start = expected.to_unix ();
            int64 end = expected.add_days (1).to_unix ();
            switch (operator) {
            case MailRuleOperator.BEFORE: return message.date_unix < start;
            case MailRuleOperator.AFTER: return message.date_unix >= end;
            default: return message.date_unix >= start && message.date_unix < end;
            }
        }

        string haystack;
        switch (field) {
        case MailRuleField.RECIPIENT: haystack = message.recipients + " " + message.cc_recipients + " " + message.bcc_recipients; break;
        case MailRuleField.CC: haystack = message.cc_recipients; break;
        case MailRuleField.BCC: haystack = message.bcc_recipients; break;
        case MailRuleField.SUBJECT: haystack = message.subject; break;
        case MailRuleField.BODY: haystack = message.body + " " + message.preview; break;
        case MailRuleField.MAILBOX: haystack = message.mailbox_id; break;
        case MailRuleField.REPLY_TO: haystack = message.reply_to; break;
        case MailRuleField.LABEL:
            var labels = new StringBuilder ();
            foreach (var label in message.labels) labels.append (label.name + " ");
            haystack = labels.str;
            break;
        case MailRuleField.SECURITY_STATUS:
            // Authentication-Results is an untrusted message header until it
            // is tied to the configured receiving server. Rules must never
            // treat an attacker-supplied header as a verified security state.
            haystack = message.security_status;
            break;
        case MailRuleField.MAILING_LIST:
            haystack = message.list_unsubscribe + " " + message.list_unsubscribe_post +
                " " + message.raw_headers;
            break;
        case MailRuleField.RAW_HEADERS: haystack = message.raw_headers; break;
        case MailRuleField.ATTACHMENT_NAME:
            var names = new StringBuilder ();
            foreach (var attachment in message.attachments) names.append (attachment.name + " ");
            haystack = names.str;
            break;
        default: haystack = message.sender_name + " " + message.sender_address; break;
        }
        return compare_text (haystack, pattern, operator);
    }

    private static bool compare_bool (bool actual, string value,
                                      MailRuleOperator operator, string positive) {
        bool expected = matches_bool (value, positive);
        bool equal = actual == expected;
        return operator == MailRuleOperator.DOES_NOT_CONTAIN ? !equal : equal;
    }

    private static bool compare_text (string haystack, string needle,
                                      MailRuleOperator operator) {
        string actual = haystack.down ().strip (); string expected = needle.down ().strip ();
        switch (operator) {
        case MailRuleOperator.DOES_NOT_CONTAIN: return !actual.contains (expected);
        case MailRuleOperator.EQUALS: return actual == expected;
        case MailRuleOperator.STARTS_WITH: return actual.has_prefix (expected);
        case MailRuleOperator.ENDS_WITH: return actual.has_suffix (expected);
        default: return actual.contains (expected);
        }
    }

    private static bool matches_bool (string value, string positive) {
        var normalized = value.strip ().down ();
        return normalized == "1" || normalized == "true" || normalized == "yes" || normalized == positive;
    }

    private static int64? parse_size (string value) {
        string lower = value.strip ().down (); double multiplier = 1;
        if (lower.has_suffix ("kb")) {
            multiplier = 1024; lower = lower.substring (0, lower.length - 2);
        } else if (lower.has_suffix ("mb")) {
            multiplier = 1024 * 1024; lower = lower.substring (0, lower.length - 2);
        } else if (lower.has_suffix ("gb")) {
            multiplier = 1024.0 * 1024.0 * 1024.0;
            lower = lower.substring (0, lower.length - 2);
        } else if (lower.has_suffix ("b")) {
            lower = lower.substring (0, lower.length - 1);
        }
        double amount = 0;
        if (!double.try_parse (lower.strip (), out amount) || amount < 0) return null;
        double bytes = amount * multiplier;
        if (bytes > int64.MAX) return null;
        return (int64) bytes;
    }

    private static DateTime? parse_date (string value) {
        string clean = value.strip ();
        if (!Regex.match_simple ("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", clean)) return null;
        return new DateTime.from_iso8601 (
            clean + "T00:00:00", new TimeZone.local ());
    }
}

public class MailRuleOperation : Object {
    public MailRuleAction action { get; construct; }
    public string value { get; construct; }

    public MailRuleOperation (MailRuleAction action, string value = "") {
        Object (action: action, value: value.strip ());
    }
}

public class MailRule : Object {
    public int64 id { get; construct; }
    public string name { get; construct; }
    public string account_id { get; construct; }
    // Legacy fields remain available to old callers and migration code. New
    // rules use the ordered condition/action collections below.
    public MailRuleField field { get; construct; }
    public string pattern { get; construct; }
    public MailRuleAction action { get; construct; }
    public string value { get; construct; }
    public bool enabled { get; set; }
    public int position { get; set; }
    public MailRuleMatchMode match_mode { get; set; default = MailRuleMatchMode.ALL; }
    public bool stop_processing { get; set; }
    public Gee.ArrayList<MailRuleCondition> conditions { get; private set; default = new Gee.ArrayList<MailRuleCondition> (); }
    public Gee.ArrayList<MailRuleCondition> exceptions { get; private set; default = new Gee.ArrayList<MailRuleCondition> (); }
    public Gee.ArrayList<MailRuleOperation> operations { get; private set; default = new Gee.ArrayList<MailRuleOperation> (); }

    public MailRule (int64 id, string name, string account_id, MailRuleField field,
                     string pattern, MailRuleAction action, string value = "", bool enabled = true,
                     int position = 0, MailRuleMatchMode match_mode = MailRuleMatchMode.ALL,
                     bool stop_processing = false) {
        Object (id: id, name: name, account_id: account_id, field: field,
            pattern: pattern, action: action, value: value, enabled: enabled,
            position: position, match_mode: match_mode, stop_processing: stop_processing);
        conditions.add (new MailRuleCondition (field, pattern));
        operations.add (new MailRuleOperation (action, value));
    }

    public void replace_legacy_parts () {
        conditions.clear (); exceptions.clear (); operations.clear ();
    }

    public bool matches (Message message, bool ignore_enabled = false) {
        if ((!enabled && !ignore_enabled) ||
            (account_id != "" && account_id != message.account_id) || conditions.size == 0)
            return false;
        bool condition_match = match_mode == MailRuleMatchMode.ALL;
        foreach (var condition in conditions) {
            bool matched = condition.matches (message);
            if (match_mode == MailRuleMatchMode.ALL && !matched) { condition_match = false; break; }
            if (match_mode == MailRuleMatchMode.ANY && matched) { condition_match = true; break; }
        }
        if (!condition_match) return false;
        foreach (var exception in exceptions) if (exception.matches (message)) return false;
        return true;
    }
}

public class QuickStep : Object {
    public int64 id { get; construct; }
    public string name { get; construct; }
    public string account_id { get; construct; }
    public int position { get; set; }
    public Gee.ArrayList<MailRuleOperation> operations { get; private set; default = new Gee.ArrayList<MailRuleOperation> (); }

    public QuickStep (int64 id, string name, string account_id = "", int position = 0) {
        Object (id: id, name: name, account_id: account_id, position: position);
    }
}
}
