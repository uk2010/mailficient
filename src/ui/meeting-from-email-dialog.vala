namespace Mailficient {
public class MeetingFromEmailDialog : Object {
    public static async CalendarMeetingDraft? choose (
        Gtk.Window parent, CalendarIntegrationService calendar_service,
        Message message, Cancellable? cancellable = null) throws Error {
        var now = new DateTime.now_local ();
        var initial = now.add_hours (1);
        initial = new DateTime.local (initial.get_year (), initial.get_month (),
            initial.get_day_of_month (), initial.get_hour (), 0, 0);
        var draft = calendar_service.meeting_from_message (
            message, initial, initial.add_hours (1));

        var fields = new Gtk.Box (Gtk.Orientation.VERTICAL, 10);
        fields.set_margin_top (8); fields.set_margin_bottom (4);

        var title_label = new Gtk.Label ("Meeting title");
        title_label.xalign = 0; title_label.add_css_class ("caption");
        var title = new Gtk.Entry (); title.text = draft.summary;
        title.activates_default = true;
        Accessibility.label (title, "Meeting title");
        fields.append (title_label); fields.append (title);

        var date_label = new Gtk.Label ("Date");
        date_label.xalign = 0; date_label.add_css_class ("caption");
        var date = new Gtk.Calendar (); date.select_day (initial);
        date.show_day_names = true; date.show_heading = true;
        Accessibility.label (date, "Meeting date");
        fields.append (date_label); fields.append (date);

        var timing = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        var hour = new Gtk.SpinButton.with_range (0, 23, 1);
        hour.value = initial.get_hour (); hour.wrap = true;
        hour.width_chars = 2; Accessibility.label (hour, "Meeting start hour");
        var colon = new Gtk.Label (":");
        var minute = new Gtk.SpinButton.with_range (0, 59, 5);
        minute.value = initial.get_minute (); minute.wrap = true;
        minute.width_chars = 2; Accessibility.label (minute, "Meeting start minute");
        timing.append (new Gtk.Label ("Start")); timing.append (hour);
        timing.append (colon); timing.append (minute);
        var duration_label = new Gtk.Label ("Duration");
        duration_label.set_margin_start (12); timing.append (duration_label);
        var duration = new Gtk.DropDown.from_strings ({
            "30 minutes", "1 hour", "90 minutes", "2 hours"
        });
        duration.selected = 1; duration.hexpand = true;
        Accessibility.label (duration, "Meeting duration");
        timing.append (duration); fields.append (timing);

        if (message.sender_address != "") {
            var attendee = new Gtk.Label ("Attendee: %s <%s>".printf (
                message.sender_name, message.sender_address));
            attendee.xalign = 0; attendee.wrap = true; attendee.add_css_class ("dim-label");
            fields.append (attendee);
        }
        var note = new Gtk.Label (
            "Mailficient saves a draft event to your default calendar and opens GNOME Calendar for review. It does not send an invitation automatically.");
        note.xalign = 0; note.wrap = true; note.add_css_class ("dim-label");
        fields.append (note);

        var dialog = new Adw.AlertDialog ("Create Meeting from Email",
            "Choose when to meet. The email subject and a bounded excerpt are included as context.");
        dialog.extra_child = fields;
        dialog.add_response ("cancel", "Cancel");
        dialog.add_response ("create", "Create Meeting");
        dialog.set_response_appearance ("create", Adw.ResponseAppearance.SUGGESTED);
        dialog.default_response = "create"; dialog.close_response = "cancel";
        if ((yield dialog.choose (parent, cancellable)) != "create") return null;

        string meeting_title = title.text.strip ();
        if (meeting_title == "")
            throw new CalendarError.CREATE_FAILED ("Enter a meeting title");
        var selected = date.get_date ();
        var start = new DateTime.local (selected.get_year (), selected.get_month (),
            selected.get_day_of_month (), (int) hour.value, (int) minute.value, 0);
        int minutes;
        switch (duration.selected) {
        case 0: minutes = 30; break;
        case 2: minutes = 90; break;
        case 3: minutes = 120; break;
        default: minutes = 60; break;
        }
        draft.summary = meeting_title; draft.start = start;
        draft.end = start.add_minutes (minutes);
        return draft;
    }
}
}
