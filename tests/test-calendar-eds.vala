using Mailficient;

private const string REQUEST =
    "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:REQUEST\r\n" +
    "BEGIN:VEVENT\r\nUID:eds-response@example.net\r\n" +
    "DTSTART:20260910T130000Z\r\nSUMMARY:EDS response\r\n" +
    "ORGANIZER:mailto:organizer@example.org\r\n" +
    "ATTENDEE;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:alex@example.net\r\n" +
    "ATTENDEE;PARTSTAT=ACCEPTED:mailto:maya@example.net\r\n" +
    "END:VEVENT\r\nEND:VCALENDAR\r\n";

private ICal.ParameterPartstat partstat_for (ICal.Component calendar, string identity) {
    var event = calendar.get_first_component (ICal.ComponentKind.VEVENT_COMPONENT);
    assert (event != null);
    for (ICal.Property? attendee = event.get_first_property (
             ICal.PropertyKind.ATTENDEE_PROPERTY);
         attendee != null;
         attendee = event.get_next_property (ICal.PropertyKind.ATTENDEE_PROPERTY)) {
        if (CalendarInvitation.normalize_email (attendee.get_attendee ()) !=
            CalendarInvitation.normalize_email (identity)) continue;
        var parameter = attendee.get_first_parameter (
            ICal.ParameterKind.PARTSTAT_PARAMETER);
        assert (parameter != null);
        return parameter.get_partstat ();
    }
    return ICal.ParameterPartstat.NONE;
}

private void test_response_mutates_only_exact_attendee () {
    try {
        var accepted = EdsCalendarBackend.prepare_response (REQUEST,
            "ALEX@EXAMPLE.NET", CalendarParticipation.ACCEPTED);
        assert (partstat_for (accepted, "alex@example.net") ==
            ICal.ParameterPartstat.ACCEPTED);
        assert (partstat_for (accepted, "maya@example.net") ==
            ICal.ParameterPartstat.ACCEPTED);

        var tentative = EdsCalendarBackend.prepare_response (REQUEST,
            "alex@example.net", CalendarParticipation.TENTATIVE);
        assert (partstat_for (tentative, "alex@example.net") ==
            ICal.ParameterPartstat.TENTATIVE);

        var declined = EdsCalendarBackend.prepare_response (REQUEST,
            "alex@example.net", CalendarParticipation.DECLINED);
        assert (partstat_for (declined, "alex@example.net") ==
            ICal.ParameterPartstat.DECLINED);
    } catch (Error error) {
        GLib.error ("EDS invitation response transform failed: %s", error.message);
    }
}

private void test_response_rejects_unlisted_identity () {
    Error? failure = null;
    try {
        EdsCalendarBackend.prepare_response (REQUEST, "intruder@example.net",
            CalendarParticipation.ACCEPTED);
    } catch (Error error) { failure = error; }
    assert (failure is CalendarError.IDENTITY_NOT_INVITED);
}

private void test_optional_response_flags () {
    assert (EdsCalendarBackend.response_operation_flags (true) ==
        ECal.OperationFlags.NONE);
    assert ((EdsCalendarBackend.response_operation_flags (false) &
        ECal.OperationFlags.DISABLE_ITIP_MESSAGE) != 0);
}

private void test_event_component_preserves_calendar_fields () {
    var start = new DateTime.local (2026, 9, 10, 13, 30, 0);
    var draft = new CalendarEventDraft (" Team sync ", "Agenda", "Room 4",
        start, start.add_minutes (45), false,
        CalendarEventRecurrence.WEEKLY, 2);
    var component = EdsCalendarBackend.event_component (draft,
        "mailficient-test@example.net");
    assert (component.get_uid () == "mailficient-test@example.net");
    assert (component.get_summary () == "Team sync");
    assert (component.get_description () == "Agenda");
    assert (component.get_location () == "Room 4");
    assert (!component.get_dtstart ().is_date ());
    assert (component.get_dtstart ().as_timet () == (time_t) start.to_unix ());
    assert (component.get_dtend ().as_timet () ==
        (time_t) start.add_minutes (45).to_unix ());
    assert (component.count_properties (ICal.PropertyKind.RRULE_PROPERTY) == 1);
}

private void test_all_day_event_uses_exclusive_date_end () {
    var start = new DateTime.local (2026, 9, 12, 0, 0, 0);
    var draft = new CalendarEventDraft ("All day", "", "", start,
        start.add_days (1), true);
    var component = EdsCalendarBackend.event_component (draft, "all-day@example.net");
    assert (component.get_dtstart ().is_date ());
    assert (component.get_dtstart ().get_day () == 12);
    assert (component.get_dtend ().is_date ());
    assert (component.get_dtend ().get_day () == 13);
}

private ICal.Component recurring_component (string rule) {
    var component = new ICal.Component (ICal.ComponentKind.VEVENT_COMPONENT);
    component.set_uid ("recurrence-bound@example.net");
    component.set_dtstart (new ICal.Time.from_timet_with_zone (
        (time_t) 1789045200, 0, ICal.Timezone.get_utc_timezone ()));
    component.add_property (new ICal.Property.rrule (
        new ICal.Recurrence.from_string (rule)));
    return component;
}

private void test_recurrence_expansion_is_bounded () {
    int64 estimate;
    int64 two_years = 2 * 366 * 86400;
    assert (EdsCalendarBackend.recurrence_expansion_is_bounded (
        recurring_component ("FREQ=WEEKLY;INTERVAL=1;BYDAY=MO,WE,FR"),
        two_years, EdsCalendarBackend.MAX_RECURRENCE_EXPANSION,
        out estimate));
    assert (estimate > 0 && estimate <
        EdsCalendarBackend.MAX_RECURRENCE_EXPANSION);

    assert (!EdsCalendarBackend.recurrence_expansion_is_bounded (
        recurring_component ("FREQ=SECONDLY"), two_years,
        EdsCalendarBackend.MAX_RECURRENCE_EXPANSION, out estimate));
    assert (EdsCalendarBackend.recurrence_expansion_is_bounded (
        recurring_component ("FREQ=HOURLY;COUNT=24"), two_years,
        EdsCalendarBackend.MAX_RECURRENCE_EXPANSION, out estimate));
    assert (estimate <= 25);
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/calendar/eds/exact-attendee-transform",
        test_response_mutates_only_exact_attendee);
    Test.add_func ("/calendar/eds/rejects-unlisted-identity",
        test_response_rejects_unlisted_identity);
    Test.add_func ("/calendar/eds/optional-response-flags",
        test_optional_response_flags);
    Test.add_func ("/calendar/eds/event-component-fields",
        test_event_component_preserves_calendar_fields);
    Test.add_func ("/calendar/eds/all-day-exclusive-end",
        test_all_day_event_uses_exclusive_date_end);
    Test.add_func ("/calendar/eds/recurrence-expansion-bound",
        test_recurrence_expansion_is_bounded);
    return Test.run ();
}
