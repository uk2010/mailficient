namespace Mailficient {
public class CalendarEvent : Object {
    public int64 id { get; construct; }
    public string title { get; construct; }
    public string starts_at { get; construct; }
    public string ends_at { get; construct; }
    public string location { get; construct; }
    public string notes { get; construct; }

    public CalendarEvent (int64 id, string title, string starts_at, string ends_at,
                          string location = "", string notes = "") {
        Object (id: id, title: title, starts_at: starts_at, ends_at: ends_at,
                location: location, notes: notes);
    }
}
}
