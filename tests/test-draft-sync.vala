using Mailficient;

private class DraftTestEngine : Object, MailEngine {
    public int connect_calls;
    public int send_calls;
    public int remote_save_calls;
    public string sent_body = "";
    public Gee.ArrayList<string> deleted_uids = new Gee.ArrayList<string> ();

    public async void connect_account (AccountSettings settings,
                                       Cancellable? cancellable = null) throws Error {
        if (cancellable != null) cancellable.set_error_if_cancelled ();
        connect_calls++;
    }
    public async void connect_incoming_account (AccountSettings settings,
                                                Cancellable? cancellable = null) throws Error {
        yield connect_account (settings, cancellable);
    }
    public async void disconnect_account (string account_id,
                                           Cancellable? cancellable = null) throws Error { }
    public async MailSyncResult synchronize (string account_id,
                                              Gee.Set<string>? cached_message_ids = null,
                                              Cancellable? cancellable = null) throws Error {
        return new MailSyncResult (account_id);
    }
    public async SendResult send (Draft draft,
                                  Cancellable? cancellable = null) throws Error {
        if (cancellable != null) cancellable.set_error_if_cancelled ();
        send_calls++; sent_body = draft.body_text;
        return new SendResult ();
    }
    public async RemoteDraftLocation? save_remote_draft (
        Draft draft, Cancellable? cancellable = null) throws Error {
        if (cancellable != null) cancellable.set_error_if_cancelled ();
        remote_save_calls++;
        return new RemoteDraftLocation ("Drafts", "uploaded-%d".printf (remote_save_calls));
    }
    public async bool delete_remote_draft (PendingDraftDeletion deletion,
                                           Cancellable? cancellable = null) throws Error {
        if (cancellable != null) cancellable.set_error_if_cancelled ();
        deleted_uids.add (deletion.remote_uid); return true;
    }
    public async void save_remote_attachment (string account_id, string mailbox_name,
                                               string remote_uid, int remote_part_index,
                                               File destination, int64 maximum_bytes,
                                               Cancellable? cancellable = null) throws Error { }
    public async void set_message_state (string account_id, string mailbox_name,
                                         string remote_uid, MessageStateField field, bool value,
                                         Cancellable? cancellable = null) throws Error { }
    public async string? transfer_message (string account_id, string source_mailbox,
                                           string remote_uid, string destination_mailbox, bool copy,
                                           Cancellable? cancellable = null) throws Error { return null; }
    public async void create_folder (string account_id, string parent_name, string folder_name,
                                     Cancellable? cancellable = null) throws Error { }
    public async void rename_folder (string account_id, string old_name, string old_display_name,
                                     string new_display_name,
                                     Cancellable? cancellable = null) throws Error { }
    public async void delete_folder (string account_id, string folder_name,
                                     Cancellable? cancellable = null) throws Error { }
    public async void permanently_delete_message (string account_id, string mailbox_name,
                                                   string remote_uid,
                                                   Cancellable? cancellable = null) throws Error { }
    public async void empty_folder (string account_id, string folder_name,
                                    Cancellable? cancellable = null) throws Error { }
    public SyncState state_for (string account_id) { return new SyncState (); }
}

private string temporary_root (string stem) {
    string path = Path.build_filename (Environment.get_tmp_dir (),
        "%s-%s".printf (stem, Uuid.string_random ()));
    assert (DirUtils.create_with_parents (path, 0700) == 0);
    return path;
}

private RemoteDraftSnapshot remote_snapshot (string account_id, string id, string uid,
                                              int64 revision, string body,
                                              bool managed = true,
                                              string html = "") {
    var draft = new Draft (account_id, id);
    draft.to = "maya@example.net"; draft.subject = "Provider draft";
    draft.body_text = body; draft.body_html = html; draft.revision = revision;
    draft.modified_at = 1700000000;
    string message_id = managed ? Draft.remote_message_id_for (id, revision) :
        "third-party-%s@example.net".printf (id);
    return new RemoteDraftSnapshot (draft, "Drafts", uid, message_id, managed,
        DraftFingerprint.calculate (draft, uid));
}

private void import_snapshot (CacheDatabase cache, RemoteDraftSnapshot snapshot) throws Error {
    assert (cache.import_remote_draft (snapshot, snapshot.draft));
}

