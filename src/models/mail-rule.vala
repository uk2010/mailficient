namespace Mailficient {
public enum MailRuleField { SENDER, RECIPIENT, SUBJECT }
public enum MailRuleAction { MARK_READ, FLAG, ARCHIVE, TRASH, LABEL }

public class MailRule : Object {
    public int64 id { get; construct; }
    public string name { get; construct; }
    public string account_id { get; construct; }
    public MailRuleField field { get; construct; }
    public string pattern { get; construct; }
    public MailRuleAction action { get; construct; }
    public string value { get; construct; }
    public bool enabled { get; construct; }

    public MailRule (int64 id, string name, string account_id, MailRuleField field,
                     string pattern, MailRuleAction action, string value = "", bool enabled = true) {
        Object (id: id, name: name, account_id: account_id, field: field,
            pattern: pattern, action: action, value: value, enabled: enabled);
    }
    public bool matches (Message message) {
        if (!enabled || (account_id != "" && account_id != message.account_id)) return false;
        string haystack;
        switch (field) {
        case MailRuleField.RECIPIENT: haystack = message.recipients + " " + message.cc_recipients; break;
        case MailRuleField.SUBJECT: haystack = message.subject; break;
        default: haystack = message.sender_name + " " + message.sender_address; break;
        }
        return haystack.down ().contains (pattern.down ());
    }
}
}
