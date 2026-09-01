using Mailficient;

private const string OUTLOOK_REQUEST =
    "BEGIN:VCALENDAR\r\n" +
    "VERSION:2.0\r\n" +
    "METHOD:REQUEST\r\n" +
    "BEGIN:VEVENT\r\n" +
    "UID:outlook-meeting-42@example.net\r\n" +
    "SEQUENCE:3\r\n" +
    "DTSTART;TZID=America/New_York:20260910T090000\r\n" +
    "DURATION:PT1H30M\r\n" +
    "SUMMARY:Quarterly product\r\n review\r\n" +
    "DESCRIPTION:Bring the roadmap\\, metrics\\; and notes\\nThank you.\r\n" +
    "LOCATION:Room 4\\, West\r\n" +
    "RRULE:FREQ=WEEKLY;COUNT=3\r\n" +
    "ORGANIZER;CN=Taylor^'Tay^' Rivera:mailto:taylor@example.org\r\n" +
    "ATTENDEE;CN=Alex Morgan;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:alex@example.net\r\n" +
    "ATTENDEE;CN=Maya Chen;PARTSTAT=ACCEPTED;RSVP=FALSE:mailto:maya@example.net\r\n" +
    "END:VEVENT\r\n" +
    "END:VCALENDAR\r\n";

private class RecordingCalendarBackend : Object, CalendarBackend {
    public bool direct = true;
    public bool manageable = true;
    public int response_calls;
    public int create_calls;
    public int event_create_calls;
    public int event_update_calls;
    public int event_delete_calls;
    public int launch_calls;
    public string response_identity = "";
    public CalendarParticipation response_participation;
    public bool response_was_sent;
    public CalendarMeetingDraft? created_meeting;
    public CalendarCreateDisposition create_disposition = CalendarCreateDisposition.CREATED;

    public bool can_respond_directly { get { return direct; } }
    public bool can_manage_events { get { return manageable; } }

    public async void respond (CalendarInvitation invitation, string identity_email,
                               CalendarParticipation participation, bool send_response,
                               Cancellable? cancellable = null) throws Error {
        if (cancellable != null) cancellable.set_error_if_cancelled ();
        response_calls++;
        response_identity = identity_email;
        response_participation = participation;
        response_was_sent = send_response;
    }

    public async CalendarCreateDisposition create_meeting (
        CalendarMeetingDraft meeting, Cancellable? cancellable = null) throws Error {
        if (cancellable != null) cancellable.set_error_if_cancelled ();
        create_calls++;
        created_meeting = meeting;
        return create_disposition;
    }

    public async Gee.ArrayList<CalendarEventOccurrence> list_events (
        DateTime range_start, DateTime range_end,
        Cancellable? cancellable = null) throws Error {
        if (cancellable != null) cancellable.set_error_if_cancelled ();
        return new Gee.ArrayList<CalendarEventOccurrence> ();
    }

    public async void create_event (CalendarEventDraft draft,
                                    Cancellable? cancellable = null) throws Error {
        if (cancellable != null) cancellable.set_error_if_cancelled ();
        event_create_calls++;
    }

    public async void update_event (CalendarEventOccurrence event,
                                    CalendarEventDraft draft,
                                    Cancellable? cancellable = null) throws Error {
        if (cancellable != null) cancellable.set_error_if_cancelled ();
        event_update_calls++;
    }

    public async void delete_event (CalendarEventOccurrence event,
                                    Cancellable? cancellable = null) throws Error {
        if (cancellable != null) cancellable.set_error_if_cancelled ();
        event_delete_calls++;
    }

    public void launch_calendar () throws Error { launch_calls++; }
}

private void run_event_create (CalendarIntegrationService service,
                               CalendarEventDraft draft,
                               out Error? failure) {
    var loop = new MainLoop ();
    Error? captured = null;
    service.create_event.begin (draft, null, (object, result) => {
        try { service.create_event.end (result); }
        catch (Error error) { captured = error; }
        loop.quit ();
    });
    loop.run ();
    failure = captured;
}

private CacheDatabase test_cache (string root, string account_id = "calendar-account") {
    var cache = new CacheDatabase (Path.build_filename (root, "mail.sqlite"));
    var account = AccountSettings.for_email ("Alex Morgan", "alex@example.net");
    account.id = account_id;
    account.incoming_host = "imap.example.net";
    account.outgoing_host = "smtp.example.net";
    cache.save_account (account);
    return cache;
}

