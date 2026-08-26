namespace Mailficient {
public class NotificationService : Object {
    private Application application;
    public bool enabled { get; set; default = true; }

    public NotificationService (Application application) {
        this.application = application;
    }

    public void notify_new_message (Message message) {
        if (!enabled) return;
        var notification = new Notification (message.sender_name == "" ? "New message" : message.sender_name);
        notification.set_body (message.subject == "" ? "(No Subject)" : message.subject);
        notification.set_icon (new ThemedIcon ("mail-unread-symbolic"));
        notification.set_default_action_and_target_value ("app.open-message", new Variant.string (message.id));
        application.send_notification ("message-" + message.id, notification);
    }

    public void notify_task_reminder (MailTask task) {
        if (!enabled) return;
        var notification = new Notification ("Task reminder");
        notification.set_body (task.title);
        notification.set_icon (new ThemedIcon ("task-due-symbolic"));
        notification.set_default_action_and_target_value (
            "app.open-task", new Variant.int64 (task.id));
        application.send_notification ("task-" + task.id.to_string (), notification);
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
        application.send_notification ("new-mail-summary-" + summary.account_id, notification);
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
