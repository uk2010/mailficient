using Mailficient;

private class TestContactSuggestionProvider : Object, ContactSuggestionProvider {
    public async Gee.List<Recipient> suggest (string query, uint limit,
                                              Cancellable? cancellable = null) throws Error {
        if (cancellable != null) cancellable.set_error_if_cancelled ();
        var result = new Gee.ArrayList<Recipient> ();
        result.add (new Recipient ("Jane from Contacts", "jane@example.net"));
        result.add (new Recipient ("Janet Rivera", "janet@example.org"));
        result.add (new Recipient ("Alex", "alex@example.com"));
        return result;
    }
}

private class CleanupCredentialStore : Object, CredentialStore {
    public bool fail_clear;
    public int clear_calls;
    public async void store_password (string account_id, string protocol, string password,
                                      Cancellable? cancellable = null) throws Error { }
    public async string? lookup_password (string account_id, string protocol,
                                          Cancellable? cancellable = null) throws Error { return null; }
    public async void clear_account (string account_id, Cancellable? cancellable = null) throws Error {
        clear_calls++;
        if (fail_clear) throw new IOError.FAILED ("Secret Service is temporarily unavailable");
    }
}

private class MemoryCredentialStore : Object, CredentialStore {
    public Gee.HashMap<string, string> values = new Gee.HashMap<string, string> ();
    public async void store_password (string account_id, string protocol, string password,
                                      Cancellable? cancellable = null) throws Error {
        if (cancellable != null) cancellable.set_error_if_cancelled ();
        values[account_id + ":" + protocol] = password;
    }
    public async string? lookup_password (string account_id, string protocol,
                                          Cancellable? cancellable = null) throws Error {
        if (cancellable != null) cancellable.set_error_if_cancelled ();
        return values[account_id + ":" + protocol];
    }
    public async void clear_account (string account_id, Cancellable? cancellable = null) throws Error {
        if (cancellable != null) cancellable.set_error_if_cancelled ();
        values.unset (account_id + ":imap"); values.unset (account_id + ":smtp");
    }
}

private class TestAccountStore : Object, AccountStore {
    public bool fail_save;
    public AccountSettings? saved;
    public void save_account (AccountSettings account) throws MailError {
        if (fail_save) throw new MailError.STORAGE ("The test account database is unavailable");
        saved = account;
    }
}

private class ProvisioningMailEngine : Object, MailEngine {
    public bool fail_candidate;
    public Gee.ArrayList<string> connections = new Gee.ArrayList<string> ();
    public Gee.ArrayList<string> disconnections = new Gee.ArrayList<string> ();
    public async void connect_account (AccountSettings settings, Cancellable? cancellable = null) throws Error {
        if (cancellable != null) cancellable.set_error_if_cancelled ();
        connections.add (settings.id + "@" + settings.incoming_host);
        if (fail_candidate && settings.id.has_prefix ("candidate-"))
            throw new MailError.CONNECTION ("Candidate server rejected the connection");
    }
    public async void connect_incoming_account (AccountSettings settings, Cancellable? cancellable = null) throws Error {
        yield connect_account (settings, cancellable);
    }
    public async void disconnect_account (string account_id, Cancellable? cancellable = null) throws Error {
        if (cancellable != null) cancellable.set_error_if_cancelled ();
        disconnections.add (account_id);
    }
    public async MailSyncResult synchronize (string account_id, Gee.Set<string>? cached_message_ids = null,
                                              Cancellable? cancellable = null) throws Error { return new MailSyncResult (account_id); }
    public async SendResult send (Draft draft, Cancellable? cancellable = null) throws Error { return new SendResult (); }
    public async void save_remote_attachment (string account_id, string mailbox_name,
                                               string remote_uid, int remote_part_index,
                                               File destination, int64 maximum_bytes,
                                               Cancellable? cancellable = null) throws Error { }
    public async void set_message_state (string account_id, string mailbox_name, string remote_uid,
                                         MessageStateField field, bool value,
                                         Cancellable? cancellable = null) throws Error { }
    public async string? transfer_message (string account_id, string source_mailbox, string remote_uid,
                                           string destination_mailbox, bool copy,
                                           Cancellable? cancellable = null) throws Error { return null; }
    public async void create_folder (string account_id, string parent_name, string folder_name,
                                     Cancellable? cancellable = null) throws Error { }
    public async void rename_folder (string account_id, string old_name, string old_display_name,
                                     string new_display_name, Cancellable? cancellable = null) throws Error { }
    public async void delete_folder (string account_id, string folder_name,
                                     Cancellable? cancellable = null) throws Error { }
    public async void permanently_delete_message (string account_id, string mailbox_name, string remote_uid,
                                                   Cancellable? cancellable = null) throws Error { }
    public async void empty_folder (string account_id, string folder_name,
                                    Cancellable? cancellable = null) throws Error { }
    public SyncState state_for (string account_id) { return new SyncState (); }
}

private class FailingMailEngine : Object, MailEngine {
    public async void connect_account (AccountSettings settings, Cancellable? cancellable = null) throws Error {
        throw new MailError.CONNECTION ("Test server is unreachable");
    }
    public async void connect_incoming_account (AccountSettings settings, Cancellable? cancellable = null) throws Error {
        throw new MailError.CONNECTION ("Test server is unreachable");
    }
    public async void disconnect_account (string account_id, Cancellable? cancellable = null) throws Error { }
    public async MailSyncResult synchronize (string account_id, Gee.Set<string>? cached_message_ids = null,
                                              Cancellable? cancellable = null) throws Error {
        return new MailSyncResult (account_id);
    }
    public async SendResult send (Draft draft, Cancellable? cancellable = null) throws Error { return new SendResult (); }
    public async void save_remote_attachment (string account_id, string mailbox_name,
                                               string remote_uid, int remote_part_index,
                                               File destination, int64 maximum_bytes,
                                               Cancellable? cancellable = null) throws Error {
        throw new MailError.CONNECTION ("Test server is unreachable");
    }
    public async void set_message_state (string account_id, string mailbox_name, string remote_uid,
                                         MessageStateField field, bool value,
                                         Cancellable? cancellable = null) throws Error {
        throw new MailError.CONNECTION ("Test server is unreachable");
    }
    public async string? transfer_message (string account_id, string source_mailbox, string remote_uid,
                                           string destination_mailbox, bool copy,
                                           Cancellable? cancellable = null) throws Error {
        throw new MailError.CONNECTION ("Test server is unreachable");
    }
    public async void create_folder (string account_id, string parent_name, string folder_name,
                                     Cancellable? cancellable = null) throws Error { throw new MailError.CONNECTION ("Test server is unreachable"); }
    public async void rename_folder (string account_id, string old_name, string old_display_name,
                                     string new_display_name, Cancellable? cancellable = null) throws Error { throw new MailError.CONNECTION ("Test server is unreachable"); }
    public async void delete_folder (string account_id, string folder_name,
                                     Cancellable? cancellable = null) throws Error { throw new MailError.CONNECTION ("Test server is unreachable"); }
    public async void permanently_delete_message (string account_id, string mailbox_name, string remote_uid,
                                                   Cancellable? cancellable = null) throws Error { throw new MailError.CONNECTION ("Test server is unreachable"); }
    public async void empty_folder (string account_id, string folder_name,
                                    Cancellable? cancellable = null) throws Error { throw new MailError.CONNECTION ("Test server is unreachable"); }
    public SyncState state_for (string account_id) { return new SyncState (); }
}

private class RecordingMailEngine : Object, MailEngine {
    public MailSyncResult snapshot { get; set; }
    public bool delay_changes { get; set; }
    public bool delay_synchronization { get; set; }
    public int connect_calls;
    public int disconnect_calls;
    public int synchronize_calls;
    public int active_synchronizations;
    public int maximum_active_synchronizations;
    public int send_calls;
    public bool fail_send;
    public bool reject_send;
    public bool rate_limit_send;
    public bool stall_connect;
    public bool stall_send;
    public Error? synchronize_failure;
    public int remote_attachment_calls;
    public int64 last_remote_attachment_maximum;
    public string last_remote_attachment_destination = "";
    public Gee.ArrayList<string> state_changes = new Gee.ArrayList<string> ();
    public Gee.ArrayList<string> transfers = new Gee.ArrayList<string> ();
    public Gee.ArrayList<string> operations = new Gee.ArrayList<string> ();
    public Gee.ArrayList<string> permanent_deletions = new Gee.ArrayList<string> ();
    public Gee.ArrayList<string> emptied_folders = new Gee.ArrayList<string> ();
    public Gee.ArrayList<MailSyncResult> batches = new Gee.ArrayList<MailSyncResult> ();
    public Gee.ArrayList<MailSyncResult> queued_snapshots = new Gee.ArrayList<MailSyncResult> ();
    private Gee.HashMap<string, SyncState> states = new Gee.HashMap<string, SyncState> ();

    public RecordingMailEngine (string account_id) {
        snapshot = new MailSyncResult (account_id);
    }

    public async void connect_account (AccountSettings settings, Cancellable? cancellable = null) throws Error {
        if (stall_connect) {
            if (cancellable == null) {
                yield;
            } else {
                ulong handler = cancellable.cancelled.connect (() => {
                    Idle.add (() => { connect_account.callback (); return Source.REMOVE; });
                });
                if (!cancellable.is_cancelled ()) yield;
                cancellable.disconnect (handler);
                cancellable.set_error_if_cancelled ();
            }
        }
        if (cancellable != null) cancellable.set_error_if_cancelled ();
        connect_calls++;
    }
    public async void connect_incoming_account (AccountSettings settings, Cancellable? cancellable = null) throws Error {
        yield connect_account (settings, cancellable);
    }
    public async void disconnect_account (string account_id, Cancellable? cancellable = null) throws Error {
        disconnect_calls++;
    }
    public async MailSyncResult synchronize (string account_id, Gee.Set<string>? cached_message_ids = null,
                                              Cancellable? cancellable = null) throws Error {
        if (cancellable != null) cancellable.set_error_if_cancelled ();
        synchronize_calls++; active_synchronizations++;
        if (synchronize_failure != null) {
            active_synchronizations--;
            throw synchronize_failure;
        }
        var state = state_for (account_id);
        state.phase = SyncPhase.SYNCHRONIZING;
        state.messages_to_download = 0; state.messages_downloaded = 0;
        state.detail = "Checking messages…"; state.progress = 0.1;
        maximum_active_synchronizations = int.max (maximum_active_synchronizations, active_synchronizations);
        if (delay_synchronization) {
            Timeout.add (20, () => { synchronize.callback (); return Source.REMOVE; });
            yield;
        }
        if (cancellable != null && cancellable.is_cancelled ()) {
            active_synchronizations--;
            cancellable.set_error_if_cancelled ();
        }
        foreach (var batch in batches) sync_batch_ready (batch);
        var current_snapshot = queued_snapshots.size > 0 ? queued_snapshots.remove_at (0) : snapshot;
        state.messages_to_download = current_snapshot.messages_to_download;
        if (current_snapshot.messages_to_download > 0 && current_snapshot.messages.size > 0)
            state.messages_downloaded = 1;
        state.messages_downloaded = current_snapshot.messages.size;
        state.detail = "Downloaded %d of %d messages".printf (
            state.messages_downloaded, state.messages_to_download);
        state.progress = state.messages_to_download > 0 ?
            state.messages_downloaded / (double) state.messages_to_download : 1;
        active_synchronizations--;
        state.detail = "Mail is up to date"; state.progress = 1; state.phase = SyncPhase.IDLE;
        return current_snapshot;
    }
    public async SendResult send (Draft draft, Cancellable? cancellable = null) throws Error {
        if (cancellable != null) cancellable.set_error_if_cancelled ();
        send_calls++;
        if (stall_send) {
            if (cancellable == null) {
                yield;
            } else {
                ulong handler = cancellable.cancelled.connect (() => {
                    Idle.add (() => { send.callback (); return Source.REMOVE; });
                });
                if (!cancellable.is_cancelled ()) yield;
                cancellable.disconnect (handler);
                cancellable.set_error_if_cancelled ();
            }
        }
        if (rate_limit_send) throw new MailError.RATE_LIMITED ("Too many requests; temporarily throttled");
        if (reject_send) throw new MailError.SEND_REJECTED ("550 Recipient address rejected");
        if (fail_send) throw new MailError.CONNECTION ("SMTP response was lost");
        return new SendResult ();
    }
    public async void save_remote_attachment (string account_id, string mailbox_name,
                                               string remote_uid, int remote_part_index,
                                               File destination, int64 maximum_bytes,
                                               Cancellable? cancellable = null) throws Error {
        if (cancellable != null) cancellable.set_error_if_cancelled ();
        remote_attachment_calls++;
        last_remote_attachment_maximum = maximum_bytes;
        last_remote_attachment_destination = destination.get_path ();
        operations.add ("attachment:%s:%s:%d".printf (mailbox_name, remote_uid, remote_part_index));
        var output = destination.replace (null, false, FileCreateFlags.PRIVATE, cancellable);
        uint8[] payload = "downloaded attachment".data; size_t written;
        output.write_all (payload, out written, cancellable); output.close (cancellable);
    }
    public async void set_message_state (string account_id, string mailbox_name, string remote_uid,
                                         MessageStateField field, bool value,
                                         Cancellable? cancellable = null) throws Error {
        if (cancellable != null) cancellable.set_error_if_cancelled ();
        state_changes.add ("%s:%d:%s".printf (remote_uid, (int) field, value.to_string ()));
        operations.add ("state:%s:%s".printf (mailbox_name, remote_uid));
        if (delay_changes) {
            Timeout.add (20, () => { set_message_state.callback (); return Source.REMOVE; });
            yield;
        }
    }
    public async string? transfer_message (string account_id, string source_mailbox, string remote_uid,
                                           string destination_mailbox, bool copy,
                                           Cancellable? cancellable = null) throws Error {
        if (cancellable != null) cancellable.set_error_if_cancelled ();
        transfers.add ("%s:%s:%s".printf (remote_uid, destination_mailbox, copy.to_string ()));
        operations.add ("transfer:%s:%s".printf (source_mailbox, remote_uid));
        return "destination-" + remote_uid;
    }
    public async void create_folder (string account_id, string parent_name, string folder_name,
                                     Cancellable? cancellable = null) throws Error { }
    public async void rename_folder (string account_id, string old_name, string old_display_name,
                                     string new_display_name, Cancellable? cancellable = null) throws Error { }
    public async void delete_folder (string account_id, string folder_name,
                                     Cancellable? cancellable = null) throws Error { }
    public async void permanently_delete_message (string account_id, string mailbox_name, string remote_uid,
                                                   Cancellable? cancellable = null) throws Error {
        permanent_deletions.add (mailbox_name + ":" + remote_uid);
        operations.add ("delete:" + mailbox_name + ":" + remote_uid);
    }
    public async void empty_folder (string account_id, string folder_name,
                                    Cancellable? cancellable = null) throws Error {
        emptied_folders.add (folder_name); operations.add ("empty:" + folder_name);
    }
    public SyncState state_for (string account_id) {
        if (!states.has_key (account_id)) states[account_id] = new SyncState ();
        return states[account_id];
    }
}

private void test_search () {
    var query = SearchQuery.parse ("from:maya to:alex mailbox:inbox label:work is:unread has:attachment after:2026-07-01 before:2026-08-01 design review");
    assert (query.sender == "maya");
    assert (query.recipient == "alex"); assert (query.mailbox == "inbox");
    assert (query.label == "work");
    assert (query.unread == true);
    assert (query.has_attachment == true);
    assert (query.after_unix != null); assert (query.before_unix != null);
    assert (query.text == "design review");
    var exact = SearchQuery.parse ("date:2026-07-19");
    assert (exact.after_unix != null); assert (exact.before_unix > exact.after_unix);
    var invalid = SearchQuery.parse ("after:not-a-date notes");
    assert (invalid.after_unix == null); assert (invalid.text == "after:not-a-date notes");
}

private void test_cached_search () {
    string path = Path.build_filename (Environment.get_tmp_dir (), "mailficient-search-%s.sqlite".printf (Uuid.string_random ()));
    try {
        var cache = new CacheDatabase (path);
        cache.cache_message (new Message ("m1", "inbox", "Maya Chen", "maya@example.net", "Alex <alex@example.com>", "Release schedule", "Ready", "The release schedule is ready for review.", "Today", true, true, true));
        cache.cache_message (new Message ("m2", "archive", "Noah Williams", "noah@example.org", "Alex <alex@example.com>", "Dinner", "Thursday", "How does Thursday sound?", "Yesterday"));
        var matches = cache.search_messages (SearchQuery.parse ("from:maya to:alex mailbox:inbox is:unread is:flagged has:attachment schedule"));
        assert (matches.size == 1); assert (matches[0].id == "m1"); assert (matches[0].flagged); assert (matches[0].has_attachment);
        cache.set_cached_flag_color ("m1", "purple");
        assert (cache.find_cached_message ("m1").flag_color == "purple");
        assert (cache.search_messages (SearchQuery.parse ("schedule"))[0].flag_color == "purple");
        assert (cache.search_messages (SearchQuery.parse ("sched")).size == 1);
        assert (cache.count_search_messages (SearchQuery.parse ("rele rev")) == 1);
        assert (cache.search_messages (SearchQuery.parse ("Thursday")).size == 1);
        assert (cache.search_messages (SearchQuery.parse ("Thurs")).size == 1);
        assert (cache.search_messages (SearchQuery.parse ("mailbox:trash")).size == 0);
        var work = cache.create_mail_label ("Work", "#ff0000");
        cache.set_message_label ("m1", work.id, true);
        assert (cache.search_messages (SearchQuery.parse ("label:work")).size == 1);
        cache.cache_message (new Message ("m1", "inbox", "Maya Chen", "maya@example.net", "Alex <alex@example.com>", "Release schedule", "Ready", "Updated body", "Today", true, true, true));
        assert (cache.labels_for_message ("m1").size == 1);
        assert (cache.find_cached_message ("m1").flag_color == "purple");
        var snapshot = new MailSyncResult ("search-account");
        var archive = new Mailbox ("search-account:opaque-folder-id", "Archive", "folder-symbolic",
            MailboxRole.ARCHIVE, 0, "search-account", "All Mail");
        snapshot.mailboxes.add (archive);
        var dated = new Message ("dated", archive.id, "Priya", "priya@example.net", "Alex <alex@example.net>",
            "Project notes", "", "Dated searchable body", "Jul 19, 2026", false, false, false, 1, false, "search-account", "44");
        dated.date_unix = new DateTime.local (2026, 7, 19, 12, 0, 0).to_unix ();
        snapshot.messages.add (dated); cache.store_sync_result (snapshot);
        assert (cache.search_messages (SearchQuery.parse ("mailbox:archive date:2026-07-19 project")).size == 1);
        assert (cache.search_messages (SearchQuery.parse ("mailbox:archive proj")).size == 1);
        assert (cache.search_messages (SearchQuery.parse ("before:2026-07-19 project")).size == 0);
        assert (cache.search_messages (SearchQuery.parse ("after:2026-07-20 project")).size == 0);
    } catch (Error caught) { GLib.error ("cached search test failed: %s", caught.message); }
    FileUtils.unlink (path);
}

private void test_mail_rules_and_labels () {
    string path = Path.build_filename (Environment.get_tmp_dir (), "mailficient-rules-%s.sqlite".printf (Uuid.string_random ())) ;
    try {
        var cache = new CacheDatabase (path); string account_id = "rules-account";
        var inbox = new Mailbox (account_id + ":inbox", "Inbox", "mail-inbox-symbolic", MailboxRole.INBOX, 1, account_id, "INBOX");
        var archive = new Mailbox (account_id + ":archive", "Archive", "package-x-generic-symbolic", MailboxRole.ARCHIVE, 0, account_id, "Archive");
        var snapshot = new MailSyncResult (account_id); snapshot.mailboxes.add (inbox); snapshot.mailboxes.add (archive);
        var message = new Message (account_id + ":inbox:1", inbox.id, "Build Bot", "build@example.net", "Alex", "Nightly report passed", "", "Body", "Now", true, false, false, 1, false, account_id, "1");
        snapshot.messages.add (message); cache.store_sync_result (snapshot);
        cache.add_mail_rule ("Read reports", "", MailRuleField.SUBJECT, "report", MailRuleAction.MARK_READ);
        cache.add_mail_rule ("Label reports", "", MailRuleField.SENDER, "build@", MailRuleAction.LABEL, "Automation");
        cache.add_mail_rule ("File reports", account_id, MailRuleField.SUBJECT, "nightly", MailRuleAction.ARCHIVE);
        assert (new MailRuleService (cache).apply (snapshot) == 3);
        var updated = cache.find_cached_message (message.id); assert (updated != null); assert (!updated.unread);
        assert (updated.mailbox_id == archive.id); assert (cache.pending_transfer_count () == 1);
        assert (cache.labels_for_message (message.id).size == 1);
        assert (cache.search_messages (SearchQuery.parse ("label:automation")).size == 1);
        var rules = cache.list_mail_rules (); assert (rules.size == 3);
        cache.remove_mail_rule (rules[0].id); assert (cache.list_mail_rules ().size == 2);
    } catch (Error error) { GLib.error ("mail rules/labels test failed: %s", error.message); }
    FileUtils.unlink (path);
}

private void test_scheduling_snooze_and_templates () {
    string path = Path.build_filename (Environment.get_tmp_dir (), "mailficient-time-features-%s.sqlite".printf (Uuid.string_random ())) ;
    try {
        var cache = new CacheDatabase (path); string account_id = "time-account";
        var account = AccountSettings.for_email ("Alex", "alex@example.net"); account.id = account_id;
        account.incoming_host = "imap.example.net"; account.outgoing_host = "smtp.example.net"; cache.save_account (account);
        var inbox = new Mailbox (account_id + ":inbox", "Inbox", "mail-inbox-symbolic", MailboxRole.INBOX, 1, account_id, "INBOX");
        var snapshot = new MailSyncResult (account_id); snapshot.mailboxes.add (inbox);
        var message = new Message (account_id + ":inbox:1", inbox.id, "Maya", "maya@example.net", account.email,
            "Later", "", "Body", "Now", true, false, false, 1, false, account_id, "1");
        snapshot.messages.add (message); cache.store_sync_result (snapshot);
        int64 tomorrow = new DateTime.now_utc ().add_days (1).to_unix ();
        cache.snooze_message (message.id, tomorrow);
        assert (cache.message_is_snoozed (message.id));
        assert (cache.list_cached_messages ("unified-inbox").size == 0);
        assert (cache.list_cached_messages ("unified-snoozed").size == 1);
        cache.unsnooze_message (message.id); assert (cache.list_cached_messages ("unified-inbox").size == 1);

        var draft = new Draft (account_id); draft.to = "maya@example.net"; draft.subject = "Scheduled"; draft.body_text = "Later body";
        cache.queue_for_sending (draft, tomorrow);
        assert (cache.list_pending_sends (account_id, true).size == 0);
        assert (cache.list_pending_sends (account_id, false).size == 1);
        var saved = cache.save_mail_template ("Status", draft); assert (saved.name == "Status");
        assert (cache.list_mail_templates ().size == 1);
        draft.subject = "Updated"; cache.save_mail_template ("Status", draft);
        assert (cache.list_mail_templates ()[0].subject == "Updated");
        cache.delete_mail_template (saved.id); assert (cache.list_mail_templates ().size == 0);
    } catch (Error error) { GLib.error ("time feature test failed: %s", error.message); }
    FileUtils.unlink (path);
}

