namespace Mailficient {
// Provider integrations consume this boundary without coupling local task
// editing to a network or desktop calendar API. The default implementation is
// intentionally local-only; an EDS/CalDAV adapter can enqueue upserts/deletes
// here once a task-capable account and credentials are available.
public interface TaskSyncProvider : Object {
    public abstract string name { owned get; }
    public abstract bool available { get; }
    public abstract void task_saved (MailTask task) throws Error;
    public abstract void task_deleted (int64 task_id) throws Error;
}

public class LocalTaskSyncProvider : Object, TaskSyncProvider {
    public string name { owned get { return "Local tasks"; } }
    public bool available { get { return false; } }
    public void task_saved (MailTask task) throws Error { }
    public void task_deleted (int64 task_id) throws Error { }
}

public class TaskService : Object {
    public signal void changed ();
    public signal void sync_failed (string provider, string detail);
    private CacheDatabase cache;
    private MailRepository repository;
    private TaskSyncProvider sync_provider;

    public TaskService (CacheDatabase cache, MailRepository repository,
                        TaskSyncProvider? sync_provider = null) {
        this.cache = cache;
        this.repository = repository;
        this.sync_provider = sync_provider ?? new LocalTaskSyncProvider ();
    }

    public string sync_status () {
        return sync_provider.available ? "Syncing with " + sync_provider.name :
            "Stored on this device";
    }

    public Gee.ArrayList<MailTask> list (TaskViewMode mode, bool include_completed = false,
                                        string query = "", int64 now = 0) throws MailError {
        int64 reference = now > 0 ? now : new DateTime.now_local ().to_unix ();
        string today = MailTask.date_for_unix (reference);
        string needle = query.strip ().down ();
        var result = new Gee.ArrayList<MailTask> ();
        foreach (var task in cache.list_mail_tasks ()) {
            if (!include_completed && task.completed) continue;
            if (mode == TaskViewMode.TODAY && !task.due_on_or_before (today)) continue;
            if (needle != "" && !(task.title.down ().contains (needle) ||
                task.notes.down ().contains (needle))) continue;
            result.add (task);
        }
        return result;
    }

    public MailTask create (string title, string due_at, string notes = "", string message_id = "",
                            int64 reminder_at = 0,
                            TaskRecurrence recurrence = TaskRecurrence.NONE,
                            int recurrence_interval = 1) throws MailError {
        validate (title, due_at, recurrence_interval);
        string normalized = MailTask.normalized_due_date (due_at);
        var task = cache.create_mail_task (title, normalized, notes, message_id,
            reminder_at, recurrence, recurrence_interval);
        synchronize_saved (task);
        update_linked_flag (message_id);
        changed ();
        return task;
    }

    public MailTask create_from_message (Message message, string title, string due_at,
                                         string notes = "", int64 reminder_at = 0,
                                         TaskRecurrence recurrence = TaskRecurrence.NONE,
                                         int recurrence_interval = 1) throws MailError {
        string context = notes.strip ();
        if (context == "") {
            string sender = message.sender_name.strip () != "" ? message.sender_name : message.sender_address;
            context = sender.strip () == "" ? "Created from an email" :
                "Email from %s".printf (sender.strip ());
        }
        return create (title, due_at, context, message.id, reminder_at,
            recurrence, recurrence_interval);
    }

    public MailTask update (MailTask task, string title, string due_at, string notes,
                            int64 reminder_at, TaskRecurrence recurrence,
                            int recurrence_interval) throws MailError {
        validate (title, due_at, recurrence_interval);
        string normalized = MailTask.normalized_due_date (due_at);
        var updated = cache.update_mail_task (task.id, title, normalized, notes,
            reminder_at, recurrence, recurrence_interval);
        synchronize_saved (updated);
        update_linked_flag (updated.message_id);
        changed ();
        return updated;
    }

    public MailTask? set_completed (MailTask task, bool completed, int64 now = 0) throws MailError {
        int64 changed_at = now > 0 ? now : new DateTime.now_utc ().to_unix ();
        MailTask? next = null;
        if (completed) {
            next = cache.complete_mail_task_occurrence (task.id, changed_at);
            var finished = cache.find_mail_task (task.id);
            if (finished != null) synchronize_saved (finished);
            if (next != null) synchronize_saved (next);
        } else {
            cache.set_mail_task_completed (task.id, false);
            var reopened = cache.find_mail_task (task.id);
            if (reopened != null) synchronize_saved (reopened);
        }
        update_linked_flag (task.message_id);
        changed ();
        return next;
    }

    public void delete (MailTask task) throws MailError {
        cache.remove_mail_task (task.id);
        try { sync_provider.task_deleted (task.id); }
        catch (Error error) { sync_failed (sync_provider.name, error.message); }
        update_linked_flag (task.message_id);
        changed ();
    }

    public MailTask? find (int64 id) throws MailError { return cache.find_mail_task (id); }

    public MailTask? open_task_for_message (string message_id) throws MailError {
        return cache.open_mail_task_for_message (message_id);
    }

    private static void validate (string title, string due_at, int recurrence_interval) throws MailError {
        string clean_title = title.strip ();
        if (clean_title == "") throw new MailError.STORAGE ("Task title is required");
        if (clean_title.length > 240) throw new MailError.STORAGE ("Task titles can contain up to 240 characters");
        if (MailTask.normalized_due_date (due_at) == null)
            throw new MailError.STORAGE ("Choose a valid task due date");
        if (recurrence_interval < 1 || recurrence_interval > 99)
            throw new MailError.STORAGE ("Task recurrence must be between 1 and 99");
    }

    private void update_linked_flag (string message_id) {
        if (message_id.strip () == "" || repository.find_message (message_id) == null) return;
        try {
            repository.set_flagged (message_id,
                cache.incomplete_mail_task_count_for_message (message_id) > 0);
        } catch (Error error) {
            warning ("Could not keep the linked email flag in sync: %s", error.message);
        }
    }

    private void synchronize_saved (MailTask task) {
        try { sync_provider.task_saved (task); }
        catch (Error error) { sync_failed (sync_provider.name, error.message); }
    }
}

public class TaskReminderService : Object {
    public signal void reminder_due (MailTask task);
    private CacheDatabase cache;
    private uint timer_source;

    public TaskReminderService (CacheDatabase cache) { this.cache = cache; }

    public void start () {
        if (timer_source != 0) return;
        dispatch_due (new DateTime.now_utc ().to_unix ());
        timer_source = Timeout.add_seconds (60, () => {
            dispatch_due (new DateTime.now_utc ().to_unix ());
            return Source.CONTINUE;
        });
    }

    public void stop () {
        if (timer_source == 0) return;
        Source.remove (timer_source); timer_source = 0;
    }

    public int dispatch_due (int64 now) {
        int delivered = 0;
        try {
            foreach (var task in cache.due_mail_task_reminders (now)) {
                // Mark first so an application crash after desktop delivery
                // cannot show the same reminder on every restart.
                cache.mark_mail_task_reminder_sent (task.id, now);
                reminder_due (task); delivered++;
            }
        } catch (Error error) {
            warning ("Could not check task reminders: %s", error.message);
        }
        return delivered;
    }

    ~TaskReminderService () { stop (); }
}
}
