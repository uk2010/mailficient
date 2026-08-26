namespace Mailficient {
// A compact mail-reader surface for one iTIP event. The calendar itself stays
// in Evolution Data Server; this card only shows the bounded invitation and
// forwards explicit user actions.
public class CalendarInvitationCard : Gtk.Box {
    public signal void response_requested (CalendarParticipation participation);
    public signal void open_requested ();

    private Gtk.Label response_status = new Gtk.Label ("");
    private Gee.ArrayList<Gtk.Button> response_buttons =
        new Gee.ArrayList<Gtk.Button> ();
    private Gtk.Spinner response_spinner = new Gtk.Spinner ();

    public CalendarInvitationCard (Message message, CalendarInvitation invitation,
                                   CalendarAttendee? account_attendee,
                                   bool direct_response_available) {
        Object (orientation: Gtk.Orientation.VERTICAL, spacing: 10);
        hexpand = true; halign = Gtk.Align.FILL;
        set_margin_start (30); set_margin_end (30);
        set_margin_top (16); set_margin_bottom (8);
        add_css_class ("card"); add_css_class ("calendar-invitation-card");

        var heading = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10);
        var icon = new Gtk.Image.from_icon_name (invitation.method ==
            CalendarInvitationMethod.CANCEL ? "appointment-missed-symbolic" :
            "x-office-calendar-symbolic");
        icon.pixel_size = 24; icon.valign = Gtk.Align.START;
        heading.append (icon);
        var title_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
        title_box.hexpand = true;
        var kind = new Gtk.Label (invitation.method == CalendarInvitationMethod.CANCEL ?
            "Meeting cancelled" : "Calendar invitation");
        kind.xalign = 0; kind.add_css_class ("caption"); kind.add_css_class ("dim-label");
        title_box.append (kind);
        var title = new Gtk.Label (invitation.summary);
        title.xalign = 0; title.wrap = true; title.selectable = true;
        title.add_css_class ("heading"); title_box.append (title);
        heading.append (title_box); append (heading);

        append_detail ("appointment-soon-symbolic", invitation.formatted_when ());
        if (invitation.location != "")
            append_detail ("mark-location-symbolic", invitation.location);
        if (invitation.organizer_display () != "")
            append_detail ("avatar-default-symbolic",
                "Organized by " + invitation.organizer_display ());
        string recurrence = invitation.recurrence_summary ();
        if (recurrence != "")
            append_detail ("view-refresh-symbolic", recurrence);

        if (invitation.description != "") {
            var description = new Gtk.Label (invitation.description);
            description.xalign = 0; description.wrap = true; description.selectable = true;
            description.lines = 4; description.ellipsize = Pango.EllipsizeMode.END;
            description.add_css_class ("dim-label"); append (description);
        }

        if (invitation.organizer_email != "" && message.sender_address != "" &&
            !invitation.organizer_matches_sender (message.sender_address)) {
            append_notice ("dialog-warning-symbolic",
                "The invitation organizer differs from the email sender. Verify it before responding.",
                "warning");
        }
        if (invitation.method == CalendarInvitationMethod.CANCEL ||
            invitation.status == "CANCELLED") {
            append_notice ("appointment-missed-symbolic",
                "This event was cancelled. Response actions are unavailable.", "error");
        }

        var actions = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
        actions.halign = Gtk.Align.START;
        bool actionable = invitation.can_respond () &&
            invitation.method == CalendarInvitationMethod.REQUEST &&
            invitation.status != "CANCELLED";
        if (actionable && account_attendee != null && direct_response_available) {
            append_response_button (actions, "Accept", CalendarParticipation.ACCEPTED,
                "suggested-action");
            append_response_button (actions, "Tentative", CalendarParticipation.TENTATIVE,
                "");
            append_response_button (actions, "Decline", CalendarParticipation.DECLINED,
                "destructive-action");
            set_response (account_attendee.participation);
        }
        var open = new Gtk.Button.with_label (actionable && !direct_response_available ?
            "Open in Calendar to Respond" : "Open in Calendar");
        open.add_css_class ("flat");
        open.tooltip_text = "Open the original invitation in your desktop calendar";
        Accessibility.label (open, open.tooltip_text);
        open.clicked.connect (() => open_requested ()); actions.append (open);
        response_spinner.spinning = false; response_spinner.visible = false;
        actions.append (response_spinner); append (actions);

        if (actionable && account_attendee == null) {
            response_status.label = "This mail account is not listed as an attendee.";
            response_status.add_css_class ("warning");
        } else if (actionable && !direct_response_available) {
            response_status.label =
                "Direct responses require Evolution Data Server calendar support.";
        }
        response_status.xalign = 0; response_status.wrap = true;
        response_status.add_css_class ("caption"); response_status.add_css_class ("dim-label");
        if (response_status.label != "") append (response_status);
    }

    public void set_busy (bool busy) {
        foreach (var button in response_buttons) button.sensitive = !busy;
        response_spinner.visible = busy; response_spinner.spinning = busy;
        if (busy) {
            response_status.label = "Updating your calendar…";
            response_status.visible = true;
        }
    }

    public void set_response (CalendarParticipation participation) {
        if (participation == CalendarParticipation.NEEDS_ACTION ||
            participation == CalendarParticipation.UNKNOWN) {
            response_status.label = "Response requested";
        } else {
            response_status.label = "Calendar response: " + participation.label ();
        }
        response_status.visible = true;
    }

    private void append_response_button (Gtk.Box actions, string label,
                                         CalendarParticipation participation,
                                         string css_class) {
        var button = new Gtk.Button.with_label (label);
        if (css_class != "") button.add_css_class (css_class);
        Accessibility.label (button, "%s calendar invitation".printf (label));
        button.clicked.connect (() => response_requested (participation));
        response_buttons.add (button); actions.append (button);
    }

    private void append_detail (string icon_name, string text) {
        var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        var icon = new Gtk.Image.from_icon_name (icon_name);
        icon.valign = Gtk.Align.START; row.append (icon);
        var label = new Gtk.Label (text);
        label.xalign = 0; label.wrap = true; label.selectable = true;
        label.hexpand = true; row.append (label); append (row);
    }

    private void append_notice (string icon_name, string text, string css_class) {
        var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        row.add_css_class ("calendar-invitation-notice");
        if (css_class != "") row.add_css_class (css_class);
        var icon = new Gtk.Image.from_icon_name (icon_name);
        icon.valign = Gtk.Align.START; row.append (icon);
        var label = new Gtk.Label (text);
        label.xalign = 0; label.wrap = true; label.hexpand = true; row.append (label);
        append (row);
    }
}
}
