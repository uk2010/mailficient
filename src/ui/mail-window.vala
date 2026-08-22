namespace Mailficient {
public class MailWindow : Adw.ApplicationWindow {
    private const int READER_MIN_WIDTH = 280;
    private static int startup_dimension (int requested, bool horizontal) {
        var display = Gdk.Display.get_default ();
        if (display == null) return requested;
        var monitors = display.get_monitors ();
        if (monitors.get_n_items () == 0) return requested;
        var monitor = monitors.get_item (0) as Gdk.Monitor;
        if (monitor == null) return requested;
        Gdk.Rectangle geometry = monitor.get_geometry ();
        int screen_dimension = horizontal ? geometry.width : geometry.height;
        int margin = horizontal ? 64 : 96;
        int available = screen_dimension - margin;
        int minimum = horizontal ? 640 : 480;
        if (available < minimum) available = screen_dimension;
        return requested < available ? requested : available;
    }

    private MailRepository repository;
    private MessageList message_list;
    private ReadingPane reader;
    private Gtk.SearchEntry search = new Gtk.SearchEntry ();
    private CacheDatabase cache;
    private AttachmentService attachment_service;
    private ReceivedAttachmentService received_attachment_service;
    private DraftLifecycleService draft_lifecycle;
    private OutboundService outbound_service;
    private MailSettingsStore settings;
    private RemoteContentPolicy remote_content_policy;
    private AccountProvisioningService? account_provisioner;
    private CredentialStore credentials;
    private CredentialCleanupService credential_cleanup;
    private MailEngine? mail_engine;
    private AccountSyncService? sync_service;
    private FolderService folder_service;
    private OnlineAccountService online_accounts;
    private Adw.ToastOverlay toast_overlay = new Adw.ToastOverlay ();
    private Gtk.Revealer sync_status_revealer = new Gtk.Revealer ();
    private Gtk.Label sync_status_label = new Gtk.Label ("");
    private Gtk.ProgressBar sync_progress_bar = new Gtk.ProgressBar ();
    private Gtk.Button sync_cancel_button = new Gtk.Button.from_icon_name ("window-close-symbolic");
    private bool sync_cancel_requested;
    private uint sync_status_hide_source;
    private uint sync_progress_update_source;
    private double pending_sync_fraction;
    private string pending_sync_detail = "";
    private Gtk.Button refresh_button = new Gtk.Button.from_icon_name ("view-refresh-symbolic");
    private Gtk.Button reply_button = new Gtk.Button.from_icon_name ("mail-reply-sender-symbolic");
    private Gtk.Button reply_all_button = new Gtk.Button.from_icon_name ("mail-reply-all-symbolic");
    private Gtk.Button forward_button = new Gtk.Button.from_icon_name ("mail-forward-symbolic");
    private Gtk.Button archive_button = new Gtk.Button.from_icon_name ("package-x-generic-symbolic");
    private Gtk.Button delete_button = new Gtk.Button.from_icon_name ("user-trash-symbolic");
    private Gtk.Button junk_button = new Gtk.Button.from_icon_name ("dialog-warning-symbolic");
    private Gtk.Button flag_button = new Gtk.Button.from_icon_name ("mailficient-flag-symbolic");
    private Gtk.MenuButton flag_color_button = new Gtk.MenuButton ();
    private Gtk.MenuButton more_button = new Gtk.MenuButton ();
    private Gtk.MenuButton move_button = new Gtk.MenuButton ();
    private SimpleAction? group_messages_action;
    private SimpleAction? always_show_images_action;
    private SimpleAction? full_html_formatting_action;
    private Gtk.MenuButton sort_button = new Gtk.MenuButton ();
    private Gtk.Box customizable_toolbar = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
    private Gtk.PopoverMenu? toolbar_context_menu;
    // Start compact until the first allocation tells the adaptive breakpoint
    // that a wide toolbar is genuinely available. This prevents the wide
    // toolbar's natural width from forcing the window wider during startup.
    private bool compact_toolbar = true;
    private Message? selected_message;
    private Mailbox? active_mailbox;
    private Adw.OverlaySplitView mailbox_split = new Adw.OverlaySplitView ();
    // The mail list/reader divider is a native split pane. The previous
    // NavigationSplitView plus custom drag widget could only move a few
    // pixels on some GTK/Adwaita layouts.
    private Gtk.Paned message_split = new Gtk.Paned (Gtk.Orientation.HORIZONTAL);
    private Gtk.Stack content_stack = new Gtk.Stack ();
    private Adw.NavigationPage content_page;
    private Gtk.Box? message_pane;
    private Gtk.Button mailbox_toggle = new Gtk.Button.from_icon_name ("sidebar-show-symbolic");
    private Gtk.Button message_back = new Gtk.Button.from_icon_name ("go-previous-symbolic");
    private double mailbox_pane_width = 240;
    private double message_pane_width = 380;
    private double resize_start_width;
    private double resize_start_pointer_x;
    private bool qa_layout;
    private MailboxSidebar sidebar;
    private bool marking_selected_message_read;
    private bool repository_refresh_pending;
    private uint repository_refresh_source;
    private string last_selected_mailbox_id = "";
    private string preserve_unread_selection_id = "";
    private Gtk.Button? toggle_read_button;
    private MenuItem? more_toggle_read_item;

    public MailWindow (Gtk.Application app, MailRepository repository, MailSearchService search_service,
                       CacheDatabase cache, AttachmentService attachment_service,
                       ReceivedAttachmentService received_attachment_service,
                       DraftLifecycleService draft_lifecycle,
                       OutboundService outbound_service, MailSettingsStore settings, RemoteContentPolicy remote_content_policy,
                       AccountProvisioningService? account_provisioner,
                       CredentialStore credentials, CredentialCleanupService credential_cleanup, MailEngine? mail_engine,
                       AccountSyncService? sync_service, FolderService folder_service,
                       OnlineAccountService online_accounts) {
        Object (application: app, title: "Mailficient",
            default_width: startup_dimension (
                Environment.get_variable ("MAILFICIENT_QA_NARROW") == "1" ? 760 : settings.window_width, true),
            default_height: startup_dimension (
                Environment.get_variable ("MAILFICIENT_QA") == "1" ? 820 : settings.window_height, false));
        // Like Apple Mail, preserve the three-column workspace and stop at a
        // usable desktop minimum instead of collapsing into a phone layout.
        set_size_request (960, 560);
        this.repository = repository;
        this.cache = cache;
        this.attachment_service = attachment_service;
        this.received_attachment_service = received_attachment_service;
        this.draft_lifecycle = draft_lifecycle;
        this.remote_content_policy = remote_content_policy;
        this.account_provisioner = account_provisioner;
        reader = new ReadingPane (received_attachment_service, remote_content_policy);
        reader.add_account_requested.connect (() => show_accounts ());
        this.outbound_service = outbound_service;
        this.settings = settings;
        settings.changed.connect ((key) => {
            if (key == "group-messages") {
                if (group_messages_action != null)
                    group_messages_action.set_state (new Variant.boolean (settings.group_messages));
                if (selected_message != null) display_message (selected_message);
            }
            if (key == "always-show-images") {
                if (always_show_images_action != null)
                    always_show_images_action.set_state (new Variant.boolean (settings.always_show_images));
                if (selected_message != null) display_message (selected_message);
            }
            if (key == "full-html-formatting") {
                if (full_html_formatting_action != null)
                    full_html_formatting_action.set_state (new Variant.boolean (settings.full_html_formatting));
                if (selected_message != null) display_message (selected_message);
            }
            if (key == "toolbar-layout") rebuild_toolbar ();
        });
        qa_layout = Environment.get_variable ("MAILFICIENT_QA") == "1";
        mailbox_pane_width = settings.mailbox_pane_width;
        message_pane_width = settings.message_pane_width;
        string? qa_mailbox_width = Environment.get_variable ("MAILFICIENT_QA_MAILBOX_WIDTH");
        string? qa_message_width = Environment.get_variable ("MAILFICIENT_QA_MESSAGE_WIDTH");
        double parsed_width = 0;
        if (qa_mailbox_width != null && double.try_parse (qa_mailbox_width, out parsed_width))
            mailbox_pane_width = parsed_width;
        if (qa_message_width != null && double.try_parse (qa_message_width, out parsed_width))
            message_pane_width = parsed_width;
        this.credentials = credentials; this.credential_cleanup = credential_cleanup;
        this.mail_engine = mail_engine; this.sync_service = sync_service;
        this.folder_service = folder_service; this.online_accounts = online_accounts;
        message_list = new MessageList (repository, search_service);
        var toolbar = new Adw.ToolbarView ();
        toolbar.overflow = Gtk.Overflow.HIDDEN;
        var header = build_header (); toolbar.add_top_bar (header);
        header.hexpand = true; header.halign = Gtk.Align.FILL;
        sidebar = new MailboxSidebar (repository, cache); sidebar.set_size_request (220, -1);
        sidebar.mailbox_selected.connect ((mailbox) => {
            int64 selection_started = DebugTrace.mark ();
            string previous_mailbox_id = active_mailbox == null ? "" : active_mailbox.id;
            DebugTrace.log ("navigation", "mailbox_selected target=%s previous=%s".printf (
                mailbox.id, previous_mailbox_id));
            if (mailbox.id == CachedMailRepository.GNOME_CALENDAR_ID) {
                open_gnome_calendar (previous_mailbox_id);
                DebugTrace.duration ("navigation", "open_gnome_calendar_complete", selection_started);
                return;
            }
            active_mailbox = mailbox;
            last_selected_mailbox_id = mailbox.id;
            if (search.text != "") search.text = "";
            DebugTrace.log ("navigation", "load_mailbox mailbox=%s".printf (mailbox.id));
            message_list.show_mailbox (mailbox);
            var first_message = message_list.first_message ();
            if (first_message != null && !is_local_draft (first_message.id)) {
                selected_message = repository.find_message (first_message.id) ?? first_message;
                display_message (selected_message);
                mark_read_after_selection (first_message.id);
                rebuild_move_menu (); update_action_sensitivity ();
            } else { selected_message = null; reader.show_empty (); update_action_sensitivity (); }
            if (mailbox_split.collapsed) { mailbox_split.show_sidebar = false; set_message_content_visible (false); }
            DebugTrace.duration ("navigation", "mailbox_selected_complete", selection_started);
        });
        sidebar.create_folder_requested.connect ((account, parent) => prompt_create_folder.begin (account, parent));
        sidebar.rename_folder_requested.connect ((mailbox) => prompt_rename_folder.begin (mailbox));
        sidebar.delete_folder_requested.connect ((mailbox) => prompt_delete_folder.begin (mailbox));
        sidebar.empty_role_requested.connect ((role) => prompt_empty_role.begin (role));
        sidebar.empty_mailbox_requested.connect ((mailbox) => prompt_empty_mailbox.begin (mailbox));
        sidebar.export_mailbox_requested.connect ((mailbox) => export_mailbox.begin (mailbox));
        sidebar.synchronize_account_requested.connect ((account) => synchronize_account.begin (account));
        sidebar.edit_account_requested.connect (edit_account);
        sidebar.account_info_requested.connect (show_account_info);
        message_list.message_selected.connect ((message) => {
            if (is_local_draft (message.id)) {
                selected_message = null; reader.show_empty (); update_action_sensitivity (); return;
            }
            selected_message = repository.find_message (message.id) ?? message;
            display_message (selected_message);
            if (preserve_unread_selection_id == message.id)
                preserve_unread_selection_id = "";
            else
                mark_read_after_selection (message.id);
            rebuild_move_menu (); update_action_sensitivity ();
            set_message_content_visible (true);
        });
        message_list.selection_changed.connect ((messages) => {
            if (messages.size != 1 || messages[0].id != preserve_unread_selection_id)
                preserve_unread_selection_id = "";
            rebuild_move_menu (); update_action_sensitivity ();
        });
        message_list.message_activated.connect ((message) => {
            if (!is_local_draft (message.id)) return;
            try {
                string draft_id = message.id.has_prefix (CachedMailRepository.DRAFT_PREFIX) ?
                    message.id.substring (CachedMailRepository.DRAFT_PREFIX.length) :
                    message.id.substring (CachedMailRepository.OUTBOX_PREFIX.length);
                var saved = cache.load_draft (draft_id);
                if (saved != null) open_compose (null, ComposeMode.NEW, saved,
                    message.id.has_prefix (CachedMailRepository.OUTBOX_PREFIX));
            } catch (Error error) { show_operation_error (error); }
        });
        message_list.no_messages.connect (() => {
            selected_message = null;
            show_reader_empty_state ();
        });
        reader.vip_toggled.connect ((message, vip) => {
            try { repository.set_sender_vip (message, vip); display_message (message); }
            catch (Error error) { show_operation_error (error); }
        });
        reader.attachment_saved.connect ((filename) =>
            toast_overlay.add_toast (new Adw.Toast ("Saved %s".printf (filename))));
        reader.attachment_failed.connect ((error) => {
            var friendly = UserFacingError.from_error (error);
            toast_overlay.add_toast (new Adw.Toast ("%s — %s".printf (friendly.title, friendly.suggestion)));
        });
        reader.remote_content_failed.connect ((error) => show_operation_error (error));
        reader.remote_sender_trusted.connect ((address) =>
            toast_overlay.add_toast (new Adw.Toast ("Images will load automatically from %s".printf (address))));
        outbound_service.delivery_failed.connect ((draft_id, error) =>
            toast_overlay.add_toast (new Adw.Toast ("Queued message not sent — %s".printf (error.suggestion))));
        outbound_service.sent_filing_failed.connect ((draft_id, detail) =>
            toast_overlay.add_toast (new Adw.Toast ("Message sent, but it could not be filed in Sent.")));
        var mailbox_pane = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        var sidebar_column = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        sidebar.hexpand = true; sidebar.vexpand = true;
        sidebar_column.hexpand = true;
        sidebar_column.append (sidebar);
        sidebar_column.append (build_sync_status ());
        mailbox_pane.append (sidebar_column);
        var mailbox_handle = new PaneResizeHandle ("Resize mailbox and message panes"); mailbox_pane.append (mailbox_handle);
        mailbox_handle.bind_drag_to (mailbox_pane);
        mailbox_handle.drag_started.connect ((pointer_x) => {
            resize_start_width = mailbox_pane.get_width ();
            resize_start_pointer_x = pointer_x;
        });
        mailbox_handle.dragged.connect ((pointer_x) =>
            set_mailbox_pane_width (resize_start_width + pointer_x - resize_start_pointer_x));
        mailbox_handle.drag_finished.connect (() => settings.mailbox_pane_width = mailbox_pane_width);
        mailbox_split.sidebar = mailbox_pane; mailbox_split.sidebar_width_unit = Adw.LengthUnit.PX;
        mailbox_split.min_sidebar_width = 190; mailbox_split.max_sidebar_width = 560;
        mailbox_split.sidebar_width_fraction = mailbox_pane_width / 1320.0;
        message_pane = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        message_pane.add_css_class ("message-pane");
        message_pane.hexpand = true; message_pane.vexpand = true;
        message_pane.overflow = Gtk.Overflow.HIDDEN;
        message_list.hexpand = true; message_list.vexpand = true;
        message_pane.append (message_list);
        message_split.hexpand = true; message_split.vexpand = true;
        message_split.set_size_request (0, -1);
        message_split.overflow = Gtk.Overflow.HIDDEN;
        // Match the three-column mail layout: the message list is flexible,
        // and the reader resizes into the remaining space. Its content is
        // responsive, so the divider can move to roughly 75% of the workspace
        // without pushing anything past the application's right edge.
        message_split.resize_start_child = true; message_split.resize_end_child = true;
        message_split.shrink_start_child = true; message_split.shrink_end_child = true;
        message_pane.set_size_request (280, -1);
        message_split.start_child = message_pane;
        content_stack.hexpand = true; content_stack.vexpand = true;
        content_stack.overflow = Gtk.Overflow.HIDDEN;
        content_stack.transition_type = Gtk.StackTransitionType.NONE;
        content_stack.add_named (reader, "reader");
        content_stack.visible_child_name = "reader";
        content_page = new Adw.NavigationPage (content_stack, "Message");
        // The reader must not contribute an oversized natural width to the
        // split. Its usable minimum is enforced when the divider is moved.
        content_page.hexpand = true; content_page.vexpand = true;
        content_page.set_size_request (0, -1);
        content_page.overflow = Gtk.Overflow.HIDDEN;
        message_split.end_child = content_page;
        message_split.position = (int) message_pane_width;
        message_split.notify["width"].connect (() => {
            clamp_message_split_position ();
        });
        message_split.notify["position"].connect (() => {
            clamp_message_split_position ();
            message_pane_width = message_split.position;
        });
        mailbox_split.content = message_split; toolbar.set_content (mailbox_split);
        mailbox_split.show_sidebar = settings.sidebar_visible;
        var mail_overlay = new Gtk.Overlay ();
        mail_overlay.overflow = Gtk.Overflow.HIDDEN;
        mail_overlay.child = toolbar;
        toast_overlay.overflow = Gtk.Overflow.HIDDEN;
        toast_overlay.child = mail_overlay; content = toast_overlay;
        restore_pane_widths_after_layout ();
        Idle.add (() => {
            select_preferred_mailbox ();
            if (selected_message == null) show_reader_empty_state ();
            return Source.REMOVE;
        });
        close_request.connect (() => { persist_layout (); return false; });
        // Request the persisted state before present(). Queuing this as idle work
        // allowed a simultaneous startup sync to monopolize the main thread first.
        if (!qa_layout && settings.window_maximized) maximize ();
        repository.changed.connect (() => {
            DebugTrace.log ("repository", "changed marking_read=%s pending_before=%s".printf (
                marking_selected_message_read.to_string (),
                repository_refresh_pending.to_string ()));
            // The selected row is already updated in place before this
            // idempotent read-state notification arrives.
            if (marking_selected_message_read) {
                // Keep the selected message/list snapshot in place, but the
                // sidebar still needs the new unread totals immediately.
                sidebar.reload (false);
                return;
            }
            repository_refresh_pending = true;
            queue_repository_refresh ();
            DebugTrace.log ("repository", "changed handled pending_after=%s".printf (repository_refresh_pending.to_string ()));
        });
        if (sync_service != null) {
            sync_service.progress_changed.connect ((account_id, fraction, detail) => {
                if (!sync_cancel_requested) sync_cancel_button.sensitive = true;
                queue_sync_progress (fraction, detail);
            });
            sync_service.pass_completed.connect ((account_id) => {
                repository.reload ();
            });
            // Batches are committed immediately, but rebuilding every message
            // row after each database batch multiplies work on large
            // imports. Reload once after each bounded backend session instead.
            sync_service.synchronized.connect ((account_id) => {
                repository.reload (); refresh_button.sensitive = true;
                sync_cancel_requested = false; sync_cancel_button.sensitive = false;
                finish_sync_progress ("Mail is up to date");
            });
            sync_service.failed.connect ((account_id, error) => {
                refresh_button.sensitive = true;
                sync_cancel_requested = false; sync_cancel_button.sensitive = false;
                finish_sync_progress (error.title);
                if (selected_message == null) reader.show_error (error);
                toast_overlay.add_toast (new Adw.Toast ("%s — %s".printf (error.title, error.suggestion)));
            });
            sync_service.cancelled.connect ((account_id) => {
                repository.reload (); refresh_button.sensitive = true;
                sync_cancel_requested = false; sync_cancel_button.sensitive = false;
                finish_sync_progress ("Mail check cancelled");
            });
        }
        install_adaptive_layout ();
        install_actions ();
        var initial = message_list.first_message ();
        if (initial != null) {
            selected_message = repository.find_message (initial.id) ?? initial;
            display_message (selected_message); update_action_sensitivity ();
        }
        string? qa_message = Environment.get_variable ("MAILFICIENT_QA_MESSAGE");
        if (qa_message != null) Timeout.add (350, () => { message_list.select_message (qa_message); return Source.REMOVE; });
        if (Environment.get_variable ("MAILFICIENT_QA_PRESERVE_SELECTION") == "1") Timeout.add (900, () => {
            repository.reload ();
            return Source.REMOVE;
        });
        if (Environment.get_variable ("MAILFICIENT_QA_ASSERT_READER_TOP") == "1") Timeout.add (3500, () => {
            if (!reader.is_scrolled_to_top ())
                critical ("Reader did not remain scrolled to the top after HTML layout");
            return Source.REMOVE;
        });
        if (Environment.get_variable ("MAILFICIENT_QA_ASSERT_READER_STABLE") == "1")
            Timeout.add (2000, () => {
                reader.qa_assert_scroll_stable (1800);
                return Source.REMOVE;
            });
        string? qa_print_pdf = Environment.get_variable ("MAILFICIENT_QA_PRINT_PDF");
        if (qa_print_pdf != null && qa_print_pdf != "")
            Timeout.add (2500, () => {
                qa_export_rendered_print.begin (qa_print_pdf);
                return Source.REMOVE;
            });
        string? qa_search = Environment.get_variable ("MAILFICIENT_QA_SEARCH");
        if (qa_search != null && qa_search != "") Idle.add (() => { search.text = qa_search; return Source.REMOVE; });
        string? qa_mailbox = Environment.get_variable ("MAILFICIENT_QA_MAILBOX");
        if (qa_mailbox != null && qa_mailbox != "") Idle.add (() => { sidebar.select_mailbox (qa_mailbox); return Source.REMOVE; });
        if (Environment.get_variable ("MAILFICIENT_QA_HIDE_SIDEBAR") == "1") Idle.add (() => {
            set_mailbox_sidebar_visible (false);
            return Source.REMOVE;
        });
        if (Environment.get_variable ("MAILFICIENT_QA_SYNC_PROGRESS") == "1") Idle.add (() => {
            show_sync_progress (0.42, "Downloading 38 of 90 — Inbox");
            return Source.REMOVE;
        });
        if (Environment.get_variable ("MAILFICIENT_QA_TOOLBAR_CUSTOMIZATION") == "1") Timeout.add (500, () => {
            show_toolbar_customization ();
            return Source.REMOVE;
        });
        if (Environment.get_variable ("MAILFICIENT_QA_ERROR") == "1") Idle.add (() => {
            reader.show_error (UserFacingError.from_error (new MailError.PARTIAL_SYNC (
                "Archive: IMAP server returned a temporary message download failure.")));
            return Source.REMOVE;
        });
        if (Environment.get_variable ("MAILFICIENT_QA_RATE_LIMIT") == "1") Idle.add (() => {
            reader.show_error (UserFacingError.from_error (new MailError.RATE_LIMITED (
                "Demo diagnostic: IMAP server returned too many requests")));
            return Source.REMOVE;
        });
        if (Environment.get_variable ("MAILFICIENT_QA_DRAFTS") == "1") Idle.add (() => {
            foreach (var mailbox in repository.list_mailboxes ())
                if (mailbox.id == CachedMailRepository.LOCAL_DRAFTS_ID || mailbox.id == "drafts") {
                    message_list.show_mailbox (mailbox);
                    var first = message_list.first_message (); if (first != null) message_list.activate_message (first.id);
                    break;
                }
            return Source.REMOVE;
        });
        if (Environment.get_variable ("MAILFICIENT_QA_OUTBOX") == "1") Idle.add (() => {
            foreach (var mailbox in repository.list_mailboxes ())
                if (mailbox.id == CachedMailRepository.LOCAL_OUTBOX_ID) { message_list.show_mailbox (mailbox); break; }
            return Source.REMOVE;
        });
    }

    private static bool is_local_draft (string id) {
        return id.has_prefix (CachedMailRepository.DRAFT_PREFIX) || id.has_prefix (CachedMailRepository.OUTBOX_PREFIX);
    }

    private void set_mailbox_pane_width (double requested) {
        mailbox_pane_width = double.max (190, double.min (560, requested));
        int available = mailbox_split.get_width ();
        if (available > 0)
            mailbox_split.sidebar_width_fraction = mailbox_pane_width / available;
    }

    private void set_message_pane_width (double requested) {
        message_pane_width = double.max (280, double.min (1400, requested));
        if (message_split.get_width () > 0) {
            message_split.position = (int) message_pane_width;
            clamp_message_split_position ();
        }
    }

    private void clamp_message_split_position () {
        int split_width = message_split.get_width ();
        if (split_width <= 0) return;

        // Use both the split allocation and the window allocation. The latter
        // protects against an oversized natural request from a rendered email
        // making the reader extend beyond the application's right edge.
        int available = split_width;
        int window_width = get_width ();
        if (window_width > 0 && mailbox_split.show_sidebar)
            available = int.min (available, window_width - (int) mailbox_pane_width);
        int maximum = int.min (available - READER_MIN_WIDTH, (available * 3) / 4);
        if (maximum < 280) maximum = 280;
        int bounded = int.max (280, int.min (message_split.position, maximum));
        if (bounded != message_split.position) message_split.position = bounded;
        reader.set_viewport_width (split_width - bounded);
    }

    private void restore_pane_widths_after_layout () {
        int stage = 0;
        add_tick_callback ((widget, frame_clock) => {
            // Split-view fractions depend on the allocated width. Applying them
            // from an idle callback races the first Libadwaita layout pass and
            // can be overwritten by its default 25% fraction.
            if (mailbox_split.get_width () <= 0) return Source.CONTINUE;
            if (stage == 0) {
                set_mailbox_pane_width (mailbox_pane_width);
                stage++;
                return Source.CONTINUE;
            }
            if (message_split.get_width () <= 0) return Source.CONTINUE;
            set_message_pane_width (message_pane_width);
            if (stage++ < 2) return Source.CONTINUE;
            // Reapply once after both split views have reacted, making the
            // second divider exact even when the first divider also moved.
            set_mailbox_pane_width (mailbox_pane_width);
            set_message_pane_width (message_pane_width);
            return Source.REMOVE;
        });
    }

    private void set_message_content_visible (bool visible) {
        var content = message_split.end_child;
        if (content != null) content.visible = visible;
    }

    public void persist_layout () {
        if (qa_layout) return;
        if (last_selected_mailbox_id != "") settings.selected_mailbox_id = last_selected_mailbox_id;
        settings.mailbox_pane_width = mailbox_pane_width;
        settings.message_pane_width = message_pane_width;
        settings.save_window_state (get_width (), get_height (), is_maximized ());
    }

    private async void prompt_create_folder (AccountSettings account, Mailbox? parent) {
        var entry = new Adw.EntryRow (); entry.title = "Folder name";
        var dialog = new Adw.AlertDialog (parent == null ? "New Mailbox" : "New Subfolder",
            parent == null ? "Create a mailbox in %s.".printf (account.display_name) :
                "Create a mailbox inside %s.".printf (parent.name));
        dialog.extra_child = entry; dialog.add_response ("cancel", "Cancel"); dialog.add_response ("create", "Create");
        dialog.default_response = "create"; dialog.close_response = "cancel";
        dialog.set_response_appearance ("create", Adw.ResponseAppearance.SUGGESTED);
        if ((yield dialog.choose (this, null)) != "create") return;
        try {
            yield folder_service.create (account.id, parent == null ? "" : parent.remote_name, entry.text);
            repository.reload (); toast_overlay.add_toast (new Adw.Toast ("Mailbox created"));
        } catch (Error error) { show_operation_error (error); }
    }

    private async void prompt_rename_folder (Mailbox mailbox) {
        var entry = new Adw.EntryRow (); entry.title = "Mailbox name"; entry.text = mailbox.name;
        var dialog = new Adw.AlertDialog ("Rename Mailbox", "Choose a new name for %s.".printf (mailbox.name));
        dialog.extra_child = entry; dialog.add_response ("cancel", "Cancel"); dialog.add_response ("rename", "Rename");
        dialog.default_response = "rename"; dialog.close_response = "cancel";
        if ((yield dialog.choose (this, null)) != "rename") return;
        try {
            yield folder_service.rename (mailbox, entry.text);
            repository.reload (); toast_overlay.add_toast (new Adw.Toast ("Mailbox renamed"));
        } catch (Error error) { show_operation_error (error); }
    }

    private async void prompt_delete_folder (Mailbox mailbox) {
        var dialog = new Adw.AlertDialog ("Delete %s?".printf (mailbox.name),
            "This deletes the mailbox on the mail server and may delete the messages it contains. This cannot be undone in Mailficient.");
        dialog.add_response ("cancel", "Cancel"); dialog.add_response ("delete", "Delete Mailbox");
        dialog.default_response = "cancel"; dialog.close_response = "cancel";
        dialog.set_response_appearance ("delete", Adw.ResponseAppearance.DESTRUCTIVE);
        if ((yield dialog.choose (this, null)) != "delete") return;
        try {
            yield folder_service.delete (mailbox);
            repository.reload (); reader.show_empty (); toast_overlay.add_toast (new Adw.Toast ("Mailbox deleted"));
        } catch (Error error) { show_operation_error (error); }
    }

    private async void prompt_empty_role (MailboxRole role) {
        string name = role == MailboxRole.TRASH ? "Trash" : "Junk";
        var dialog = new Adw.AlertDialog ("Empty %s?".printf (name),
            "Every message in %s will be permanently deleted from all configured accounts. This cannot be undone.".printf (name));
        dialog.add_response ("cancel", "Cancel"); dialog.add_response ("empty", "Empty %s".printf (name));
        dialog.default_response = "cancel"; dialog.close_response = "cancel";
        dialog.set_response_appearance ("empty", Adw.ResponseAppearance.DESTRUCTIVE);
        if ((yield dialog.choose (this, null)) != "empty") return;
        try {
            repository.empty_role (role); selected_message = null; reader.show_empty ();
            toast_overlay.add_toast (new Adw.Toast ("%s will be emptied on the mail server".printf (name)));
        } catch (Error error) { show_operation_error (error); }
    }

    private async void prompt_empty_mailbox (Mailbox mailbox) {
        string name = mailbox.role == MailboxRole.TRASH ? "Trash" : "Junk";
        AccountSettings? account = null;
        try { account = cache.find_account (mailbox.account_id); }
        catch (Error error) { show_operation_error (error); return; }
        string account_name = account == null ? "this account" : account.display_name;
        var dialog = new Adw.AlertDialog ("Empty %s?".printf (name),
            "Every message in %s for %s will be permanently deleted. This cannot be undone.".printf (
                name, account_name));
        dialog.add_response ("cancel", "Cancel"); dialog.add_response ("empty", "Empty %s".printf (name));
        dialog.default_response = "cancel"; dialog.close_response = "cancel";
        dialog.set_response_appearance ("empty", Adw.ResponseAppearance.DESTRUCTIVE);
        if ((yield dialog.choose (this, null)) != "empty") return;
        try {
            repository.empty_mailbox (mailbox); selected_message = null; reader.show_empty ();
            toast_overlay.add_toast (new Adw.Toast ("%s will be emptied".printf (name)));
        } catch (Error error) { show_operation_error (error); }
    }

    private async void prompt_permanent_delete (string next_message_id) {
        var messages = action_messages (); if (messages.size == 0) return;
        string subject = messages.size == 1 ? "Delete this message permanently?" :
            "Delete %d messages permanently?".printf (messages.size);
        var dialog = new Adw.AlertDialog (subject,
            "Permanent deletion removes the selected mail from the server and cannot be undone.");
        dialog.add_response ("cancel", "Cancel"); dialog.add_response ("delete", "Delete Permanently");
        dialog.default_response = "cancel"; dialog.close_response = "cancel";
        dialog.set_response_appearance ("delete", Adw.ResponseAppearance.DESTRUCTIVE);
        if ((yield dialog.choose (this, null)) != "delete") return;
        int completed = 0;
        foreach (var message in messages) {
            try { repository.permanently_delete (message.id); completed++; }
            catch (Error error) { show_operation_error (error); }
        }
        select_after_removal (next_message_id, completed);
        toast_overlay.add_toast (new Adw.Toast (completed == 1 ? "Message permanently deleted" :
            "%d messages permanently deleted".printf (completed)));
    }

    private void show_operation_error (Error error) {
        var friendly = UserFacingError.from_error (error);
        toast_overlay.add_toast (new Adw.Toast ("%s — %s".printf (friendly.title, friendly.suggestion)));
    }

    private void account_changed (AccountSettings? account) {
        try {
            cache.clear_demo_data ();
        } catch (Error error) {
            warning ("Could not refresh local account mode: %s", error.message);
        }
        repository.reload ();
        try {
            if (cache.list_accounts ().size == 0) {
                selected_message = null;
                show_reader_empty_state ();
            }
            else if (account != null) reader.show_loading ();
        } catch (Error error) { warning ("Could not inspect accounts: %s", error.message); }
        if (account != null && sync_service != null) {
            sync_service.resume_account (account.id);
            sync_service.sync_account.begin (account);
        }
    }

    private Gtk.Widget build_header () {
        var header = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
        header.add_css_class ("mail-header-bar");
        message_back.tooltip_text = "Back to message list";
        Accessibility.label (message_back, "Back to message list");
        message_back.clicked.connect (() => set_message_content_visible (false));
        message_back.visible = false;
        header.append (message_back);

        search.placeholder_text = "Search Mail";
        search.set_size_request (240, -1);
        search.add_css_class ("apple-toolbar-search");
        Accessibility.label (search, "Search mail");
        search.search_changed.connect (() => message_list.search (search.text));

        var sort_menu = new Menu (); sort_menu.append ("Newest First", "win.sort::newest");
        sort_menu.append ("Oldest First", "win.sort::oldest"); sort_menu.append ("Sender", "win.sort::sender");
        sort_menu.append ("Subject", "win.sort::subject"); sort_menu.append ("Unread First", "win.sort::unread");
        sort_menu.append ("Flagged First", "win.sort::flagged");
        sort_button.child = new Gtk.Image.from_icon_name ("view-sort-descending-symbolic");
        sort_button.set_size_request (44, 38);
        sort_button.always_show_arrow = false;
        sort_button.tooltip_text = "Sort messages — " + sort_label_for (settings.message_sort);
        sort_button.menu_model = sort_menu;
        Accessibility.label (sort_button, "Sort messages");

        var more_menu = new Menu (); more_menu.append ("Archive", "win.archive"); more_menu.append ("Move to Trash", "win.trash");
        more_menu.append ("Junk or Not Junk", "win.junk"); more_menu.append ("Flag or Unflag", "win.flag");
        more_toggle_read_item = new MenuItem ("Mark as Read", "win.toggle-read");
        more_menu.append_item (more_toggle_read_item);
        more_menu.append ("Move or Copy…", "win.show-move");
        more_button.icon_name = "view-more-symbolic"; more_button.tooltip_text = "More message actions"; more_button.menu_model = more_menu;
        Accessibility.label (more_button, "More message actions");

        customizable_toolbar.hexpand = true;
        customizable_toolbar.halign = Gtk.Align.FILL;
        customizable_toolbar.set_size_request (0, -1);
        customizable_toolbar.add_css_class ("apple-toolbar");
        header.append (customizable_toolbar);

        var app_menu = new Menu ();
        var mail_menu = new Menu ();
        mail_menu.append ("New Message", "win.compose");
        mail_menu.append ("Get Mail", "win.refresh");
        app_menu.append_section ("Mail", mail_menu);

        var view_menu = new Menu ();
        var sort_app_menu = new Menu ();
        sort_app_menu.append ("Newest First", "win.sort::newest");
        sort_app_menu.append ("Oldest First", "win.sort::oldest");
        sort_app_menu.append ("Sender", "win.sort::sender");
        sort_app_menu.append ("Subject", "win.sort::subject");
        sort_app_menu.append ("Unread First", "win.sort::unread");
        sort_app_menu.append ("Flagged First", "win.sort::flagged");
        view_menu.append_submenu ("Sort Messages", sort_app_menu);
        view_menu.append ("Group Related Messages", "win.group-messages");
        var display_menu = new Menu ();
        display_menu.append ("Always Show Images", "win.always-show-images");
        display_menu.append ("Display Full HTML", "win.full-html-formatting");
        view_menu.append_submenu ("Message Display", display_menu);
        app_menu.append_section ("View", view_menu);

        var accounts_menu = new Menu ();
        accounts_menu.append ("Manage Accounts…", "win.accounts");
        app_menu.append_section ("Accounts", accounts_menu);

        var settings_menu = new Menu ();
        settings_menu.append ("Preferences…", "win.preferences");
        settings_menu.append ("Customize Toolbar…", "win.customize-toolbar");
        app_menu.append_section ("Settings", settings_menu);

        var help_menu = new Menu ();
        help_menu.append ("Keyboard Shortcuts", "win.shortcuts");
        help_menu.append ("About Mailficient", "win.about");
        app_menu.append_section ("Help", help_menu);
        var app_menu_button = new Gtk.MenuButton ();
        app_menu_button.child = new Gtk.Image.from_icon_name ("open-menu-symbolic");
        app_menu_button.set_size_request (30, 30);
        app_menu_button.always_show_arrow = false;
        app_menu_button.add_css_class ("app-menu-button");
        app_menu_button.valign = Gtk.Align.CENTER;
        app_menu_button.tooltip_text = "Mailficient menu"; app_menu_button.menu_model = app_menu; header.append (app_menu_button);
        Accessibility.label (app_menu_button, "Mailficient menu");
        var window_controls = new Gtk.WindowControls (Gtk.PackType.END);
        header.append (window_controls);

        var toolbar_menu = new Menu ();
        toolbar_menu.append ("Customize Toolbar…", "win.customize-toolbar");
        toolbar_context_menu = new Gtk.PopoverMenu.from_model (toolbar_menu);
        toolbar_context_menu.set_parent (customizable_toolbar);
        toolbar_context_menu.has_arrow = false;

        var secondary_click = new Gtk.GestureClick ();
        secondary_click.button = Gdk.BUTTON_SECONDARY;
        // Toolbar buttons have their own event controllers. Capture the
        // secondary click before a child can consume it so right-clicking a
        // button works just like right-clicking empty toolbar space.
        secondary_click.propagation_phase = Gtk.PropagationPhase.CAPTURE;
        secondary_click.pressed.connect ((presses, x, y) => {
            secondary_click.set_state (Gtk.EventSequenceState.CLAIMED);
            toolbar_context_menu.pointing_to = { (int) x, (int) y, 1, 1 };
            toolbar_context_menu.popup ();
        });
        customizable_toolbar.add_controller (secondary_click);
        rebuild_toolbar ();
        var window_handle = new Gtk.WindowHandle ();
        window_handle.child = header;
        return window_handle;
    }

    private Gtk.Button make_toolbar_button (string id, string action_name) {
        var button = new Gtk.Button.from_icon_name (ToolbarLayout.icon_name (id));
        if (action_name != "") button.action_name = action_name;
        button.tooltip_text = ToolbarLayout.label (id);
        button.add_css_class ("apple-toolbar-button");
        if (id == "compose") button.add_css_class ("compose-toolbar-button");
        Accessibility.label (button, ToolbarLayout.label (id));
        return button;
    }

    private Gtk.Box make_toolbar_group (string[] ids, string[] actions, string label) {
        var group = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        group.add_css_class ("linked");
        group.add_css_class ("apple-toolbar-group");
        group.tooltip_text = label;
        for (int i = 0; i < ids.length; i++) {
            var button = make_toolbar_button (ids[i], actions[i]);
            switch (ids[i]) {
            case "reply": reply_button = button; break;
            case "reply-all": reply_all_button = button; break;
            case "forward": forward_button = button; break;
            case "archive": archive_button = button; break;
            case "trash": delete_button = button; break;
            case "junk": junk_button = button; break;
            default: break;
            }
            group.append (button);
        }
        return group;
    }

    private bool overflows_in_compact_toolbar (string id) {
        switch (id) {
        case "mail-actions":
        case "archive":
        case "trash":
        case "junk":
        case "move":
        case "flag":
        case "toggle-read":
        case "labels":
        case "snooze":
        case "print":
            return true;
        default:
            return false;
        }
    }

    private bool belongs_in_action_cluster (string id) {
        switch (id) {
        case "reply-group":
        case "mail-actions":
        case "reply":
        case "reply-all":
        case "forward":
        case "archive":
        case "trash":
        case "junk":
        case "move":
        case "flag":
        case "toggle-read":
        case "labels":
        case "snooze":
        case "print":
            return true;
        default:
            return false;
        }
    }

    private void rebuild_toolbar () {
        Gtk.Widget? child = customizable_toolbar.get_first_child ();
        while (child != null) {
            Gtk.Widget? next = child.get_next_sibling ();
            if (child != toolbar_context_menu)
                customizable_toolbar.remove (child);
            child = next;
        }

        var layout = ToolbarLayout.parse (settings.toolbar_layout);
        if (layout.size == 0) layout = ToolbarLayout.parse (ToolbarLayout.DEFAULT_LAYOUT);
        if (compact_toolbar) {
            var compact_sidebar = toolbar_widget_for ("sidebar");
            if (compact_sidebar != null) customizable_toolbar.append (compact_sidebar);
        }
        bool added_overflow = false;
        Gtk.Box? action_cluster = null;
        foreach (var id in layout) {
            // The adaptive layout always supplies its own mailbox control.
            if (compact_toolbar && id == "sidebar") continue;
            if (compact_toolbar && overflows_in_compact_toolbar (id)) {
                action_cluster = null;
                if (!added_overflow) {
                    more_button.add_css_class ("apple-toolbar-button");
                    customizable_toolbar.append (more_button);
                    added_overflow = true;
                }
                continue;
            }
            Gtk.Widget? item = toolbar_widget_for (id);
            if (item == null) continue;
            if (belongs_in_action_cluster (id)) {
                if (action_cluster == null) {
                    action_cluster = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
                    action_cluster.add_css_class ("toolbar-action-cluster");
                    customizable_toolbar.append (action_cluster);
                }
                item.add_css_class ("toolbar-cluster-segment");
                action_cluster.append (item);
            } else {
                action_cluster = null;
                customizable_toolbar.append (item);
            }
        }
        // The search field is the flexible part of the toolbar. Keeping a
        // minimum width preserves usability while allowing the toolbar to
        // consume extra window width instead of clipping its right side.
        search.hexpand = !compact_toolbar;
        search.halign = Gtk.Align.FILL;
        search.set_size_request (compact_toolbar ? 150 : 240, -1);
        update_action_sensitivity ();
    }

    private Gtk.Widget? toolbar_widget_for (string id) {
        switch (id) {
        case "sidebar":
            mailbox_toggle = make_toolbar_button (id, "");
            mailbox_toggle.sensitive = true;
            mailbox_toggle.clicked.connect (() => set_mailbox_sidebar_visible (!mailbox_split.show_sidebar));
            mailbox_toggle.tooltip_text = "Show or hide mailboxes";
            return mailbox_toggle;
        case "refresh":
            refresh_button = make_toolbar_button (id, "win.refresh");
            refresh_button.tooltip_text = "Get Mail (F9)";
            return refresh_button;
        case "compose": return make_toolbar_button (id, "win.compose");
        case "reply-group":
            return make_toolbar_group (
                { "reply", "reply-all", "forward" },
                { "win.reply", "win.reply-all", "win.forward" },
                ToolbarLayout.label (id));
        case "mail-actions":
            return make_toolbar_group (
                { "trash", "archive", "junk" },
                { "win.trash", "win.archive", "win.junk" },
                ToolbarLayout.label (id));
        case "reply": reply_button = make_toolbar_button (id, "win.reply"); return reply_button;
        case "reply-all": reply_all_button = make_toolbar_button (id, "win.reply-all"); return reply_all_button;
        case "forward": forward_button = make_toolbar_button (id, "win.forward"); return forward_button;
        case "archive": archive_button = make_toolbar_button (id, "win.archive"); return archive_button;
        case "trash": delete_button = make_toolbar_button (id, "win.trash"); return delete_button;
        case "junk": junk_button = make_toolbar_button (id, "win.junk"); return junk_button;
        case "flag": return make_flag_control ();
        case "toggle-read": toggle_read_button = make_toolbar_button (id, "win.toggle-read"); return toggle_read_button;
        case "labels": return make_toolbar_button (id, "win.labels");
        case "snooze": return make_toolbar_button (id, "win.snooze");
        case "print": return make_toolbar_button (id, "win.print-message");
        case "move":
            move_button = new Gtk.MenuButton ();
            move_button.icon_name = ToolbarLayout.icon_name (id);
            move_button.tooltip_text = "Move or copy to mailbox";
            move_button.add_css_class ("apple-toolbar-button");
            Accessibility.label (move_button, "Move or copy to mailbox");
            rebuild_move_menu ();
            return move_button;
        case "search": return search;
        case "sort":
            sort_button.add_css_class ("apple-toolbar-button");
            sort_button.add_css_class ("sort-toolbar-button");
            return sort_button;
        case "space":
            var space = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
            space.set_size_request (18, -1);
            return space;
        case "flex":
            var flexible = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
            flexible.hexpand = true;
            return flexible;
        default: return null;
        }
    }

    private Gtk.Widget make_flag_control () {
        var control = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        control.add_css_class ("linked");
        control.add_css_class ("flag-control");

        flag_button = make_toolbar_button ("flag", "win.flag");
        flag_button.tooltip_text = "Toggle flag";
        control.append (flag_button);

        flag_color_button = new Gtk.MenuButton ();
        flag_color_button.icon_name = "pan-down-symbolic";
        flag_color_button.tooltip_text = "Choose flag color";
        flag_color_button.add_css_class ("apple-toolbar-button");
        Accessibility.label (flag_color_button, "Choose flag color");

        var popover = new Gtk.Popover ();
        popover.has_arrow = false;
        var menu = new Gtk.Box (Gtk.Orientation.VERTICAL, 1);
        menu.add_css_class ("flag-color-menu");
        menu.append (make_flag_color_row ("orange", "Orange", popover));
        menu.append (make_flag_color_row ("red", "Red", popover));
        menu.append (make_flag_color_row ("purple", "Purple", popover));
        menu.append (make_flag_color_row ("blue", "Blue", popover));
        menu.append (make_flag_color_row ("yellow", "Yellow", popover));
        menu.append (make_flag_color_row ("green", "Green", popover));
        menu.append (make_flag_color_row ("gray", "Gray", popover));
        menu.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));

        var clear = new Gtk.Button.with_label ("Clear Flag");
        clear.halign = Gtk.Align.FILL;
        clear.clicked.connect (() => {
            popover.popdown ();
            clear_selected_flags ();
        });
        menu.append (clear);
        var toggle = new Gtk.Button.with_label ("Toggle Flag");
        toggle.halign = Gtk.Align.FILL;
        toggle.clicked.connect (() => {
            popover.popdown ();
            toggle_selected_flag ();
        });
        menu.append (toggle);
        popover.child = menu;
        flag_color_button.popover = popover;
        control.append (flag_color_button);
        update_flag_button_color ();
        return control;
    }

    private Gtk.Button make_flag_color_row (string color, string label, Gtk.Popover popover) {
        var row = new Gtk.Button ();
        var content = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10);
        var icon = new Gtk.Image.from_icon_name ("mailficient-flag-symbolic");
        icon.add_css_class ("flag-" + color);
        var text = new Gtk.Label (label);
        text.xalign = 0;
        text.hexpand = true;
        content.append (icon);
        content.append (text);
        row.child = content;
        row.clicked.connect (() => {
            popover.popdown ();
            set_selected_flag_color (color);
        });
        Accessibility.label (row, "Flag %s".printf (label.down ()));
        return row;
    }

    private void show_toolbar_customization () {
        var dialog = new ToolbarCustomizationDialog (settings.toolbar_layout);
        dialog.layout_changed.connect ((layout) => settings.toolbar_layout = layout);
        dialog.present (this);
    }

    private void install_adaptive_layout () {
        var breakpoint = new Adw.Breakpoint (
            new Adw.BreakpointCondition.length (
                Adw.BreakpointConditionLengthType.MAX_WIDTH, 1300, Adw.LengthUnit.PX));
        breakpoint.apply.connect (() => {
            apply_compact_layout ();
        });
        breakpoint.unapply.connect (() => {
            apply_wide_layout ();
        });
        add_breakpoint (breakpoint);

        // A window restored maximized can be allocated before the breakpoint
        // gets its first size evaluation. Keep the toolbar in sync with the
        // actual window width so it does not remain in its compact layout
        // until the user performs a resize.
        notify["width"].connect (() => sync_adaptive_toolbar_layout ());
        add_tick_callback ((widget, frame_clock) => {
            if (get_width () <= 0) return Source.CONTINUE;
            sync_adaptive_toolbar_layout ();
            return Source.REMOVE;
        });
    }

    private void sync_adaptive_toolbar_layout () {
        if (get_width () <= 0) return;
        if (get_width () <= 1300) apply_compact_layout ();
        else apply_wide_layout ();
    }

    private void apply_compact_layout () {
        if (compact_toolbar) return;
        mailbox_split.collapsed = false; mailbox_split.show_sidebar = settings.sidebar_visible;
        set_message_content_visible (true);
        message_back.visible = false;
        compact_toolbar = true;
        rebuild_toolbar ();
    }

    private void apply_wide_layout () {
        if (!compact_toolbar) return;
        mailbox_split.collapsed = false; mailbox_split.show_sidebar = settings.sidebar_visible;
        set_message_content_visible (true);
        message_back.visible = false;
        compact_toolbar = false;
        rebuild_toolbar ();
    }

    private void set_mailbox_sidebar_visible (bool visible) {
        settings.sidebar_visible = visible;
        mailbox_split.show_sidebar = visible;
    }

    private void install_actions () {
        var compose = new SimpleAction ("compose", null); compose.activate.connect (() => open_compose ()); add_action (compose);
        var preferences = new SimpleAction ("preferences", null); preferences.activate.connect (() => show_preferences ()); add_action (preferences);
        var customize_toolbar = new SimpleAction ("customize-toolbar", null);
        customize_toolbar.activate.connect (() => show_toolbar_customization ());
        add_action (customize_toolbar);
        group_messages_action = new SimpleAction.stateful (
            "group-messages", null, new Variant.boolean (settings.group_messages));
        group_messages_action.change_state.connect ((value) =>
            settings.group_messages = value.get_boolean ());
        add_action (group_messages_action);
        always_show_images_action = new SimpleAction.stateful (
            "always-show-images", null, new Variant.boolean (settings.always_show_images));
        always_show_images_action.change_state.connect ((value) =>
            settings.always_show_images = value.get_boolean ());
        add_action (always_show_images_action);
        full_html_formatting_action = new SimpleAction.stateful (
            "full-html-formatting", null, new Variant.boolean (settings.full_html_formatting));
        full_html_formatting_action.change_state.connect ((value) =>
            settings.full_html_formatting = value.get_boolean ());
        add_action (full_html_formatting_action);
        var accounts = new SimpleAction ("accounts", null); accounts.activate.connect (() => show_accounts ()); add_action (accounts);
        var shortcuts = new SimpleAction ("shortcuts", null); shortcuts.activate.connect (() => new ShortcutsDialog ().present (this)); add_action (shortcuts);
        var about = new SimpleAction ("about", null); about.activate.connect (() => show_about ()); add_action (about);
        var focus_search = new SimpleAction ("search", null); focus_search.activate.connect (() => search.grab_focus ()); add_action (focus_search);
        var zoom_in = new SimpleAction ("zoom-in", null);
        zoom_in.activate.connect (() => reader.zoom_in ());
        add_action (zoom_in);
        var zoom_out = new SimpleAction ("zoom-out", null);
        zoom_out.activate.connect (() => reader.zoom_out ());
        add_action (zoom_out);
        application.set_accels_for_action ("win.compose", { "<Control>n" });
        application.set_accels_for_action ("win.search", { "<Control>f" });
        application.set_accels_for_action ("win.zoom-in", { "<Control>plus", "<Control>equal", "<Control>KP_Add" });
        application.set_accels_for_action ("win.zoom-out", { "<Control>minus", "<Control>KP_Subtract" });
        var select_all = new SimpleAction ("select-all", null);
        select_all.activate.connect (() => message_list.select_all ()); add_action (select_all);
        application.set_accels_for_action ("win.select-all", { "<Control>a" });
        var clear_selection = new SimpleAction ("clear-selection", null);
        clear_selection.activate.connect (() => message_list.clear_selection ()); add_action (clear_selection);
        application.set_accels_for_action ("win.clear-selection", { "Escape" });
        var refresh = new SimpleAction ("refresh", null); refresh.activate.connect (() => synchronize.begin ()); add_action (refresh);
        application.set_accels_for_action ("win.refresh", { "F9" });
        var archive = new SimpleAction ("archive", null); archive.activate.connect (() => move_selected (MailboxRole.ARCHIVE)); add_action (archive);
        var trash = new SimpleAction ("trash", null); trash.activate.connect (() => move_selected (MailboxRole.TRASH)); add_action (trash);
        var junk = new SimpleAction ("junk", null); junk.activate.connect (classify_selected_junk); add_action (junk);
        var flag = new SimpleAction ("flag", null); flag.activate.connect (toggle_selected_flag); add_action (flag);
        var clear_flag = new SimpleAction ("clear-flag", null); clear_flag.activate.connect (clear_selected_flags); add_action (clear_flag);
        var set_flag_color = new SimpleAction ("set-flag-color", VariantType.STRING);
        set_flag_color.activate.connect ((parameter) => {
            if (parameter != null) set_selected_flag_color (parameter.get_string ());
        });
        add_action (set_flag_color);
        var toggle_read = new SimpleAction ("toggle-read", null); toggle_read.activate.connect (toggle_selected_read); add_action (toggle_read);
        var labels = new SimpleAction ("labels", null); labels.activate.connect (() => edit_selected_labels.begin ()); add_action (labels);
        var snooze = new SimpleAction ("snooze", null); snooze.activate.connect (() => snooze_selected.begin ()); add_action (snooze);
        var export_message = new SimpleAction ("export-message", null); export_message.activate.connect (() => export_selected_message.begin ()); add_action (export_message);
        var print_message = new SimpleAction ("print-message", null); print_message.activate.connect (() => print_selected_message.begin ()); add_action (print_message);
        var reply = new SimpleAction ("reply", null); reply.activate.connect (() => compose_response (ComposeMode.REPLY)); add_action (reply);
        var reply_all = new SimpleAction ("reply-all", null); reply_all.activate.connect (() => compose_response (ComposeMode.REPLY_ALL)); add_action (reply_all);
        var forward = new SimpleAction ("forward", null); forward.activate.connect (() => compose_response (ComposeMode.FORWARD)); add_action (forward);
        var next = new SimpleAction ("next-message", null); next.activate.connect (() => message_list.select_relative (1)); add_action (next);
        var previous = new SimpleAction ("previous-message", null); previous.activate.connect (() => message_list.select_relative (-1)); add_action (previous);
        var move_to = new SimpleAction ("move-to", VariantType.STRING); move_to.activate.connect ((parameter) => {
            if (parameter != null) transfer_selected_to (parameter.get_string (), false);
        }); add_action (move_to);
        var copy_to = new SimpleAction ("copy-to", VariantType.STRING); copy_to.activate.connect ((parameter) => {
            if (parameter != null) transfer_selected_to (parameter.get_string (), true);
        }); add_action (copy_to);
        var show_move = new SimpleAction ("show-move", null); show_move.activate.connect (() => move_button.popup ()); add_action (show_move);
        string initial_sort = settings.message_sort;
        var sort = new SimpleAction.stateful ("sort", VariantType.STRING, new Variant.string (initial_sort));
        message_list.set_sort (sort_mode_for (initial_sort));
        sort.change_state.connect ((value) => {
            string selected_sort = value.get_string ();
            sort.set_state (value);
            settings.message_sort = selected_sort;
            message_list.set_sort (sort_mode_for (selected_sort));
            sort_button.tooltip_text = "Sort messages — " + sort_label_for (selected_sort);
            Accessibility.label (sort_button, sort_button.tooltip_text);
        });
        add_action (sort);
        application.set_accels_for_action ("win.reply", { "<Control>r" });
        application.set_accels_for_action ("win.reply-all", { "<Control><Shift>r" });
        application.set_accels_for_action ("win.forward", { "<Control>l" });
        application.set_accels_for_action ("win.trash", { "Delete" });
        application.set_accels_for_action ("win.archive", { "<Control><Shift>a", "<Control>e" });
        application.set_accels_for_action ("win.flag", { "<Control><Shift>l" });
        application.set_accels_for_action ("win.toggle-read", { "<Control><Shift>u", "<Control>i" });
        application.set_accels_for_action ("win.next-message", { "<Alt>Down", "<Control>j" });
        application.set_accels_for_action ("win.previous-message", { "<Alt>Up", "<Control>k" });
        application.set_accels_for_action ("win.snooze", { "<Control>s" });
    }

    private static MessageSortMode sort_mode_for (string value) {
        switch (value) {
        case "oldest": return MessageSortMode.OLDEST;
        case "sender": return MessageSortMode.SENDER;
        case "subject": return MessageSortMode.SUBJECT;
        case "unread": return MessageSortMode.UNREAD_FIRST;
        case "flagged": return MessageSortMode.FLAGGED_FIRST;
        default: return MessageSortMode.NEWEST;
        }
    }

    private static string sort_label_for (string value) {
        switch (value) {
        case "oldest": return "Oldest First";
        case "sender": return "Sender";
        case "subject": return "Subject";
        case "unread": return "Unread First";
        case "flagged": return "Flagged First";
        default: return "Newest First";
        }
    }

    private async void synchronize () {
        if (sync_service == null) { message_list.refresh (); return; }
        refresh_button.sensitive = false; refresh_button.tooltip_text = "Getting Mail…";
        sync_cancel_requested = false; sync_cancel_button.sensitive = true;
        show_sync_progress (0, "Checking for new mail…");
        var spinner = new Gtk.Spinner (); spinner.spinning = true;
        refresh_button.child = spinner;
        yield sync_service.sync_all ();
        refresh_button.child = null; refresh_button.icon_name = "view-refresh-symbolic";
        refresh_button.tooltip_text = "Get Mail (F9)"; refresh_button.sensitive = true;
    }

    private Gtk.Widget build_sync_status () {
        var panel = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
        panel.add_css_class ("sync-status-dialog");
        sync_status_label.ellipsize = Pango.EllipsizeMode.END;
        sync_status_label.wrap = true;
        sync_status_label.wrap_mode = Pango.WrapMode.WORD_CHAR;
        sync_status_label.lines = 2;
        sync_status_label.xalign = 0; sync_status_label.hexpand = true;
        var heading = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 4);
        sync_progress_bar.hexpand = true;
        sync_progress_bar.show_text = false;
        Accessibility.label (sync_progress_bar, "Mail download progress");
        sync_cancel_button.sensitive = false;
        sync_cancel_button.tooltip_text = "Cancel mail check";
        sync_cancel_button.add_css_class ("flat");
        sync_cancel_button.add_css_class ("circular");
        sync_cancel_button.clicked.connect (() => {
            if (sync_service == null || sync_cancel_requested) return;
            sync_cancel_requested = true; sync_cancel_button.sensitive = false;
            sync_status_label.label = "Cancelling mail check…";
            sync_service.cancel ();
        });
        Accessibility.label (sync_cancel_button, "Cancel checking and downloading mail");
        heading.append (sync_status_label);
        heading.append (sync_cancel_button);
        panel.append (heading);
        panel.append (sync_progress_bar);
        panel.margin_start = 12;
        panel.margin_end = 12;
        panel.margin_bottom = 12;
        sync_status_revealer.transition_type = Gtk.RevealerTransitionType.SLIDE_UP;
        sync_status_revealer.halign = Gtk.Align.FILL;
        sync_status_revealer.valign = Gtk.Align.END;
        sync_status_revealer.child = panel;
        return sync_status_revealer;
    }

    private void show_sync_progress (double fraction, string detail) {
        if (sync_status_hide_source != 0) {
            Source.remove (sync_status_hide_source); sync_status_hide_source = 0;
        }
        sync_status_label.label = detail == "" ? "Getting mail…" : detail;
        double bounded = double.max (0, double.min (1, fraction));
        sync_progress_bar.fraction = bounded;
        string progress_description = bounded > 0 ?
            "%d%% complete".printf ((int) (bounded * 100 + 0.5)) : "Starting";
        sync_progress_bar.tooltip_text = progress_description;
        Accessibility.label (sync_progress_bar, progress_description);
        sync_status_revealer.reveal_child = true;
    }

    private void queue_sync_progress (double fraction, string detail) {
        pending_sync_fraction = fraction;
        pending_sync_detail = detail;
        if (sync_progress_update_source != 0) return;
        sync_progress_update_source = Timeout.add (100, () => {
            sync_progress_update_source = 0;
            if (!sync_cancel_requested)
                show_sync_progress (pending_sync_fraction, pending_sync_detail);
            return Source.REMOVE;
        });
    }

    private void finish_sync_progress (string detail) {
        if (sync_progress_update_source != 0) {
            Source.remove (sync_progress_update_source);
            sync_progress_update_source = 0;
        }
        show_sync_progress (1, detail);
        sync_status_hide_source = Timeout.add (2200, () => {
            sync_status_revealer.reveal_child = false;
            sync_status_hide_source = 0;
            return Source.REMOVE;
        });
    }

    private void update_action_sensitivity () {
        var messages = action_messages ();
        bool selected = messages.size > 0;
        bool single = messages.size == 1;
        bool server_messages = selected;
        bool local_messages = selected;
        foreach (var message in messages) {
            if (message.account_id == "" || is_local_draft (message.id)) server_messages = false;
            if (!is_local_draft (message.id)) local_messages = false;
        }
        bool in_junk = active_mailbox != null && active_mailbox.role == MailboxRole.JUNK;
        bool permanent = selected && selected_are_in_discard_folders ();
        junk_button.icon_name = in_junk ? "security-high-symbolic" : "dialog-warning-symbolic";
        junk_button.tooltip_text = in_junk ? "Mark as Not Junk" : "Move to Junk";
        delete_button.tooltip_text = local_messages ? "Delete message" :
            permanent ? "Delete permanently" : "Move to Trash";
        Accessibility.label (delete_button, delete_button.tooltip_text);
        Accessibility.label (junk_button, in_junk ? "Mark as Not Junk" : "Move to Junk");
        string read_label = read_action_label (messages);
        if (toggle_read_button != null) {
            toggle_read_button.tooltip_text = read_label;
            Accessibility.label (toggle_read_button, read_label);
        }
        if (more_toggle_read_item != null) more_toggle_read_item.set_label (read_label);
        reply_button.sensitive = single; reply_all_button.sensitive = single; forward_button.sensitive = single;
        archive_button.sensitive = server_messages; delete_button.sensitive = selected;
        junk_button.sensitive = server_messages; move_button.sensitive = server_messages;
        flag_button.sensitive = selected; flag_color_button.sensitive = selected;
        update_flag_button_color ();
        foreach (var name in new string[] { "reply", "reply-all", "forward" }) {
            var action = lookup_action (name) as SimpleAction; if (action != null) action.set_enabled (single);
        }
        foreach (var name in new string[] { "export-message", "print-message" }) {
            var action = lookup_action (name) as SimpleAction; if (action != null) action.set_enabled (single);
        }
        foreach (var name in new string[] { "flag", "clear-flag", "set-flag-color", "toggle-read", "labels", "snooze" }) {
            var action = lookup_action (name) as SimpleAction; if (action != null) action.set_enabled (selected);
        }
        foreach (var name in new string[] { "archive", "junk", "move-to", "copy-to", "show-move" }) {
            var action = lookup_action (name) as SimpleAction; if (action != null) action.set_enabled (server_messages);
        }
        var trash_action = lookup_action ("trash") as SimpleAction;
        if (trash_action != null) trash_action.set_enabled (selected);
    }

    private void rebuild_move_menu () {
        var root = new Menu (); var moves = new Menu (); var copies = new Menu (); bool found = false;
        var selected = action_messages ();
        string account_id = selected.size == 0 ? "" : selected[0].account_id;
        foreach (var message in selected)
            if (message.account_id != account_id) account_id = "";
        if (account_id != "") {
            foreach (var mailbox in repository.list_mailboxes ()) {
                if (mailbox.account_id != account_id) continue;
                bool is_current_for_every_message = true;
                foreach (var message in selected)
                    if (message.mailbox_id != mailbox.id) is_current_for_every_message = false;
                if (is_current_for_every_message) continue;
                var move_item = new MenuItem (mailbox.name, null);
                move_item.set_action_and_target_value ("win.move-to", new Variant.string (mailbox.id)); moves.append_item (move_item);
                var copy_item = new MenuItem (mailbox.name, null);
                copy_item.set_action_and_target_value ("win.copy-to", new Variant.string (mailbox.id)); copies.append_item (copy_item);
                found = true;
            }
        }
        if (found) { root.append_section ("Move to", moves); root.append_section ("Copy to", copies); }
        else root.append ("No other mailboxes", null);
        move_button.menu_model = root;
    }

    private void transfer_selected_to (string mailbox_id, bool copy) {
        var messages = action_messages (); if (messages.size == 0) return;
        var undo = new Gee.HashMap<string, string> (); int completed = 0;
        repository.begin_batch ();
        try {
            foreach (var message in messages) {
                try {
                    repository.transfer_to_mailbox (message.id, mailbox_id, copy);
                    if (!copy) undo[message.id] = message.mailbox_id;
                    completed++;
                } catch (Error error) { show_operation_error (error); }
            }
        } finally { repository.end_batch (); }
        message_list.finish_bulk_action ();
        if (copy) toast_overlay.add_toast (new Adw.Toast (completed == 1 ?
            "Message copy queued" : "%d message copies queued".printf (completed)));
        else {
            selected_message = null; reader.show_empty (); update_action_sensitivity ();
            show_transfer_undo (completed == 1 ? "Message moved" : "%d messages moved".printf (completed), undo);
        }
    }

    private void display_message (Message message) {
        var conversation = settings.group_messages ? repository.conversation_for (message) : null;
        reader.show_message (message, conversation, repository.sender_is_vip (message),
            settings.always_show_images, settings.full_html_formatting);
    }

    private void mark_read_after_selection (string message_id) {
        Idle.add (() => {
            marking_selected_message_read = true;
            message_list.mark_read_in_place (message_id);
            repository.mark_read (message_id, true);
            marking_selected_message_read = false;
            return Source.REMOVE;
        });
    }

    public void open_message (string id) {
        var message = repository.find_message (id); if (message == null) return;
        selected_message = message; display_message (message); update_action_sensitivity ();
        set_message_content_visible (true);
        present ();
    }

    private void compose_response (ComposeMode mode) {
        if (selected_message == null) return;
        var source = repository.find_message (selected_message.id) ?? selected_message;
        selected_message = source;
        open_compose (source, mode);
    }

    private void open_compose (Message? source = null, ComposeMode mode = ComposeMode.NEW, Draft? saved = null,
                               bool queued = false) {
        try {
            bool demo = Environment.get_variable ("MAILFICIENT_QA") == "1" &&
                Environment.get_variable ("MAILFICIENT_QA_NO_DEMO") != "1";
            if (cache.list_accounts ().size == 0 && !demo) {
                toast_overlay.add_toast (new Adw.Toast ("Add an email account before composing"));
                show_accounts (true); return;
            }
        } catch (Error error) { show_operation_error (error); return; }
        var compose = new ComposeWindow (this, cache, attachment_service,
            received_attachment_service, draft_lifecycle, outbound_service, settings,
            source, mode, saved, queued);
        compose.draft_changed.connect (() => repository.reload ()); compose.present ();
    }

    public void show_preferences (string page_name = "") {
        var dialog = new PreferencesWindow (cache, settings, remote_content_policy,
            credential_cleanup, account_provisioner, mail_engine, sync_service, online_accounts);
        dialog.account_saved.connect ((account) => account_changed (account));
        dialog.accounts_changed.connect (() => account_changed (null));
        dialog.smart_mailboxes_changed.connect (() => repository.reload ());
        if (page_name != "") dialog.set_visible_page_name (page_name);
        dialog.present (this);
    }

    private void queue_repository_refresh () {
        DebugTrace.log ("refresh", "queue requested source=%u pending=%s".printf (
            repository_refresh_source, repository_refresh_pending.to_string ()));
        if (repository_refresh_source != 0) return;
        repository_refresh_source = Timeout.add (250, () => {
            int64 started = DebugTrace.mark ();
            DebugTrace.log ("refresh", "queued refresh begin pending=%s".printf (
                repository_refresh_pending.to_string ()));
            repository_refresh_source = 0;
            if (!repository_refresh_pending) return Source.REMOVE;

            repository_refresh_pending = false;
            string selected_id = selected_message == null ? "" : selected_message.id;
            DebugTrace.log ("refresh", "reload sidebar and message list selected=%s".printf (selected_id));
            sidebar.reload (false);
            message_list.refresh_preserving_selection (selected_id);
            if (selected_message != null) {
                var refreshed = repository.find_message (selected_message.id);
                if (refreshed != null) selected_message = refreshed;
            }
            rebuild_move_menu ();
            update_action_sensitivity ();
            DebugTrace.duration ("refresh", "queued refresh complete", started);
            return Source.REMOVE;
        });
    }

    private void show_about () {
        var dialog = new Adw.AboutDialog ();
        dialog.application_name = "Mailficient"; dialog.application_icon = "com.local.Mailficient";
        dialog.version = "0.2.2"; dialog.developer_name = "Mailficient Contributors";
        dialog.comments = "A focused native email client for the Linux desktop.";
        dialog.license_type = Gtk.License.GPL_3_0; dialog.present (this);
    }

    private void show_accounts (bool onboarding = false) {
        if (!onboarding) {
            show_preferences ("accounts");
            return;
        }
        var dialog = new AccountManagerDialog (cache, credentials, credential_cleanup, account_provisioner,
            mail_engine, sync_service, online_accounts, onboarding);
        dialog.account_saved.connect ((account) => account_changed (account));
        dialog.accounts_changed.connect (() => account_changed (null));
        if (onboarding) dialog.closed.connect (() => settings.onboarding_completed = true);
        dialog.present (this);
    }

    private void edit_account (AccountSettings account) {
        var dialog = new AccountDialog (account_provisioner, account);
        dialog.account_saved.connect ((saved) => account_changed (saved));
        dialog.present (this);
    }

    private void show_account_info (AccountSettings account) {
        string authentication = account.authentication == AuthenticationMode.GNOME_ONLINE_ACCOUNTS ?
            "GNOME Online Accounts OAuth" : "Password / app password";
        var dialog = new Adw.AlertDialog (account.display_name,
            "%s\n\nIncoming: %s:%u\nOutgoing: %s:%u\nAuthentication: %s".printf (
                account.email, account.incoming_host, account.incoming_port,
                account.outgoing_host, account.outgoing_port, authentication));
        dialog.add_response ("close", "Close"); dialog.close_response = "close";
        dialog.present (this);
    }

    private async void synchronize_account (AccountSettings account) {
        if (sync_service == null) {
            toast_overlay.add_toast (new Adw.Toast ("Account synchronization is unavailable in this build"));
            return;
        }
        toast_overlay.add_toast (new Adw.Toast ("Synchronizing %s…".printf (account.display_name)));
        yield sync_service.sync_account (account);
    }

    public void show_account_onboarding () { show_accounts (true); }

    private void select_preferred_mailbox () {
        string preferred = settings.selected_mailbox_id;
        if (preferred != "" && preferred != CachedMailRepository.GNOME_CALENDAR_ID &&
            preferred != "local-calendar" && sidebar.select_mailbox (preferred)) return;
        var mailboxes = repository.list_mailboxes ();
        foreach (var mailbox in mailboxes) {
            if (mailbox.id != CachedMailRepository.GNOME_CALENDAR_ID)
                if (sidebar.select_mailbox (mailbox.id)) return;
        }
    }

    private void open_gnome_calendar (string previous_mailbox_id) {
        try {
            GnomeCalendarLauncher.launch ();
        } catch (Error error) {
            toast_overlay.add_toast (new Adw.Toast (error.message));
        }

        // The launcher is an action, not a mailbox. Restore the previous mail
        // selection so it is never persisted or reopened during a refresh.
        if (previous_mailbox_id != "" && previous_mailbox_id != CachedMailRepository.GNOME_CALENDAR_ID &&
            sidebar.select_mailbox (previous_mailbox_id)) return;
        sidebar.clear_selection ();
    }

    private void show_reader_empty_state () {
        try {
            bool no_accounts = cache.list_accounts ().size == 0;
            bool normal_mode = Environment.get_variable ("MAILFICIENT_QA") != "1" ||
                Environment.get_variable ("MAILFICIENT_QA_NO_DEMO") == "1";
            if (no_accounts && normal_mode) reader.show_no_accounts ();
            else reader.show_empty ();
        } catch (Error error) { reader.show_empty (); }
    }

    private void toggle_selected_flag () {
        var messages = action_messages (); if (messages.size == 0) return;
        bool flag = false; foreach (var message in messages) if (!message.flagged) flag = true;
        repository.begin_batch ();
        try {
            foreach (var message in messages) { message.flagged = flag; repository.set_flagged (message.id, flag); }
        } finally { repository.end_batch (); }
        message_list.finish_bulk_action ();
    }

    private void clear_selected_flags () {
        var messages = action_messages (); if (messages.size == 0) return;
        repository.begin_batch ();
        try {
            foreach (var message in messages) {
                message.flagged = false;
                repository.set_flagged (message.id, false);
            }
        } finally { repository.end_batch (); }
        message_list.finish_bulk_action ();
    }

    private void set_selected_flag_color (string color) {
        var messages = action_messages (); if (messages.size == 0) return;
        repository.begin_batch ();
        try {
            foreach (var message in messages) {
                message.flag_color = color;
                message.flagged = true;
                repository.set_flag_color (message.id, color);
            }
        } finally { repository.end_batch (); }
        message_list.finish_bulk_action ();
    }

    private void update_flag_button_color () {
        var image = flag_button.get_child () as Gtk.Image;
        if (image == null) return;
        foreach (var color in new string[] { "orange", "red", "purple", "blue", "yellow", "green", "gray" })
            image.remove_css_class ("flag-" + color);
        string selected_color = "red";
        var messages = action_messages ();
        if (messages.size > 0) selected_color = messages[0].flag_color;
        image.add_css_class ("flag-" + selected_color);
    }

    private void toggle_selected_read () {
        var messages = action_messages (); if (messages.size == 0) return;
        bool read = false; foreach (var message in messages) if (message.unread) read = true;
        if (!read && messages.size == 1) preserve_unread_selection_id = messages[0].id;
        repository.begin_batch ();
        try {
            foreach (var message in messages) { message.unread = !read; repository.mark_read (message.id, read); }
        } finally { repository.end_batch (); }
        message_list.finish_bulk_action ();
    }

    private static string read_action_label (Gee.List<Message> messages) {
        if (messages.size == 0) return "Mark as Read or Unread";
        foreach (var message in messages)
            if (message.unread) return "Mark as Read";
        return "Mark as Unread";
    }

    private void move_selected (MailboxRole role) {
        var messages = action_messages (); if (messages.size == 0) return;
        string next_message_id = message_list.adjacent_message_id_after_selection ();
        if (role == MailboxRole.TRASH) {
            bool has_local = false;
            foreach (var message in messages)
                if (is_local_draft (message.id)) { has_local = true; break; }
            if (has_local) {
                prompt_delete_local_messages.begin (messages, next_message_id);
                return;
            }
        }
        if (role == MailboxRole.TRASH && selected_are_in_discard_folders ()) {
            prompt_permanent_delete.begin (next_message_id); return;
        }
        var undo = new Gee.HashMap<string, string> (); int completed = 0;
        repository.begin_batch ();
        try {
            foreach (var message in messages) {
                try {
                    string original = message.mailbox_id;
                    repository.move_to_role (message.id, role);
                    undo[message.id] = original; completed++;
                } catch (Error error) {
                    var friendly = UserFacingError.from_error (error);
                    toast_overlay.add_toast (new Adw.Toast ("%s — %s".printf (friendly.title, friendly.suggestion)));
                }
            }
        } finally { repository.end_batch (); }
        select_after_removal (next_message_id, completed);
        string action = role == MailboxRole.TRASH ? "moved to Trash" : "archived";
        show_transfer_undo (completed == 1 ? "Message %s".printf (action) :
            "%d messages %s".printf (completed, action), undo);
    }

    private async void prompt_delete_local_messages (Gee.List<Message> messages,
                                                     string next_message_id) {
        var dialog = new Adw.AlertDialog (
            messages.size == 1 ? "Delete this message?" :
                "Delete %d messages?".printf (messages.size),
            "Scheduled messages will be removed from Outbox and will not be sent.");
        dialog.add_response ("cancel", "Cancel"); dialog.add_response ("delete", "Delete");
        dialog.default_response = "cancel"; dialog.close_response = "cancel";
        dialog.set_response_appearance ("delete", Adw.ResponseAppearance.DESTRUCTIVE);
        if ((yield dialog.choose (this, null)) != "delete") return;
        int deleted = 0;
        foreach (var message in messages) {
            if (!is_local_draft (message.id)) continue;
            string draft_id = message.id.has_prefix (CachedMailRepository.DRAFT_PREFIX) ?
                message.id.substring (CachedMailRepository.DRAFT_PREFIX.length) :
                message.id.substring (CachedMailRepository.OUTBOX_PREFIX.length);
            try {
                var draft = cache.load_draft (draft_id);
                if (draft == null) continue;
                draft_lifecycle.discard (draft);
                outbound_service.outbox_changed (draft.account_id);
                deleted++;
            } catch (Error error) { show_operation_error (error); }
        }
        repository.reload ();
        select_after_removal (next_message_id, deleted);
        toast_overlay.add_toast (new Adw.Toast (deleted == 1 ?
            "Message deleted" : "%d messages deleted".printf (deleted)));
    }

    private bool selected_is_junk () {
        var messages = action_messages (); if (messages.size == 0) return false;
        foreach (var message in messages) {
            bool junk = false;
            foreach (var mailbox in repository.list_mailboxes ())
                if (mailbox.id == message.mailbox_id) junk = mailbox.role == MailboxRole.JUNK;
            if (!junk) return false;
        }
        return true;
    }

    private bool selected_are_in_discard_folders () {
        var messages = action_messages (); if (messages.size == 0) return false;
        foreach (var message in messages) {
            bool discard = false;
            foreach (var mailbox in repository.list_mailboxes ())
                if (mailbox.id == message.mailbox_id)
                    discard = mailbox.role == MailboxRole.TRASH || mailbox.role == MailboxRole.JUNK;
            if (!discard) return false;
        }
        return true;
    }

    private void classify_selected_junk () {
        var messages = action_messages (); if (messages.size == 0) return;
        string next_message_id = message_list.adjacent_message_id_after_selection ();
        bool mark_junk = !selected_is_junk ();
        var undo = new Gee.HashMap<string, string> (); int completed = 0;
        repository.begin_batch ();
        try {
            foreach (var message in messages) {
                try {
                    string original = message.mailbox_id;
                    repository.classify_junk (message.id, mark_junk);
                    undo[message.id] = original; completed++;
                } catch (Error error) {
                    var friendly = UserFacingError.from_error (error);
                    toast_overlay.add_toast (new Adw.Toast ("%s — %s".printf (friendly.title, friendly.suggestion)));
                }
            }
        } finally { repository.end_batch (); }
        select_after_removal (next_message_id, completed);
        show_transfer_undo (completed == 1 ? (mark_junk ? "Marked as junk" : "Returned to Inbox") :
            (mark_junk ? "%d messages marked as junk".printf (completed) :
                         "%d messages returned to Inbox".printf (completed)), undo);
    }

    private void select_after_removal (string next_message_id, int completed) {
        message_list.finish_bulk_action ();
        if (completed > 0) {
            message_list.refresh_after_removal ();
            if (next_message_id != "" && message_list.select_message (next_message_id)) return;
        }
        selected_message = null;
        reader.show_empty ();
        update_action_sensitivity ();
    }

    private Gee.List<Message> action_messages () {
        var selected = message_list.selected_messages ();
        if (selected.size > 0) return selected;
        var fallback = new Gee.ArrayList<Message> ();
        if (selected_message != null) fallback.add (selected_message);
        return fallback;
    }

    private void show_transfer_undo (string title, Gee.Map<string, string> moves) {
        if (moves.size == 0) return;
        var toast = new Adw.Toast (title); toast.button_label = "Undo";
        toast.button_clicked.connect (() => {
            repository.begin_batch ();
            try {
                foreach (var entry in moves.entries) {
                    try { repository.undo_transfer (entry.key, entry.value); }
                    catch (Error error) { show_operation_error (error); }
                }
            } finally { repository.end_batch (); }
            toast_overlay.add_toast (new Adw.Toast (moves.size == 1 ?
                "Move undone" : "%d moves undone".printf (moves.size)));
        });
        toast_overlay.add_toast (toast);
    }

    private async void edit_selected_labels () {
        var messages = action_messages (); if (messages.size == 0) return;
        var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
        var checks = new Gee.HashMap<int64?, Gtk.CheckButton> ();
        try {
            foreach (var label in repository.list_labels ()) {
                var check = new Gtk.CheckButton.with_label (label.name); bool all = true;
                foreach (var message in messages) {
                    bool found = false;
                    foreach (var applied in repository.labels_for (message.id))
                        if (applied.id == label.id) found = true;
                    if (!found) all = false;
                }
                check.active = all; checks[label.id] = check; content.append (check);
            }
        } catch (Error error) { show_operation_error (error); return; }
        var new_name = new Gtk.Entry (); new_name.placeholder_text = "New label name";
        Accessibility.label (new_name, "New label name"); content.append (new_name);
        var dialog = new Adw.AlertDialog (messages.size == 1 ? "Message Labels" :
            "Labels for %d Messages".printf (messages.size), "Choose labels or create a new one.");
        dialog.extra_child = content; dialog.add_response ("cancel", "Cancel"); dialog.add_response ("apply", "Apply");
        dialog.default_response = "apply"; dialog.close_response = "cancel";
        if ((yield dialog.choose (this, null)) != "apply") return;
        try {
            repository.begin_batch ();
            try {
                foreach (var entry in checks.entries)
                    foreach (var message in messages) repository.set_label (message.id, entry.key, entry.value.active);
                if (new_name.text.strip () != "") {
                    var label = repository.create_label (new_name.text);
                    foreach (var message in messages) repository.set_label (message.id, label.id, true);
                }
            } finally { repository.end_batch (); }
            toast_overlay.add_toast (new Adw.Toast ("Labels updated"));
        } catch (Error error) { show_operation_error (error); }
    }

    private async void snooze_selected () {
        var messages = action_messages (); if (messages.size == 0) return;
        bool all_snoozed = true;
        try { foreach (var message in messages) if (!repository.is_snoozed (message.id)) all_snoozed = false; }
        catch (Error error) { show_operation_error (error); return; }
        if (all_snoozed) {
            try {
                repository.begin_batch ();
                try { foreach (var message in messages) repository.unsnooze (message.id); }
                finally { repository.end_batch (); }
            }
            catch (Error error) { show_operation_error (error); }
            toast_overlay.add_toast (new Adw.Toast ("Message restored")); return;
        }
        var choices = new Gtk.StringList (null); choices.append ("In 1 hour"); choices.append ("In 4 hours");
        choices.append ("Tomorrow"); choices.append ("Next week");
        var when = new Adw.ComboRow (); when.title = "Return to Inbox"; when.model = choices;
        var dialog = new Adw.AlertDialog (messages.size == 1 ? "Snooze Message" : "Snooze Messages",
            "Snoozed mail is hidden until the selected time."); dialog.extra_child = when;
        dialog.add_response ("cancel", "Cancel"); dialog.add_response ("snooze", "Snooze");
        dialog.default_response = "snooze"; dialog.close_response = "cancel";
        if ((yield dialog.choose (this, null)) != "snooze") return;
        int hours = when.selected == 0 ? 1 : when.selected == 1 ? 4 : when.selected == 2 ? 24 : 24 * 7;
        int64 until = new DateTime.now_utc ().add_hours (hours).to_unix ();
        try {
            repository.begin_batch ();
            try { foreach (var message in messages) repository.snooze (message.id, until); }
            finally { repository.end_batch (); }
        }
        catch (Error error) { show_operation_error (error); return; }
        message_list.finish_bulk_action (); selected_message = null; reader.show_empty ();
        toast_overlay.add_toast (new Adw.Toast (messages.size == 1 ? "Message snoozed" :
            "%d messages snoozed".printf (messages.size)));
    }

    private async void export_selected_message () {
        var messages = action_messages (); if (messages.size != 1) return;
        var message = repository.find_message (messages[0].id) ?? messages[0];
        var dialog = new Gtk.FileDialog (); dialog.title = "Export Message"; dialog.accept_label = "Export";
        dialog.initial_name = AttachmentSafety.safe_filename (message.subject) + ".eml";
        try {
            var destination = yield dialog.save (this, null);
            new MessageExportService ().export_eml (message, destination);
            toast_overlay.add_toast (new Adw.Toast ("Message exported"));
        } catch (Error error) { if (!(error is IOError.CANCELLED)) show_operation_error (error); }
    }

    private async void export_mailbox (Mailbox mailbox) {
        var dialog = new Gtk.FileDialog (); dialog.title = "Export Mailbox"; dialog.accept_label = "Export";
        dialog.initial_name = AttachmentSafety.safe_filename (mailbox.name) + ".mbox";
        try {
            var destination = yield dialog.save (this, null);
            new MessageExportService ().export_mbox (repository, mailbox, destination);
            toast_overlay.add_toast (new Adw.Toast ("Mailbox exported"));
        } catch (Error error) { if (!(error is IOError.CANCELLED)) show_operation_error (error); }
    }

    private async void print_selected_message () {
        var messages = action_messages (); if (messages.size != 1) return;
        var message = repository.find_message (messages[0].id) ?? messages[0];
        File? temporary = null;
        bool handed_to_print_system = false;
        try {
            FileIOStream stream;
            temporary = File.new_tmp ("mailficient-print-XXXXXX.pdf", out stream);
            stream.close ();
            // Render HTML to a complete PDF before handing it to the desktop
            // print system so formatting, images, and pagination are retained.
            if (message.body_html != "")
                yield reader.export_current_pdf (message.id, temporary);
            else
                new MessageExportService ().export_pdf (message, temporary);
            var dialog = new Gtk.PrintDialog ();
            dialog.title = "Print Message";
            yield dialog.print_file (this, null, temporary, null);
            handed_to_print_system = true;
        } catch (Error error) { if (!(error is IOError.CANCELLED)) show_operation_error (error); }
        finally {
            if (temporary != null) {
                if (handed_to_print_system) retain_print_document (temporary);
                else try { temporary.delete (); } catch (Error ignored) { }
            }
        }
    }

    private void retain_print_document (File document) {
        // The print backend may read the file after the dialog closes.
        Timeout.add_seconds (2 * 60 * 60, () => {
            try { document.delete (); } catch (Error ignored) { }
            return Source.REMOVE;
        });
    }

    private async void qa_export_rendered_print (string path) {
        if (selected_message == null) {
            critical ("Rendered message was not available for print QA");
            return;
        }
        try {
            yield reader.export_current_pdf (
                selected_message.id, File.new_for_path (path));
        } catch (Error error) {
            critical ("Rendered print QA failed: %s", error.message);
        }
    }
}
}
