namespace Mailficient {

// Embedded calendar workspace.  Evolution Data Server remains the only event
// store; this widget is a presentation and navigation layer over the same
// CalendarIntegrationService used by Today and Events.
public class CalendarView : Gtk.Box {
    public signal void create_requested ();
    public signal void edit_requested (CalendarEventOccurrence event);
    public signal void delete_requested (CalendarEventOccurrence event);
    public signal void operation_failed (Error error);

    private CalendarIntegrationService service;
    private Gtk.Label month_label = new Gtk.Label ("");
    private Gtk.Label summary = new Gtk.Label ("");
    private Gtk.ListBox event_list = new Gtk.ListBox ();
    private Gtk.Grid month_grid = new Gtk.Grid ();
    private Gtk.Label state_label = new Gtk.Label ("");
    private DateTime month;
    private DateTime selected_day;
    private Gee.ArrayList<CalendarEventOccurrence> loaded_events =
        new Gee.ArrayList<CalendarEventOccurrence> ();
    private string query = "";
    private Cancellable? reload_cancellable;
    private uint reload_generation;
    private uint refresh_source;

    public CalendarView (CalendarIntegrationService service) {
        Object (orientation: Gtk.Orientation.VERTICAL, spacing: 0);
        this.service = service;
        add_css_class ("calendar-view");

        DateTime now = new DateTime.now_local ();
        month = new DateTime.local (now.get_year (), now.get_month (), 1, 12, 0, 0);
        selected_day = new DateTime.local (now.get_year (), now.get_month (),
            now.get_day_of_month (), 12, 0, 0);

        var header = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10);
        header.add_css_class ("calendar-view-header");
        header.margin_start = 18; header.margin_end = 18;
        header.margin_top = 16; header.margin_bottom = 12;
        var heading = new Gtk.Label ("Calendar");
        heading.xalign = 0; heading.add_css_class ("title-1"); heading.hexpand = true;
        header.append (heading);
        var previous = new Gtk.Button.from_icon_name ("go-previous-symbolic");
        previous.add_css_class ("flat"); previous.tooltip_text = "Previous month";
        Accessibility.label (previous, "Previous month");
        previous.clicked.connect (() => change_month (-1));
        header.append (previous);
        month_label.add_css_class ("heading");
        month_label.set_size_request (145, -1);
        header.append (month_label);
        var next = new Gtk.Button.from_icon_name ("go-next-symbolic");
        next.add_css_class ("flat"); next.tooltip_text = "Next month";
        Accessibility.label (next, "Next month");
        next.clicked.connect (() => change_month (1));
        header.append (next);
        var today = new Gtk.Button.with_label ("Today");
        today.add_css_class ("flat"); today.tooltip_text = "Show this month";
        today.clicked.connect (() => {
            DateTime current = new DateTime.now_local ();
            month = new DateTime.local (current.get_year (), current.get_month (), 1, 12, 0, 0);
            selected_day = new DateTime.local (current.get_year (), current.get_month (),
                current.get_day_of_month (), 12, 0, 0);
            reload ();
        });
        header.append (today);
        append (header);

        summary.xalign = 0;
        summary.margin_start = 20; summary.margin_end = 20; summary.margin_bottom = 8;
        summary.add_css_class ("dim-label");
        append (summary);

        var panes = new Gtk.Paned (Gtk.Orientation.HORIZONTAL);
        panes.set_position (390);
        panes.set_wide_handle (true);
        panes.hexpand = true; panes.vexpand = true;

        var agenda = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);
        agenda.margin_start = 18; agenda.margin_end = 10;
        agenda.margin_bottom = 18;
        var agenda_header = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        var agenda_title = new Gtk.Label ("Agenda");
        agenda_title.xalign = 0; agenda_title.hexpand = true;
        agenda_title.add_css_class ("heading");
        agenda_header.append (agenda_title);
        var add = new Gtk.Button.with_label ("Add Event");
        add.add_css_class ("suggested-action");
        add.clicked.connect (() => create_requested ());
        Accessibility.label (add, "Add calendar event");
        agenda_header.append (add);
        agenda.append (agenda_header);
        event_list.selection_mode = Gtk.SelectionMode.NONE;
        event_list.show_separators = false;
        var agenda_scroller = new Gtk.ScrolledWindow ();
        agenda_scroller.hscrollbar_policy = Gtk.PolicyType.NEVER;
        agenda_scroller.vexpand = true;
        agenda_scroller.child = event_list;
        agenda.append (agenda_scroller);
        panes.set_start_child (agenda);

