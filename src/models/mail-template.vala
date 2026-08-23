namespace Mailficient {
public class MailTemplate : Object {
    public int64 id { get; construct; }
    public string name { get; construct; }
    public string subject { get; construct; }
    public string body_text { get; construct; }
    public string body_html { get; construct; }
    public string body_format { get; construct; }
    public MailTemplate (int64 id, string name, string subject, string body_text,
                         string body_html = "", string body_format = "") {
        Object (id: id, name: name, subject: subject, body_text: body_text,
            body_html: body_html, body_format: body_format);
    }
}
}
