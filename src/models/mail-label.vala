namespace Mailficient {
public class MailLabel : Object {
    public int64 id { get; construct; }
    public string name { get; construct; }
    public string color { get; construct; }
    public MailLabel (int64 id, string name, string color = "#3584e4") {
        Object (id: id, name: name, color: color);
    }
}
}
