namespace Mailficient {
public class MailTask : Object {
    public int64 id { get; construct; }
    public string title { get; construct; }
    public string due_at { get; construct; }
    public bool completed { get; set; }
    public string notes { get; construct; }
    public string message_id { get; construct; }

    public MailTask (int64 id, string title, string due_at, bool completed = false,
                     string notes = "", string message_id = "") {
        Object (id: id, title: title, due_at: due_at, completed: completed,
                notes: notes, message_id: message_id);
    }
}
}