private async void exercise_vacation_responder () throws Error {
    string root = Path.build_filename (Environment.get_tmp_dir (), "mailficient-vacation-%s".printf (Uuid.string_random ())) ;
    DirUtils.create_with_parents (root, 0700); var cache = new CacheDatabase (Path.build_filename (root, "mail.sqlite"));
    var account = AccountSettings.for_email ("Alex", "alex@example.net"); account.id = "vacation-account";
    account.incoming_host = "imap.example.net"; account.outgoing_host = "smtp.example.net"; cache.save_account (account);
    var settings = new VacationSettings (account.id, true, 0, 0, "Away", "I am away."); cache.save_vacation_settings (settings);
    var inbox = new Mailbox (account.id + ":inbox", "Inbox", "mail-inbox-symbolic", MailboxRole.INBOX, 1, account.id, "INBOX");
    var snapshot = new MailSyncResult (account.id); snapshot.mailboxes.add (inbox);
    snapshot.messages.add (new Message (account.id + ":inbox:1", inbox.id, "Maya", "maya@example.net", account.email,
        "Question", "", "Hello", "Now", true, false, false, 1, false, account.id, "1"));
    var engine = new RecordingMailEngine (account.id); var attachments = new AttachmentService (Path.build_filename (root, "attachments"));
    var responder = new VacationResponderService (cache, new OutboundService (cache, engine, attachments));
    assert ((yield responder.respond (snapshot)) == 1); assert (engine.send_calls == 1);
    assert (cache.vacation_replied_to (account.id, "maya@example.net"));
    assert ((yield responder.respond (snapshot)) == 0); assert (engine.send_calls == 1);
}

private void test_vacation_responder () {
    var loop = new MainLoop (); Error? failure = null;
    exercise_vacation_responder.begin ((object, result) => {
        try { exercise_vacation_responder.end (result); } catch (Error error) { failure = error; }
        loop.quit ();
    }); loop.run (); if (failure != null) GLib.error ("vacation responder test failed: %s", failure.message);
}

private void test_message_export () {
    string root = Path.build_filename (Environment.get_tmp_dir (), "mailficient-export-%s".printf (Uuid.string_random ())) ;
    try {
        DirUtils.create_with_parents (root, 0700); string attachment_path = Path.build_filename (root, "note.txt");
        FileUtils.set_contents (attachment_path, "attachment bytes");
        var message = new Message ("export-1", "inbox", "Maya", "maya@example.net", "Alex <alex@example.net>",
            "Export subject", "", "Hello export", "Today", false, false, true);
        message.add_attachment (new Attachment ("a1", attachment_path, "note.txt", 16, "text/plain"));
        var service = new MessageExportService (); string eml_path = Path.build_filename (root, "message.eml");
        service.export_eml (message, File.new_for_path (eml_path)); string eml; FileUtils.get_contents (eml_path, out eml);
        assert (eml.contains ("Subject: Export subject")); assert (eml.contains ("multipart/mixed"));
        assert (eml.contains (Base64.encode ("attachment bytes".data)));
        var demo = new DemoMailRepository ();
        string mbox_path = Path.build_filename (root, "inbox.mbox");
        service.export_mbox (demo, demo.list_mailboxes ()[0], File.new_for_path (mbox_path));
        string mbox; FileUtils.get_contents (mbox_path, out mbox);
        assert (mbox.has_prefix ("From "));
        assert (mbox.contains ("\nSubject: "));
        string pdf_path = Path.build_filename (root, "message.pdf"); service.export_pdf (message, File.new_for_path (pdf_path));
        uint8[] prefix = new uint8[5]; var input = File.new_for_path (pdf_path).read (); assert (input.read (prefix) == 5);
        assert ((char) prefix[0] == '%' && (char) prefix[1] == 'P' && (char) prefix[2] == 'D' && (char) prefix[3] == 'F');
    } catch (Error error) { GLib.error ("message export test failed: %s", error.message); }
}

private void test_sanitizer () {
    var result = HtmlSanitizer.sanitize ("<p onclick=\"steal()\">Hello</p><script>alert(1)</script><img src=\"https://tracker.test/pixel\">");
    assert (!result.contains ("script"));
    assert (!result.contains ("onclick"));
    assert (!result.contains ("tracker.test"));
    var allowed = HtmlSanitizer.sanitize ("<img src=\"https://images.example.net/photo.jpg\"><script>bad()</script>", true);
    assert (allowed.contains ("images.example.net")); assert (!allowed.contains ("script"));
    var hostile = HtmlSanitizer.sanitize ("<iframe src='https://tracker.test'></iframe><form action='https://bad.test'><input></form><p onmouseover=steal() style='background:url(https://pixel.test)'>Safe</p><a href='javascript:steal()'>click</a>");
    assert (!hostile.down ().contains ("iframe")); assert (!hostile.down ().contains ("form"));
    assert (!hostile.down ().contains ("onmouseover")); assert (!hostile.down ().contains ("pixel.test")); assert (!hostile.down ().contains ("javascript:"));

    string full_text = HtmlSanitizer.to_plain_text (
        "<html><head><title>Ignore me</title><script>bad()</script></head><body>" +
        "<p>Hello &amp; welcome.</p><p>This second paragraph must not be lost.</p>" +
        "<ul><li>First item</li><li>Second item</li></ul><img alt='Status chart' src='https://tracker.test/chart'></body></html>");
    assert (full_text.contains ("Hello & welcome."));
    assert (full_text.contains ("This second paragraph must not be lost."));
    assert (full_text.contains ("• First item"));
    assert (full_text.contains ("• Second item"));
    assert (full_text.contains ("[Status chart]"));
    assert (!full_text.contains ("Ignore me")); assert (!full_text.contains ("bad()"));
}

private void test_sanitizer_adversarial () {
    string hostile = "<!doctype html><html><head><base href='https://tracker.test/'><meta http-equiv='refresh' content='0;url=https://bad.test'></head>" +
        "<body><SCRIPT SRC=https://bad.test/payload.js>alert(1)</SCRIPT>" +
        "<img src=https://tracker.test/unquoted srcset='https://tracker.test/2x 2x' onerror=steal()>" +
        "<a href='java&#x73;cript:steal()'>encoded</a><a href='  JAVASCRIPT:steal()'>spaced</a>" +
        "<svg><script>alert(2)</script><a href='https://bad.test'>svg</a></svg>" +
        "<div style='background:url(https://pixel.test)' formaction=https://bad.test>Readable text</div>" +
        "<img src='data:image/svg+xml;base64,PHN2Zz48c2NyaXB0Pg=='>" +
        "<img src='file:///etc/passwd'><iframe srcdoc='<script>bad()</script>'></iframe></body></html>";
    string safe = HtmlSanitizer.sanitize (hostile);
    string lower = safe.down ();
    assert (safe.contains ("Readable text"));
    assert (!lower.contains ("script")); assert (!lower.contains ("iframe"));
    assert (!lower.contains ("svg")); assert (!lower.contains ("onerror"));
    assert (!lower.contains ("style=")); assert (!lower.contains ("srcset"));
    assert (!lower.contains ("tracker.test")); assert (!lower.contains ("pixel.test"));
    assert (!lower.contains ("javascript:")); assert (!lower.contains ("file:"));
    assert (!lower.contains ("data:image/svg")); assert (!lower.contains ("<meta"));
}

private void test_sanitizer_preserves_safe_mail () {
    string mail = "<h2>Project update</h2><table width='100%' cellpadding='6' style='color:red'>" +
        "<tr><th align='left'>Item</th><th>Owner</th></tr><tr><td colspan='2'>Ready &amp; reviewed</td></tr></table>" +
        "<blockquote><strong>Previous message</strong></blockquote>" +
        "<a href='https://example.net/details' onclick='bad()'>Details</a>" +
        "<img alt='Chart' width='640' src='cid:chart@example.net'>";
    string safe = HtmlSanitizer.sanitize (mail);
    assert (safe.contains ("<h2>Project update</h2>")); assert (safe.contains ("<table"));
    assert (safe.contains ("width=\"100%\"")); assert (safe.contains ("cellpadding=\"6\""));
    assert (safe.contains ("Ready &amp; reviewed")); assert (safe.contains ("<blockquote>"));
    assert (safe.contains ("href=\"https://example.net/details\""));
    assert (safe.contains ("rel=\"noreferrer noopener\""));
    assert (safe.contains ("src=\"cid:chart@example.net\""));
    assert (!safe.contains ("onclick")); assert (!safe.contains ("style="));

    string blocked = HtmlSanitizer.sanitize ("<img src='https://images.example.net/chart.png'>");
    string loaded = HtmlSanitizer.sanitize ("<img src='https://images.example.net/chart.png'>", true);
    assert (!blocked.contains ("images.example.net")); assert (blocked.contains ("about:blank"));
    assert (loaded.contains ("https://images.example.net/chart.png"));

    string formatted = HtmlSanitizer.sanitize (
        "<title>Hidden preview title</title><style>.hero > span{color:#245}</style>" +
        "<div class='hero' style='text-align:center'>Readable</div>" +
        "<script>bad()</script><iframe src='https://evil.test'></iframe>", false, true);
    assert (formatted.contains ("<style>.hero > span{color:#245}</style>"));
    assert (formatted.contains ("class=\"hero\""));
    assert (formatted.contains ("style=\"text-align:center\""));
    assert (!formatted.contains ("Hidden preview title"));
    assert (!formatted.contains ("bad()"));
    assert (!formatted.contains ("evil.test"));
}

private void test_html_content_policy () {
    string blocked = HtmlContentPolicy.document ("<p>Safe</p>", false);
    assert (blocked.contains ("default-src 'none'")); assert (blocked.contains ("script-src 'none'"));
    assert (blocked.contains ("form-action 'none'")); assert (blocked.contains ("img-src data: cid:"));
    assert (!blocked.contains ("img-src data: cid: https:"));
    assert (blocked.contains ("name='viewport'"));
    assert (blocked.contains ("background:#fff"));
    assert (blocked.contains ("color-scheme:light"));
    assert (blocked.contains ("max-width:100%!important"));
    assert (blocked.contains ("overflow-wrap:anywhere"));
    assert (blocked.contains ("@media print"));
    string printable = HtmlContentPolicy.document ("<p>Safe</p>", false,
        "<section class='mailficient-print-header'>Header</section>");
    assert (printable.contains ("mailficient-print-header"));
    assert (printable.contains ("Header"));
    string enabled = HtmlContentPolicy.document ("<p>Safe</p>", true);
    assert (enabled.contains ("img-src data: cid: https: http:"));

    assert (HtmlContentPolicy.allows_resource ("about:blank", false));
    assert (HtmlContentPolicy.allows_resource ("cid:logo@example.net", false));
    assert (HtmlContentPolicy.allows_resource ("data:image/png;base64,iVBORw0KGgo=", false));
    assert (!HtmlContentPolicy.allows_resource ("data:image/svg+xml,<svg/>", false));
    assert (!HtmlContentPolicy.allows_resource ("file:///etc/passwd", true));
    assert (!HtmlContentPolicy.allows_resource ("javascript:alert(1)", true));
    assert (!HtmlContentPolicy.allows_resource ("https://tracker.test/pixel", false));
    assert (HtmlContentPolicy.allows_resource ("https://images.example.net/photo", true));
}

private void test_inline_content_resolver () {
    string root = Path.build_filename (Environment.get_tmp_dir (),
        "mailficient-inline-%s".printf (Uuid.string_random ()));
    string image_path = Path.build_filename (root, "logo.png");
    string fake_path = Path.build_filename (root, "fake.png");
    try {
        assert (DirUtils.create_with_parents (root, 0700) == 0);
        uint8[] png = Base64.decode ("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=");
        var output = File.new_for_path (image_path).replace (null, false, FileCreateFlags.PRIVATE);
        size_t written; output.write_all (png, out written); output.close (); assert (written == png.length);
        assert (FileUtils.set_contents (fake_path, "<script>alert(1)</script>"));

        var attachments = new Gee.ArrayList<Attachment> ();
        attachments.add (new Attachment ("inline-logo", image_path, "logo.png", png.length,
            "image/png", "<logo@example.net>"));
        string safe = HtmlSanitizer.sanitize ("<p>Logo</p><img alt='Company logo' src='cid:logo@example.net'>");
        string resolved = InlineContentResolver.resolve (safe, attachments);
        assert (resolved.contains ("src=\"data:image/png;base64,"));
        assert (!resolved.contains ("cid:logo@example.net"));
        assert (resolved.contains ("alt=\"Company logo\""));

        var hostile = new Gee.ArrayList<Attachment> ();
        hostile.add (new Attachment ("fake", fake_path, "fake.png", 25, "image/png", "fake@example.net"));
        string unresolved = InlineContentResolver.resolve (
            HtmlSanitizer.sanitize ("<img src='cid:fake@example.net'>"), hostile);
        assert (unresolved.contains ("cid:fake@example.net"));
        assert (!unresolved.contains ("data:image/png"));
    } catch (Error error) { GLib.error ("inline content resolver test failed: %s", error.message); }
    FileUtils.unlink (image_path); FileUtils.unlink (fake_path); DirUtils.remove (root);
}

private void test_filename () {
    assert (AttachmentSafety.safe_filename ("../../invoice.pdf") == "_.._invoice.pdf");
    assert (AttachmentSafety.safe_filename ("..") == "attachment");
    assert (AttachmentSafety.safe_filename ("notes.txt") == "notes.txt");
    assert (AttachmentSafety.preview_kind ("image/png", "photo.png") == AttachmentPreviewKind.IMAGE);
    assert (AttachmentSafety.preview_kind ("application/pdf", "report.pdf") == AttachmentPreviewKind.PDF);
    assert (AttachmentSafety.preview_kind ("text/plain; charset=utf-8", "notes.txt") == AttachmentPreviewKind.TEXT);
    assert (AttachmentSafety.preview_kind ("text/html", "message.html") == AttachmentPreviewKind.NONE);
    assert (AttachmentSafety.preview_kind ("image/svg+xml", "drawing.svg") == AttachmentPreviewKind.NONE);
    assert (AttachmentSafety.preview_kind ("application/pdf", "report.exe") == AttachmentPreviewKind.NONE);
    uint8[] pdf = { '%', 'P', 'D', 'F', '-', '1', '.', '7' };
    uint8[] fake_pdf = { 'M', 'Z', 0x90, 0x00 };
    uint8[] png = { 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a };
    uint8[] fake_png = { '<', 's', 'v', 'g', '>' };
    uint8[] text = { 'h', 'e', 'l', 'l', 'o' };
    uint8[] binary_text = { 'h', 'i', 0x00, 'x' };
    assert (AttachmentSafety.preview_signature_matches (AttachmentPreviewKind.PDF,
        "application/pdf", pdf, pdf.length));
    assert (!AttachmentSafety.preview_signature_matches (AttachmentPreviewKind.PDF,
        "application/pdf", fake_pdf, fake_pdf.length));
    assert (AttachmentSafety.preview_signature_matches (AttachmentPreviewKind.IMAGE,
        "image/png", png, png.length));
    assert (!AttachmentSafety.preview_signature_matches (AttachmentPreviewKind.IMAGE,
        "image/png", fake_png, fake_png.length));
    assert (AttachmentSafety.preview_signature_matches (AttachmentPreviewKind.TEXT,
        "text/plain", text, text.length));
    assert (!AttachmentSafety.preview_signature_matches (AttachmentPreviewKind.TEXT,
        "text/plain", binary_text, binary_text.length));
    assert (new Attachment ("calendar", "/unused", "meeting.ics", 100,
        "application/octet-stream").is_calendar_invitation ());
    assert (new Attachment ("calendar-mime", "/unused", "invite", 100,
        "text/calendar; method=REQUEST").is_calendar_invitation ());
    assert (!new Attachment ("not-calendar", "/unused", "notes.txt", 100,
        "text/plain").is_calendar_invitation ());
}

private void test_attachment_import () {
    string root = Path.build_filename (Environment.get_tmp_dir (), "mailficient-attachments-%s".printf (Uuid.string_random ()));
    string source_path = Path.build_filename (root, "source", "quarterly report.txt");
    var loop = new MainLoop (); Attachment? imported = null; Error? failure = null;
    try {
        assert (DirUtils.create_with_parents (Path.get_dirname (source_path), 0700) == 0);
        FileUtils.set_contents (source_path, "private attachment body");
        var service = new AttachmentService (Path.build_filename (root, "private"));
        service.import_file.begin (File.new_for_path (source_path), null, (object, result) => {
            try { imported = service.import_file.end (result); } catch (Error error) { failure = error; }
            loop.quit ();
        });
        loop.run ();
        assert (failure == null); assert (imported != null);
        assert (imported.name == "quarterly report.txt"); assert (imported.size == 23);
        assert (imported.path != source_path); assert (FileUtils.test (imported.path, FileTest.IS_REGULAR));
        string exported_path = Path.build_filename (root, "exported.txt"); failure = null;
        service.save_received.begin (imported, File.new_for_path (exported_path), null, (object, result) => {
            try { service.save_received.end (result); } catch (Error error) { failure = error; }
            loop.quit ();
        });
        loop.run (); assert (failure == null);
        string exported_contents; FileUtils.get_contents (exported_path, out exported_contents);
        assert (exported_contents == "private attachment body");
        service.remove_private_copy (imported); assert (!FileUtils.test (imported.path, FileTest.EXISTS));
    } catch (Error error) { GLib.error ("attachment import test failed: %s", error.message); }
}

private async void exercise_remote_attachment_download () throws Error {
    string root = Path.build_filename (Environment.get_tmp_dir (),
        "mailficient-remote-attachment-%s".printf (Uuid.string_random ()));
    assert (DirUtils.create_with_parents (root, 0700) == 0);
    string database_path = Path.build_filename (root, "mail.db");
    var cache = new CacheDatabase (database_path);
    var account = AccountSettings.for_email ("Alex", "alex@example.net");
    account.id = "attachment-account";
    account.incoming_host = "imap.example.net"; account.outgoing_host = "smtp.example.net";
    cache.save_account (account);
    var snapshot = new MailSyncResult (account.id);
    var inbox = new Mailbox ("attachment-account:inbox", "Inbox", "mail-inbox-symbolic",
        MailboxRole.INBOX, 0, account.id, "INBOX");
    snapshot.mailboxes.add (inbox);
    var message = new Message ("attachment-account:inbox:44", inbox.id, "Maya", "maya@example.net",
        account.email, "Large report", "Report attached", "See attachment", "Today", false,
        false, true, 1, false, account.id, "44");
    message.add_attachment (new Attachment ("remote-report", "", "report.pdf", 75 * 1024 * 1024,
        "application/pdf", "", 2));
    snapshot.messages.add (message); cache.store_sync_result (snapshot);

    var loaded = cache.find_cached_message (message.id);
    assert (loaded != null); assert (loaded.attachments.size == 1);
    assert (!loaded.attachments[0].is_downloaded ());
    assert (loaded.attachments[0].remote_part_index == 2);
    assert (cache.remote_mailbox_for_message (message.id) == "INBOX");

    var engine = new RecordingMailEngine (account.id);
    var local = new AttachmentService (Path.build_filename (root, "draft-attachments"));
    var service = new ReceivedAttachmentService (cache, local, engine);
    string destination_path = Path.build_filename (root, "saved-report.pdf");
    yield service.save (loaded, loaded.attachments[0], File.new_for_path (destination_path));
    string contents; assert (FileUtils.get_contents (destination_path, out contents));
    assert (contents == "downloaded attachment");
    assert (engine.remote_attachment_calls == 1);
    assert (engine.operations.contains ("attachment:INBOX:44:2"));

    var remote_small = new Attachment ("remote-small", "", "notes.txt", 21,
        "text/plain", "", 3);
    var forwarded = yield service.copy_for_draft (loaded, remote_small);
    assert (forwarded.is_downloaded ());
    assert (forwarded.path != engine.last_remote_attachment_destination);
    assert (!FileUtils.test (engine.last_remote_attachment_destination, FileTest.EXISTS));
    assert (engine.last_remote_attachment_maximum == AttachmentService.MAX_ATTACHMENT_SIZE);
    assert (engine.operations.contains ("attachment:INBOX:44:3"));
    assert (FileUtils.get_contents (forwarded.path, out contents));
    assert (contents == "downloaded attachment");
    local.remove_private_copy (forwarded);

    Error? oversized_error = null;
    try { yield service.copy_for_draft (loaded, loaded.attachments[0]); }
    catch (Error error) { oversized_error = error; }
    assert (oversized_error is MailError.ATTACHMENT);
    assert (engine.remote_attachment_calls == 2);

    string local_calendar_path = Path.build_filename (root, "meeting.ics");
    string calendar_contents = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nEND:VCALENDAR\r\n";
    FileUtils.set_contents (local_calendar_path, calendar_contents);
    var local_calendar = new Attachment ("local-calendar", local_calendar_path,
        "meeting.ics", calendar_contents.length, "application/octet-stream");
    var staged_local = yield service.stage_calendar_invitation (loaded, local_calendar);
    assert (staged_local.get_path () != local_calendar_path);
    assert (staged_local.get_basename ().has_suffix (".ics"));
    assert (FileUtils.get_contents (staged_local.get_path (), out contents));
    assert (contents == calendar_contents);
    staged_local.delete (null);

    var remote_calendar = new Attachment ("remote-calendar", "", "meeting.ics", 128,
        "text/calendar; method=REQUEST", "", 4);
    var staged_remote = yield service.stage_calendar_invitation (loaded, remote_calendar);
    assert (engine.remote_attachment_calls == 3);
    assert (engine.last_remote_attachment_maximum ==
        ReceivedAttachmentService.MAX_CALENDAR_INVITATION_BYTES);
    assert (FileUtils.get_contents (staged_remote.get_path (), out contents));
    assert (contents == "downloaded attachment");
    staged_remote.delete (null);

    var oversized_calendar = new Attachment ("oversized-calendar", "", "huge.ics",
        ReceivedAttachmentService.MAX_CALENDAR_INVITATION_BYTES + 1, "text/calendar", "", 5);
    oversized_error = null;
    try { yield service.stage_calendar_invitation (loaded, oversized_calendar); }
    catch (Error error) { oversized_error = error; }
    assert (oversized_error is MailError.ATTACHMENT);
    assert (engine.remote_attachment_calls == 3);
}