private async void exercise_remote_upload_and_revision () throws Error {
    string root = temporary_root ("mailficient-draft-upload");
    var cache = new CacheDatabase (Path.build_filename (root, "mail.sqlite"));
    var engine = new DraftTestEngine ();
    var service = new DraftSyncService (cache, engine);
    var draft = new Draft ("draft-account");
    draft.to = "maya@example.net"; draft.body_text = "first";
    cache.save_draft (draft);
    assert (cache.has_pending_remote_draft_work (draft.account_id));
    yield service.synchronize_account (draft.account_id);
    var uploaded = cache.load_draft (draft.id);
    assert (uploaded != null); assert (uploaded.remote_uid == "uploaded-1");
    assert (uploaded.remote_revision == uploaded.revision); assert (uploaded.remote_owned);
    uploaded.body_text = "second"; uploaded.touch (); cache.save_draft (uploaded);
    yield service.synchronize_account (draft.account_id);
    var updated = cache.load_draft (draft.id);
    assert (updated != null); assert (updated.remote_uid == "uploaded-2");
    assert (updated.remote_revision == updated.revision);
    assert (engine.deleted_uids.size == 1);
    assert (engine.deleted_uids[0] == "uploaded-1");
    assert (!cache.has_pending_remote_draft_work (draft.account_id));
}

private void test_remote_upload_and_revision () {
    Error? failure = null; var loop = new MainLoop ();
    exercise_remote_upload_and_revision.begin ((object, result) => {
        try { exercise_remote_upload_and_revision.end (result); }
        catch (Error error) { failure = error; }
        loop.quit ();
    });
    loop.run ();
    if (failure != null) GLib.error ("Remote draft upload test failed: %s", failure.message);
}

private void test_remote_edits_uid_replacement_and_deletion () {
    string root = temporary_root ("mailficient-draft-reconcile");
    try {
        var cache = new CacheDatabase (Path.build_filename (root, "mail.sqlite"));
        string account_id = "reconcile-account";
        string edited_id = Uuid.string_random ();
        var initial = remote_snapshot (account_id, edited_id, "10", 7,
            "original plain", true, "<p><b>Original</b></p>");
        import_snapshot (cache, initial);
        var external = remote_snapshot (account_id, edited_id, "10", 7,
            "externally changed plain", true, "<section>Exact <em>HTML</em></section>");
        assert (cache.import_remote_draft (external, external.draft));
        var edited = cache.load_draft (edited_id);
        assert (edited != null); assert (edited.revision == 8);
        assert (edited.remote_revision == 7);
        assert (edited.body_text == "externally changed plain");
        assert (edited.body_html == "<section>Exact <em>HTML</em></section>");
        assert (cache.list_pending_draft_uploads (account_id).size == 1);

        string replaced_id = Uuid.string_random ();
        import_snapshot (cache, remote_snapshot (account_id, replaced_id, "20", 3,
            "same content"));
        var inventory = new MailSyncResult (account_id);
        inventory.folder_inventory_complete = true;
        var drafts_box = new Mailbox ("draft-box", "Drafts", "document-edit-symbolic",
            MailboxRole.DRAFTS, 0, account_id, "Drafts");
        inventory.mailboxes.add (drafts_box);
        inventory.begin_remote_inventory (drafts_box.id);
        inventory.record_remote_uid (drafts_box.id, "21");
        var removed = cache.reconcile_remote_draft_deletions (inventory);
        assert (removed.size == 1); assert (removed[0].id == replaced_id);
        import_snapshot (cache, remote_snapshot (account_id, replaced_id, "21", 3,
            "same content"));
        var replacement = cache.load_draft (replaced_id);
        assert (replacement != null); assert (replacement.remote_uid == "21");

        // A successfully refreshed empty Drafts inventory removes the last
        // unchanged mirror, while a dirty local edit survives for re-upload.
        string dirty_id = Uuid.string_random ();
        import_snapshot (cache, remote_snapshot (account_id, dirty_id, "30", 2, "remote"));
        var dirty = cache.load_draft (dirty_id); assert (dirty != null);
        dirty.body_text = "offline local edit"; dirty.touch (); cache.save_draft (dirty);
        var empty = new MailSyncResult (account_id); empty.folder_inventory_complete = true;
        empty.mailboxes.add (drafts_box); empty.begin_remote_inventory (drafts_box.id);
        removed = cache.reconcile_remote_draft_deletions (empty);
        assert (cache.load_draft (replaced_id) == null);
        var preserved = cache.load_draft (dirty_id);
        assert (preserved != null); assert (preserved.remote_uid == "");
        assert (preserved.remote_revision == 0);
        assert (cache.list_pending_draft_uploads (account_id).size >= 2);
    } catch (Error error) {
        GLib.error ("Remote draft reconciliation test failed: %s", error.message);
    }
}

