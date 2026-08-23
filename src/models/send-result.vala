namespace Mailficient {
public class SendResult : Object {
    public bool filed_to_sent { get; construct; }
    public string filing_warning { get; construct; }

    public SendResult (bool filed_to_sent = true, string filing_warning = "") {
        Object (filed_to_sent: filed_to_sent, filing_warning: filing_warning);
    }
}
}
