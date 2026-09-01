namespace Mailficient {
public errordomain CalendarError {
    INVALID_INVITATION,
    UNSUPPORTED,
    NO_CALENDAR,
    IDENTITY_NOT_INVITED,
    RESPONSE_FAILED,
    CREATE_FAILED
}

public enum CalendarInvitationMethod {
    REQUEST,
    CANCEL,
    PUBLISH,
    REPLY,
    UNKNOWN
}

public enum CalendarParticipation {
    NEEDS_ACTION,
    ACCEPTED,
    TENTATIVE,
    DECLINED,
    DELEGATED,
    UNKNOWN;

    public string label () {
        switch (this) {
        case ACCEPTED: return "Accepted";
        case TENTATIVE: return "Tentative";
        case DECLINED: return "Declined";
        case DELEGATED: return "Delegated";
        case NEEDS_ACTION: return "Needs response";
        default: return "Response unknown";
        }
    }
}

public class CalendarAttendee : Object {
    public string name { get; construct; }
    public string email { get; construct; }
    public bool response_requested { get; construct; }
    public CalendarParticipation participation { get; construct; }

    public CalendarAttendee (string name, string email, bool response_requested,
                             CalendarParticipation participation) {
        Object (name: name, email: email, response_requested: response_requested,
                participation: participation);
    }
}

// This is deliberately a compact display/action model rather than a second
// calendar database. The bounded original payload is retained only while the
// message is open so Evolution Data Server can process the complete iTIP item,
// including recurrence exceptions and embedded timezones that the summary UI
// does not need to reproduce.
public class CalendarInvitation : Object {
    public string uid { get; construct; }
    public CalendarInvitationMethod method { get; construct; }
    public string summary { get; construct; }
    public string description { get; construct; }
    public string location { get; construct; }
    public string organizer_name { get; construct; }
    public string organizer_email { get; construct; }
    public DateTime start { get; construct; }
    public DateTime? end { get; construct; }
    public bool all_day { get; construct; }
    public string timezone_label { get; construct; }
    public string recurrence_rule { get; construct; }
    public string status { get; construct; }
    public int sequence { get; construct; }
    public string raw_icalendar { get; construct; }
    public Gee.ArrayList<CalendarAttendee> attendees { get; private set;
        default = new Gee.ArrayList<CalendarAttendee> (); }

    public CalendarInvitation (string uid, CalendarInvitationMethod method,
                               string summary, string description, string location,
                               string organizer_name, string organizer_email,
                               DateTime start, DateTime? end, bool all_day,
                               string timezone_label, string recurrence_rule,
                               string status, int sequence, string raw_icalendar) {
        Object (uid: uid, method: method, summary: summary,
                description: description, location: location,
                organizer_name: organizer_name, organizer_email: organizer_email,
                start: start, end: end, all_day: all_day,
                timezone_label: timezone_label, recurrence_rule: recurrence_rule,
                status: status, sequence: sequence, raw_icalendar: raw_icalendar);
    }

    public bool can_respond () {
        return method == CalendarInvitationMethod.REQUEST && organizer_email != "";
    }

    public CalendarAttendee? attendee_for (string email) {
        string expected = normalize_email (email);
        foreach (var attendee in attendees)
            if (normalize_email (attendee.email) == expected) return attendee;
        return null;
    }

    public bool response_requested_for (string email) {
        var attendee = attendee_for (email);
        return attendee != null && attendee.response_requested;
    }

    public string organizer_display () {
        if (organizer_name != "" && organizer_email != "")
            return "%s <%s>".printf (organizer_name, organizer_email);
        return organizer_name != "" ? organizer_name : organizer_email;
    }

    public bool organizer_matches_sender (string sender_address) {
        return organizer_email != "" &&
            normalize_email (organizer_email) == normalize_email (sender_address);
    }

    public string formatted_when () {
        if (all_day) {
            if (end == null || end.compare (start.add_days (1)) <= 0)
                return start.format ("%A, %B %e, %Y").strip () + " · All day";
            // DATE-valued DTEND is exclusive under RFC 5545.
            var inclusive_end = end.add_days (-1);
            return "%s – %s · All day".printf (
                start.format ("%B %e, %Y").strip (),
                inclusive_end.format ("%B %e, %Y").strip ());
        }
        string first = start.to_local ().format ("%A, %B %e, %Y · %l:%M %p").strip ();
        if (end == null) return with_timezone (first);
        var local_start = start.to_local ();
        var local_end = end.to_local ();
        string tail = local_start.get_year () == local_end.get_year () &&
            local_start.get_day_of_year () == local_end.get_day_of_year () ?
            local_end.format ("%l:%M %p").strip () :
            local_end.format ("%B %e, %Y · %l:%M %p").strip ();
        return with_timezone ("%s – %s".printf (first, tail));
    }

    public string recurrence_summary () {
        if (recurrence_rule == "") return "";
        string frequency = ""; int interval = 1; string ending = "";
        foreach (var item in recurrence_rule.split (";")) {
            string[] pair = item.split ("=", 2);
            if (pair.length != 2) continue;
            switch (pair[0].up ()) {
            case "FREQ": frequency = pair[1].down (); break;
            case "INTERVAL": int.try_parse (pair[1], out interval, null, 10); break;
            case "COUNT": ending = " · %s occurrences".printf (pair[1]); break;
            case "UNTIL": ending = " · until %s".printf (compact_until (pair[1])); break;
            default: break;
            }
        }
        if (interval < 1) interval = 1;
        switch (frequency) {
        case "daily": return (interval == 1 ? "Repeats daily" :
            "Repeats every %d days".printf (interval)) + ending;
        case "weekly": return (interval == 1 ? "Repeats weekly" :
            "Repeats every %d weeks".printf (interval)) + ending;
        case "monthly": return (interval == 1 ? "Repeats monthly" :
            "Repeats every %d months".printf (interval)) + ending;
        case "yearly": return (interval == 1 ? "Repeats yearly" :
            "Repeats every %d years".printf (interval)) + ending;
        default: return "Recurring meeting";
        }
    }

    private string with_timezone (string value) {
        return timezone_label == "" ? value : "%s %s".printf (value, timezone_label);
    }

    private static string compact_until (string value) {
        if (value.length < 8) return value;
        return "%s-%s-%s".printf (value.substring (0, 4),
            value.substring (4, 2), value.substring (6, 2));
    }

    internal static string normalize_email (string value) {
        string normalized = value.strip ().down ();
        if (normalized.has_prefix ("mailto:")) normalized = normalized.substring (7);
        return normalized;
    }
}

public class CalendarMeetingDraft : Object {
    public string summary { get; set; }
    public string description { get; set; }
    public string organizer_email { get; set; }
    public string attendee_name { get; set; }
    public string attendee_email { get; set; }
    public DateTime start { get; set; }
    public DateTime end { get; set; }

    public CalendarMeetingDraft (string summary, string description,
                                 string organizer_email, string attendee_name,
                                 string attendee_email, DateTime start, DateTime end) {
        Object (summary: summary, description: description,
                organizer_email: organizer_email, attendee_name: attendee_name,
                attendee_email: attendee_email, start: start, end: end);
    }
}

// One expanded VEVENT occurrence from an Evolution Data Server calendar.
// Identity stays in EDS terms so edits and deletes never depend on the mail
// cache or on a synthetic local database row.
public class CalendarEventOccurrence : Object {
    public string source_uid { get; construct; }
    public string uid { get; construct; }
    public string recurrence_id { get; construct; }
    public string calendar_name { get; construct; }
    public string calendar_color { get; construct; }
    public string summary { get; construct; }
    public string description { get; construct; }
    public string location { get; construct; }
    public DateTime start { get; construct; }
    public DateTime end { get; construct; }
    public bool all_day { get; construct; }
    public bool recurring { get; construct; }
    public bool writable { get; construct; }

    public CalendarEventOccurrence (string source_uid, string uid,
                                    string recurrence_id, string calendar_name,
                                    string calendar_color, string summary,
                                    string description, string location,
                                    DateTime start, DateTime end, bool all_day,
                                    bool recurring, bool writable) {
        Object (source_uid: source_uid, uid: uid,
                recurrence_id: recurrence_id, calendar_name: calendar_name,
                calendar_color: calendar_color, summary: summary,
                description: description, location: location, start: start,
                end: end, all_day: all_day, recurring: recurring,
                writable: writable);
    }

    public string identity () {
        return "%s\n%s\n%s\n%s".printf (source_uid, uid, recurrence_id,
            start.to_unix ().to_string ());
    }
}

public enum CalendarEventRecurrence {
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

public class CalendarEventDraft : Object {
    public string summary { get; construct; }
    public string description { get; construct; }
    public string location { get; construct; }
    public DateTime start { get; construct; }
    public DateTime end { get; construct; }
    public bool all_day { get; construct; }
    public CalendarEventRecurrence recurrence { get; construct; }
    public int recurrence_interval { get; construct; }

    public CalendarEventDraft (string summary, string description,
                               string location, DateTime start, DateTime end,
                               bool all_day,
                               CalendarEventRecurrence recurrence =
                                   CalendarEventRecurrence.NONE,
                               int recurrence_interval = 1) {
        Object (summary: summary, description: description,
                location: location, start: start, end: end,
                all_day: all_day, recurrence: recurrence,
                recurrence_interval: int.max (1, recurrence_interval));
    }
}
}
