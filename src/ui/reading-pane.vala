namespace Mailficient {
public class ReadingPane : Gtk.Box {
    internal static int qa_live_message_actions;
    private const int MAX_POOLED_HTML_VIEWS = 1;
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
    public signal void retry_requested ();
    public signal void account_settings_requested ();
    private Gtk.Box content = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
    private Gtk.ScrolledWindow scroller = new Gtk.ScrolledWindow ();
    private ReceivedAttachmentService attachment_service;
    private RemoteContentPolicy remote_content_policy;
    private CalendarIntegrationService calendar_service;
    private CacheDatabase cache;
    private MailSettingsStore settings;
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
    private bool tracks_available_width;
    private int last_available_width = -1;
    private bool shutting_down;
    private bool suspended;
    private Gtk.Widget? recovery_notice;

    public ReadingPane (ReceivedAttachmentService attachment_service,
                        RemoteContentPolicy remote_content_policy,
                        CalendarIntegrationService calendar_service,
                        CacheDatabase cache) {
        Object (orientation: Gtk.Orientation.VERTICAL);
        this.attachment_service = attachment_service;
        this.remote_content_policy = remote_content_policy;
        this.calendar_service = calendar_service;
        this.cache = cache;
        this.settings = new MailSettingsStore (cache);
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
        if (shutting_down) return;
        if (width <= 0) return;
        tracks_available_width = false;
        last_available_width = -1;
        constrained_width = width;
        content.set_size_request (width, -1);
        foreach (var html_view in html_views)
            if (html_view.get_parent () != null) html_view.constrain_width (width);
    }

    public void use_available_width () {
        if (shutting_down) return;
        tracks_available_width = true;
        constrained_width = 0;
        last_available_width = -1;
        content.set_size_request (0, -1);
        var adjustment = scroller.hadjustment;
        adjustment.value = adjustment.lower;
        queue_resize ();
    }

    public override void size_allocate (int width, int height, int baseline) {
        base.size_allocate (width, height, baseline);
        if (!tracks_available_width || shutting_down) return;
        int available = scroller.get_width ();
        if (available <= 0) available = width;
        if (available <= 0 || available == last_available_width) return;
        last_available_width = available;
        foreach (var html_view in html_views)
            if (html_view.get_parent () != null)
                html_view.constrain_width (available);
        var adjustment = scroller.hadjustment;
        adjustment.value = adjustment.lower;
    }

    public void zoom_in () {
        if (shutting_down) return;
        foreach (var html_view in html_views)
            if (html_view.get_parent () != null) html_view.zoom_in ();
    }

    public void zoom_out () {
        if (shutting_down) return;
        foreach (var html_view in html_views)
            if (html_view.get_parent () != null) html_view.zoom_out ();
    }

    public void show_message (Message message, Gee.List<Message>? conversation = null,
                              bool sender_is_vip = false, bool always_load_remote_content = false,
                              bool full_html_formatting = false) {
        if (shutting_down) return;
        suspended = false;
        message_generation++;
        current = message;
        this.always_load_remote_content = always_load_remote_content;
        this.full_html_formatting = full_html_formatting;
        replace_scroll_adjustment ();
        clear ();
        calendar_cancellable = new Cancellable ();
        var header = new Gtk.Box (Gtk.Orientation.VERTICAL, 7); header.hexpand = true; header.halign = Gtk.Align.FILL; header.add_css_class ("message-header");
        var subject_line = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8); subject_line.hexpand = true; subject_line.halign = Gtk.Align.FILL;
        subject_line.add_css_class ("reader-subject-line");
        var subject = new Gtk.Label (message.subject); subject.xalign = 0; subject.wrap = true; subject.hexpand = true; subject.add_css_class ("message-subject"); subject_line.append (subject);
        var vip = new Gtk.ToggleButton (); vip.icon_name = sender_is_vip ? "starred-symbolic" : "non-starred-symbolic";
        vip.active = sender_is_vip; vip.tooltip_text = sender_is_vip ? "Remove sender from VIPs" : "Add sender to VIPs";
        Accessibility.label (vip, vip.tooltip_text); vip.add_css_class ("flat");
        vip.add_css_class ("reader-subject-action");
        weak Gtk.ToggleButton weak_vip = vip;
        vip.toggled.connect (() => {
            if (weak_vip == null) return;
            weak_vip.icon_name = weak_vip.active ? "starred-symbolic" : "non-starred-symbolic";
            weak_vip.tooltip_text = weak_vip.active ? "Remove sender from VIPs" : "Add sender to VIPs";
            Accessibility.label (weak_vip, weak_vip.tooltip_text); vip_toggled (message, weak_vip.active);
        });
        var create_meeting = new Gtk.Button.from_icon_name ("appointment-new-symbolic");
        qa_live_message_actions++;
        create_meeting.weak_ref ((object) => qa_live_message_actions--);
        create_meeting.add_css_class ("flat");
        create_meeting.add_css_class ("reader-subject-action");
        create_meeting.tooltip_text = "Create Meeting from Email";
        Accessibility.label (create_meeting, "Create meeting from this email");
        weak Gtk.Button weak_create_meeting = create_meeting;
        create_meeting.clicked.connect (() => {
            if (weak_create_meeting != null)
                create_meeting_from_email.begin (message, weak_create_meeting);
        });
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
        if (tracks_available_width) {
            int available = scroller.get_width ();
            if (available <= 0) available = get_width ();
            if (available > 0) {
                last_available_width = available;
                foreach (var html_view in html_views)
                    if (html_view.get_parent () != null)
                        html_view.constrain_width (available);
            }
        } else if (constrained_width > 0) {
            set_viewport_width (constrained_width);
        }
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

    private string compact_recipient_summary (Message message) {
        try {
            var recipients = RecipientParser.parse (message.recipients);
            string own_address = "";
            try {
                var account = cache.find_account (message.account_id);
                if (account != null) own_address = account.email.down ();
            } catch (Error ignored) { }

            bool includes_me = false;
            foreach (var recipient in recipients)
                if (own_address != "" && recipient.address.down () == own_address) {
                    includes_me = true;
                    break;
                }
            string summary = includes_me ? "to me" : "to " + recipient_display_name (recipients[0]);
            int additional = recipients.size - 1;
            if (additional > 0) summary += " +%d".printf (additional);
            if (message.cc_recipients.strip () != "") {
                try {
                    int cc_count = RecipientParser.parse (message.cc_recipients).size;
                    summary += " · cc %d".printf (cc_count);
                } catch (Error ignored) { summary += " · cc"; }
            }
            return summary;
        } catch (Error error) {
            string fallback = message.recipients.strip ();
            int address_start = fallback.index_of_char ('<');
            if (address_start > 0) fallback = fallback.substring (0, address_start).strip ();
            return fallback == "" ? "Recipients unavailable" : "to " + fallback;
        }
    }

    private static string recipient_display_name (Recipient recipient) {
        return recipient.name.strip () == "" ? recipient.address : recipient.name;
    }

    private void append_conversation_message (Message message, bool expanded) {
        var card = new Gtk.Box (Gtk.Orientation.VERTICAL, 0); card.hexpand = true; card.halign = Gtk.Align.FILL; card.add_css_class ("conversation-message");
        card.add_css_class (expanded ? "conversation-expanded" : "conversation-collapsed");
        var header_button = new Gtk.Button (); header_button.hexpand = true; header_button.halign = Gtk.Align.FILL; header_button.add_css_class ("flat");
        header_button.add_css_class ("conversation-header-button");
        var sender_line = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 9);
        sender_line.add_css_class ("conversation-sender-line");
        sender_line.hexpand = true; sender_line.halign = Gtk.Align.FILL;
        var sender_avatar = new Gtk.Button.with_label (message.initials ());
        sender_avatar.set_size_request (36, 36);
        sender_avatar.halign = Gtk.Align.CENTER;
        sender_avatar.valign = Gtk.Align.CENTER;
        sender_avatar.focusable = false;
        sender_avatar.can_target = false;
        sender_avatar.add_css_class ("sender-avatar");
        sender_avatar.add_css_class ("circular");
        sender_avatar.add_css_class ("avatar-tone-%u".printf (
            str_hash (message.sender_address) % 6));
        sender_line.append (sender_avatar);
        var sender_text = new Gtk.Box (Gtk.Orientation.VERTICAL, 2); sender_text.hexpand = true;
        sender_text.add_css_class ("conversation-sender-meta");
        var primary = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        var sender = new Gtk.Label (message.sender_name);
        sender.xalign = 0; sender.hexpand = true;
        sender.ellipsize = Pango.EllipsizeMode.END;
        sender.add_css_class ("heading");
        sender.tooltip_text = "%s <%s>".printf (message.sender_name, message.sender_address);
        primary.append (sender);
        var time = new Gtk.Label (message.timestamp); time.add_css_class ("dim-label");
        time.ellipsize = Pango.EllipsizeMode.END; time.max_width_chars = 12;
        time.xalign = 1; primary.append (time); sender_text.append (primary);
        var recipients = new Gtk.Label (compact_recipient_summary (message));
        recipients.xalign = 0; recipients.ellipsize = Pango.EllipsizeMode.END;
        string recipient_tooltip = "To: %s".printf (message.recipients);
        if (message.cc_recipients.strip () != "")
            recipient_tooltip += "\nCc: %s".printf (message.cc_recipients);
        recipients.tooltip_text = recipient_tooltip;
        recipients.add_css_class ("dim-label"); sender_text.append (recipients);
        sender_line.append (sender_text);
        header_button.child = sender_line; header_button.tooltip_text = expanded ? "Message details" : "Expand message";
        Accessibility.label (header_button, "%s message from %s".printf (expanded ? "Message details" : "Expand", message.sender_name));
        var header_actions = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 2);
        header_actions.add_css_class ("conversation-header-actions");
        header_actions.hexpand = true; header_actions.append (header_button);
        var details_button = new Gtk.Button.from_icon_name ("security-high-symbolic");
        details_button.add_css_class ("flat"); details_button.valign = Gtk.Align.CENTER;
        details_button.add_css_class ("conversation-details-button");
        details_button.tooltip_text = "Message security and raw headers";
        Accessibility.label (details_button, "View message security and raw headers");
        details_button.clicked.connect (() => show_security_details (
            hydrated_message (message)));
        header_actions.append (details_button); card.append (header_actions);
        var revealer = new Gtk.Revealer (); revealer.hexpand = true; revealer.halign = Gtk.Align.FILL; revealer.reveal_child = expanded; revealer.transition_type = Gtk.RevealerTransitionType.SLIDE_DOWN;
        var message_content = new Gtk.Box (Gtk.Orientation.VERTICAL, 0); message_content.hexpand = true; message_content.halign = Gtk.Align.FILL;
        message_content.add_css_class ("conversation-content"); revealer.child = message_content;
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
                // Conversation discovery returns lightweight summaries for
                // collapsed messages. Load one full body only when the user
                // actually expands that part of the thread.
                populate_message_content (hydrated_message (message), message_content);
                content_loaded = true;
            }
            weak_revealer.reveal_child = true;
            weak_header_button.tooltip_text = "Message details";
            Accessibility.label (weak_header_button, "Message details from %s".printf (message.sender_name));
        });
        content.append (card);
    }

    private Message hydrated_message (Message summary) {
        if (current != null && current.id == summary.id) return current;
        try { return cache.find_cached_message (summary.id) ?? summary; }
        catch (Error error) {
            warning ("Could not load conversation message %s: %s",
                summary.id, error.message);
            return summary;
        }
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
            // A pooled renderer can outlive the message subtree that owned it.
            // Always sever that direct GTK parent before attaching it to the
            // next message, even if an earlier teardown was interrupted.
            if (!detach_html_view (html_view))
                html_view = new HtmlMessageView ();
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
        bool authenticated_sender = sender_authenticated_for_remote_content (message);
        bool sender_trusted = always_load_remote_content ||
            (message.has_remote_content && authenticated_sender &&
                remote_content_policy.is_sender_trusted (message.sender_address));
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
            weak Gtk.Box weak_notice_box = notice_box;
            load.clicked.connect (() => {
                if (html_view != null)
                    html_view.display (message.body_html, true, message.attachments,
                        full_html_formatting, print_header (message));
                if (weak_notice_box != null) weak_notice_box.visible = false;
            });
            notice_box.append (notice_text);
            notice_box.append (load);
            var trust = new Gtk.Button.with_label ("Always Load for Authenticated Mail from This Sender");
            trust.halign = Gtk.Align.START; trust.add_css_class ("flat"); trust.add_css_class ("caption");
            trust.set_margin_top (4); Accessibility.label (trust,
                "Always load remote images from authenticated mail sent by " + message.sender_address);
            trust.tooltip_text = "Future messages must pass trusted DMARC authentication before images load automatically.";
            trust.clicked.connect (() => {
                try {
                    remote_content_policy.trust_sender (message.sender_address);
                    if (html_view != null)
                        html_view.display (message.body_html, true, message.attachments,
                            full_html_formatting, print_header (message));
                    if (weak_notice_box != null) weak_notice_box.visible = false;
                    remote_sender_trusted (message.sender_address);
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
        if (shutting_down) return;
        current = null; clear ();
        var empty = new Adw.StatusPage (); empty.icon_name = "mail-read-symbolic";
        empty.title = "No Message Selected";
        empty.description = "Messages you select will appear here.";
        empty.vexpand = true; empty.add_css_class ("empty-state"); content.append (empty);
    }

    // The workspace stack hides the reader while tasks are open. Preserve the
    // complete reader tree and its selection so opening Today/Events does no
    // WebKit or GtkListView teardown, and returning to mail does not reload the
    // same HTML message.
    public void suspend () {
        if (shutting_down) return;
        suspended = true;
    }

    public bool resume_message (string message_id) {
        if (shutting_down || !suspended || current == null ||
            current.id != message_id) return false;
        suspended = false;
        return true;
    }

    public void show_no_accounts () {
        if (shutting_down) return;
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
        if (shutting_down) return;
        current = null; clear ();
        var status = new Adw.StatusPage (); status.title = "Loading Message";
        status.description = "Opening the cached message content…"; status.vexpand = true;
        status.accessible_role = Gtk.AccessibleRole.STATUS;
        status.update_state (Gtk.AccessibleState.BUSY, true, -1);
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
        if (shutting_down) return;
        if (current != null) {
            if (recovery_notice != null && recovery_notice.get_parent () == content)
                content.remove (recovery_notice);
            var banner = new Adw.Banner (error.title);
            banner.button_label = "Try Again"; banner.revealed = true;
            banner.accessible_role = Gtk.AccessibleRole.ALERT;
            banner.update_property (Gtk.AccessibleProperty.DESCRIPTION,
                "%s %s".printf (error.description, error.suggestion), -1);
            banner.button_clicked.connect (() => {
                banner.revealed = false; recovery_notice = null; retry_requested ();
            });
            recovery_notice = banner; content.prepend (banner);
            return;
        }
        current = null; clear ();
        var status = new Adw.StatusPage (); status.icon_name = "dialog-warning-symbolic";
        status.title = error.title; status.description = "%s\n%s".printf (error.description, error.suggestion);
        status.vexpand = true; status.add_css_class ("error-state"); status.accessible_role = Gtk.AccessibleRole.ALERT;
        var controls = new Gtk.Box (Gtk.Orientation.VERTICAL, 10); controls.halign = Gtk.Align.CENTER;
        var actions = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8); actions.halign = Gtk.Align.CENTER;
        var settings_button = new Gtk.Button.with_label ("Account Settings");
        settings_button.clicked.connect (() => account_settings_requested ());
        var retry = new Gtk.Button.with_label ("Try Again"); retry.add_css_class ("suggested-action");
        retry.clicked.connect (() => retry_requested ());
        actions.append (settings_button); actions.append (retry); controls.append (actions);
        if (error.technical_detail != "") {
            var details = new Gtk.Expander ("Technical Details");
            details.halign = Gtk.Align.CENTER;
            var label = new Gtk.Label (error.technical_detail); label.selectable = true; label.wrap = true;
            details.child = label; controls.append (details);
        }
        status.child = controls;
        content.append (status);
    }
    private void clear () {
        // Invalidate every callback captured by the outgoing reader tree,
        // including clears that do not immediately display another message.
        message_generation++;
        if (calendar_cancellable != null) calendar_cancellable.cancel ();
        calendar_cancellable = null;
        current_html_view = null;
        for (int index = 0; index < html_views.size; index++) {
            var view = html_views[index];
            var layout_handler = html_layout_handlers[index];
            var link_handler = html_link_handlers[index];
            if (layout_handler != 0) view.disconnect (layout_handler);
            if (link_handler != 0) view.disconnect (link_handler);
            if (!detach_html_view (view)) continue;
            if (html_view_pool.size < MAX_POOLED_HTML_VIEWS) {
                view.reset_for_reuse (true);
                html_view_pool.add (view);
            } else view.shutdown ();
        }
        html_views.clear ();
        html_layout_handlers.clear ();
        html_link_handlers.clear ();
        recovery_notice = null;
        while (content.get_first_child () != null)
            content.remove ((Gtk.Widget) content.get_first_child ());
    }

    public void shutdown () {
        if (shutting_down) return;
        shutting_down = true;
        message_generation++;
        if (calendar_cancellable != null) calendar_cancellable.cancel ();
        calendar_cancellable = null;
        current = null;
        current_html_view = null;
        var renderers = new Gee.ArrayList<HtmlMessageView> ();

        for (int index = 0; index < html_views.size; index++) {
            var view = html_views[index];
            var layout_handler = html_layout_handlers[index];
            var link_handler = html_link_handlers[index];
            if (layout_handler != 0) view.disconnect (layout_handler);
            if (link_handler != 0) view.disconnect (link_handler);
            detach_html_view (view);
            renderers.add (view);
        }
        html_views.clear ();
        html_layout_handlers.clear ();
        html_link_handlers.clear ();

        foreach (var view in html_view_pool)
            renderers.add (view);
        html_view_pool.clear ();
        // All mail views use WebKit's default process pool. Keep one view alive
        // while the others close, then terminate that shared renderer exactly
        // once through WebKit's supported API.
        for (int index = 0; index < renderers.size; index++)
            renderers[index].shutdown (index == renderers.size - 1);
        renderers.clear ();
        while (content.get_first_child () != null)
            content.remove ((Gtk.Widget) content.get_first_child ());
    }

    private static bool detach_html_view (HtmlMessageView view) {
        var parent = view.get_parent ();
        if (parent == null) return true;
        var box = parent as Gtk.Box;
        if (box != null) {
            box.remove (view);
            return view.get_parent () == null;
        }
        warning ("Pooled HTML renderer has an unexpected non-box parent");
        return false;
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

    private bool authentication_results_trusted (Message message) {
        try {
            var account = cache.find_account (message.account_id);
            return account != null &&
                MessageSecurityService.authentication_results_are_trusted (
                    message.authentication_results, account.incoming_host);
        } catch (Error error) {
            warning ("Could not validate the Authentication-Results trust boundary: %s",
                error.message);
            return false;
        }
    }

    private bool sender_authenticated_for_remote_content (Message message) {
        return authentication_results_trusted (message) &&
            MessageSecurityService.authenticated_from_domain (
                message.authentication_results, message.sender_address);
    }

    private void append_identity_security (Message message, Gtk.Box target) {
        var assessment = message_security.assess (message, sender_is_safe (message),
            authentication_results_trusted (message));
        if (!assessment.should_show_inline_warning) return;
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
        details.clicked.connect (() => show_security_details (message)); actions.append (details);
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

    private void show_security_details (Message message) {
        var parent = get_root () as Gtk.Window;
        if (parent == null) return;
        bool safe = sender_is_safe (message);
        bool trusted_authentication = authentication_results_trusted (message);
        var assessment = message_security.assess (message, safe,
            trusted_authentication);

        var dialog = new Adw.Dialog ();
        dialog.title = "Message Security";
        dialog.presentation_mode = Adw.DialogPresentationMode.FLOATING;
        dialog.content_width = 700;
        dialog.content_height = 560;
        dialog.set_size_request (520, 480);
        dialog.add_css_class ("message-security-dialog");
        sync_security_dialog_theme (dialog);
        var style_manager = Adw.StyleManager.get_default ();
        ulong style_handler = style_manager.notify["dark"].connect (() =>
            sync_security_dialog_theme (dialog));
        dialog.closed.connect (() => {
            if (style_handler == 0) return;
            style_manager.disconnect (style_handler);
            style_handler = 0;
        });

        var toolbar = new Adw.ToolbarView ();
        toolbar.add_css_class ("message-security-surface");
        var header = new Adw.HeaderBar ();
        header.show_start_title_buttons = false;
        header.show_end_title_buttons = false;
        header.add_css_class ("message-security-headerbar");
        var window_title = new Adw.WindowTitle (
            "Message Security", "Sender and authentication checks");
        header.title_widget = window_title;
        var done = new Gtk.Button.with_mnemonic ("_Done");
        done.add_css_class ("suggested-action");
        done.add_css_class ("message-security-done");
        done.tooltip_text = "Close message security";
        Accessibility.label (done, "Close message security");
        done.clicked.connect (() => dialog.close ());
        header.pack_end (done);
        toolbar.add_top_bar (header);

        var content_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);
        content_box.add_css_class ("message-security-content");

        string level_class;
        string verdict_label;
        string verdict_detail;
        if (assessment.level == MessageThreatLevel.DANGER) {
            level_class = "danger";
            verdict_label = "Authentication failed";
            verdict_detail = "Treat links, attachments, and requests in this message with caution.";
        } else if (assessment.level == MessageThreatLevel.CAUTION) {
            level_class = "warning";
            verdict_label = "Review before acting";
            verdict_detail = "One or more sender or authentication details need your attention.";
        } else if (safe) {
            level_class = "trusted";
            verdict_label = safe ? "Known sender" : "No obvious warning signs";
            verdict_detail = "This address is on your Safe Senders list. Still review unexpected requests.";
        } else {
            level_class = "neutral";
            verdict_label = "No obvious warning signs";
            verdict_detail = "Mailficient did not find an obvious identity or authentication warning.";
        }

        var verdict = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
        verdict.add_css_class ("message-security-verdict");
        verdict.add_css_class (level_class);
        var verdict_badge = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        verdict_badge.halign = Gtk.Align.CENTER;
        verdict_badge.valign = Gtk.Align.CENTER;
        verdict_badge.add_css_class ("message-security-verdict-badge");
        string verdict_icon_name;
        if (assessment.level >= MessageThreatLevel.CAUTION)
            verdict_icon_name = "dialog-warning-symbolic";
        else if (safe)
            verdict_icon_name = "security-high-symbolic";
        else
            verdict_icon_name = "dialog-information-symbolic";
        var verdict_icon = new Gtk.Image.from_icon_name (verdict_icon_name);
        verdict_badge.append (verdict_icon);
        verdict.append (verdict_badge);
        var verdict_copy = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
        verdict_copy.hexpand = true;
        var verdict_eyebrow = new Gtk.Label (
            assessment.level >= MessageThreatLevel.CAUTION ? "Needs attention" : "Security review");
        verdict_eyebrow.xalign = 0;
        verdict_eyebrow.add_css_class ("message-security-eyebrow");
        var verdict_title = new Gtk.Label (verdict_label);
        verdict_title.xalign = 0;
        verdict_title.wrap = true;
        verdict_title.add_css_class ("message-security-verdict-title");
        var verdict_description = new Gtk.Label (verdict_detail);
        verdict_description.xalign = 0;
        verdict_description.wrap = true;
        verdict_description.add_css_class ("message-security-verdict-description");
        verdict_copy.append (verdict_eyebrow);
        verdict_copy.append (verdict_title);
        verdict_copy.append (verdict_description);
        verdict.append (verdict_copy);
        content_box.append (verdict);

        var identity = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        identity.add_css_class ("message-security-card");
        var identity_heading = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        identity_heading.add_css_class ("message-security-card-heading");
        var identity_title = new Gtk.Label ("Sender Identity");
        identity_title.xalign = 0;
        identity_title.hexpand = true;
        identity_title.add_css_class ("heading");
        identity_heading.append (identity_title);
        var safe_status = new Gtk.Label (safe ? "Safe Sender" : "Not marked safe");
        safe_status.add_css_class ("message-security-status-pill");
        if (safe) safe_status.add_css_class ("passed");
        identity_heading.append (safe_status);
        identity.append (identity_heading);

        var sender_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10);
        sender_row.add_css_class ("message-security-identity-row");
        var sender_icon = new Gtk.Image.from_icon_name ("avatar-default-symbolic");
        sender_icon.add_css_class ("message-security-identity-icon");
        sender_row.append (sender_icon);
        var sender_copy = new Gtk.Box (Gtk.Orientation.VERTICAL, 1);
        sender_copy.hexpand = true;
        var sender_name = new Gtk.Label (
            message.sender_name.strip () == "" ? message.sender_address : message.sender_name);
        sender_name.xalign = 0;
        sender_name.ellipsize = Pango.EllipsizeMode.END;
        var sender_address = new Gtk.Label (message.sender_address);
        sender_address.xalign = 0;
        sender_address.ellipsize = Pango.EllipsizeMode.MIDDLE;
        sender_address.selectable = true;
        sender_address.add_css_class ("caption");
        sender_address.add_css_class ("dim-label");
        sender_copy.append (sender_name);
        sender_copy.append (sender_address);
        sender_row.append (sender_copy);
        identity.append (sender_row);

        if (message.reply_to.strip () != "" &&
            message.reply_to.strip ().down () != message.sender_address.strip ().down ()) {
            var reply_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10);
            reply_row.add_css_class ("message-security-identity-row");
            var reply_label = new Gtk.Label ("Replies go to");
            reply_label.xalign = 0;
            reply_label.add_css_class ("dim-label");
            var reply_value = new Gtk.Label (message.reply_to);
            reply_value.xalign = 1;
            reply_value.hexpand = true;
            reply_value.ellipsize = Pango.EllipsizeMode.MIDDLE;
            reply_value.selectable = true;
            reply_row.append (reply_label);
            reply_row.append (reply_value);
            identity.append (reply_row);
        }
        content_box.append (identity);

        var authentication = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        authentication.add_css_class ("message-security-card");
        var auth_heading = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        auth_heading.add_css_class ("message-security-card-heading");
        var auth_title = new Gtk.Label ("Email Authentication");
        auth_title.xalign = 0;
        auth_title.hexpand = true;
        auth_title.add_css_class ("heading");
        auth_heading.append (auth_title);
        bool has_authentication_header = message.authentication_results.strip () != "";
        var auth_source = new Gtk.Label (trusted_authentication ?
            "Verified receiving-server results" :
            (has_authentication_header ? "Unverified header — not trusted" : "No results retained"));
        auth_source.add_css_class ("caption");
        auth_source.add_css_class ("dim-label");
        auth_heading.append (auth_source);
        authentication.append (auth_heading);
        if (message.security_status.strip () != "") {
            var protection_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 9);
            protection_row.add_css_class ("message-security-protection-row");
            var protection_icon = new Gtk.Image.from_icon_name ("security-high-symbolic");
            protection_icon.add_css_class ("message-security-protection-icon");
            protection_row.append (protection_icon);
            var protection_label = new Gtk.Label ("Message protection");
            protection_label.xalign = 0;
            protection_label.hexpand = true;
            protection_row.append (protection_label);
            var protection_status = new Gtk.Label (message.security_status);
            protection_status.xalign = 1;
            protection_status.wrap = true;
            protection_status.selectable = true;
            protection_status.add_css_class ("message-security-protection-status");
            protection_row.append (protection_status);
            authentication.append (protection_row);
        }
        var auth_grid = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        auth_grid.homogeneous = true;
        auth_grid.add_css_class ("message-security-auth-grid");
        string displayed_authentication = trusted_authentication ? message.authentication_results : "";
        auth_grid.append (build_authentication_item (
            "SPF", authentication_result (displayed_authentication, "spf")));
        auth_grid.append (build_authentication_item (
            "DKIM", authentication_result (displayed_authentication, "dkim")));
        auth_grid.append (build_authentication_item (
            "DMARC", authentication_result (displayed_authentication, "dmarc")));
        authentication.append (auth_grid);
        var auth_notice = new Gtk.Label (trusted_authentication ?
            "These results were added by the configured receiving service. They do not make links or attachments safe." :
            (has_authentication_header ?
                "Mailficient ignored these results because their authentication service could not be tied to the configured receiving server." :
                "The receiving service did not retain authentication results for this message."));
        auth_notice.xalign = 0;
        auth_notice.wrap = true;
        auth_notice.add_css_class ("message-security-auth-notice");
        authentication.append (auth_notice);
        content_box.append (authentication);

        int notable_findings = 0;
        foreach (var finding in assessment.findings) {
            if (finding != "Your mail server reports at least one passing authentication check.")
                notable_findings++;
        }
        if (notable_findings > 0) {
            var findings = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            findings.add_css_class ("message-security-card");
            var findings_heading = new Gtk.Label (
                notable_findings == 1 ? "What Needs Attention" : "What Needs Attention (%d)".printf (notable_findings));
            findings_heading.xalign = 0;
            findings_heading.add_css_class ("heading");
            findings_heading.add_css_class ("message-security-card-heading");
            findings.append (findings_heading);
            foreach (var finding in assessment.findings) {
                if (finding == "Your mail server reports at least one passing authentication check.")
                    continue;
                var finding_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 9);
                finding_row.add_css_class ("message-security-finding-row");
                var finding_icon = new Gtk.Image.from_icon_name ("dialog-warning-symbolic");
                finding_icon.valign = Gtk.Align.START;
                var finding_label = new Gtk.Label (finding);
                finding_label.xalign = 0;
                finding_label.wrap = true;
                finding_label.hexpand = true;
                finding_label.selectable = true;
                finding_row.append (finding_icon);
                finding_row.append (finding_label);
                findings.append (finding_row);
            }
            content_box.append (findings);
        }

        string raw_headers = MessageSecurityService.headers_for_display (message);
        var headers = new Gtk.TextView ();
        headers.editable = false;
        headers.cursor_visible = false;
        headers.monospace = true;
        headers.wrap_mode = Gtk.WrapMode.NONE;
        headers.buffer.text = raw_headers;
        headers.add_css_class ("message-security-header-text");
        Accessibility.label (headers, "Raw message headers");
        var headers_scroller = new Gtk.ScrolledWindow ();
        headers_scroller.child = headers;
        headers_scroller.set_policy (Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC);
        headers_scroller.set_min_content_height (180);
        headers_scroller.add_css_class ("message-security-header-scroller");

        var advanced = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        advanced.add_css_class ("message-security-card");
        advanced.add_css_class ("message-security-advanced");
        var details_button = new Gtk.ToggleButton ();
        details_button.has_frame = false;
        details_button.add_css_class ("message-security-details-button");
        var details_content = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 9);
        var details_icon = new Gtk.Image.from_icon_name ("go-next-symbolic");
        var details_copy = new Gtk.Box (Gtk.Orientation.VERTICAL, 1);
        details_copy.hexpand = true;
        var details_title = new Gtk.Label ("Technical Details");
        details_title.xalign = 0;
        details_title.add_css_class ("heading");
        var details_subtitle = new Gtk.Label ("View the original message headers");
        details_subtitle.xalign = 0;
        details_subtitle.add_css_class ("caption");
        details_subtitle.add_css_class ("dim-label");
        details_copy.append (details_title);
        details_copy.append (details_subtitle);
        var details_bound = new Gtk.Label ("64 KiB maximum");
        details_bound.add_css_class ("message-security-header-badge");
        details_content.append (details_icon);
        details_content.append (details_copy);
        details_content.append (details_bound);
        details_button.child = details_content;
        advanced.append (details_button);
        var headers_revealer = new Gtk.Revealer ();
        headers_revealer.transition_type = Gtk.RevealerTransitionType.SLIDE_DOWN;
        headers_revealer.child = headers_scroller;
        details_button.toggled.connect (() => {
            headers_revealer.reveal_child = details_button.active;
            details_icon.set_from_icon_name (
                details_button.active ? "go-down-symbolic" : "go-next-symbolic");
            details_subtitle.label = details_button.active ?
                "Hide the original message headers" : "View the original message headers";
        });
        advanced.append (headers_revealer);
        content_box.append (advanced);

        var clamp = new Adw.Clamp ();
        clamp.maximum_size = 660;
        clamp.child = content_box;
        clamp.margin_start = 16;
        clamp.margin_end = 16;
        clamp.margin_top = 10;
        clamp.margin_bottom = 10;
        var page_scroller = new Gtk.ScrolledWindow ();
        page_scroller.set_policy (Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC);
        page_scroller.child = clamp;
        page_scroller.add_css_class ("message-security-page");
        toolbar.content = page_scroller;

        var action_bar = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        action_bar.margin_start = 12;
        action_bar.margin_end = 12;
        action_bar.margin_top = 8;
        action_bar.margin_bottom = 8;
        action_bar.add_css_class ("message-security-action-bar");
        var report = new Gtk.Button.with_label ("Report Phishing");
        report.add_css_class ("destructive-action");
        report.tooltip_text = "Report this message as a phishing attempt";
        Accessibility.label (report, "Report this message as phishing");
        report.clicked.connect (() => {
            dialog.close ();
            phishing_report_requested (message);
        });
        action_bar.append (report);
        var action_space = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        action_space.hexpand = true;
        action_bar.append (action_space);
        var copy = new Gtk.Button.with_label ("Copy Headers");
        copy.tooltip_text = "Copy the original message headers";
        Accessibility.label (copy, "Copy original message headers");
        copy.clicked.connect (() => {
            get_clipboard ().set_text (raw_headers);
            copy.label = "Copied";
            Timeout.add (1600, () => {
                if (copy.get_root () != null) copy.label = "Copy Headers";
                return Source.REMOVE;
            });
        });
        action_bar.append (copy);
        if (RecipientParser.is_valid_address (message.sender_address)) {
            var safe_button = new Gtk.Button.with_label (
                safe ? "Remove Safe Sender" : "Add Safe Sender");
            safe_button.clicked.connect (() => {
                try {
                    safe = !safe;
                    cache.set_safe_sender (message.sender_address, safe);
                    safe_sender_changed (message.sender_address, safe);
                    safe_button.label = safe ? "Remove Safe Sender" : "Add Safe Sender";
                    safe_status.label = safe ? "Safe Sender" : "Not marked safe";
                    if (safe) safe_status.add_css_class ("passed");
                    else safe_status.remove_css_class ("passed");
                    if (assessment.level < MessageThreatLevel.CAUTION) {
                        verdict.remove_css_class (safe ? "neutral" : "trusted");
                        verdict.add_css_class (safe ? "trusted" : "neutral");
                        verdict_title.label = safe ? "Known sender" : "No obvious warning signs";
                        verdict_description.label = safe ?
                            "This address is on your Safe Senders list. Still review unexpected requests." :
                            "Mailficient did not find an obvious identity or authentication warning.";
                        verdict_icon.set_from_icon_name (safe ?
                            "security-high-symbolic" : "dialog-information-symbolic");
                    }
                } catch (Error error) {
                    safe = !safe;
                    remote_content_failed (error);
                }
            });
            action_bar.append (safe_button);
        }
        toolbar.add_bottom_bar (action_bar);
        dialog.child = toolbar;
        dialog.default_widget = done;
        dialog.present (parent);
    }

    private void sync_security_dialog_theme (Adw.Dialog dialog) {
        if (Adw.StyleManager.get_default ().dark)
            dialog.add_css_class ("message-security-dark");
        else
            dialog.remove_css_class ("message-security-dark");
    }

    private string authentication_result (string raw, string mechanism) {
        string normalized = raw.replace ("\r\n", " ").replace ("\n", " ")
            .replace ("\r", " ").down ();
        try {
            var expression = new Regex ("(?:^|[;\\s])" + Regex.escape_string (mechanism) +
                "\\s*=\\s*([a-z0-9_-]+)", RegexCompileFlags.CASELESS);
            MatchInfo match;
            if (expression.match (normalized, 0, out match))
                return match.fetch (1).down ();
        } catch (RegexError error) { }
        return "";
    }

    private Gtk.Widget build_authentication_item (string mechanism, string result) {
        bool passed = result == "pass";
        bool failed = result == "fail" || result == "softfail" ||
            result == "temperror" || result == "permerror";
        string status;
        string detail;
        string icon_name;
        string level_class;
        if (passed) {
            status = "Passed";
            detail = "Verified";
            icon_name = "emblem-ok-symbolic";
            level_class = "passed";
        } else if (failed) {
            status = result == "softfail" ? "Soft fail" :
                (result == "temperror" ? "Temporary error" :
                (result == "permerror" ? "Error" : "Failed"));
            detail = "Needs review";
            icon_name = "dialog-warning-symbolic";
            level_class = "failed";
        } else if (result != "") {
            status = result.substring (0, 1).up () + result.substring (1);
            detail = "Inconclusive";
            icon_name = "dialog-information-symbolic";
            level_class = "unknown";
        } else {
            status = "Not reported";
            detail = "No result";
            icon_name = "dialog-information-symbolic";
            level_class = "unknown";
        }
        var item = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        item.add_css_class ("message-security-auth-item");
        item.add_css_class (level_class);
        var icon = new Gtk.Image.from_icon_name (icon_name);
        icon.add_css_class ("message-security-auth-icon");
        item.append (icon);
        var copy = new Gtk.Box (Gtk.Orientation.VERTICAL, 1);
        copy.hexpand = true;
        var name = new Gtk.Label (mechanism);
        name.xalign = 0;
        name.add_css_class ("caption");
        name.add_css_class ("dim-label");
        var value = new Gtk.Label (status);
        value.xalign = 0;
        value.ellipsize = Pango.EllipsizeMode.END;
        value.add_css_class ("message-security-auth-value");
        copy.append (name);
        copy.append (value);
        item.append (copy);
        item.tooltip_text = "%s: %s — %s".printf (mechanism, status, detail);
        Accessibility.label (item, "%s authentication: %s".printf (mechanism, status));
        return item;
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
            if (generation != message_generation || host.get_root () == null) return;
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
                host.get_root () == null) return;
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
        if (parent == null || card.get_root () == null) return;
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
            if (card.get_root () == null) return;
            card.set_busy (false); card.set_response (participation);
            calendar_action_completed (send.active ?
                "%s — response sent to the organizer".printf (participation.label ()) :
                "%s in your calendar — no response sent".printf (participation.label ()));
        } catch (Error error) {
            if (card.get_root () != null) card.set_busy (false);
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
            if (button.get_root () != null) {
                button.child = null; button.icon_name = "appointment-new-symbolic";
                button.sensitive = true;
            }
        }
    }

    private void append_attachments (Message message, Gtk.Box target) {
        if (!message.has_attachment && message.attachments.size == 0) return;

        var section = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
        section.set_margin_start (18); section.set_margin_end (18);
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
                var icon = new Gtk.Image.from_icon_name ("mail-attachment-symbolic");
                icon.valign = Gtk.Align.CENTER; row.append (icon);
                var details = new Gtk.Box (Gtk.Orientation.VERTICAL, 1);
                details.hexpand = true;
                var filename = new Gtk.Label (attachment.name);
                filename.xalign = 0; filename.hexpand = true;
                filename.ellipsize = Pango.EllipsizeMode.MIDDLE;
                filename.tooltip_text = attachment.name;
                filename.add_css_class ("heading"); details.append (filename);
                var size = new Gtk.Label (attachment.formatted_size ());
                size.xalign = 0; size.add_css_class ("caption");
                size.add_css_class ("dim-label"); details.append (size);
                row.append (details);
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
                var save = new Gtk.Button.with_label (attachment.is_downloaded () ?
                    "Save" : "Download");
                save.add_css_class ("flat");
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
        dialog.initial_folder = settings.file_dialog_initial_folder ();
        dialog.initial_name = AttachmentSafety.safe_filename (attachment.name);
        try {
            var destination = yield dialog.save (root_window, null);
            settings.remember_file_dialog_selection (destination);
            button.sensitive = false;
            var spinner = new Gtk.Spinner (); spinner.spinning = true; button.child = spinner;
            yield attachment_service.save (message, attachment, destination);
            attachment_saved (destination.get_basename ());
        } catch (Error error) {
            if (!DialogErrors.was_cancelled (error)) attachment_failed (error);
        } finally {
            button.child = null;
            button.label = attachment.is_downloaded () ? "Save" : "Download";
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
