namespace Mailficient {
// Today and Events are calendar projections. They intentionally do not read
// or write CacheDatabase task rows: Evolution Data Server is the sole event
// store shared with GNOME Calendar.
public class TaskView : Gtk.Box {
    public signal void toast_requested (string message);
    public signal void operation_failed (Error error);
    public signal void event_changed ();

    private CalendarIntegrationService service;
    private TaskViewMode mode = TaskViewMode.TODAY;
    private Gtk.Label heading = new Gtk.Label ("");
    private Gtk.Label summary = new Gtk.Label ("");
    private Gtk.ListBox event_list = new Gtk.ListBox ();
    private Gtk.Stack state_stack = new Gtk.Stack ();
    private Adw.StatusPage empty_page = new Adw.StatusPage ();
    private Gtk.Box view_header = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
    private Gtk.Box header_labels = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
    private Adw.ButtonContent add_content = new Adw.ButtonContent ();
    private Gee.ArrayList<CalendarEventOccurrence> loaded_events =
        new Gee.ArrayList<CalendarEventOccurrence> ();
    private string query = "";
    private Cancellable? reload_cancellable;
    private uint reload_generation;

    public TaskView (CalendarIntegrationService service) {
        Object (orientation: Gtk.Orientation.VERTICAL, spacing: 0);
        this.service = service;
        service.calendars_changed.connect (() => {
            if (get_mapped ()) reload ();
        });
        add_css_class ("task-view");

        view_header.add_css_class ("task-view-header");
        view_header.margin_start = 24; view_header.margin_end = 24;
        view_header.margin_top = 20; view_header.margin_bottom = 14;
        header_labels.hexpand = true;
        heading.xalign = 0; heading.ellipsize = Pango.EllipsizeMode.END;
        heading.add_css_class ("title-1"); header_labels.append (heading);
        summary.xalign = 0; summary.ellipsize = Pango.EllipsizeMode.END;
        summary.add_css_class ("dim-label"); header_labels.append (summary);
        view_header.append (header_labels);
        add_content.icon_name = "appointment-new-symbolic";
        add_content.label = "New Event";
        var add = new Gtk.Button ();
        add.child = add_content; add.add_css_class ("suggested-action");
        add.tooltip_text = "Create an event in GNOME Calendar";
        Accessibility.label (add, "Create a new calendar event");
        add.sensitive = service.can_manage_events;
        add.clicked.connect (() => edit_event.begin (null, null));
        view_header.append (add);
        append (view_header);

        event_list.selection_mode = Gtk.SelectionMode.NONE;
        event_list.show_separators = false;
        event_list.valign = Gtk.Align.START;
        var list_clamp = new Adw.Clamp ();
        list_clamp.maximum_size = 760; list_clamp.valign = Gtk.Align.START;
        list_clamp.margin_start = 24; list_clamp.margin_end = 24;
        list_clamp.margin_top = 4; list_clamp.margin_bottom = 24;
        list_clamp.child = event_list;
        var scroller = new Gtk.ScrolledWindow ();
        scroller.hscrollbar_policy = Gtk.PolicyType.NEVER;
        scroller.child = list_clamp;

        empty_page.icon_name = "calendar-agenda-symbolic";
        state_stack.hexpand = true; state_stack.vexpand = true;
        state_stack.transition_type = Gtk.StackTransitionType.CROSSFADE;
        state_stack.add_named (scroller, "events");
        state_stack.add_named (empty_page, "empty");
        append (state_stack);
        set_mode (TaskViewMode.TODAY);
    }

    public void set_compact_layout (bool compact) {
        view_header.spacing = compact ? 8 : 12;
        view_header.margin_start = compact ? 12 : 24;
        view_header.margin_end = compact ? 12 : 24;
        view_header.margin_top = compact ? 12 : 20;
        view_header.margin_bottom = compact ? 10 : 14;
        add_content.label = compact ? "New" : "New Event";
    }

