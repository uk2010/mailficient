namespace Mailficient {
public enum MessageThreatLevel {
    NONE,
    NOTICE,
    CAUTION,
    DANGER
}

public class MessageSecurityAssessment : Object {
    public MessageThreatLevel level { get; set; default = MessageThreatLevel.NONE; }
    public string title { get; set; default = "No obvious warning signs"; }
    public bool sender_is_safe { get; construct; }
    public bool authentication_reported { get; set; }
    public Gee.ArrayList<string> findings { get; private set; default = new Gee.ArrayList<string> (); }

    public MessageSecurityAssessment (bool sender_is_safe = false) {
        Object (sender_is_safe: sender_is_safe);
    }

    public void add (MessageThreatLevel finding_level, string finding) {
        if (finding.strip () == "" || findings.contains (finding)) return;
        findings.add (finding);
        if (finding_level > level) level = finding_level;
    }
}

public class UnsubscribeTarget : Object {
    public string uri { get; construct; }
    public string label { get; construct; }
    public bool is_email { get; construct; }
    public bool supports_one_click { get; construct; }

    public UnsubscribeTarget (string uri, string label, bool is_email,
                              bool supports_one_click = false) {
        Object (uri: uri, label: label, is_email: is_email,
            supports_one_click: supports_one_click);
    }
}
}
