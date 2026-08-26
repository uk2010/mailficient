namespace Mailficient {
public class OutboxStatusView : Gtk.Box {
    public OutboxStatusView (OutboxItem item) {
        Object (orientation: Gtk.Orientation.VERTICAL, spacing: 3);
        add_css_class ("outbox-status");

        string title;
        string description;
        string icon_name;
        if (item.can_undo ()) {
            int64 remaining = int64.max (1,
                item.undo_until - new DateTime.now_utc ().to_unix ());
            title = "Undo Send available";
            description = "This message is safe in Outbox and cannot leave for %s. Choose Undo to keep editing.".printf (
                remaining == 1 ? "1 more second" : "%lld more seconds".printf (remaining));
            icon_name = "edit-undo-symbolic";
            add_css_class ("undo-send");
        } else if (item.delivery_state == OutboxDeliveryState.SENDING) {
            title = "Delivery could not be confirmed";
            description = "This message may already have been delivered. Check Sent mail before sending another copy.";
            icon_name = "dialog-warning-symbolic";
            add_css_class ("uncertain");
        } else if (item.delivery_state == OutboxDeliveryState.ACCEPTED) {
            title = "Accepted by the mail server";
            description = "Mailficient is waiting to finish local Outbox cleanup. This message cannot be sent again.";
            icon_name = "object-select-symbolic";
            add_css_class ("accepted");
        } else if (item.delivery_state == OutboxDeliveryState.PREPARING) {
            title = "Sending…";
            description = "Mailficient is sending this message in the background. Editing and deletion are paused until it finishes.";
            icon_name = "mail-send-symbolic";
            add_css_class ("preparing");
        } else if (item.delivery_state == OutboxDeliveryState.REJECTED) {
            title = "Mail server rejected this message";
            description = "Review the technical details, correct the message, and try again. It will not retry automatically.";
            icon_name = "dialog-error-symbolic";
            add_css_class ("rejected");
        } else if (item.attempts == 0 && item.next_attempt_at > new DateTime.now_utc ().to_unix ()) {
            title = "Scheduled to send";
            var scheduled = new DateTime.from_unix_local (item.next_attempt_at);
            description = "Mailficient will send this message after %s in the background.".printf (
                scheduled == null ? "the selected time" : scheduled.format ("%b %e at %l:%M %p").strip ());
            icon_name = "alarm-symbolic";
            add_css_class ("scheduled");
        } else if (item.attempts > 0) {
            title = "Previous send attempt failed";
            description = "The message is safe in Outbox and will retry automatically, or you can try again now.";
            icon_name = "network-error-symbolic";
            add_css_class ("retrying");
        } else {
            title = "Waiting in Outbox";
            description = "This message is saved locally and will be delivered when the account is connected.";
            icon_name = "mail-send-symbolic";
            add_css_class ("waiting");
        }

        var heading = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        var icon = new Gtk.Image.from_icon_name (icon_name); icon.valign = Gtk.Align.START;
        heading.append (icon);
        var copy = new Gtk.Box (Gtk.Orientation.VERTICAL, 2); copy.hexpand = true;
        var title_label = new Gtk.Label (title); title_label.xalign = 0;
        title_label.add_css_class ("heading"); copy.append (title_label);
        var description_label = new Gtk.Label (description); description_label.xalign = 0;
        description_label.wrap = true; copy.append (description_label); heading.append (copy);
        append (heading);
        Accessibility.label (this, "%s. %s".printf (title, description));

        if (item.last_error.strip () != "") {
            var details = new Gtk.Expander ("Technical Details");
            details.set_margin_start (24);
            var detail = new Gtk.Label (item.last_error); detail.xalign = 0;
            detail.wrap = true; detail.selectable = true; detail.add_css_class ("dim-label");
            details.child = detail; append (details);
        }
    }
}
}
