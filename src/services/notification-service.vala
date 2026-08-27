namespace Mailficient {
internal interface NotificationBackend : Object {
    public abstract void send (string id, Notification notification);
    public abstract void withdraw (string id);
}

private class ApplicationNotificationBackend : Object, NotificationBackend {
    private Application application;

    public ApplicationNotificationBackend (Application application) {
        this.application = application;
    }

    public void send (string id, Notification notification) {
        application.send_notification (id, notification);
    }

    public void withdraw (string id) {
        application.withdraw_notification (id);
    }
}

public class NotificationService : Object {
    private NotificationBackend backend;
    private CacheDatabase? cache;
    private bool notifications_enabled = true;
    public bool enabled {
        get { return notifications_enabled; }
        set {
            if (notifications_enabled == value) return;
            notifications_enabled = value;
            if (!value) reconcile (true);
        }
    }

    public NotificationService (Application application) {
        backend = new ApplicationNotificationBackend (application);
    }

    internal NotificationService.with_backend (NotificationBackend backend) {
        this.backend = backend;
    }

    public void attach_cache (CacheDatabase cache) {
        this.cache = cache;
        reconcile (!enabled);
    }

    // Desktop notifications can remain in the shell after the application
    // exits. Their durable IDs are withdrawn before their journal rows are
    // removed, so an interruption simply repeats an idempotent withdrawal on
    // the next launch.
    public void reconcile (bool withdraw_all = false) {
        if (cache == null) return;
        try {
            var ids = withdraw_all ? cache.list_new_mail_notification_ids () :
                cache.list_stale_new_mail_notification_ids ();
            foreach (var id in ids) {
                backend.withdraw (id);
                cache.forget_new_mail_notification (id);
            }
        } catch (Error error) {
            warning ("Could not reconcile desktop mail notifications: %s", error.message);
        }
    }

    public void notify_new_message (Message message) {
        if (!enabled) return;
        var notification = new Notification (message.sender_name == "" ? "New message" : message.sender_name);
        notification.set_body (message.subject == "" ? "(No Subject)" : message.subject);
        notification.set_icon (new ThemedIcon ("mail-unread-symbolic"));
        notification.set_default_action_and_target_value ("app.open-message", new Variant.string (message.id));
        publish ("message-" + message.id, message.account_id, message.id, notification);
    }

    public void notify_task_reminder (MailTask task) {
        if (!enabled) return;
        var notification = new Notification ("Task reminder");
        notification.set_body (task.title);
        notification.set_icon (new ThemedIcon ("task-due-symbolic"));
        notification.set_default_action_and_target_value (
            "app.open-task", new Variant.int64 (task.id));
        backend.send ("task-" + task.id.to_string (), notification);
    }

    public void notify_new_mail (NewMailSummary summary) {
        if (!enabled || summary.total == 0) return;
        if (!summary.has_overflow ()) {
            foreach (var message in summary.samples) notify_new_message (message);
            return;
        }

        var notification = new Notification (summary_title (summary));
        notification.set_body (summary_body (summary));
        notification.set_icon (new ThemedIcon ("mail-unread-symbolic"));
        if (summary.samples.size > 0) {
            var latest = summary.samples[0];
            notification.set_default_action_and_target_value (
                "app.open-message", new Variant.string (latest.id));
        }
        publish ("new-mail-summary-" + summary.account_id,
            summary.account_id, "", notification);
    }

    private void publish (string id, string account_id, string message_id,
                          Notification notification) {
        if (cache != null) {
            try {
                cache.remember_new_mail_notification (id, account_id, message_id);
            } catch (Error error) {
                // Do not create a persistent shell notification that cannot be
                // reconciled after a restart.
                warning ("Could not preserve desktop mail notification: %s", error.message);
                return;
            }
        }
        backend.send (id, notification);
    }

    internal static string summary_title (NewMailSummary summary) {
        string count = summary.total == 1 ? "1 new message" :
            "%d new messages".printf (summary.total);
        return summary.account_label.strip () == "" ? count :
            "%s for %s".printf (count, summary.account_label);
    }

    internal static string summary_body (NewMailSummary summary) {
        if (summary.samples.size == 0) return "Open Mailficient to review them.";
        var sample = summary.samples[0];
        string sender = sample.sender_name.strip () == "" ? sample.sender_address : sample.sender_name;
        if (sender.strip () == "") sender = "Unknown sender";
        string subject = sample.subject.strip () == "" ? "(No Subject)" : sample.subject;
        return "Includes: %s — %s".printf (sender, subject);
    }
}
}