private void test_remote_attachment_download () {
    var loop = new MainLoop (); Error? failure = null;
    exercise_remote_attachment_download.begin ((object, result) => {
        try { exercise_remote_attachment_download.end (result); }
        catch (Error error) { failure = error; }
        loop.quit ();
    });
    loop.run ();
    if (failure != null) GLib.error ("remote attachment download test failed: %s", failure.message);
}

private void test_forward_attachment_copy_is_private () {
    string root = Path.build_filename (Environment.get_tmp_dir (), "mailficient-forward-attachment-%s".printf (Uuid.string_random ()));
    string source_path = Path.build_filename (root, "received", "agenda.txt");
    var loop = new MainLoop (); Attachment? copied = null; Error? failure = null;
    try {
        assert (DirUtils.create_with_parents (Path.get_dirname (source_path), 0700) == 0);
        FileUtils.set_contents (source_path, "forwarded source");
        var source = new Attachment ("received-1", source_path, "agenda.txt", 16, "text/plain");
        var service = new AttachmentService (Path.build_filename (root, "drafts"));
        service.copy_received_for_draft.begin (source, null, (object, result) => {
            try { copied = service.copy_received_for_draft.end (result); }
            catch (Error error) { failure = error; }
            loop.quit ();
        });
        loop.run ();
        assert (failure == null); assert (copied != null);
        assert (copied.path != source.path); assert (copied.name == source.name);
        string contents; FileUtils.get_contents (copied.path, out contents); assert (contents == "forwarded source");
        service.remove_private_copy (copied);
        assert (FileUtils.test (source.path, FileTest.IS_REGULAR));
    } catch (Error error) { GLib.error ("forward attachment copy test failed: %s", error.message); }
}

private void test_draft_discard_is_database_first () {
    string root = Path.build_filename (Environment.get_tmp_dir (),
        "mailficient-draft-discard-%s".printf (Uuid.string_random ())) ;
    try {
        assert (DirUtils.create_with_parents (root, 0700) == 0);
        string database_path = Path.build_filename (root, "mail.sqlite");
        string private_dir = Path.build_filename (root, "attachments");
        string source_path = Path.build_filename (root, "source.txt");
        assert (FileUtils.set_contents (source_path, "private draft attachment"));
        var cache = new CacheDatabase (database_path);
        var attachments = new AttachmentService (private_dir);
        Attachment? imported = null; Error? import_error = null; var loop = new MainLoop ();
        attachments.import_file.begin (File.new_for_path (source_path), null, (object, result) => {
            try { imported = attachments.import_file.end (result); }
            catch (Error error) { import_error = error; }
            loop.quit ();
        });
        loop.run (); assert (import_error == null); assert (imported != null);
        var draft = new Draft ("discard-account"); draft.to = "maya@example.net";
        draft.body_text = "Do not partially discard"; draft.add_attachment (imported);
        cache.save_draft (draft);
        var lifecycle = new DraftLifecycleService (cache, attachments);

        Sqlite.Database injector; assert (Sqlite.Database.open (database_path, out injector) == Sqlite.OK);
        string? detail = null;
        assert (injector.exec ("CREATE TRIGGER block_draft_delete BEFORE DELETE ON drafts " +
            "BEGIN SELECT RAISE(ABORT,'simulated draft delete failure'); END", null, out detail) == Sqlite.OK);
        Error? discard_error = null;
        try { lifecycle.discard (draft); } catch (Error error) { discard_error = error; }
        assert (discard_error is MailError.STORAGE);
        assert (cache.load_draft (draft.id) != null);
        assert (FileUtils.test (imported.path, FileTest.IS_REGULAR));

        assert (injector.exec ("DROP TRIGGER block_draft_delete", null, out detail) == Sqlite.OK);
        lifecycle.discard (draft);
        assert (cache.load_draft (draft.id) == null);
        assert (!FileUtils.test (imported.path, FileTest.EXISTS));

        var scheduled = new Draft ("discard-account");
        scheduled.to = "maya@example.net"; scheduled.body_text = "Delete from Outbox";
        cache.queue_for_sending (scheduled, new DateTime.now_utc ().add_days (1).to_unix ());
        assert (cache.outbox_count () == 1);
        lifecycle.discard (scheduled);
        assert (cache.outbox_count () == 0);
        assert (cache.load_draft (scheduled.id) == null);

        string outside = Path.build_filename (root, "outside.txt");
        assert (FileUtils.set_contents (outside, "must survive corrupt metadata"));
        Error? unsafe_error = null;
        try { attachments.remove_private_copy (new Attachment (
            "outside", outside, "outside.txt", 28, "text/plain")); }
        catch (Error error) { unsafe_error = error; }
        assert (unsafe_error is MailError.ATTACHMENT);
        assert (FileUtils.test (outside, FileTest.IS_REGULAR));
    } catch (Error error) { GLib.error ("draft discard lifecycle test failed: %s", error.message); }
}

private void test_cancelled_attachment_import_leaves_no_copy () {
    string root = Path.build_filename (Environment.get_tmp_dir (), "mailficient-attachment-cancel-%s".printf (Uuid.string_random ()));
    string source_path = Path.build_filename (root, "source.txt");
    try {
        assert (DirUtils.create_with_parents (root, 0700) == 0);
        FileUtils.set_contents (source_path, "cancel me");
        string private_dir = Path.build_filename (root, "private");
        var service = new AttachmentService (private_dir); var cancellable = new Cancellable (); cancellable.cancel ();
        Error? failure = null; var loop = new MainLoop ();
        service.import_file.begin (File.new_for_path (source_path), cancellable, (object, result) => {
            try { service.import_file.end (result); } catch (Error error) { failure = error; }
            loop.quit ();
        });
        loop.run (); assert (failure is IOError.CANCELLED);
        var directory = Dir.open (private_dir); assert (directory.read_name () == null);
    } catch (Error error) { GLib.error ("cancelled attachment import test failed: %s", error.message); }
}

private void test_message_initials () {
    var message = new Message ("1", "inbox", "Maya Chen", "m@example.net", "a@example.net", "Hi", "Preview", "Body", "Today");
    assert (message.initials () == "MC");
}

private void test_message_sorting () {
    var messages = new Gee.ArrayList<Message> ();
    messages.add (new Message ("new", "inbox", "Zoe", "z@example.net", "a@example.net", "Re: Alpha", "", "", "Today", false, false));
    messages.add (new Message ("old", "inbox", "Alex", "a@example.net", "z@example.net", "Beta", "", "", "Yesterday", true, true));
    var sorter = new MessageSorter ();
    assert (sorter.sort (messages, MessageSortMode.NEWEST)[0].id == "new");
    assert (sorter.sort (messages, MessageSortMode.OLDEST)[0].id == "old");
    assert (sorter.sort (messages, MessageSortMode.SENDER)[0].sender_name == "Alex");
    assert (sorter.sort (messages, MessageSortMode.SUBJECT)[0].subject == "Re: Alpha");
    assert (sorter.sort (messages, MessageSortMode.UNREAD_FIRST)[0].unread);
    assert (sorter.sort (messages, MessageSortMode.FLAGGED_FIRST)[0].flagged);
}

private void test_conversation_builder () {
    var root = new Message ("root", "sent", "Alex", "alex@example.net", "Maya <maya@example.net>", "Project", "", "Root", "Monday",
        false, false, false, 1, false, "account", "1", "<root@example.net>");
    var reply = new Message ("reply", "inbox", "Maya", "maya@example.net", "Alex <alex@example.net>", "Re: Project", "", "Reply", "Tuesday",
        false, false, false, 1, false, "account", "2", "<reply@example.net>", "<root@example.net>", "<root@example.net>");
    var final_message = new Message ("final", "inbox", "Alex", "alex@example.net", "Maya <maya@example.net>", "Re: Project", "", "Final", "Wednesday",
        false, false, false, 1, false, "account", "3", "<final@example.net>", "<reply@example.net>", "<root@example.net> <reply@example.net>");
    var unrelated = new Message ("other", "inbox", "Maya", "maya@example.net", "Alex <alex@example.net>", "Another topic", "", "Other", "Today",
        false, false, false, 1, false, "account", "4", "<other@example.net>");
    var same_sender_and_subject = new Message ("same-sender", "inbox", "Alex", "alex@example.net",
        "Maya <maya@example.net>", "Re: Project", "", "Separate message", "Thursday",
        false, false, false, 1, false, "account", "5");
    var reused_message_id = new Message ("reused-id", "inbox", "Maya", "maya@example.net",
        "Alex <alex@example.net>", "Project promotion", "", "Independent bulk message", "Friday",
        false, false, false, 1, false, "account", "6", "<final@example.net>");
    var candidates = new Gee.ArrayList<Message> ();
    candidates.add (final_message); candidates.add (unrelated); candidates.add (reply);
    candidates.add (root); candidates.add (same_sender_and_subject); candidates.add (reused_message_id);
    var thread = new ConversationBuilder ().build (candidates, final_message);
    assert (thread.size == 3); assert (thread[0].id == "root"); assert (thread[2].id == "final");
    var standalone = new ConversationBuilder ().build (candidates, same_sender_and_subject);
    assert (standalone.size == 1); assert (standalone[0].id == "same-sender");
    var reused_standalone = new ConversationBuilder ().build (candidates, reused_message_id);
    assert (reused_standalone.size == 1); assert (reused_standalone[0].id == "reused-id");
}

private void test_account_validation () {
    var settings = AccountSettings.for_email ("Alex Morgan", "alex@gmail.com");
    assert (settings.incoming_host == "imap.gmail.com");
    assert (settings.outgoing_host == "smtp.gmail.com");
    try { settings.validate (); } catch (Error error) { assert_not_reached (); }
    settings.incoming_port = 0;
    try { settings.validate (); assert_not_reached (); } catch (MailError error) { assert (error is MailError.INVALID_ACCOUNT); }

    var icloud = AccountSettings.for_email ("Alex", "alex@icloud.com");
    assert (icloud.incoming_host == "imap.mail.me.com");
    assert (icloud.incoming_username == "alex");
    assert (icloud.outgoing_host == "smtp.mail.me.com");
    assert (icloud.outgoing_port == 587);
    assert (icloud.outgoing_encryption == EncryptionMode.STARTTLS);

    var yahoo = AccountSettings.for_email ("Alex", "alex@yahoo.com");
    assert (yahoo.incoming_host == "imap.mail.yahoo.com");
    assert (yahoo.outgoing_host == "smtp.mail.yahoo.com");
    assert (yahoo.outgoing_port == 465);

    var aol = AccountSettings.for_email ("Alex", "alex@aol.com");
    assert (aol.incoming_host == "imap.aol.com");
    assert (aol.outgoing_host == "smtp.aol.com");

    var microsoft = AccountSettings.for_provider (
        MailProvider.MICROSOFT, "Alex", "alex@business.example");
    assert (microsoft.incoming_host == "outlook.office365.com");
    assert (microsoft.outgoing_host == "smtp.office365.com");
    assert (microsoft.outgoing_encryption == EncryptionMode.STARTTLS);
}

private void test_mobileconfig_import () {
    string profile = """<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>PayloadContent</key><array><dict>
<key>PayloadType</key><string>com.apple.mail.managed</string>
<key>EmailAccountType</key><string>EmailTypeIMAP</string>
<key>EmailAccountName</key><string>Profile User</string>
<key>EmailAddress</key><string>profile@example.net</string>
<key>IncomingMailServerAuthentication</key><string>EmailAuthPassword</string>
<key>IncomingMailServerHostName</key><string>imap.example.net</string>
<key>IncomingMailServerPortNumber</key><integer>993</integer>
<key>IncomingMailServerUseSSL</key><true/>
<key>IncomingMailServerUsername</key><string>profile@example.net</string>
<key>IncomingMailServerPassword</key><string>candidate-secret</string>
<key>OutgoingMailServerAuthentication</key><string>EmailAuthPassword</string>
<key>OutgoingMailServerHostName</key><string>smtp.example.net</string>
<key>OutgoingMailServerPortNumber</key><integer>587</integer>
<key>OutgoingMailServerUseSSL</key><false/>
<key>OutgoingMailServerUsername</key><string>profile@example.net</string>
<key>OutgoingPasswordSameAsIncomingPassword</key><true/>
</dict></array></dict></plist>""";
    try {
        var imported = MobileConfigImporter.parse ((uint8[]) profile.data);
        assert (imported.size == 1);
        var account = imported[0];
        assert (account.settings.display_name == "Profile User");
        assert (account.settings.email == "profile@example.net");
        assert (account.settings.incoming_host == "imap.example.net");
        assert (account.settings.incoming_port == 993);
        assert (account.settings.incoming_encryption == EncryptionMode.TLS);
        assert (account.settings.outgoing_host == "smtp.example.net");
        assert (account.settings.outgoing_port == 587);
        assert (account.settings.outgoing_encryption == EncryptionMode.STARTTLS);
        assert (account.incoming_password == "candidate-secret");
        assert (account.outgoing_password == "candidate-secret");
    } catch (Error error) { GLib.error ("mobileconfig import test failed: %s", error.message); }
}

private void test_signed_mobileconfig_fixture () {
    string? path = Environment.get_variable ("MAILFICIENT_TEST_MOBILECONFIG");
    if (path == null || path == "") {
        Test.skip ("Set MAILFICIENT_TEST_MOBILECONFIG to exercise a signed profile fixture");
        return;
    }
    try {
        uint8[] contents;
        FileUtils.get_data (path, out contents);
        var imported = MobileConfigImporter.parse (contents);
        assert (imported.size > 0);
        foreach (var account in imported) account.settings.validate ();
    } catch (Error error) { GLib.error ("signed mobileconfig fixture failed: %s", error.message); }
}

private Variant test_goa_interfaces (bool smtp_xoauth2 = true) {
    var account = new VariantBuilder (new VariantType ("a{sv}"));
    account.add ("{sv}", "ProviderName", new Variant.string ("Google"));
    account.add ("{sv}", "MailDisabled", new Variant.boolean (false));
    var mail = new VariantBuilder (new VariantType ("a{sv}"));
    mail.add ("{sv}", "Name", new Variant.string ("Alex Morgan"));
    mail.add ("{sv}", "EmailAddress", new Variant.string ("alex@gmail.com"));
    mail.add ("{sv}", "ImapSupported", new Variant.boolean (true));
    mail.add ("{sv}", "ImapHost", new Variant.string ("imap.gmail.com:993"));
    mail.add ("{sv}", "ImapUserName", new Variant.string ("alex@gmail.com"));
    mail.add ("{sv}", "ImapUseSsl", new Variant.boolean (true));
    mail.add ("{sv}", "ImapUseTls", new Variant.boolean (false));
    mail.add ("{sv}", "SmtpSupported", new Variant.boolean (true));
    mail.add ("{sv}", "SmtpAuthXoauth2", new Variant.boolean (smtp_xoauth2));
    mail.add ("{sv}", "SmtpHost", new Variant.string ("smtp.gmail.com:587"));
    mail.add ("{sv}", "SmtpUserName", new Variant.string ("alex@gmail.com"));
    mail.add ("{sv}", "SmtpUseSsl", new Variant.boolean (false));
    mail.add ("{sv}", "SmtpUseTls", new Variant.boolean (true));
    var oauth = new VariantBuilder (new VariantType ("a{sv}"));
    var interfaces = new VariantBuilder (new VariantType ("a{sa{sv}}"));
    interfaces.add ("{s@a{sv}}", "org.gnome.OnlineAccounts.Account", account.end ());
    interfaces.add ("{s@a{sv}}", "org.gnome.OnlineAccounts.Mail", mail.end ());
    interfaces.add ("{s@a{sv}}", "org.gnome.OnlineAccounts.OAuth2Based", oauth.end ());
    return interfaces.end ();
}

private void test_online_account_mapping_and_storage () {
    string path = Path.build_filename (Environment.get_tmp_dir (), "mailficient-goa-%s.sqlite".printf (Uuid.string_random ()));
    try {
        var online = GnomeOnlineAccountService.account_from_interfaces (
            "/org/gnome/OnlineAccounts/Accounts/account_42", test_goa_interfaces ());
        assert (online != null); assert (online.provider_name == "Google");
        var settings = online.to_settings ();
        assert (settings.id == "goa-account_42");
        assert (settings.authentication == AuthenticationMode.GNOME_ONLINE_ACCOUNTS);
        assert (settings.incoming_host == "imap.gmail.com"); assert (settings.incoming_port == 993);
        assert (settings.outgoing_host == "smtp.gmail.com"); assert (settings.outgoing_port == 587);
        assert (settings.outgoing_encryption == EncryptionMode.STARTTLS);
        var cache = new CacheDatabase (path); cache.save_account (settings);
        var loaded = cache.find_account (settings.id); assert (loaded != null);
        assert (loaded.authentication == AuthenticationMode.GNOME_ONLINE_ACCOUNTS);
        assert (loaded.online_account_path == settings.online_account_path);
    } catch (Error error) { GLib.error ("online account mapping test failed: %s", error.message); }
    FileUtils.unlink (path);
}

private void test_online_account_security_requirements () {
    var unsupported = GnomeOnlineAccountService.account_from_interfaces (
        "/org/gnome/OnlineAccounts/Accounts/no_xoauth2", test_goa_interfaces (false));
    assert (unsupported == null);

    var insecure = new OnlineMailAccount (
        "/org/gnome/OnlineAccounts/Accounts/insecure", "Provider", "Alex",
        "alex@example.com", "imap.example.com", "alex@example.com", false, false,
        "smtp.example.com", "alex@example.com", false, true);
    try {
        insecure.to_settings ();
        assert_not_reached ();
    } catch (MailError error) {
        assert (error is MailError.INVALID_ACCOUNT);
    }
}

private void test_folder_validation () {
    try { FolderService.validate_name ("Projects 2026"); } catch (Error error) { assert_not_reached (); }
    try { FolderService.validate_name ("   "); assert_not_reached (); } catch (MailError error) { }
    try { FolderService.validate_name ("Bad\nFolder"); assert_not_reached (); } catch (MailError error) { }
}

private void test_recipients () {
    try {
        var recipients = RecipientParser.parse ("Maya Chen <maya@example.net>, noah@example.org");
        assert (recipients.size == 2); assert (recipients[0].name == "Maya Chen");
        assert (recipients[1].address == "noah@example.org");
    } catch (Error error) { assert_not_reached (); }
    try { RecipientParser.parse ("not an address"); assert_not_reached (); } catch (MailError error) { }
    try {
        var quoted = RecipientParser.parse ("\"Doe, Jane\" <jane@example.net>, team@example.org");
        assert (quoted.size == 2); assert (quoted[0].name == "Doe, Jane");
        assert (quoted[0].formatted () == "\"Doe, Jane\" <jane@example.net>");
        assert (RecipientParser.parse (quoted[0].formatted ())[0].address == "jane@example.net");
    } catch (Error error) { assert_not_reached (); }
}

private void test_reply_all_recipients () {
    var message = new Message ("reply-all", "inbox", "Maya Chen", "maya@example.net",
        "Alex <alex@example.com>, Noah <NOAH@example.org>", "Planning", "", "", "Today");
    message.cc_recipients = "Priya Raman <priya@example.org>, Noah Duplicate <noah@example.org>";
    var recipients = new ReplyRecipientService ().build (message, "ALEX@example.com");
    assert (recipients.to == "Maya Chen <maya@example.net>");
    assert (recipients.cc == "Noah <noah@example.org>, Priya Raman <priya@example.org>");

    var sent = new Message ("sent-reply-all", "sent", "Alex", "alex@example.com",
        "Maya <maya@example.net>, Noah <noah@example.org>", "Planning", "", "", "Today");
    sent.cc_recipients = "Priya <priya@example.org>";
    recipients = new ReplyRecipientService ().build (sent, "alex@example.com");
    assert (recipients.to == "Maya <maya@example.net>");
    assert (recipients.cc == "Noah <noah@example.org>, Priya <priya@example.org>");
}

private void test_cc_recipient_cache_roundtrip () {
    string path = Path.build_filename (Environment.get_tmp_dir (), "mailficient-cc-cache-%s.sqlite".printf (Uuid.string_random ()));
    try {
        var cache = new CacheDatabase (path);
        var message = new Message ("cc-message", "inbox", "Maya", "maya@example.net",
            "Alex <alex@example.com>", "Status", "", "Body", "Today");
        message.cc_recipients = "Noah Williams <noah@example.org>";
        message.security_status = "OpenPGP signature verified";
        cache.cache_message (message);
        var loaded = cache.find_cached_message (message.id);
        assert (loaded != null); assert (loaded.cc_recipients == message.cc_recipients);
        assert (loaded.security_status == message.security_status);
        assert (cache.search_messages (SearchQuery.parse ("to:noah")).size == 1);
        bool found = false;
        foreach (var candidate in cache.recipient_candidates ())
            if (candidate.address == "noah@example.org") found = true;
        assert (found);
    } catch (Error error) { GLib.error ("Cc recipient cache test failed: %s", error.message); }
    FileUtils.unlink (path);
}

