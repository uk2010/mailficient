namespace Mailficient {
private class CalendarDatePickerState : Object {
    public Gtk.Calendar calendar = new Gtk.Calendar ();
    public Gtk.Popover popover;
    public signal void date_selected (string value);

    public CalendarDatePickerState () {}
}

public class CalendarTasksWindow : Gtk.Box {
    private CacheDatabase cache;
    private Gtk.Calendar calendar = new Gtk.Calendar ();
    private Gtk.Grid month_grid = new Gtk.Grid ();
    private Gtk.Label month_label = new Gtk.Label ("");
    private Gtk.ListBox day_events_list = new Gtk.ListBox ();
    private Gtk.ListBox tasks_list = new Gtk.ListBox ();
    private Gtk.Entry event_title = new Gtk.Entry ();
    private Gtk.Entry event_start_date = new Gtk.Entry ();
    private Gtk.Entry event_end_date = new Gtk.Entry ();
    private Gtk.MenuButton event_start_date_button = new Gtk.MenuButton ();
    private Gtk.MenuButton event_end_date_button = new Gtk.MenuButton ();
    private Gtk.Entry event_start_time = new Gtk.Entry ();
    private Gtk.Entry event_end_time = new Gtk.Entry ();
    private Gtk.MenuButton event_start_time_button = new Gtk.MenuButton ();
    private Gtk.MenuButton event_end_time_button = new Gtk.MenuButton ();
    private Gtk.Entry event_location = new Gtk.Entry ();
    private Gtk.Entry task_title = new Gtk.Entry ();
    private Gtk.Entry task_due = new Gtk.Entry ();
    private Gtk.MenuButton task_due_button = new Gtk.MenuButton ();
    private Gtk.Entry task_notes = new Gtk.Entry ();
    private string selected_day = "";
    private string event_start_date_value = "";
    private string event_end_date_value = "";
    private string event_start_time_value = "09:00";
    private string event_end_time_value = "10:00";
    private string task_due_value = "";
    private Gee.ArrayList<CalendarEvent> events = new Gee.ArrayList<CalendarEvent> ();
    private bool calendar_data_loaded;
    private Gtk.Widget? event_column_widget;
    private Gtk.Widget? tasks_column_widget;
    private Gtk.Box? panel_reopen_controls;
    private Gtk.Button? event_panel_show_button;
    private Gtk.Button? tasks_panel_show_button;
    private Gtk.MenuButton? event_add_button;
    private Gtk.MenuButton? task_add_button;
    private Gtk.Popover? event_editor_popover;
    private Gtk.Popover? task_editor_popover;

    public CalendarTasksWindow (CacheDatabase cache) {
        Object (orientation: Gtk.Orientation.VERTICAL, spacing: 0);
        this.cache = cache;
        set_size_request (0, -1);
        hexpand = true; vexpand = true;
        halign = Gtk.Align.FILL; valign = Gtk.Align.FILL;
        overflow = Gtk.Overflow.HIDDEN;
        calendar.show_heading = true; calendar.show_day_names = true; calendar.show_week_numbers = false;
        set_calendar_date (calendar, new DateTime.now_local ());
        calendar.day_selected.connect (() => select_calendar_day ());
        calendar.next_month.connect (() => reload_calendar ()); calendar.prev_month.connect (() => reload_calendar ());
        calendar.next_year.connect (() => reload_calendar ()); calendar.prev_year.connect (() => reload_calendar ());

        append (build_workspace ());
        // Let the Calendar page become visible before loading and laying out
        // all event/task rows. This keeps opening Calendar responsive even
        // when the local cache contains a large history.
        Idle.add (() => {
            reload_calendar (); reload_tasks ();
            return Source.REMOVE;
        });
    }

    private Gtk.Widget build_workspace () {
        // Keep the month grid directly beside the application's mailbox
        // sidebar. The detail rail is one fixed-width column on the right;
        // individual cards can be hidden without moving the calendar away
        // from the sidebar.
        var event_column = build_calendar_column ();
        event_column_widget = event_column;
        var tasks_column = build_tasks_column ();
        tasks_column_widget = tasks_column;
        // Build the task editor before the month header attaches its Add Task
        // button to the popover. Otherwise the button exists without a
        // backing form on the first calendar page construction.
        var month_column = build_month_column ();
        var detail_rail = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
        detail_rail.add_css_class ("calendar-detail-rail");
        detail_rail.set_size_request (280, -1);
        detail_rail.hexpand = false; detail_rail.vexpand = true;
        detail_rail.append (event_column);
        detail_rail.append (tasks_column);

        var workspace = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        workspace.add_css_class ("calendar-workspace");
        workspace.hexpand = true; workspace.vexpand = true;
        workspace.append (month_column);
        workspace.append (detail_rail);
        workspace.notify["width"].connect (() => resize_detail_rail (this, detail_rail));
        notify["width"].connect (() => resize_detail_rail (this, detail_rail));
        add_tick_callback ((widget, frame_clock) => {
            resize_detail_rail (this, detail_rail);
            return get_width () > 0 ? Source.REMOVE : Source.CONTINUE;
        });
        resize_detail_rail (this, detail_rail);
        return workspace;
    }

    private static void resize_detail_rail (Gtk.Widget available_page, Gtk.Widget rail) {
        int width = available_page.get_width ();
        if (width <= 0) return;
        // Give the detail cards room to breathe on a wide window while
        // preventing them from consuming the month grid on smaller windows.
        int rail_width = int.max (120, int.min (380, (width * 20) / 100));
        if (rail.get_width () != rail_width)
            rail.set_size_request (rail_width, -1);
    }

    private Gtk.Widget build_calendar_column () {
        var column = new Gtk.Box (Gtk.Orientation.VERTICAL, 10);
        column.add_css_class ("calendar-detail-card");
        column.add_css_class ("calendar-event-card");
        column.margin_top = 18; column.margin_bottom = 0; column.margin_start = 0; column.margin_end = 0;
        column.hexpand = true; column.vexpand = true; column.set_size_request (0, 0);
        var heading = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        var title = new Gtk.Label ("Events");
        title.xalign = 0; title.hexpand = true; title.add_css_class ("title-3"); heading.append (title);
        column.append (heading);
        day_events_list.selection_mode = Gtk.SelectionMode.NONE; day_events_list.add_css_class ("boxed-list");
        var events_scroll = new Gtk.ScrolledWindow (); events_scroll.vexpand = true; events_scroll.hexpand = true; events_scroll.child = day_events_list; column.append (events_scroll);

        event_title.placeholder_text = "Title"; event_title.width_chars = 18; event_title.max_width_chars = 24;
        configure_picker_field (event_start_date, "Start date"); configure_picker_field (event_end_date, "End date");
        configure_picker_field (event_start_time, event_start_time_value); configure_picker_field (event_end_time, event_end_time_value);
        event_start_time.tooltip_text = "Choose start time"; event_end_time.tooltip_text = "Choose end time";
        event_location.placeholder_text = "Location"; event_location.width_chars = 18; event_location.max_width_chars = 24;
        configure_date_picker_button (event_start_date_button, event_start_date, true);
        configure_date_picker_button (event_end_date_button, event_end_date, false);
        configure_time_picker_button (event_start_time_button, event_start_time, true);
        configure_time_picker_button (event_end_time_button, event_end_time, false);
        event_editor_popover = new Gtk.Popover (); event_editor_popover.autohide = true;
        var form = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
        form.margin_top = 10; form.margin_bottom = 10; form.margin_start = 10; form.margin_end = 10;
        var add_heading = new Gtk.Label ("Add event"); add_heading.xalign = 0; add_heading.add_css_class ("heading"); form.append (add_heading);
        form.append (event_title);
        var dates = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6); dates.append (picker_field_row (event_start_date, event_start_date_button)); dates.append (picker_field_row (event_end_date, event_end_date_button)); form.append (dates);
        var times = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6); times.append (picker_field_row (event_start_time, event_start_time_button)); times.append (picker_field_row (event_end_time, event_end_time_button)); form.append (times);
        form.append (event_location);
        var add = new Gtk.Button.with_label ("Add Event"); add.halign = Gtk.Align.END; add.add_css_class ("suggested-action");
        add.clicked.connect (() => { add_event (); event_editor_popover.popdown (); }); form.append (add);
        event_editor_popover.child = form;
        return column;
    }

    private Gtk.Widget build_month_column () {
        var column = new Gtk.Box (Gtk.Orientation.VERTICAL, 10);
        column.add_css_class ("calendar-month-column");
        column.margin_top = 18; column.margin_bottom = 18; column.margin_start = 18; column.margin_end = 12;
        column.hexpand = true; column.vexpand = true;
        var navigation = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
        navigation.hexpand = true; navigation.halign = Gtk.Align.FILL;
        var previous = new Gtk.Button.from_icon_name ("go-previous-symbolic"); previous.tooltip_text = "Previous month";
        var today = new Gtk.Button.with_label ("Today"); today.tooltip_text = "Go to today";
        var next = new Gtk.Button.from_icon_name ("go-next-symbolic"); next.tooltip_text = "Next month";
        month_label.hexpand = true; month_label.xalign = 0; month_label.add_css_class ("title-2");
        previous.clicked.connect (() => shift_month (-1)); today.clicked.connect (() => { set_calendar_date (calendar, new DateTime.now_local ()); reload_calendar (); }); next.clicked.connect (() => shift_month (1));
        navigation.append (previous); navigation.append (today); navigation.append (month_label);
        panel_reopen_controls = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
        panel_reopen_controls.add_css_class ("calendar-panel-reopen-controls");
        panel_reopen_controls.halign = Gtk.Align.END;
        event_add_button = new Gtk.MenuButton (); event_add_button.icon_name = "x-office-calendar-symbolic"; event_add_button.tooltip_text = "Add event"; event_add_button.popover = event_editor_popover;
        task_add_button = new Gtk.MenuButton (); task_add_button.icon_name = "emblem-ok-symbolic"; task_add_button.tooltip_text = "Add task"; task_add_button.popover = task_editor_popover;
        event_panel_show_button = new Gtk.Button.from_icon_name ("eye-open-negative-filled-symbolic");
        event_panel_show_button.add_css_class ("flat");
        event_panel_show_button.clicked.connect (() => set_event_panel_visible (event_column_widget == null || !event_column_widget.visible));
        tasks_panel_show_button = new Gtk.Button.from_icon_name ("eye-open-negative-filled-symbolic");
        tasks_panel_show_button.add_css_class ("flat");
        tasks_panel_show_button.clicked.connect (() => set_tasks_panel_visible (tasks_column_widget == null || !tasks_column_widget.visible));
        panel_reopen_controls.append (event_add_button); panel_reopen_controls.append (event_panel_show_button);
        panel_reopen_controls.append (task_add_button); panel_reopen_controls.append (tasks_panel_show_button);
        navigation.append (panel_reopen_controls); navigation.append (next); column.append (navigation);
        update_panel_reopen_controls ();
        month_grid.column_homogeneous = true; month_grid.row_homogeneous = true; month_grid.hexpand = true; month_grid.vexpand = true; month_grid.set_size_request (0, 0); month_grid.add_css_class ("calendar-month-grid"); column.append (month_grid);
        return column;
    }

    private Gtk.Widget build_tasks_column () {
        var column = new Gtk.Box (Gtk.Orientation.VERTICAL, 10);
        column.add_css_class ("calendar-detail-card");
        column.add_css_class ("calendar-task-card");
        column.margin_top = 0; column.margin_bottom = 18; column.margin_start = 0; column.margin_end = 0;
        column.hexpand = true; column.vexpand = true; column.set_size_request (0, 0);
        var heading = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        var title = new Gtk.Label ("Tasks"); title.xalign = 0; title.hexpand = true; title.add_css_class ("title-3"); heading.append (title); column.append (heading);
        task_title.placeholder_text = "Task"; configure_picker_field (task_due, "Due date"); task_due.tooltip_text = "Choose task due date"; task_notes.placeholder_text = "Notes";
        configure_date_picker_button (task_due_button, task_due, false);
        task_editor_popover = new Gtk.Popover (); task_editor_popover.autohide = true;
        var form = new Gtk.Box (Gtk.Orientation.VERTICAL, 6); form.append (task_title); form.append (picker_field_row (task_due, task_due_button)); form.append (task_notes);
        var add = new Gtk.Button.with_label ("Add Task"); add.halign = Gtk.Align.END; add.add_css_class ("suggested-action");
        add.clicked.connect (() => { add_task (); task_editor_popover.popdown (); }); form.append (add);
        form.margin_top = 10; form.margin_bottom = 10; form.margin_start = 10; form.margin_end = 10;
        task_editor_popover.child = form;
        tasks_list.selection_mode = Gtk.SelectionMode.NONE; tasks_list.add_css_class ("boxed-list");
        var tasks_scroll = new Gtk.ScrolledWindow (); tasks_scroll.vexpand = true; tasks_scroll.child = tasks_list; column.append (tasks_scroll);
        return column;
    }

    private void set_event_panel_visible (bool visible) {
        if (event_column_widget != null) event_column_widget.visible = visible;
        update_panel_reopen_controls ();
    }

    private void set_tasks_panel_visible (bool visible) {
        if (tasks_column_widget != null) tasks_column_widget.visible = visible;
        update_panel_reopen_controls ();
    }

    private void update_panel_reopen_controls () {
        if (event_panel_show_button != null) {
            bool visible = event_column_widget == null || event_column_widget.visible;
            event_panel_show_button.icon_name = visible ? "eye-open-negative-filled-symbolic" : "eye-not-looking-symbolic";
            event_panel_show_button.tooltip_text = visible ? "Hide events" : "Show events";
        }
        if (tasks_panel_show_button != null) {
            bool visible = tasks_column_widget == null || tasks_column_widget.visible;
            tasks_panel_show_button.icon_name = visible ? "eye-open-negative-filled-symbolic" : "eye-not-looking-symbolic";
            tasks_panel_show_button.tooltip_text = visible ? "Hide tasks" : "Show tasks";
        }
        if (panel_reopen_controls != null) panel_reopen_controls.visible = true;
    }

    private void select_calendar_day () {
        selected_day = calendar_date_key (calendar);
        reload_day_events (); reload_month_grid ();
    }

    private void reload_calendar () {
        try { events = cache.list_calendar_events (); }
        catch (Error error) { warning ("Could not load calendar events: %s", error.message); events.clear (); }
        calendar_data_loaded = true;
        render_calendar ();
    }

    private void render_calendar () {
        calendar.clear_marks ();
        int year = calendar.get_year (); int month = calendar.get_month () + 1;
        foreach (var event in events) {
            var date = parse_date (event.starts_at);
            if (date != null && date.get_year () == year && date.get_month () == month)
                calendar.mark_day ((uint) int.parse (event.starts_at.substring (8, 2)));
        }
        selected_day = calendar_date_key (calendar);
        reload_day_events (); reload_month_grid ();
    }

    private void shift_month (int amount) {
        var current = calendar.get_date ();
        set_calendar_date (calendar, new DateTime.local (current.get_year (), current.get_month (), 1, 0, 0, 0));
        set_calendar_date (calendar, calendar.get_date ().add_months (amount));
        if (calendar_data_loaded) render_calendar (); else reload_calendar ();
    }

    private void reload_month_grid () {
        Gtk.Widget? child; while ((child = month_grid.get_first_child ()) != null) month_grid.remove (child);
        string[] weekdays = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
        for (int column = 0; column < 7; column++) {
            var heading = new Gtk.Label (weekdays[column]); heading.add_css_class ("heading"); month_grid.attach (heading, column, 0, 1, 1);
        }
        var visible = calendar.get_date (); int year = visible.get_year (); int month = visible.get_month ();
        var first = new DateTime.local (year, month, 1, 0, 0, 0);
        int leading = first.get_day_of_week () % 7;
        int days = first.add_months (1).add_days (-1).get_day_of_month ();
        month_label.label = first.format ("%B %Y");
        for (int index = 0; index < 42; index++) {
            int day = index - leading + 1; var cell = new Gtk.Box (Gtk.Orientation.VERTICAL, 3); cell.margin_top = 0; cell.margin_start = 0; cell.margin_end = 0; cell.margin_bottom = 0; cell.valign = Gtk.Align.FILL; cell.hexpand = true; cell.vexpand = true;
            cell.add_css_class ("calendar-day-cell");
            if (day < 1 || day > days) { cell.add_css_class ("calendar-day-cell-outside"); month_grid.attach (cell, index % 7, index / 7 + 1, 1, 1); continue; }
            var day_button = new Gtk.Label (day.to_string ()); day_button.halign = Gtk.Align.START; day_button.add_css_class ("calendar-day-number");
            string day_id = "%04d-%02d-%02d".printf (year, month, day); if (day_id == selected_day) day_button.add_css_class ("calendar-selected-day");
            int selected_day_number = day;
            string selected_day_id = day_id;
            var primary = new Gtk.GestureClick (); primary.button = Gdk.BUTTON_PRIMARY; primary.propagation_phase = Gtk.PropagationPhase.CAPTURE;
            primary.pressed.connect ((presses, x, y) => select_main_day (year, month, selected_day_number, selected_day_id)); cell.add_controller (primary);
            cell.append (day_button);
            var context = new Gtk.GestureClick (); context.button = Gdk.BUTTON_SECONDARY; context.pressed.connect ((presses, x, y) => show_day_context_menu (cell, year, month, selected_day_number, selected_day_id, x, y)); cell.add_controller (context);
            foreach (var event in events) {
            var date = parse_date (event.starts_at); if (date == null || date_key (date) != day_id) continue;
                var chip = new Gtk.Label ("• " + event.title); chip.xalign = 0; chip.ellipsize = Pango.EllipsizeMode.END; chip.max_width_chars = 14; chip.set_size_request (0, -1); chip.add_css_class ("calendar-event-chip"); cell.append (chip);
            }
            month_grid.attach (cell, index % 7, index / 7 + 1, 1, 1);
        }
    }

    private void reload_day_events () {
        clear (day_events_list);
        bool any = false;
        foreach (var event in events) {
            var date = parse_date (event.starts_at);
            if (date == null) continue;
            any = true; append_event_row (event);
        }
        if (!any) {
            var empty = new Gtk.Label ("No events"); empty.xalign = 0; empty.add_css_class ("dim-label"); empty.margin_top = 8; empty.margin_bottom = 8; day_events_list.append (empty);
        }
    }

    private void append_event_row (CalendarEvent event) {
        var row = new Gtk.ListBoxRow (); row.add_css_class ("calendar-event-row"); var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8); box.margin_top = 10; box.margin_bottom = 10; box.margin_start = 10; box.margin_end = 10;
        var color = new Gtk.Box (Gtk.Orientation.VERTICAL, 0); color.set_size_request (8, -1); color.add_css_class ("calendar-event-dot"); box.append (color);
        var labels = new Gtk.Box (Gtk.Orientation.VERTICAL, 3); labels.hexpand = true;
        var date = new Gtk.Label (format_event_date (event.starts_at)); date.xalign = 0; date.add_css_class ("dim-label"); labels.append (date);
        var details = new Gtk.Label (format_event_time (event.starts_at) + "   " + event.title); details.xalign = 0; details.ellipsize = Pango.EllipsizeMode.END; details.max_width_chars = 28; labels.append (details); box.append (labels);
        var remove = new Gtk.Button.from_icon_name ("user-trash-symbolic"); remove.tooltip_text = "Delete event"; remove.valign = Gtk.Align.CENTER;
        remove.clicked.connect (() => { try { cache.remove_calendar_event (event.id); reload_calendar (); } catch (Error error) { warning ("Could not delete event: %s", error.message); } }); box.append (remove);
        row.child = box; day_events_list.append (row);
    }

    private static string format_event_date (string value) {
        var date = parse_date (value);
        return date == null ? value : date.format ("%d %b %Y");
    }

    private static string format_event_time (string value) {
        if (value.length < 16) return "";
        return value.substring (11, 5);
    }

    private void reload_tasks () {
        clear (tasks_list);
        try {
            foreach (var task in cache.list_mail_tasks ()) {
                var row = new Gtk.ListBoxRow (); var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10); box.margin_top = 9; box.margin_bottom = 9; box.margin_start = 12; box.margin_end = 12;
                var done = new Gtk.CheckButton (); done.active = task.completed; done.valign = Gtk.Align.CENTER;
                done.toggled.connect (() => { try { cache.set_mail_task_completed (task.id, done.active); reload_tasks (); } catch (Error error) { warning ("Could not update task: %s", error.message); } }); box.append (done);
                var labels = new Gtk.Box (Gtk.Orientation.VERTICAL, 3); labels.hexpand = true;
                var title = new Gtk.Label (task.title); title.xalign = 0; title.ellipsize = Pango.EllipsizeMode.END; title.max_width_chars = 28; title.add_css_class ("heading"); if (task.completed) title.add_css_class ("dim-label"); labels.append (title);
                var details = new Gtk.Label ((task.due_at == "" ? "No due date" : "Due " + task.due_at) + (task.notes == "" ? "" : " · " + task.notes)); details.xalign = 0; details.ellipsize = Pango.EllipsizeMode.END; details.max_width_chars = 32; details.add_css_class ("dim-label"); labels.append (details); box.append (labels);
                var remove = new Gtk.Button.from_icon_name ("user-trash-symbolic"); remove.tooltip_text = "Delete task"; remove.valign = Gtk.Align.CENTER;
                remove.clicked.connect (() => { try { cache.remove_mail_task (task.id); reload_tasks (); } catch (Error error) { warning ("Could not delete task: %s", error.message); } }); box.append (remove);
                row.child = box; tasks_list.append (row);
            }
        } catch (Error error) { warning ("Could not load tasks: %s", error.message); }
    }

    private void add_event () {
        try {
            if (event_start_date_value == "") set_event_date (date_key (new DateTime.now_local ()));
            if (event_end_date_value == "") event_end_date_value = event_start_date_value;
            var start_time = event_start_time_value == "" ? "09:00" : event_start_time_value;
            var end_time = event_end_time_value == "" ? "10:00" : event_end_time_value;
            cache.add_calendar_event (event_title.text, event_start_date_value + " " + start_time, event_end_date_value + " " + end_time, event_location.text);
            event_title.text = ""; event_location.text = ""; reload_calendar ();
        }
        catch (Error error) { warning ("Could not add calendar event: %s", error.message); }
    }

    private void set_event_date (string value) {
        event_start_date_value = value; event_end_date_value = value;
        set_field_text (event_start_date, value); set_field_text (event_end_date, value);
    }

    private void select_main_day (int year, int month, int day, string value) {
        set_calendar_date (calendar, new DateTime.local (year, month, day, 0, 0, 0));
        selected_day = value;
        reload_day_events (); reload_month_grid ();
    }

    private void show_day_context_menu (Gtk.Widget anchor, int year, int month, int day, string value, double x, double y) {
        set_calendar_date (calendar, new DateTime.local (year, month, day, 0, 0, 0));
        selected_day = value;
        reload_day_events ();

        var popover = new Gtk.Popover (); popover.autohide = true; popover.has_arrow = true;
        var menu = new Gtk.Box (Gtk.Orientation.VERTICAL, 4); menu.margin_top = 6; menu.margin_bottom = 6; menu.margin_start = 6; menu.margin_end = 6;
        var add_event_button = new Gtk.Button.with_label ("Add event on this day"); add_event_button.halign = Gtk.Align.FILL;
        var add_task_button = new Gtk.Button.with_label ("Add task on this day"); add_task_button.halign = Gtk.Align.FILL;
        add_event_button.clicked.connect (() => {
            set_event_panel_visible (true);
            set_event_date (value); popover.popdown ();
            if (event_add_button != null) event_add_button.active = true;
            event_title.grab_focus ();
        });
        add_task_button.clicked.connect (() => {
            set_tasks_panel_visible (true);
            task_due_value = value; set_field_text (task_due, value); popover.popdown ();
            if (task_add_button != null) task_add_button.active = true;
            task_title.grab_focus ();
        });
        menu.append (add_event_button); menu.append (add_task_button); popover.child = menu;
        popover.set_parent (anchor); popover.pointing_to = { (int) x, (int) y, 1, 1 }; popover.popup ();
    }

    private void configure_date_picker_button (Gtk.MenuButton button, Gtk.Entry field, bool start) {
        button.icon_name = "x-office-calendar-symbolic";
        button.tooltip_text = "Choose date";
        button.valign = Gtk.Align.CENTER;
        button.add_css_class ("flat");

        string initial = start ? event_start_date_value : (field == task_due ? task_due_value : event_end_date_value);
        var state = create_date_picker (button, initial == "" ? date_key (new DateTime.now_local ()) : initial);
        state.date_selected.connect ((date) => {
            set_field_text (field, date);
            if (field == event_start_date) event_start_date_value = date;
            else if (field == event_end_date) event_end_date_value = date;
            else if (field == task_due) task_due_value = date;
            state.popover.popdown ();
        });
    }

    private CalendarDatePickerState create_date_picker (Gtk.MenuButton button, string initial) {
        var parsed = parse_date (initial);
        var state = new CalendarDatePickerState ();

        var popover = new Gtk.Popover (); popover.autohide = true;
        state.popover = popover;

        var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);
        content.margin_top = 10; content.margin_bottom = 10; content.margin_start = 10; content.margin_end = 10;
        state.calendar.show_heading = true;
        state.calendar.show_day_names = true;
        state.calendar.show_week_numbers = false;
        set_calendar_date (state.calendar, parsed ?? new DateTime.now_local ());
        state.calendar.set_size_request (280, 240);
        state.calendar.day_selected.connect (() => state.date_selected (calendar_date_key (state.calendar)));
        // Gtk.Calendar does not emit day-selected when the user clicks the
        // date that is already selected. Confirm the current date after the
        // click as well so Today works on the first click.
        var confirm_click = new Gtk.GestureClick (); confirm_click.button = Gdk.BUTTON_PRIMARY;
        confirm_click.released.connect ((presses, x, y) => {
            Idle.add (() => { state.date_selected (calendar_date_key (state.calendar)); return Source.REMOVE; });
        });
        state.calendar.add_controller (confirm_click);
        content.append (state.calendar);
        popover.child = content;
        button.popover = popover;
        return state;
    }

    private void configure_time_picker_button (Gtk.MenuButton button, Gtk.Entry field, bool start) {
        button.icon_name = "preferences-system-time-symbolic";
        button.tooltip_text = "Choose time";
        button.valign = Gtk.Align.CENTER;
        button.add_css_class ("flat");

        var popover = new Gtk.Popover (); popover.autohide = true;
        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);
        box.margin_top = 10; box.margin_bottom = 10; box.margin_start = 10; box.margin_end = 10;
        var controls = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
        var current = start ? event_start_time_value : event_end_time_value;
        var parts = current.split (":");
        int hour = parts.length > 0 ? int.parse (parts[0]) : (start ? 9 : 10);
        int minute = parts.length > 1 ? int.parse (parts[1]) : 0;
        var hour_picker = new Gtk.SpinButton.with_range (0, 23, 1); hour_picker.value = hour; hour_picker.numeric = true;
        var separator = new Gtk.Label (":");
        var minute_picker = new Gtk.SpinButton.with_range (0, 59, 1); minute_picker.value = minute; minute_picker.numeric = true;
        controls.append (hour_picker); controls.append (separator); controls.append (minute_picker);
        var done = new Gtk.Button.with_label ("Set time"); done.add_css_class ("suggested-action"); done.halign = Gtk.Align.END;
        done.clicked.connect (() => {
            var value = "%02d:%02d".printf ((int) hour_picker.value, (int) minute_picker.value);
            if (start) { event_start_time_value = value; set_field_text (event_start_time, value); }
            else { event_end_time_value = value; set_field_text (event_end_time, value); }
            popover.popdown ();
        });
        box.append (controls); box.append (done);
        popover.child = box;
        button.popover = popover;
    }

    private void add_task () {
        try { cache.add_mail_task (task_title.text, task_due_value, task_notes.text); task_title.text = ""; task_due_value = ""; set_field_text (task_due, "Due date"); task_notes.text = ""; reload_tasks (); }
        catch (Error error) { warning ("Could not add task: %s", error.message); }
    }

    private static void configure_picker_field (Gtk.Entry field, string initial) {
        field.text = initial;
        field.editable = false;
        field.can_focus = false;
        field.width_chars = 10;
        field.max_width_chars = 12;
    }

    private static void set_field_text (Gtk.Entry field, string value) {
        field.text = value;
    }

    private static Gtk.Widget picker_field_row (Gtk.Entry field, Gtk.MenuButton button) {
        var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        row.hexpand = true;
        field.hexpand = true;
        row.append (field);
        row.append (button);
        return row;
    }

    private static void set_calendar_date (Gtk.Calendar calendar, DateTime date) {
        // Some installed GTK 4 Vala bindings expose these writable legacy
        // properties but not Gtk.Calendar.set_date().
        calendar.year = date.get_year ();
        calendar.month = date.get_month () - 1;
        calendar.day = date.get_day_of_month ();
    }

    private static string date_key (DateTime date) {
        return "%04d-%02d-%02d".printf (date.get_year (), date.get_month (), date.get_day_of_month ());
    }

    private static string calendar_date_key (Gtk.Calendar value) {
        return "%04d-%02d-%02d".printf (value.get_year (), value.get_month () + 1, value.get_day ());
    }

    private static DateTime? parse_date (string value) {
        if (value.strip ().length < 10) return null;
        var zone = new TimeZone.local (); return new DateTime.from_iso8601 (value.strip ().substring (0, 10) + "T00:00:00", zone);
    }

    private static void clear (Gtk.ListBox list) {
        Gtk.Widget? child; while ((child = list.get_first_child ()) != null) list.remove (child);
    }
}
}