    public void set_mode (TaskViewMode mode) {
        this.mode = mode;
        heading.label = mode == TaskViewMode.TODAY ? "Today" : "Events";
        empty_page.title = mode == TaskViewMode.TODAY ?
            "No events today" : "No upcoming events";
        empty_page.description = "Events are read directly from GNOME Calendar.";
        // Always reload on navigation so changes made in GNOME Calendar are
        // visible immediately when the user returns.
        reload ();
    }

    public void set_query (string query) {
        if (this.query == query) return;
        this.query = query;
        render ();
    }

    public void new_task () { edit_event.begin (null, null); }

    // CalendarView delegates its editor actions here so Today, Events, and
    // the embedded Calendar page share one validated EDS-backed editor.
    public void edit_existing_event (CalendarEventOccurrence event) {
        edit_event.begin (event, null);
    }

    public void delete_existing_event (CalendarEventOccurrence event) {
        confirm_delete.begin (event);
    }

    public void create_from_message (Message message) {
        edit_event.begin (null, message);
    }

    public void reload () {
        reload_async.begin ();
    }

    private async void reload_async () {
        reload_generation++;
        uint generation = reload_generation;
        if (reload_cancellable != null) reload_cancellable.cancel ();
        var cancellable = new Cancellable ();
        reload_cancellable = cancellable;
        summary.label = "Loading GNOME Calendar…";

        if (!service.can_manage_events) {
            loaded_events.clear ();
            empty_page.title = "GNOME Calendar events unavailable";
            empty_page.description =
                "This build does not include Evolution Data Server calendar support.";
            summary.label = "Evolution Data Server is required";
            render ();
            return;
        }

        DateTime now = new DateTime.now_local ();
        var day_start = new DateTime.local (now.get_year (), now.get_month (),
            now.get_day_of_month (), 0, 0, 0);
        DateTime range_start = day_start;
        DateTime range_end = mode == TaskViewMode.TODAY ?
            day_start.add_days (1) :
            day_start.add_years (CalendarIntegrationService.EVENT_LOOKAHEAD_YEARS);
        try {
            var events = yield service.list_events (range_start, range_end,
                cancellable);
            if (cancellable.is_cancelled () || generation != reload_generation)
                return;
            loaded_events = events;
            render ();
        } catch (Error error) {
            if (error is IOError.CANCELLED || generation != reload_generation)
                return;
            loaded_events.clear ();
            summary.label = "Calendar events could not be loaded";
            empty_page.title = "Could not read GNOME Calendar";
            empty_page.description = error.message;
            show_state ("empty");
            operation_failed (error);
        } finally {
            if (reload_cancellable == cancellable)
                reload_cancellable = null;
        }
    }

    private void render () {
        Gtk.ListBoxRow? existing;
        while ((existing = event_list.get_row_at_index (0)) != null)
            event_list.remove (existing);

        string needle = query.strip ().down ();
        int visible_count = 0;
        string previous_date = "";
        foreach (var event in loaded_events) {
            if (needle != "" && !(event.summary.down ().contains (needle) ||
                event.description.down ().contains (needle) ||
                event.location.down ().contains (needle) ||
                event.calendar_name.down ().contains (needle))) continue;
            var row = build_row (event);
            string date = event.start.format ("%F");
            if (mode == TaskViewMode.PLANNED && date != previous_date)
                row.set_header (date_header (event.start));
            previous_date = date;
            event_list.append (row);
            visible_count++;
        }
        show_state (visible_count == 0 ? "empty" : "events");
        if (service.can_manage_events) {
            string count = visible_count == 1 ? "1 event" :
                "%d events".printf (visible_count);
            summary.label = count + " · GNOME Calendar";
            empty_page.title = mode == TaskViewMode.TODAY ?
                "No events today" : "No upcoming events";
            empty_page.description = query.strip () == "" ?
                "Events are read directly from GNOME Calendar." :
                "No calendar events match this search.";
        }
    }

