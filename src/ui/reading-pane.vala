namespace Mailficient {
public class ReadingPane : Gtk.Box {
    public signal void vip_toggled (Message message, bool vip);
    public signal void attachment_saved (string filename);
    public signal void attachment_failed (Error error);
    public signal void remote_content_failed (Error error);
    public signal void remote_sender_trusted (string address);
    public signal void safe_sender_changed (string address, bool safe);
    public signal void phishing_report_requested (Message message);
    public signal void unsubscribe_requested (Message message, UnsubscribeTarget target);
    public signal void calendar_action_completed (string message);
    public signal void calendar_action_failed (Error error);
    public signal void add_account_requested ();
    private Gtk.Box content = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
    private Gtk.ScrolledWindow scroller = new Gtk.ScrolledWindow ();
    private ReceivedAttachmentService attachment_service;
    private RemoteContentPolicy remote_content_policy;
    private CalendarIntegrationService calendar_service;
    private CacheDatabase cache;
    private MessageSecurityService message_security = new MessageSecurityService ();
    private Cancellable? calendar_cancellable;
    private Message? current;
    private bool qa_preview_opened;
    private bool always_load_remote_content;
    private bool full_html_formatting;
    private uint scroll_reset_generation;
    private uint message_generation;
    private HtmlMessageView? current_html_view;
    private Gee.ArrayList<HtmlMessageView> html_views = new Gee.ArrayList<HtmlMessageView> ();
    private Gee.ArrayList<HtmlMessageView> html_view_pool = new Gee.ArrayList<HtmlMessageView> ();
    private Gee.ArrayList<ulong> html_layout_handlers = new Gee.ArrayList<ulong> ();
    private Gee.ArrayList<ulong> html_link_handlers = new Gee.ArrayList<ulong> ();
    private int constrained_width;

    public ReadingPane (ReceivedAttachmentService attachment_service,
                        RemoteContentPolicy remote_content_policy,
                        CalendarIntegrationService calendar_service,
                        CacheDatabase cache) {
        Object (orientation: Gtk.Orientation.VERTICAL);
        this.attachment_service = attachment_service;
        this.remote_content_policy = remote_content_policy;
        this.calendar_service = calendar_service;
        this.cache = cache;
        set_size_request (0, -1);
        hexpand = true;
        add_css_class ("reading-pane");
        content.hexpand = true; content.halign = Gtk.Align.FILL;
        content.set_size_request (0, -1);
        scroller.hscrollbar_policy = Gtk.PolicyType.NEVER;
        scroller.hexpand = true;
        scroller.propagate_natural_width = false;
        scroller.propagate_natural_height = false;
        scroller.set_child (content);
        // GtkScrolledWindow wraps non-scrollable content in a GtkViewport.
        // Its default focus handling scrolls a large WebKit child into view
        // when the user clicks the message, which can jump to the document's
        // bottom. The reader owns its position, so focus must not move it.
        var viewport = scroller.get_child () as Gtk.Viewport;
        if (viewport != null) viewport.scroll_to_focus = false;
        scroller.vexpand = true; append (scroller);
        show_empty ();
    }

    public void set_viewport_width (int width) {
        if (width <= 0) return;
        constrained_width = width;
        content.set_size_request (width, -1);
        foreach (var html_view in html_views)
            if (html_view.get_parent () != null) html_view.constrain_width (width);
    }

    public void zoom_in () {
        foreach (var html_view in html_views)
            if (html_view.get_parent () != null) html_view.zoom_in ();
    }

    public void zoom_out () {
        foreach (var html_view in html_views)
            if (html_view.get_parent () != null) html_view.zoom_out ();
    }

    public void show_message (Message message, Gee.List<Message>? conversation = null,
                              bool sender_is_vip = false, bool always_load_remote_content = false,
                              bool full_html_formatting = false) {
        message_generation++;
        current = message;
        this.always_load_remote_content = always_load_remote_content;
        this.full_html_formatting = full_html_formatting;
        replace_scroll_adjustment ();
        clear ();
        calendar_cancellable = new Cancellable ();
        var header = new Gtk.Box (Gtk.Orientation.VERTICAL, 7); header.hexpand = true; header.halign = Gtk.Align.FILL; header.add_css_class ("message-header");
        var subject_line = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8); subject_line.hexpand = true; subject_line.halign = Gtk.Align.FILL;
        var subject = new Gtk.Label (message.subject); subject.xalign = 0; subject.wrap = true; subject.hexpand = true; subject.add_css_class ("message-subject"); subject_line.append (subject);
        var vip = new Gtk.ToggleButton (); vip.icon_name = sender_is_vip ? "starred-symbolic" : "non-starred-symbolic";
        vip.active = sender_is_vip; vip.tooltip_text = sender_is_vip ? "Remove sender from VIPs" : "Add sender to VIPs";
        Accessibility.label (vip, vip.tooltip_text); vip.add_css_class ("flat");
        weak Gtk.ToggleButton weak_vip = vip;
        vip.toggled.connect (() => {
            if (weak_vip == null) return;
            weak_vip.icon_name = weak_vip.active ? "starred-symbolic" : "non-starred-symbolic";
            weak_vip.tooltip_text = weak_vip.active ? "Remove sender from VIPs" : "Add sender to VIPs";
            Accessibility.label (weak_vip, weak_vip.tooltip_text); vip_toggled (message, weak_vip.active);
        });
        var create_meeting = new Gtk.Button.from_icon_name ("appointment-new-symbolic");
        create_meeting.add_css_class ("flat");
        create_meeting.tooltip_text = "Create Meeting from Email";
        Accessibility.label (create_meeting, "Create meeting from this email");
        create_meeting.clicked.connect (() =>
            create_meeting_from_email.begin (message, create_meeting));
        subject_line.append (create_meeting);
        subject_line.append (vip); header.append (subject_line);
        if (message.labels.size > 0) {
            var labels = new Gtk.FlowBox (); labels.selection_mode = Gtk.SelectionMode.NONE;
            labels.max_children_per_line = 8; labels.column_spacing = 6; labels.row_spacing = 4;
            foreach (var item in message.labels) {
                var chip = new Gtk.Label (item.name); chip.add_css_class ("caption"); chip.add_css_class ("card");
                chip.set_margin_start (5); chip.set_margin_end (5); chip.set_margin_top (2); chip.set_margin_bottom (2);
                labels.append (chip);
            }
            header.append (labels);
        }
        content.append (header);
        if (conversation == null || conversation.size == 0) append_conversation_message (message, true);
        else foreach (var item in conversation) append_conversation_message (item, item.id == message.id);
        if (constrained_width > 0) set_viewport_width (constrained_width);
        string? qa_preview = Environment.get_variable ("MAILFICIENT_QA_PREVIEW");
        if (!qa_preview_opened && qa_preview != null && qa_preview != "" && message.attachments.size > 0) {
            int index = qa_preview == "image" && message.attachments.size > 1 ? 1 : 0;
            qa_preview_opened = true;
            Idle.add (() => { preview_attachment (message.attachments[index]); return Source.REMOVE; });
        }
        reset_scroll_to_top ();
    }

    private void reset_scroll_to_top () {
        uint generation = ++scroll_reset_generation;
        var adjustment = scroller.vadjustment;
        adjustment.value = adjustment.lower;
        int frame = 0;
        add_tick_callback ((widget, frame_clock) => {
            if (generation != scroll_reset_generation) return Source.REMOVE;
            var current_adjustment = scroller.vadjustment;
            current_adjustment.value = current_adjustment.lower;
            // GTK can restore the previous adjustment during either of the
            // first two allocations after replacing a large WebKit child.
            return ++frame < 2 ? Source.CONTINUE : Source.REMOVE;
        });
    }

    private void replace_scroll_adjustment () {
        // Do not carry an adjustment from the previously viewed message.
        // Replacing only the adjustment is safe inside a list click callback;
        // replacing the live scroller widget itself is not.
        scroller.vadjustment = new Gtk.Adjustment (0, 0, 0, 24, 240, 0);
    }

    private void append_conversation_message (Message message, bool expanded) {
        var card = new Gtk.Box (Gtk.Orientation.VERTICAL, 0); card.hexpand = true; card.halign = Gtk.Align.FILL; card.add_css_class ("conversation-message");
        var header_button = new Gtk.Button (); header_button.hexpand = true; header_button.halign = Gtk.Align.FILL; header_button.add_css_class ("flat");
        var sender_line = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10); sender_line.hexpand = true; sender_line.halign = Gtk.Align.FILL;
        sender_line.append (new Adw.Avatar (42, message.initials (), false));
        var sender_text = new Gtk.Box (Gtk.Orientation.VERTICAL, 1); sender_text.hexpand = true;
        var sender = new Gtk.Label ("<b>%s</b>  <span alpha='65%%'>&lt;%s&gt;</span>".printf (Markup.escape_text (message.sender_name), Markup.escape_text (message.sender_address)));
        sender.use_markup = true; sender.xalign = 0; sender.ellipsize = Pango.EllipsizeMode.END;
        sender.tooltip_text = "%s <%s>".printf (message.sender_name, message.sender_address);
        sender_text.append (sender);
        string recipient_detail = "to %s".printf (message.recipients);
        if (message.cc_recipients.strip () != "") recipient_detail += "\ncc %s".printf (message.cc_recipients);
        var recipients = new Gtk.Label (recipient_detail); recipients.xalign = 0; recipients.wrap = true;
        recipients.add_css_class ("dim-label"); sender_text.append (recipients); sender_line.append (sender_text);
        var time = new Gtk.Label (message.timestamp); time.add_css_class ("dim-label");
        time.ellipsize = Pango.EllipsizeMode.END; time.max_width_chars = 18; sender_line.append (time);
        header_button.child = sender_line; header_button.tooltip_text = expanded ? "Message details" : "Expand message";
        Accessibility.label (header_button, "%s message from %s".printf (expanded ? "Message details" : "Expand", message.sender_name));
        var header_actions = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 2);
        header_actions.hexpand = true; header_actions.append (header_button);
        var details_button = new Gtk.Button.from_icon_name ("security-high-symbolic");
        details_button.add_css_class ("flat"); details_button.valign = Gtk.Align.CENTER;
        details_button.tooltip_text = "Message security and raw headers";
        Accessibility.label (details_button, "View message security and raw headers");
        details_button.clicked.connect (() => show_security_details.begin (message));
        header_actions.append (details_button); card.append (header_actions);
        var revealer = new Gtk.Revealer (); revealer.hexpand = true; revealer.halign = Gtk.Align.FILL; revealer.reveal_child = expanded; revealer.transition_type = Gtk.RevealerTransitionType.SLIDE_DOWN;
        var message_content = new Gtk.Box (Gtk.Orientation.VERTICAL, 0); message_content.hexpand = true; message_content.halign = Gtk.Align.FILL; revealer.child = message_content;
        bool content_loaded = false;
        if (expanded) {
            populate_message_content (message, message_content);
            content_loaded = true;
        }
        card.append (revealer); card.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));
        weak Gtk.Button weak_header_button = header_button;
        weak Gtk.Revealer weak_revealer = revealer;
        header_button.clicked.connect (() => {
            // A header click may reveal an older collapsed message, but it
            // must never hide the message that is already open.
            if (weak_header_button == null || weak_revealer == null || weak_revealer.reveal_child) return;
            if (!content_loaded) {
                populate_message_content (message, message_content);
                content_loaded = true;
            }
            weak_revealer.reveal_child = true;
            weak_header_button.tooltip_text = "Message details";
            Accessibility.label (weak_header_button, "Message details from %s".printf (message.sender_name));
        });
        content.append (card);
    }

    private void populate_message_content (Message message, Gtk.Box message_content) {
        append_identity_security (message, message_content);
        if (message.security_status != "") {
            var security = new Adw.Banner (message.security_status);
            security.revealed = true; security.add_css_class ("security-notice");
            message_content.append (security);
        }
        append_unsubscribe (message, message_content);
        append_calendar_invitations (message, message_content);
        HtmlMessageView? html_view = null;
        if (message.body_html != "") {
            uint view_generation = message_generation;
            html_view = html_view_pool.size > 0 ? html_view_pool.remove_at (html_view_pool.size - 1) : new HtmlMessageView ();
            html_view.reset_for_reuse ();
            html_view.hexpand = true; html_view.halign = Gtk.Align.FILL; html_view.vexpand = true;
            html_views.add (html_view);
            if (current != null && message.id == current.id) current_html_view = html_view;
            var link_handler = html_view.link_requested.connect ((uri) => confirm_external_link.begin (uri));
            html_link_handlers.add (link_handler);
            // WebKit reports its final document height after GTK has already
            // restored the old scroll adjustment. Reassert the top whenever
            // the currently displayed message finishes laying out.
            var layout_handler = html_view.layout_changed.connect (() => {
                // Any message in a conversation can finish sizing after the
                // selected one. Each late size change alters the shared
                // scroller, so keep the new reader generation pinned to top.
                if (view_generation == message_generation) reset_scroll_to_top ();
            });
            html_layout_handlers.add (layout_handler);
        }
        bool sender_trusted = always_load_remote_content ||
            (message.has_remote_content && remote_content_policy.is_sender_trusted (message.sender_address));
        if (message.has_remote_content && !sender_trusted) {
            var notice_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0); notice_box.hexpand = true; notice_box.halign = Gtk.Align.FILL;
            notice_box.add_css_class ("remote-notice");
            var notice_text = new Gtk.Label ("Remote images are blocked to protect your privacy.");
            notice_text.xalign = 0; notice_text.wrap = true;
            var load = new Gtk.Button.with_label ("Load Remote Images");
            load.halign = Gtk.Align.START;
            load.add_css_class ("suggested-action");
            load.set_margin_top (8);
            Accessibility.label (load, "Load remote images in this message");
            load.clicked.connect (() => {
                if (html_view != null)
                    html_view.display (message.body_html, true, message.attachments,
                        full_html_formatting, print_header (message));
                notice_box.visible = false;
            });
            notice_box.append (notice_text);
            notice_box.append (load);
            var trust = new Gtk.Button.with_label ("Always Load for This Sender");
            trust.halign = Gtk.Align.START; trust.add_css_class ("flat"); trust.add_css_class ("caption");
            trust.set_margin_top (4); Accessibility.label (trust,
                "Always load remote images from " + message.sender_address);
            trust.tooltip_text = "Always load remote images from " + message.sender_address;
            trust.clicked.connect (() => {
                try {
                    remote_content_policy.trust_sender (message.sender_address);
                    if (html_view != null)
                        html_view.display (message.body_html, true, message.attachments,
                            full_html_formatting, print_header (message));
                    notice_box.visible = false; remote_sender_trusted (message.sender_address);
                } catch (Error error) { remote_content_failed (error); }
            });
            notice_box.append (trust); message_content.append (notice_box);
        }
        if (html_view != null && message.body_html.strip () != "") {
            html_view.display (message.body_html, sender_trusted, message.attachments,
                full_html_formatting, print_header (message));
            message_content.append (html_view);
        }
        else { var body = new Gtk.Label (message.body); body.hexpand = true; body.halign = Gtk.Align.FILL; body.xalign = 0; body.yalign = 0; body.wrap = true; body.selectable = true; body.add_css_class ("message-body"); message_content.append (body); }
        append_attachments (message, message_content);
    }

    public void show_empty () {
        current = null; clear ();
        var empty = new Adw.StatusPage (); empty.icon_name = "mail-read-symbolic"; empty.title = "Select a Message"; empty.description = "Choose a message from the list to read it."; empty.vexpand = true; empty.add_css_class ("empty-state"); content.append (empty);
    }

    public void show_no_accounts () {
        current = null; clear ();
        var status = new Adw.StatusPage (); status.icon_name = "mail-unread-symbolic";
        status.title = "Welcome to Mailficient";
        status.description = "Add an email account to receive, read, and send mail.";
        status.vexpand = true; status.add_css_class ("empty-state");
        var add = new Gtk.Button.with_label ("Add Email Account");
        add.halign = Gtk.Align.CENTER; add.add_css_class ("suggested-action");
        add.tooltip_text = "Set up IMAP and SMTP or choose a GNOME Online Account";
        Accessibility.label (add, "Add email account");
        add.clicked.connect (() => add_account_requested ()); status.child = add;
        content.append (status);
    }

    public void show_loading () {
        current = null; clear ();
        var status = new Adw.StatusPage (); status.title = "Loading Message";
        status.description = "Opening the cached message content…"; status.vexpand = true;
        var spinner = new Gtk.Spinner (); spinner.spinning = true; spinner.set_size_request (32, 32);
        status.child = spinner; content.append (status);
    }

    public bool is_scrolled_to_top () {
        return scroller.vadjustment.value <= scroller.vadjustment.lower + 1.0;
    }

    public async void export_current_pdf (string message_id, File destination) throws Error {
        if (current == null || current.id != message_id || current_html_view == null)
            throw new IOError.PENDING ("The formatted message is still loading");
        yield current_html_view.export_rendered_pdf (destination);
    }

    public bool qa_print_current_pdf (string path) {
        return current_html_view != null && current_html_view.qa_print_pdf (path);
    }

    public void qa_assert_scroll_stable (uint duration_ms) {
        var adjustment = scroller.vadjustment;
        double expected = adjustment.value;
        ulong handler_id = 0;
        handler_id = adjustment.notify["value"].connect (() => {
            if (Math.fabs (adjustment.value - expected) > 1.0)
                critical ("Reader position changed during a content click: %.1f to %.1f",
                    expected, adjustment.value);
        });
        Timeout.add (duration_ms, () => {
            if (handler_id != 0) adjustment.disconnect (handler_id);
            return Source.REMOVE;
        });
    }

    public void show_error (UserFacingError error) {
        current = null; clear ();
        var status = new Adw.StatusPage (); status.icon_name = "dialog-warning-symbolic";
        status.title = error.title; status.description = "%s\n%s".printf (error.description, error.suggestion);
        status.vexpand = true; status.add_css_class ("error-state");
        if (error.technical_detail != "") {
            var details = new Gtk.Expander ("Technical Details");
            details.halign = Gtk.Align.CENTER;
            var label = new Gtk.Label (error.technical_detail); label.selectable = true; label.wrap = true;
            details.child = label; status.child = details;
        }
        content.append (status);
    }
    private void clear () {
        if (calendar_cancellable != null) calendar_cancellable.cancel ();
        calendar_cancellable = null;
        current_html_view = null;
        for (int index = 0; index < html_views.size; index++) {
            var view = html_views[index];
            var layout_handler = html_layout_handlers[index];
            var link_handler = html_link_handlers[index];
            if (layout_handler != 0) view.disconnect (layout_handler);
            if (link_handler != 0) view.disconnect (link_handler);
            view.reset_for_reuse ();
            if (html_view_pool.size < 3) html_view_pool.add (view);
            else view.shutdown ();
        }
        html_views.clear ();
        html_layout_handlers.clear ();
        html_link_handlers.clear ();
        while (content.get_first_child () != null)
            content.remove ((Gtk.Widget) content.get_first_child ());
    }

    private string print_header (Message message) {
        string recipients = Markup.escape_text (message.recipients);
        string cc = message.cc_recipients.strip () == "" ? "" :
            "<p><strong>Cc:</strong> %s</p>".printf (
                Markup.escape_text (message.cc_recipients));
        return "<section class='mailficient-print-header'>" +
            "<h1>%s</h1>".printf (Markup.escape_text (message.subject)) +
            "<p><strong>From:</strong> %s &lt;%s&gt;</p>".printf (
                Markup.escape_text (message.sender_name),
                Markup.escape_text (message.sender_address)) +
            "<p><strong>To:</strong> %s</p>".printf (recipients) + cc +
            "<p><strong>Date:</strong> %s</p></section>".printf (
                Markup.escape_text (message.timestamp));
    }

    private bool sender_is_safe (Message message) {
        try { return cache.is_safe_sender (message.sender_address); }
        catch (Error error) { warning ("Could not inspect Safe Senders: %s", error.message); return false; }
    }

    private void append_identity_security (Message message, Gtk.Box target) {
        var assessment = message_security.assess (message, sender_is_safe (message));
        if ((int) assessment.level < (int) MessageThreatLevel.CAUTION) return;
        var card = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);
        card.hexpand = true; card.halign = Gtk.Align.FILL;
        card.set_margin_start (30); card.set_margin_end (30);
        card.set_margin_top (12); card.set_margin_bottom (4);
        card.add_css_class ("card"); card.add_css_class (assessment.level == MessageThreatLevel.DANGER ?
            "message-security-danger" : "message-security-warning");
        var heading = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        heading.append (new Gtk.Image.from_icon_name (assessment.level == MessageThreatLevel.DANGER ?
            "security-low-symbolic" : "dialog-warning-symbolic"));
        var title = new Gtk.Label (assessment.title); title.xalign = 0; title.wrap = true;
        title.hexpand = true; title.add_css_class ("heading"); heading.append (title); card.append (heading);
        int displayed = 0;
        foreach (var finding in assessment.findings) {
            if (displayed++ >= 3) break;
            var detail = new Gtk.Label (finding); detail.xalign = 0; detail.wrap = true;
            detail.selectable = true; card.append (detail);
        }
        var actions = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6); actions.halign = Gtk.Align.START;
        var details = new Gtk.Button.with_mnemonic ("_Security Details");
        Accessibility.label (details, "View message security details and raw headers");
        details.clicked.connect (() => show_security_details.begin (message)); actions.append (details);
        var report = new Gtk.Button.with_mnemonic ("Report _Phishing"); report.add_css_class ("destructive-action");
        Accessibility.label (report, "Report this message as phishing");
        report.clicked.connect (() => phishing_report_requested (message)); actions.append (report);
        card.append (actions); target.append (card);
    }

    private void append_unsubscribe (Message message, Gtk.Box target) {
        var targets = message_security.unsubscribe_targets (message); if (targets.size == 0) return;
        var card = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10);
        card.hexpand = true; card.halign = Gtk.Align.FILL;
        card.set_margin_start (30); card.set_margin_end (30);
        card.set_margin_top (10); card.set_margin_bottom (4);
        card.add_css_class ("card"); card.add_css_class ("unsubscribe-card");
        card.append (new Gtk.Image.from_icon_name ("mail-unread-symbolic"));
        var text = new Gtk.Box (Gtk.Orientation.VERTICAL, 2); text.hexpand = true;
        var title = new Gtk.Label ("Mailing list message"); title.xalign = 0; title.add_css_class ("heading");
        var note = new Gtk.Label ("The sender provided a standard unsubscribe option.");
        note.xalign = 0; note.wrap = true; note.add_css_class ("dim-label"); text.append (title); text.append (note);
        card.append (text);
        var button = new Gtk.Button.with_mnemonic ("_Unsubscribe…");
        Accessibility.label (button, "Choose how to unsubscribe from this mailing list");
        button.clicked.connect (() => choose_unsubscribe.begin (message, targets)); card.append (button);
        target.append (card);
    }

    private async void show_security_details (Message message) {
        var parent = get_root () as Gtk.Window; if (parent == null) return;
        bool safe = sender_is_safe (message); var assessment = message_security.assess (message, safe);
        var content_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 10);
        var summary = new Gtk.Label (assessment.title); summary.xalign = 0; summary.wrap = true;
        summary.add_css_class ("heading"); content_box.append (summary);
        foreach (var finding in assessment.findings) {
            var label = new Gtk.Label ("• " + finding); label.xalign = 0; label.wrap = true;
            label.selectable = true; content_box.append (label);
        }
        var caveat = new Gtk.Label (assessment.authentication_reported ?
            "Authentication results are reported by the receiving mail system. A pass is useful context, not an instruction to trust links or attachments." :
            "No SPF, DKIM, or DMARC result was retained for this message. Inspect the headers and sender before acting on sensitive requests.");
        caveat.xalign = 0; caveat.wrap = true; caveat.add_css_class ("dim-label"); content_box.append (caveat);
        var heading = new Gtk.Label ("Raw message headers (bounded to 64 KiB)");
        heading.xalign = 0; heading.add_css_class ("heading"); content_box.append (heading);
        var headers = new Gtk.TextView (); headers.editable = false; headers.cursor_visible = false;
        headers.monospace = true; headers.wrap_mode = Gtk.WrapMode.NONE;
        headers.buffer.text = MessageSecurityService.headers_for_display (message);
        Accessibility.label (headers, "Raw message headers");
        var scroller = new Gtk.ScrolledWindow (); scroller.child = headers;
        scroller.set_policy (Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC);
        scroller.set_size_request (680, 300); scroller.add_css_class ("card"); content_box.append (scroller);
        var dialog = new Adw.AlertDialog ("Message Security", "Review identity signals and original header fields.");
        dialog.extra_child = content_box; dialog.add_response ("close", "Close");
        dialog.add_response ("copy", "Copy Headers");
        if (RecipientParser.is_valid_address (message.sender_address))
            dialog.add_response ("safe", safe ? "Remove Safe Sender" : "Add Safe Sender");
        dialog.add_response ("phishing", "Report Phishing");
        dialog.set_response_appearance ("phishing", Adw.ResponseAppearance.DESTRUCTIVE);
        dialog.default_response = "close"; dialog.close_response = "close";
        string response = yield dialog.choose (parent, null);
        if (response == "copy") get_clipboard ().set_text (headers.buffer.text);
        else if (response == "safe") {
            try {
                cache.set_safe_sender (message.sender_address, !safe);
                safe_sender_changed (message.sender_address, !safe);
                if (current != null && current.id == message.id) show_message (message);
            } catch (Error error) { remote_content_failed (error); }
        } else if (response == "phishing") phishing_report_requested (message);
    }

    private async void choose_unsubscribe (Message message, Gee.List<UnsubscribeTarget> targets) {
        if (targets.size == 1) { unsubscribe_requested (message, targets[0]); return; }
        var parent = get_root () as Gtk.Window; if (parent == null) return;
        var dialog = new Adw.AlertDialog ("Unsubscribe", "Choose the method advertised by this mailing list.");
        dialog.add_response ("cancel", "Cancel"); dialog.close_response = "cancel";
        for (int index = 0; index < targets.size; index++)
            dialog.add_response ("target-%d".printf (index), targets[index].label);
        string response = yield dialog.choose (parent, null);
        if (!response.has_prefix ("target-")) return;
        int selected = -1;
        if (int.try_parse (response.substring (7), out selected) && selected >= 0 && selected < targets.size)
            unsubscribe_requested (message, targets[selected]);
    }

    private void append_calendar_invitations (Message message, Gtk.Box target) {
        int displayed = 0;
        foreach (var attachment in message.attachments) {
            if (!attachment.is_calendar_invitation ()) continue;
            if (displayed++ >= CalendarIntegrationService.MAX_DISPLAYED_INVITATIONS) break;
            var host = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            host.hexpand = true; host.halign = Gtk.Align.FILL;
            var loading = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            loading.set_margin_start (30); loading.set_margin_end (30);
            loading.set_margin_top (16); loading.set_margin_bottom (8);
            loading.add_css_class ("card"); loading.add_css_class ("calendar-invitation-card");
            var spinner = new Gtk.Spinner (); spinner.spinning = true;
            loading.append (spinner);
            var label = new Gtk.Label ("Reading calendar invitation…");
            label.xalign = 0; label.hexpand = true; loading.append (label);
            host.append (loading); target.append (host);
            uint generation = message_generation;
            var cancellable = calendar_cancellable;
            load_calendar_card.begin (message, attachment, host, generation, cancellable);
        }
    }

    private async void load_calendar_card (Message message, Attachment attachment,
                                           Gtk.Box host, uint generation,
                                           Cancellable? cancellable) {
        try {
            var invitation = yield calendar_service.load_invitation (
                message, attachment, cancellable);
            if (generation != message_generation || host.get_parent () == null) return;
            while (host.get_first_child () != null)
                host.remove ((Gtk.Widget) host.get_first_child ());
            var card = new CalendarInvitationCard (message, invitation,
                calendar_service.account_attendee (message, invitation),
                calendar_service.can_respond_directly);
            card.response_requested.connect ((participation) =>
                confirm_calendar_response.begin (message, invitation, participation, card));
            card.open_requested.connect (() =>
                open_parsed_invitation.begin (invitation));
            host.append (card);
            reset_scroll_to_top ();
        } catch (Error error) {
            if (error is IOError.CANCELLED || generation != message_generation ||
                host.get_parent () == null) return;
            while (host.get_first_child () != null)
                host.remove ((Gtk.Widget) host.get_first_child ());
            var notice = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            notice.set_margin_start (30); notice.set_margin_end (30);
            notice.set_margin_top (16); notice.set_margin_bottom (8);
            notice.add_css_class ("card"); notice.add_css_class ("calendar-invitation-card");
            notice.append (new Gtk.Image.from_icon_name ("dialog-warning-symbolic"));
            var label = new Gtk.Label (
                "Invitation details are unavailable. You can still open the original .ics attachment.");
            label.xalign = 0; label.wrap = true; label.hexpand = true;
            notice.append (label); host.append (notice);
        }
    }

    private async void confirm_calendar_response (
        Message message, CalendarInvitation invitation,
        CalendarParticipation participation, CalendarInvitationCard card) {
        var parent = get_root () as Gtk.Window;
        if (parent == null || card.get_parent () == null) return;
        string action = participation == CalendarParticipation.ACCEPTED ? "Accept" :
            (participation == CalendarParticipation.TENTATIVE ? "Mark Tentative" : "Decline");
        var send = new Gtk.CheckButton.with_label ("Send a response to the organizer");
        send.active = calendar_service.response_requested (message, invitation);
        send.tooltip_text =
            "When off, your calendar is updated without sending a reply";
        var dialog = new Adw.AlertDialog (action + " this invitation?",
            "Mailficient will update your default calendar. Sending a reply is optional.");
        dialog.extra_child = send;
        dialog.add_response ("cancel", "Cancel");
        dialog.add_response ("respond", action);
        dialog.set_response_appearance ("respond",
            participation == CalendarParticipation.DECLINED ?
                Adw.ResponseAppearance.DESTRUCTIVE : Adw.ResponseAppearance.SUGGESTED);
        dialog.default_response = "respond"; dialog.close_response = "cancel";
        try {
            if ((yield dialog.choose (parent, calendar_cancellable)) != "respond") return;
            card.set_busy (true);
            yield calendar_service.respond (message, invitation, participation,
                send.active, calendar_cancellable);
            if (card.get_parent () == null) return;
            card.set_busy (false); card.set_response (participation);
            calendar_action_completed (send.active ?
                "%s — response sent to the organizer".printf (participation.label ()) :
                "%s in your calendar — no response sent".printf (participation.label ()));
        } catch (Error error) {
            if (card.get_parent () != null) card.set_busy (false);
            if (!(error is IOError.CANCELLED)) calendar_action_failed (error);
        }
    }

    private async void open_parsed_invitation (CalendarInvitation invitation) {
        try { yield calendar_service.open_invitation (invitation, calendar_cancellable); }
        catch (Error error) {
            if (!(error is IOError.CANCELLED)) calendar_action_failed (error);
        }
    }

    private async void create_meeting_from_email (Message message, Gtk.Button button) {
        var parent = get_root () as Gtk.Window;
        if (parent == null) return;
        button.sensitive = false;
        var spinner = new Gtk.Spinner (); spinner.spinning = true; button.child = spinner;
        try {
            var meeting = yield MeetingFromEmailDialog.choose (
                parent, calendar_service, message, calendar_cancellable);
            if (meeting == null) return;
            var disposition = yield calendar_service.create_meeting (
                meeting, calendar_cancellable);
            calendar_action_completed (disposition == CalendarCreateDisposition.CREATED ?
                "Meeting added to your default calendar" :
                "Meeting opened in your calendar for review");
        } catch (Error error) {
            if (!(error is IOError.CANCELLED)) calendar_action_failed (error);
        } finally {
            if (button.get_parent () != null) {
                button.child = null; button.icon_name = "appointment-new-symbolic";
                button.sensitive = true;
            }
        }
    }

    private void append_attachments (Message message, Gtk.Box target) {
        if (!message.has_attachment && message.attachments.size == 0) return;

        var section = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
        section.set_margin_start (30); section.set_margin_end (30);
        section.set_margin_top (18); section.set_margin_bottom (20);
        string attachment_title;
        if (message.attachments.size == 0) attachment_title = "Attachments";
        else if (message.attachments.size == 1) attachment_title = "1 Attachment";
        else attachment_title = "%d Attachments".printf (message.attachments.size);
        var title = new Gtk.Label (attachment_title);
        title.xalign = 0; title.add_css_class ("heading"); section.append (title);

        if (message.attachments.size == 0) {
            var unavailable = new Gtk.Label (
                "Attachment details are unavailable. Very large attachments remain on the server and are not cached automatically.");
            unavailable.xalign = 0; unavailable.wrap = true; unavailable.add_css_class ("dim-label");
            section.append (unavailable);
        } else {
            foreach (var attachment in message.attachments) {
                var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
                row.add_css_class ("attachment-row");
                row.append (new Gtk.Image.from_icon_name ("mail-attachment-symbolic"));
                var label = new Gtk.Label ("%s  ·  %s".printf (
                    attachment.name, attachment.formatted_size ()));
                label.ellipsize = Pango.EllipsizeMode.MIDDLE; label.max_width_chars = 52; label.hexpand = true; label.xalign = 0;
                row.append (label);
                if (attachment.is_downloaded () &&
                    AttachmentSafety.preview_kind (attachment.content_type, attachment.name) != AttachmentPreviewKind.NONE) {
                    var preview = new Gtk.Button.with_label ("Preview");
                    preview.add_css_class ("flat"); preview.tooltip_text = "Preview attachment in Mailficient";
                    Accessibility.label (preview, "Preview attachment %s".printf (attachment.name));
                    preview.clicked.connect (() => preview_attachment (attachment));
                    row.append (preview);
                }
                if (attachment.is_calendar_invitation ()) {
                    var calendar = new Gtk.Button.with_label ("Open .ics");
                    calendar.add_css_class ("flat");
                    calendar.tooltip_text = "Open this invitation in your desktop calendar";
                    Accessibility.label (calendar,
                        "Open calendar invitation %s".printf (attachment.name));
                    weak Gtk.Button weak_calendar = calendar;
                    calendar.clicked.connect (() => {
                        if (weak_calendar != null)
                            open_calendar_invitation.begin (message, attachment, weak_calendar);
                    });
                    row.append (calendar);
                }
                var save = new Gtk.Button.from_icon_name ("document-save-symbolic");
                save.add_css_class ("flat");
                save.icon_name = attachment.is_downloaded () ?
                    "document-save-symbolic" : "folder-download-symbolic";
                save.tooltip_text = attachment.is_downloaded () ?
                    "Save attachment" : "Download attachment from the mail server";
                Accessibility.label (save, "%s %s, %s".printf (
                    attachment.is_downloaded () ? "Save attachment" : "Download attachment",
                    attachment.name, attachment.formatted_size ()));
                weak Gtk.Button weak_save = save;
                save.clicked.connect (() => {
                    if (weak_save != null)
                        choose_attachment_destination.begin (message, attachment, weak_save);
                });
                row.append (save);
                section.append (row);
            }
        }
        target.append (section);
    }

    private void preview_attachment (Attachment attachment) {
        var root_window = get_root () as Gtk.Window;
        if (root_window == null) return;
        new AttachmentPreviewWindow (root_window, attachment).present ();
    }

    private async void open_calendar_invitation (Message message, Attachment attachment,
                                                  Gtk.Button button) {
        button.sensitive = false;
        var spinner = new Gtk.Spinner (); spinner.spinning = true; button.child = spinner;
        File? staged = null;
        try {
            staged = yield attachment_service.stage_calendar_invitation (message, attachment);
            AppInfo.launch_default_for_uri (staged.get_uri (), null);
            // Desktop calendar applications and portals may read the file after
            // launch returns. Keep it briefly, then remove the private copy.
            File cleanup_file = staged;
            Timeout.add_seconds (300, () => {
                try {
                    if (cleanup_file.query_exists ()) cleanup_file.delete (null);
                } catch (Error ignored) { }
                return Source.REMOVE;
            });
            staged = null;
        } catch (Error error) {
            if (staged != null) {
                try {
                    if (staged.query_exists ()) staged.delete (null);
                } catch (Error ignored) { }
            }
            attachment_failed (error);
        } finally {
            button.child = null;
            button.label = "Open .ics";
            button.sensitive = true;
        }
    }

    private async void choose_attachment_destination (Message message, Attachment attachment,
                                                       Gtk.Button button) {
        var root_window = get_root () as Gtk.Window;
        if (root_window == null) return;
        var dialog = new Gtk.FileDialog ();
        dialog.title = "Save Attachment"; dialog.accept_label = "Save";
        dialog.initial_name = AttachmentSafety.safe_filename (attachment.name);
        try {
            var destination = yield dialog.save (root_window, null);
            button.sensitive = false;
            var spinner = new Gtk.Spinner (); spinner.spinning = true; button.child = spinner;
            yield attachment_service.save (message, attachment, destination);
            attachment_saved (destination.get_basename ());
        } catch (Error error) {
            if (!(error is IOError.CANCELLED)) attachment_failed (error);
        } finally {
            button.child = null;
            button.icon_name = attachment.is_downloaded () ?
                "document-save-symbolic" : "folder-download-symbolic";
            button.sensitive = true;
        }
    }

    private async void confirm_external_link (string uri) {
        var root_window = get_root () as Gtk.Window; if (root_window == null) return;
        var dialog = new Adw.AlertDialog ("Open this link?", uri);
        dialog.body_use_markup = false;
        dialog.add_response ("cancel", "Cancel"); dialog.add_response ("open", "Open Link");
        dialog.default_response = "cancel"; dialog.close_response = "cancel";
        if ((yield dialog.choose (root_window, null)) != "open") return;
        try { AppInfo.launch_default_for_uri (uri, null); }
        catch (Error error) { warning ("Could not open external link: %s", error.message); }
    }
}
}