private void test_recipient_completion () {
    string path = Path.build_filename (Environment.get_tmp_dir (), "mailficient-completion-%s.sqlite".printf (Uuid.string_random ()));
    try {
        var cache = new CacheDatabase (path);
        var account = AccountSettings.for_email ("Alex", "alex@example.com"); account.id = "account-1";
        account.incoming_host = "imap.example.com"; account.outgoing_host = "smtp.example.com"; cache.save_account (account);
        cache.cache_message (new Message ("candidate-1", "inbox", "Doe, Jane", "jane@example.net",
            "Alex <alex@example.com>, Noah Williams <noah@example.org>", "Hello", "", "", "Today"));
        var service = new RecipientCompletionService (cache, new TestContactSuggestionProvider ());
        var jane = service.suggest ("ja", 2, account.id); assert (jane.size == 1);
        assert (jane[0].address == "jane@example.net");
        assert (service.suggest ("alex", 4, account.id).size == 0);
        string partial = "Noah <noah@example.org>, ja";
        assert (RecipientCompletionService.fragment (partial, partial.length) == "ja");
        int cursor; string completed = RecipientCompletionService.complete (
            partial, partial.length, jane[0], out cursor);
        assert (completed == "Noah <noah@example.org>, \"Doe, Jane\" <jane@example.net>, ");
        assert (cursor == completed.length);
        Gee.List<Recipient>? merged = null; Error? failure = null; var loop = new MainLoop ();
        service.suggest_with_contacts.begin ("ja", 2, account.id, 6, null, (object, result) => {
            try { merged = service.suggest_with_contacts.end (result); }
            catch (Error error) { failure = error; }
            loop.quit ();
        });
        loop.run (); assert (failure == null); assert (merged != null); assert (merged.size == 2);
        assert (merged[0].address == "jane@example.net"); assert (merged[1].address == "janet@example.org");
    } catch (Error caught) { GLib.error ("recipient completion test failed: %s", caught.message); }
    FileUtils.unlink (path);
}

private void test_local_data_migration () {
    string root = Path.build_filename (Environment.get_tmp_dir (), "mailficient-migration-%s".printf (Uuid.string_random ()));
    string legacy = Path.build_filename (root, "personal-mail");
    string attachment_directory = Path.build_filename (legacy, "attachments");
    string received_directory = Path.build_filename (legacy, "received-attachments");
    try {
        assert (DirUtils.create_with_parents (attachment_directory, 0700) == 0);
        assert (DirUtils.create_with_parents (received_directory, 0700) == 0);
        string draft_path = Path.build_filename (attachment_directory, "note.txt");
        string received_path = Path.build_filename (received_directory, "report.pdf");
        assert (FileUtils.set_contents (draft_path, "attachment"));
        assert (FileUtils.set_contents (received_path, "%PDF-1.4 migrated"));
        var legacy_cache = new CacheDatabase (Path.build_filename (legacy, "mail.db"));
        var draft = new Draft ("legacy-account"); draft.to = "maya@example.net";
        draft.body_text = "Migrated draft";
        draft.add_attachment (new Attachment ("legacy-draft", draft_path,
            "note.txt", 10, "text/plain"));
        legacy_cache.save_draft (draft);
        var message = new Message ("legacy-message", "legacy-inbox", "Maya",
            "maya@example.net", "alex@example.net", "Legacy report", "Report",
            "See attachment", "Yesterday");
        message.add_attachment (new Attachment ("legacy-received", received_path,
            "report.pdf", 17, "application/pdf"));
        legacy_cache.cache_message (message); legacy_cache.checkpoint ();

        string migrated = LocalDataMigration.prepare (root);
        string contents;
        assert (FileUtils.get_contents (Path.build_filename (migrated, "attachments", "note.txt"), out contents));
        assert (contents == "attachment");
        var migrated_cache = new CacheDatabase (Path.build_filename (migrated, "mail.db"));
        var migrated_draft = migrated_cache.load_draft (draft.id); assert (migrated_draft != null);
        assert (migrated_draft.attachments.size == 1);
        assert (migrated_draft.attachments[0].path ==
            Path.build_filename (migrated, "attachments", "note.txt"));
        assert (FileUtils.test (migrated_draft.attachments[0].path, FileTest.IS_REGULAR));
        var migrated_message = migrated_cache.find_cached_message (message.id);
        assert (migrated_message != null); assert (migrated_message.attachments.size == 1);
        assert (migrated_message.attachments[0].path ==
            Path.build_filename (migrated, "received-attachments", "report.pdf"));
        assert (FileUtils.test (migrated_message.attachments[0].path, FileTest.IS_REGULAR));
        assert (FileUtils.test (draft_path, FileTest.IS_REGULAR));

        assert (LocalDataMigration.prepare (root) == migrated);
        assert (migrated_cache.load_draft (draft.id).attachments[0].path ==
            Path.build_filename (migrated, "attachments", "note.txt"));
    } catch (Error error) { GLib.error ("local data migration test failed: %s", error.message); }
}

private void test_failed_local_data_migration_is_atomic () {
    string root = Path.build_filename (Environment.get_tmp_dir (),
        "mailficient-failed-migration-%s".printf (Uuid.string_random ())) ;
    string legacy = Path.build_filename (root, "personal-mail");
    try {
        assert (DirUtils.create_with_parents (legacy, 0700) == 0);
        string database_path = Path.build_filename (legacy, "mail.db");
        assert (FileUtils.set_contents (database_path, "not a sqlite database"));
        Error? failure = null;
        try { LocalDataMigration.prepare (root); } catch (Error error) { failure = error; }
        assert (failure is MailError.STORAGE);
        assert (FileUtils.test (database_path, FileTest.IS_REGULAR));
        assert (!FileUtils.test (Path.build_filename (root, "mailficient"), FileTest.EXISTS));
        var directory = Dir.open (root); string? name;
        while ((name = directory.read_name ()) != null)
            assert (!name.has_prefix (".mailficient-migration-"));
    } catch (Error error) { GLib.error ("failed migration atomicity test failed: %s", error.message); }
}

private void test_draft_state () {
    var draft = new Draft ("account-1"); assert (draft.dirty); assert (!draft.can_send ());
    draft.to = "maya@example.net"; draft.body_text = "Hello"; draft.touch (); assert (draft.can_send ());
    draft.cc = "not-an-address"; assert (!draft.can_send ());
    try { draft.validate_for_send (); assert_not_reached (); }
    catch (MailError error) { assert (error is MailError.INVALID_MESSAGE); }
    draft.cc = "Noah <noah@example.org>"; draft.bcc = "private@example.com"; assert (draft.can_send ());
    draft.sign_message = true; assert (!draft.can_send ());
    draft.security_protocol = MessageSecurityProtocol.OPENPGP; assert (draft.can_send ());
    try {
        var secure_recipients = draft.security_recipients ("MAYA@example.net");
        assert (secure_recipients.size == 3);
        assert (secure_recipients[0] == "maya@example.net");
        assert (secure_recipients[1] == "noah@example.org");
        assert (secure_recipients[2] == "private@example.com");
    } catch (Error error) { assert_not_reached (); }
    draft.mark_saved (); assert (!draft.dirty);
}

private void test_settings_store () {
    string path = Path.build_filename (Environment.get_tmp_dir (), "mailficient-settings-%s.sqlite".printf (Uuid.string_random ()));
    try {
        var cache = new CacheDatabase (path); var settings = new MailSettingsStore (cache);
        assert (settings.notifications_enabled); settings.notifications_enabled = false;
        settings.set_signature ("account-1", "Alex Morgan\nDesign Team");
        settings.set_signature_enabled ("account-1", true);
        settings.mailbox_pane_width = 276; settings.message_pane_width = 428;
        settings.save_window_state (1480, 910, false);
        settings.sidebar_visible = false;
        settings.onboarding_completed = true;
        settings.selected_mailbox_id = "account-1:archive";
        settings.message_sort = "sender";
        settings.preferences_page = "privacy";
        settings.toolbar_layout = "refresh,flex,compose,space,space";
        settings.sync_on_startup = false;
        settings.sync_interval_minutes = 30;
        assert (settings.group_messages);
        settings.group_messages = false;
        assert (!settings.always_show_images);
        settings.always_show_images = true;
        assert (settings.full_html_formatting);
        settings.full_html_formatting = false;
        assert (settings.appearance == "system");
        settings.appearance = "dark";
        var reopened = new MailSettingsStore (new CacheDatabase (path));
        assert (!reopened.notifications_enabled); assert (reopened.signature_enabled ("account-1"));
        assert (reopened.signature ("account-1") == "Alex Morgan\nDesign Team");
        assert (reopened.mailbox_pane_width == 276); assert (reopened.message_pane_width == 428);
        assert (reopened.window_width == 1480); assert (reopened.window_height == 910);
        assert (!reopened.window_maximized);
        assert (!reopened.sidebar_visible);
        assert (reopened.onboarding_completed);
        assert (reopened.selected_mailbox_id == "account-1:archive");
        assert (reopened.message_sort == "sender");
        assert (reopened.preferences_page == "privacy");
        assert (reopened.toolbar_layout == "refresh,flex,compose,space,space");
        assert (!reopened.sync_on_startup);
        assert (reopened.sync_interval_minutes == 30);
        assert (!reopened.group_messages);
        assert (reopened.always_show_images);
        assert (!reopened.full_html_formatting);
        assert (reopened.appearance == "dark");
        reopened.save_window_state (1920, 1080, true);
        var maximized = new MailSettingsStore (new CacheDatabase (path));
        assert (maximized.window_maximized);
        assert (maximized.window_width == 1480); assert (maximized.window_height == 910);
        maximized.window_width = 10; maximized.window_height = 9999;
        maximized.mailbox_pane_width = 2; maximized.message_pane_width = 9999;
        assert (maximized.window_width == 640); assert (maximized.window_height == 2160);
        assert (maximized.mailbox_pane_width == 190); assert (maximized.message_pane_width == 620);
        maximized.sync_interval_minutes = 7;
        assert (maximized.sync_interval_minutes == 5);
        maximized.preferences_page = "unknown";
        assert (maximized.preferences_page == "general");
        maximized.appearance = "invalid";
        assert (maximized.appearance == "system");
    } catch (Error caught) { GLib.error ("settings store test failed: %s", caught.message); }
    FileUtils.unlink (path);
}

private void test_startup_sync_gate () {
    var online = new StartupSyncGate (true);
    // Initial state discovery and any startup flapping are ignored.
    assert (!online.should_sync_for_network_change (true));
    assert (!online.should_sync_for_network_change (false));
    assert (!online.should_sync_for_network_change (true));
    online.enable_reconnect_sync ();
    assert (!online.should_sync_for_network_change (true));
    assert (!online.should_sync_for_network_change (false));
    assert (online.should_sync_for_network_change (true));
    assert (!online.should_sync_for_network_change (true));

    var offline = new StartupSyncGate (false);
    assert (!offline.should_sync_for_network_change (true));
    offline.enable_reconnect_sync ();
    // The state observed during startup is the new baseline, not a queued reconnect.
    assert (!offline.should_sync_for_network_change (true));
    assert (!offline.should_sync_for_network_change (false));
    assert (offline.should_sync_for_network_change (true));
}

private void test_signature_service () {
    string path = Path.build_filename (Environment.get_tmp_dir (), "mailficient-signature-%s.sqlite".printf (Uuid.string_random ()));
    try {
        var settings = new MailSettingsStore (new CacheDatabase (path));
        settings.set_signature ("personal", "Alex Morgan\nDesign Team");
        settings.set_signature_enabled ("personal", true);
        settings.set_signature ("work", "Alex\nNorthstar"); settings.set_signature_enabled ("work", true);
        var service = new SignatureService (settings); string applied;
        string reply = service.apply ("personal", "\n\nOn Friday, Maya wrote:\n> Hello", out applied);
        assert (reply.has_prefix ("\n\n-- \nAlex Morgan")); assert (reply.contains ("On Friday"));
        string updated = service.replace (applied, "work", reply, out applied);
        assert (!updated.contains ("Design Team")); assert (updated.contains ("Alex\nNorthstar"));
        string quoted_same_text = updated + "\n> -- \nAlex\nNorthstar";
        settings.set_signature_enabled ("personal", false);
        assert (service.block_for ("personal") == "");
        assert (service.configured_block_for ("personal").contains ("Alex Morgan"));
        string removed = service.replace (applied, "personal", quoted_same_text, out applied);
        assert (removed.contains ("> -- \nAlex\nNorthstar")); assert (!removed.has_prefix ("\n\n-- "));
    } catch (Error caught) { GLib.error ("signature service test failed: %s", caught.message); }
    FileUtils.unlink (path);
}

private void test_cache_maintenance () {
    string root = Path.build_filename (Environment.get_tmp_dir (), "mailficient-maintenance-%s".printf (Uuid.string_random ()));
    string managed = Path.build_filename (root, "attachments"); string outside = Path.build_filename (root, "outside.txt");
    string kept = Path.build_filename (managed, "kept.txt"); string orphan = Path.build_filename (managed, "orphan.txt");
    string missing = Path.build_filename (managed, "missing.txt"); string database_path = Path.build_filename (root, "mail.sqlite");
    try {
        assert (DirUtils.create_with_parents (managed, 0700) == 0);
        FileUtils.set_contents (kept, "keep"); FileUtils.set_contents (orphan, "remove"); FileUtils.set_contents (outside, "outside");
        var cache = new CacheDatabase (database_path); var draft = new Draft ("account-1");
        draft.add_attachment (new Attachment ("kept", kept, "kept.txt", 4, "text/plain"));
        draft.add_attachment (new Attachment ("missing", missing, "missing.txt", 7, "text/plain")); cache.save_draft (draft);
        var service = new CacheMaintenanceService (cache, { managed }); var result = service.run ();
        assert (result.deleted_files == 1); assert (result.removed_records == 1); assert (result.failures == 0);
        assert (FileUtils.test (kept, FileTest.EXISTS)); assert (!FileUtils.test (orphan, FileTest.EXISTS));
        assert (FileUtils.test (outside, FileTest.EXISTS)); assert (cache.load_draft (draft.id).attachments.size == 1);
        FileUtils.unlink (kept); FileUtils.unlink (outside);
    } catch (Error caught) { GLib.error ("cache maintenance test failed: %s", caught.message); }
    FileUtils.unlink (database_path); DirUtils.remove (managed); DirUtils.remove (root);
}

private void test_cache_drafts () {
    string path = Path.build_filename (Environment.get_tmp_dir (), "mailficient-test-%s.sqlite".printf (Uuid.string_random ()));
    try {
        var cache = new CacheDatabase (path); var draft = new Draft ("account-1");
        draft.to = "maya@example.net"; draft.subject = "Hello"; draft.body_text = "Safe after restart";
        draft.body_html = "<div><strong>Safe</strong> after restart</div>";
        draft.body_format = "[{\"tag\":\"mailficient-bold\",\"start\":0,\"end\":4}]";
        draft.in_reply_to = "<parent@example.net>"; draft.references = "<root@example.net> <parent@example.net>";
        draft.security_protocol = MessageSecurityProtocol.SMIME; draft.sign_message = true;
        draft.encrypt_message = true; draft.security_identity = "mail-cert-alex";
        draft.add_attachment (new Attachment ("a1", "/private/a1-report.pdf", "report.pdf", 2048, "application/pdf"));
        cache.save_draft (draft); assert (!draft.dirty); assert (cache.draft_count () == 1);
        assert (cache.saved_draft_count () == 1); assert (cache.list_saved_drafts ().size == 1);
        var repository = new CachedMailRepository (cache, new DemoMailRepository (), true);
        assert (repository.list_messages ("drafts").size == 1);
        assert (repository.list_messages ("drafts")[0].id.has_prefix (CachedMailRepository.DRAFT_PREFIX));
        var loaded = cache.load_draft (draft.id); assert (loaded != null); assert (loaded.subject == "Hello");
        assert (loaded.body_text == "Safe after restart"); assert (loaded.attachments.size == 1);
        assert (loaded.body_html.contains ("<strong>Safe</strong>")); assert (loaded.body_format.contains ("mailficient-bold"));
        assert (loaded.in_reply_to == "<parent@example.net>"); assert (loaded.references.contains ("<root@example.net>"));
        assert (loaded.security_protocol == MessageSecurityProtocol.SMIME); assert (loaded.sign_message);
        assert (loaded.encrypt_message); assert (loaded.security_identity == "mail-cert-alex");
        assert (loaded.attachments[0].name == "report.pdf"); assert (loaded.attachments[0].size == 2048);
        cache.queue_for_sending (loaded); assert (cache.outbox_count () == 1); assert (cache.saved_draft_count () == 0);
        assert (cache.list_outbox_items ().size == 1); assert (cache.list_outbox_items ()[0].draft.subject == "Hello");
        assert (repository.list_messages (CachedMailRepository.LOCAL_OUTBOX_ID).size == 1);
        assert (repository.list_messages (CachedMailRepository.LOCAL_OUTBOX_ID)[0].id.has_prefix (CachedMailRepository.OUTBOX_PREFIX));
        cache.delete_draft (loaded.id); assert (cache.draft_count () == 0); assert (cache.outbox_count () == 0);
    } catch (Error caught) { GLib.error ("cache test failed: %s", caught.message); }
    FileUtils.unlink (path);
}

private void test_outbound_queue () {
    string root = Path.build_filename (Environment.get_tmp_dir (), "mailficient-outbound-%s".printf (Uuid.string_random ()));
    try {
        assert (DirUtils.create_with_parents (root, 0700) == 0);
        var cache = new CacheDatabase (Path.build_filename (root, "mail.sqlite"));
        var attachments = new AttachmentService (Path.build_filename (root, "attachments"));
        var draft = new Draft ("demo-account"); draft.to = "maya@example.net"; draft.body_text = "Queued safely";
        var queued_service = new OutboundService (cache, null, attachments);
        var loop = new MainLoop (); SendDisposition disposition = SendDisposition.SENT; Error? failure = null;
        queued_service.deliver.begin (draft, null, (object, result) => {
            try { disposition = queued_service.deliver.end (result); } catch (Error error) { failure = error; }
            loop.quit ();
        });
        loop.run (); assert (failure == null); assert (disposition == SendDisposition.QUEUED); assert (cache.outbox_count () == 1);
        cache.queue_for_sending (draft); assert (cache.outbox_count () == 1); assert (cache.outbox_attempts (draft.id) == 0);

        var account = AccountSettings.for_email ("Test", "test@example.net"); account.id = "failing-account";
        account.incoming_host = "imap.example.net"; account.outgoing_host = "smtp.example.net"; cache.save_account (account);
        var failed_draft = new Draft (account.id); failed_draft.to = "maya@example.net"; failed_draft.body_text = "Retry me";
        var failing_service = new OutboundService (cache, new FailingMailEngine (), attachments); failure = null;
        failing_service.deliver.begin (failed_draft, null, (object, result) => {
            try { failing_service.deliver.end (result); } catch (Error error) { failure = error; }
            loop.quit ();
        });
        loop.run (); assert (failure is MailError.SEND_FAILED); assert (cache.outbox_count () == 2);
        assert (cache.outbox_attempts (failed_draft.id) == 1);
        assert (cache.list_pending_sends (account.id, false).size == 1);
        assert (cache.list_pending_sends (account.id, false)[0].body_text == "Retry me");
        assert (cache.list_pending_sends (account.id, true).size == 0);
        cache.complete_send (draft.id); assert (cache.outbox_count () == 1); assert (cache.load_draft (draft.id) == null);
    } catch (Error error) { GLib.error ("outbound test failed: %s", error.message); }
}

private void test_scheduled_delivery_timer () {
    string root = Path.build_filename (Environment.get_tmp_dir (),
        "mailficient-scheduled-send-%s".printf (Uuid.string_random ()));
    try {
        assert (DirUtils.create_with_parents (root, 0700) == 0);
        var cache = new CacheDatabase (Path.build_filename (root, "mail.sqlite"));
        var account = AccountSettings.for_email ("Alex", "alex@example.net");
        account.id = "scheduled-account"; account.incoming_host = "imap.example.net";
        account.outgoing_host = "smtp.example.net"; cache.save_account (account);
        var engine = new RecordingMailEngine (account.id);
        var attachments = new AttachmentService (Path.build_filename (root, "attachments"));
        var service = new OutboundService (cache, engine, attachments);
        var draft = new Draft (account.id); draft.to = "maya@example.net";
        draft.body_text = "Deliver when due";
        bool delivered = false; bool timed_out = false; var loop = new MainLoop ();
        service.delivered.connect ((draft_id) => {
            if (draft_id == draft.id) { delivered = true; loop.quit (); }
        });
        service.start_scheduler ();
        service.schedule (draft, new DateTime.now_utc ().to_unix () + 1);
        Timeout.add_seconds (5, () => {
            if (!delivered) { timed_out = true; loop.quit (); }
            return Source.REMOVE;
        });
        loop.run (); service.stop_scheduler ();
        assert (!timed_out); assert (delivered); assert (engine.send_calls == 1);
        assert (cache.find_outbox_item (draft.id) == null);
    } catch (Error error) { GLib.error ("scheduled delivery timer test failed: %s", error.message); }
}

private void test_outbound_deadlines () {
    string root = Path.build_filename (Environment.get_tmp_dir (),
        "mailficient-send-deadlines-%s".printf (Uuid.string_random ()));
    try {
        assert (DirUtils.create_with_parents (root, 0700) == 0);
        var cache = new CacheDatabase (Path.build_filename (root, "mail.sqlite"));
        var account = AccountSettings.for_email ("Alex", "alex@example.net");
        account.id = "deadline-account"; account.incoming_host = "imap.example.net";
        account.outgoing_host = "smtp.example.net"; cache.save_account (account);
        var attachments = new AttachmentService (Path.build_filename (root, "attachments"));
        var engine = new RecordingMailEngine (account.id); engine.stall_connect = true;
        var service = new OutboundService (cache, engine, attachments, 1, 1);
        var connect_draft = new Draft (account.id); connect_draft.to = "maya@example.net";
        connect_draft.body_text = "Connection must stop";
        Error? failure = null; var loop = new MainLoop ();
        service.deliver.begin (connect_draft, null, (object, result) => {
            try { service.deliver.end (result); } catch (Error error) { failure = error; }
            loop.quit ();
        });
        loop.run ();
        assert (failure is MailError.TIMEOUT);
        var connect_item = cache.find_outbox_item (connect_draft.id); assert (connect_item != null);
        assert (connect_item.delivery_state == OutboxDeliveryState.QUEUED);
        assert (connect_item.last_error.contains ("connecting within 1 seconds"));

        engine.stall_connect = false; engine.stall_send = true; failure = null;
        var send_draft = new Draft (account.id); send_draft.to = "maya@example.net";
        send_draft.body_text = "SMTP must stop";
        service.deliver.begin (send_draft, null, (object, result) => {
            try { service.deliver.end (result); } catch (Error error) { failure = error; }
            loop.quit ();
        });
        loop.run ();
        assert (failure is MailError.DELIVERY_UNCERTAIN);
        var send_item = cache.find_outbox_item (send_draft.id); assert (send_item != null);
        assert (send_item.delivery_state == OutboxDeliveryState.SENDING);
        assert (send_item.requires_resend_confirmation ());
        assert (send_item.last_error.contains ("sending within 1 seconds"));
    } catch (Error error) { GLib.error ("outbound deadline test failed: %s", error.message); }
}