    private Gtk.ListBoxRow build_row (CalendarEventOccurrence event) {
        var row = new Gtk.ListBoxRow ();
        row.selectable = false; row.activatable = false;
        row.add_css_class ("card"); row.add_css_class ("task-row");
        row.margin_start = 2; row.margin_end = 2;
        row.margin_top = 4; row.margin_bottom = 4;

        var content = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
        content.margin_start = 14; content.margin_end = 10;
        content.margin_top = 9; content.margin_bottom = 9;
        var event_icon = new Gtk.Image.from_icon_name (
            event.all_day ? "calendar-agenda-symbolic" :
                "appointment-soon-symbolic");
        event_icon.valign = Gtk.Align.START;
        event_icon.add_css_class ("dim-label");
        content.append (event_icon);

        var body = new Gtk.Box (Gtk.Orientation.VERTICAL, 4);
        body.hexpand = true;
        var title = new Gtk.Label (event.summary);
        title.xalign = 0; title.wrap = true;
        title.wrap_mode = Pango.WrapMode.WORD_CHAR;
        title.add_css_class ("task-title"); body.append (title);
        var metadata = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        metadata.add_css_class ("task-metadata");
        metadata.append (metadata_label (event_time_label (event),
            event.all_day ? "calendar-agenda-symbolic" : "alarm-symbolic"));
        if (event.calendar_name.strip () != "")
            metadata.append (metadata_label (event.calendar_name,
                "x-office-calendar-symbolic"));
        if (event.location.strip () != "")
            metadata.append (metadata_label (event.location,
                "mark-location-symbolic"));
        if (event.recurring)
            metadata.append (metadata_label ("Repeats",
                "media-playlist-repeat-symbolic"));
        body.append (metadata);
        if (event.description.strip () != "") {
            var description = new Gtk.Label (event.description.strip ());
            description.xalign = 0;
            description.ellipsize = Pango.EllipsizeMode.END;
            description.lines = 1; description.add_css_class ("dim-label");
            body.append (description);
        }
        content.append (body);

        var open = new Gtk.Button.from_icon_name ("x-office-calendar-symbolic");
        open.add_css_class ("flat"); open.valign = Gtk.Align.CENTER;
        open.tooltip_text = "Open GNOME Calendar";
        Accessibility.label (open,
            "Open " + event.summary + " in GNOME Calendar");
        open.clicked.connect (() => open_calendar ()); content.append (open);

        if (event.writable) {
            var edit = new Gtk.Button.from_icon_name ("document-edit-symbolic");
            edit.add_css_class ("flat"); edit.valign = Gtk.Align.CENTER;
            edit.tooltip_text = event.recurring ?
                "Edit this series in GNOME Calendar" : "Edit event";
            Accessibility.label (edit, "Edit " + event.summary);
            edit.clicked.connect (() => {
                if (event.recurring || spans_multiple_dates (event))
                    open_calendar ();
                else edit_event.begin (event, null);
            });
            content.append (edit);

            var remove = new Gtk.Button.from_icon_name ("user-trash-symbolic");
            remove.add_css_class ("flat"); remove.valign = Gtk.Align.CENTER;
            remove.tooltip_text = event.recurring ?
                "Delete event series" : "Delete event";
            Accessibility.label (remove, "Delete " + event.summary);
            remove.clicked.connect (() => confirm_delete.begin (event));
            content.append (remove);
        }
        row.child = content;
        return row;
    }

    private Gtk.Widget date_header (DateTime date) {
        DateTime now = new DateTime.now_local ();
        string today = now.format ("%F");
        string tomorrow = now.add_days (1).format ("%F");
        string key = date.format ("%F");
        string label = key == today ? "Today" :
            (key == tomorrow ? "Tomorrow" :
                date.format ("%A, %b %e, %Y").strip ());
        var header = new Gtk.Label (label);
        header.xalign = 0; header.add_css_class ("heading");
        header.margin_start = 8; header.margin_end = 8;
        header.margin_top = 12; header.margin_bottom = 2;
        Accessibility.label (header, label + " events");
        return header;
    }

    private Gtk.Widget metadata_label (string text, string icon_name) {
        var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 3);
        var icon = new Gtk.Image.from_icon_name (icon_name);
        icon.pixel_size = 13;
        icon.accessible_role = Gtk.AccessibleRole.PRESENTATION;
        box.append (icon);
        var label = new Gtk.Label (text);
        label.add_css_class ("caption");
        label.ellipsize = Pango.EllipsizeMode.END;
        box.append (label);
        return box;
    }

