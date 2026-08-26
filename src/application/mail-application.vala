namespace Mailficient {
public class MailApplication : Adw.Application {
    private MailWindow? window;
    private StartupErrorWindow? startup_error_window;
    private CacheDatabase? cache;
    private CredentialStore credentials;
    private MailEngine? mail_engine;
    private AttachmentService? attachment_service;
    private ReceivedAttachmentService? received_attachment_service;
    private CalendarIntegrationService? calendar_service;
    private DraftLifecycleService? draft_lifecycle;
    private OutboundService? outbound_service;
    private BackgroundAutostartService background_autostart = new BackgroundAutostartService ();
    private AccountSyncService? sync_service;
    private FolderService? folder_service;
    private MailSettingsStore settings;
    private CacheMaintenanceService? cache_maintenance;
    private NotificationService notifications;
    private TaskReminderService? task_reminders;
    private OnlineAccountService online_accounts;
    private CredentialCleanupService? credential_cleanup;
    private RemoteContentPolicy? remote_content_policy;
    private AccountProvisioningService? account_provisioner;
    private uint background_sync_source;
    private uint startup_sync_source;
    private ulong network_changed_handler;
    private StartupSyncGate? startup_sync_gate;
    private bool onboarding_presented;

    public MailApplication () {
        // Development builds can run beside the installed application. This
        // prevents testing the source tree from silently activating an older
        // /usr/lib/mailficient process with the production application ID.
        Object (application_id: Environment.get_variable ("MAILFICIENT_DEV_INSTANCE") == "1" ?
                "com.local.Mailficient.Dev" : "com.local.Mailficient",
            flags: Environment.get_variable ("MAILFICIENT_QA") == "1" ?
                ApplicationFlags.NON_UNIQUE : ApplicationFlags.DEFAULT_FLAGS);
        credentials = new LibsecretCredentialStore ();
        online_accounts = new GnomeOnlineAccountService ();
        notifications = new NotificationService (this);
    }

    protected override void startup () {
        base.startup ();
        Gtk.Window.set_default_icon_name ("com.local.Mailficient");
        var icon_theme = Gtk.IconTheme.get_for_display (Gdk.Display.get_default ());
        icon_theme.add_resource_path ("/com/local/Mailficient/icons");
        if (Environment.get_variable ("MAILFICIENT_QA_DARK") == "1")
            Adw.StyleManager.get_default ().color_scheme = Adw.ColorScheme.FORCE_DARK;
        else if (Environment.get_variable ("MAILFICIENT_QA") == "1")
            Adw.StyleManager.get_default ().color_scheme = Adw.ColorScheme.FORCE_LIGHT;
        var provider = new Gtk.CssProvider ();
        provider.load_from_resource ("/com/local/Mailficient/style.css");
        Gtk.StyleContext.add_provider_for_display (Gdk.Display.get_default (), provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
        var quit_action = new SimpleAction ("quit", null);
        quit_action.activate.connect (quit);
        add_action (quit_action);
        set_accels_for_action ("app.quit", { "<Control>q" });
        var open_message = new SimpleAction ("open-message", VariantType.STRING);
        open_message.activate.connect ((parameter) => {
            if (parameter == null) return;
            activate ();
            if (window != null) window.open_message (parameter.get_string ());
        });
        add_action (open_message);
        var open_task = new SimpleAction ("open-task", VariantType.INT64);
        open_task.activate.connect ((parameter) => {
            if (parameter == null) return;
            activate ();
            if (window != null) window.open_task (parameter.get_int64 ());
        });
        add_action (open_task);
        var preferences_action = new SimpleAction ("preferences", null);
        preferences_action.activate.connect (() => { activate (); if (window != null) window.show_preferences (); });
        add_action (preferences_action);
        set_accels_for_action ("app.preferences", { "<Control>comma" });
    }

    protected override void activate () {
        if (window == null && startup_error_window != null) {
            startup_error_window.present ();
            return;
        }
        bool created_window = false;
        if (window == null) {
            var demo_repository = new DemoMailRepository ();
            CachedMailRepository repository;
            bool has_accounts = false;
            bool demo_mode = Environment.get_variable ("MAILFICIENT_QA") == "1" &&
                Environment.get_variable ("MAILFICIENT_QA_NO_DEMO") != "1";
            try {
                if (Environment.get_variable ("MAILFICIENT_QA_STARTUP_ERROR") == "1")
                    throw new MailError.STORAGE ("Demo diagnostic: SQLite reported that mail.db is not a database");
                string directory = LocalDataMigration.prepare (Environment.get_user_data_dir ());
                cache = new CacheDatabase (Path.build_filename (directory, "mail.db"));
                cache.remote_draft_work_queued.connect ((account_id) => {
                    try {
                        if (cache.find_account (account_id) != null)
                            background_autostart.ensure_available.begin ();
                    } catch (MailError error) {
                        warning ("Could not inspect background Drafts activation: %s", error.message);
                    }
                });
                settings = new MailSettingsStore (cache);
                apply_appearance ();
                credential_cleanup = new CredentialCleanupService (cache, credentials);
                remote_content_policy = new RemoteContentPolicy (cache);
                if (Environment.get_variable ("MAILFICIENT_QA_SIGNATURE") == "1") {
                    settings.set_signature ("demo-account", "Alex Morgan\nSent from Mailficient");
                    settings.set_signature_enabled ("demo-account", true);
                }
                notifications.enabled = settings.notifications_enabled;
                settings.changed.connect ((key) => {
                    if (key == "notifications-enabled") notifications.enabled = settings.notifications_enabled;
                    if (key == "appearance") apply_appearance ();
                    if ((key == "sync-interval-minutes" || key == "sync-on-startup") && sync_service != null)
                        install_background_sync (false);
                });
                attachment_service = new AttachmentService (Path.build_filename (directory, "attachments"));
                cache_maintenance = new CacheMaintenanceService (cache, {
                    Path.build_filename (directory, "attachments"),
                    Path.build_filename (directory, "received-attachments")
                });
                has_accounts = cache.list_accounts ().size > 0;
                if (demo_mode && !has_accounts) {
                    foreach (var message in demo_repository.list_messages ("inbox")) cache.cache_message (message);
                    if (cache.saved_draft_count () == 0) {
                        var sample_draft = new Draft ("demo-account");
                        sample_draft.to = "Maya Chen <maya@example.net>";
                        sample_draft.subject = "Thoughts for the design follow-up";
                        sample_draft.body_text = "Hi Maya,\n\nThe updated spacing looks excellent. I’ll send the remaining notes tomorrow.\n\nAlex";
                        cache.save_draft (sample_draft);
                    }
                    if (Environment.get_variable ("MAILFICIENT_QA_OUTBOX") == "1" && cache.outbox_count () == 0) {
                        var queued = new Draft ("demo-account"); queued.to = "Noah Williams <noah@example.org>";
                        queued.subject = "Re: Dinner next week?"; queued.body_text = "Thursday at seven works perfectly. See you then!";
                        cache.queue_for_sending (queued);
                        if (Environment.get_variable ("MAILFICIENT_QA_OUTBOX_PREPARING") == "1") {
                            cache.claim_queued_send (queued.id, "visual-qa",
                                new DateTime.now_utc ().to_unix () + 300, false);
                        } else if (Environment.get_variable ("MAILFICIENT_QA_OUTBOX_ACCEPTED") == "1") {
                            cache.mark_send_started (queued.id);
                            cache.mark_send_accepted (queued.id);
                        } else if (Environment.get_variable ("MAILFICIENT_QA_OUTBOX_REJECTED") == "1") {
                            cache.record_send_rejection (queued.id,
                                "550 5.1.1 The recipient address was rejected by the mail server.");
                        } else if (Environment.get_variable ("MAILFICIENT_QA_OUTBOX_EDITOR") == "1") {
                            cache.mark_send_started (queued.id);
                            cache.record_send_uncertain (queued.id,
                                "Demo diagnostic: SMTP connection ended before the server confirmed delivery.");
                        }
                    }
                } else cache.clear_demo_data ();
                repository = new CachedMailRepository (cache, demo_repository, demo_mode);
#if HAVE_CAMEL
                // Camel's folder-summary SQLite schema is private to the EDS
                // release that created it. Do not reopen the pre-v3 cache:
                // some upgrades abort inside Camel instead of reporting an
                // error when an older folders.db lacks a required column.
                // This cache is disposable; mail.db remains authoritative.
                var camel_engine = new CamelMailEngine (credentials,
                    Path.build_filename (directory, "camel-data"), Path.build_filename (directory, "camel-cache-v3"),
                    Path.build_filename (directory, "received-attachments"), online_accounts);
                mail_engine = camel_engine;
                account_provisioner = new AccountProvisioningService (cache, credentials,
                    credential_cleanup, camel_engine);
#endif
                outbound_service = new OutboundService (cache, mail_engine, attachment_service);
                outbound_service.background_delivery_needed.connect ((account_id) => {
                    try {
                        if (cache.find_account (account_id) != null)
                            background_autostart.ensure_available.begin ();
                    } catch (MailError error) {
                        warning ("Could not inspect background Outbox activation: %s", error.message);
                    }
                });
                outbound_service.start_scheduler ();
                bool pending_background_work = false;
                foreach (var account in cache.list_accounts ()) {
                    if (cache.next_outbox_attempt (account.id) != null ||
                        cache.has_pending_remote_draft_work (account.id)) {
                        pending_background_work = true;
                        break;
                    }
                }
                if (pending_background_work)
                    background_autostart.ensure_available.begin ();
#if HAVE_CAMEL
                sync_service = new AccountSyncService (cache, mail_engine, outbound_service,
                    new JunkFilterService (cache), attachment_service);
                // AccountSyncService already bounds and aggregates arrivals
                // across multi-session history checks. Listening only to the
                // summary prevents duplicate per-message notifications.
                sync_service.new_mail_summary.connect ((summary) =>
                    notifications.notify_new_mail (summary));
#endif
                folder_service = new FolderService (cache, mail_engine, sync_service);
                received_attachment_service = new ReceivedAttachmentService (cache,
                    attachment_service, mail_engine);
                CalendarBackend calendar_backend;
#if HAVE_CALENDAR
                calendar_backend = new EdsCalendarBackend ();
#else
                calendar_backend = new DesktopCalendarBackend ();
#endif
                calendar_service = new CalendarIntegrationService (cache,
                    received_attachment_service, calendar_backend);
                draft_lifecycle = new DraftLifecycleService (cache, attachment_service);
            } catch (Error error) {
                warning ("Local mail cache unavailable: %s", error.message);
                show_startup_error (error); return;
            }
            var search_service = new MailSearchService (cache,
                mail_engine as RemoteMailSearchProvider, mail_engine);
            window = new MailWindow (this, repository, search_service, cache, attachment_service,
                received_attachment_service, calendar_service, draft_lifecycle,
                outbound_service, settings, remote_content_policy, account_provisioner,
                credentials, credential_cleanup, mail_engine, sync_service, folder_service,
                online_accounts);
            task_reminders = new TaskReminderService (cache);
            task_reminders.reminder_due.connect ((task) => notifications.notify_task_reminder (task));
            task_reminders.start ();
            created_window = true;
            credential_cleanup.retry_pending.begin ();
            Idle.add (() => {
                try { cache_maintenance.run (); }
                catch (Error error) { warning ("Local cache maintenance failed: %s", error.message); }
                return Source.REMOVE;
            });
        }
        window.present ();
        // Present and request the saved window state before installing anything
        // that can initiate network or MIME work.
        if (created_window && sync_service != null) install_background_sync (true);
        bool qa_onboarding = Environment.get_variable ("MAILFICIENT_QA_NO_DEMO") == "1";
        try {
            if (cache != null && cache.list_accounts ().size == 0 &&
                !onboarding_presented &&
                (qa_onboarding || (Environment.get_variable ("MAILFICIENT_QA") != "1" && !settings.onboarding_completed))) {
                onboarding_presented = true;
                Idle.add (() => { window.show_account_onboarding (); return Source.REMOVE; });
            }
        } catch (Error error) { warning ("Could not inspect first-launch account state: %s", error.message); }
        if (Environment.get_variable ("MAILFICIENT_QA_COMPOSE") == "1") {
            var compose = new ComposeWindow (window, cache, attachment_service,
                received_attachment_service, draft_lifecycle, outbound_service, settings);
            compose.present ();
            if (Environment.get_variable ("MAILFICIENT_QA_DISCARD") == "1")
                Timeout.add (700, () => { compose.close (); return Source.REMOVE; });
        }
        if (Environment.get_variable ("MAILFICIENT_QA_FORWARD") == "1")
            Timeout.add (900, () => {
                window.activate_action ("forward", null);
                return Source.REMOVE;
            });
        if (Environment.get_variable ("MAILFICIENT_QA_OUTBOX_EDITOR") == "1") {
            try {
                var outbox = cache.list_outbox_items ();
                if (outbox.size > 0)
                    new ComposeWindow (window, cache, attachment_service, received_attachment_service,
                        draft_lifecycle, outbound_service, settings, null, ComposeMode.NEW,
                        outbox[0].draft, true).present ();
            } catch (Error error) { warning ("Could not open QA Outbox message: %s", error.message); }
        }
        if (Environment.get_variable ("MAILFICIENT_QA_ACCOUNT") == "1")
            new AccountDialog (account_provisioner).present (window);
        if (Environment.get_variable ("MAILFICIENT_QA_ACCOUNTS") == "1")
            window.show_preferences ("accounts");
        if (Environment.get_variable ("MAILFICIENT_QA_ONLINE_ACCOUNTS") == "1")
            new OnlineAccountDialog (cache, account_provisioner, new DemoOnlineAccountService ()).present (window);
        if (Environment.get_variable ("MAILFICIENT_QA_PROVIDERS") == "1")
            new ProviderChooserDialog ().present (window);
        string? qa_preferences = Environment.get_variable ("MAILFICIENT_QA_PREFERENCES");
        if (qa_preferences != null && qa_preferences != "" && qa_preferences != "0") window.show_preferences ();
    }

    private void show_startup_error (Error error) {
        UserFacingError friendly = UserFacingError.from_error (error);
        if (error is MailError.STORAGE) {
            friendly = new UserFacingError ("Mail data could not be opened",
                "Mailficient could not safely open or update its local mail database.",
                "Check available disk space and file permissions, then choose Try Again.",
                friendly.technical_detail);
        }
        var failed_window = new StartupErrorWindow (this, friendly);
        startup_error_window = failed_window;
        failed_window.retry_requested.connect (() => {
            failed_window.close ();
            if (startup_error_window == failed_window) startup_error_window = null;
            reset_failed_initialization ();
            activate ();
        });
        failed_window.quit_requested.connect (quit);
        failed_window.present ();
    }

    private void reset_failed_initialization () {
        cache = null; mail_engine = null; attachment_service = null;
        received_attachment_service = null; draft_lifecycle = null; outbound_service = null;
        sync_service = null; folder_service = null; cache_maintenance = null;
        credential_cleanup = null; remote_content_policy = null; account_provisioner = null;
        if (task_reminders != null) task_reminders.stop ();
        task_reminders = null;
        onboarding_presented = false;
    }

    private void install_background_sync (bool initial) {
        if (background_sync_source != 0) {
            Source.remove (background_sync_source); background_sync_source = 0;
        }
        if (initial) {
            if (startup_sync_source != 0) Source.remove (startup_sync_source);
            startup_sync_source = Timeout.add_seconds (StartupSyncGate.GRACE_SECONDS, () => {
                startup_sync_source = 0;
                if (startup_sync_gate != null) startup_sync_gate.enable_reconnect_sync ();
                if (settings.sync_on_startup) sync_service.sync_all.begin ();
                return Source.REMOVE;
            });
        }
        int interval = settings.sync_interval_minutes;
        if (interval > 0) {
            background_sync_source = Timeout.add_seconds ((uint) (interval * 60), () => {
                sync_service.sync_all.begin (); return Source.CONTINUE;
            });
        }
        if (network_changed_handler == 0) {
            var monitor = NetworkMonitor.get_default ();
            var gate = new StartupSyncGate (monitor.network_available);
            startup_sync_gate = gate;
            network_changed_handler = monitor.network_changed.connect ((available) => {
                if (gate.should_sync_for_network_change (available))
                    sync_service.sync_all.begin ();
            });
        }
    }

    private void apply_appearance () {
        var manager = Adw.StyleManager.get_default ();
        if (Environment.get_variable ("MAILFICIENT_QA_DARK") == "1") {
            manager.color_scheme = Adw.ColorScheme.FORCE_DARK;
            return;
        }
        if (Environment.get_variable ("MAILFICIENT_QA") == "1") {
            manager.color_scheme = Adw.ColorScheme.FORCE_LIGHT;
            return;
        }
        switch (settings.appearance) {
        case "light": manager.color_scheme = Adw.ColorScheme.FORCE_LIGHT; break;
        case "dark": manager.color_scheme = Adw.ColorScheme.FORCE_DARK; break;
        default: manager.color_scheme = Adw.ColorScheme.DEFAULT; break;
        }
    }

    protected override void shutdown () {
        if (window != null) window.persist_layout ();
        if (background_sync_source != 0) Source.remove (background_sync_source);
        if (startup_sync_source != 0) Source.remove (startup_sync_source);
        if (network_changed_handler != 0)
            NetworkMonitor.get_default ().disconnect (network_changed_handler);
        startup_sync_gate = null;
        if (outbound_service != null) outbound_service.stop_scheduler ();
        if (task_reminders != null) task_reminders.stop ();
        if (sync_service != null) sync_service.cancel ();
        base.shutdown ();
    }
}
}
