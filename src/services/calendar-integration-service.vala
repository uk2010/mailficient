namespace Mailficient {
public enum CalendarCreateDisposition {
    CREATED,
    OPENED_FOR_REVIEW
}

public interface CalendarBackend : Object {
    public abstract bool can_respond_directly { get; }
    public abstract bool can_manage_events { get; }
    public abstract async void respond (CalendarInvitation invitation,
                                        string identity_email,
                                        CalendarParticipation participation,
                                        bool send_response,
                                        Cancellable? cancellable = null) throws Error;
    public abstract async CalendarCreateDisposition create_meeting (
        CalendarMeetingDraft meeting, Cancellable? cancellable = null) throws Error;
    public abstract async Gee.ArrayList<CalendarEventOccurrence> list_events (
        DateTime range_start, DateTime range_end,
        Cancellable? cancellable = null) throws Error;
    public abstract async void create_event (
        CalendarEventDraft draft, Cancellable? cancellable = null) throws Error;
    public abstract async void update_event (
        CalendarEventOccurrence event, CalendarEventDraft draft,
        Cancellable? cancellable = null) throws Error;
    public abstract async void delete_event (
        CalendarEventOccurrence event,
        Cancellable? cancellable = null) throws Error;
    public abstract void launch_calendar () throws Error;
}

// Portable fallback for source builds without libecal development files. It
// still hands new meetings and invitations to the registered calendar app for
// review, but never pretends that an RSVP was recorded when direct EDS support
// is unavailable.
public class DesktopCalendarBackend : Object, CalendarBackend {
    public bool can_respond_directly { get { return false; } }
    public bool can_manage_events { get { return false; } }

    public async void respond (CalendarInvitation invitation, string identity_email,
                               CalendarParticipation participation, bool send_response,
                               Cancellable? cancellable = null) throws Error {
        throw new CalendarError.UNSUPPORTED (
            "Direct invitation responses require Evolution Data Server calendar support. " +
            "Use Add to Calendar to respond in GNOME Calendar.");
    }

    public async CalendarCreateDisposition create_meeting (
        CalendarMeetingDraft meeting, Cancellable? cancellable = null) throws Error {
        string icalendar = meeting_icalendar (meeting);
        File temporary = yield write_private_calendar_file (icalendar, "meeting", cancellable);
        try {
            AppInfo.launch_default_for_uri (temporary.get_uri (), null);
            schedule_cleanup (temporary);
            return CalendarCreateDisposition.OPENED_FOR_REVIEW;
        } catch (Error error) {
            try { temporary.delete (); } catch (Error ignored) { }
            throw new CalendarError.CREATE_FAILED (
                "The meeting could not be opened in the desktop calendar: %s".printf (
                    error.message));
        }
    }

    public async Gee.ArrayList<CalendarEventOccurrence> list_events (
        DateTime range_start, DateTime range_end,
        Cancellable? cancellable = null) throws Error {
        throw event_store_unavailable ();
    }

    public async void create_event (CalendarEventDraft draft,
                                    Cancellable? cancellable = null) throws Error {
        throw event_store_unavailable ();
    }

    public async void update_event (CalendarEventOccurrence event,
                                    CalendarEventDraft draft,
                                    Cancellable? cancellable = null) throws Error {
        throw event_store_unavailable ();
    }

    public async void delete_event (CalendarEventOccurrence event,
                                    Cancellable? cancellable = null) throws Error {
        throw event_store_unavailable ();
    }

    private static CalendarError event_store_unavailable () {
        return new CalendarError.UNSUPPORTED (
            "Today and Events require Evolution Data Server calendar support");
    }

    public void launch_calendar () throws Error {
        GnomeCalendarLauncher.launch ();
    }

    internal static string meeting_icalendar (CalendarMeetingDraft meeting) {
        string uid = "mailficient-%s@local".printf (Uuid.string_random ());
        string stamp = new DateTime.now_utc ().format ("%Y%m%dT%H%M%SZ");
        string start = meeting.start.to_utc ().format ("%Y%m%dT%H%M%SZ");
        string end = meeting.end.to_utc ().format ("%Y%m%dT%H%M%SZ");
        var result = new StringBuilder ();
        result.append ("BEGIN:VCALENDAR\r\nVERSION:2.0\r\n");
        result.append ("PRODID:-//Mailficient//Meeting from email//EN\r\n");
        result.append ("CALSCALE:GREGORIAN\r\nBEGIN:VEVENT\r\n");
        result.append ("UID:%s\r\nDTSTAMP:%s\r\nDTSTART:%s\r\nDTEND:%s\r\n".printf (
            uid, stamp, start, end));
        result.append ("SUMMARY:%s\r\n".printf (
            ICalendarParser.escape_text (meeting.summary)));
        if (meeting.description != "") result.append ("DESCRIPTION:%s\r\n".printf (
            ICalendarParser.escape_text (meeting.description)));
        if (RecipientParser.is_valid_address (meeting.organizer_email))
            result.append ("ORGANIZER:mailto:%s\r\n".printf (meeting.organizer_email));
        if (RecipientParser.is_valid_address (meeting.attendee_email)) {
            string common_name = meeting.attendee_name == "" ? "" :
                ";CN=\"%s\"".printf (escape_parameter (meeting.attendee_name));
            result.append ("ATTENDEE%s;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:%s\r\n".printf (
                common_name, meeting.attendee_email));
        }
        result.append ("END:VEVENT\r\nEND:VCALENDAR\r\n");
        return result.str;
    }

    private static string escape_parameter (string value) {
        return value.replace ("^", "^^").replace ("\n", "^n")
            .replace ("\r", "").replace ("\"", "^'");
    }

    internal static async File write_private_calendar_file (
        string contents, string stem, Cancellable? cancellable = null) throws Error {
        if (contents.length > ICalendarParser.MAX_INPUT_BYTES)
            throw new CalendarError.INVALID_INVITATION (
                "The calendar data exceeds the 2 MB safety limit");
        string path = Path.build_filename (Environment.get_tmp_dir (),
            "mailficient-%s-%s.ics".printf (stem, Uuid.string_random ()));
        var file = File.new_for_path (path);
        try {
            var stream = yield file.replace_async (null, false, FileCreateFlags.PRIVATE,
                Priority.DEFAULT, cancellable);
            size_t written;
            yield stream.write_all_async (contents.data, Priority.DEFAULT,
                cancellable, out written);
            yield stream.close_async (Priority.DEFAULT, cancellable);
            if (written != contents.length)
                throw new IOError.FAILED ("The private calendar copy was incomplete");
            return file;
        } catch (Error error) {
            try { if (file.query_exists ()) file.delete (); } catch (Error ignored) { }
            throw error;
        }
    }

    internal static void schedule_cleanup (File file) {
        Timeout.add_seconds (300, () => {
            try { if (file.query_exists ()) file.delete (); } catch (Error ignored) { }
            return Source.REMOVE;
        });
    }
}

public class CalendarIntegrationService : Object {
    public const int EVENT_LOOKAHEAD_YEARS = 2;
    public const int MAX_DISPLAYED_INVITATIONS = 5;
    public const int MAX_EVENT_TITLE_BYTES = 240;
    public const int MAX_EVENT_DESCRIPTION_BYTES = 16 * 1024;
    public const int MAX_EVENT_LOCATION_BYTES = 2048;
    private CacheDatabase cache;
    private ReceivedAttachmentService attachments;
    private CalendarBackend backend;

    public CalendarIntegrationService (CacheDatabase cache,
                                       ReceivedAttachmentService attachments,
                                       CalendarBackend backend) {
        this.cache = cache;
        this.attachments = attachments;
        this.backend = backend;
    }

    public bool can_respond_directly { get { return backend.can_respond_directly; } }
    public bool can_manage_events { get { return backend.can_manage_events; } }

    public void open_calendar () throws Error {
        backend.launch_calendar ();
    }

    public async Gee.ArrayList<CalendarEventOccurrence> list_events (
        DateTime range_start, DateTime range_end,
        Cancellable? cancellable = null) throws Error {
        if (range_end.compare (range_start) <= 0)
            throw new CalendarError.INVALID_INVITATION (
                "The calendar range must end after it starts");
        return yield backend.list_events (range_start, range_end, cancellable);
    }

    public async void create_event (CalendarEventDraft draft,
                                    Cancellable? cancellable = null) throws Error {
        validate_event_draft (draft);
        yield backend.create_event (draft, cancellable);
    }

    public async void update_event (CalendarEventOccurrence event,
                                    CalendarEventDraft draft,
                                    Cancellable? cancellable = null) throws Error {
        if (!event.writable)
            throw new CalendarError.CREATE_FAILED (
                "This calendar is read-only");
        validate_event_draft (draft);
        yield backend.update_event (event, draft, cancellable);
    }

    public async void delete_event (CalendarEventOccurrence event,
                                    Cancellable? cancellable = null) throws Error {
        if (!event.writable)
            throw new CalendarError.CREATE_FAILED (
                "This calendar is read-only");
        yield backend.delete_event (event, cancellable);
    }

    private static void validate_event_draft (CalendarEventDraft draft)
        throws CalendarError {
        if (draft.summary.strip () == "")
            throw new CalendarError.CREATE_FAILED ("An event title is required");
        if (draft.summary.length > MAX_EVENT_TITLE_BYTES)
            throw new CalendarError.CREATE_FAILED (
                "Event titles can contain up to 240 characters");
        if (draft.description.length > MAX_EVENT_DESCRIPTION_BYTES)
            throw new CalendarError.CREATE_FAILED (
                "Event descriptions are limited to 16 KiB");
        if (draft.location.length > MAX_EVENT_LOCATION_BYTES)
            throw new CalendarError.CREATE_FAILED (
                "Event locations are limited to 2 KiB");
        if (draft.end.compare (draft.start) <= 0)
            throw new CalendarError.CREATE_FAILED (
                "The event must end after it starts");
        if (draft.recurrence_interval < 1 || draft.recurrence_interval > 99)
            throw new CalendarError.CREATE_FAILED (
                "Event recurrence must be between 1 and 99");
    }

    internal static string bounded_event_text (string value, int maximum_bytes) {
        if (value.length <= maximum_bytes) return value;
        int boundary = maximum_bytes;
        while (boundary > 0 && ((((uint8) value[boundary]) & 0xc0) == 0x80))
            boundary--;
        return value.substring (0, boundary).make_valid ();
    }

    public CalendarAttendee? account_attendee (Message message,
                                               CalendarInvitation invitation) {
        try {
            var account = cache.find_account (message.account_id);
            return account == null ? null : invitation.attendee_for (account.email);
        } catch (Error error) { return null; }
    }

    public async CalendarInvitation load_invitation (Message message,
                                                     Attachment attachment,
                                                     Cancellable? cancellable = null) throws Error {
        File? staged = null;
        try {
            staged = yield attachments.stage_calendar_invitation (
                message, attachment, cancellable);
            uint8[] contents; string? etag;
            yield staged.load_contents_async (cancellable, out contents, out etag);
            if (contents.length == 0 || contents.length > ICalendarParser.MAX_INPUT_BYTES)
                throw new CalendarError.INVALID_INVITATION (
                    "The calendar invitation is empty or exceeds the 2 MB safety limit");
            foreach (uint8 item in contents)
                if (item == 0)
                    throw new CalendarError.INVALID_INVITATION (
                        "The calendar invitation contains invalid binary data");
            var text = new StringBuilder.sized (contents.length + 1);
            text.append_len ((string) contents, (ssize_t) contents.length);
            return ICalendarParser.parse (text.str);
        } finally {
            if (staged != null) {
                try { if (staged.query_exists ()) staged.delete (); }
                catch (Error ignored) { }
            }
        }
    }

    public async void respond (Message message, CalendarInvitation invitation,
                               CalendarParticipation participation, bool send_response,
                               Cancellable? cancellable = null) throws Error {
        if (participation != CalendarParticipation.ACCEPTED &&
            participation != CalendarParticipation.TENTATIVE &&
            participation != CalendarParticipation.DECLINED)
            throw new CalendarError.RESPONSE_FAILED ("Choose a valid invitation response");
        if (!invitation.can_respond ())
            throw new CalendarError.UNSUPPORTED (
                "This calendar item is not an actionable meeting request");
        var account = cache.find_account (message.account_id);
        if (account == null || !RecipientParser.is_valid_address (account.email))
            throw new CalendarError.IDENTITY_NOT_INVITED (
                "The invitation's mail account is no longer configured");
        if (invitation.attendee_for (account.email) == null)
            throw new CalendarError.IDENTITY_NOT_INVITED (
                "This invitation does not list %s as an attendee".printf (account.email));
        yield backend.respond (invitation, account.email, participation,
            send_response, cancellable);
    }

    public bool response_requested (Message message, CalendarInvitation invitation) {
        var attendee = account_attendee (message, invitation);
        return attendee != null && attendee.response_requested;
    }

    public CalendarMeetingDraft meeting_from_message (Message message,
                                                       DateTime start, DateTime end) {
        string organizer = "";
        try {
            var account = cache.find_account (message.account_id);
            if (account != null) organizer = account.email;
        } catch (Error error) { }
        string subject = strip_reply_prefixes (message.subject);
        if (subject == "") subject = "Meeting with %s".printf (
            message.sender_name == "" ? message.sender_address : message.sender_name);
        string excerpt = message.body.strip ();
        if (excerpt.length > 4000)
            excerpt = excerpt.substring (0, 4000).make_valid () + "…";
        string description = "Created from an email in Mailficient.\n\nFrom: %s <%s>\nSubject: %s".printf (
            message.sender_name, message.sender_address, message.subject);
        if (message.internet_message_id != "")
            description += "\nMessage-ID: %s".printf (message.internet_message_id);
        if (excerpt != "") description += "\n\n" + excerpt;
        return new CalendarMeetingDraft (subject, description, organizer,
            message.sender_name, message.sender_address, start, end);
    }

    public async CalendarCreateDisposition create_meeting (
        CalendarMeetingDraft meeting, Cancellable? cancellable = null) throws Error {
        if (meeting.summary.strip () == "")
            throw new CalendarError.CREATE_FAILED ("A meeting title is required");
        if (meeting.end.compare (meeting.start) <= 0)
            throw new CalendarError.CREATE_FAILED (
                "The meeting must end after it starts");
        var disposition = yield backend.create_meeting (meeting, cancellable);
        if (disposition == CalendarCreateDisposition.CREATED) {
            try { backend.launch_calendar (); }
            catch (Error error) {
                // A directly created EDS event remains safely stored even if
                // the companion application cannot be activated.
                warning ("Created meeting could not be shown in GNOME Calendar: %s",
                    error.message);
            }
        }
        return disposition;
    }

    public async void open_invitation (CalendarInvitation invitation,
                                       Cancellable? cancellable = null) throws Error {
        var temporary = yield DesktopCalendarBackend.write_private_calendar_file (
            invitation.raw_icalendar, "invitation", cancellable);
        try {
            AppInfo.launch_default_for_uri (temporary.get_uri (), null);
            DesktopCalendarBackend.schedule_cleanup (temporary);
        } catch (Error error) {
            try { temporary.delete (); } catch (Error ignored) { }
            throw error;
        }
    }

    private static string strip_reply_prefixes (string input) {
        string result = input.strip ();
        while (true) {
            string lower = result.down ();
            int prefix = lower.has_prefix ("re:") ? 3 :
                (lower.has_prefix ("fwd:") ? 4 : (lower.has_prefix ("fw:") ? 3 : 0));
            if (prefix == 0) return result;
            result = result.substring (prefix).strip ();
        }
    }
}
}