    private async void edit_event (CalendarEventOccurrence? event,
                                   Message? source) {
        DateTime now = new DateTime.now_local ();
        int next_hour = (now.get_hour () + 1) % 24;
        DateTime initial_start = event != null ? event.start :
            new DateTime.local (now.get_year (), now.get_month (),
                now.get_day_of_month (), next_hour, 0, 0);
        DateTime initial_end = event != null ? event.end :
            initial_start.add_hours (1);

        var title = new Adw.EntryRow (); title.title = "Event";
        if (event != null) title.text = event.summary;
        else if (source != null) title.text = source.subject.strip () == "" ?
            "Event from email" : source.subject.strip ();
        var location = new Adw.EntryRow (); location.title = "Location";
        location.text = event != null ? event.location : "";
        var notes = new Adw.EntryRow (); notes.title = "Notes";
        if (event != null) notes.text = event.description;
        else if (source != null) notes.text =
            "Created from an email from %s <%s>.".printf (
                source.sender_name, source.sender_address);
        var details = new Adw.PreferencesGroup ();
        details.add (title); details.add (location); details.add (notes);

        var date_label = new Gtk.Label ("Date");
        date_label.xalign = 0; date_label.add_css_class ("heading");
        var calendar = new Gtk.Calendar ();
        calendar.show_day_names = true; calendar.show_heading = true;
        calendar.select_day (initial_start);
        Accessibility.label (calendar, "Event date");

        var all_day = new Adw.SwitchRow ();
        all_day.title = "All-day event";
        all_day.active = event != null && event.all_day;
        var start_hour = new Adw.SpinRow.with_range (0, 23, 1);
        start_hour.title = "Starts at hour";
        start_hour.value = initial_start.get_hour ();
        var start_minute = new Adw.SpinRow.with_range (0, 59, 5);
        start_minute.title = "Start minute";
        start_minute.value = initial_start.get_minute ();
        var end_hour = new Adw.SpinRow.with_range (0, 23, 1);
        end_hour.title = "Ends at hour";
        end_hour.value = initial_end.get_hour ();
        var end_minute = new Adw.SpinRow.with_range (0, 59, 5);
        end_minute.title = "End minute";
        end_minute.value = initial_end.get_minute ();
        all_day.notify["active"].connect (() => {
            bool sensitive = !all_day.active;
            start_hour.sensitive = sensitive;
            start_minute.sensitive = sensitive;
            end_hour.sensitive = sensitive;
            end_minute.sensitive = sensitive;
        });
        bool time_sensitive = !all_day.active;
        start_hour.sensitive = time_sensitive;
        start_minute.sensitive = time_sensitive;
        end_hour.sensitive = time_sensitive;
        end_minute.sensitive = time_sensitive;

        var recurrence_model = new Gtk.StringList (null);
        foreach (var label in new string[] {
            "Does not repeat", "Daily", "Weekly", "Monthly", "Yearly"
        }) recurrence_model.append (label);
        var recurrence = new Adw.ComboRow ();
        recurrence.title = "Repeat"; recurrence.model = recurrence_model;
        recurrence.selected = 0;
        var interval = new Adw.SpinRow.with_range (1, 99, 1);
        interval.title = "Repeat every";
        interval.subtitle = "Number of days, weeks, months, or years";
        interval.value = 1; interval.sensitive = false;
        recurrence.notify["selected"].connect (() =>
            interval.sensitive = recurrence.selected != 0);

        var schedule = new Adw.PreferencesGroup ();
        schedule.add (all_day); schedule.add (start_hour);
        schedule.add (start_minute); schedule.add (end_hour);
        schedule.add (end_minute); schedule.add (recurrence);
        schedule.add (interval);
        var editor = new Gtk.Box (Gtk.Orientation.VERTICAL, 10);
        editor.set_size_request (440, -1);
        editor.append (details); editor.append (date_label);
        editor.append (calendar); editor.append (schedule);
        var source_note = new Gtk.Label (
            "This event is saved directly to your default GNOME Calendar.");
        source_note.wrap = true; source_note.xalign = 0;
        source_note.add_css_class ("dim-label"); editor.append (source_note);
        var scroller = new Gtk.ScrolledWindow ();
        scroller.set_size_request (460, 560);
        scroller.hscrollbar_policy = Gtk.PolicyType.NEVER;
        scroller.child = editor;
        var dialog = new Adw.AlertDialog (
            event == null ? "New Event" : "Edit Event",
            "Evolution Data Server is the authoritative event store.");
        dialog.add_css_class ("task-editor-dialog");
        dialog.extra_child = scroller;
        dialog.add_response ("cancel", "Cancel");
        dialog.add_response ("save", "Save");
        dialog.default_response = "save"; dialog.close_response = "cancel";
        var parent = get_root () as Gtk.Widget;
        if (parent == null || (yield dialog.choose (parent, null)) != "save")
            return;

        DateTime date = calendar.get_date ();
        DateTime start;
        DateTime end;
        if (all_day.active) {
            start = new DateTime.local (date.get_year (), date.get_month (),
                date.get_day_of_month (), 0, 0, 0);
            end = start.add_days (1);
        } else {
            start = new DateTime.local (date.get_year (), date.get_month (),
                date.get_day_of_month (), (int) start_hour.value,
                (int) start_minute.value, 0);
            end = new DateTime.local (date.get_year (), date.get_month (),
                date.get_day_of_month (), (int) end_hour.value,
                (int) end_minute.value, 0);
            if (end.compare (start) <= 0) end = end.add_days (1);
        }
        var draft = new CalendarEventDraft (title.text, notes.text,
            location.text, start, end, all_day.active,
            (CalendarEventRecurrence) recurrence.selected,
            (int) interval.value);
        try {
            if (event == null) yield service.create_event (draft);
            else yield service.update_event (event, draft);
            toast_requested (event == null ?
                "Event saved to GNOME Calendar" :
                "Event updated in GNOME Calendar");
            event_changed ();
            reload ();
        } catch (Error error) { operation_failed (error); }
    }