private Message invitation_message (string account_id = "calendar-account") {
    return new Message ("message-1", "inbox", "Taylor Rivera",
        "taylor@example.org", "Alex Morgan <alex@example.net>",
        "Quarterly product review", "Meeting request",
        "Would you be available for the quarterly product review?",
        "Sep 1", false, false, true, 1, false, account_id, "77",
        "<message-1@example.org>");
}

private void test_outlook_request_parser () {
    try {
        var invitation = ICalendarParser.parse (OUTLOOK_REQUEST);
        assert (invitation.uid == "outlook-meeting-42@example.net");
        assert (invitation.method == CalendarInvitationMethod.REQUEST);
        assert (invitation.summary == "Quarterly productreview");
        assert (invitation.description == "Bring the roadmap, metrics; and notes\nThank you.");
        assert (invitation.location == "Room 4, West");
        assert (invitation.sequence == 3);
        assert (invitation.recurrence_summary () == "Repeats weekly · 3 occurrences");
        assert (invitation.start.to_utc ().format ("%Y%m%dT%H%M%SZ") ==
            "20260910T130000Z");
        assert (invitation.end != null);
        assert (invitation.end.to_utc ().format ("%Y%m%dT%H%M%SZ") ==
            "20260910T143000Z");
        assert (invitation.organizer_name == "Taylor\"Tay\" Rivera");
        assert (invitation.organizer_email == "taylor@example.org");
        assert (invitation.attendees.size == 2);
        var alex = invitation.attendee_for ("ALEX@EXAMPLE.NET");
        assert (alex != null);
        assert (alex.response_requested);
        assert (alex.participation == CalendarParticipation.NEEDS_ACTION);
        assert (invitation.organizer_matches_sender ("Taylor@example.org"));
        assert (!invitation.organizer_matches_sender ("spoof@example.org"));
    } catch (Error error) {
        GLib.error ("Outlook invitation parse failed: %s", error.message);
    }
}

private void test_all_day_and_cancel_parser () {
    string payload = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:CANCEL\r\n" +
        "BEGIN:VEVENT\r\nUID:all-day@example.net\r\nDTSTART;VALUE=DATE:20261224\r\n" +
        "DTEND;VALUE=DATE:20261227\r\nSUMMARY:Office closed\r\nSTATUS:CANCELLED\r\n" +
        "END:VEVENT\r\nEND:VCALENDAR\r\n";
    try {
        var invitation = ICalendarParser.parse (payload);
        assert (invitation.method == CalendarInvitationMethod.CANCEL);
        assert (invitation.all_day);
        assert (invitation.status == "CANCELLED");
        assert (!invitation.can_respond ());
        assert (invitation.formatted_when ().contains ("December"));
        assert (invitation.formatted_when ().contains ("All day"));
    } catch (Error error) {
        GLib.error ("All-day cancellation parse failed: %s", error.message);
    }
}

private void assert_invalid (string payload) {
    Error? failure = null;
    try { ICalendarParser.parse (payload); }
    catch (Error error) { failure = error; }
    assert (failure is CalendarError.INVALID_INVITATION);
}

private void test_parser_rejects_malformed_and_unbounded_data () {
    assert_invalid ("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:x\r\nEND:VCALENDAR\r\n");
    assert_invalid ("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:x\r\n" +
        "DTSTART:20261340T250000Z\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n");

    var long_line = new StringBuilder ();
    for (int index = 0; index <= ICalendarParser.MAX_UNFOLDED_LINE_BYTES; index++)
        long_line.append_c ('x');
    assert_invalid ("BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:x\nDTSTART:20260910T130000Z\n" +
        "SUMMARY:" + long_line.str + "\nEND:VEVENT\nEND:VCALENDAR\n");

    var oversized = new StringBuilder.sized (ICalendarParser.MAX_INPUT_BYTES + 1);
    for (int index = 0; index <= ICalendarParser.MAX_INPUT_BYTES; index++)
        oversized.append_c ('x');
    assert_invalid (oversized.str);
}

private void run_response (CalendarIntegrationService service, Message message,
                           CalendarInvitation invitation, CalendarParticipation participation,
                           bool send_response, out Error? failure) {
    var loop = new MainLoop ();
    Error? captured = null;
    service.respond.begin (message, invitation, participation, send_response, null,
        (object, result) => {
            try { service.respond.end (result); }
            catch (Error error) { captured = error; }
            loop.quit ();
        });
    loop.run ();
    failure = captured;
}

