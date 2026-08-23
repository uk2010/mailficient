namespace Mailficient {
public class ReplyRecipients : Object {
    public string to { get; construct; }
    public string cc { get; construct; }

    public ReplyRecipients (string to, string cc) {
        Object (to: to, cc: cc);
    }
}
}