private void test_attachment_send_preflight () {
    var declared = new Gee.ArrayList<Attachment> ();
    for (int index = 0; index < 4; index++)
        declared.add (new Attachment ("declared-%d".printf (index), "/unused",
            "part-%d.bin".printf (index), AttachmentService.MAX_ATTACHMENT_SIZE,
            "application/octet-stream"));
    try { AttachmentService.validate_declared_total (declared); }
    catch (Error error) { GLib.error ("valid aggregate attachment size was rejected: %s", error.message); }
    declared.add (new Attachment ("declared-5", "/unused", "part-5.bin",
        AttachmentService.MAX_ATTACHMENT_SIZE, "application/octet-stream"));
    Error? aggregate_error = null;
    try { AttachmentService.validate_declared_total (declared); }
    catch (Error error) { aggregate_error = error; }
    assert (aggregate_error is MailError.ATTACHMENT);

    string root = Path.build_filename (Environment.get_tmp_dir (),
        "mailficient-send-preflight-%s".printf (Uuid.string_random ())) ;
    try {
        assert (DirUtils.create_with_parents (root, 0700) == 0);
        string source_path = Path.build_filename (root, "source.txt");
        assert (FileUtils.set_contents (source_path, "attachment body"));
        var cache = new CacheDatabase (Path.build_filename (root, "mail.sqlite"));
        var account = AccountSettings.for_email ("Alex", "alex@example.net");
        account.id = "preflight-account"; account.incoming_host = "imap.example.net";
        account.outgoing_host = "smtp.example.net"; cache.save_account (account);
        var attachments = new AttachmentService (Path.build_filename (root, "attachments"));
        Attachment? imported = null; Error? failure = null; var loop = new MainLoop ();
        attachments.import_file.begin (File.new_for_path (source_path), null, (object, result) => {
            try { imported = attachments.import_file.end (result); }
            catch (Error error) { failure = error; }
            loop.quit ();
        });
        loop.run (); assert (failure == null); assert (imported != null);
        assert (FileUtils.set_contents (imported.path, "attachment changed after import"));
        var draft = new Draft (account.id); draft.to = "maya@example.net";
        draft.body_text = "Do not start SMTP"; draft.add_attachment (imported);
        var engine = new RecordingMailEngine (account.id);
        var outbound = new OutboundService (cache, engine, attachments); failure = null;
        outbound.deliver.begin (draft, null, (object, result) => {
            try { outbound.deliver.end (result); } catch (Error error) { failure = error; }
            loop.quit ();
        });
        loop.run ();
        assert (failure is MailError.ATTACHMENT);
        assert (engine.connect_calls == 0); assert (engine.send_calls == 0);
        var queued = cache.find_outbox_item (draft.id); assert (queued != null);
        assert (queued.delivery_state == OutboxDeliveryState.QUEUED);
        assert (queued.attempts == 1); assert (!queued.requires_resend_confirmation ());
        assert (queued.last_error.contains ("changed"));
    } catch (Error error) { GLib.error ("attachment send preflight test failed: %s", error.message); }
}

private void test_outbox_delivery_state_machine () {
    string root = Path.build_filename (Environment.get_tmp_dir (),
        "mailficient-delivery-state-%s".printf (Uuid.string_random ())) ;
    try {
        assert (DirUtils.create_with_parents (root, 0700) == 0);
        var cache = new CacheDatabase (Path.build_filename (root, "mail.sqlite"));
        var account = AccountSettings.for_email ("Alex", "alex@example.net"); account.id = "delivery-state";
        account.incoming_host = "imap.example.net"; account.outgoing_host = "smtp.example.net";
        cache.save_account (account);
        var engine = new RecordingMailEngine (account.id); engine.fail_send = true;
        var attachments = new AttachmentService (Path.build_filename (root, "attachments"));
        var service = new OutboundService (cache, engine, attachments);
        var draft = new Draft (account.id); draft.to = "maya@example.net"; draft.body_text = "Do not duplicate";
        Error? failure = null; var loop = new MainLoop ();
        service.deliver.begin (draft, null, (object, result) => {
            try { service.deliver.end (result); } catch (Error error) { failure = error; }
            loop.quit ();
        });
        loop.run ();
        assert (failure is MailError.DELIVERY_UNCERTAIN);
        assert (cache.outbox_count () == 1); assert (cache.list_pending_sends (account.id, false).size == 0);
        var item = cache.list_outbox_items ()[0];
        assert (item.delivery_state == OutboxDeliveryState.SENDING);
        assert (item.requires_resend_confirmation ()); assert (item.can_attempt_delivery ());
        assert (item.last_error.contains ("SMTP response"));
        var found_item = cache.find_outbox_item (draft.id); assert (found_item != null);
        assert (found_item.requires_resend_confirmation ()); assert (found_item.last_error == item.last_error);
        int send_calls = engine.send_calls;
        service.retry_pending.begin (account.id, false, null, (object, result) => {
            try { service.retry_pending.end (result); } catch (Error error) { failure = error; }
            loop.quit ();
        });
        loop.run (); assert (engine.send_calls == send_calls); assert (cache.outbox_count () == 1);

        // Pressing Send from the reopened Outbox editor is an explicit retry.
        engine.fail_send = false; failure = null;
        service.deliver.begin (draft, null, (object, result) => {
            try { service.deliver.end (result); } catch (Error error) { failure = error; }
            loop.quit ();
        });
        loop.run (); assert (failure == null); assert (engine.send_calls == send_calls + 1);
        assert (cache.outbox_count () == 0);

        // A confirmed message left behind by local cleanup is finalized without SMTP.
        var accepted = new Draft (account.id); accepted.to = "maya@example.net"; accepted.body_text = "Accepted";
        cache.queue_for_sending (accepted); cache.mark_send_started (accepted.id); cache.mark_send_accepted (accepted.id);
        var accepted_item = cache.find_outbox_item (accepted.id); assert (accepted_item != null);
        assert (!accepted_item.can_attempt_delivery ()); assert (!accepted_item.requires_resend_confirmation ());
        send_calls = engine.send_calls;
        service.retry_pending.begin (account.id, false, null, (object, result) => {
            try { service.retry_pending.end (result); } catch (Error error) { failure = error; }
            loop.quit ();
        });
        loop.run (); assert (engine.send_calls == send_calls); assert (cache.outbox_count () == 0);
    } catch (Error error) { GLib.error ("delivery state test failed: %s", error.message); }
}

private void test_rate_limited_send_is_retryable () {
    string root = Path.build_filename (Environment.get_tmp_dir (),
        "mailficient-rate-limit-%s".printf (Uuid.string_random ())) ;
    try {
        assert (DirUtils.create_with_parents (root, 0700) == 0);
        var cache = new CacheDatabase (Path.build_filename (root, "mail.sqlite"));
        var account = AccountSettings.for_email ("Alex", "alex@example.net");
        account.id = "rate-limited"; account.incoming_host = "imap.example.net";
        account.outgoing_host = "smtp.example.net"; cache.save_account (account);
        var engine = new RecordingMailEngine (account.id); engine.rate_limit_send = true;
        var attachments = new AttachmentService (Path.build_filename (root, "attachments"));
        var service = new OutboundService (cache, engine, attachments);
        var draft = new Draft (account.id); draft.to = "maya@example.net";
        draft.body_text = "Keep this queued";
        Error? failure = null; var loop = new MainLoop ();
        service.deliver.begin (draft, null, (object, result) => {
            try { service.deliver.end (result); } catch (Error error) { failure = error; }
            loop.quit ();
        });
        loop.run ();
        assert (failure is MailError.RATE_LIMITED);
        var queued = cache.find_outbox_item (draft.id); assert (queued != null);
        assert (queued.delivery_state == OutboxDeliveryState.QUEUED);
        assert (queued.attempts == 1); assert (queued.next_attempt_at > new DateTime.now_utc ().to_unix ());
        assert (!queued.requires_resend_confirmation ());
        assert (cache.list_pending_sends (account.id, false).size == 1);
        assert (cache.list_pending_sends (account.id, true).size == 0);
        var friendly = UserFacingError.from_error (failure);
        assert (friendly.title == "The mail server is busy");
        assert (friendly.suggestion.contains ("retry automatically"));

        engine.rate_limit_send = false; failure = null;
        service.retry_pending.begin (account.id, false, null, (object, result) => {
            try { service.retry_pending.end (result); } catch (Error error) { failure = error; }
            loop.quit ();
        });
        loop.run ();
        assert (failure == null); assert (cache.find_outbox_item (draft.id) == null);
        assert (engine.send_calls == 2);
    } catch (Error error) { GLib.error ("rate-limited send test failed: %s", error.message); }
}

private void test_definitive_send_rejection_is_retryable () {
    string root = Path.build_filename (Environment.get_tmp_dir (),
        "mailficient-smtp-rejection-%s".printf (Uuid.string_random ())) ;
    try {
        assert (DirUtils.create_with_parents (root, 0700) == 0);
        var cache = new CacheDatabase (Path.build_filename (root, "mail.sqlite"));
        var account = AccountSettings.for_email ("Alex", "alex@example.net");
        account.id = "smtp-rejection"; account.incoming_host = "imap.example.net";
        account.outgoing_host = "smtp.example.net"; cache.save_account (account);
        var engine = new RecordingMailEngine (account.id); engine.reject_send = true;
        var attachments = new AttachmentService (Path.build_filename (root, "attachments"));
        var service = new OutboundService (cache, engine, attachments);
        var draft = new Draft (account.id); draft.to = "missing@example.net";
        draft.body_text = "Keep this editable";
        Error? failure = null; var loop = new MainLoop ();
        service.deliver.begin (draft, null, (object, result) => {
            try { service.deliver.end (result); } catch (Error error) { failure = error; }
            loop.quit ();
        });
        loop.run ();
        assert (failure is MailError.SEND_REJECTED);
        var queued = cache.find_outbox_item (draft.id); assert (queued != null);
        assert (queued.delivery_state == OutboxDeliveryState.REJECTED);
        assert (queued.attempts == 1); assert (!queued.requires_resend_confirmation ());
        assert (queued.can_attempt_delivery ());
        assert (queued.last_error.contains ("550"));
        assert (cache.list_pending_sends (account.id, false).size == 0);
        var friendly = UserFacingError.from_error (failure);
        assert (friendly.title.contains ("rejected"));
        assert (friendly.description.contains ("not retry automatically"));
    } catch (Error error) { GLib.error ("definitive SMTP rejection test failed: %s", error.message); }
}

private void test_outbox_queue_is_atomic () {
    string path = Path.build_filename (Environment.get_tmp_dir (),
        "mailficient-atomic-outbox-%s.sqlite".printf (Uuid.string_random ())) ;
    try {
        var cache = new CacheDatabase (path);
        var existing = new Draft ("atomic-account"); existing.to = "maya@example.net";
        existing.body_text = "Previously saved version"; cache.save_draft (existing);
        existing.body_text = "Edited version for Outbox"; existing.touch (); assert (existing.dirty);

        Sqlite.Database injector;
        assert (Sqlite.Database.open (path, out injector) == Sqlite.OK);
        string? detail = null;
        assert (injector.exec ("CREATE TRIGGER fail_outbox_insert BEFORE INSERT ON outbox " +
            "BEGIN SELECT RAISE(FAIL, 'simulated outbox write failure'); END;",
            null, out detail) == Sqlite.OK);

        bool rejected = false;
        try { cache.queue_for_sending (existing); }
        catch (MailError error) { rejected = true; }
        assert (rejected); assert (existing.dirty); assert (cache.outbox_count () == 0);
        var preserved = cache.load_draft (existing.id); assert (preserved != null);
        assert (preserved.body_text == "Previously saved version");

        var fresh = new Draft ("atomic-account"); fresh.to = "noah@example.net";
        fresh.body_text = "Never partially save this";
        rejected = false;
        try { cache.queue_for_sending (fresh); }
        catch (MailError error) { rejected = true; }
        assert (rejected); assert (fresh.dirty); assert (cache.load_draft (fresh.id) == null);

        assert (injector.exec ("DROP TRIGGER fail_outbox_insert", null, out detail) == Sqlite.OK);
        cache.queue_for_sending (fresh);
        assert (!fresh.dirty); assert (cache.find_outbox_item (fresh.id) != null);
    } catch (Error error) { GLib.error ("atomic Outbox test failed: %s", error.message); }
    FileUtils.unlink (path);
}

private void test_error_conversion () {
    var tls = UserFacingError.from_error (new MailError.TLS ("certificate expired for server.example"));
    assert (tls.title == "Secure connection failed"); assert (tls.suggestion.contains ("Do not bypass"));
    assert (tls.technical_detail.contains ("expired"));
    var sending = UserFacingError.from_error (new MailError.SEND_FAILED ("temporary SMTP failure"));
    assert (sending.title == "Message was not sent"); assert (sending.description.contains ("Outbox"));
    var uncertain = UserFacingError.from_error (new MailError.DELIVERY_UNCERTAIN ("connection ended"));
    assert (uncertain.title == "Delivery status is uncertain"); assert (uncertain.suggestion.down ().contains ("review"));
    var connection = UserFacingError.from_error (new MailError.CONNECTION ("refused"));
    assert (connection.title == "Could not reach the mail server");
    var throttled = UserFacingError.from_error (new MailError.RATE_LIMITED ("too many requests"));
    assert (throttled.title == "The mail server is busy");
    assert (throttled.description.contains ("limiting"));
    var partial = UserFacingError.from_error (new MailError.PARTIAL_SYNC (
        "Archive: one server message could not be downloaded"));
    assert (partial.title == "Some mail could not be updated");
    assert (partial.description.contains ("kept older cached mail"));
    assert (partial.technical_detail.contains ("Archive"));
}

private void test_account_storage () {
    string path = Path.build_filename (Environment.get_tmp_dir (), "mailficient-account-%s.sqlite".printf (Uuid.string_random ()));
    try {
        var cache = new CacheDatabase (path);
        var account = AccountSettings.for_email ("Alex Morgan", "alex@gmail.com"); account.id = "account-test";
        cache.save_account (account);
        var accounts = cache.list_accounts (); assert (accounts.size == 1); assert (accounts[0].id == "account-test");
        assert (accounts[0].incoming_host == "imap.gmail.com"); assert (accounts[0].outgoing_encryption == EncryptionMode.TLS);
        var snapshot = new MailSyncResult (account.id);
        var inbox = new Mailbox ("account-test:inbox", "Inbox", "mail-inbox-symbolic", MailboxRole.INBOX, 1, account.id, "INBOX");
        snapshot.mailboxes.add (inbox);
        snapshot.messages.add (new Message ("account-test:message", inbox.id, "Sender", "sender@example.net", account.email,
            "Cached", "Preview", "Body", "Today", true, false, false, 1, false, account.id, "1"));
        cache.store_sync_result (snapshot);
        cache.set_cached_read ("account-test:message", true);
        var draft = new Draft (account.id); draft.to = "sender@example.net"; draft.body_text = "Pending";
        cache.queue_for_sending (draft);
        assert (cache.cached_message_count (account.id) == 1); assert (cache.outbox_count () == 1);
        cache.delete_account (account.id);
        assert (cache.list_accounts ().size == 0); assert (cache.cached_message_count (account.id) == 0);
        assert (cache.outbox_count () == 0); assert (cache.draft_count () == 0);
        assert (cache.pending_mutation_count () == 0);
    } catch (Error caught) { GLib.error ("account storage test failed: %s", caught.message); }
    FileUtils.unlink (path);
}

private void test_credential_cleanup_journal () {
    string path = Path.build_filename (Environment.get_tmp_dir (),
        "mailficient-credential-cleanup-%s.sqlite".printf (Uuid.string_random ())) ;
    try {
        var cache = new CacheDatabase (path);
        var account = AccountSettings.for_email ("Alex", "alex@gmail.com"); account.id = "cleanup-account";
        cache.save_account (account); cache.delete_account (account.id);
        assert (cache.find_account (account.id) == null);
        assert (cache.list_pending_credential_cleanups ().size == 1);
        var store = new CleanupCredentialStore (); store.fail_clear = true;
        var service = new CredentialCleanupService (cache, store); bool cleaned = true; var loop = new MainLoop ();
        service.cleanup_account.begin (account.id, null, (object, result) => {
            cleaned = service.cleanup_account.end (result); loop.quit ();
        });
        loop.run (); assert (!cleaned); assert (cache.list_pending_credential_cleanups ().size == 1);
        store.fail_clear = false;
        service.retry_pending.begin (null, (object, result) => {
            service.retry_pending.end (result); loop.quit ();
        });
        loop.run (); assert (cache.list_pending_credential_cleanups ().size == 0); assert (store.clear_calls == 2);

        // Re-importing a deterministic account ID cancels stale cleanup
        // without touching its newly active credentials.
        cache.save_account (account); cache.delete_account (account.id); cache.save_account (account);
        int before = store.clear_calls;
        service.retry_pending.begin (null, (object, result) => {
            service.retry_pending.end (result); loop.quit ();
        });
        loop.run (); assert (store.clear_calls == before);
        assert (cache.list_pending_credential_cleanups ().size == 0);
    } catch (Error error) { GLib.error ("credential cleanup test failed: %s", error.message); }
    FileUtils.unlink (path);
}

private void test_synchronized_cache_repository () {
    string path = Path.build_filename (Environment.get_tmp_dir (), "mailficient-sync-%s.sqlite".printf (Uuid.string_random ()));
    try {
        var cache = new CacheDatabase (path);
        var account = AccountSettings.for_email ("Alex Morgan", "alex@example.net"); account.id = "account-sync";
        account.incoming_host = "imap.example.net"; account.outgoing_host = "smtp.example.net"; cache.save_account (account);
        var snapshot = new MailSyncResult (account.id);
        var inbox = new Mailbox ("account-sync:inbox", "Inbox", "mail-inbox-symbolic", MailboxRole.INBOX, 1, account.id, "INBOX");
        snapshot.mailboxes.add (inbox);
        var archive = new Mailbox ("account-sync:archive", "Archive", "package-x-generic-symbolic", MailboxRole.ARCHIVE, 0, account.id, "Archive");
        snapshot.mailboxes.add (archive);
        snapshot.messages.add (new Message ("account-sync:inbox:42", inbox.id, "Maya Chen", "maya@example.net", "Alex <alex@example.net>",
            "Synced subject", "Synced preview", "Offline body", "Today", true, true, true, 1, false, account.id, "42", "<message-42@example.net>",
            "<parent@example.net>", "<root@example.net> <parent@example.net>"));
        snapshot.messages[0].add_attachment (new Attachment ("received-a1", "/private/received-a1.pdf",
            "received.pdf", 4096, "application/pdf", "<report@example.net>"));
        cache.store_sync_result (snapshot);
        assert (cache.cached_message_count (account.id) == 1);
        assert (cache.list_cached_mailboxes ().size == 2); assert (cache.unified_unread_count () == 1);
        assert (cache.list_cached_messages ("unified-inbox").size == 1);
        var summary = cache.list_cached_messages ("unified-inbox")[0];
        assert (summary.body == ""); assert (summary.body_html == "");
        assert (summary.attachments.size == 0);
        var loaded = cache.find_cached_message ("account-sync:inbox:42"); assert (loaded != null);
        assert (loaded.account_id == account.id); assert (loaded.remote_uid == "42"); assert (loaded.body == "Offline body");
        assert (loaded.internet_message_id == "<message-42@example.net>");
        assert (loaded.in_reply_to == "<parent@example.net>"); assert (loaded.references.has_prefix ("<root@example.net>"));
        assert (loaded.attachments.size == 1); assert (loaded.attachments[0].name == "received.pdf");
        assert (loaded.attachments[0].content_id == "<report@example.net>");
        var conversation = cache.conversation_for (loaded);
        assert (conversation.size == 1); assert (conversation[0].body == "Offline body");
        assert (conversation[0].attachments.size == 1);
        cache.set_cached_read (loaded.id, true); assert (!cache.find_cached_message (loaded.id).unread);
        assert (cache.unified_unread_count () == 0);
        cache.set_cached_flagged (loaded.id, false); assert (!cache.find_cached_message (loaded.id).flagged);
        assert (cache.pending_mutation_count () == 2);
        var repository = new CachedMailRepository (cache, new DemoMailRepository ());
        int repository_changes = 0;
        repository.changed.connect (() => repository_changes++);
        repository.mark_read (loaded.id, true);
        assert (repository_changes == 0);
        assert (cache.pending_mutation_count () == 2);
        assert (repository.list_mailboxes ()[0].id == "unified-inbox");
        assert (repository.list_messages ("unified-inbox").size == 1);
        repository.transfer_to_mailbox (loaded.id, archive.id, true);
        assert (cache.pending_transfer_count () == 1);
        assert (repository.list_messages ("unified-inbox").size == 1);
        var pending_copy = cache.list_pending_transfers (account.id)[0]; assert (pending_copy.copy);
        cache.complete_pending_transfer (pending_copy);
        repository.move_to_role (loaded.id, MailboxRole.ARCHIVE);
        assert (cache.pending_transfer_count () == 1);
        assert (repository.list_messages ("unified-inbox").size == 0);
        assert (repository.list_messages (archive.id).size == 1);
    } catch (Error caught) { GLib.error ("synchronized cache test failed: %s", caught.message); }
    FileUtils.unlink (path);
}

private void test_cached_message_pagination () {
    string path = Path.build_filename (Environment.get_tmp_dir (),
        "mailficient-pages-%s.sqlite".printf (Uuid.string_random ())) ;
    try {
        var cache = new CacheDatabase (path);
        var account = AccountSettings.for_email ("Pager", "pager@example.net");
        account.id = "paged-account"; account.incoming_host = "imap.example.net";
        account.outgoing_host = "smtp.example.net"; cache.save_account (account);
        var inbox = new Mailbox (account.id + ":inbox", "Inbox", "mail-inbox-symbolic",
            MailboxRole.INBOX, 0, account.id, "INBOX");
        var snapshot = new MailSyncResult (account.id); snapshot.mailboxes.add (inbox);
        for (int index = 0; index < 230; index++) {
            string uid = index.to_string ();
            snapshot.messages.add (new Message (account.id + ":inbox:" + uid, inbox.id,
                "Paged Sender", "sender@example.net", account.email,
                "Paged message " + uid, "Summary " + uid, "Body " + uid, "Today",
                index % 2 == 0, false, false, 1, false, account.id, uid));
        }
        cache.store_sync_result (snapshot);

        var first = cache.list_cached_messages ("unified-inbox", 100, 0);
        var second = cache.list_cached_messages ("unified-inbox", 100, 100);
        var third = cache.list_cached_messages ("unified-inbox", 100, 200);
        assert (cache.count_cached_messages ("unified-inbox") == 230);
        assert (cache.count_cached_messages ("unified-inbox", true) == 115);
        assert (first.size == 100); assert (second.size == 100); assert (third.size == 30);
        assert (first[0].remote_uid == "229"); assert (second[0].remote_uid == "129");
        assert (third[0].remote_uid == "29"); assert (first[0].body == "");
        assert (first[99].id != second[0].id); assert (second[99].id != third[0].id);
        var oldest = cache.list_cached_messages ("unified-inbox", 100, 0, false,
            MessageSortMode.OLDEST);
        assert (oldest[0].remote_uid == "0");
        var unread = cache.list_cached_messages ("unified-inbox", 100, 0, true);
        assert (unread.size == 100); assert (unread[0].unread);

        var query = SearchQuery.parse ("Paged");
        var search_first = cache.search_messages (query, 100, 0);
        var search_third = cache.search_messages (query, 100, 200);
        assert (cache.count_search_messages (query) == 230);
        query.unread = true; assert (cache.count_search_messages (query) == 115);
        assert (search_first.size == 100); assert (search_third.size == 30);
        assert (search_first[0].remote_uid == "229"); assert (search_third[0].remote_uid == "29");
    } catch (Error error) { GLib.error ("cached pagination test failed: %s", error.message); }
    FileUtils.unlink (path);
}