        var month_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);
        month_box.margin_start = 12; month_box.margin_end = 18; month_box.margin_bottom = 18;
        var month_hint = new Gtk.Label ("Select a day to view its events");
        month_hint.xalign = 0; month_hint.add_css_class ("dim-label");
        month_box.append (month_hint);
        month_grid.column_homogeneous = true; month_grid.row_homogeneous = true;
        month_grid.column_spacing = 4; month_grid.row_spacing = 4;
        month_grid.hexpand = true; month_grid.vexpand = true;
        month_box.append (month_grid);
        panes.set_end_child (month_box);
        append (panes);

        state_label.visible = false;
        append (state_label);
        refresh_source = Timeout.add_seconds (15, () => {
            if (get_mapped ()) reload ();
            return Source.CONTINUE;
        });
        reload ();
    }

    public void set_compact_layout (bool compact) {
        panes_spacing (compact ? 8 : 18);
    }

    private void panes_spacing (int margin) {
        // Keep the workspace usable in narrow windows without changing the
        // authoritative data or the month/agenda interaction model.
        month_grid.column_spacing = margin > 10 ? 4 : 2;
        month_grid.row_spacing = margin > 10 ? 4 : 2;
    }

    public void set_query (string value) {
        query = value;
        render_agenda ();
    }

    public void reload () {
        reload_async.begin ();
    }

    private void change_month (int amount) {
        month = month.add_months (amount);
        selected_day = new DateTime.local (month.get_year (), month.get_month (), 1, 12, 0, 0);
        reload ();
    }

    private async void reload_async () {
        reload_generation++;
        uint generation = reload_generation;
        if (reload_cancellable != null) reload_cancellable.cancel ();
        var cancellable = new Cancellable ();
        reload_cancellable = cancellable;
        month_label.label = month.format ("%B %Y");
        summary.label = "Loading events from GNOME Calendar…";
        if (!service.can_manage_events) {
            loaded_events.clear ();
            summary.label = "Evolution Data Server calendar support is unavailable";
            render_agenda (); render_month (); return;
        }
        DateTime grid_start = month.add_days (-(month.get_day_of_week () - 1));
        DateTime grid_end = grid_start.add_days (42);
        try {
            var events = yield service.list_events (grid_start, grid_end, cancellable);
            if (cancellable.is_cancelled () || generation != reload_generation) return;
            loaded_events = events;
            render_agenda (); render_month ();
        } catch (Error error) {
            if (error is IOError.CANCELLED || generation != reload_generation) return;
            loaded_events.clear ();
            summary.label = "Could not read GNOME Calendar";
            state_label.label = error.message; state_label.visible = true;
            render_agenda (); render_month (); operation_failed (error);
        } finally {
            if (reload_cancellable == cancellable) reload_cancellable = null;
        }
    }

    private void render_agenda () {
        Gtk.ListBoxRow? row;
        while ((row = event_list.get_row_at_index (0)) != null)
            event_list.remove (row);
        state_label.visible = false;
        string needle = query.strip ().down ();
        int count = 0;
        foreach (var event in loaded_events) {
            if (!event_touches_day (event, selected_day)) continue;
            if (needle != "" && !(event.summary.down ().contains (needle) ||
                event.description.down ().contains (needle) ||
                event.location.down ().contains (needle))) continue;
            event_list.append (build_event_row (event)); count++;
        }
        string day_label = selected_day.format ("%A, %B %e").strip ();
        summary.label = count == 0 ? "%s · No events".printf (day_label) :
            "%s · %d event%s".printf (day_label, count, count == 1 ? "" : "s");
    }

    private Gtk.ListBoxRow build_event_row (CalendarEventOccurrence event) {
        var row = new Gtk.ListBoxRow (); row.selectable = false; row.activatable = false;
        row.add_css_class ("calendar-event-row");
        var content = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        content.margin_start = 8; content.margin_end = 6; content.margin_top = 7; content.margin_bottom = 7;
        var dot = new Gtk.Label ("●"); dot.add_css_class ("calendar-event-dot");
        content.append (dot);
        var body = new Gtk.Box (Gtk.Orientation.VERTICAL, 2); body.hexpand = true;
        var title = new Gtk.Label (event.summary); title.xalign = 0; title.wrap = true;
        title.add_css_class ("calendar-event-title"); body.append (title);
        var when = new Gtk.Label (event.all_day ? "All day" :
            event.start.format ("%l:%M %p").strip ());
        when.xalign = 0; when.add_css_class ("dim-label"); body.append (when);
        content.append (body);
        if (event.writable) {
            var edit = new Gtk.Button.from_icon_name ("document-edit-symbolic");
            edit.add_css_class ("flat"); edit.tooltip_text = "Edit event";
            edit.clicked.connect (() => edit_requested (event)); content.append (edit);
            var remove = new Gtk.Button.from_icon_name ("user-trash-symbolic");
            remove.add_css_class ("flat"); remove.tooltip_text = "Delete event";
            remove.clicked.connect (() => delete_requested (event)); content.append (remove);
        }
        row.child = content; return row;
    }

    private void render_month () {
        Gtk.Widget? child;
        while ((child = month_grid.get_first_child ()) != null) month_grid.remove (child);
        string[] names = { "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };
        for (int column = 0; column < 7; column++) {
            var label = new Gtk.Label (names[column]); label.add_css_class ("calendar-weekday");
            month_grid.attach (label, column, 0, 1, 1);
        }
        DateTime grid_start = month.add_days (-(month.get_day_of_week () - 1));
        for (int index = 0; index < 42; index++) {
            DateTime day = grid_start.add_days (index);
            month_grid.attach (build_day_button (day), index % 7, 1 + index / 7, 1, 1);
        }
        month_grid.show (); month_label.label = month.format ("%B %Y");
    }

    private Gtk.Button build_day_button (DateTime day) {
        var button = new Gtk.Button ();
        button.add_css_class ("calendar-day"); button.hexpand = true; button.vexpand = true;
        if (day.get_month () != month.get_month ()) button.add_css_class ("calendar-day-outside");
        if (day.format ("%F") == selected_day.format ("%F")) button.add_css_class ("calendar-day-selected");
        DateTime now = new DateTime.now_local ();
        if (day.format ("%F") == now.format ("%F")) button.add_css_class ("calendar-day-today");
        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
        var number = new Gtk.Label (day.get_day_of_month ().to_string ()); number.add_css_class ("calendar-day-number");
        box.append (number);
        var dots = new Gtk.Label (events_on_day (day) ? "•" : "");
        dots.add_css_class ("calendar-day-events"); box.append (dots);
        button.child = box;
        Accessibility.label (button, day.format ("%A, %B %e, %Y").strip ());
        button.clicked.connect (() => { selected_day = day; render_month (); render_agenda (); });
        return button;
    }

    private bool events_on_day (DateTime day) {
        foreach (var event in loaded_events) if (event_touches_day (event, day)) return true;
        return false;
    }

    private static bool event_touches_day (CalendarEventOccurrence event, DateTime day) {
        DateTime start = new DateTime.local (event.start.to_local ().get_year (),
            event.start.to_local ().get_month (), event.start.to_local ().get_day_of_month (), 0, 0, 0);
        DateTime end = event.end.to_local ();
        if (event.all_day) end = end.add_seconds (-1);
        DateTime end_day = new DateTime.local (end.get_year (), end.get_month (), end.get_day_of_month (), 0, 0, 0);
        return day.compare (start) >= 0 && day.compare (end_day) <= 0;
    }

    ~CalendarView () {
        if (reload_cancellable != null) reload_cancellable.cancel ();
        if (refresh_source != 0) Source.remove (refresh_source);
    }
}
}
