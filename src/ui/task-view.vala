namespace Mailficient {
public class TaskView : Gtk.Box {
    public signal void open_message_requested (string message_id);
    public signal void toast_requested (string message);
    public signal void operation_failed (Error error);

    private TaskService service;
    private TaskViewMode mode = TaskViewMode.TODAY;
    private Gtk.Label heading = new Gtk.Label ("");
    private Gtk.Label summary = new Gtk.Label ("");
    private Gtk.ListBox task_list = new Gtk.ListBox ();
    private Gtk.Stack state_stack = new Gtk.Stack ();
    private Adw.StatusPage empty_page = new Adw.StatusPage ();
    private Gtk.CheckButton show_completed = new Gtk.CheckButton.with_label ("Show completed");
    private string query = "";
    private int64 focus_task_id;
    private uint reload_source;

    public TaskView (TaskService service) {
        Object (orientation: Gtk.Orientation.VERTICAL, spacing: 0);
        this.service = service;
        add_css_class ("task-view");

        var header = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
        header.add_css_class ("task-view-header");
        header.margin_start = 24; header.margin_end = 24;
        header.margin_top = 20; header.margin_bottom = 14;
        var labels = new Gtk.Box (Gtk.Orientation.VERTICAL, 2); labels.hexpand = true;
        heading.xalign = 0; heading.add_css_class ("title-1"); labels.append (heading);
        summary.xalign = 0; summary.add_css_class ("dim-label"); labels.append (summary);
        header.append (labels);
        show_completed.valign = Gtk.Align.CENTER;
        show_completed.toggled.connect (reload);
        header.append (show_completed);
        var add_content = new Adw.ButtonContent ();
        add_content.icon_name = "list-add-symbolic"; add_content.label = "New Task";
        var add = new Gtk.Button (); add.child = add_content; add.add_css_class ("suggested-action");
        add.tooltip_text = "Create a task"; Accessibility.label (add, "Create a new task");
        add.clicked.connect (() => edit_task.begin (null, null));
        header.append (add);
        append (header);

        task_list.selection_mode = Gtk.SelectionMode.NONE;
        task_list.add_css_class ("boxed-list");
        task_list.add_css_class ("task-list");
        var list_clamp = new Adw.Clamp (); list_clamp.maximum_size = 920;
        list_clamp.margin_start = 20; list_clamp.margin_end = 20; list_clamp.margin_bottom = 24;
        list_clamp.child = task_list;
        var scroller = new Gtk.ScrolledWindow ();
        scroller.hscrollbar_policy = Gtk.PolicyType.NEVER; scroller.child = list_clamp;

        empty_page.icon_name = "task-due-symbolic";
        empty_page.title = "Nothing due";
        empty_page.description = "Create a task or turn an email into a follow-up.";
        var empty_add = new Gtk.Button.with_label ("Create Task");
        empty_add.halign = Gtk.Align.CENTER; empty_add.add_css_class ("suggested-action");
        empty_add.clicked.connect (() => edit_task.begin (null, null));
        empty_page.child = empty_add;

        state_stack.hexpand = true; state_stack.vexpand = true;
        state_stack.transition_type = Gtk.StackTransitionType.CROSSFADE;
        state_stack.add_named (scroller, "tasks"); state_stack.add_named (empty_page, "empty");
        append (state_stack);

        service.changed.connect (queue_reload);
        service.sync_failed.connect ((provider, detail) =>
            toast_requested ("%s sync is unavailable — changes remain saved locally".printf (provider)));
        set_mode (TaskViewMode.TODAY);
    }

    public void set_mode (TaskViewMode mode) {
        this.mode = mode;
        heading.label = mode == TaskViewMode.TODAY ? "Today" : "Planned";
        empty_page.title = mode == TaskViewMode.TODAY ? "Nothing due today" : "No planned tasks";
        empty_page.description = mode == TaskViewMode.TODAY ?
            "You’re caught up. Add a task or turn an email into a follow-up." :
            "Create a task with a due date to start planning.";
        reload ();
    }

    public void set_query (string query) {
        this.query = query;
        reload ();
    }

    public void new_task () { edit_task.begin (null, null); }

    public void create_from_message (Message message) {
        try {
            var existing = service.open_task_for_message (message.id);
            if (existing != null) {
                toast_requested ("This email already has an open task");
                edit_task.begin (existing, message);
            } else edit_task.begin (null, message);
        } catch (Error error) { operation_failed (error); }
    }

    public void focus_task (int64 task_id) {
        focus_task_id = task_id;
        reload ();
    }

    public void reload () {
        Gtk.ListBoxRow? row;
        while ((row = task_list.get_row_at_index (0)) != null) task_list.remove (row);
        try {
            var tasks = service.list (mode, show_completed.active, query);
            foreach (var task in tasks) task_list.append (build_row (task));
            state_stack.visible_child_name = tasks.size == 0 ? "empty" : "tasks";
            string count = tasks.size == 1 ? "1 task" : "%d tasks".printf (tasks.size);
            summary.label = "%s · %s".printf (count, service.sync_status ());
        } catch (Error error) {
            summary.label = "Tasks could not be loaded";
            state_stack.visible_child_name = "empty";
            operation_failed (error);
        }
    }

    private void queue_reload () {
        if (reload_source != 0) return;
        reload_source = Idle.add (() => {
            reload_source = 0; reload (); return Source.REMOVE;
        });
    }

    private Gtk.ListBoxRow build_row (MailTask task) {
        var row = new Gtk.ListBoxRow (); row.selectable = false;
        row.add_css_class ("task-row");
        if (task.completed) row.add_css_class ("completed");
        string today = MailTask.date_for_unix (new DateTime.now_local ().to_unix ());
        bool overdue = !task.completed && task.due_on_or_before (today) && task.due_at != today;
        if (overdue) row.add_css_class ("overdue");

        var content = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
        content.margin_start = 14; content.margin_end = 10;
        content.margin_top = 11; content.margin_bottom = 11;
        var completed = new Gtk.CheckButton (); completed.active = task.completed;
        completed.valign = Gtk.Align.START;
        string completion_label = task.completed ? "Reopen %s".printf (task.title) :
            "Complete %s".printf (task.title);
        Accessibility.label (completed, completion_label);
        completed.toggled.connect (() => {
            if (completed.active == task.completed) return;
            try {
                var next = service.set_completed (task, completed.active);
                if (next != null)
                    toast_requested ("Completed — next occurrence is due %s".printf (friendly_date (next.due_at)));
                else toast_requested (completed.active ? "Task completed" : "Task reopened");
            } catch (Error error) {
                completed.active = task.completed; operation_failed (error);
            }
        });
        content.append (completed);

        var body = new Gtk.Box (Gtk.Orientation.VERTICAL, 4); body.hexpand = true;
        var title = new Gtk.Label (task.title); title.xalign = 0;
        title.wrap = true; title.wrap_mode = Pango.WrapMode.WORD_CHAR;
        title.add_css_class ("task-title"); body.append (title);
        var metadata = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        metadata.add_css_class ("task-metadata");
        // Keep the formatted value in one owned string. Nested conditional
        // concatenation can release a temporary before Gtk.Label copies it.
        string due_text;
        if (task.completed) due_text = "Completed";
        else if (overdue) due_text = "Overdue · %s".printf (friendly_date (task.due_at));
        else if (task.due_at == today) due_text = "Due today";
        else due_text = "Due %s".printf (friendly_date (task.due_at));
        metadata.append (metadata_label (due_text, overdue ? "task-past-due-symbolic" : "task-due-symbolic"));
        if (task.reminder_at > 0)
            metadata.append (metadata_label (friendly_reminder (task.reminder_at), "alarm-symbolic"));
        if (task.recurrence != TaskRecurrence.NONE)
            metadata.append (metadata_label (task.recurrence_label (), "media-playlist-repeat-symbolic"));
        if (task.is_linked_to_message ())
            metadata.append (metadata_label ("Linked email", "mail-unread-symbolic"));
        body.append (metadata);
        if (task.notes.strip () != "") {
            var notes = new Gtk.Label (task.notes); notes.xalign = 0;
            notes.ellipsize = Pango.EllipsizeMode.END; notes.lines = 2;
            notes.add_css_class ("dim-label"); body.append (notes);
        }
        content.append (body);

        if (task.is_linked_to_message ()) {
            var open = new Gtk.Button.from_icon_name ("mail-unread-symbolic");
            open.add_css_class ("flat"); open.valign = Gtk.Align.CENTER;
            open.tooltip_text = "Open linked email"; Accessibility.label (open, "Open linked email for " + task.title);
            open.clicked.connect (() => open_message_requested (task.message_id)); content.append (open);
        }
        var edit = new Gtk.Button.from_icon_name ("document-edit-symbolic");
        edit.add_css_class ("flat"); edit.valign = Gtk.Align.CENTER;
        edit.tooltip_text = "Edit task"; Accessibility.label (edit, "Edit " + task.title);
        edit.clicked.connect (() => edit_task.begin (task, null)); content.append (edit);
        var remove = new Gtk.Button.from_icon_name ("user-trash-symbolic");
        remove.add_css_class ("flat"); remove.valign = Gtk.Align.CENTER;
        remove.tooltip_text = "Delete task"; Accessibility.label (remove, "Delete " + task.title);
        remove.clicked.connect (() => confirm_delete.begin (task)); content.append (remove);
        row.child = content;

        if (focus_task_id == task.id) {
            focus_task_id = 0;
            Idle.add (() => { row.grab_focus (); return Source.REMOVE; });
        }
        return row;
    }

    private Gtk.Widget metadata_label (string text, string icon_name) {
        var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 3);
        var icon = new Gtk.Image.from_icon_name (icon_name); icon.pixel_size = 13;
        icon.accessible_role = Gtk.AccessibleRole.PRESENTATION; box.append (icon);
        var label = new Gtk.Label (text); label.add_css_class ("caption"); box.append (label);
        return box;
    }

    private async void edit_task (MailTask? task, Message? source) {
        var title = new Adw.EntryRow (); title.title = "Task";
        string initial_title = "";
        if (task != null) initial_title = task.title;
        else if (source != null) initial_title = source.subject.strip () == "" ?
            "Follow up on email" : "Follow up: %s".printf (source.subject);
        title.text = initial_title;
        var notes = new Adw.EntryRow (); notes.title = "Notes";
        notes.text = task != null ? task.notes : "";

        var details = new Adw.PreferencesGroup (); details.add (title); details.add (notes);
        var due_label = new Gtk.Label ("Due date"); due_label.xalign = 0; due_label.add_css_class ("heading");
        var calendar = new Gtk.Calendar (); calendar.show_day_names = true; calendar.show_heading = true;
        Accessibility.label (calendar, "Task due date");
        string initial_due = task != null ? task.due_at :
            MailTask.date_for_unix (new DateTime.now_local ().to_unix ());
        var parsed_due = MailTask.parse_due_date (initial_due);
        if (parsed_due != null) calendar.select_day (parsed_due);

        var reminder = new Adw.SwitchRow (); reminder.title = "Reminder";
        reminder.subtitle = "Notify me on the due date";
        reminder.active = task != null && task.reminder_at > 0;
        var reminder_hour = new Adw.SpinRow.with_range (0, 23, 1); reminder_hour.title = "Hour";
        var reminder_minute = new Adw.SpinRow.with_range (0, 59, 5); reminder_minute.title = "Minute";
        if (task != null && task.reminder_at > 0) {
            var reminder_date = new DateTime.from_unix_local (task.reminder_at);
            reminder_hour.value = reminder_date.get_hour ();
            reminder_minute.value = reminder_date.get_minute ();
        } else { reminder_hour.value = 9; reminder_minute.value = 0; }
        reminder_hour.sensitive = reminder.active; reminder_minute.sensitive = reminder.active;
        reminder.notify["active"].connect (() => {
            reminder_hour.sensitive = reminder.active; reminder_minute.sensitive = reminder.active;
        });

        var recurrence_model = new Gtk.StringList (null);
        foreach (var label in new string[] { "Does not repeat", "Daily", "Weekly", "Monthly", "Yearly" })
            recurrence_model.append (label);
        var recurrence = new Adw.ComboRow (); recurrence.title = "Repeat";
        recurrence.model = recurrence_model;
        recurrence.selected = task == null ? 0 : (uint) task.recurrence;
        var interval = new Adw.SpinRow.with_range (1, 99, 1); interval.title = "Repeat every";
        interval.subtitle = "Number of days, weeks, months, or years";
        interval.value = task == null ? 1 : task.recurrence_interval;
        interval.sensitive = recurrence.selected != 0;
        recurrence.notify["selected"].connect (() => interval.sensitive = recurrence.selected != 0);
        var schedule = new Adw.PreferencesGroup (); schedule.add (reminder);
        schedule.add (reminder_hour); schedule.add (reminder_minute); schedule.add (recurrence); schedule.add (interval);

        var editor = new Gtk.Box (Gtk.Orientation.VERTICAL, 10);
        editor.set_size_request (440, -1); editor.append (details); editor.append (due_label); editor.append (calendar); editor.append (schedule);
        if (source != null) {
            var linked = new Gtk.Label ("This task will stay linked to the selected email and keep it flagged until completion.");
            linked.wrap = true; linked.xalign = 0; linked.add_css_class ("dim-label"); editor.append (linked);
        }
        var scroller = new Gtk.ScrolledWindow (); scroller.set_size_request (460, 540);
        scroller.hscrollbar_policy = Gtk.PolicyType.NEVER; scroller.child = editor;
        var dialog = new Adw.AlertDialog (task == null ? "New Task" : "Edit Task",
            task == null ? "Plan a follow-up with an optional reminder and recurrence." : "Update this task’s schedule and details.");
        dialog.extra_child = scroller; dialog.add_response ("cancel", "Cancel"); dialog.add_response ("save", "Save");
        dialog.default_response = "save"; dialog.close_response = "cancel";
        var parent = get_root () as Gtk.Widget;
        if (parent == null || (yield dialog.choose (parent, null)) != "save") return;

        var date = calendar.get_date ();
        string due_at = date.format ("%F"); int64 reminder_at = 0;
        if (reminder.active) {
            var when = new DateTime.local (date.get_year (), date.get_month (), date.get_day_of_month (),
                (int) reminder_hour.value, (int) reminder_minute.value, 0);
            reminder_at = when.to_unix ();
        }
        try {
            MailTask saved;
            if (task != null)
                saved = service.update (task, title.text, due_at, notes.text, reminder_at,
                    (TaskRecurrence) recurrence.selected, (int) interval.value);
            else if (source != null)
                saved = service.create_from_message (source, title.text, due_at, notes.text,
                    reminder_at, (TaskRecurrence) recurrence.selected, (int) interval.value);
            else
                saved = service.create (title.text, due_at, notes.text, "", reminder_at,
                    (TaskRecurrence) recurrence.selected, (int) interval.value);
            focus_task_id = saved.id;
            toast_requested (task == null ? "Task created" : "Task updated");
        } catch (Error error) { operation_failed (error); }
    }

    private async void confirm_delete (MailTask task) {
        var dialog = new Adw.AlertDialog ("Delete task?", task.title);
        dialog.add_response ("cancel", "Cancel"); dialog.add_response ("delete", "Delete");
        dialog.set_response_appearance ("delete", Adw.ResponseAppearance.DESTRUCTIVE);
        dialog.default_response = "cancel"; dialog.close_response = "cancel";
        var parent = get_root () as Gtk.Widget;
        if (parent == null || (yield dialog.choose (parent, null)) != "delete") return;
        try { service.delete (task); toast_requested ("Task deleted"); }
        catch (Error error) { operation_failed (error); }
    }

    private static string friendly_date (string due_at) {
        var date = MailTask.parse_due_date (due_at);
        return date == null ? due_at : date.format ("%b %e, %Y").strip ();
    }

    private static string friendly_reminder (int64 reminder_at) {
        return new DateTime.from_unix_local (reminder_at).format ("%b %e · %l:%M %p").strip ();
    }

    ~TaskView () {
        if (reload_source != 0) Source.remove (reload_source);
    }
}
}