private void test_virtual_message_model_is_bounded () {
    int page_loads = 0;
    var model = new VirtualMessageModel (10000, (limit, offset) => {
        page_loads++;
        var page = new Gee.ArrayList<Message> ();
        for (int index = 0; index < limit; index++) {
            int sequence = offset + index;
            page.add (new Message ("virtual-%d".printf (sequence), "inbox", "Sender",
                "sender@example.net", "recipient@example.net", "Message %d".printf (sequence),
                "Preview", "", "Today", false, false, false));
        }
        return page;
    });
    assert (model.get_n_items () == 10000);
    assert ((model.get_item (0) as Message).id == "virtual-0");
    assert ((model.get_item (150) as Message).id == "virtual-150");
    assert ((model.get_item (250) as Message).id == "virtual-250");
    assert (page_loads == 3); assert (model.cached_page_count == 3);
    assert ((model.get_item (350) as Message).id == "virtual-350");
    assert (page_loads == 4); assert (model.cached_page_count == 3);
    // Returning to an evicted page reloads it from the backing store instead
    // of retaining every message summary visited while scrolling.
    assert ((model.get_item (50) as Message).id == "virtual-50");
    assert (page_loads == 5); assert (model.cached_page_count == 3);
    assert (model.get_item (10000) == null);
}

private void test_pending_state_survives_sync () {
    string path = Path.build_filename (Environment.get_tmp_dir (), "mailficient-pending-sync-%s.sqlite".printf (Uuid.string_random ()));
    try {
        var cache = new CacheDatabase (path);
        var account = AccountSettings.for_email ("Alex", "alex@example.net"); account.id = "pending-sync-account";
        account.incoming_host = "imap.example.net"; account.outgoing_host = "smtp.example.net"; cache.save_account (account);
        var inbox = new Mailbox (account.id + ":inbox", "Inbox", "mail-inbox-symbolic", MailboxRole.INBOX, 1, account.id, "INBOX");
        var archive = new Mailbox (account.id + ":archive", "Archive", "package-x-generic-symbolic", MailboxRole.ARCHIVE, 0, account.id, "Archive");
        var initial = new MailSyncResult (account.id); initial.mailboxes.add (inbox); initial.mailboxes.add (archive);
        var message = new Message (account.id + ":inbox:7", inbox.id, "Maya", "maya@example.net", account.email,
            "Offline changes", "", "Original body", "Earlier", true, false, false, 1, false, account.id, "7");
        initial.messages.add (message); cache.store_sync_result (initial);

        cache.set_cached_read (message.id, true);
        cache.set_cached_flagged (message.id, true);
        cache.queue_message_transfer_to (message.id, archive.id, false);
        assert (cache.pending_mutation_count () == 2); assert (cache.pending_transfer_count () == 1);

        // A server snapshot can still contain the old values while these offline
        // operations wait to be retried. Replacing the cache must not undo them.
        var stale = new MailSyncResult (account.id);
        stale.mailboxes.add (new Mailbox (inbox.id, "Inbox", "mail-inbox-symbolic", MailboxRole.INBOX, 1, account.id, "INBOX"));
        stale.mailboxes.add (new Mailbox (archive.id, "Archive", "package-x-generic-symbolic", MailboxRole.ARCHIVE, 0, account.id, "Archive"));
        stale.messages.add (new Message (message.id, inbox.id, "Maya", "maya@example.net", account.email,
            "Offline changes", "", "Fresh body", "Now", true, false, false, 1, false, account.id, "7"));
        cache.store_sync_result (stale);

        var restored = cache.find_cached_message (message.id); assert (restored != null);
        assert (!restored.unread); assert (restored.flagged); assert (restored.mailbox_id == archive.id);
        assert (cache.pending_mutation_count () == 2); assert (cache.pending_transfer_count () == 1);
        foreach (var mailbox in cache.list_cached_mailboxes ()) assert (mailbox.unread_count == 0);
    } catch (Error error) { GLib.error ("pending state sync test failed: %s", error.message); }
    FileUtils.unlink (path);
}

private void test_incremental_sync_merges_and_prunes () {
    string path = Path.build_filename (Environment.get_tmp_dir (), "mailficient-incremental-%s.sqlite".printf (Uuid.string_random ()));
    try {
        var cache = new CacheDatabase (path);
        var inbox = new Mailbox ("incremental:inbox", "Inbox", "mail-inbox-symbolic",
            MailboxRole.INBOX, 1, "incremental", "INBOX");
        var removed_folder = new Mailbox ("incremental:old", "Old", "folder-symbolic",
            MailboxRole.CUSTOM, 0, "incremental", "Old");
        var initial = new MailSyncResult ("incremental"); initial.mailboxes.add (inbox); initial.mailboxes.add (removed_folder);
        initial.messages.add (new Message ("incremental:inbox:1", inbox.id, "Maya", "maya@example.net", "Alex",
            "Keep my body", "Preview", "Downloaded once", "Yesterday", true, false, false, 1, false,
            "incremental", "1"));
        initial.messages.add (new Message ("incremental:old:9", removed_folder.id, "Noah", "noah@example.net", "Alex",
            "Removed folder", "", "Old body", "Earlier", false, false, false, 1, false,
            "incremental", "9"));
        cache.store_sync_result (initial);

        var refresh = new MailSyncResult ("incremental"); refresh.folder_inventory_complete = true;
        refresh.mailboxes.add (new Mailbox (inbox.id, "Inbox", "mail-inbox-symbolic", MailboxRole.INBOX, 0, "incremental", "INBOX"));
        refresh.record_remote_uid (inbox.id, "1"); refresh.record_remote_uid (inbox.id, "2");
        refresh.states.add (new RemoteMessageState ("incremental:inbox:1", false, true));
        refresh.messages.add (new Message ("incremental:inbox:2", inbox.id, "Priya", "priya@example.net", "Alex",
            "New message", "", "New body", "Now", true, false, false, 1, false, "incremental", "2"));
        cache.store_sync_result (refresh);
        assert (cache.cached_message_count ("incremental") == 2);
        var preserved = cache.find_cached_message ("incremental:inbox:1"); assert (preserved != null);
        assert (preserved.body == "Downloaded once"); assert (!preserved.unread); assert (preserved.flagged);
        assert (cache.find_cached_message ("incremental:old:9") == null);

        var deletion = new MailSyncResult ("incremental"); deletion.folder_inventory_complete = true;
        deletion.mailboxes.add (inbox); deletion.record_remote_uid (inbox.id, "2");
        cache.store_sync_result (deletion);
        assert (cache.find_cached_message ("incremental:inbox:1") == null);
        assert (cache.find_cached_message ("incremental:inbox:2") != null);
    } catch (Error error) { GLib.error ("incremental sync merge test failed: %s", error.message); }
    FileUtils.unlink (path);
}

private void test_server_unread_total_survives_partial_cache () {
    string path = Path.build_filename (Environment.get_tmp_dir (), "mailficient-unread-total-%s.sqlite".printf (Uuid.string_random ()));
    try {
        var cache = new CacheDatabase (path);
        var snapshot = new MailSyncResult ("large-account");
        var inbox = new Mailbox ("large-account:inbox", "Inbox", "mail-inbox-symbolic", MailboxRole.INBOX,
            250, "large-account", "INBOX");
        snapshot.mailboxes.add (inbox);
        snapshot.messages.add (new Message ("large-account:inbox:999", inbox.id, "Maya", "maya@example.net", "Alex <alex@example.net>",
            "Newest cached message", "", "Body", "Now", true, false, false, 1, false, "large-account", "999"));
        cache.store_sync_result (snapshot);
        var mailboxes = cache.list_cached_mailboxes ();
        assert (mailboxes.size == 1); assert (mailboxes[0].unread_count == 250);
        assert (cache.unified_unread_count () == 250);
    } catch (Error error) { GLib.error ("authoritative unread total test failed: %s", error.message); }
    FileUtils.unlink (path);
}

private void test_cached_message_ids_do_not_require_message_loading () {
    string path = Path.build_filename (Environment.get_tmp_dir (),
        "mailficient-id-scan-%s.sqlite".printf (Uuid.string_random ()));
    try {
        var cache = new CacheDatabase (path);
        var snapshot = new MailSyncResult ("id-scan-account");
        var inbox = new Mailbox ("id-scan-account:inbox", "Inbox", "mail-inbox-symbolic",
            MailboxRole.INBOX, 2, "id-scan-account", "INBOX");
        snapshot.mailboxes.add (inbox);
        for (int index = 0; index < 2; index++) {
            string body = string.nfill (1024 * 1024, (char) ('a' + index));
            snapshot.messages.add (new Message ("id-scan-account:inbox:%d".printf (index), inbox.id,
                "Sender", "sender@example.net", "recipient@example.net", "Subject", "", body,
                "Now", true, false, false, 1, false, "id-scan-account", index.to_string ()));
        }
        cache.store_sync_result (snapshot);
        var ids = cache.cached_message_ids ("id-scan-account");
        assert (ids.size == 2);
        assert (ids.contains ("id-scan-account:inbox:0"));
        assert (ids.contains ("id-scan-account:inbox:1"));
        var extracted = cache.cached_extracted_message_ids ("id-scan-account");
        assert (extracted.size == 2);
        assert (extracted.contains ("id-scan-account:inbox:0"));
        assert (extracted.contains ("id-scan-account:inbox:1"));
    } catch (Error error) { GLib.error ("cached identity scan test failed: %s", error.message); }
    FileUtils.unlink (path);
}

private void test_pending_unread_move_adjusts_server_totals () {
    string path = Path.build_filename (Environment.get_tmp_dir (), "mailficient-unread-move-%s.sqlite".printf (Uuid.string_random ()));
    try {
        var cache = new CacheDatabase (path);
        var inbox = new Mailbox ("move-account:inbox", "Inbox", "mail-inbox-symbolic", MailboxRole.INBOX, 10, "move-account", "INBOX");
        var archive = new Mailbox ("move-account:archive", "Archive", "package-x-generic-symbolic", MailboxRole.ARCHIVE, 2, "move-account", "Archive");
        var initial = new MailSyncResult ("move-account"); initial.mailboxes.add (inbox); initial.mailboxes.add (archive);
        var message = new Message ("move-account:inbox:5", inbox.id, "Maya", "maya@example.net", "Alex <alex@example.net>",
            "Queued move", "", "Body", "Now", true, false, false, 1, false, "move-account", "5");
        initial.messages.add (message); cache.store_sync_result (initial);
        cache.queue_message_transfer_to (message.id, archive.id, false);

        var stale = new MailSyncResult ("move-account");
        stale.mailboxes.add (new Mailbox (inbox.id, "Inbox", "mail-inbox-symbolic", MailboxRole.INBOX, 10, "move-account", "INBOX"));
        stale.mailboxes.add (new Mailbox (archive.id, "Archive", "package-x-generic-symbolic", MailboxRole.ARCHIVE, 2, "move-account", "Archive"));
        stale.messages.add (new Message (message.id, inbox.id, "Maya", "maya@example.net", "Alex <alex@example.net>",
            "Queued move", "", "Body", "Now", true, false, false, 1, false, "move-account", "5"));
        cache.store_sync_result (stale);
        assert (cache.find_cached_message (message.id).mailbox_id == archive.id);
        foreach (var mailbox in cache.list_cached_mailboxes ()) {
            if (mailbox.id == inbox.id) assert (mailbox.unread_count == 9);
            if (mailbox.id == archive.id) assert (mailbox.unread_count == 3);
        }
    } catch (Error error) { GLib.error ("queued unread move count test failed: %s", error.message); }
    FileUtils.unlink (path);
}

private void test_sync_pipeline () {
    string root = Path.build_filename (Environment.get_tmp_dir (), "mailficient-sync-pipeline-%s".printf (Uuid.string_random ()));
    try {
        assert (DirUtils.create_with_parents (root, 0700) == 0);
        var cache = new CacheDatabase (Path.build_filename (root, "mail.sqlite"));
        var account = AccountSettings.for_email ("Alex", "alex@example.net"); account.id = "pipeline-account";
        account.incoming_host = "imap.example.net"; account.outgoing_host = "smtp.example.net"; cache.save_account (account);
        var initial = new MailSyncResult (account.id);
        var inbox = new Mailbox (account.id + ":inbox", "Inbox", "mail-inbox-symbolic", MailboxRole.INBOX, 1, account.id, "INBOX");
        var archive = new Mailbox (account.id + ":archive", "Archive", "package-x-generic-symbolic", MailboxRole.ARCHIVE, 0, account.id, "Archive");
        initial.mailboxes.add (inbox); initial.mailboxes.add (archive);
        var existing = new Message (account.id + ":inbox:1", inbox.id, "Maya", "maya@example.net", account.email,
            "Existing", "", "Cached body", "Earlier", true, false, false, 1, false, account.id, "1");
        initial.messages.add (existing); cache.store_sync_result (initial);
        cache.set_cached_read (existing.id, true);
        cache.queue_message_transfer_to (existing.id, archive.id, true);
        var queued = new Draft (account.id); queued.to = "maya@example.net"; queued.body_text = "Queued body"; cache.queue_for_sending (queued);

        var engine = new RecordingMailEngine (account.id);
        engine.snapshot.mailboxes.add (inbox); engine.snapshot.mailboxes.add (archive);
        engine.snapshot.messages.add (new Message (existing.id, inbox.id, "Maya", "maya@example.net", account.email,
            "Existing", "", "Fresh body", "Earlier", false, false, false, 1, false, account.id, "1"));
        var incoming = new Message (account.id + ":inbox:2", inbox.id, "Noah", "noah@example.org", account.email,
            "New message", "", "New body", "Now", true, false, false, 1, false, account.id, "2");
        engine.snapshot.messages.add (incoming);
        engine.snapshot.messages_to_download = 2;
        var attachments = new AttachmentService (Path.build_filename (root, "attachments"));
        var outbound = new OutboundService (cache, engine, attachments);
        var service = new AccountSyncService (cache, engine, outbound, new JunkFilterService (cache));
        int synchronized_count = 0; int notification_count = 0; int failure_count = 0;
        bool saw_download_progress = false;
        service.synchronized.connect ((id) => { if (id == account.id) synchronized_count++; });
        service.new_message.connect ((message) => { if (message.id == incoming.id) notification_count++; });
        service.failed.connect ((id, error) => { failure_count++; });
        service.progress_changed.connect ((id, fraction, detail) => {
            if (id == account.id && fraction == 0.5 && detail == "Downloaded 1 of 2 messages")
                saw_download_progress = true;
        });
        var loop = new MainLoop ();
        service.sync_account.begin (account, null, (object, result) => {
            service.sync_account.end (result); loop.quit ();
        });
        loop.run ();
        assert (failure_count == 0); assert (synchronized_count == 1); assert (notification_count == 1);
        assert (saw_download_progress);
        assert (engine.connect_calls == 2); assert (engine.send_calls == 1); assert (engine.synchronize_calls == 1);
        assert (engine.state_changes.size == 1); assert (engine.transfers.size == 1);
        assert (cache.outbox_count () == 0); assert (cache.pending_mutation_count () == 0); assert (cache.pending_transfer_count () == 0);
        assert (cache.find_cached_message (incoming.id) != null);
    } catch (Error error) { GLib.error ("sync pipeline test failed: %s", error.message); }
}

private int64 current_rss_kb () {
    string contents;
    try {
        FileUtils.get_contents ("/proc/self/status", out contents);
        foreach (var line in contents.split ("\n")) {
            if (!line.has_prefix ("VmRSS:")) continue;
            var fields = line.split_set (" \t");
            foreach (var field in fields)
                if (field != "" && field[0] >= '0' && field[0] <= '9')
                    return int64.parse (field);
        }
    } catch (Error ignored) { }
    return 0;
}

private void test_long_running_streamed_sync_is_bounded () {
    string root = Path.build_filename (Environment.get_tmp_dir (),
        "mailficient-sync-stress-%s".printf (Uuid.string_random ())) ;
    try {
        assert (DirUtils.create_with_parents (root, 0700) == 0);
        var cache = new CacheDatabase (Path.build_filename (root, "mail.sqlite"));
        var account = AccountSettings.for_email ("Stress", "stress@example.net");
        account.id = "stress-account"; account.incoming_host = "imap.example.net";
        account.outgoing_host = "smtp.example.net"; cache.save_account (account);
        var inbox = new Mailbox (account.id + ":inbox", "Inbox", "mail-inbox-symbolic",
            MailboxRole.INBOX, 5000, account.id, "INBOX");
        var initial = new MailSyncResult (account.id); initial.mailboxes.add (inbox);
        initial.messages.add (new Message (account.id + ":inbox:seed", inbox.id, "Seed",
            "seed@example.net", account.email, "Seed", "", "Seed", "Earlier", false,
            false, false, 1, false, account.id, "seed"));
        cache.store_sync_result (initial);

        var engine = new RecordingMailEngine (account.id);
        var attachments = new AttachmentService (Path.build_filename (root, "attachments"));
        var service = new AccountSyncService (cache, engine,
            new OutboundService (cache, engine, attachments), new JunkFilterService (cache));
        int notifications = 0; int failures = 0; int successes = 0;
        service.new_message.connect ((message) => notifications++);
        service.failed.connect ((id, error) => failures++);
        service.synchronized.connect ((id) => successes++);
        int64 baseline_rss = current_rss_kb (); int64 peak_rss = baseline_rss;
        var loop = new MainLoop ();

        for (int round = 0; round < 240; round++) {
            engine.batches.clear ();
            engine.snapshot = new MailSyncResult (account.id);
            engine.snapshot.mailboxes.add (inbox);
            if (round % 6 == 5) {
                engine.synchronize_failure = new MailError.OFFLINE ("Synthetic network interruption");
            } else {
                engine.synchronize_failure = null;
                for (int batch_index = 0; batch_index < 5; batch_index++) {
                    var batch = new MailSyncResult (account.id); batch.mailboxes.add (inbox);
                    for (int item = 0; item < 20; item++) {
                        int sequence = round * 100 + batch_index * 20 + item;
                        batch.messages.add (new Message (
                            "%s:inbox:%d".printf (account.id, sequence), inbox.id,
                            "Sender", "sender@example.net", account.email,
                            "Stress message %d".printf (sequence), "", string.nfill (1024, 'x'),
                            "Now", true, false, false, 1, false, account.id, sequence.to_string ()));
                    }
                    engine.batches.add (batch);
                }
            }
            service.sync_account.begin (account, null, (object, result) => {
                service.sync_account.end (result); loop.quit ();
            });
            loop.run ();
            peak_rss = int64.max (peak_rss, current_rss_kb ());
        }

        // Forty interrupted passes preserve their queues and cache; two hundred
        // successful passes install 20,000 messages while notifying at most five
        // times per pass and releasing the backend after every pass.
        assert (failures == 40); assert (successes == 200);
        assert (notifications == 1000);
        assert (cache.cached_message_count (account.id) == 20001);
        assert (engine.disconnect_calls == 0);
        assert (engine.maximum_active_synchronizations == 1);
        var summaries = cache.list_cached_messages (inbox.id);
        assert (summaries.size == CacheDatabase.MESSAGE_LIST_LIMIT);
        foreach (var summary in summaries) {
            assert (summary.body == ""); assert (summary.body_html == "");
            assert (summary.attachments.size == 0);
        }
        if (baseline_rss > 0)
            assert (peak_rss - baseline_rss < 128 * 1024);
    } catch (Error error) { GLib.error ("streamed synchronization stress test failed: %s", error.message); }
}

private void test_automatic_history_backfill () {
    string root = Path.build_filename (Environment.get_tmp_dir (),
        "mailficient-auto-backfill-%s".printf (Uuid.string_random ())) ;
    try {
        assert (DirUtils.create_with_parents (root, 0700) == 0);
        var cache = new CacheDatabase (Path.build_filename (root, "mail.sqlite"));
        var account = AccountSettings.for_email ("Backfill", "backfill@example.net");
        account.id = "backfill-account"; account.incoming_host = "imap.example.net";
        account.outgoing_host = "smtp.example.net"; cache.save_account (account);
        var inbox = new Mailbox (account.id + ":inbox", "Inbox", "mail-inbox-symbolic",
            MailboxRole.INBOX, 4, account.id, "INBOX");
        var initial = new MailSyncResult (account.id); initial.mailboxes.add (inbox);
        initial.messages.add (new Message (account.id + ":inbox:seed", inbox.id, "Seed",
            "seed@example.net", account.email, "Seed", "", "Seed", "Earlier", false,
            false, false, 1, false, account.id, "seed"));
        cache.store_sync_result (initial);

        var engine = new RecordingMailEngine (account.id);
        for (int pass = 0; pass < 3; pass++) {
            var snapshot = new MailSyncResult (account.id); snapshot.mailboxes.add (inbox);
            snapshot.messages_to_download = 3 - pass;
            snapshot.messages.add (new Message ("%s:inbox:%d".printf (account.id, pass),
                inbox.id, "History", "history@example.net", account.email,
                "History %d".printf (pass), "", "Body", "Earlier", true, false,
                false, 1, false, account.id, pass.to_string ()));
            snapshot.more_messages_available = pass < 2;
            engine.queued_snapshots.add (snapshot);
        }
        var attachments = new AttachmentService (Path.build_filename (root, "attachments"));
        var service = new AccountSyncService (cache, engine,
            new OutboundService (cache, engine, attachments), new JunkFilterService (cache));
        int completed = 0; int checkpoints = 0; int notifications = 0; int failures = 0;
        bool saw_initial_total = false; bool saw_background_total = false;
        service.synchronized.connect ((id) => completed++);
        service.pass_completed.connect ((id) => checkpoints++);
        service.new_message.connect ((message) => notifications++);
        service.failed.connect ((id, error) => failures++);
        service.progress_changed.connect ((id, fraction, detail) => {
            if (detail == "Downloaded 0 of 3 messages") saw_initial_total = true;
            if (detail == "Downloaded 1 of 3 messages — continuing in background") saw_background_total = true;
        });
        var loop = new MainLoop ();
        service.sync_account.begin (account, null, (object, result) => {
            service.sync_account.end (result);
        });
        uint timeout_source = Timeout.add_seconds (8, () => { loop.quit (); return Source.REMOVE; });
        service.synchronized.connect ((id) => {
            if (completed >= 3) loop.quit ();
        });
        loop.run ();
        if (timeout_source != 0) Source.remove (timeout_source);
        assert (failures == 0); assert (completed == 3); assert (checkpoints == 2);
        assert (engine.synchronize_calls == 3); assert (engine.disconnect_calls == 0);
        assert (cache.cached_message_count (account.id) == 4);
        assert (saw_initial_total); assert (saw_background_total);
        // Each streamed pass announces newly cached mail while the remaining
        // history continues automatically in the background.
        assert (notifications == 3);
    } catch (Error error) { GLib.error ("automatic backfill test failed: %s", error.message); }
}