private void test_response_uses_exact_account_identity_and_optional_send () {
    string root = DirUtils.make_tmp ("mailficient-calendar-response-XXXXXX");
    try {
        var cache = test_cache (root);
        var files = new AttachmentService (Path.build_filename (root, "attachments"));
        var received = new ReceivedAttachmentService (cache, files, null);
        var backend = new RecordingCalendarBackend ();
        var service = new CalendarIntegrationService (cache, received, backend);
        var invitation = ICalendarParser.parse (OUTLOOK_REQUEST);
        Error? failure;
        run_response (service, invitation_message (), invitation,
            CalendarParticipation.TENTATIVE, false, out failure);
        assert (failure == null);
        assert (backend.response_calls == 1);
        assert (backend.response_identity == "alex@example.net");
        assert (backend.response_participation == CalendarParticipation.TENTATIVE);
        assert (!backend.response_was_sent);
        assert (service.response_requested (invitation_message (), invitation));

        run_response (service, invitation_message (), invitation,
            CalendarParticipation.ACCEPTED, true, out failure);
        assert (failure == null);
        assert (backend.response_calls == 2);
        assert (backend.response_was_sent);
    } catch (Error error) {
        GLib.error ("Calendar response service test failed: %s", error.message);
    }
}

private void test_response_rejects_uninvited_or_missing_identity () {
    string root = DirUtils.make_tmp ("mailficient-calendar-identity-XXXXXX");
    try {
        var cache = test_cache (root);
        var files = new AttachmentService (Path.build_filename (root, "attachments"));
        var backend = new RecordingCalendarBackend ();
        var service = new CalendarIntegrationService (cache,
            new ReceivedAttachmentService (cache, files, null), backend);
        string uninvited_payload = OUTLOOK_REQUEST.replace (
            "mailto:alex@example.net", "mailto:someone@example.net");
        var uninvited = ICalendarParser.parse (uninvited_payload);
        Error? failure;
        run_response (service, invitation_message (), uninvited,
            CalendarParticipation.DECLINED, false, out failure);
        assert (failure is CalendarError.IDENTITY_NOT_INVITED);
        assert (backend.response_calls == 0);

        run_response (service, invitation_message ("missing-account"), uninvited,
            CalendarParticipation.DECLINED, false, out failure);
        assert (failure is CalendarError.IDENTITY_NOT_INVITED);
        assert (backend.response_calls == 0);
    } catch (Error error) {
        GLib.error ("Calendar identity validation test failed: %s", error.message);
    }
}

private void run_create (CalendarIntegrationService service, CalendarMeetingDraft meeting,
                         out CalendarCreateDisposition disposition, out Error? failure) {
    var loop = new MainLoop ();
    CalendarCreateDisposition captured = CalendarCreateDisposition.OPENED_FOR_REVIEW;
    Error? captured_error = null;
    service.create_meeting.begin (meeting, null, (object, result) => {
        try { captured = service.create_meeting.end (result); }
        catch (Error error) { captured_error = error; }
        loop.quit ();
    });
    loop.run ();
    disposition = captured;
    failure = captured_error;
}

private void test_meeting_from_email_is_draft_and_never_auto_sends () {
    string root = DirUtils.make_tmp ("mailficient-calendar-create-XXXXXX");
    try {
        var cache = test_cache (root);
        var backend = new RecordingCalendarBackend ();
        var service = new CalendarIntegrationService (cache,
            new ReceivedAttachmentService (cache,
                new AttachmentService (Path.build_filename (root, "attachments")), null),
            backend);
        var start = new DateTime.local (2026, 10, 5, 9, 30, 0);
        var message = invitation_message ();
        var meeting = service.meeting_from_message (message, start, start.add_hours (1));
        assert (meeting.summary == "Quarterly product review");
        assert (meeting.organizer_email == "alex@example.net");
        assert (meeting.attendee_email == "taylor@example.org");
        assert (meeting.description.contains ("Message-ID: <message-1@example.org>"));

        string payload = DesktopCalendarBackend.meeting_icalendar (meeting);
        assert (!payload.contains ("METHOD:REQUEST"));
        assert (payload.contains ("PARTSTAT=NEEDS-ACTION"));
        var parsed = ICalendarParser.parse (payload);
        assert (parsed.summary == meeting.summary);

        // The Calendar favorite must launch through this same backend rather
        // than bypassing the authoritative calendar integration.
        service.open_calendar ();
        assert (backend.launch_calls == 1);

        CalendarCreateDisposition disposition; Error? failure;
        run_create (service, meeting, out disposition, out failure);
        assert (failure == null);
        assert (disposition == CalendarCreateDisposition.CREATED);
        assert (backend.create_calls == 1);
        assert (backend.launch_calls == 2);

        backend.create_disposition = CalendarCreateDisposition.OPENED_FOR_REVIEW;
        run_create (service, meeting, out disposition, out failure);
        assert (failure == null);
        assert (backend.launch_calls == 2);
    } catch (Error error) {
        GLib.error ("Meeting-from-email test failed: %s", error.message);
    }
}

