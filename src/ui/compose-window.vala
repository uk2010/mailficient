namespace Mailficient {
public class ComposeWindow : Adw.Window {
    private static int child_window_dimension (int preferred, int parent_size, int minimum) {
        if (parent_size <= 0) return preferred;
        int available = parent_size - 64;
        if (available < minimum) available = parent_size;
        return preferred < available ? preferred : available;
    }

    public signal void draft_changed ();
    private CacheDatabase cache;
    private AttachmentService attachment_service;
    private ReceivedAttachmentService received_attachment_service;
    private DraftLifecycleService draft_lifecycle;
    private OutboundService outbound_service;
    private MailSettingsStore settings;
    private SignatureService signatures;
    private Draft draft;
    private Gtk.Entry to_entry = new Gtk.Entry ();
    private Gtk.Entry cc_entry = new Gtk.Entry ();
    private Gtk.Entry bcc_entry = new Gtk.Entry ();
    private Gtk.Entry subject_entry = new Gtk.Entry ();
    private Gtk.TextView body = new Gtk.TextView ();
    private Gtk.Box attachment_rows = new Gtk.Box (Gtk.Orientation.VERTICAL, 4);
    private Gtk.Box forward_status = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
    private Gtk.Spinner forward_spinner = new Gtk.Spinner ();
    private Gtk.Label forward_status_label = new Gtk.Label ("");
    private Adw.ToastOverlay overlay = new Adw.ToastOverlay ();
    private uint autosave_source;
    private bool force_close;
    private Gtk.Button send_button;
    private Gtk.Button cancel_button;
    private Gtk.Button? delete_queued_button;
    private Gtk.Button attach_button;
    private Gtk.Button security_button;
    private Gtk.Box bottom_actions;
    private Gtk.Widget from_selector;
    private Cancellable attachment_operations = new Cancellable ();
    private bool sending;
    private bool importing_forward_attachments;
    private string applied_signature_block = "";
    private bool signature_initialized;
    private ulong signature_settings_handler;
    private OutboxItem? queued_item;
    private bool accepted_pending_cleanup;
    private bool uncertain_resend_confirmed;
    private Gee.ArrayList<RecipientCompletionController> recipient_completions = new Gee.ArrayList<RecipientCompletionController> ();
    private ContactSuggestionProvider? address_book;

    public ComposeWindow (Gtk.Window parent, CacheDatabase cache, AttachmentService attachment_service,
                          ReceivedAttachmentService received_attachment_service,
                          DraftLifecycleService draft_lifecycle,
                          OutboundService outbound_service,
                          MailSettingsStore settings,
                          Message? source_message = null, ComposeMode mode = ComposeMode.REPLY,
                          Draft? saved_draft = null, bool queued = false) {
        Object (title: saved_draft == null ? compose_title (source_message, mode) :
                    (queued ? "Outbox Message" : "Edit Draft"), transient_for: parent,
                modal: false,
                default_width: child_window_dimension (720, parent.get_width (), 480),
                default_height: child_window_dimension (620, parent.get_height (), 420));
        this.cache = cache;
        this.attachment_service = attachment_service;
        this.received_attachment_service = received_attachment_service;
        this.draft_lifecycle = draft_lifecycle;
        this.outbound_service = outbound_service;
        this.settings = settings;
        this.signatures = new SignatureService (settings);
        draft = saved_draft ?? new Draft (source_message == null || source_message.account_id == "" ? "demo-account" : source_message.account_id);
        if (queued) {
            try { queued_item = cache.find_outbox_item (draft.id); }
            catch (Error error) { warning ("Could not load Outbox delivery status: %s", error.message); }
        }
        var toolbar = new Adw.ToolbarView ();
        var header = new Adw.HeaderBar ();
        cancel_button = new Gtk.Button.with_label ("Cancel"); cancel_button.clicked.connect (() => confirm_close.begin ()); header.pack_start (cancel_button);
        if (queued_item != null && queued_item.delivery_state != OutboxDeliveryState.ACCEPTED) {
            delete_queued_button = new Gtk.Button.with_label ("Delete");
            delete_queued_button.add_css_class ("destructive-action");
            delete_queued_button.tooltip_text = "Delete this message from Outbox";
            Accessibility.label (delete_queued_button, "Delete this message from Outbox");
            delete_queued_button.clicked.connect (() => delete_queued_message.begin ());
            header.pack_start (delete_queued_button);
        }
        send_button = new Gtk.Button.with_label ("Send"); send_button.add_css_class ("suggested-action"); send_button.clicked.connect (() => send_message.begin ()); header.pack_end (send_button);
        var send_later = new Gtk.Button.from_icon_name ("alarm-symbolic"); send_later.tooltip_text = "Send later";
        Accessibility.label (send_later, "Schedule message to send later"); send_later.clicked.connect (() => schedule_send.begin ()); header.pack_end (send_later);
        toolbar.add_top_bar (header);
        var root = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        if (queued_item != null) root.append (new OutboxStatusView (queued_item));
        from_selector = build_from_selector ();
        var compose_header = new ComposeHeader (from_selector, to_entry, cc_entry, bcc_entry, subject_entry);
        compose_header.contacts_requested.connect (show_contacts);
        root.append (compose_header);
        root.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));
#if HAVE_ADDRESS_BOOK
        address_book = new GnomeAddressBookProvider ();
#endif
        var completion_service = new RecipientCompletionService (cache, address_book);
        foreach (var recipient_entry in new Gtk.Entry[] { to_entry, cc_entry, bcc_entry })
            recipient_completions.add (new RecipientCompletionController (recipient_entry, completion_service, draft.account_id));
        body.wrap_mode = Gtk.WrapMode.WORD_CHAR; body.add_css_class ("compose-body"); Accessibility.label (body, "Message body");
        RichTextBuffer.prepare (body.buffer);
        var scroller = new Gtk.ScrolledWindow (); scroller.set_child (body); scroller.vexpand = true; root.append (scroller);
        forward_status.set_margin_start (14); forward_status.set_margin_end (14);
        forward_status.set_margin_top (8); forward_status.set_margin_bottom (2);
        forward_status.append (forward_spinner); forward_status.append (forward_status_label);
        forward_status_label.add_css_class ("dim-label"); forward_status_label.xalign = 0;
        forward_status.visible = false; root.append (forward_status);
        attachment_rows.set_margin_start (12); attachment_rows.set_margin_end (12); attachment_rows.set_margin_top (6);
        root.append (attachment_rows);
        bottom_actions = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6); bottom_actions.set_margin_start (12); bottom_actions.set_margin_end (12); bottom_actions.set_margin_top (8); bottom_actions.set_margin_bottom (10);
        attach_button = new Gtk.Button.from_icon_name ("mail-attachment-symbolic"); attach_button.tooltip_text = "Attach files"; Accessibility.label (attach_button, "Attach files"); attach_button.clicked.connect (() => choose_attachments.begin ()); bottom_actions.append (attach_button);
        var image_button = new Gtk.Button.from_icon_name ("insert-image-symbolic"); image_button.tooltip_text = "Insert image";
        Accessibility.label (image_button, "Insert inline image"); image_button.clicked.connect (() => choose_inline_image.begin ()); bottom_actions.append (image_button);
        bottom_actions.append (format_button ("format-text-bold-symbolic", "Bold", RichTextBuffer.BOLD));
        bottom_actions.append (format_button ("format-text-italic-symbolic", "Italic", RichTextBuffer.ITALIC));
        bottom_actions.append (format_button ("format-text-underline-symbolic", "Underline", RichTextBuffer.UNDERLINE));
        bottom_actions.append (format_button ("format-text-strikethrough-symbolic", "Strikethrough", RichTextBuffer.STRIKETHROUGH));
        bottom_actions.append (format_button ("applications-engineering-symbolic", "Code", RichTextBuffer.CODE));
        var link = new Gtk.Button.from_icon_name ("insert-link-symbolic"); link.tooltip_text = "Insert link";
        Accessibility.label (link, "Insert link"); link.clicked.connect (() => insert_link.begin ()); bottom_actions.append (link);
        var bullets = new Gtk.Button.from_icon_name ("view-list-bullet-symbolic"); bullets.tooltip_text = "Bulleted list";
        Accessibility.label (bullets, "Create bulleted list"); bullets.clicked.connect (() => apply_list (false)); bottom_actions.append (bullets);
        var numbers = new Gtk.Button.from_icon_name ("view-list-ordered-symbolic"); numbers.tooltip_text = "Numbered list";
        Accessibility.label (numbers, "Create numbered list"); numbers.clicked.connect (() => apply_list (true)); bottom_actions.append (numbers);
        var insert_template_button = new Gtk.Button.from_icon_name ("document-open-symbolic"); insert_template_button.tooltip_text = "Insert template";
        Accessibility.label (insert_template_button, "Insert message template"); insert_template_button.clicked.connect (() => insert_template.begin ()); bottom_actions.append (insert_template_button);
        var save_template_button = new Gtk.Button.from_icon_name ("document-save-symbolic"); save_template_button.tooltip_text = "Save as template";
        Accessibility.label (save_template_button, "Save message as template"); save_template_button.clicked.connect (() => save_as_template.begin ()); bottom_actions.append (save_template_button);
        var signature_button = new Gtk.Button.from_icon_name ("insert-text-symbolic");
        signature_button.tooltip_text = "Insert signature";
        Accessibility.label (signature_button, "Insert signature");
        signature_button.clicked.connect (insert_signature);
        bottom_actions.append (signature_button);
        security_button = new Gtk.Button.from_icon_name ("channel-insecure-symbolic");
        Accessibility.label (security_button, "Message signing and encryption");
        security_button.clicked.connect (() => configure_security.begin ()); bottom_actions.append (security_button);
        root.append (bottom_actions); toolbar.set_content (root); overlay.set_child (toolbar); content = overlay;

        if (saved_draft != null) populate_draft ();
        else if (source_message != null) prepare_response (source_message, mode);
        if (saved_draft == null) apply_initial_signature ();
        signature_initialized = true;
        signature_settings_handler = settings.changed.connect ((key) => {
            if (key == "signature." + draft.account_id ||
                key == "signature-enabled." + draft.account_id)
                apply_signature_setting ();
        });
        to_entry.changed.connect (schedule_autosave); cc_entry.changed.connect (schedule_autosave); bcc_entry.changed.connect (schedule_autosave);
        subject_entry.changed.connect (schedule_autosave); body.buffer.changed.connect (schedule_autosave);
        var controller = new Gtk.ShortcutController ();
        controller.add_shortcut (new Gtk.Shortcut (Gtk.ShortcutTrigger.parse_string ("<Control>Return"), new Gtk.CallbackAction (() => { send_message.begin (); return true; })));
        controller.add_shortcut (new Gtk.Shortcut (Gtk.ShortcutTrigger.parse_string ("<Control>s"), new Gtk.CallbackAction (() => { save_draft_now (); return true; })));
        controller.add_shortcut (new Gtk.Shortcut (Gtk.ShortcutTrigger.parse_string ("<Control><Shift>a"), new Gtk.CallbackAction (() => { choose_attachments.begin (); return true; })));
        controller.add_shortcut (format_shortcut ("<Control>b", RichTextBuffer.BOLD));
        controller.add_shortcut (format_shortcut ("<Control>i", RichTextBuffer.ITALIC));
        controller.add_shortcut (format_shortcut ("<Control>u", RichTextBuffer.UNDERLINE));
        add_controller (controller);
        var drop_target = new Gtk.DropTarget (typeof (Gdk.FileList), Gdk.DragAction.COPY);
        drop_target.drop.connect ((value, x, y) => {
            unowned Gdk.FileList files = (Gdk.FileList) value.get_boxed ();
            foreach (unowned File file in files.get_files ()) import_attachment.begin (file);
            return true;
        });
        ((Gtk.Widget) this).add_controller (drop_target);
        string? qa_attachment = Environment.get_variable ("MAILFICIENT_QA_ATTACHMENT");
        if (qa_attachment != null && qa_attachment != "")
            Idle.add (() => { import_attachment.begin (File.new_for_path (qa_attachment)); return Source.REMOVE; });
        string? qa_recipients = Environment.get_variable ("MAILFICIENT_QA_RECIPIENTS");
        if (qa_recipients != null && qa_recipients != "" && qa_recipients != "0") {
            to_entry.text = "Maya Chen <maya@example.net>";
            cc_entry.text = "Noah Williams <noah@example.org>";
            bcc_entry.text = "alex.archive@example.com";
            subject_entry.text = "Design review — final details";
        }
        string? qa_completion = Environment.get_variable ("MAILFICIENT_QA_COMPLETION");
        if (qa_completion != null && qa_completion != "") Timeout.add (500, () => {
            to_entry.grab_focus (); to_entry.text = qa_completion; to_entry.set_position (-1);
            Timeout.add (100, () => { recipient_completions[0].refresh (); return Source.REMOVE; });
            return Source.REMOVE;
        });
        if (Environment.get_variable ("MAILFICIENT_QA_CONTACTS") == "1")
            Timeout.add (700, () => { show_contacts (to_entry); return Source.REMOVE; });
        else if (Environment.get_variable ("MAILFICIENT_QA_SEND_LATER") == "1")
            Timeout.add (700, () => { schedule_send.begin (); return Source.REMOVE; });
        else if (saved_draft == null && source_message == null)
            Idle.add (() => { to_entry.grab_focus (); return Source.REMOVE; });
        if (saved_draft == null && source_message != null && mode == ComposeMode.FORWARD)
            copy_forward_attachments.begin (source_message);
        configure_outbox_state ();
        update_security_button ();
    }

    private void show_contacts (Gtk.Entry target) {
        if (address_book == null) {
            overlay.add_toast (new Adw.Toast ("GNOME Contacts is unavailable in this build")); return;
        }
        var picker = new ContactPickerWindow (this, address_book);
        picker.recipient_selected.connect ((recipient) => {
            int position; string current = target.text.strip ();
            target.text = RecipientCompletionService.complete (current, current.length,
                recipient, out position);
            target.set_position (position); target.grab_focus ();
        });
        picker.present ();
    }

    protected override bool close_request () {
        if (sending) { overlay.add_toast (new Adw.Toast ("Wait for the current send attempt to finish.")); return true; }
        if (force_close || !has_content ()) {
            attachment_operations.cancel ();
            disconnect_signature_settings ();
            return false;
        }
        confirm_close.begin (); return true;
    }

    private void populate_draft () {
        to_entry.text = draft.to; cc_entry.text = draft.cc; bcc_entry.text = draft.bcc;
        subject_entry.text = draft.subject; body.buffer.text = draft.body_text;
        RichTextBuffer.restore (body.buffer, draft.body_format); render_attachments ();
    }

    private async void configure_security () {
        var protocols = new Gtk.StringList (null);
        protocols.append ("None"); protocols.append ("OpenPGP"); protocols.append ("S/MIME");
        var protocol = new Adw.ComboRow (); protocol.title = "Technology"; protocol.model = protocols;
        protocol.selected = (uint) draft.security_protocol;
        var sign = new Adw.SwitchRow (); sign.title = "Digitally sign"; sign.subtitle = "Lets recipients verify the sender and content";
        sign.active = draft.sign_message;
        var encrypt = new Adw.SwitchRow (); encrypt.title = "Encrypt"; encrypt.subtitle = "Requires a public key or certificate for every recipient";
        encrypt.active = draft.encrypt_message;
        var identity = new Adw.EntryRow (); identity.title = "Key or certificate identity (optional)";
        identity.text = draft.security_identity;
        var group = new Adw.PreferencesGroup (); group.add (protocol); group.add (sign); group.add (encrypt); group.add (identity);
        var dialog = new Adw.AlertDialog ("Message Security",
            "OpenPGP uses the system GnuPG keyring. S/MIME uses the Evolution Data Server certificate store. Leave the identity empty to use the sending address.");
        dialog.extra_child = group; dialog.add_response ("cancel", "Cancel"); dialog.add_response ("apply", "Apply");
        dialog.default_response = "apply"; dialog.close_response = "cancel";
        if ((yield dialog.choose (this, null)) != "apply") return;
        var selected_protocol = (MessageSecurityProtocol) protocol.selected;
        if ((sign.active || encrypt.active) && selected_protocol == MessageSecurityProtocol.NONE) {
            overlay.add_toast (new Adw.Toast ("Choose OpenPGP or S/MIME to secure the message.")); return;
        }
        draft.security_protocol = selected_protocol; draft.sign_message = sign.active;
        draft.encrypt_message = encrypt.active; draft.security_identity = identity.text.strip ();
        draft.touch (); schedule_autosave (); update_security_button ();
    }

    private void update_security_button () {
        if (!draft.sign_message && !draft.encrypt_message) {
            security_button.icon_name = "channel-insecure-symbolic";
            security_button.tooltip_text = "Message security: off"; return;
        }
        security_button.icon_name = draft.encrypt_message ? "channel-secure-symbolic" : "security-high-symbolic";
        string protocol = draft.security_protocol == MessageSecurityProtocol.OPENPGP ? "OpenPGP" : "S/MIME";
        if (draft.sign_message && draft.encrypt_message) security_button.tooltip_text = "%s signed and encrypted".printf (protocol);
        else if (draft.encrypt_message) security_button.tooltip_text = "%s encrypted".printf (protocol);
        else security_button.tooltip_text = "%s signed".printf (protocol);
    }

    private Gtk.Button format_button (string icon_name, string label, string tag_name) {
        var button = new Gtk.Button.from_icon_name (icon_name);
        button.add_css_class ("flat"); button.tooltip_text = "%s selected text".printf (label);
        Accessibility.label (button, "%s selected text".printf (label));
        button.clicked.connect (() => apply_format (tag_name));
        return button;
    }

    private Gtk.Shortcut format_shortcut (string trigger, string tag_name) {
        return new Gtk.Shortcut (Gtk.ShortcutTrigger.parse_string (trigger),
            new Gtk.CallbackAction (() => { apply_format (tag_name); return true; }));
    }

    private void apply_format (string tag_name) {
        if (!RichTextBuffer.toggle_selection (body.buffer, tag_name)) {
            overlay.add_toast (new Adw.Toast ("Select text to apply formatting."));
            body.grab_focus ();
            return;
        }
        update_draft (); schedule_autosave (); body.grab_focus ();
    }

    private void apply_list (bool ordered) {
        RichTextBuffer.prefix_lines (body.buffer, ordered);
        update_draft (); schedule_autosave (); body.grab_focus ();
    }

    private async void insert_link () {
        var entry = new Adw.EntryRow (); entry.title = "Web or email address";
        var dialog = new Adw.AlertDialog ("Insert Link", "Enter an https:// or mailto: address.");
        dialog.extra_child = entry; dialog.add_response ("cancel", "Cancel"); dialog.add_response ("insert", "Insert");
        dialog.default_response = "insert"; dialog.close_response = "cancel";
        if ((yield dialog.choose (this, null)) != "insert") return;
        string url = entry.text.strip ();
        if (!(url.has_prefix ("https://") || url.has_prefix ("http://") || url.has_prefix ("mailto:"))) {
            overlay.add_toast (new Adw.Toast ("Use an http, https, or mailto link.")); return;
        }
        Gtk.TextIter start; Gtk.TextIter end; string insertion = url;
        if (body.buffer.get_selection_bounds (out start, out end)) {
            string label = body.buffer.get_text (start, end, true);
            body.buffer.delete (ref start, ref end); insertion = "%s (%s)".printf (label, url);
            body.buffer.insert (ref start, insertion, -1);
        } else {
            body.buffer.get_iter_at_mark (out start, body.buffer.get_insert ());
            body.buffer.insert (ref start, insertion, -1);
        }
        schedule_autosave (); body.grab_focus ();
    }

    private Gtk.Widget build_from_selector () {
        var labels = new Gtk.StringList (null);
        var ids = new Gee.ArrayList<string> ();
        try {
            foreach (var account in cache.list_accounts ()) {
                labels.append ("%s <%s>".printf (account.display_name, account.email)); ids.add (account.id);
            }
        } catch (Error error) { warning ("Could not load compose identities: %s", error.message); }
        if (ids.size == 0) { labels.append ("Demo Mode — not connected"); ids.add ("demo-account"); }
        var selector = new Gtk.DropDown (labels, null);
        int selected_index = ids.index_of (draft.account_id);
        if (selected_index < 0) { selected_index = 0; draft.account_id = ids[0]; }
        selector.selected = (uint) selected_index;
        selector.notify["selected"].connect (() => {
            uint selected = selector.selected;
            if (selected < ids.size) {
                draft.account_id = ids[(int) selected];
                foreach (var completion in recipient_completions) {
                    completion.account_id = draft.account_id; completion.refresh ();
                }
                if (signature_initialized) replace_signature_for_account ();
                draft.touch (); schedule_autosave ();
            }
        });
        return selector;
    }

    private void apply_initial_signature () {
        body.buffer.text = signatures.apply (draft.account_id, body.buffer.text, out applied_signature_block);
        if (applied_signature_block == "") return;
        Gtk.TextIter start; body.buffer.get_start_iter (out start); body.buffer.place_cursor (start);
    }

    private void replace_signature_for_account () {
        body.buffer.text = signatures.replace (applied_signature_block, draft.account_id,
            body.buffer.text, out applied_signature_block);
        Gtk.TextIter start; body.buffer.get_start_iter (out start); body.buffer.place_cursor (start);
    }

    private void apply_signature_setting () {
        string replacement = signatures.block_for (draft.account_id);
        if (applied_signature_block != "") {
            body.buffer.text = signatures.replace (applied_signature_block, draft.account_id,
                body.buffer.text, out applied_signature_block);
        } else if (replacement != "") {
            applied_signature_block = replacement;
            body.buffer.text = replacement + body.buffer.text;
        }
        Gtk.TextIter start;
        body.buffer.get_start_iter (out start);
        body.buffer.place_cursor (start);
        schedule_autosave ();
    }

    private void disconnect_signature_settings () {
        if (signature_settings_handler == 0) return;
        settings.disconnect (signature_settings_handler);
        signature_settings_handler = 0;
    }

    private void insert_signature () {
        // Manual insertion is available whenever signature text is configured;
        // the enabled preference controls automatic insertion only.
        string block = signatures.configured_block_for (draft.account_id);
        if (block == "") {
            overlay.add_toast (new Adw.Toast ("Set up a signature in Settings → Composing"));
            return;
        }
        if (applied_signature_block != "" && body.buffer.text.contains (applied_signature_block)) {
            overlay.add_toast (new Adw.Toast ("The signature is already included"));
            return;
        }
        Gtk.TextIter position;
        body.buffer.get_iter_at_mark (out position, body.buffer.get_insert ());
        body.buffer.insert (ref position, block, -1);
        applied_signature_block = block;
        schedule_autosave ();
        body.grab_focus ();
    }

    private static string compose_title (Message? source, ComposeMode mode) {
        if (source == null || mode == ComposeMode.NEW) return "New Message";
        if (mode == ComposeMode.FORWARD) return "Forward";
        if (mode == ComposeMode.REPLY_ALL) return "Reply All";
        return "Reply";
    }

    private void prepare_response (Message source, ComposeMode mode) {
        string original_body = response_body (source);
        if (mode == ComposeMode.FORWARD) {
            subject_entry.text = source.subject.has_prefix ("Fwd:") ? source.subject : "Fwd: " + source.subject;
            body.buffer.text = "\n\n---------- Forwarded message ----------\nFrom: %s <%s>\nTo: %s\nDate: %s\nSubject: %s\n\n%s".printf (
                source.sender_name, source.sender_address, source.recipients, source.timestamp, source.subject, original_body);
            return;
        }
        if (mode == ComposeMode.REPLY_ALL) {
            string own_address = "";
            try {
                var account = cache.find_account (draft.account_id);
                if (account != null) own_address = account.email;
            } catch (Error error) { warning ("Could not resolve the reply identity: %s", error.message); }
            var recipients = new ReplyRecipientService ().build (source, own_address);
            to_entry.text = recipients.to; cc_entry.text = recipients.cc;
        } else to_entry.text = source.sender_address;
        subject_entry.text = source.subject.has_prefix ("Re:") ? source.subject : "Re: " + source.subject;
        var quoted = new StringBuilder ();
        foreach (string line in original_body.split ("\n")) quoted.append ("> ").append (line).append_c ('\n');
        body.buffer.text = "\n\nOn %s, %s wrote:\n%s".printf (source.timestamp, source.sender_name, quoted.str);
        draft.in_reply_to = source.internet_message_id == "" ? source.id : source.internet_message_id;
        draft.references = source.references.strip () == "" ? draft.in_reply_to :
            source.references.strip () + " " + draft.in_reply_to;
    }

    private static string response_body (Message source) {
        string plain = source.body;
        if (source.body_html == "") return plain;
        string from_html = HtmlSanitizer.to_plain_text (source.body_html);
        if (from_html != "" &&
            (plain.strip () == "" || plain.strip () == source.preview.strip () ||
             from_html.length > plain.length))
            return from_html;
        return plain;
    }

    private async void copy_forward_attachments (Message source) {
        if (source.attachments.size == 0) return;
        importing_forward_attachments = true; send_button.sensitive = false;
        forward_status_label.label = source.attachments.size == 1 ?
            "Preparing forwarded attachment…" :
            "Preparing %d forwarded attachments…".printf (source.attachments.size);
        forward_status.visible = true; forward_spinner.start ();
        int failures = 0;
        foreach (var attachment in source.attachments) {
            try {
                var copy = yield received_attachment_service.copy_for_draft (
                    source, attachment, attachment_operations);
                draft.add_attachment (copy); render_attachments ();
            } catch (Error error) {
                if (!(error is IOError.CANCELLED) && !(error is MailError.CANCELLED)) failures++;
            }
        }
        importing_forward_attachments = false;
        forward_spinner.stop (); forward_status.visible = false;
        if (!sending) send_button.sensitive = true;
        if (failures > 0)
            overlay.add_toast (new Adw.Toast (failures == 1 ?
                "One attachment could not be included in the forward." :
                "%d attachments could not be included in the forward.".printf (failures)));
        if (draft.attachments.size > 0) schedule_autosave ();
    }

    private bool has_content () { return to_entry.text != "" || cc_entry.text != "" || bcc_entry.text != "" || subject_entry.text != "" || body.buffer.text != "" || draft.attachments.size > 0; }

    private async void choose_attachments () {
        var dialog = new Gtk.FileDialog (); dialog.title = "Attach Files";
        try {
            var files = yield dialog.open_multiple (this, attachment_operations);
            for (uint index = 0; index < files.get_n_items (); index++) {
                var file = files.get_item (index) as File;
                if (file != null) yield import_attachment (file);
            }
        } catch (Error error) {
            if (!(error is IOError.CANCELLED)) show_attachment_error (error);
        }
    }

    private async void import_attachment (File file) {
        try {
            var attachment = yield attachment_service.import_file (file, attachment_operations);
            draft.add_attachment (attachment); render_attachments (); schedule_autosave ();
        } catch (Error error) { if (!(error is IOError.CANCELLED)) show_attachment_error (error); }
    }

    private async void choose_inline_image () {
        var dialog = new Gtk.FileDialog (); dialog.title = "Insert Image";
        try {
            var file = yield dialog.open (this, attachment_operations);
            var imported = yield attachment_service.import_file (file, attachment_operations);
            if (!imported.content_type.has_prefix ("image/")) {
                attachment_service.remove_private_copy (imported);
                overlay.add_toast (new Adw.Toast ("Choose an image file.")); return;
            }
            string content_id = "<%s@mailficient.local>".printf (Uuid.string_random ());
            var inline = new Attachment (imported.id, imported.path, imported.name, imported.size,
                imported.content_type, content_id);
            draft.add_attachment (inline);
            Gtk.TextIter cursor; body.buffer.get_iter_at_mark (out cursor, body.buffer.get_insert ());
            body.buffer.insert (ref cursor, "[Image: %s]".printf (inline.name), -1);
            render_attachments (); schedule_autosave ();
        } catch (Error error) { if (!(error is IOError.CANCELLED)) show_attachment_error (error); }
    }

    private void render_attachments () {
        while (attachment_rows.get_first_child () != null)
            attachment_rows.remove ((Gtk.Widget) attachment_rows.get_first_child ());
        foreach (var attachment in draft.attachments) {
            var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8); row.add_css_class ("attachment-chip");
            row.append (new Gtk.Image.from_icon_name ("mail-attachment-symbolic"));
            var label = new Gtk.Label ("%s  ·  %s".printf (attachment.name, attachment.formatted_size ()));
            label.xalign = 0; label.hexpand = true; label.ellipsize = Pango.EllipsizeMode.MIDDLE; row.append (label);
            if (AttachmentSafety.preview_kind (attachment.content_type, attachment.name) != AttachmentPreviewKind.NONE) {
                var preview = new Gtk.Button.from_icon_name ("view-reveal-symbolic"); preview.tooltip_text = "Preview attachment";
                Accessibility.label (preview, "Preview attachment %s".printf (attachment.name)); preview.add_css_class ("flat");
                preview.clicked.connect (() => new AttachmentPreviewWindow (this, attachment).present ()); row.append (preview);
            }
            var remove = new Gtk.Button.from_icon_name ("window-close-symbolic"); remove.tooltip_text = "Remove attachment";
            Accessibility.label (remove, "Remove attachment %s".printf (attachment.name));
            remove.add_css_class ("flat"); remove.clicked.connect (() => remove_attachment (attachment)); row.append (remove);
            attachment_rows.append (row);
        }
        attachment_rows.visible = draft.attachments.size > 0;
    }

    private void remove_attachment (Attachment attachment) {
        try { attachment_service.remove_private_copy (attachment); }
        catch (Error error) { overlay.add_toast (new Adw.Toast ("The private attachment copy could not be removed.")); return; }
        draft.remove_attachment (attachment); render_attachments (); schedule_autosave ();
    }

    private void show_attachment_error (Error error) {
        var friendly = UserFacingError.from_error (error);
        overlay.add_toast (new Adw.Toast ("%s — %s".printf (friendly.title, friendly.suggestion)));
    }

    private void update_draft () {
        draft.to = to_entry.text; draft.cc = cc_entry.text; draft.bcc = bcc_entry.text;
        draft.subject = subject_entry.text; draft.body_text = body.buffer.text;
        draft.body_format = RichTextBuffer.serialize (body.buffer);
        draft.body_html = RichTextBuffer.to_html (body.buffer);
        foreach (var attachment in draft.attachments) {
            if (attachment.content_id == "" || draft.body_html == "") continue;
            string marker = "[Image: %s]".printf (Markup.escape_text (attachment.name));
            string cid = attachment.content_id.replace ("<", "").replace (">", "");
            draft.body_html = draft.body_html.replace (marker,
                "<img src=\"cid:%s\" alt=\"%s\">".printf (cid, Markup.escape_text (attachment.name)));
        }
        draft.touch ();
    }

    private void schedule_autosave () {
        cancel_autosave ();
        autosave_source = Timeout.add_seconds (2, () => {
            autosave_source = 0;
            try {
                if (has_content ()) { update_draft (); cache.save_draft (draft); }
            }
            catch (Error error) { overlay.add_toast (new Adw.Toast ("Draft could not be saved. Check local storage and try again.")); }
            return Source.REMOVE;
        });
    }

    private void save_draft_now () {
        cancel_autosave ();
        try {
            update_draft (); cache.save_draft (draft); draft_changed ();
            overlay.add_toast (new Adw.Toast ("Draft saved"));
        } catch (Error error) {
            overlay.add_toast (new Adw.Toast ("Draft could not be saved. Check local storage and try again."));
        }
    }

    private async void send_message () {
        if (sending) return;
        if (accepted_pending_cleanup) {
            overlay.add_toast (new Adw.Toast ("This message was already accepted by the mail server."));
            return;
        }
        if (queued_item != null && queued_item.requires_resend_confirmation () && !uncertain_resend_confirmed) {
            var confirmation = new Adw.AlertDialog ("Send this message again?",
                "The previous delivery could not be confirmed, so the recipient may already have received it. Check Sent mail before sending another copy.");
            confirmation.add_response ("cancel", "Cancel"); confirmation.add_response ("send", "Send Again");
            confirmation.default_response = "cancel"; confirmation.close_response = "cancel";
            confirmation.set_response_appearance ("send", Adw.ResponseAppearance.DESTRUCTIVE);
            if ((yield confirmation.choose (this, null)) != "send") return;
            uncertain_resend_confirmed = true;
        }
        if (importing_forward_attachments) {
            overlay.add_toast (new Adw.Toast ("Wait for the forwarded attachments to finish copying."));
            return;
        }
        update_draft ();
        try {
            RecipientParser.parse (draft.to);
        } catch (Error error) {
            yield show_message_validation_error (error, to_entry); return;
        }
        try {
            if (draft.cc.strip () != "") RecipientParser.parse (draft.cc);
        } catch (Error error) {
            yield show_message_validation_error (error, cc_entry); return;
        }
        try {
            if (draft.bcc.strip () != "") RecipientParser.parse (draft.bcc);
        } catch (Error error) {
            yield show_message_validation_error (error, bcc_entry); return;
        }
        try { draft.validate_for_send (); }
        catch (Error error) { yield show_message_validation_error (error, body); return; }
        if (draft.subject.strip () == "" && draft.body_text.strip () == "" && draft.attachments.size == 0) {
            var confirmation = new Adw.AlertDialog ("Send an empty message?",
                "This message has no subject, message text, or attachment.");
            confirmation.add_response ("cancel", "Keep Editing");
            confirmation.add_response ("send", "Send Anyway");
            confirmation.close_response = "cancel"; confirmation.default_response = "cancel";
            confirmation.set_response_appearance ("send", Adw.ResponseAppearance.SUGGESTED);
            if ((yield confirmation.choose (this, null)) != "send") return;
        }
        // Freeze every producer of draft changes before OutboundService takes its
        // durable snapshot. In particular, a late autosave must never recreate a
        // draft after a successful send removed it from the database.
        cancel_autosave (); attachment_operations.cancel ();
        sending = true; set_editor_sensitive (false); send_button.sensitive = false; send_button.label = "Sending…";
        try {
            var disposition = yield outbound_service.deliver (draft);
            if (disposition == SendDisposition.SENT) {
                // close_request() deliberately refuses to close during an active
                // send.  Clear that guard after SMTP acceptance, before asking
                // GTK to close the successfully delivered compose window.  Do
                // the close on the next main-loop turn so this async callback
                // has returned before GTK disposes the compose object.
                draft_changed (); force_close = true; sending = false;
                attachment_operations.cancel ();
                Idle.add (() => { close (); return Source.REMOVE; }); return;
            } else {
                overlay.add_toast (new Adw.Toast ("Saved safely to Outbox — connect an account to deliver it."));
                draft.mark_saved (); draft_changed ();
            }
        } catch (Error error) {
            var friendly = UserFacingError.from_error (error);
            bool preserved = false;
            try {
                queued_item = cache.find_outbox_item (draft.id);
                preserved = queued_item != null;
            } catch (Error status_error) {
                warning ("Could not verify Outbox preservation: %s", status_error.message);
            }
            overlay.add_toast (new Adw.Toast (preserved ?
                "%s — the message remains in Outbox.".printf (friendly.title) :
                "%s — the message was not queued. Keep this window open and save the draft.".printf (friendly.title)));
            draft_changed ();
            uncertain_resend_confirmed = false;
        }
        if (!force_close) attachment_operations = new Cancellable ();
        sending = false; set_editor_sensitive (true); send_button.sensitive = true; restore_send_button_label ();
    }

    private async void schedule_send () {
        update_draft ();
        var initial = queued_item != null && queued_item.next_attempt_at > 0 ?
            new DateTime.from_unix_local (queued_item.next_attempt_at) :
            new DateTime.now_local ().add_hours (1);
        var picker = new Gtk.Box (Gtk.Orientation.VERTICAL, 10);
        var calendar = new Gtk.Calendar (); calendar.select_day (initial);
        calendar.show_day_names = true; calendar.show_heading = true;
        picker.append (calendar);
        var time_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        time_row.halign = Gtk.Align.CENTER;
        var time_label = new Gtk.Label ("Time");
        int initial_hour = initial.get_hour ();
        var hour = new Gtk.SpinButton.with_range (1, 12, 1);
        hour.value = initial_hour % 12 == 0 ? 12 : initial_hour % 12;
        hour.numeric = true; hour.wrap = true;
        hour.tooltip_text = "Scheduled hour";
        Accessibility.label (hour, "Scheduled hour");
        var separator = new Gtk.Label (":");
        var minute = new Gtk.SpinButton.with_range (0, 59, 1);
        minute.value = initial.get_minute (); minute.numeric = true; minute.wrap = true;
        minute.tooltip_text = "Scheduled minute";
        Accessibility.label (minute, "Scheduled minute");
        var periods = new Gtk.StringList (null);
        periods.append ("AM"); periods.append ("PM");
        var period = new Gtk.DropDown (periods, null);
        period.selected = initial_hour >= 12 ? 1 : 0;
        period.tooltip_text = "AM or PM";
        Accessibility.label (period, "Scheduled time AM or PM");
        time_row.append (time_label); time_row.append (hour);
        time_row.append (separator); time_row.append (minute); time_row.append (period);
        picker.append (time_row);
        var dialog = new Adw.AlertDialog ("Send Later",
            "Choose the exact local date and time for delivery. Mailficient must be running, or the message will send when it next opens.");
        dialog.extra_child = picker; dialog.add_response ("cancel", "Cancel"); dialog.add_response ("schedule", "Schedule");
        dialog.default_response = "schedule"; dialog.close_response = "cancel";
        if ((yield dialog.choose (this, null)) != "schedule") return;
        var date = calendar.get_date ();
        int selected_hour = hour.get_value_as_int () % 12 +
            (period.selected == 1 ? 12 : 0);
        var selected_time = new DateTime.local (date.get_year (), date.get_month (),
            date.get_day_of_month (), selected_hour,
            minute.get_value_as_int (), 0);
        try {
            outbound_service.schedule (draft, selected_time.to_unix ());
            cancel_autosave (); draft_changed (); force_close = true; close ();
        } catch (Error error) { yield show_message_validation_error (error, body); }
    }

    private async void delete_queued_message () {
        if (queued_item == null || queued_item.delivery_state == OutboxDeliveryState.ACCEPTED) return;
        var dialog = new Adw.AlertDialog ("Delete this Outbox message?",
            "The message will not be sent. This also removes its private attachment copies.");
        dialog.add_response ("cancel", "Keep Message");
        dialog.add_response ("delete", "Delete");
        dialog.default_response = "cancel"; dialog.close_response = "cancel";
        dialog.set_response_appearance ("delete", Adw.ResponseAppearance.DESTRUCTIVE);
        if ((yield dialog.choose (this, null)) != "delete") return;
        cancel_autosave (); attachment_operations.cancel ();
        try {
            draft_lifecycle.discard (draft);
            outbound_service.outbox_changed (draft.account_id);
        } catch (Error error) {
            overlay.add_toast (new Adw.Toast ("The Outbox message could not be deleted."));
            attachment_operations = new Cancellable ();
            return;
        }
        draft_changed (); force_close = true; close ();
    }

    private async void save_as_template () {
        update_draft (); var entry = new Adw.EntryRow (); entry.title = "Template name";
        var dialog = new Adw.AlertDialog ("Save Message Template", "Templates preserve the subject, body, and formatting.");
        dialog.extra_child = entry; dialog.add_response ("cancel", "Cancel"); dialog.add_response ("save", "Save");
        dialog.default_response = "save"; dialog.close_response = "cancel";
        if ((yield dialog.choose (this, null)) != "save") return;
        try { cache.save_mail_template (entry.text, draft); overlay.add_toast (new Adw.Toast ("Template saved")); }
        catch (Error error) { overlay.add_toast (new Adw.Toast (error.message)); }
    }

    private async void insert_template () {
        Gee.ArrayList<MailTemplate> templates;
        try { templates = cache.list_mail_templates (); }
        catch (Error error) { overlay.add_toast (new Adw.Toast (error.message)); return; }
        if (templates.size == 0) { overlay.add_toast (new Adw.Toast ("No templates have been saved yet.")); return; }
        var names = new Gtk.StringList (null); foreach (var template in templates) names.append (template.name);
        var choice = new Adw.ComboRow (); choice.title = "Template"; choice.model = names;
        var dialog = new Adw.AlertDialog ("Insert Template", "This replaces the current subject and message body.");
        dialog.extra_child = choice; dialog.add_response ("cancel", "Cancel"); dialog.add_response ("insert", "Insert");
        dialog.default_response = "insert"; dialog.close_response = "cancel";
        if ((yield dialog.choose (this, null)) != "insert") return;
        var template = templates[(int) choice.selected]; subject_entry.text = template.subject;
        body.buffer.text = template.body_text; RichTextBuffer.restore (body.buffer, template.body_format);
        schedule_autosave (); body.grab_focus ();
    }

    private async void show_message_validation_error (Error error, Gtk.Widget field) {
        field.add_css_class ("error"); field.grab_focus ();
        var dialog = new Adw.AlertDialog ("Message can’t be sent", error.message);
        dialog.add_response ("ok", "OK"); dialog.default_response = "ok"; dialog.close_response = "ok";
        yield dialog.choose (this, null);
        Timeout.add (1800, () => { field.remove_css_class ("error"); return Source.REMOVE; });
    }

    private void cancel_autosave () {
        if (autosave_source != 0) { Source.remove (autosave_source); autosave_source = 0; }
    }

    private void set_editor_sensitive (bool sensitive) {
        cancel_button.sensitive = sensitive; from_selector.sensitive = sensitive;
        to_entry.sensitive = sensitive; cc_entry.sensitive = sensitive; bcc_entry.sensitive = sensitive;
        subject_entry.sensitive = sensitive; body.sensitive = sensitive; attach_button.sensitive = sensitive;
        attachment_rows.sensitive = sensitive;
        bottom_actions.sensitive = sensitive;
        if (delete_queued_button != null) delete_queued_button.sensitive = sensitive;
    }

    private void configure_outbox_state () {
        if (queued_item == null) return;
        if (queued_item.delivery_state == OutboxDeliveryState.SENDING) {
            send_button.label = "Send Again…";
        } else if (queued_item.delivery_state == OutboxDeliveryState.ACCEPTED) {
            accepted_pending_cleanup = true;
            set_editor_sensitive (false); cancel_button.sensitive = true; cancel_button.label = "Close";
            send_button.sensitive = false; send_button.label = "Already Sent";
        } else if (queued_item.attempts > 0) send_button.label = "Try Again";
    }

    private void restore_send_button_label () {
        if (queued_item != null && queued_item.requires_resend_confirmation ())
            send_button.label = "Send Again…";
        else if (queued_item != null && queued_item.attempts > 0)
            send_button.label = "Try Again";
        else send_button.label = "Send";
    }

    private async void confirm_close () {
        if (sending) { overlay.add_toast (new Adw.Toast ("Wait for the current send attempt to finish.")); return; }
        if (accepted_pending_cleanup) { force_close = true; close (); return; }
        if (!has_content ()) { force_close = true; attachment_operations.cancel (); close (); return; }
        var dialog = new Adw.AlertDialog ("Save this draft?", "You can reopen saved drafts from the Drafts mailbox.");
        dialog.add_response ("cancel", "Keep Editing"); dialog.add_response ("discard", "Discard"); dialog.add_response ("save", "Save Draft");
        dialog.close_response = "cancel"; dialog.default_response = "save";
        dialog.set_response_appearance ("discard", Adw.ResponseAppearance.DESTRUCTIVE);
        dialog.set_response_appearance ("save", Adw.ResponseAppearance.SUGGESTED);
        string response = yield dialog.choose (this, null);
        if (response == "save") {
            cancel_autosave ();
            try { update_draft (); cache.save_draft (draft); }
            catch (Error error) { overlay.add_toast (new Adw.Toast ("Draft could not be saved. Check local storage and try again.")); return; }
            draft_changed (); force_close = true; attachment_operations.cancel (); close (); return;
        }
        if (response == "discard") {
            cancel_autosave (); attachment_operations.cancel ();
            try {
                draft_lifecycle.discard (draft);
            } catch (Error error) { overlay.add_toast (new Adw.Toast ("Draft could not be discarded.")); return; }
            draft_changed (); force_close = true; close ();
        }
    }
}
}
