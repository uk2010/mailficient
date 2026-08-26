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

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/calendar/eds/exact-attendee-transform",
        test_response_mutates_only_exact_attendee);
    Test.add_func ("/calendar/eds/rejects-unlisted-identity",
        test_response_rejects_unlisted_identity);
    Test.add_func ("/calendar/eds/optional-response-flags",
        test_optional_response_flags);
    return Test.run ();
}
