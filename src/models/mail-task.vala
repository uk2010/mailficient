namespace Mailficient {
public enum TaskRecurrence {
    NONE,
    DAILY,
    WEEKLY,
    MONTHLY,
    YEARLY;

    public string label () {
        switch (this) {
        case DAILY: return "Daily";
        case WEEKLY: return "Weekly";
        case MONTHLY: return "Monthly";
        case YEARLY: return "Yearly";
        default: return "Does not repeat";
        }
    }
}

public enum TaskViewMode { TODAY, PLANNED }

public class MailTask : Object {
    public int64 id { get; construct; }
    public string title { get; construct; }
    public string due_at { get; construct; }
    public bool completed { get; set; }
    public string notes { get; construct; }
    public string message_id { get; construct; }
    public int64 reminder_at { get; construct; }
    public TaskRecurrence recurrence { get; construct; }
    public int recurrence_interval { get; construct; }
    public int64 created_at { get; construct; }
    public int64 completed_at { get; construct; }
    public int64 reminder_sent_at { get; construct; }

    public MailTask (int64 id, string title, string due_at, bool completed = false,
                     string notes = "", string message_id = "", int64 reminder_at = 0,
                     TaskRecurrence recurrence = TaskRecurrence.NONE,
                     int recurrence_interval = 1, int64 created_at = 0,
                     int64 completed_at = 0, int64 reminder_sent_at = 0) {
        Object (id: id, title: title, due_at: due_at, completed: completed,
                notes: notes, message_id: message_id, reminder_at: reminder_at,
                recurrence: recurrence, recurrence_interval: int.max (1, recurrence_interval),
                created_at: created_at, completed_at: completed_at,
                reminder_sent_at: reminder_sent_at);
    }

    public bool is_linked_to_message () { return message_id.strip () != ""; }

    public bool due_on_or_before (string iso_date) {
        return due_at.length == 10 && due_at <= iso_date;
    }

    public static string date_for_unix (int64 unix_time) {
        var date = new DateTime.from_unix_local (unix_time);
        return date.format ("%F");
    }

    public static DateTime? parse_due_date (string value) {
        string clean = value.strip ();
        if (clean.length != 10 || clean[4] != '-' || clean[7] != '-') return null;
        return new DateTime.from_iso8601 (clean + "T00:00:00", new TimeZone.local ());
    }

    public static string? normalized_due_date (string value) {
        var parsed = parse_due_date (value);
        return parsed == null ? null : parsed.format ("%F");
    }

    public string next_due_date () {
        var due = parse_due_date (due_at);
        if (due == null || recurrence == TaskRecurrence.NONE) return due_at;
        DateTime next;
        switch (recurrence) {
        case DAILY: next = due.add_days (recurrence_interval); break;
        case WEEKLY: next = due.add_weeks (recurrence_interval); break;
        case MONTHLY: next = due.add_months (recurrence_interval); break;
        case YEARLY: next = due.add_years (recurrence_interval); break;
        default: next = due; break;
        }
        return next.format ("%F");
    }

    public string recurrence_label () {
        if (recurrence == TaskRecurrence.NONE) return recurrence.label ();
        if (recurrence_interval == 1) return recurrence.label ();
        string unit;
        switch (recurrence) {
        case DAILY: unit = "days"; break;
        case WEEKLY: unit = "weeks"; break;
        case MONTHLY: unit = "months"; break;
        case YEARLY: unit = "years"; break;
        default: unit = "occurrences"; break;
        }
        return "Every %d %s".printf (recurrence_interval, unit);
    }
}
}
