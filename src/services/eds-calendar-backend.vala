namespace Mailficient {
// Evolution Data Server remains the authoritative calendar store. Mailficient
// submits bounded iTIP objects and new event drafts, then returns the user to
// GNOME Calendar instead of maintaining a parallel event database.
public class EdsCalendarBackend : Object, CalendarBackend {
    internal const int MAX_EVENT_OCCURRENCES = 2000;
    internal const int MAX_RECURRENCE_EXPANSION = 8192;
    internal const int MAX_CALENDAR_OBJECT_BYTES = 1024 * 1024;
    internal const int MAX_EVENT_RANGE_YEARS =
        CalendarIntegrationService.EVENT_LOOKAHEAD_YEARS;
    public bool can_respond_directly { get { return true; } }
    public bool can_manage_events { get { return true; } }

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

    public async Gee.ArrayList<CalendarEventOccurrence> list_events (
        DateTime range_start, DateTime range_end,
        Cancellable? cancellable = null) throws Error {
        if (cancellable != null) cancellable.set_error_if_cancelled ();
        DateTime maximum_end = range_start.add_years (MAX_EVENT_RANGE_YEARS);
        if (range_end.compare (range_start) <= 0)
            throw new CalendarError.NO_CALENDAR (
                "The requested calendar range is invalid");
        if (range_end.compare (maximum_end) > 0) range_end = maximum_end;
        E.SourceRegistry registry = yield source_registry (cancellable);
        var sources = registry.list_enabled (E.SOURCE_EXTENSION_CALENDAR);
        if (sources == null)
            throw new CalendarError.NO_CALENDAR (
                "No enabled Evolution Data Server calendar is available");

        var result = new Gee.ArrayList<CalendarEventOccurrence> ();
        Error? last_error = null;
        int connected_sources = 0;
        foreach (var source in sources) {
            if (result.size >= MAX_EVENT_OCCURRENCES) break;
            if (cancellable != null) cancellable.set_error_if_cancelled ();
            try {
                ECal.Client client = yield connect_source (source, false, cancellable);
                connected_sources++;
                string source_uid = source.dup_uid ();
                string calendar_name = source.dup_display_name ();
                string calendar_color = "";
                var selectable = source.get_extension (
                    E.SOURCE_EXTENSION_CALENDAR) as E.SourceSelectable;
                if (selectable != null)
                    calendar_color = selectable.dup_color () ?? "";
                bool writable = !client.is_readonly ();

                // ECalClient expands every matching recurrence into an
                // intermediate collection before it invokes our callback. A
                // result-size check inside the callback therefore cannot stop
                // a hostile SECONDLY rule from exhausting memory. Inspect the
                // exact range first and skip sources whose conservative upper
                // bound exceeds the amount we are willing to expand.
                if (!(yield source_expansion_is_bounded (client, range_start,
                        range_end, cancellable))) {
                    warning ("Calendar %s contains a recurrence expansion that exceeds the safety limit",
                        calendar_name);
                    continue;
                }

                // EDS expands recurring masters and applies detached
                // occurrences here, so Today receives the same instances that
                // GNOME Calendar displays rather than only recurrence masters.
                client.generate_instances_sync (
                    (time_t) range_start.to_unix (),
                    (time_t) range_end.to_unix (), cancellable,
                    (component, instance_start, instance_end, callback_cancel) => {
                        if (callback_cancel != null && callback_cancel.is_cancelled ())
                            return false;
                        if (result.size >= MAX_EVENT_OCCURRENCES) return false;
                        append_occurrence (result, component, instance_start,
                            instance_end, source_uid, calendar_name,
                            calendar_color, writable);
                        return result.size < MAX_EVENT_OCCURRENCES;
                    });
            } catch (Error error) {
                if (error is IOError.CANCELLED) throw error;
                last_error = error;
                warning ("Could not read calendar %s: %s",
                    source.dup_display_name (), error.message);
            }
        }
        if (connected_sources == 0 && last_error != null)
            throw new CalendarError.NO_CALENDAR (
                "Calendar events could not be loaded: %s".printf (
                    last_error.message));
        if (result.size >= MAX_EVENT_OCCURRENCES)
            warning ("Calendar results were limited to %d occurrences",
                MAX_EVENT_OCCURRENCES);
        result.sort ((first, second) => {
            int comparison = first.start.compare (second.start);
            if (comparison != 0) return comparison;
            comparison = first.end.compare (second.end);
            if (comparison != 0) return comparison;
            return strcmp (first.summary, second.summary);
        });
        return result;
    }

    private async bool source_expansion_is_bounded (
        ECal.Client client, DateTime range_start, DateTime range_end,
        Cancellable? cancellable) throws Error {
        string start = range_start.to_utc ().format ("%Y%m%dT%H%M%SZ");
        string end = range_end.to_utc ().format ("%Y%m%dT%H%M%SZ");
        string query = "(occur-in-time-range? (make-time \"%s\") (make-time \"%s\"))".printf (
            start, end);
        SList<ECal.Component> components;
        yield client.get_object_list_as_comps (query, cancellable,
            out components);

        int64 range_seconds = int64.max (1,
            range_end.to_unix () - range_start.to_unix ());
        int64 total = 0;
        foreach (var component in components) {
            if (cancellable != null) cancellable.set_error_if_cancelled ();
            unowned ICal.Component? ical = component.get_icalcomponent ();
            if (ical == null) continue;
            int64 estimate;
            if (!recurrence_expansion_is_bounded (ical, range_seconds,
                    MAX_RECURRENCE_EXPANSION - total, out estimate))
                return false;
            total += estimate;
        }
        return true;
    }

    internal static bool recurrence_expansion_is_bounded (
        ICal.Component component, int64 range_seconds, int64 budget,
        out int64 estimate) {
        estimate = 0;
        if (budget <= 0 || range_seconds <= 0) return false;
        string serialized = component.as_ical_string ();
        if (serialized.length > MAX_CALENDAR_OBJECT_BYTES) return false;

        int rdate_count = component.count_properties (
            ICal.PropertyKind.RDATE_PROPERTY);
        int rule_count = component.count_properties (
            ICal.PropertyKind.RRULE_PROPERTY);
        if (rule_count == 0) {
            estimate = 1 + rdate_count;
            return estimate <= budget;
        }

        int64 total = 1 + rdate_count;
        for (ICal.Property? property = component.get_first_property (
                 ICal.PropertyKind.RRULE_PROPERTY);
             property != null;
             property = component.get_next_property (
                 ICal.PropertyKind.RRULE_PROPERTY)) {
            ICal.Recurrence rule = property.get_rrule ();
            int64 interval = int64.max (1, rule.get_interval ());
            int64 occurrences;
            switch (rule.get_freq ()) {
            case ICal.RecurrenceFrequency.SECONDLY_RECURRENCE:
                occurrences = range_seconds / interval + 2;
                break;
            case ICal.RecurrenceFrequency.MINUTELY_RECURRENCE:
                occurrences = range_seconds / (60 * interval) + 2;
                break;
            case ICal.RecurrenceFrequency.HOURLY_RECURRENCE:
                occurrences = range_seconds / (3600 * interval) + 2;
                break;
            case ICal.RecurrenceFrequency.DAILY_RECURRENCE:
                occurrences = range_seconds / (86400 * interval) + 2;
                break;
            case ICal.RecurrenceFrequency.WEEKLY_RECURRENCE:
                occurrences = range_seconds / (7 * 86400 * interval) + 2;
                break;
            case ICal.RecurrenceFrequency.MONTHLY_RECURRENCE:
                occurrences = range_seconds / (28 * 86400 * interval) + 2;
                break;
            case ICal.RecurrenceFrequency.YEARLY_RECURRENCE:
                occurrences = range_seconds / (365 * 86400 * interval) + 2;
                break;
            default:
                return false;
            }

            // BY* fields can turn one recurrence period into many events.
            // Multiplying all populated fields is deliberately conservative;
            // some combinations are filters, but never underestimating here
            // is more important than accepting an exotic rule.
            int64 factor = 1;
            factor = bounded_factor (factor, populated_by_count (
                rule.get_by_second_array ()),
                budget);
            factor = bounded_factor (factor, populated_by_count (
                rule.get_by_minute_array ()),
                budget);
            factor = bounded_factor (factor, populated_by_count (
                rule.get_by_hour_array ()),
                budget);
            factor = bounded_factor (factor, populated_by_count (
                rule.get_by_month_array ()),
                budget);
            factor = bounded_factor (factor, populated_by_count (
                rule.get_by_month_day_array ()),
                budget);
            factor = bounded_factor (factor, populated_by_count (
                rule.get_by_year_day_array ()),
                budget);
            factor = bounded_factor (factor, populated_by_count (
                rule.get_by_week_no_array ()),
                budget);
            int64 day_factor = populated_by_count (rule.get_by_day_array ());
            if (day_factor > 0) {
                if (rule.get_freq () == ICal.RecurrenceFrequency.MONTHLY_RECURRENCE)
                    day_factor *= 6;
                else if (rule.get_freq () == ICal.RecurrenceFrequency.YEARLY_RECURRENCE)
                    day_factor *= 54;
                factor = bounded_factor (factor, day_factor, budget);
            }
            occurrences = saturated_multiply (occurrences, factor, budget + 1);
            int count = rule.get_count ();
            if (count > 0) occurrences = int64.min (occurrences, count);
            total = saturated_add (total, occurrences, budget + 1);
            if (total > budget) return false;
        }
        estimate = total;
        return true;
    }

    private static int64 populated_by_count (Array<short> values) {
        int64 count = 0;
        for (uint index = 0; index < values.length; index++) {
            if (values.index (index) == (short)
                    ICal.RecurrenceArrayMaxValues.RECURRENCE_ARRAY_MAX)
                break;
            count++;
        }
        return count;
    }

    private static int64 bounded_factor (int64 current, int64 count,
                                         int64 budget) {
        return count <= 0 ? current : saturated_multiply (current, count,
            budget + 1);
    }

    private static int64 saturated_multiply (int64 left, int64 right,
                                              int64 limit) {
        if (left <= 0 || right <= 0) return 0;
        if (left > limit / right) return limit;
        return int64.min (left * right, limit);
    }

    private static int64 saturated_add (int64 left, int64 right,
                                         int64 limit) {
        if (left >= limit || right >= limit || left > limit - right)
            return limit;
        return left + right;
    }

    public async void create_event (CalendarEventDraft draft,
                                    Cancellable? cancellable = null) throws Error {
        ECal.Client client = yield default_client (cancellable);
        var component = event_component (draft,
            "mailficient-%s@local".printf (Uuid.string_random ()));
        try {
            string uid;
            yield client.create_object (component,
                ECal.OperationFlags.DISABLE_ITIP_MESSAGE, cancellable, out uid);
        } catch (Error error) {
            if (error is IOError.CANCELLED) throw error;
            throw new CalendarError.CREATE_FAILED (
                "The event could not be saved to GNOME Calendar: %s".printf (
                    error.message));
        }
    }

    public async void update_event (CalendarEventOccurrence event,
                                    CalendarEventDraft draft,
                                    Cancellable? cancellable = null) throws Error {
        ECal.Client client = yield client_for_source (event.source_uid, true,
            cancellable);
        try {
            ICal.Component component;
            yield client.get_object (event.uid, null, cancellable,
                out component);
            apply_event_draft (component, draft);
            yield client.modify_object (component, ECal.ObjModType.ALL,
                ECal.OperationFlags.DISABLE_ITIP_MESSAGE, cancellable);
        } catch (Error error) {
            if (error is IOError.CANCELLED) throw error;
            throw new CalendarError.CREATE_FAILED (
                "The event could not be updated in GNOME Calendar: %s".printf (
                    error.message));
        }
    }

    public async void delete_event (CalendarEventOccurrence event,
                                    Cancellable? cancellable = null) throws Error {
        ECal.Client client = yield client_for_source (event.source_uid, true,
            cancellable);
        try {
            // The Events editor treats a recurring item as one series. Delete
            // the series explicitly rather than guessing at an occurrence RID.
            yield client.remove_object (event.uid, null, ECal.ObjModType.ALL,
                ECal.OperationFlags.DISABLE_ITIP_MESSAGE, cancellable);
        } catch (Error error) {
            if (error is IOError.CANCELLED) throw error;
            throw new CalendarError.CREATE_FAILED (
                "The event could not be deleted from GNOME Calendar: %s".printf (
                    error.message));
        }
    }

    internal static ICal.Component event_component (CalendarEventDraft draft,
                                                     string uid) {
        var component = new ICal.Component (
            ICal.ComponentKind.VEVENT_COMPONENT);
        component.set_uid (uid);
        component.set_dtstamp (calendar_time (
            new DateTime.now_utc (), false));
        apply_event_draft (component, draft);
        return component;
    }

    internal static void apply_event_draft (ICal.Component component,
                                            CalendarEventDraft draft) {
        component.set_summary (draft.summary.strip ());
        component.set_description (draft.description.strip ());
        component.set_location (draft.location.strip ());
        component.set_dtstart (calendar_time (draft.start, draft.all_day));
        component.set_dtend (calendar_time (draft.end, draft.all_day));

        ICal.Property? rule;
        while ((rule = component.get_first_property (
                    ICal.PropertyKind.RRULE_PROPERTY)) != null)
            component.remove_property (rule);
        if (draft.recurrence != CalendarEventRecurrence.NONE) {
            string frequency;
            switch (draft.recurrence) {
            case CalendarEventRecurrence.DAILY: frequency = "DAILY"; break;
            case CalendarEventRecurrence.WEEKLY: frequency = "WEEKLY"; break;
            case CalendarEventRecurrence.MONTHLY: frequency = "MONTHLY"; break;
            case CalendarEventRecurrence.YEARLY: frequency = "YEARLY"; break;
            default: frequency = "DAILY"; break;
            }
            var recurrence = new ICal.Recurrence.from_string (
                "FREQ=%s;INTERVAL=%d".printf (frequency,
                    draft.recurrence_interval));
            component.add_property (new ICal.Property.rrule (recurrence));
        }
    }

    private static ICal.Time calendar_time (DateTime value, bool all_day) {
        if (!all_day)
            return new ICal.Time.from_timet_with_zone (
                (time_t) value.to_unix (), 0,
                ICal.Timezone.get_utc_timezone ());
        var result = new ICal.Time ();
        result.set_date (value.get_year (), value.get_month (),
            value.get_day_of_month ());
        result.set_is_date (true);
        return result;
    }

    private static void append_occurrence (
        Gee.ArrayList<CalendarEventOccurrence> result,
        ICal.Component component, ICal.Time instance_start,
        ICal.Time instance_end, string source_uid, string calendar_name,
        string calendar_color, bool writable) {
        if (component.get_status () == ICal.PropertyStatus.CANCELLED) return;
        string? raw_uid = component.get_uid ();
        if (raw_uid == null || raw_uid.strip () == "" || raw_uid.length > 1024)
            return;
        string? raw_summary = component.get_summary ();
        string? raw_description = component.get_description ();
        string? raw_location = component.get_location ();
        var recurrence = component.get_recurrenceid ();
        string recurrence_id = recurrence == null || recurrence.is_null_time () ?
            "" : recurrence.as_ical_string ();
        bool all_day = instance_start.is_date ();
        DateTime start = calendar_datetime (instance_start, all_day);
        DateTime end = calendar_datetime (instance_end, all_day);
        bool recurring = component.count_properties (
            ICal.PropertyKind.RRULE_PROPERTY) > 0 || recurrence_id != "";
        result.add (new CalendarEventOccurrence (
            CalendarIntegrationService.bounded_event_text (source_uid, 512), raw_uid,
            CalendarIntegrationService.bounded_event_text (recurrence_id, 1024),
            CalendarIntegrationService.bounded_event_text (calendar_name, 256),
            CalendarIntegrationService.bounded_event_text (calendar_color, 64),
            raw_summary == null || raw_summary.strip () == "" ?
                "Untitled event" : CalendarIntegrationService.bounded_event_text (
                    raw_summary.strip (), CalendarIntegrationService.MAX_EVENT_TITLE_BYTES),
            CalendarIntegrationService.bounded_event_text (raw_description ?? "",
                CalendarIntegrationService.MAX_EVENT_DESCRIPTION_BYTES),
            CalendarIntegrationService.bounded_event_text (raw_location ?? "",
                CalendarIntegrationService.MAX_EVENT_LOCATION_BYTES), start, end,
            all_day, recurring, writable));
    }

    private static DateTime calendar_datetime (ICal.Time value,
                                               bool all_day) {
        if (all_day)
            return new DateTime.local (value.get_year (), value.get_month (),
                value.get_day (), 0, 0, 0);
        ICal.Timezone? zone = value.get_timezone ();
        return new DateTime.from_unix_local ((int64)
            value.as_timet_with_zone (zone));
    }

    public void launch_calendar () throws Error {
        GnomeCalendarLauncher.launch ();
    }

    private async E.SourceRegistry source_registry (
        Cancellable? cancellable) throws Error {
        try { return yield new E.SourceRegistry (cancellable); }
        catch (Error error) {
            if (error is IOError.CANCELLED) throw error;
            throw new CalendarError.NO_CALENDAR (
                "Calendar sources are unavailable: %s".printf (error.message));
        }
    }

    private async ECal.Client default_client (Cancellable? cancellable) throws Error {
        E.SourceRegistry registry = yield source_registry (cancellable);
        E.Source source = registry.ref_default_calendar ();
        if (!registry.check_enabled (source)) {
            var enabled = registry.list_enabled (E.SOURCE_EXTENSION_CALENDAR);
            if (enabled == null)
                throw new CalendarError.NO_CALENDAR (
                    "No enabled Evolution Data Server calendar is available");
            source = enabled.data;
        }
        return yield connect_source (source, true, cancellable);
    }

    private async ECal.Client client_for_source (string source_uid,
                                                 bool require_writable,
                                                 Cancellable? cancellable)
        throws Error {
        E.SourceRegistry registry = yield source_registry (cancellable);
        E.Source? source = registry.ref_source (source_uid);
        if (source == null || !registry.check_enabled (source))
            throw new CalendarError.NO_CALENDAR (
                "The event's calendar is no longer available");
        return yield connect_source (source, require_writable, cancellable);
    }

    private async ECal.Client connect_source (E.Source source,
                                              bool require_writable,
                                              Cancellable? cancellable)
        throws Error {
        try {
            E.Client? base_client = yield ECal.Client.connect (source,
                ECal.ClientSourceType.EVENTS, 10, cancellable);
            var client = base_client as ECal.Client;
            if (client == null)
                throw new CalendarError.NO_CALENDAR (
                    "The calendar returned an incompatible client");
            if (require_writable && client.is_readonly ())
                throw new CalendarError.NO_CALENDAR (
                    "The calendar is read-only; choose a writable calendar in GNOME Calendar");
            return client;
        } catch (CalendarError error) {
            throw error;
        } catch (Error error) {
            if (error is IOError.CANCELLED) throw error;
            throw new CalendarError.NO_CALENDAR (
                "The calendar could not be opened: %s".printf (error.message));
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