private void test_active_sync_can_be_cancelled () {
    string root = Path.build_filename (Environment.get_tmp_dir (),
        "mailficient-cancel-sync-%s".printf (Uuid.string_random ())) ;
    try {
        assert (DirUtils.create_with_parents (root, 0700) == 0);
        var cache = new CacheDatabase (Path.build_filename (root, "mail.sqlite"));
        var account = AccountSettings.for_email ("Cancel", "cancel@example.net");
        account.id = "cancel-account"; account.incoming_host = "imap.example.net";
        account.outgoing_host = "smtp.example.net"; cache.save_account (account);
        var engine = new RecordingMailEngine (account.id);
        engine.delay_synchronization = true;
        var attachments = new AttachmentService (Path.build_filename (root, "attachments"));
        var service = new AccountSyncService (cache, engine,
            new OutboundService (cache, engine, attachments), new JunkFilterService (cache));
        int cancellations = 0; int failures = 0; int completions = 0;
        service.cancelled.connect ((id) => { if (id == account.id) cancellations++; });
        service.failed.connect ((id, error) => failures++);
        service.synchronized.connect ((id) => completions++);
        var loop = new MainLoop ();
        service.sync_account.begin (account, null, (object, result) => {
            service.sync_account.end (result); loop.quit ();
        });
        Timeout.add (2, () => { service.cancel (); return Source.REMOVE; });
        loop.run ();
        assert (cancellations == 1); assert (failures == 0); assert (completions == 0);
        assert (engine.disconnect_calls == 0);
    } catch (Error error) { GLib.error ("sync cancellation test failed: %s", error.message); }
}

private void test_partial_sync_is_installed_and_reported () {
    string root = Path.build_filename (Environment.get_tmp_dir (),
        "mailficient-partial-sync-%s".printf (Uuid.string_random ())) ;
    try {
        assert (DirUtils.create_with_parents (root, 0700) == 0);
        var cache = new CacheDatabase (Path.build_filename (root, "mail.sqlite"));
        var account = AccountSettings.for_email ("Alex", "alex@example.net");
        account.id = "partial-account"; account.incoming_host = "imap.example.net";
        account.outgoing_host = "smtp.example.net"; cache.save_account (account);
        var inbox = new Mailbox (account.id + ":inbox", "Inbox", "mail-inbox-symbolic",
            MailboxRole.INBOX, 1, account.id, "INBOX");
        var archive = new Mailbox (account.id + ":archive", "Archive", "package-x-generic-symbolic",
            MailboxRole.ARCHIVE, 0, account.id, "Archive");
        var initial = new MailSyncResult (account.id);
        initial.mailboxes.add (inbox); initial.mailboxes.add (archive);
        var preserved = new Message (account.id + ":archive:1", archive.id, "Maya",
            "maya@example.net", account.email, "Keep cached", "", "Offline body", "Earlier",
            false, false, false, 1, false, account.id, "1");
        initial.messages.add (preserved); cache.store_sync_result (initial);

        var engine = new RecordingMailEngine (account.id);
        engine.snapshot.folder_inventory_complete = true;
        engine.snapshot.mailboxes.add (inbox); engine.snapshot.mailboxes.add (archive);
        var incoming = new Message (account.id + ":inbox:2", inbox.id, "Noah",
            "noah@example.net", account.email, "Downloaded successfully", "", "New body", "Now",
            true, false, false, 1, false, account.id, "2");
        engine.snapshot.messages.add (incoming);
        engine.snapshot.record_remote_uid (inbox.id, "2");
        engine.snapshot.record_issue ("Archive",
            new MailError.CONNECTION ("A server message could not be downloaded"));

        var attachments = new AttachmentService (Path.build_filename (root, "attachments"));
        var service = new AccountSyncService (cache, engine,
            new OutboundService (cache, engine, attachments), new JunkFilterService (cache));
        int synchronized_count = 0; int failure_count = 0; UserFacingError? reported = null;
        service.synchronized.connect ((id) => { if (id == account.id) synchronized_count++; });
        service.failed.connect ((id, error) => {
            if (id == account.id) { failure_count++; reported = error; }
        });
        var loop = new MainLoop ();
        service.sync_account.begin (account, null, (object, result) => {
            service.sync_account.end (result); loop.quit ();
        });
        loop.run ();
        assert (synchronized_count == 1); assert (failure_count == 1); assert (reported != null);
        assert (reported.title == "Some mail could not be updated");
        assert (reported.technical_detail.contains ("Archive"));
        assert (cache.find_cached_message (incoming.id) != null);
        assert (cache.find_cached_message (preserved.id) != null);

        engine.snapshot.terminal_error = new MailError.AUTHENTICATION ("OAuth authorization expired");
        service.sync_account.begin (account, null, (object, result) => {
            service.sync_account.end (result); loop.quit ();
        });
        loop.run ();
        assert (synchronized_count == 2); assert (failure_count == 2);
        assert (reported.title == "Sign-in failed");
    } catch (Error error) { GLib.error ("partial synchronization test failed: %s", error.message); }
}

private void test_mutation_flush_serialization () {
    string root = Path.build_filename (Environment.get_tmp_dir (), "mailficient-flush-race-%s".printf (Uuid.string_random ()));
    try {
        assert (DirUtils.create_with_parents (root, 0700) == 0);
        var cache = new CacheDatabase (Path.build_filename (root, "mail.sqlite"));
        var account = AccountSettings.for_email ("Alex", "alex@example.net"); account.id = "race-account";
        account.incoming_host = "imap.example.net"; account.outgoing_host = "smtp.example.net"; cache.save_account (account);
        var snapshot = new MailSyncResult (account.id);
        var inbox = new Mailbox (account.id + ":inbox", "Inbox", "mail-inbox-symbolic", MailboxRole.INBOX, 1, account.id, "INBOX");
        snapshot.mailboxes.add (inbox);
        var message = new Message (account.id + ":inbox:1", inbox.id, "Maya", "maya@example.net", account.email,
            "Race", "", "Body", "Now", true, false, false, 1, false, account.id, "1");
        snapshot.messages.add (message); cache.store_sync_result (snapshot);
        var engine = new RecordingMailEngine (account.id); engine.delay_changes = true;
        var attachments = new AttachmentService (Path.build_filename (root, "attachments"));
        var service = new AccountSyncService (cache, engine, new OutboundService (cache, engine, attachments),
            new JunkFilterService (cache));
        assert (service != null);
        cache.set_cached_read (message.id, true);
        cache.set_cached_flagged (message.id, true);
        var loop = new MainLoop (); bool timed_out = false;
        uint timeout_id = Timeout.add (8000, () => { timed_out = true; loop.quit (); return Source.REMOVE; });
        Timeout.add (5, () => {
            try {
                if (cache.pending_mutation_count () != 0) return Source.CONTINUE;
            } catch (Error error) { timed_out = true; }
            if (!timed_out) Source.remove (timeout_id);
            loop.quit (); return Source.REMOVE;
        });
        loop.run ();
        assert (!timed_out); assert (engine.state_changes.size == 2);
        assert (engine.state_changes[0] != engine.state_changes[1]);
    } catch (Error error) { GLib.error ("mutation serialization test failed: %s", error.message); }
}

private void test_account_sync_serialization () {
    string root = Path.build_filename (Environment.get_tmp_dir (), "mailficient-sync-race-%s".printf (Uuid.string_random ()));
    try {
        assert (DirUtils.create_with_parents (root, 0700) == 0);
        var cache = new CacheDatabase (Path.build_filename (root, "mail.sqlite"));
        var account = AccountSettings.for_email ("Alex", "alex@example.net"); account.id = "sync-race-account";
        account.incoming_host = "imap.example.net"; account.outgoing_host = "smtp.example.net"; cache.save_account (account);
        var engine = new RecordingMailEngine (account.id); engine.delay_synchronization = true;
        engine.snapshot.mailboxes.add (new Mailbox (account.id + ":inbox", "Inbox", "mail-inbox-symbolic",
            MailboxRole.INBOX, 0, account.id, "INBOX"));
        var attachments = new AttachmentService (Path.build_filename (root, "attachments"));
        var service = new AccountSyncService (cache, engine, new OutboundService (cache, engine, attachments),
            new JunkFilterService (cache));
        int completed = 0; var loop = new MainLoop ();
        service.sync_account.begin (account, null, (object, result) => {
            service.sync_account.end (result); completed++; if (completed == 2) loop.quit ();
        });
        service.sync_account.begin (account, null, (object, result) => {
            service.sync_account.end (result); completed++; if (completed == 2) loop.quit ();
        });
        loop.run ();
        assert (engine.synchronize_calls == 2); assert (engine.maximum_active_synchronizations == 1);
    } catch (Error error) { GLib.error ("account sync serialization test failed: %s", error.message); }
}

private void test_chained_move_remaps_server_identity () {
    string path = Path.build_filename (Environment.get_tmp_dir (),
        "mailficient-chained-move-%s.sqlite".printf (Uuid.string_random ()));
    try {
        var cache = new CacheDatabase (path);
        string account_id = "chained-move";
        var inbox = new Mailbox (account_id + ":inbox", "Inbox", "mail-inbox-symbolic",
            MailboxRole.INBOX, 1, account_id, "INBOX");
        var archive = new Mailbox (account_id + ":archive", "Archive", "package-x-generic-symbolic",
            MailboxRole.ARCHIVE, 0, account_id, "Archive");
        var trash = new Mailbox (account_id + ":trash", "Trash", "user-trash-symbolic",
            MailboxRole.TRASH, 0, account_id, "Trash");
        var snapshot = new MailSyncResult (account_id);
        snapshot.mailboxes.add (inbox); snapshot.mailboxes.add (archive); snapshot.mailboxes.add (trash);
        var message = new Message (account_id + ":inbox:1", inbox.id, "Maya", "maya@example.net",
            "Alex", "Move twice", "", "Body", "Now", true, false, false, 1, false, account_id, "1");
        snapshot.messages.add (message); cache.store_sync_result (snapshot);

        cache.queue_message_transfer_to (message.id, archive.id, false);
        var first = cache.list_pending_transfers (account_id)[0];
        cache.queue_message_transfer_to (message.id, trash.id, false);
        cache.set_cached_flagged (message.id, true);
        cache.complete_pending_transfer (first, "archive-77");

        var chained = cache.list_pending_transfers (account_id);
        assert (chained.size == 1);
        assert (chained[0].source_mailbox == "Archive");
        assert (chained[0].destination_mailbox == "Trash");
        assert (chained[0].remote_uid == "archive-77");
        var mutations = cache.list_pending_mutations (account_id);
        assert (mutations.size == 1);
        assert (mutations[0].mailbox_name == "Archive");
        assert (mutations[0].remote_uid == "archive-77");

        cache.complete_pending_transfer (chained[0], "trash-91");
        assert (cache.pending_transfer_count () == 0);
        mutations = cache.list_pending_mutations (account_id);
        assert (mutations[0].mailbox_name == "Trash");
        assert (mutations[0].remote_uid == "trash-91");
    } catch (Error error) { GLib.error ("chained move identity test failed: %s", error.message); }
    FileUtils.unlink (path);
}

private void test_undo_and_permanent_deletion_pipeline () {
    string root = Path.build_filename (Environment.get_tmp_dir (),
        "mailficient-delete-pipeline-%s".printf (Uuid.string_random ())) ;
    try {
        assert (DirUtils.create_with_parents (root, 0700) == 0);
        var cache = new CacheDatabase (Path.build_filename (root, "mail.sqlite"));
        var account = AccountSettings.for_email ("Alex", "alex@example.net"); account.id = "delete-account";
        account.incoming_host = "imap.example.net"; account.outgoing_host = "smtp.example.net";
        cache.save_account (account);
        var inbox = new Mailbox (account.id + ":inbox", "Inbox", "mail-inbox-symbolic",
            MailboxRole.INBOX, 0, account.id, "INBOX");
        var trash = new Mailbox (account.id + ":trash", "Trash", "user-trash-symbolic",
            MailboxRole.TRASH, 1, account.id, "Trash");
        var junk = new Mailbox (account.id + ":junk", "Junk", "dialog-warning-symbolic",
            MailboxRole.JUNK, 4, account.id, "Junk");
        var snapshot = new MailSyncResult (account.id);
        snapshot.mailboxes.add (inbox); snapshot.mailboxes.add (trash); snapshot.mailboxes.add (junk);
        var moving = new Message (account.id + ":inbox:1", inbox.id, "Maya", "maya@example.net",
            account.email, "Undo then delete", "", "Body", "Now", false, false, false, 1, false,
            account.id, "1");
        var junk_message = new Message (account.id + ":junk:2", junk.id, "Offer", "offer@example.net",
            account.email, "Purge", "", "Body", "Now", false, false, false, 1, false,
            account.id, "2");
        snapshot.messages.add (moving); snapshot.messages.add (junk_message); cache.store_sync_result (snapshot);

        cache.queue_message_transfer_to (moving.id, trash.id, false);
        assert (cache.find_cached_message (moving.id).mailbox_id == trash.id);
        cache.undo_queued_transfer (moving.id, inbox.id);
        assert (cache.pending_transfer_count () == 0);
        assert (cache.find_cached_message (moving.id).mailbox_id == inbox.id);

        cache.queue_message_transfer_to (moving.id, trash.id, false);
        cache.queue_permanent_delete (moving.id);
        assert (cache.find_cached_message (moving.id) == null);
        assert (cache.list_pending_deletions (account.id).size == 1);
        cache.queue_role_purge (MailboxRole.JUNK);
        assert (cache.find_cached_message (junk_message.id) == null);
        assert (cache.list_pending_folder_purges (account.id).size == 1);
        foreach (var mailbox in cache.list_cached_mailboxes ()) {
            if (mailbox.id == junk.id) assert (mailbox.unread_count == 0);
            if (mailbox.id == trash.id) assert (mailbox.unread_count == 1);
        }

        var engine = new RecordingMailEngine (account.id);
        engine.snapshot.mailboxes.add (inbox); engine.snapshot.mailboxes.add (trash); engine.snapshot.mailboxes.add (junk);
        var attachments = new AttachmentService (Path.build_filename (root, "attachments"));
        var service = new AccountSyncService (cache, engine, new OutboundService (cache, engine, attachments),
            new JunkFilterService (cache));
        var loop = new MainLoop ();
        service.sync_account.begin (account, null, (object, result) => {
            service.sync_account.end (result); loop.quit ();
        });
        loop.run ();
        assert (engine.operations[0] == "transfer:INBOX:1");
        assert (engine.operations[1] == "delete:Trash:destination-1");
        assert (engine.operations[2] == "empty:Junk");
        assert (cache.pending_transfer_count () == 0);
        assert (cache.list_pending_deletions (account.id).size == 0);
        assert (cache.list_pending_folder_purges (account.id).size == 0);
    } catch (Error error) { GLib.error ("undo/delete pipeline test failed: %s", error.message); }
}

private void test_move_flushes_state_before_transfer () {
    string root = Path.build_filename (Environment.get_tmp_dir (),
        "mailficient-move-order-%s".printf (Uuid.string_random ()));
    try {
        assert (DirUtils.create_with_parents (root, 0700) == 0);
        var cache = new CacheDatabase (Path.build_filename (root, "mail.sqlite"));
        var account = AccountSettings.for_email ("Alex", "alex@example.net"); account.id = "move-order";
        account.incoming_host = "imap.example.net"; account.outgoing_host = "smtp.example.net";
        cache.save_account (account);
        var inbox = new Mailbox (account.id + ":inbox", "Inbox", "mail-inbox-symbolic",
            MailboxRole.INBOX, 1, account.id, "INBOX");
        var archive = new Mailbox (account.id + ":archive", "Archive", "package-x-generic-symbolic",
            MailboxRole.ARCHIVE, 0, account.id, "Archive");
        var initial = new MailSyncResult (account.id); initial.mailboxes.add (inbox); initial.mailboxes.add (archive);
        var message = new Message (account.id + ":inbox:5", inbox.id, "Maya", "maya@example.net",
            account.email, "Offline ordering", "", "Body", "Now", true, false, false, 1, false,
            account.id, "5");
        initial.messages.add (message); cache.store_sync_result (initial);

        // This is the formerly deadlocking order: move locally, then change a
        // flag while the server still has the message in the source folder.
        cache.queue_message_transfer_to (message.id, archive.id, false);
        cache.set_cached_flagged (message.id, true);
        var engine = new RecordingMailEngine (account.id);
        engine.snapshot.mailboxes.add (inbox); engine.snapshot.mailboxes.add (archive);
        var attachments = new AttachmentService (Path.build_filename (root, "attachments"));
        var service = new AccountSyncService (cache, engine, new OutboundService (cache, engine, attachments),
            new JunkFilterService (cache));
        var loop = new MainLoop ();
        service.sync_account.begin (account, null, (object, result) => {
            service.sync_account.end (result); loop.quit ();
        });
        loop.run ();

        assert (engine.operations.size == 2);
        assert (engine.operations[0] == "state:INBOX:5");
        assert (engine.operations[1] == "transfer:INBOX:5");
        assert (cache.pending_mutation_count () == 0);
        assert (cache.pending_transfer_count () == 0);
    } catch (Error error) { GLib.error ("move/state ordering test failed: %s", error.message); }
}

private void test_junk_classification_is_durable () {
    string root = Path.build_filename (Environment.get_tmp_dir (),
        "mailficient-junk-%s".printf (Uuid.string_random ())) ;
    try {
        assert (DirUtils.create_with_parents (root, 0700) == 0);
        var cache = new CacheDatabase (Path.build_filename (root, "mail.sqlite"));
        var account = AccountSettings.for_email ("Alex", "alex@example.net"); account.id = "junk-account";
        account.incoming_host = "imap.example.net"; account.outgoing_host = "smtp.example.net";
        cache.save_account (account);
        var inbox = new Mailbox (account.id + ":inbox", "Inbox", "mail-inbox-symbolic",
            MailboxRole.INBOX, 1, account.id, "INBOX");
        var junk = new Mailbox (account.id + ":junk", "Junk", "dialog-warning-symbolic",
            MailboxRole.JUNK, 0, account.id, "[Gmail]/Spam");
        var local_junk = new Mailbox (account.id + ":local-junk", "Junk", "dialog-warning-symbolic",
            MailboxRole.JUNK, 0, account.id, ".#evolution/Junk");
        var initial = new MailSyncResult (account.id); initial.mailboxes.add (inbox);
        initial.mailboxes.add (local_junk); initial.mailboxes.add (junk);
        var message = new Message (account.id + ":inbox:12", inbox.id, "Suspicious Sender",
            "sender@example.net", account.email, "Limited offer", "", "Body", "Now", true,
            false, false, 1, false, account.id, "12");
        initial.messages.add (message); cache.store_sync_result (initial);

        var repository = new CachedMailRepository (cache, new DemoMailRepository ());
        repository.classify_junk (message.id, true);
        assert (cache.find_cached_message (message.id).mailbox_id == junk.id);
        assert (cache.list_junk_rules ().size == 1);
        assert (cache.list_junk_rules ()[0].kind == JunkRuleKind.ADDRESS);
        assert (cache.list_junk_rules ()[0].pattern == "sender@example.net");
        assert (cache.pending_transfer_count () == 1);
        assert (cache.list_pending_transfers (account.id)[0].destination_mailbox == "[Gmail]/Spam");
        var mutations = cache.list_pending_mutations (account.id);
        assert (mutations.size == 2);
        bool saw_junk = false; bool saw_not_junk = false;
        foreach (var mutation in mutations) {
            if (mutation.field == MessageStateField.JUNK) { saw_junk = true; assert (mutation.value); }
            if (mutation.field == MessageStateField.NOT_JUNK) { saw_not_junk = true; assert (!mutation.value); }
        }
        assert (saw_junk && saw_not_junk);

        var engine = new RecordingMailEngine (account.id);
        engine.snapshot.mailboxes.add (inbox); engine.snapshot.mailboxes.add (junk);
        var attachments = new AttachmentService (Path.build_filename (root, "attachments"));
        var service = new AccountSyncService (cache, engine, new OutboundService (cache, engine, attachments),
            new JunkFilterService (cache));
        var loop = new MainLoop ();
        service.sync_account.begin (account, null, (object, result) => {
            service.sync_account.end (result); loop.quit ();
        });
        loop.run ();
        assert (engine.state_changes.contains ("12:2:true"));
        assert (engine.state_changes.contains ("12:3:false"));
        assert (engine.transfers.contains ("12:[Gmail]/Spam:false"));
        assert (cache.pending_mutation_count () == 0);
        assert (cache.pending_transfer_count () == 0);

        // The next server snapshot identifies the moved message by its Spam
        // folder identity. It must replace, not duplicate, the optimistic
        // Inbox-derived cache row.
        var confirmed = new Message (junk.id + ":destination-12", junk.id,
            message.sender_name, message.sender_address, message.recipients,
            message.subject, message.preview, message.body, message.timestamp,
            message.unread, message.flagged, message.has_attachment,
            message.conversation_count, message.has_remote_content, account.id,
            "destination-12", message.internet_message_id);
        var confirmation = new MailSyncResult (account.id);
        confirmation.mailboxes.add (junk); confirmation.messages.add (confirmed);
        cache.store_sync_result (confirmation);
        assert (cache.list_cached_messages ("unified-junk").size == 1);
        assert (cache.find_cached_message (message.id) == null);
        assert (cache.find_cached_message (confirmed.id) != null);
    } catch (Error error) { GLib.error ("junk classification test failed: %s", error.message); }
}