private void test_third_party_discard_is_explicit_remote_delete () {
    string root = temporary_root ("mailficient-third-party-discard");
    try {
        var cache = new CacheDatabase (Path.build_filename (root, "mail.sqlite"));
        string account_id = "third-party-account"; string id = "remote-third-party";
        var account = AccountSettings.for_email ("Third Party", "third-party@example.net");
        account.id = account_id; account.incoming_host = "imap.example.net";
        account.outgoing_host = "smtp.example.net"; cache.save_account (account);
        int activation_count = 0;
        cache.remote_draft_work_queued.connect ((activated_account) => {
            assert (activated_account == account_id); activation_count++;
        });
        var snapshot = remote_snapshot (account_id, id, "44", 1, "other client", false);
        import_snapshot (cache, snapshot);
        var imported = cache.load_draft (id); assert (imported != null);
        assert (!imported.remote_owned);
        assert (cache.pending_remote_draft_deletion_count () == 0);
        cache.delete_draft (id);
        assert (activation_count == 1);
        assert (cache.load_draft (id) == null);
        var pending = cache.list_pending_remote_draft_deletions (account_id);
        assert (pending.size == 1); assert (pending[0].remote_uid == "44");
        assert (pending[0].expected_message_id == snapshot.internet_message_id);
    } catch (Error error) {
        GLib.error ("Third-party draft discard test failed: %s", error.message);
    }
}

private void test_reconcile_vs_local_edit_race () {
    string root = temporary_root ("mailficient-reconcile-edit-race");
    string path = Path.build_filename (root, "mail.sqlite");
    try {
        var cache = new CacheDatabase (path);
        string account_id = "reconcile-race-account";
        var drafts_box = new Mailbox ("race-drafts", "Drafts", "document-edit-symbolic",
            MailboxRole.DRAFTS, 0, account_id, "Drafts");

        // Exercise both legal lock orderings repeatedly. If reconciliation
        // commits first, the later save recreates the locally edited draft; if
        // the save commits first, reconciliation observes the new revision and
        // clears only its stale remote mapping. Neither ordering may lose it.
        for (int iteration = 0; iteration < 20; iteration++) {
            string id = "race-draft-%d".printf (iteration);
            import_snapshot (cache, remote_snapshot (account_id, id,
                "remote-%d".printf (iteration), 1, "provider version"));
            var local_edit = cache.load_draft (id); assert (local_edit != null);
            local_edit.body_text = "local edit %d".printf (iteration);
            local_edit.touch ();

            var empty = new MailSyncResult (account_id);
            empty.folder_inventory_complete = true; empty.mailboxes.add (drafts_box);
            empty.begin_remote_inventory (drafts_box.id);
            Mutex mutex = Mutex (); Cond barrier = Cond ();
            bool contender_ready = false; bool start = false; string thread_error = "";
            var reconciler = new Thread<bool> ("mailficient-reconcile-race", () => {
                try {
                    var competing_cache = new CacheDatabase (path);
                    mutex.lock (); contender_ready = true; barrier.signal ();
                    while (!start) barrier.wait (mutex);
                    mutex.unlock ();
                    competing_cache.reconcile_remote_draft_deletions (empty);
                    return true;
                } catch (Error error) {
                    thread_error = error.message;
                    mutex.lock (); contender_ready = true; barrier.signal (); mutex.unlock ();
                    return false;
                }
            });
            mutex.lock ();
            while (!contender_ready) barrier.wait (mutex);
            if (thread_error != "") {
                mutex.unlock (); reconciler.join ();
                GLib.error ("Reconciliation contender setup failed: %s", thread_error);
            }
            start = true; barrier.broadcast (); mutex.unlock ();
            cache.save_draft (local_edit);
            assert (reconciler.join ()); assert (thread_error == "");
            var preserved = cache.load_draft (id); assert (preserved != null);
            assert (preserved.body_text == "local edit %d".printf (iteration));
            assert (preserved.remote_uid == "");
        }
    } catch (Error error) {
        GLib.error ("Reconcile-versus-edit race test failed: %s", error.message);
    }
}

