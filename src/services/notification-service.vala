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
}
}
