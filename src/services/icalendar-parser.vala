namespace Mailficient {
internal class ParsedICalendarProperty : Object {
    public string name;
    public string value;
    public Gee.HashMap<string, string> parameters = new Gee.HashMap<string, string> ();

    public ParsedICalendarProperty (string name, string value) {
        this.name = name;
        this.value = value;
    }

    public string parameter (string name) {
        return parameters.get (name.up ()) ?? "";
    }
}

internal class ParsedICalendarEvent : Object {
    public Gee.HashMap<string, ParsedICalendarProperty> first =
        new Gee.HashMap<string, ParsedICalendarProperty> ();
    public Gee.ArrayList<ParsedICalendarProperty> attendees =
        new Gee.ArrayList<ParsedICalendarProperty> ();

    public void add (ParsedICalendarProperty property) {
        if (property.name == "ATTENDEE") attendees.add (property);
        else if (!first.has_key (property.name)) first.set (property.name, property);
    }

    public ParsedICalendarProperty? property (string name) {
        return first.get (name);
    }
}

public class ICalendarParser : Object {
    public const int MAX_INPUT_BYTES = 2 * 1024 * 1024;
    public const int MAX_UNFOLDED_LINES = 4096;
    public const int MAX_UNFOLDED_LINE_BYTES = 16384;
    public const int MAX_COMPONENTS = 64;
    public const int MAX_ATTENDEES = 256;

    public static CalendarInvitation parse (string input) throws CalendarError {
        if (input.length == 0 || input.length > MAX_INPUT_BYTES)
            throw new CalendarError.INVALID_INVITATION (
                "The calendar invitation is empty or exceeds the 2 MB safety limit");
        if (!input.validate ())
            throw new CalendarError.INVALID_INVITATION (
                "The calendar invitation is not valid UTF-8 text");

        var lines = unfold (input);
        bool in_calendar = false;
        ParsedICalendarEvent? current_event = null;
        var events = new Gee.ArrayList<ParsedICalendarEvent> ();
        var calendar_properties = new Gee.HashMap<string, ParsedICalendarProperty> ();
        int component_depth = 0; int component_count = 0;

        foreach (var raw_line in lines) {
            string line = raw_line.strip ();
            if (line == "") continue;
            if (line.up () == "BEGIN:VCALENDAR") {
                if (in_calendar || component_depth != 0)
                    throw invalid ("The invitation contains a nested calendar");
                in_calendar = true; component_depth = 1; component_count++;
                continue;
            }
            if (line.up () == "END:VCALENDAR") {
                if (!in_calendar || component_depth != 1 || current_event != null)
                    throw invalid ("The invitation has an unmatched calendar boundary");
                in_calendar = false; component_depth = 0;
                continue;
            }
            if (!in_calendar) continue;
            if (line.up () == "BEGIN:VEVENT") {
                if (current_event != null || component_depth != 1)
                    throw invalid ("The invitation contains a nested event");
                if (++component_count > MAX_COMPONENTS)
                    throw invalid ("The invitation contains too many components");
                current_event = new ParsedICalendarEvent (); component_depth = 2;
                continue;
            }
            if (line.up () == "END:VEVENT") {
                if (current_event == null || component_depth != 2)
                    throw invalid ("The invitation has an unmatched event boundary");
                events.add (current_event); current_event = null; component_depth = 1;
                continue;
            }
            if (line.up ().has_prefix ("BEGIN:")) {
                // Preserve VTIMEZONE/VALARM and other valid components in the
                // original payload for EDS, but the compact reader does not
                // need to materialize their entire object graphs.
                if (++component_count > MAX_COMPONENTS)
                    throw invalid ("The invitation contains too many components");
                component_depth++;
                continue;
            }
            if (line.up ().has_prefix ("END:")) {
                if (component_depth <= 1)
                    throw invalid ("The invitation has an unmatched component boundary");
                component_depth--;
                continue;
            }
            if (component_depth > 2) continue;
            var property = parse_property (raw_line);
            if (property == null) continue;
            if (current_event != null && component_depth == 2) {
                if (property.name == "ATTENDEE" &&
                    current_event.attendees.size >= MAX_ATTENDEES)
                    throw invalid ("The invitation contains too many attendees");
                current_event.add (property);
            } else if (component_depth == 1 &&
                       !calendar_properties.has_key (property.name)) {
                calendar_properties.set (property.name, property);
            }
        }
        if (in_calendar || component_depth != 0 || current_event != null)
            throw invalid ("The invitation is incomplete");
        if (events.size == 0)
            throw invalid ("The calendar attachment does not contain an event");

        // Prefer the recurrence master. Detached instances remain in the raw
        // iCalendar passed to EDS, which applies them together.
        ParsedICalendarEvent selected = events[0];
        foreach (var candidate in events)
            if (candidate.property ("RECURRENCE-ID") == null) { selected = candidate; break; }

        var start_property = selected.property ("DTSTART");
        var uid_property = selected.property ("UID");
        if (start_property == null || uid_property == null || uid_property.value.strip () == "")
            throw invalid ("The invitation is missing its event identity or start time");

        bool all_day; string timezone_label;
        DateTime start = parse_datetime (start_property, out all_day, out timezone_label);
        DateTime? end = null;
        var end_property = selected.property ("DTEND");
        if (end_property != null) {
            bool end_all_day; string end_timezone;
            end = parse_datetime (end_property, out end_all_day, out end_timezone);
            if (end_all_day != all_day)
                throw invalid ("The invitation mixes all-day and timed boundaries");
            if (end.compare (start) < 0)
                throw invalid ("The invitation ends before it starts");
        } else {
            var duration = selected.property ("DURATION");
            if (duration != null)
                end = start.add (parse_duration (duration.value));
            else if (all_day)
                end = start.add_days (1);
        }

        string method_value = property_value (calendar_properties.get ("METHOD")).up ();
        CalendarInvitationMethod method;
        switch (method_value) {
        case "REQUEST": method = CalendarInvitationMethod.REQUEST; break;
        case "CANCEL": method = CalendarInvitationMethod.CANCEL; break;
        case "PUBLISH": method = CalendarInvitationMethod.PUBLISH; break;
        case "REPLY": method = CalendarInvitationMethod.REPLY; break;
        default: method = CalendarInvitationMethod.UNKNOWN; break;
        }

        var organizer_property = selected.property ("ORGANIZER");
        string organizer_email = organizer_property == null ? "" :
            address_value (organizer_property.value);
        string organizer_name = organizer_property == null ? "" :
            safe_text (decode_parameter (organizer_property.parameter ("CN")), 320);
        string sequence_value = property_value (selected.property ("SEQUENCE"));
        int sequence = 0; int.try_parse (sequence_value, out sequence, null, 10);
        if (sequence < 0) sequence = 0;

        var invitation = new CalendarInvitation (
            safe_text (unescape_text (uid_property.value), 512), method,
            display_text (selected.property ("SUMMARY"), "(Untitled meeting)", 512),
            display_text (selected.property ("DESCRIPTION"), "", 8192),
            display_text (selected.property ("LOCATION"), "", 1024),
            organizer_name, safe_text (organizer_email, 320), start, end, all_day,
            all_day ? "" : timezone_label,
            property_value (selected.property ("RRULE")),
            property_value (selected.property ("STATUS")).up (), sequence, input);

        foreach (var attendee_property in selected.attendees) {
            string email = address_value (attendee_property.value);
            if (email == "") continue;
            string name = safe_text (decode_parameter (attendee_property.parameter ("CN")), 320);
            bool rsvp = attendee_property.parameter ("RSVP").up () == "TRUE";
            CalendarParticipation participation = participation_from_string (
                attendee_property.parameter ("PARTSTAT"));
            invitation.attendees.add (new CalendarAttendee (name,
                safe_text (email, 320), rsvp, participation));
        }
        return invitation;
    }

    private static Gee.ArrayList<string> unfold (string input) throws CalendarError {
        string normalized = input.replace ("\r\n", "\n").replace ("\r", "\n");
        if (normalized.has_prefix ("\xef\xbb\xbf")) normalized = normalized.substring (3);
        var result = new Gee.ArrayList<string> ();
        foreach (var physical in normalized.split ("\n")) {
            if ((physical.has_prefix (" ") || physical.has_prefix ("\t")) && result.size > 0) {
                string unfolded = result[result.size - 1] + physical.substring (1);
                if (unfolded.length > MAX_UNFOLDED_LINE_BYTES)
                    throw invalid ("The invitation contains an excessively long line");
                result[result.size - 1] = unfolded;
            } else {
                if (physical.length > MAX_UNFOLDED_LINE_BYTES)
                    throw invalid ("The invitation contains an excessively long line");
                if (result.size >= MAX_UNFOLDED_LINES)
                    throw invalid ("The invitation contains too many lines");
                result.add (physical);
            }
        }
        return result;
    }

    private static ParsedICalendarProperty? parse_property (string line) throws CalendarError {
        int colon = separator_outside_quotes (line, ':');
        if (colon <= 0) return null;
        string left = line.substring (0, colon);
        string value = line.substring (colon + 1);
        var pieces = split_outside_quotes (left, ';');
        if (pieces.size == 0) return null;
        string name = pieces[0].strip ().up ();
        int group = name.last_index_of_char ('.');
        if (group >= 0) name = name.substring (group + 1);
        if (name == "") return null;
        var property = new ParsedICalendarProperty (name, value);
        for (int index = 1; index < pieces.size; index++) {
            int equal = separator_outside_quotes (pieces[index], '=');
            if (equal <= 0) continue;
            string key = pieces[index].substring (0, equal).strip ().up ();
            string parameter_value = pieces[index].substring (equal + 1).strip ();
            if (parameter_value.length >= 2 && parameter_value.has_prefix ("\"") &&
                parameter_value.has_suffix ("\""))
                parameter_value = parameter_value.substring (1, parameter_value.length - 2);
            if (key != "" && !property.parameters.has_key (key))
                property.parameters.set (key, parameter_value);
        }
        return property;
    }

    private static int separator_outside_quotes (string value, char separator) {
        bool quoted = false; bool escaped = false;
        for (int index = 0; index < value.length; index++) {
            char item = value[index];
            if (escaped) { escaped = false; continue; }
            if (item == '\\') { escaped = true; continue; }
            if (item == '"') quoted = !quoted;
            else if (!quoted && item == separator) return index;
        }
        return -1;
    }

    private static Gee.ArrayList<string> split_outside_quotes (string value, char separator) {
        var result = new Gee.ArrayList<string> (); int start = 0;
        bool quoted = false; bool escaped = false;
        for (int index = 0; index < value.length; index++) {
            char item = value[index];
            if (escaped) { escaped = false; continue; }
            if (item == '\\') { escaped = true; continue; }
            if (item == '"') quoted = !quoted;
            else if (!quoted && item == separator) {
                result.add (value.substring (start, index - start)); start = index + 1;
            }
        }
        result.add (value.substring (start)); return result;
    }

    private static DateTime parse_datetime (ParsedICalendarProperty property,
                                            out bool all_day,
                                            out string timezone_label) throws CalendarError {
        string value = property.value.strip ();
        all_day = property.parameter ("VALUE").up () == "DATE" ||
            (value.length == 8 && value.index_of_char ('T') < 0);
        int expected_minimum = all_day ? 8 : 13;
        if (value.length < expected_minimum || !digits (value, 0, 8))
            throw invalid ("The invitation contains an invalid date or time");
        int year; int month; int day;
        int.try_parse (value.substring (0, 4), out year, null, 10);
        int.try_parse (value.substring (4, 2), out month, null, 10);
        int.try_parse (value.substring (6, 2), out day, null, 10);
        if (!Date.valid_dmy ((DateDay) day, (DateMonth) month, (DateYear) year))
            throw invalid ("The invitation contains an invalid calendar date");
        int hour = 0; int minute = 0; int second = 0;
        if (!all_day) {
            if (value[8] != 'T' || !digits (value, 9, 4))
                throw invalid ("The invitation contains an invalid start time");
            int.try_parse (value.substring (9, 2), out hour, null, 10);
            int.try_parse (value.substring (11, 2), out minute, null, 10);
            if (value.length >= 15) {
                if (!digits (value, 13, 2))
                    throw invalid ("The invitation contains an invalid start time");
                int.try_parse (value.substring (13, 2), out second, null, 10);
            }
            int terminal = value.has_suffix ("Z") ? value.length - 1 : value.length;
            if (terminal != 13 && terminal != 15)
                throw invalid ("The invitation contains an unsupported date-time value");
            if (hour > 23 || minute > 59 || second > 60)
                throw invalid ("The invitation contains an invalid start time");
        }

        TimeZone zone;
        string requested_zone = property.parameter ("TZID");
        if (!all_day && value.has_suffix ("Z")) zone = new TimeZone.utc ();
        else if (requested_zone != "") {
            try { zone = new TimeZone.identifier (requested_zone); }
            catch (Error error) { zone = new TimeZone.local (); }
        } else zone = new TimeZone.local ();
        var parsed = new DateTime (zone, year, month, day, hour, minute, second);
        if (all_day) { timezone_label = ""; return parsed; }
        var local = parsed.to_local ();
        timezone_label = local.get_timezone_abbreviation ();
        return local;
    }

    private static TimeSpan parse_duration (string input) throws CalendarError {
        string value = input.strip ().up ();
        if (!value.has_prefix ("P")) throw invalid ("The invitation has an invalid duration");
        int64 seconds = 0; int64 number = 0; bool have_number = false; bool in_time = false;
        for (int index = 1; index < value.length; index++) {
            char item = value[index];
            if (item >= '0' && item <= '9') {
                have_number = true; number = number * 10 + (item - '0');
                if (number > 366000) throw invalid ("The invitation duration is too large");
                continue;
            }
            if (item == 'T' && !have_number) { in_time = true; continue; }
            if (!have_number) throw invalid ("The invitation has an invalid duration");
            switch (item) {
            case 'W': seconds += number * 7 * 86400; break;
            case 'D': seconds += number * 86400; break;
            case 'H': if (!in_time) throw invalid ("The invitation has an invalid duration");
                seconds += number * 3600; break;
            case 'M': if (!in_time) throw invalid ("The invitation has an invalid duration");
                seconds += number * 60; break;
            case 'S': if (!in_time) throw invalid ("The invitation has an invalid duration");
                seconds += number; break;
            default: throw invalid ("The invitation has an invalid duration");
            }
            number = 0; have_number = false;
            if (seconds > 3660 * 86400)
                throw invalid ("The invitation duration is too large");
        }
        if (have_number || seconds <= 0)
            throw invalid ("The invitation has an invalid duration");
        return (TimeSpan) (seconds * TimeSpan.SECOND);
    }

    private static bool digits (string value, int offset, int count) {
        if (offset < 0 || count < 0 || offset + count > value.length) return false;
        for (int index = offset; index < offset + count; index++)
            if (value[index] < '0' || value[index] > '9') return false;
        return true;
    }

    private static string property_value (ParsedICalendarProperty? property) {
        return property == null ? "" : property.value.strip ();
    }

    private static string display_text (ParsedICalendarProperty? property,
                                        string fallback, int maximum) {
        if (property == null) return fallback;
        string value = safe_text (unescape_text (property.value), maximum);
        return value == "" ? fallback : value;
    }

    internal static string unescape_text (string value) {
        return value.replace ("\\n", "\n").replace ("\\N", "\n")
            .replace ("\\,", ",").replace ("\\;", ";").replace ("\\\\", "\\");
    }

    internal static string escape_text (string value) {
        return value.replace ("\\", "\\\\").replace ("\r\n", "\n")
            .replace ("\r", "\n").replace ("\n", "\\n")
            .replace (",", "\\,").replace (";", "\\;");
    }

    private static string decode_parameter (string value) {
        // RFC 6868 parameter escaping, used by modern Outlook and Evolution.
        return value.replace ("^^", "\u0001").replace ("^n", "\n")
            .replace ("^N", "\n").replace ("^'", "\"").replace ("\u0001", "^");
    }

    private static string address_value (string value) {
        string address = value.strip ();
        if (address.down ().has_prefix ("mailto:")) address = address.substring (7);
        int query = address.index_of_char ('?');
        if (query >= 0) address = address.substring (0, query);
        return address.strip ().down ();
    }

    private static string safe_text (string value, int maximum) {
        string result = value.strip ();
        if (result.length <= maximum) return result;
        return result.substring (0, maximum).make_valid () + "…";
    }

    private static CalendarParticipation participation_from_string (string value) {
        switch (value.up ()) {
        case "NEEDS-ACTION": return CalendarParticipation.NEEDS_ACTION;
        case "ACCEPTED": return CalendarParticipation.ACCEPTED;
        case "TENTATIVE": return CalendarParticipation.TENTATIVE;
        case "DECLINED": return CalendarParticipation.DECLINED;
        case "DELEGATED": return CalendarParticipation.DELEGATED;
        default: return CalendarParticipation.UNKNOWN;
        }
    }

    private static CalendarError invalid (string message) {
        return new CalendarError.INVALID_INVITATION (message);
    }
}
}