private async void exercise_placeholder_import () throws Error {
    string root = temporary_root ("mailficient-draft-placeholder");
    var cache = new CacheDatabase (Path.build_filename (root, "mail.sqlite"));
    var attachments = new AttachmentService (Path.build_filename (root, "attachments"));
    var service = new DraftSyncService (cache, new DraftTestEngine (), attachments);
    var snapshot = remote_snapshot ("placeholder-account", Uuid.string_random (), "55", 1,
        "Attachment must not disappear", false);
    snapshot.draft.attachments.add (new Attachment ("missing-part", "", "contract.pdf",
        4096, "application/pdf", "", 3));
    var snapshots = new Gee.ArrayList<RemoteDraftSnapshot> (); snapshots.add (snapshot);
    yield service.import_remote_drafts (snapshots);
    var imported = cache.load_draft (snapshot.draft.id);
    assert (imported != null); assert (imported.attachments.size == 1);
    var placeholder = imported.attachments[0];
    assert (!placeholder.is_downloaded ()); assert (placeholder.name == "contract.pdf");
    assert (placeholder.remote_part_index == 3);
    Error? blocked = null;
    try { attachments.validate_draft_attachments (imported); }
    catch (Error error) { blocked = error; }
    assert (blocked is MailError.ATTACHMENT);
    assert (blocked.message.contains ("Remove it or reattach"));
    attachments.remove_private_copy (placeholder);
}

private void test_remote_attachment_placeholder_blocks_send () {
    Error? failure = null; var loop = new MainLoop ();
    exercise_placeholder_import.begin ((object, result) => {
        try { exercise_placeholder_import.end (result); }
        catch (Error error) { failure = error; }
        loop.quit ();
    });
    loop.run ();
    if (failure != null) GLib.error ("Provider attachment placeholder test failed: %s", failure.message);
}

private async void exercise_outbox_claim_snapshot () throws Error {
    string root = temporary_root ("mailficient-outbox-snapshot");
    var cache = new CacheDatabase (Path.build_filename (root, "mail.sqlite"));
    var account = AccountSettings.for_email ("Alex", "alex@example.net");
    account.id = "outbox-race"; account.incoming_host = "imap.example.net";
    account.outgoing_host = "smtp.example.net"; cache.save_account (account);
    var engine = new DraftTestEngine ();
    var service = new OutboundService (cache, engine,
        new AttachmentService (Path.build_filename (root, "attachments")));
    int activation_count = 0; string activated_account = "";
    service.background_delivery_needed.connect ((account_id) => {
        activation_count++; activated_account = account_id;
    });
    var demo_schedule = new Draft ("demo-account");
    demo_schedule.to = "maya@example.net"; demo_schedule.body_text = "QA-only queue";
    service.schedule (demo_schedule, new DateTime.now_utc ().to_unix () + 3600);
    assert (activation_count == 0);
    var real_schedule = new Draft (account.id);
    real_schedule.to = "maya@example.net"; real_schedule.body_text = "Provider queue";
    service.schedule (real_schedule, new DateTime.now_utc ().to_unix () + 3600);
    assert (activation_count == 1); assert (activated_account == account.id);
    cache.delete_draft (demo_schedule.id);
    cache.delete_draft (real_schedule.id);
    var original = new Draft (account.id); original.to = "maya@example.net";
    original.body_text = "stale body"; cache.queue_for_sending (original);
    var stale = cache.list_pending_sends (account.id, false)[0];
    var edited = cache.load_draft (original.id); assert (edited != null);
    edited.body_text = "latest committed autosave"; edited.touch (); cache.save_draft (edited);
    yield service.attempt_queued (stale, false, null);
    assert (engine.send_calls == 1); assert (engine.sent_body == "latest committed autosave");
    assert (cache.find_outbox_item (original.id) == null);

    int connects = engine.connect_calls;
    assert (!cache.has_pending_remote_draft_work (account.id));
    yield service.retry_pending (account.id, true, null);
    assert (engine.connect_calls == connects);

    var claimed = new Draft (account.id); claimed.to = "maya@example.net";
    claimed.body_text = "background owns this"; cache.queue_for_sending (claimed);
    assert (cache.claim_queued_send (claimed.id, "worker", 4000000000, false));
    var foreground = cache.load_draft (claimed.id); assert (foreground != null);
    foreground.body_text = "late GUI autosave"; foreground.touch ();
    Error? collision = null;
    try { cache.save_draft (foreground); } catch (Error error) { collision = error; }
    assert (collision is MailError.SEND_FAILED);
    assert (cache.load_draft (claimed.id).body_text == "background owns this");
}