    private async void confirm_delete (CalendarEventOccurrence event) {
        string heading = event.recurring ?
            "Delete event series?" : "Delete event?";
        var dialog = new Adw.AlertDialog (heading, event.summary);
        dialog.add_response ("cancel", "Cancel");
        dialog.add_response ("delete", "Delete");
        dialog.set_response_appearance ("delete",
            Adw.ResponseAppearance.DESTRUCTIVE);
        dialog.default_response = "cancel"; dialog.close_response = "cancel";
        var parent = get_root () as Gtk.Widget;
        if (parent == null || (yield dialog.choose (parent, null)) != "delete")
            return;
        try {
            yield service.delete_event (event);
            toast_requested (event.recurring ?
                "Event series deleted from GNOME Calendar" :
                "Event deleted from GNOME Calendar");
            event_changed ();
            reload ();
        } catch (Error error) { operation_failed (error); }
    }

    private void open_calendar () {
        try { service.open_calendar (); }
        catch (Error error) { operation_failed (error); }
    }

    private static string event_time_label (CalendarEventOccurrence event) {
        if (event.all_day) return "All day";
        string start = event.start.format ("%l:%M %p").strip ();
        string end = event.end.format ("%l:%M %p").strip ();
        if (event.start.format ("%F") != event.end.format ("%F"))
            end = event.end.format ("%b %e · %l:%M %p").strip ();
        return start + "–" + end;
    }

    private static bool spans_multiple_dates (
        CalendarEventOccurrence event) {
        if (event.all_day)
            return event.end.compare (event.start.add_days (1)) != 0;
        return event.start.format ("%F") != event.end.format ("%F");
    }

    private void show_state (string name) {
        state_stack.transition_type = get_mapped () ?
            Gtk.StackTransitionType.CROSSFADE : Gtk.StackTransitionType.NONE;
        state_stack.visible_child_name = name;
    }

    ~TaskView () {
        if (reload_cancellable != null) reload_cancellable.cancel ();
    }
}
}
