namespace Mailficient {
public class ReadingPane : Gtk.Box {
    public signal void vip_toggled (Message message, bool vip);
    public signal void attachment_saved (string filename);
    public signal void attachment_failed (Error error);
    public signal void remote_content_failed (Error error);
    public signal void remote_sender_trusted (string address);
    public signal void add_account_requested ();
    private Gtk.Box content = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
    private Gtk.ScrolledWindow scroller = new Gtk.ScrolledWindow ();
    private ReceivedAttachmentService attachment_service;
    private RemoteContentPolicy remote_content_policy;
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

    public ReadingPane (ReceivedAttachmentService attachment_service, RemoteContentPolicy remote_content_policy) {
        Object (orientation: Gtk.Orientation.VERTICAL);
        this.attachment_service = attachment_service;
        this.remote_content_policy = remote_content_policy;
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
        card.append (header_button);
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
        if (message.security_status != "") {
            var security = new Adw.Banner (message.security_status);
            security.revealed = true; security.add_css_class ("security-notice");
            message_content.append (security);
        }
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
        status.vexpand = true;
        if (error.technical_detail != "") {
            var details = new Gtk.Expander ("Technical Details");
            details.halign = Gtk.Align.CENTER;
            var label = new Gtk.Label (error.technical_detail); label.selectable = true; label.wrap = true;
            details.child = label; status.child = details;
        }
        content.append (status);
    }
    private void clear () {
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

    private void append_attachments (Message message, Gtk.Box target) {
        if (!message.has_attachment && message.attachments.size == 0) return;

        var section = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
        section.set_margin_start (30); section.set_margin_end (30);
        section.set_margin_top (18); section.set_margin_bottom (20);
        var title = new Gtk.Label (message.attachments.size == 0 ? "Attachments" :
            (message.attachments.size == 1 ? "1 Attachment" :
            "%d Attachments".printf (message.attachments.size)));
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
                    var calendar = new Gtk.Button.with_label ("Add to Calendar");
                    calendar.add_css_class ("flat");
                    calendar.tooltip_text = "Open this invitation in your desktop calendar";
                    Accessibility.label (calendar,
                        "Add calendar invitation %s to calendar".printf (attachment.name));
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
            button.label = "Add to Calendar";
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