private void test_outbox_claim_reloads_durable_snapshot () {
    Error? failure = null; var loop = new MainLoop ();
    exercise_outbox_claim_snapshot.begin ((object, result) => {
        try { exercise_outbox_claim_snapshot.end (result); }
        catch (Error error) { failure = error; }
        loop.quit ();
    });
    loop.run ();
    if (failure != null) GLib.error ("Outbox claim snapshot test failed: %s", failure.message);
}

private void test_concurrent_database_writes_wait_and_draft_save_activates () {
    string root = temporary_root ("mailficient-database-overlap");
    string path = Path.build_filename (root, "mail.sqlite");
    try {
        var cache = new CacheDatabase (path);
        int activation_count = 0; string activated_account = "";
        cache.remote_draft_work_queued.connect ((account_id) => {
            activation_count++; activated_account = account_id;
        });
        var demo_draft = new Draft ("demo-account");
        demo_draft.body_text = "Local-only sample";
        cache.save_draft (demo_draft);
        assert (activation_count == 0);

        var account = AccountSettings.for_email ("Activation", "activation@example.net");
        account.id = "activation-account"; account.incoming_host = "imap.example.net";
        account.outgoing_host = "smtp.example.net"; cache.save_account (account);
        var draft = new Draft ("activation-account");
        draft.body_text = "Saved locally for background Drafts synchronization";
        cache.save_draft (draft);
        assert (activation_count == 1);
        assert (activated_account == draft.account_id);

        Mutex mutex = Mutex (); Cond ready = Cond (); bool holder_ready = false;
        bool writer_has_lock = false;
        string thread_error = "";
        var holder = new Thread<bool> ("mailficient-write-holder", () => {
            Sqlite.Database writer;
            if (Sqlite.Database.open (path, out writer) != Sqlite.OK) {
                thread_error = "could not open competing database connection";
                mutex.lock (); holder_ready = true; ready.signal (); mutex.unlock ();
                return false;
            }
            string? detail = null;
            if (writer.exec ("BEGIN IMMEDIATE", null, out detail) != Sqlite.OK) {
                thread_error = detail ?? "could not acquire competing write lock";
                mutex.lock (); holder_ready = true; ready.signal (); mutex.unlock ();
                return false;
            }
            mutex.lock (); holder_ready = true; writer_has_lock = true; ready.signal (); mutex.unlock ();
            Thread.usleep (150000);
            if (writer.exec ("ROLLBACK", null, out detail) != Sqlite.OK)
                thread_error = detail ?? "could not release competing write lock";
            return thread_error == "";
        });
        mutex.lock ();
        while (!holder_ready) ready.wait (mutex);
        mutex.unlock ();
        if (!writer_has_lock) {
            holder.join ();
            GLib.error ("Competing writer setup failed: %s", thread_error);
        }

        // This second writer blocks briefly, then succeeds because every
        // CacheDatabase connection installs the bounded busy timeout.
        cache.set_preference ("overlap-proof", "saved");
        assert (holder.join ());
        assert (thread_error == "");
        assert (cache.preference ("overlap-proof") == "saved");
    } catch (Error error) {
        GLib.error ("Concurrent database write test failed: %s", error.message);
    }
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/draft-sync/upload-and-revision", test_remote_upload_and_revision);
    Test.add_func ("/draft-sync/external-edit-uid-replacement-and-deletion",
        test_remote_edits_uid_replacement_and_deletion);
    Test.add_func ("/draft-sync/third-party-explicit-discard",
        test_third_party_discard_is_explicit_remote_delete);
    Test.add_func ("/draft-sync/reconcile-vs-local-edit-race",
        test_reconcile_vs_local_edit_race);
    Test.add_func ("/draft-sync/attachment-placeholder-blocks-send",
        test_remote_attachment_placeholder_blocks_send);
    Test.add_func ("/outbound/claim-reloads-durable-snapshot",
        test_outbox_claim_reloads_durable_snapshot);
    Test.add_func ("/storage/concurrent-writes-wait-and-draft-save-activates",
        test_concurrent_database_writes_wait_and_draft_save_activates);
    return Test.run ();
}
