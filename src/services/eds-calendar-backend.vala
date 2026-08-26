namespace Mailficient {
// Evolution Data Server remains the authoritative calendar store. Mailficient
// submits bounded iTIP objects and new event drafts, then returns the user to
// GNOME Calendar instead of maintaining a parallel event database.
public class EdsCalendarBackend : Object, CalendarBackend {
    public bool can_respond_directly { get { return true; } }

    public async void respond (CalendarInvitation invitation, string identity_email,
                               CalendarParticipation participation, bool send_response,
                               Cancellable? cancellable = null) throws Error {
        if (cancellable != null) cancellable.set_error_if_cancelled ();
        var calendar = prepare_response (invitation.raw_icalendar,
            identity_email, participation);
        ECal.Client client = yield default_client (cancellable);
        ECal.OperationFlags flags = response_operation_flags (send_response);
        try {
            yield client.receive_objects (calendar, flags, cancellable);
        } catch (Error error) {
            if (error is IOError.CANCELLED) throw error;
            throw new CalendarError.RESPONSE_FAILED (
                "The calendar could not record this response: %s".printf (error.message));
        }
    }

    internal static ICal.Component prepare_response (
        string raw_icalendar, string identity_email,
        CalendarParticipation participation) throws CalendarError {
        var calendar = new ICal.Component.from_string (raw_icalendar);
        if (calendar == null || !calendar.is_valid ())
            throw new CalendarError.INVALID_INVITATION (
                "Evolution Data Server could not parse this invitation");
        ICal.ParameterPartstat partstat = to_ical_participation (participation);
        bool matched = false;
        for (ICal.Component? event = calendar.get_first_component (
                 ICal.ComponentKind.VEVENT_COMPONENT);
             event != null;
             event = calendar.get_next_component (ICal.ComponentKind.VEVENT_COMPONENT)) {
            for (ICal.Property? attendee = event.get_first_property (
                     ICal.PropertyKind.ATTENDEE_PROPERTY);
                 attendee != null;
                 attendee = event.get_next_property (ICal.PropertyKind.ATTENDEE_PROPERTY)) {
                if (CalendarInvitation.normalize_email (attendee.get_attendee ()) !=
                    CalendarInvitation.normalize_email (identity_email)) continue;
                attendee.remove_parameter_by_kind (ICal.ParameterKind.PARTSTAT_PARAMETER);
                attendee.add_parameter (new ICal.Parameter.partstat (partstat));
                matched = true;
            }
        }
        if (!matched)
            throw new CalendarError.IDENTITY_NOT_INVITED (
                "Evolution Data Server could not match the invited mail identity");
        return calendar;
    }

    internal static ECal.OperationFlags response_operation_flags (bool send_response) {
        return send_response ? ECal.OperationFlags.NONE :
            ECal.OperationFlags.DISABLE_ITIP_MESSAGE;
    }

    public async CalendarCreateDisposition create_meeting (
        CalendarMeetingDraft meeting, Cancellable? cancellable = null) throws Error {
        if (cancellable != null) cancellable.set_error_if_cancelled ();
        string payload = DesktopCalendarBackend.meeting_icalendar (meeting);
        var calendar = new ICal.Component.from_string (payload);
        ICal.Component? event = calendar == null ? null :
            calendar.get_first_component (ICal.ComponentKind.VEVENT_COMPONENT);
        if (event == null || !event.is_valid ())
            throw new CalendarError.CREATE_FAILED (
                "The meeting draft could not be converted to an iCalendar event");
        ECal.Client client = yield default_client (cancellable);
        try {
            string uid;
            // The event is a draft for review in GNOME Calendar. Do not send
            // invitations merely because an email was converted to a meeting.
            yield client.create_object (event.clone (),
                ECal.OperationFlags.DISABLE_ITIP_MESSAGE, cancellable, out uid);
            return CalendarCreateDisposition.CREATED;
        } catch (Error error) {
            if (error is IOError.CANCELLED) throw error;
            throw new CalendarError.CREATE_FAILED (
                "The meeting could not be saved to the default calendar: %s".printf (
                    error.message));
        }
    }

    public void launch_calendar () throws Error {
        GnomeCalendarLauncher.launch ();
    }

    private async ECal.Client default_client (Cancellable? cancellable) throws Error {
        E.SourceRegistry registry;
        try { registry = yield new E.SourceRegistry (cancellable); }
        catch (Error error) {
            if (error is IOError.CANCELLED) throw error;
            throw new CalendarError.NO_CALENDAR (
                "Calendar sources are unavailable: %s".printf (error.message));
        }
        E.Source source = registry.ref_default_calendar ();
        if (!registry.check_enabled (source)) {
            var enabled = registry.list_enabled (E.SOURCE_EXTENSION_CALENDAR);
            if (enabled == null)
                throw new CalendarError.NO_CALENDAR (
                    "No enabled Evolution Data Server calendar is available");
            source = enabled.data;
        }
        try {
            E.Client? base_client = yield ECal.Client.connect (source,
                ECal.ClientSourceType.EVENTS, 10, cancellable);
            var client = base_client as ECal.Client;
            if (client == null)
                throw new CalendarError.NO_CALENDAR (
                    "The default calendar returned an incompatible client");
            if (client.is_readonly ())
                throw new CalendarError.NO_CALENDAR (
                    "The default calendar is read-only; choose a writable default in GNOME Calendar");
            return client;
        } catch (CalendarError error) {
            throw error;
        } catch (Error error) {
            if (error is IOError.CANCELLED) throw error;
            throw new CalendarError.NO_CALENDAR (
                "The default calendar could not be opened: %s".printf (error.message));
        }
    }

    private static ICal.ParameterPartstat to_ical_participation (
        CalendarParticipation participation) throws CalendarError {
        switch (participation) {
        case CalendarParticipation.ACCEPTED: return ICal.ParameterPartstat.ACCEPTED;
        case CalendarParticipation.TENTATIVE: return ICal.ParameterPartstat.TENTATIVE;
        case CalendarParticipation.DECLINED: return ICal.ParameterPartstat.DECLINED;
        default: throw new CalendarError.RESPONSE_FAILED (
            "Choose Accept, Tentative, or Decline");
        }
    }
}
}