private void test_junk_rules_and_filter () {
    string path = Path.build_filename (Environment.get_tmp_dir (),
        "mailficient-junk-rules-%s.sqlite".printf (Uuid.string_random ())) ;
    try {
        var cache = new CacheDatabase (path);
        assert (JunkRule.normalize (JunkRuleKind.DOMAIN, " @Example.NET ") == "example.net");
        assert (new JunkRule (1, JunkRuleKind.DOMAIN, "example.net").matches ("Offer@Example.NET"));
        bool rejected = false;
        try { JunkRule.normalize (JunkRuleKind.ADDRESS, "not-an-address"); }
        catch (MailError error) { rejected = error is MailError.INVALID_ACCOUNT; }
        assert (rejected);
        cache.add_junk_rule (JunkRuleKind.DOMAIN, "@example.net");
        cache.add_junk_rule (JunkRuleKind.DOMAIN, "EXAMPLE.NET");
        cache.add_junk_rule (JunkRuleKind.ADDRESS, "specific@example.org");
        assert (cache.list_junk_rules ().size == 2);

        string account_id = "rule-account";
        var inbox = new Mailbox (account_id + ":inbox", "Inbox", "mail-inbox-symbolic",
            MailboxRole.INBOX, 1, account_id, "INBOX");
        var junk = new Mailbox (account_id + ":junk", "Junk", "dialog-warning-symbolic",
            MailboxRole.JUNK, 0, account_id, "Junk");
        var snapshot = new MailSyncResult (account_id); snapshot.mailboxes.add (inbox); snapshot.mailboxes.add (junk);
        var message = new Message (account_id + ":inbox:8", inbox.id, "Offer", "offer@example.net",
            "Alex", "Offer", "", "Body", "Now", true, false, false, 1, false, account_id, "8");
        snapshot.messages.add (message); cache.store_sync_result (snapshot);
        var filter = new JunkFilterService (cache);
        assert (filter.apply (snapshot) == 1);
        assert (cache.find_cached_message (message.id).mailbox_id == junk.id);
        assert (cache.pending_mutation_count () == 2); assert (cache.pending_transfer_count () == 1);
        assert (filter.apply (snapshot) == 0);
        var rules = cache.list_junk_rules (); cache.remove_junk_rule (rules[0].id);
        assert (cache.list_junk_rules ().size == 1);
    } catch (Error error) { GLib.error ("junk rule test failed: %s", error.message); }
    FileUtils.unlink (path);
}

private void test_demo_actions () {
    try {
        var demo = new DemoMailRepository ();
        uint inbox_unread = uint.MAX; uint vip_unread = uint.MAX; uint flagged_unread = uint.MAX;
        foreach (var mailbox in demo.list_mailboxes ()) {
            if (mailbox.role == MailboxRole.INBOX) inbox_unread = mailbox.unread_count;
            if (mailbox.role == MailboxRole.VIP) vip_unread = mailbox.unread_count;
            if (mailbox.role == MailboxRole.FLAGGED) flagged_unread = mailbox.unread_count;
        }
        assert (inbox_unread == 3); assert (vip_unread == 1); assert (flagged_unread == 1);
        var message = demo.find_message ("1"); assert (message != null);
        assert (message.account_id == DemoMailRepository.ACCOUNT_ID);
        assert (message.attachments.size == 2);
        assert (AttachmentSafety.preview_kind (message.attachments[0].content_type, message.attachments[0].name) == AttachmentPreviewKind.TEXT);
        assert (AttachmentSafety.preview_kind (message.attachments[1].content_type, message.attachments[1].name) == AttachmentPreviewKind.IMAGE);
        int changes = 0; demo.changed.connect (() => changes++);
        demo.mark_read (message.id, true); assert (!message.unread); assert (changes == 1);
        foreach (var mailbox in demo.list_mailboxes ())
            if (mailbox.role == MailboxRole.INBOX) assert (mailbox.unread_count == 2);
        demo.mark_read (message.id, false); assert (message.unread); assert (changes == 2);
        assert (demo.sender_is_vip (message)); assert (demo.list_messages ("vip").size > 0);
        demo.set_sender_vip (message, false); assert (!demo.sender_is_vip (message));
        demo.move_to_role (message.id, MailboxRole.ARCHIVE);
        assert (demo.find_message (message.id).mailbox_id == "archive");
        int before = demo.list_messages ("trash").size;
        demo.transfer_to_mailbox (message.id, "trash", true);
        assert (demo.list_messages ("trash").size == before + 1);
        assert (demo.find_message (message.id).mailbox_id == "archive");
        demo.set_flagged (message.id, false); assert (!demo.find_message (message.id).flagged);
        demo.mark_read (message.id, false); assert (demo.find_message (message.id).unread);
    } catch (Error error) { GLib.error ("demo action test failed: %s", error.message); }
}

private void test_demo_is_testing_only () {
    string path = Path.build_filename (Environment.get_tmp_dir (),
        "mailficient-demo-mode-%s.sqlite".printf (Uuid.string_random ()));
    try {
        var cache = new CacheDatabase (path); var demo = new DemoMailRepository ();
        var normal = new CachedMailRepository (cache, demo);
        assert (normal.list_mailboxes ().size == 0);
        assert (normal.list_messages ("inbox").size == 0);
        assert (normal.find_message ("1") == null);
        var testing = new CachedMailRepository (cache, demo, true);
        assert (testing.list_mailboxes ().size > 0);
        assert (testing.list_messages ("inbox").size > 0);
        int repository_changes = 0; testing.changed.connect (() => repository_changes++);
        demo.mark_read ("2", true); assert (repository_changes == 1);

        var sample = demo.find_message ("1"); assert (sample != null); cache.cache_message (sample);
        var draft = new Draft (DemoMailRepository.ACCOUNT_ID);
        draft.to = "test@example.net"; draft.body_text = "Testing only"; cache.queue_for_sending (draft);
        assert (cache.cached_message_count (DemoMailRepository.ACCOUNT_ID) == 1);
        assert (cache.outbox_count () == 1);
        cache.clear_demo_data ();
        assert (cache.cached_message_count (DemoMailRepository.ACCOUNT_ID) == 0);
        assert (cache.outbox_count () == 0); assert (cache.draft_count () == 0);
    } catch (Error error) { GLib.error ("demo isolation test failed: %s", error.message); }
    FileUtils.unlink (path);
}

private void test_vip_and_unified_mailboxes () {
    string path = Path.build_filename (Environment.get_tmp_dir (), "mailficient-vip-%s.sqlite".printf (Uuid.string_random ()));
    try {
        var cache = new CacheDatabase (path);
        var inbox = new Mailbox ("vip-account:inbox", "Inbox", "mail-inbox-symbolic", MailboxRole.INBOX, 1, "vip-account", "INBOX");
        var sent = new Mailbox ("vip-account:sent", "Sent", "mail-sent-symbolic", MailboxRole.SENT, 0, "vip-account", "Sent");
        var all_mail = new Mailbox ("vip-account:all", "All Mail", "package-x-generic-symbolic", MailboxRole.ARCHIVE, 1, "vip-account", "All Mail");
        var important = new Mailbox ("vip-account:important", "Important", "folder-symbolic", MailboxRole.CUSTOM, 1, "vip-account", "Important");
        var snapshot = new MailSyncResult ("vip-account"); snapshot.mailboxes.add (inbox); snapshot.mailboxes.add (sent);
        snapshot.mailboxes.add (all_mail); snapshot.mailboxes.add (important);
        snapshot.messages.add (new Message ("vip-account:inbox:1", inbox.id, "Maya", "MAYA@example.net", "Alex",
            "VIP mail", "", "Body", "Today", true, true, false, 1, false, "vip-account", "1", "same-message@example.net"));
        snapshot.messages.add (new Message ("vip-account:all:1", all_mail.id, "Maya", "maya@example.net", "Alex",
            "VIP mail", "", "Body", "Today", true, true, false, 1, false, "vip-account", "101", "same-message@example.net"));
        snapshot.messages.add (new Message ("vip-account:important:1", important.id, "Maya", "maya@example.net", "Alex",
            "VIP mail", "", "Body", "Today", true, true, false, 1, false, "vip-account", "201", "same-message@example.net"));
        snapshot.messages.add (new Message ("vip-account:sent:2", sent.id, "Alex", "alex@example.net", "Maya",
            "Sent mail", "", "Body", "Today", false, false, false, 1, false, "vip-account", "2"));
        cache.store_sync_result (snapshot);
        assert (cache.list_cached_messages ("unified-flagged").size == 1);
        assert (cache.count_cached_messages ("unified-flagged") == 1);
        assert (cache.smart_unread_count ("unified-flagged") == 1);
        assert (cache.list_cached_messages ("unified-sent").size == 1);
        assert (cache.list_cached_messages ("unified-vip").size == 0);
        cache.set_vip_sender ("maya@example.net", true);
        assert (cache.is_vip_sender ("MAYA@example.net"));
        assert (cache.list_cached_messages ("unified-vip").size == 1);
        assert (cache.count_cached_messages ("unified-vip") == 1);
        assert (cache.smart_unread_count ("unified-vip") == 1);
        cache.set_vip_sender ("Maya@Example.Net", false);
        assert (!cache.is_vip_sender ("maya@example.net"));
    } catch (Error error) { GLib.error ("VIP smart mailbox test failed: %s", error.message); }
    FileUtils.unlink (path);
}

private void test_remote_content_sender_policy () {
    string path = Path.build_filename (Environment.get_tmp_dir (),
        "mailficient-remote-policy-%s.sqlite".printf (Uuid.string_random ()));
    try {
        var cache = new CacheDatabase (path);
        var policy = new RemoteContentPolicy (cache);
        int changes = 0; policy.changed.connect (() => changes++);
        assert (!policy.is_sender_trusted ("maya@example.net"));
        policy.trust_sender (" Maya@Example.NET ");
        assert (policy.is_sender_trusted ("MAYA@example.net"));
        assert (policy.trusted_senders ().size == 1);
        assert (policy.trusted_senders ()[0] == "maya@example.net");
        assert (changes == 1);
        bool rejected = false;
        try { policy.trust_sender ("not an address"); }
        catch (MailError error) { rejected = true; }
        assert (rejected);
        policy.forget_sender ("maya@example.net");
        assert (!policy.is_sender_trusted ("maya@example.net"));
        assert (policy.trusted_senders ().size == 0);
        assert (changes == 2);
    } catch (Error error) { GLib.error ("remote-content sender policy test failed: %s", error.message); }
    FileUtils.unlink (path);
}

private static AccountSettings provisioning_account (string id, string incoming_host) {
    var account = new AccountSettings ();
    account.id = id;
    account.display_name = "Alex Morgan";
    account.email = "alex@example.net";
    account.incoming_host = incoming_host;
    account.incoming_username = account.email;
    account.outgoing_host = incoming_host.replace ("imap.", "smtp.");
    account.outgoing_username = account.email;
    return account;
}

private async void exercise_account_provisioning_transaction () throws Error {
    string path = Path.build_filename (Environment.get_tmp_dir (),
        "mailficient-account-provisioning-%s.sqlite".printf (Uuid.string_random ())) ;
    var cache = new CacheDatabase (path);
    var credentials = new MemoryCredentialStore ();
    var cleanup = new CredentialCleanupService (cache, credentials);

    // A new account is tested under an isolated credential identity before it
    // is connected and persisted under its real identity.
    var store = new TestAccountStore ();
    var engine = new ProvisioningMailEngine ();
    var provisioner = new AccountProvisioningService (store, credentials, cleanup, engine);
    var fresh = provisioning_account ("account-new", "imap.new.test");
    yield provisioner.provision (fresh, "new-imap-password", "new-smtp-password");
    assert (store.saved == fresh);
    assert (engine.connections.size == 2);
    assert (engine.connections[0].has_prefix ("candidate-"));
    assert (engine.connections[0].has_suffix ("@imap.new.test"));
    assert (engine.connections[1] == "account-new@imap.new.test");
    assert (credentials.values["account-new:imap"] == "new-imap-password");
    assert (credentials.values["account-new:smtp"] == "new-smtp-password");
    assert (credentials.values.size == 2);
    assert (cache.list_pending_credential_cleanups ().size == 0);

    // A rejected edit must leave the working account connected and its
    // original secrets untouched.
    var existing = provisioning_account ("account-edit", "imap.old.test");
    credentials.values["account-edit:imap"] = "old-imap-password";
    credentials.values["account-edit:smtp"] = "old-smtp-password";
    store = new TestAccountStore ();
    engine = new ProvisioningMailEngine (); engine.fail_candidate = true;
    provisioner = new AccountProvisioningService (store, credentials, cleanup, engine);
    var rejected_edit = provisioning_account ("account-edit", "imap.rejected.test");
    bool rejected = false;
    try { yield provisioner.provision (rejected_edit, "replacement", "replacement", existing); }
    catch (MailError error) { rejected = true; }
    assert (rejected); assert (store.saved == null);
    assert (engine.disconnections.size == 1);
    assert (engine.disconnections[0].has_prefix ("candidate-"));
    assert (!engine.disconnections.contains (existing.id));
    assert (credentials.values["account-edit:imap"] == "old-imap-password");
    assert (credentials.values["account-edit:smtp"] == "old-smtp-password");
    assert (credentials.values.size == 4);
    assert (cache.list_pending_credential_cleanups ().size == 0);

    // If local persistence fails after the candidate and replacement connect,
    // both credentials and the prior live connection are restored.
    store = new TestAccountStore (); store.fail_save = true;
    engine = new ProvisioningMailEngine ();
    provisioner = new AccountProvisioningService (store, credentials, cleanup, engine);
    var failed_edit = provisioning_account ("account-edit", "imap.changed.test");
    bool rolled_back = false;
    try { yield provisioner.provision (failed_edit, "changed-imap", "changed-smtp", existing); }
    catch (MailError error) { rolled_back = true; }
    assert (rolled_back); assert (store.saved == null);
    assert (engine.connections.size == 3);
    assert (engine.connections[0].has_prefix ("candidate-"));
    assert (engine.connections[1] == "account-edit@imap.changed.test");
    assert (engine.connections[2] == "account-edit@imap.old.test");
    assert (engine.disconnections.contains (existing.id));
    assert (credentials.values["account-edit:imap"] == "old-imap-password");
    assert (credentials.values["account-edit:smtp"] == "old-smtp-password");
    assert (credentials.values.size == 4);
    assert (cache.list_pending_credential_cleanups ().size == 0);
    FileUtils.unlink (path);
}

private void test_account_provisioning_transaction () {
    var loop = new MainLoop (); Error? failure = null;
    exercise_account_provisioning_transaction.begin ((object, result) => {
        try { exercise_account_provisioning_transaction.end (result); }
        catch (Error error) { failure = error; }
        loop.quit ();
    });
    loop.run ();
    if (failure != null) GLib.error ("account provisioning transaction test failed: %s", failure.message);
}

private void test_toolbar_layout () {
    var layout = ToolbarLayout.parse (
        "sidebar,refresh,invalid,sidebar,flex,space,flex,archive");
    assert (layout.size == 6);
    assert (layout[0] == "sidebar");
    assert (layout[1] == "refresh");
    assert (layout[2] == "flex");
    assert (layout[3] == "space");
    assert (layout[4] == "flex");
    assert (layout[5] == "archive");
    assert (ToolbarLayout.serialize (layout) ==
        "sidebar,refresh,flex,space,flex,archive");
    assert (ToolbarLayout.is_repeatable ("space"));
    assert (!ToolbarLayout.is_repeatable ("archive"));
    assert (ToolbarLayout.parse (ToolbarLayout.DEFAULT_LAYOUT).size > 0);
    assert (ToolbarLayout.icon_name ("junk") == "dialog-warning-symbolic");
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/search/parse", test_search);
    Test.add_func ("/search/cache", test_cached_search);
    Test.add_func ("/security/html", test_sanitizer);
    Test.add_func ("/security/html-adversarial", test_sanitizer_adversarial);
    Test.add_func ("/security/html-preserves-safe-mail", test_sanitizer_preserves_safe_mail);
    Test.add_func ("/security/html-content-policy", test_html_content_policy);
    Test.add_func ("/security/inline-content-resolver", test_inline_content_resolver);
    Test.add_func ("/security/filename", test_filename);
    Test.add_func ("/attachments/import", test_attachment_import);
    Test.add_func ("/attachments/forward-copy-is-private", test_forward_attachment_copy_is_private);
    Test.add_func ("/attachments/draft-discard-is-database-first", test_draft_discard_is_database_first);
    Test.add_func ("/attachments/cancelled-import-cleanup", test_cancelled_attachment_import_leaves_no_copy);
    Test.add_func ("/attachments/remote-download", test_remote_attachment_download);
    Test.add_func ("/models/initials", test_message_initials);
    Test.add_func ("/models/toolbar-layout", test_toolbar_layout);
    Test.add_func ("/mail/sorting", test_message_sorting);
    Test.add_func ("/mail/conversation", test_conversation_builder);
    Test.add_func ("/account/validation", test_account_validation);
    Test.add_func ("/account/mobileconfig-import", test_mobileconfig_import);
    Test.add_func ("/account/mobileconfig-signed-fixture", test_signed_mobileconfig_fixture);
    Test.add_func ("/account/online-account-mapping-and-storage", test_online_account_mapping_and_storage);
    Test.add_func ("/account/online-account-security-requirements", test_online_account_security_requirements);
    Test.add_func ("/account/provisioning-transaction", test_account_provisioning_transaction);
    Test.add_func ("/mail/folder-validation", test_folder_validation);
    Test.add_func ("/mail/recipients", test_recipients);
    Test.add_func ("/mail/reply-all-recipients", test_reply_all_recipients);
    Test.add_func ("/storage/cc-recipient-roundtrip", test_cc_recipient_cache_roundtrip);
    Test.add_func ("/compose/recipient-completion", test_recipient_completion);
    Test.add_func ("/storage/local-data-migration", test_local_data_migration);
    Test.add_func ("/storage/failed-local-data-migration-is-atomic",
        test_failed_local_data_migration_is_atomic);
    Test.add_func ("/draft/state", test_draft_state);
    Test.add_func ("/storage/settings", test_settings_store);
    Test.add_func ("/sync/startup-network-gate", test_startup_sync_gate);
    Test.add_func ("/compose/signatures", test_signature_service);
    Test.add_func ("/storage/cache-maintenance", test_cache_maintenance);
    Test.add_func ("/storage/drafts", test_cache_drafts);
    Test.add_func ("/outbound/queue-and-retry", test_outbound_queue);
    Test.add_func ("/outbound/scheduled-delivery-timer", test_scheduled_delivery_timer);
    Test.add_func ("/outbound/deadlines", test_outbound_deadlines);
    Test.add_func ("/outbound/attachment-preflight", test_attachment_send_preflight);
    Test.add_func ("/outbound/delivery-state-machine", test_outbox_delivery_state_machine);
    Test.add_func ("/outbound/rate-limit-backoff", test_rate_limited_send_is_retryable);
    Test.add_func ("/outbound/definitive-rejection", test_definitive_send_rejection_is_retryable);
    Test.add_func ("/outbound/atomic-queue", test_outbox_queue_is_atomic);
    Test.add_func ("/errors/conversion", test_error_conversion);
    Test.add_func ("/storage/accounts", test_account_storage);
    Test.add_func ("/security/credential-cleanup-journal", test_credential_cleanup_journal);
    Test.add_func ("/security/remote-content-sender-policy", test_remote_content_sender_policy);
    Test.add_func ("/storage/synchronized-mail", test_synchronized_cache_repository);
    Test.add_func ("/storage/message-pagination", test_cached_message_pagination);
    Test.add_func ("/mail/virtualized-inbox-is-bounded", test_virtual_message_model_is_bounded);
    Test.add_func ("/storage/pending-state-survives-sync", test_pending_state_survives_sync);
    Test.add_func ("/storage/incremental-sync-merges-and-prunes", test_incremental_sync_merges_and_prunes);
    Test.add_func ("/storage/cached-message-ids-are-lightweight", test_cached_message_ids_do_not_require_message_loading);
    Test.add_func ("/storage/server-unread-total-survives-partial-cache", test_server_unread_total_survives_partial_cache);
    Test.add_func ("/storage/pending-unread-move-adjusts-server-totals", test_pending_unread_move_adjusts_server_totals);
    Test.add_func ("/sync/pipeline", test_sync_pipeline);
    Test.add_func ("/sync/long-running-stream-is-bounded", test_long_running_streamed_sync_is_bounded);
    Test.add_func ("/sync/automatic-history-backfill", test_automatic_history_backfill);
    Test.add_func ("/sync/can-be-cancelled", test_active_sync_can_be_cancelled);
    Test.add_func ("/sync/partial-result-is-installed", test_partial_sync_is_installed_and_reported);
    Test.add_func ("/sync/mutation-serialization", test_mutation_flush_serialization);
    Test.add_func ("/sync/account-serialization", test_account_sync_serialization);
    Test.add_func ("/sync/move-flushes-state-before-transfer", test_move_flushes_state_before_transfer);
    Test.add_func ("/sync/junk-classification-is-durable", test_junk_classification_is_durable);
    Test.add_func ("/junk/rules-and-filter", test_junk_rules_and_filter);
    Test.add_func ("/mail/rules-and-labels", test_mail_rules_and_labels);
    Test.add_func ("/mail/scheduling-snooze-and-templates", test_scheduling_snooze_and_templates);
    Test.add_func ("/mail/vacation-responder", test_vacation_responder);
    Test.add_func ("/mail/export-eml-and-pdf", test_message_export);
    Test.add_func ("/storage/chained-move-remaps-server-identity", test_chained_move_remaps_server_identity);
    Test.add_func ("/storage/undo-and-permanent-deletion", test_undo_and_permanent_deletion_pipeline);
    Test.add_func ("/demo/message-actions", test_demo_actions);
    Test.add_func ("/demo/testing-only", test_demo_is_testing_only);
    Test.add_func ("/storage/vip-and-unified-mailboxes", test_vip_and_unified_mailboxes);
    return Test.run ();
}