private async void exercise_local_invitation_load (CalendarIntegrationService service,
                                                    Message message,
                                                    Attachment attachment) throws Error {
    var invitation = yield service.load_invitation (message, attachment);
    assert (invitation.uid == "outlook-meeting-42@example.net");
}

private void test_local_invitation_is_staged_and_parsed () {
    string root = DirUtils.make_tmp ("mailficient-calendar-load-XXXXXX");
    try {
        var cache = test_cache (root);
        var files = new AttachmentService (Path.build_filename (root, "attachments"));
        var service = new CalendarIntegrationService (cache,
            new ReceivedAttachmentService (cache, files, null),
            new RecordingCalendarBackend ());
        string path = Path.build_filename (root, "invite.ics");
        FileUtils.set_contents (path, OUTLOOK_REQUEST);
        var attachment = new Attachment ("invite", path, "invite.ics",
            OUTLOOK_REQUEST.length, "text/calendar; method=REQUEST");
        var loop = new MainLoop (); Error? failure = null;
        exercise_local_invitation_load.begin (service, invitation_message (), attachment,
            (object, result) => {
                try { exercise_local_invitation_load.end (result); }
                catch (Error error) { failure = error; }
                loop.quit ();
            });
        loop.run ();
        if (failure != null) GLib.error ("Invitation load failed: %s", failure.message);
    } catch (Error error) {
        GLib.error ("Calendar staging test failed: %s", error.message);
    }
}

private void test_event_creation_uses_calendar_backend_and_validates () {
    string root = DirUtils.make_tmp ("mailficient-calendar-event-XXXXXX");
    try {
        var cache = test_cache (root);
        var backend = new RecordingCalendarBackend ();
        var service = new CalendarIntegrationService (cache,
            new ReceivedAttachmentService (cache,
                new AttachmentService (Path.build_filename (root, "attachments")), null),
            backend);
        assert (service.can_manage_events);
        var start = new DateTime.local (2026, 9, 10, 13, 0, 0);
        var draft = new CalendarEventDraft ("Calendar-backed event", "Notes",
            "Room 4", start, start.add_hours (1), false);
        Error? failure;
        run_event_create (service, draft, out failure);
        assert (failure == null);
        assert (backend.event_create_calls == 1);

        run_event_create (service, new CalendarEventDraft ("", "", "",
            start, start.add_hours (1), false), out failure);
        assert (failure is CalendarError.CREATE_FAILED);
        assert (backend.event_create_calls == 1);
    } catch (Error error) {
        GLib.error ("Calendar event creation test failed: %s", error.message);
    }
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/calendar/parser/outlook-request", test_outlook_request_parser);
    Test.add_func ("/calendar/parser/all-day-cancel", test_all_day_and_cancel_parser);
    Test.add_func ("/calendar/parser/rejects-malformed-and-unbounded",
        test_parser_rejects_malformed_and_unbounded_data);
    Test.add_func ("/calendar/service/exact-identity-and-optional-send",
        test_response_uses_exact_account_identity_and_optional_send);
    Test.add_func ("/calendar/service/rejects-uninvited-or-missing-identity",
        test_response_rejects_uninvited_or_missing_identity);
    Test.add_func ("/calendar/service/meeting-from-email-no-auto-send",
        test_meeting_from_email_is_draft_and_never_auto_sends);
    Test.add_func ("/calendar/service/local-staging", test_local_invitation_is_staged_and_parsed);
    Test.add_func ("/calendar/service/event-create-routes-to-calendar-store",
        test_event_creation_uses_calendar_backend_and_validates);
    return Test.run ();
}
