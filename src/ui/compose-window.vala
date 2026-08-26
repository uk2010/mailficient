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
    // Draft.dirty tracks persistence/synchronization. These two fields track
    // this editor session so an untouched new reply/forward can close without
    // asking to save automatically prepared content.
    private bool opened_saved_draft;
    private bool changed_by_user;
    private Gtk.Button send_button;
    private Gtk.Button send_later_button;
    private Gtk.Button cancel_button;
    private Gtk.Button? delete_queued_button;
    private Gtk.Button undo_send_button;
    private Gtk.Button attach_button;
    private Gtk.Button spellcheck_button;
    private Gtk.Button security_button;
    private Gtk.ToggleButton bold_button;
    private Gtk.ToggleButton italic_button;
    private Gtk.ToggleButton underline_button;
    private Gtk.Label draft_status_label = new Gtk.Label ("");
    private SimpleActionGroup compose_actions = new SimpleActionGroup ();
    private Gtk.Box bottom_actions;
    private Gtk.Box outbox_status_container = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
    private Gtk.Widget from_selector;
    private Cancellable attachment_operations = new Cancellable ();
    private bool sending;
    private bool importing_forward_attachments;
    private string applied_signature_block = "";
    private bool signature_initialized;
    private ulong signature_settings_handler;
    private OutboxItem? queued_item;
    private uint undo_countdown_source;
    private bool accepted_pending_cleanup;
    private bool outbox_read_only;
    private bool uncertain_resend_confirmed;
    private Gee.ArrayList<RecipientCompletionController> recipient_completions = new Gee.ArrayList<RecipientCompletionController> ();
    private ContactSuggestionProvider? address_book;
    private string response_quote_text = "";
    private string response_quote_html = "";
    private string loaded_body_text = "";
    private string loaded_body_html = "";
    private bool loaded_draft_snapshot;
    private LocalSpellChecker spell_checker = new LocalSpellChecker ();
    private Gee.ArrayList<SpellingIssue> spelling_issues = new Gee.ArrayList<SpellingIssue> ();
    private Gtk.TextTag spelling_tag = new Gtk.TextTag ("mailficient-spelling-error");
    private Cancellable spelling_cancellable = new Cancellable ();
    private uint spellcheck_source;
    private uint spellcheck_generation;
    private SimpleActionGroup spelling_actions = new SimpleActionGroup ();
    private Menu spelling_context_menu = new Menu ();
    private Gtk.TextMark? context_spelling_start;
    private Gtk.TextMark? context_spelling_end;
    private string context_spelling_word = "";
    private Gee.ArrayList<string> context_spelling_suggestions = new Gee.ArrayList<string> ();

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
        // Adw.Window intentionally has a transparent content surface. The
        // standard background class gives standalone compose windows an
        // opaque, theme-aware canvas (including X11 sessions without a
        // compositor).
        add_css_class ("background");
        add_css_class ("compose-window");
        var style_manager = Adw.StyleManager.get_default ();
        update_compose_palette (style_manager.dark);
        style_manager.notify["dark"].connect (() =>
            update_compose_palette (Adw.StyleManager.get_default ().dark));
        set_deletable (false);
        this.cache = cache;
        this.attachment_service = attachment_service;
        this.received_attachment_service = received_attachment_service;
        this.draft_lifecycle = draft_lifecycle;
        this.outbound_service = outbound_service;
        this.settings = settings;
        this.signatures = new SignatureService (settings);
        opened_saved_draft = saved_draft != null;
        draft = saved_draft ?? new Draft (source_message == null || source_message.account_id == "" ? "demo-account" : source_message.account_id);
        if (queued) {
            try { queued_item = cache.find_outbox_item (draft.id); }
            catch (Error error) { warning ("Could not load Outbox delivery status: %s", error.message); }
        }
        var toolbar = new Adw.ToolbarView ();
        var header = new Adw.HeaderBar ();
        var title_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        var title_label = new Gtk.Label ("");
        title_label.add_css_class ("heading");
        bind_property ("title", title_label, "label", BindingFlags.SYNC_CREATE);
        draft_status_label.add_css_class ("caption");
        draft_status_label.add_css_class ("dim-label");
        draft_status_label.visible = false;
        title_box.append (title_label); title_box.append (draft_status_label);
        header.title_widget = title_box;
        cancel_button = new Gtk.Button.with_label ("Cancel"); cancel_button.clicked.connect (request_close); header.pack_start (cancel_button);
        if (queued_item != null && queued_item.delivery_state != OutboxDeliveryState.ACCEPTED &&
            queued_item.delivery_state != OutboxDeliveryState.PREPARING) {
            delete_queued_button = new Gtk.Button.with_label ("Delete");
            delete_queued_button.add_css_class ("destructive-action");
            delete_queued_button.tooltip_text = "Delete this message from Outbox";
            Accessibility.label (delete_queued_button, "Delete this message from Outbox");
            delete_queued_button.clicked.connect (() => delete_queued_message.begin ());
            header.pack_start (delete_queued_button);
        }
        undo_send_button = new Gtk.Button.with_label ("Undo");
        undo_send_button.add_css_class ("suggested-action");
        undo_send_button.tooltip_text = "Cancel this send and keep editing";
        Accessibility.label (undo_send_button, "Undo Send and keep editing");
        undo_send_button.clicked.connect (undo_send); undo_send_button.visible = false;
        header.pack_start (undo_send_button);
        send_button = new Gtk.Button.with_label ("Send");
        send_button.add_css_class ("suggested-action");
        send_button.tooltip_text = "Send message (Ctrl+Enter)";
        Accessibility.label (send_button, "Send message");
        send_button.clicked.connect (() => send_message.begin ()); header.pack_end (send_button);
        send_later_button = new Gtk.Button.with_label ("Send Later…");
        send_later_button.tooltip_text = "Choose a date and time to send";
        Accessibility.label (send_later_button, "Choose a date and time to send this message");
        send_later_button.clicked.connect (() => schedule_send.begin ()); header.pack_end (send_later_button);
        toolbar.add_top_bar (header);
        var root = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        root.add_css_class ("compose-root");
        root.append (outbox_status_container);
        refresh_outbox_status ();
        from_selector = build_from_selector ();
        var compose_header = new ComposeHeader (from_selector, to_entry, cc_entry, bcc_entry, subject_entry);
        compose_header.contacts_requested.connect (show_contacts);
        configure_recipient_entry (to_entry, "Add one or more recipients", true);
        configure_recipient_entry (cc_entry, "Add carbon-copy recipients", false);
        configure_recipient_entry (bcc_entry, "Add blind-copy recipients", false);
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
        spelling_tag.underline = Pango.Underline.ERROR;
        body.buffer.tag_table.add (spelling_tag);
        install_spelling_context_menu ();
        // Keep the compose form keyboard-navigable. Gtk.TextView normally
        // consumes Tab as text, which traps focus in the message body; Ctrl+Tab
        // remains available when a literal tab is intentionally needed.
        var body_key_controller = new Gtk.EventControllerKey ();
        body_key_controller.propagation_phase = Gtk.PropagationPhase.CAPTURE;
        body_key_controller.key_pressed.connect ((keyval, keycode, state) => {
            if (keyval == Gdk.Key.Menu ||
                (keyval == Gdk.Key.F10 && (state & Gdk.ModifierType.SHIFT_MASK) != 0)) {
                prepare_keyboard_spelling_context ();
                // GtkTextView owns the platform menu binding; returning false
                // lets it open the native menu with our spelling section.
                return false;
            }
            if (keyval != Gdk.Key.Tab && keyval != Gdk.Key.ISO_Left_Tab) return false;
            if ((state & Gdk.ModifierType.CONTROL_MASK) != 0 && body.editable) {
                body.buffer.insert_at_cursor ("\t", 1);
                return true;
            }
            bool backwards = keyval == Gdk.Key.ISO_Left_Tab ||
                (state & Gdk.ModifierType.SHIFT_MASK) != 0;
            return child_focus (backwards ? Gtk.DirectionType.TAB_BACKWARD :
                Gtk.DirectionType.TAB_FORWARD);
        });
        body.add_controller (body_key_controller);
        var scroller = new Gtk.ScrolledWindow (); scroller.add_css_class ("compose-editor-scroller");
        scroller.set_child (body); scroller.vexpand = true; root.append (scroller);
        forward_status.set_margin_start (14); forward_status.set_margin_end (14);
        forward_status.set_margin_top (8); forward_status.set_margin_bottom (2);
        forward_status.append (forward_spinner); forward_status.append (forward_status_label);
        forward_status_label.add_css_class ("dim-label"); forward_status_label.xalign = 0;
        forward_status.visible = false; root.append (forward_status);
        attachment_rows.set_margin_start (12); attachment_rows.set_margin_end (12); attachment_rows.set_margin_top (6);
        root.append (attachment_rows);
        bottom_actions = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6); bottom_actions.add_css_class ("compose-actions");
        bottom_actions.set_margin_start (12); bottom_actions.set_margin_end (12); bottom_actions.set_margin_top (8); bottom_actions.set_margin_bottom (10);
        var content_group = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        content_group.add_css_class ("linked");
        attach_button = new Gtk.Button.from_icon_name ("mail-attachment-symbolic"); attach_button.tooltip_text = "Attach files"; Accessibility.label (attach_button, "Attach files"); attach_button.clicked.connect (() => choose_attachments.begin ()); content_group.append (attach_button);
        var image_button = new Gtk.Button.from_icon_name ("insert-image-symbolic"); image_button.tooltip_text = "Insert image";
        Accessibility.label (image_button, "Insert inline image"); image_button.clicked.connect (() => choose_inline_image.begin ()); content_group.append (image_button);
        bottom_actions.append (content_group);

        var format_group = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        format_group.add_css_class ("linked");
        bold_button = format_toggle_button ("format-text-bold-symbolic", "Bold", RichTextBuffer.BOLD);
        italic_button = format_toggle_button ("format-text-italic-symbolic", "Italic", RichTextBuffer.ITALIC);
        underline_button = format_toggle_button ("format-text-underline-symbolic", "Underline", RichTextBuffer.UNDERLINE);
        format_group.append (bold_button); format_group.append (italic_button); format_group.append (underline_button);
        var link = new Gtk.Button.from_icon_name ("insert-link-symbolic"); link.tooltip_text = "Insert link";
        Accessibility.label (link, "Insert link"); link.clicked.connect (() => insert_link.begin ()); format_group.append (link);
        bottom_actions.append (format_group);

        var flexible_space = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        flexible_space.hexpand = true; bottom_actions.append (flexible_space);
        var utility_group = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        utility_group.add_css_class ("linked");
        spellcheck_button = new Gtk.Button.from_icon_name ("tools-check-spelling-symbolic");
        spellcheck_button.tooltip_text = "Check spelling";
        Accessibility.label (spellcheck_button, "Check spelling");
        spellcheck_button.clicked.connect (() => show_spelling_dialog.begin ());
        utility_group.append (spellcheck_button);
        security_button = new Gtk.Button.from_icon_name ("channel-insecure-symbolic");
        Accessibility.label (security_button, "Message signing and encryption");
        security_button.clicked.connect (() => configure_security.begin ()); utility_group.append (security_button);
        utility_group.append (build_compose_overflow_button ());
        bottom_actions.append (utility_group);
        root.append (bottom_actions); toolbar.set_content (root); overlay.set_child (toolbar); content = overlay;

        if (saved_draft != null) populate_draft ();
        else if (source_message != null) prepare_response (source_message, mode);
        if (saved_draft == null) apply_initial_signature ();
        signature_initialized = true;
        signature_settings_handler = settings.changed.connect ((key) => {
            if (key == "signature." + draft.account_id ||
                key == "signature-enabled." + draft.account_id)
                apply_signature_setting ();
            if (key == "spellcheck-enabled") schedule_spellcheck ();
        });
        to_entry.changed.connect (edited_by_user); cc_entry.changed.connect (edited_by_user); bcc_entry.changed.connect (edited_by_user);
        subject_entry.changed.connect (edited_by_user);
        body.buffer.changed.connect (() => { edited_by_user (); schedule_spellcheck (); });
        body.buffer.mark_set.connect ((location, mark) => {
            if (mark == body.buffer.get_insert () ||
                mark == body.buffer.get_selection_bound ())
                update_format_controls ();
        });
        // GtkShortcutAction on Ctrl+Return can re-enter GTK's active focus
        // traversal on some GTK 4/X11 combinations. Handle the completed key
        // gesture instead, then begin the transition after key dispatch has
        // returned to the main loop.
        var send_keys = new Gtk.EventControllerKey ();
        bool send_key_pending = false;
        send_keys.propagation_phase = Gtk.PropagationPhase.CAPTURE;
        send_keys.key_pressed.connect ((keyval, keycode, state) => {
            if ((state & Gdk.ModifierType.CONTROL_MASK) == 0 ||
                (keyval != Gdk.Key.Return && keyval != Gdk.Key.KP_Enter))
                return false;
            send_key_pending = true;
            return true;
        });
        send_keys.key_released.connect ((keyval, keycode, state) => {
            if (send_key_pending &&
                (keyval == Gdk.Key.Return || keyval == Gdk.Key.KP_Enter)) {
                send_key_pending = false;
                Idle.add (() => { send_message.begin (); return Source.REMOVE; });
            }
        });
        ((Gtk.Widget) this).add_controller (send_keys);
        var controller = new Gtk.ShortcutController ();
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
        if (saved_draft == null && source_message != null) {
            if (mode == ComposeMode.FORWARD)
                copy_response_attachments.begin (source_message, true);
            else
                copy_response_attachments.begin (source_message, false);
        }
        configure_outbox_state ();
        update_security_button ();
        schedule_spellcheck ();
        update_format_controls ();
        if (saved_draft != null && queued_item == null)
            set_draft_status ("Draft saved");
    }

    private void update_compose_palette (bool dark) {
        if (dark) add_css_class ("compose-dark");
        else remove_css_class ("compose-dark");
    }

    private void schedule_spellcheck () {
        if (spellcheck_source != 0) {
            Source.remove (spellcheck_source); spellcheck_source = 0;
        }
        spelling_cancellable.cancel ();
        spelling_cancellable = new Cancellable ();
        spellcheck_generation++;
        clear_spelling_context ();
        spelling_issues.clear ();
        clear_spelling_marks ();
        if (!settings.spellcheck_enabled) {
            spellcheck_button.tooltip_text = "Spell checking is off";
            Accessibility.label (spellcheck_button, "Spell checking is off");
            return;
        }
        uint generation = spellcheck_generation;
        spellcheck_source = Timeout.add (450, () => {
            spellcheck_source = 0;
            refresh_spelling.begin (generation, spelling_cancellable);
            return Source.REMOVE;
        });
    }

    private async void refresh_spelling (uint generation, Cancellable cancellable) {
        try {
            var issues = yield spell_checker.check (body.buffer.text, cancellable);
            if (cancellable.is_cancelled () || generation != spellcheck_generation) return;
            clear_spelling_context ();
            spelling_issues = issues; clear_spelling_marks ();
            foreach (var issue in spelling_issues) {
                Gtk.TextIter start; Gtk.TextIter end;
                body.buffer.get_iter_at_offset (out start, issue.start_offset);
                body.buffer.get_iter_at_offset (out end, issue.end_offset);
                body.buffer.apply_tag (spelling_tag, start, end);
            }
            string status = spelling_issues.size == 0 ? "No spelling issues found" :
                (spelling_issues.size == 1 ? "1 possible spelling issue" :
                    "%d possible spelling issues".printf (spelling_issues.size));
            spellcheck_button.tooltip_text = status;
            Accessibility.label (spellcheck_button, status + ". Check spelling");
        } catch (Error error) {
            if (!(error is IOError.CANCELLED))
                warning ("Local spell checking failed: %s", error.message);
        }
    }

    private void clear_spelling_marks () {
        Gtk.TextIter start; Gtk.TextIter end;
        body.buffer.get_bounds (out start, out end);
        body.buffer.remove_tag (spelling_tag, start, end);
    }

    private void install_spelling_context_menu () {
        var replace = new SimpleAction ("replace", VariantType.STRING);
        replace.activate.connect ((parameter) => {
            if (parameter != null) replace_context_spelling (parameter.get_string ());
        });
        spelling_actions.add_action (replace);
        var ignore = new SimpleAction ("ignore", null);
        ignore.activate.connect (() => {
            Gtk.TextIter start; Gtk.TextIter end;
            if (!resolve_spelling_context (out start, out end)) {
                clear_spelling_context (); return;
            }
            string word = context_spelling_word;
            clear_spelling_context ();
            spell_checker.ignore (word);
            schedule_spellcheck ();
            body.grab_focus ();
        });
        spelling_actions.add_action (ignore);
        var no_suggestions = new SimpleAction ("no-suggestions", null);
        no_suggestions.set_enabled (false);
        spelling_actions.add_action (no_suggestions);
        body.insert_action_group ("spell", spelling_actions);
        body.extra_menu = spelling_context_menu;

        // GtkTextView owns Cut/Copy/Paste and the rest of its normal context
        // menu. extra_menu is merged into that menu, so spelling corrections
        // augment the standard actions instead of replacing them.
        var context_click = new Gtk.GestureClick ();
        context_click.button = 0;
        context_click.propagation_phase = Gtk.PropagationPhase.CAPTURE;
        context_click.pressed.connect ((count, x, y) => {
            var event = context_click.get_current_event ();
            if (event == null || !event.triggers_context_menu ()) return;
            int buffer_x; int buffer_y;
            body.window_to_buffer_coords (Gtk.TextWindowType.WIDGET,
                (int) x, (int) y, out buffer_x, out buffer_y);
            Gtk.TextIter location; int trailing;
            if (body.get_iter_at_position (out location, out trailing, buffer_x, buffer_y))
                update_spelling_context (location.get_offset (), false);
            else clear_spelling_context ();
        });
        body.add_controller (context_click);
    }

    private void prepare_keyboard_spelling_context () {
        int offset = body.buffer.cursor_position;
        Gtk.TextIter selection_start; Gtk.TextIter selection_end;
        if (body.buffer.get_selection_bounds (out selection_start, out selection_end)) {
            foreach (var issue in spelling_issues) {
                if (issue.start_offset == selection_start.get_offset () &&
                    issue.end_offset == selection_end.get_offset ()) {
                    offset = issue.start_offset;
                    break;
                }
            }
        }
        update_spelling_context (offset, true);
    }

    private void update_spelling_context (int offset, bool accept_trailing_boundary) {
        SpellingIssue? found = null;
        foreach (var issue in spelling_issues) {
            if (issue.start_offset <= offset && offset < issue.end_offset) {
                found = issue; break;
            }
        }
        // The insertion cursor naturally sits after a word. Pointer targeting
        // remains half-open so clicking the next word cannot use the previous
        // word's correction.
        if (found == null && accept_trailing_boundary && offset > 0) {
            foreach (var issue in spelling_issues) {
                if (issue.end_offset == offset) { found = issue; break; }
            }
        }
        if (found == null) {
            clear_spelling_context (); return;
        }
        clear_spelling_context ();
        Gtk.TextIter start; Gtk.TextIter end;
        body.buffer.get_iter_at_offset (out start, found.start_offset);
        body.buffer.get_iter_at_offset (out end, found.end_offset);
        context_spelling_start = body.buffer.create_mark (null, start, true);
        context_spelling_end = body.buffer.create_mark (null, end, false);
        context_spelling_word = found.word;
        context_spelling_suggestions.add_all (found.suggestions);
        var suggestions = new Menu ();
        if (found.suggestions.size == 0)
            suggestions.append ("No Suggestions", "spell.no-suggestions");
        else foreach (var correction in found.suggestions) {
                var item = new MenuItem (correction, null);
                item.set_action_and_target_value ("spell.replace", new Variant.string (correction));
                suggestions.append_item (item);
            }
        spelling_context_menu.append_section (
            "Spelling — “%s”".printf (found.word), suggestions);
        var controls = new Menu ();
        controls.append ("Ignore for This Message", "spell.ignore");
        spelling_context_menu.append_section (null, controls);
    }

    private void clear_spelling_context () {
        if (context_spelling_start != null)
            body.buffer.delete_mark (context_spelling_start);
        if (context_spelling_end != null)
            body.buffer.delete_mark (context_spelling_end);
        context_spelling_start = null;
        context_spelling_end = null;
        context_spelling_word = "";
        context_spelling_suggestions.clear ();
        spelling_context_menu.remove_all ();
    }

    private bool resolve_spelling_context (out Gtk.TextIter start,
                                           out Gtk.TextIter end) {
        body.buffer.get_start_iter (out start);
        end = start;
        if (!settings.spellcheck_enabled || !body.editable ||
            context_spelling_start == null || context_spelling_end == null ||
            context_spelling_word == "") return false;
        body.buffer.get_iter_at_mark (out start, context_spelling_start);
        body.buffer.get_iter_at_mark (out end, context_spelling_end);
        return start.compare (end) < 0 &&
            body.buffer.get_text (start, end, true) == context_spelling_word;
    }

    private void replace_context_spelling (string correction) {
        Gtk.TextIter start; Gtk.TextIter end;
        body.buffer.get_start_iter (out start);
        end = start;
        if (correction.strip () == "" ||
            !context_spelling_suggestions.contains (correction) ||
            !resolve_spelling_context (out start, out end)) {
            clear_spelling_context (); schedule_spellcheck (); return;
        }
        clear_spelling_context ();
        RichTextBuffer.replace_preserving_format (body.buffer, start, end, correction);
        body.grab_focus ();
    }

    private void cancel_spellcheck () {
        if (spellcheck_source != 0) {
            Source.remove (spellcheck_source); spellcheck_source = 0;
        }
        spellcheck_generation++; spelling_cancellable.cancel ();
        clear_spelling_context ();
    }

    private async void show_spelling_dialog () {
        if (!settings.spellcheck_enabled) {
            overlay.add_toast (new Adw.Toast ("Turn on spell checking in Settings → Composing"));
            return;
        }
        cancel_spellcheck (); spelling_cancellable = new Cancellable ();
        uint generation = spellcheck_generation;
        yield refresh_spelling (generation, spelling_cancellable);
        if (spelling_issues.size == 0) {
            overlay.add_toast (new Adw.Toast ("No spelling issues found")); return;
        }

        int cursor = body.buffer.cursor_position;
        SpellingIssue issue = spelling_issues[0];
        foreach (var candidate in spelling_issues) {
            if (candidate.start_offset <= cursor && candidate.end_offset >= cursor) {
                issue = candidate; break;
            }
            if (candidate.start_offset >= cursor) { issue = candidate; break; }
        }
        var dialog = new Adw.AlertDialog ("Check Spelling",
            "“%s” may be misspelled. Corrections come from a local dictionary.".printf (issue.word));
        Adw.ComboRow? suggestions_row = null;
        if (issue.suggestions.size > 0) {
            var suggestions = new Gtk.StringList (null);
            foreach (var suggestion in issue.suggestions) suggestions.append (suggestion);
            suggestions_row = new Adw.ComboRow (); suggestions_row.title = "Replace with";
            suggestions_row.model = suggestions; dialog.extra_child = suggestions_row;
        }
        dialog.add_response ("cancel", "Close");
        dialog.add_response ("ignore", "Ignore for This Message");
        if (suggestions_row != null) {
            dialog.add_response ("change", "Change");
            dialog.set_response_appearance ("change", Adw.ResponseAppearance.SUGGESTED);
            dialog.default_response = "change";
        } else dialog.default_response = "ignore";
        dialog.close_response = "cancel";
        string response = yield dialog.choose (this, null);
        if (response == "ignore") {
            spell_checker.ignore (issue.word); schedule_spellcheck (); body.grab_focus ();
            return;
        }
        if (response != "change" || suggestions_row == null ||
            suggestions_row.selected >= issue.suggestions.size) return;
        Gtk.TextIter start; Gtk.TextIter end;
        body.buffer.get_iter_at_offset (out start, issue.start_offset);
        body.buffer.get_iter_at_offset (out end, issue.end_offset);
        if (body.buffer.get_text (start, end, true) != issue.word) {
            schedule_spellcheck ();
            return;
        }
        RichTextBuffer.replace_preserving_format (body.buffer, start, end,
            issue.suggestions[(int) suggestions_row.selected]);
        body.grab_focus ();
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
        if (force_close) {
            attachment_operations.cancel (); cancel_undo_countdown (); cancel_spellcheck ();
            disconnect_signature_settings ();
            return false;
        }
        confirm_close.begin (); return true;
    }

    internal void request_close () {
        confirm_close.begin ();
    }

    private void populate_draft () {
        to_entry.text = draft.to; cc_entry.text = draft.cc; bcc_entry.text = draft.bcc;
        subject_entry.text = draft.subject;
        string body_text = draft.body_text;
        // Older drafts can retain their HTML body while the plain-text column
        // is empty. Reconstruct readable editor text instead of opening a
        // blank compose window.
        if (body_text.strip () == "" && draft.body_html.strip () != "")
            body_text = HtmlSanitizer.to_plain_text (draft.body_html);
        body.buffer.text = body_text;
        RichTextBuffer.restore (body.buffer, draft.body_format); render_attachments ();
        loaded_body_text = body_text; loaded_body_html = draft.body_html;
        loaded_draft_snapshot = true;
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
        string selected_identity = identity.text.strip ();
        bool changed = draft.security_protocol != selected_protocol ||
            draft.sign_message != sign.active || draft.encrypt_message != encrypt.active ||
            draft.security_identity != selected_identity;
        draft.security_protocol = selected_protocol; draft.sign_message = sign.active;
        draft.encrypt_message = encrypt.active; draft.security_identity = selected_identity;
        if (changed) { draft.touch (); edited_by_user (); }
        update_security_button ();
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

    private Gtk.ToggleButton format_toggle_button (string icon_name, string label,
                                                    string tag_name) {
        var button = new Gtk.ToggleButton ();
        button.icon_name = icon_name;
        button.add_css_class ("flat");
        button.tooltip_text = "%s selected text".printf (label);
        Accessibility.label (button, "%s formatting".printf (label));
        button.clicked.connect (() => apply_format (tag_name));
        return button;
    }

    private Gtk.MenuButton build_compose_overflow_button () {
        var strikethrough = new SimpleAction ("strikethrough", null);
        strikethrough.activate.connect (() => apply_format (RichTextBuffer.STRIKETHROUGH));
        compose_actions.add_action (strikethrough);
        var code = new SimpleAction ("code", null);
        code.activate.connect (() => apply_format (RichTextBuffer.CODE));
        compose_actions.add_action (code);
        var bullets = new SimpleAction ("bullets", null);
        bullets.activate.connect (() => apply_list (false));
        compose_actions.add_action (bullets);
        var numbers = new SimpleAction ("numbers", null);
        numbers.activate.connect (() => apply_list (true));
        compose_actions.add_action (numbers);
        var insert_template_action = new SimpleAction ("insert-template", null);
        insert_template_action.activate.connect (() => insert_template.begin ());
        compose_actions.add_action (insert_template_action);
        var save_template_action = new SimpleAction ("save-template", null);
        save_template_action.activate.connect (() => save_as_template.begin ());
        compose_actions.add_action (save_template_action);
        var signature = new SimpleAction ("signature", null);
        signature.activate.connect (insert_signature);
        compose_actions.add_action (signature);
        insert_action_group ("compose", compose_actions);

        var formatting = new Menu ();
        formatting.append ("Strikethrough", "compose.strikethrough");
        formatting.append ("Code Style", "compose.code");
        formatting.append ("Bulleted List", "compose.bullets");
        formatting.append ("Numbered List", "compose.numbers");
        var reusable_content = new Menu ();
        reusable_content.append ("Insert Template…", "compose.insert-template");
        reusable_content.append ("Save as Template…", "compose.save-template");
        reusable_content.append ("Insert Signature", "compose.signature");
        var menu = new Menu ();
        menu.append_section ("More Formatting", formatting);
        menu.append_section ("Reusable Content", reusable_content);

        var button = new Gtk.MenuButton ();
        button.icon_name = "view-more-symbolic";
        button.tooltip_text = "More compose options";
        Accessibility.label (button, "More compose options");
        button.menu_model = menu;
        return button;
    }

    private bool format_is_active (string tag_name) {
        var tag = body.buffer.tag_table.lookup (tag_name);
        if (tag == null) return false;
        Gtk.TextIter start; Gtk.TextIter end;
        if (body.buffer.get_selection_bounds (out start, out end)) {
            Gtk.TextIter cursor = start;
            while (cursor.compare (end) < 0) {
                if (!cursor.has_tag (tag)) return false;
                if (!cursor.forward_char ()) break;
            }
            return start.compare (end) < 0;
        }
        body.buffer.get_iter_at_mark (out start, body.buffer.get_insert ());
        if (start.has_tag (tag)) return true;
        if (start.get_offset () == 0) return false;
        start.backward_char ();
        return start.has_tag (tag);
    }

    private void update_format_controls () {
        bold_button.active = format_is_active (RichTextBuffer.BOLD);
        italic_button.active = format_is_active (RichTextBuffer.ITALIC);
        underline_button.active = format_is_active (RichTextBuffer.UNDERLINE);
    }

    private Gtk.Shortcut format_shortcut (string trigger, string tag_name) {
        return new Gtk.Shortcut (Gtk.ShortcutTrigger.parse_string (trigger),
            new Gtk.CallbackAction (() => { apply_format (tag_name); return true; }));
    }

    private void apply_format (string tag_name) {
        if (!RichTextBuffer.toggle_selection (body.buffer, tag_name)) {
            overlay.add_toast (new Adw.Toast ("Select text to apply formatting."));
            body.grab_focus ();
            update_format_controls ();
            return;
        }
        update_draft (); edited_by_user (); body.grab_focus (); update_format_controls ();
    }

    private void apply_list (bool ordered) {
        RichTextBuffer.prefix_lines (body.buffer, ordered);
        update_draft (); edited_by_user (); body.grab_focus ();
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

    private void configure_recipient_entry (Gtk.Entry entry, string placeholder,
                                            bool required) {
        entry.placeholder_text = placeholder;
        string guidance = required ?
            "Enter at least one email address. Separate multiple recipients with commas." :
            "Separate multiple email addresses with commas.";
        entry.tooltip_text = guidance;
        Accessibility.description (entry, guidance);
        entry.changed.connect (() => {
            entry.remove_css_class ("error");
            entry.tooltip_text = guidance;
            Accessibility.description (entry, guidance);
        });
        entry.notify["has-focus"].connect (() => {
            if (!entry.has_focus) validate_recipient_entry (entry, required, guidance);
        });
    }

    private void validate_recipient_entry (Gtk.Entry entry, bool required,
                                           string guidance) {
        if (!required && entry.text.strip () == "") {
            entry.remove_css_class ("error");
            entry.tooltip_text = guidance;
            Accessibility.description (entry, guidance);
            return;
        }
        try {
            var recipients = RecipientParser.parse (entry.text);
            string status = recipients.size == 1 ? "1 valid recipient" :
                "%d valid recipients".printf (recipients.size);
            entry.remove_css_class ("error");
            entry.tooltip_text = status;
            Accessibility.description (entry, status);
        } catch (Error error) {
            entry.add_css_class ("error");
            entry.tooltip_text = error.message;
            Accessibility.description (entry, error.message);
        }
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
                draft.touch (); edited_by_user ();
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
        string original_html = response_html (source);
        if (mode == ComposeMode.FORWARD) {
            subject_entry.text = source.subject.has_prefix ("Fwd:") ? source.subject : "Fwd: " + source.subject;
            response_quote_text = "---------- Forwarded message ----------\nFrom: %s <%s>\nTo: %s\nDate: %s\nSubject: %s\n\n%s".printf (
                source.sender_name, source.sender_address, source.recipients, source.timestamp, source.subject, original_body);
            response_quote_html = original_html == "" ? "" : response_html_block (source, original_html, true);
            body.buffer.text = "\n\n" + response_quote_text;
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
        response_quote_text = "On %s, %s wrote:\n%s".printf (source.timestamp, source.sender_name, quoted.str);
        response_quote_html = original_html == "" ? "" : response_html_block (source, original_html, false);
        body.buffer.text = "\n\n" + response_quote_text;
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

    private string response_html (Message source) {
        if (source.body_html.strip () == "") return "";
        // The received HTML has already been parsed for display, but sanitize
        // again at the outgoing boundary. Remote images are retained so a
        // forwarded/replied message keeps the original visual content.
        return HtmlSanitizer.sanitize (source.body_html, true, settings.full_html_formatting);
    }

    private static string response_html_block (Message source, string original_html, bool forwarded) {
        if (forwarded) {
            return "<p>---------- Forwarded message ----------</p>" +
                "<p><strong>From:</strong> %s &lt;%s&gt;<br>".printf (
                    Markup.escape_text (source.sender_name), Markup.escape_text (source.sender_address)) +
                "<strong>To:</strong> %s<br><strong>Date:</strong> %s<br>".printf (
                    Markup.escape_text (source.recipients), Markup.escape_text (source.timestamp)) +
                "<strong>Subject:</strong> %s</p><blockquote type=\"cite\">%s</blockquote>".printf (
                    Markup.escape_text (source.subject), original_html);
        }
        return "<p>On %s, %s wrote:</p><blockquote type=\"cite\">%s</blockquote>".printf (
            Markup.escape_text (source.timestamp), Markup.escape_text (source.sender_name), original_html);
    }

    private async void copy_response_attachments (Message source, bool forwarded) {
        var candidates = new Gee.ArrayList<Attachment> ();
        foreach (var attachment in source.attachments)
            if (forwarded || attachment.content_id != "") candidates.add (attachment);
        if (candidates.size == 0) return;
        importing_forward_attachments = true; send_button.sensitive = false;
        forward_status_label.label = candidates.size == 1 ?
            (forwarded ? "Preparing forwarded attachment…" : "Preparing inline image…") :
            (forwarded ? "Preparing %d forwarded attachments…" : "Preparing %d inline images…").printf (candidates.size);
        forward_status.visible = true; forward_spinner.start ();
        int failures = 0;
        foreach (var attachment in candidates) {
            try {
                var copy = yield received_attachment_service.copy_for_draft (
                    source, attachment, attachment_operations);
                if (force_close) {
                    try { attachment_service.remove_private_copy (copy); }
                    catch (Error cleanup_error) {
                        warning ("Closed response attachment cleanup remains pending: %s",
                            cleanup_error.message);
                    }
                    break;
                }
                draft.add_attachment (copy); render_attachments ();
            } catch (Error error) {
                if (!(error is IOError.CANCELLED) && !(error is MailError.CANCELLED)) failures++;
            }
        }
        if (force_close) return;
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

    private async bool confirm_attachment_intent () {
        if (!ComposeSafetyService.mentions_missing_attachment (
                draft.subject, draft.body_text, draft.attachments.size > 0)) return true;
        var dialog = new Adw.AlertDialog ("Did you forget an attachment?",
            "The message mentions an attachment, but no file is attached.");
        dialog.add_response ("edit", "Keep Editing");
        dialog.add_response ("send", "Send Without Attachment");
        dialog.close_response = "edit"; dialog.default_response = "edit";
        dialog.set_response_appearance ("send", Adw.ResponseAppearance.SUGGESTED);
        return (yield dialog.choose (this, null)) == "send";
    }

    private async void choose_attachments () {
        var dialog = new Gtk.FileDialog (); dialog.title = "Attach Files";
        dialog.initial_folder = settings.file_dialog_initial_folder ();
        try {
            var files = yield dialog.open_multiple (this, attachment_operations);
            var first = files.get_item (0) as File;
            if (first != null) settings.remember_file_dialog_selection (first);
            for (uint index = 0; index < files.get_n_items (); index++) {
                var file = files.get_item (index) as File;
                if (file != null) yield import_attachment (file);
            }
        } catch (Error error) {
            if (!DialogErrors.was_cancelled (error)) show_attachment_error (error);
        }
    }

    private async void import_attachment (File file) {
        try {
            var attachment = yield attachment_service.import_file (file, attachment_operations);
            if (force_close) {
                attachment_service.remove_private_copy (attachment);
                return;
            }
            draft.add_attachment (attachment); render_attachments (); edited_by_user ();
        } catch (Error error) { if (!DialogErrors.was_cancelled (error)) show_attachment_error (error); }
    }

    private async void choose_inline_image () {
        var dialog = new Gtk.FileDialog (); dialog.title = "Insert Image";
        dialog.initial_folder = settings.file_dialog_initial_folder ();
        try {
            var file = yield dialog.open (this, attachment_operations);
            settings.remember_file_dialog_selection (file);
            var imported = yield attachment_service.import_file (file, attachment_operations);
            if (force_close) {
                attachment_service.remove_private_copy (imported);
                return;
            }
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
        } catch (Error error) { if (!DialogErrors.was_cancelled (error)) show_attachment_error (error); }
    }

    private void render_attachments () {
        while (attachment_rows.get_first_child () != null)
            attachment_rows.remove ((Gtk.Widget) attachment_rows.get_first_child ());
        foreach (var attachment in draft.attachments) {
            var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8); row.add_css_class ("attachment-chip");
            bool requires_download = !attachment.is_downloaded ();
            if (requires_download) row.add_css_class ("requires-download");
            row.append (new Gtk.Image.from_icon_name (requires_download ?
                "dialog-warning-symbolic" : "mail-attachment-symbolic"));
            var label = new Gtk.Label (requires_download ?
                "%s  ·  Not available locally — remove or reattach before sending".printf (attachment.name) :
                "%s  ·  %s".printf (attachment.name, attachment.formatted_size ()));
            label.xalign = 0; label.hexpand = true; label.ellipsize = Pango.EllipsizeMode.MIDDLE; row.append (label);
            if (requires_download) {
                row.tooltip_text = "Remove this attachment or attach a local copy before sending";
                Accessibility.label (row, "%s. Not available locally. Remove or reattach before sending.".printf (
                    attachment.name));
            }
            if (!requires_download &&
                AttachmentSafety.preview_kind (attachment.content_type, attachment.name) != AttachmentPreviewKind.NONE) {
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
        draft.remove_attachment (attachment); render_attachments (); edited_by_user ();
    }

    private void show_attachment_error (Error error) {
        var friendly = UserFacingError.from_error (error);
        overlay.add_toast (new Adw.Toast ("%s — %s".printf (friendly.title, friendly.suggestion)));
    }

    private void update_draft () {
        draft.to = to_entry.text; draft.cc = cc_entry.text; draft.bcc = bcc_entry.text;
        draft.subject = subject_entry.text; draft.body_text = body.buffer.text;
        draft.body_format = RichTextBuffer.serialize (body.buffer);
        bool preserve_loaded = loaded_draft_snapshot && body.buffer.text == loaded_body_text;
        int quote_byte_start = response_quote_text == "" ? -1 : body.buffer.text.index_of (response_quote_text);
        int quote_start = quote_byte_start < 0 ? -1 :
            body.buffer.text.substring (0, quote_byte_start).char_count ();
        if (response_quote_html != "" && quote_start >= 0) {
            int quote_end = quote_start + response_quote_text.char_count ();
            draft.body_html = "<div>" +
                RichTextBuffer.to_html_fragment (body.buffer, 0, quote_start) +
                response_quote_html +
                RichTextBuffer.to_html_fragment (body.buffer, quote_end, body.buffer.get_char_count ()) +
                "</div>";
        } else if (!preserve_loaded) draft.body_html = RichTextBuffer.to_html (body.buffer);
        foreach (var attachment in draft.attachments) {
            if (attachment.content_id == "" || draft.body_html == "") continue;
            string marker = "[Image: %s]".printf (Markup.escape_text (attachment.name));
            string cid = attachment.content_id.replace ("<", "").replace (">", "");
            draft.body_html = draft.body_html.replace (marker,
                "<img src=\"cid:%s\" alt=\"%s\">".printf (cid, Markup.escape_text (attachment.name)));
        }
        loaded_body_text = draft.body_text; loaded_body_html = draft.body_html;
        loaded_draft_snapshot = true;
        draft.touch ();
    }

    private void edited_by_user () {
        if (force_close || outbox_read_only) return;
        changed_by_user = true;
        schedule_autosave ();
    }

    private void set_draft_status (string status) {
        draft_status_label.label = status;
        draft_status_label.visible = status != "";
        draft_status_label.tooltip_text = status == "" ? null : status;
    }

    private void schedule_autosave () {
        if (force_close) return;
        cancel_autosave ();
        set_draft_status (has_content () ? "Saving…" : "");
        autosave_source = Timeout.add_seconds (2, () => {
            autosave_source = 0;
            try {
                if (has_content ()) {
                    update_draft (); cache.save_draft (draft);
                    set_draft_status ("Draft saved");
                } else set_draft_status ("");
            }
            catch (Error error) {
                set_draft_status ("Draft not saved");
                overlay.add_toast (new Adw.Toast ("Draft could not be saved. Check local storage and try again."));
            }
            return Source.REMOVE;
        });
    }

    private void save_draft_now () {
        if (importing_forward_attachments) {
            overlay.add_toast (new Adw.Toast (
                "Wait for the forwarded attachments to finish copying."));
            return;
        }
        cancel_autosave ();
        set_draft_status ("Saving…");
        try {
            update_draft (); cache.save_draft (draft); draft_changed ();
            opened_saved_draft = true; changed_by_user = false;
            set_draft_status ("Draft saved");
            overlay.add_toast (new Adw.Toast ("Draft saved"));
        } catch (Error error) {
            set_draft_status ("Draft not saved");
            overlay.add_toast (new Adw.Toast ("Draft could not be saved. Check local storage and try again."));
        }
    }

    private async void send_message () {
        if (sending) return;
        if (outbox_read_only) {
            overlay.add_toast (new Adw.Toast (queued_item != null &&
                queued_item.delivery_state == OutboxDeliveryState.PREPARING ?
                "This message is already being sent." :
                "This message cannot be sent again."));
            return;
        }
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
        if (!(yield confirm_attachment_intent ())) return;
        // Freeze every producer of draft changes before OutboundService takes its
        // durable Undo Send snapshot. A late autosave must never overwrite the
        // exact version waiting behind the Outbox deadline.
        cancel_autosave (); cancel_spellcheck (); attachment_operations.cancel ();
        sending = true; set_editor_sensitive (false); send_button.sensitive = false;
        send_button.label = "Saving to Outbox…";
        try {
            int seconds = settings.undo_send_seconds;
            outbound_service.defer_for_undo (draft, seconds, uncertain_resend_confirmed);
            queued_item = cache.find_outbox_item (draft.id);
            if (queued_item == null)
                throw new MailError.STORAGE ("The Undo Send item could not be reopened from Outbox");
            draft.mark_saved (); draft_changed (); sending = false;
            attachment_operations = new Cancellable ();
            configure_outbox_state (); begin_undo_countdown ();
            overlay.add_toast (new Adw.Toast (
                "Message saved to Outbox — Undo is available for %d seconds.".printf (seconds)));
            return;
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
        attachment_operations = new Cancellable ();
        sending = false; set_editor_sensitive (true); send_button.sensitive = true; restore_send_button_label ();
        configure_outbox_state ();
    }

    private async void schedule_send () {
        if (queued_item != null && queued_item.delivery_state == OutboxDeliveryState.PREPARING) return;
        if (importing_forward_attachments) {
            overlay.add_toast (new Adw.Toast ("Wait for the forwarded attachments to finish copying."));
            return;
        }
        update_draft ();
        if (!(yield confirm_attachment_intent ())) return;
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
            "Choose the exact local date and time for delivery. Mailficient will use background delivery when allowed; otherwise it sends during the next mail check or launch.");
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
        if (queued_item == null || queued_item.delivery_state == OutboxDeliveryState.ACCEPTED ||
            queued_item.delivery_state == OutboxDeliveryState.PREPARING) return;
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

    private void refresh_outbox_status () {
        while (outbox_status_container.get_first_child () != null)
            outbox_status_container.remove ((Gtk.Widget) outbox_status_container.get_first_child ());
        if (queued_item != null)
            outbox_status_container.append (new OutboxStatusView (queued_item));
        outbox_status_container.visible = queued_item != null;
    }

    private void begin_undo_countdown () {
        cancel_undo_countdown ();
        if (queued_item == null || !queued_item.can_undo ()) return;
        update_undo_countdown_copy ();
        undo_countdown_source = Timeout.add_seconds (1, () => {
            try { queued_item = cache.find_outbox_item (draft.id); }
            catch (Error error) {
                warning ("Could not refresh Undo Send status: %s", error.message);
                undo_countdown_source = 0; return Source.REMOVE;
            }
            if (queued_item != null && queued_item.can_undo ()) {
                update_undo_countdown_copy (); refresh_outbox_status ();
                return Source.CONTINUE;
            }
            undo_countdown_source = 0; undo_send_button.visible = false;
            // The durable deadline has elapsed. Closing prevents an editor from
            // racing the worker as it moves QUEUED to its exclusive PREPARING
            // lease; the Outbox remains visible in the main window.
            draft_changed (); force_close = true; close ();
            return Source.REMOVE;
        });
    }

    private void update_undo_countdown_copy () {
        if (queued_item == null) return;
        int64 remaining = int64.max (1,
            queued_item.undo_until - new DateTime.now_utc ().to_unix ());
        send_button.label = remaining == 1 ? "Sending in 1 second…" :
            "Sending in %lld seconds…".printf (remaining);
        undo_send_button.tooltip_text = remaining == 1 ?
            "1 second remains to cancel this send" :
            "%lld seconds remain to cancel this send".printf (remaining);
    }

    private void cancel_undo_countdown () {
        if (undo_countdown_source != 0) {
            Source.remove (undo_countdown_source); undo_countdown_source = 0;
        }
    }

    private void undo_send () {
        if (queued_item == null || !queued_item.can_undo ()) return;
        cancel_undo_countdown ();
        try {
            if (!outbound_service.cancel_undo_send (draft.id, draft.account_id)) {
                queued_item = cache.find_outbox_item (draft.id);
                overlay.add_toast (new Adw.Toast (
                    "The Undo Send window ended before the message could be canceled."));
                configure_outbox_state ();
                force_close = true;
                Idle.add (() => { close (); return Source.REMOVE; });
                return;
            }
            queued_item = cache.find_outbox_item (draft.id);
        } catch (Error error) {
            overlay.add_toast (new Adw.Toast (
                "Undo Send could not update Outbox. The message remains queued."));
            try { queued_item = cache.find_outbox_item (draft.id); }
            catch (Error status_error) {
                warning ("Could not reload Outbox after Undo Send failure: %s", status_error.message);
            }
            if (queued_item == null || !queued_item.can_undo ()) {
                force_close = true; Idle.add (() => { close (); return Source.REMOVE; });
            } else begin_undo_countdown ();
            return;
        }
        uncertain_resend_confirmed = false;
        if (queued_item == null) {
            title = "Edit Draft"; outbox_read_only = false; accepted_pending_cleanup = false;
            set_editor_sensitive (true); cancel_button.label = "Cancel";
            send_button.sensitive = true; send_later_button.sensitive = true;
            undo_send_button.visible = false;
            if (delete_queued_button != null) delete_queued_button.visible = false;
            attachment_operations = new Cancellable (); restore_send_button_label ();
            refresh_outbox_status (); schedule_spellcheck ();
            overlay.add_toast (new Adw.Toast ("Send canceled — the message is back in Drafts."));
        } else {
            configure_outbox_state ();
            overlay.add_toast (new Adw.Toast ("Send canceled — the previous Outbox state was restored."));
        }
        draft_changed ();
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
        outbox_read_only = false; accepted_pending_cleanup = false;
        undo_send_button.visible = false; cancel_button.label = "Cancel";
        set_editor_sensitive (true); send_button.sensitive = true;
        send_later_button.sensitive = true;
        if (delete_queued_button != null) {
            delete_queued_button.visible = queued_item != null;
            delete_queued_button.sensitive = true;
        }
        refresh_outbox_status ();
        if (queued_item == null) { restore_send_button_label (); return; }
        if (queued_item.can_undo ()) {
            outbox_read_only = true; set_editor_sensitive (false);
            cancel_button.sensitive = true; cancel_button.label = "Close";
            undo_send_button.sensitive = true; undo_send_button.visible = true;
            send_button.sensitive = false; send_later_button.sensitive = false;
            if (delete_queued_button != null) delete_queued_button.sensitive = false;
            update_undo_countdown_copy (); begin_undo_countdown ();
        } else if (queued_item.delivery_state == OutboxDeliveryState.SENDING) {
            send_button.label = "Send Again…";
        } else if (queued_item.delivery_state == OutboxDeliveryState.PREPARING) {
            outbox_read_only = true;
            set_editor_sensitive (false); cancel_button.sensitive = true; cancel_button.label = "Close";
            send_button.sensitive = false; send_button.label = "Sending…";
            send_later_button.sensitive = false;
        } else if (queued_item.delivery_state == OutboxDeliveryState.ACCEPTED) {
            accepted_pending_cleanup = true;
            outbox_read_only = true;
            set_editor_sensitive (false); cancel_button.sensitive = true; cancel_button.label = "Close";
            send_button.sensitive = false; send_button.label = "Already Sent";
            send_later_button.sensitive = false;
        } else if (queued_item.attempts > 0) send_button.label = "Try Again";
    }

    private void restore_send_button_label () {
        if (queued_item != null && queued_item.can_undo ())
            update_undo_countdown_copy ();
        else if (queued_item != null && queued_item.requires_resend_confirmation ())
            send_button.label = "Send Again…";
        else if (queued_item != null && queued_item.attempts > 0)
            send_button.label = "Try Again";
        else send_button.label = "Send";
    }

    private async void confirm_close () {
        if (sending) { overlay.add_toast (new Adw.Toast ("Wait for the current send attempt to finish.")); return; }
        if (outbox_read_only) { force_close = true; close (); return; }
        if (!changed_by_user) {
            cancel_autosave ();
            force_close = true;
            attachment_operations.cancel ();
            if (!opened_saved_draft) {
                try {
                    draft_lifecycle.discard (draft);
                } catch (Error error) {
                    force_close = false;
                    attachment_operations = new Cancellable ();
                    overlay.add_toast (new Adw.Toast ("Draft could not be discarded."));
                    return;
                }
                draft_changed ();
            }
            close ();
            return;
        }
        var dialog = new Adw.AlertDialog ("Save this draft?", "You can reopen saved drafts from the Drafts mailbox.");
        dialog.add_response ("cancel", "Keep Editing"); dialog.add_response ("discard", "Discard"); dialog.add_response ("save", "Save Draft");
        dialog.close_response = "cancel"; dialog.default_response = "save";
        dialog.set_response_appearance ("discard", Adw.ResponseAppearance.DESTRUCTIVE);
        dialog.set_response_appearance ("save", Adw.ResponseAppearance.SUGGESTED);
        string response = yield dialog.choose (this, null);
        if (response == "save") {
            if (importing_forward_attachments) {
                overlay.add_toast (new Adw.Toast (
                    "Wait for the forwarded attachments to finish copying, then save again."));
                return;
            }
            cancel_autosave ();
            force_close = true;
            attachment_operations.cancel ();
            try { update_draft (); cache.save_draft (draft); }
            catch (Error error) {
                force_close = false;
                attachment_operations = new Cancellable ();
                overlay.add_toast (new Adw.Toast ("Draft could not be saved. Check local storage and try again."));
                return;
            }
            draft_changed (); close (); return;
        }
        if (response == "discard") {
            cancel_autosave (); force_close = true; attachment_operations.cancel ();
            try {
                draft_lifecycle.discard (draft);
            } catch (Error error) {
                force_close = false;
                attachment_operations = new Cancellable ();
                overlay.add_toast (new Adw.Toast ("Draft could not be discarded."));
                return;
            }
            draft_changed (); close ();
        }
    }
}
}
