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

private void test_no_message_id_discard_uses_fingerprint_tombstone () {
    string root = temporary_root ("mailficient-no-id-discard");
    try {
        var cache = new CacheDatabase (Path.build_filename (root, "mail.sqlite"));
        string account_id = "no-id-discard-account";
        string remote_uid = "no-id-41";
        var drafts_box = new Mailbox ("no-id-drafts", "Drafts",
            "document-edit-symbolic", MailboxRole.DRAFTS, 0, account_id, "Drafts");

        // Some third-party clients create drafts without Message-ID. The
        // provider snapshot's exact content fingerprint is the only durable
        // identity available for canceling that copy safely.
        var discarded_draft = new Draft (account_id, "provider-no-id-draft");
        discarded_draft.to = "maya@example.net";
        discarded_draft.subject = "Reply without Message-ID";
        discarded_draft.body_text = "This provider draft was canceled";
        discarded_draft.modified_at = 1700000000;
        string discarded_fingerprint = DraftFingerprint.calculate (
            discarded_draft, remote_uid);
        var discarded_snapshot = new RemoteDraftSnapshot (discarded_draft,
            "Drafts", remote_uid, "", false, discarded_fingerprint);
        import_snapshot (cache, discarded_snapshot);

        var provider_sync = new MailSyncResult (account_id);
        provider_sync.mailboxes.add (drafts_box);
        provider_sync.messages.add (new Message ("cached-no-id-draft", drafts_box.id,
            "Draft", "", "maya@example.net", discarded_draft.subject,
            discarded_draft.body_text, discarded_draft.body_text, "Today", false,
            false, false, 1, false, account_id, remote_uid, ""));
        provider_sync.remote_drafts.add (discarded_snapshot);
        cache.store_sync_result (provider_sync);
        assert (cache.find_cached_message ("cached-no-id-draft") != null);

        cache.delete_draft (discarded_draft.id);
        assert (cache.load_draft (discarded_draft.id) == null);
        assert (cache.find_cached_message ("cached-no-id-draft") == null);
        var pending = cache.list_pending_remote_draft_deletions (account_id);
        assert (pending.size == 1);
        assert (pending[0].remote_uid == remote_uid);
        assert (pending[0].expected_message_id == "");
        assert (pending[0].expected_fingerprint == discarded_fingerprint);

        assert (!cache.import_remote_draft (discarded_snapshot,
            discarded_snapshot.draft));
        cache.store_sync_result (provider_sync);
        assert (cache.find_cached_message ("cached-no-id-draft") == null);

        // Completing provider deletion retires network work but preserves the
        // user-cancel tombstone. Verify stale snapshots after a second draft
        // has exercised reuse of this exact provider UID.
        cache.complete_remote_draft_deletion (pending[0].id);
        assert (cache.pending_remote_draft_deletion_count () == 0);

        // A second distinct no-ID draft can legitimately reuse the same UID.
        // Canceling it must create a second fingerprint tombstone rather than
        // overwrite the completed identity of the first canceled draft.
        var second_draft = new Draft (account_id, "second-provider-no-id-draft");
        second_draft.to = "alex@example.net";
        second_draft.subject = "A second provider draft";
        second_draft.body_text = "Second canceled content at a reused UID";
        second_draft.modified_at = 1700000100;
        var second_snapshot = new RemoteDraftSnapshot (second_draft,
            "Drafts", remote_uid, "", false,
            DraftFingerprint.calculate (second_draft, remote_uid));
        assert (second_snapshot.content_fingerprint != discarded_fingerprint);
        assert (cache.import_remote_draft (second_snapshot, second_snapshot.draft));
        assert (cache.load_draft (second_draft.id) != null);
        cache.delete_draft (second_draft.id);
        pending = cache.list_pending_remote_draft_deletions (account_id);
        assert (pending.size == 1);
        assert (pending[0].expected_message_id == "");
        assert (pending[0].expected_fingerprint == second_snapshot.content_fingerprint);

        cache.complete_remote_draft_deletion (pending[0].id);
        assert (cache.pending_remote_draft_deletion_count () == 0);
        assert (!cache.import_remote_draft (discarded_snapshot,
            discarded_snapshot.draft));
        assert (!cache.import_remote_draft (second_snapshot, second_snapshot.draft));

        // A third, different fingerprint at the reused UID is new provider
        // content and must remain importable and visible.
        var replacement_draft = new Draft (account_id, "third-provider-no-id-draft");
        replacement_draft.to = "casey@example.net";
        replacement_draft.subject = "A third provider draft";
        replacement_draft.body_text = "Different content that must survive";
        replacement_draft.modified_at = 1700000200;
        var replacement_snapshot = new RemoteDraftSnapshot (replacement_draft,
            "Drafts", remote_uid, "", false,
            DraftFingerprint.calculate (replacement_draft, remote_uid));
        assert (replacement_snapshot.content_fingerprint != discarded_fingerprint);
        assert (replacement_snapshot.content_fingerprint !=
            second_snapshot.content_fingerprint);
        assert (cache.import_remote_draft (replacement_snapshot,
            replacement_snapshot.draft));
        assert (cache.load_draft (replacement_draft.id) != null);

        var replacement_sync = new MailSyncResult (account_id);
        replacement_sync.mailboxes.add (drafts_box);
        replacement_sync.messages.add (new Message ("replacement-no-id-message",
            drafts_box.id, "Draft", "", "alex@example.net",
            replacement_draft.subject, replacement_draft.body_text,
            replacement_draft.body_text, "Today", false, false, false, 1,
            false, account_id, remote_uid, ""));
        replacement_sync.remote_drafts.add (replacement_snapshot);
        cache.store_sync_result (replacement_sync);
        assert (cache.find_cached_message ("replacement-no-id-message") != null);
    } catch (Error error) {
        GLib.error ("No-Message-ID discarded draft test failed: %s", error.message);
    }
}

private void test_no_id_uid_reuse_between_batch_store_and_draft_import () {
    string root = temporary_root ("mailficient-no-id-batch-import-race");
    try {
        var cache = new CacheDatabase (Path.build_filename (root, "mail.sqlite"));
        string account_id = "no-id-batch-import-race-account";
        string remote_uid = "reused-no-id-71";
        string local_id = "remote-no-id-reused-location";
        var drafts_box = new Mailbox ("no-id-race-drafts", "Drafts",
            "document-edit-symbolic", MailboxRole.DRAFTS, 0, account_id, "Drafts");

        var first = new Draft (account_id, local_id);
        first.to = "maya@example.net"; first.subject = "Canceled draft A";
        first.body_text = "The provider's first no-ID draft";
        first.modified_at = 1700000000;
        var first_snapshot = new RemoteDraftSnapshot (first, "Drafts", remote_uid,
            "", false, DraftFingerprint.calculate (first, remote_uid));
        import_snapshot (cache, first_snapshot);

        // Camel stores each downloaded message batch immediately, while draft
        // import is intentionally deferred until the account pass completes.
        // Model the provider reusing A's UID for different no-ID draft B in that
        // interval: the editable mapping still describes A, but the cache row
        // already describes B and carries B's verified semantic fingerprint.
        var second = new Draft (account_id, local_id);
        second.to = "casey@example.net"; second.subject = "Replacement draft B";
        second.body_text = "Different provider content at the reused UID";
        second.modified_at = 1700000100;
        var second_snapshot = new RemoteDraftSnapshot (second, "Drafts", remote_uid,
            "", false, DraftFingerprint.calculate (second, remote_uid));
        assert (second_snapshot.content_fingerprint !=
            first_snapshot.content_fingerprint);
        var replacement_batch = new MailSyncResult (account_id);
        replacement_batch.mailboxes.add (drafts_box);
        replacement_batch.messages.add (new Message ("cached-replacement-b",
            drafts_box.id, "Draft", "", second.to, second.subject,
            second.body_text, second.body_text, "Today", false, false, false, 1,
            false, account_id, remote_uid, ""));
        replacement_batch.remote_drafts.add (second_snapshot);
        cache.store_sync_result (replacement_batch);
        assert (cache.find_cached_message ("cached-replacement-b") != null);
        var still_first = cache.load_draft (local_id);
        assert (still_first != null);
        assert (still_first.remote_content_fingerprint ==
            first_snapshot.content_fingerprint);

        cache.delete_draft (local_id);
        // Canceling stale A must not turn the immediate cache purge into a
        // UID-only delete of B. Its later draft-import stage must also survive
        // A's exact fingerprint tombstone.
        assert (cache.find_cached_message ("cached-replacement-b") != null);
        var pending = cache.list_pending_remote_draft_deletions (account_id);
        assert (pending.size == 1);
        assert (pending[0].expected_message_id == "");
        assert (pending[0].expected_fingerprint ==
            first_snapshot.content_fingerprint);
        assert (cache.import_remote_draft (second_snapshot, second_snapshot.draft));
        var imported_second = cache.load_draft (local_id);
        assert (imported_second != null);
        assert (imported_second.body_text == second.body_text);
        cache.store_sync_result (replacement_batch);
        assert (cache.find_cached_message ("cached-replacement-b") != null);
    } catch (Error error) {
        GLib.error ("No-ID batch/import UID reuse race test failed: %s", error.message);
    }
}

private void test_legacy_discard_tombstone_migration () {
    string root = temporary_root ("mailficient-legacy-discard-migration");
    string path = Path.build_filename (root, "mail.sqlite");
    string account_id = "legacy-discard-account";
    string draft_id = "legacy-cancelled-reply";
    string expected_id = Draft.remote_message_id_for (draft_id, 3);
    try {
        Sqlite.Database legacy;
        assert (Sqlite.Database.open (path, out legacy) == Sqlite.OK);
        string? detail = null;
        assert (legacy.exec ("CREATE TABLE pending_remote_draft_deletions(" +
            "id INTEGER PRIMARY KEY AUTOINCREMENT,account_id TEXT NOT NULL," +
            "mailbox_name TEXT NOT NULL,remote_uid TEXT NOT NULL," +
            "expected_message_id TEXT NOT NULL,created_at INTEGER NOT NULL," +
            "UNIQUE(account_id,mailbox_name,remote_uid,expected_message_id));" +
            "INSERT INTO pending_remote_draft_deletions(" +
            "account_id,mailbox_name,remote_uid,expected_message_id,created_at) " +
            "VALUES('%s','Drafts','legacy-31','%s',1700000000)".printf (
                account_id, expected_id), null, out detail) == Sqlite.OK);

        var cache = new CacheDatabase (path);
        var stale = remote_snapshot (account_id, draft_id, "legacy-31", 3,
            "Canceled by an older Mailficient build");
        assert (!cache.import_remote_draft (stale, stale.draft));
        assert (cache.load_draft (draft_id) == null);
        var pending = cache.list_pending_remote_draft_deletions (account_id);
        assert (pending.size == 1);
        cache.complete_remote_draft_deletion (pending[0].id);
        assert (!cache.import_remote_draft (stale, stale.draft));

        // The legacy Message-ID-only table is rebuilt with partial identity
        // indexes. Distinct no-ID fingerprints at one provider UID must then
        // coexist instead of collapsing into one empty-Message-ID row.
        var first_no_id = new Draft (account_id, "legacy-no-id-a");
        first_no_id.subject = "Legacy no-ID A";
        first_no_id.body_text = "First fingerprint";
        var first_no_id_snapshot = new RemoteDraftSnapshot (first_no_id,
            "Drafts", "legacy-shared-uid", "", false,
            DraftFingerprint.calculate (first_no_id, "legacy-shared-uid"));
        import_snapshot (cache, first_no_id_snapshot);
        cache.delete_draft (first_no_id.id);

        var second_no_id = new Draft (account_id, "legacy-no-id-b");
        second_no_id.subject = "Legacy no-ID B";
        second_no_id.body_text = "Second fingerprint";
        var second_no_id_snapshot = new RemoteDraftSnapshot (second_no_id,
            "Drafts", "legacy-shared-uid", "", false,
            DraftFingerprint.calculate (second_no_id, "legacy-shared-uid"));
        assert (first_no_id_snapshot.content_fingerprint !=
            second_no_id_snapshot.content_fingerprint);
        import_snapshot (cache, second_no_id_snapshot);
        cache.delete_draft (second_no_id.id);

        bool found_first_fingerprint = false;
        bool found_second_fingerprint = false;
        int fingerprint_deletions = 0;
        pending = cache.list_pending_remote_draft_deletions (account_id);
        foreach (var deletion in pending) {
            if (deletion.expected_message_id == "") fingerprint_deletions++;
            if (deletion.expected_fingerprint ==
                first_no_id_snapshot.content_fingerprint)
                found_first_fingerprint = true;
            if (deletion.expected_fingerprint ==
                second_no_id_snapshot.content_fingerprint)
                found_second_fingerprint = true;
        }
        assert (fingerprint_deletions == 2);
        assert (found_first_fingerprint);
        assert (found_second_fingerprint);
        assert (!cache.import_remote_draft (first_no_id_snapshot,
            first_no_id_snapshot.draft));
        assert (!cache.import_remote_draft (second_no_id_snapshot,
            second_no_id_snapshot.draft));
    } catch (Error error) {
        GLib.error ("Legacy discarded-draft migration test failed: %s", error.message);
    }
}

private void test_discard_tombstones_provider_copy () {
    string root = temporary_root ("mailficient-discard-tombstone");
    string path = Path.build_filename (root, "mail.sqlite");
    try {
        var cache = new CacheDatabase (path);
        string account_id = "discard-tombstone-account";
        var snapshot = remote_snapshot (account_id, Uuid.string_random (), "91", 2,
            "This reply was canceled");
        assert (Uuid.string_is_valid (snapshot.draft.id));
        snapshot.draft.in_reply_to = "<source-message@example.net>";
        import_snapshot (cache, snapshot);

        var drafts_box = new Mailbox ("discard-drafts", "Drafts",
            "document-edit-symbolic", MailboxRole.DRAFTS, 0, account_id, "Drafts");
        var all_mail_box = new Mailbox ("discard-all-mail", "All Mail",
            "mail-archive-symbolic", MailboxRole.ARCHIVE, 0, account_id,
            "[Gmail]/All Mail");
        var sent_box = new Mailbox ("discard-sent", "Sent",
            "mail-sent-symbolic", MailboxRole.SENT, 0, account_id,
            "[Gmail]/Sent Mail");
        var provider_sync = new MailSyncResult (account_id);
        provider_sync.mailboxes.add (drafts_box);
        provider_sync.mailboxes.add (all_mail_box);
        provider_sync.mailboxes.add (sent_box);
        provider_sync.messages.add (new Message ("cached-cancelled-reply", drafts_box.id,
            "Draft", "", "maya@example.net", "Re: Provider draft", "Canceled reply",
            "This reply was canceled", "Today", false, false, false, 1, false,
            account_id, snapshot.remote_uid, snapshot.internet_message_id,
            snapshot.draft.in_reply_to, snapshot.draft.in_reply_to));
        // Gmail can expose the same draft under both Drafts and All Mail with
        // different UIDs and angle-bracket formatting for Message-ID.
        provider_sync.messages.add (new Message ("cached-cancelled-all-mail", all_mail_box.id,
            "Draft", "", "maya@example.net", "Re: Provider draft", "Canceled reply",
            "This reply was canceled", "Today", false, false, false, 1, false,
            account_id, "5191", "<%s>".printf (snapshot.internet_message_id),
            snapshot.draft.in_reply_to, snapshot.draft.in_reply_to));
        var stripped_legacy_copy = new Message ("cached-stripped-all-mail",
            all_mail_box.id, "Draft", "", "maya@example.net", "Re: Provider draft",
            "Canceled reply", "This reply was canceled", "Today", false, false,
            false, 1, false, account_id, "5192", "",
            snapshot.draft.in_reply_to, snapshot.draft.in_reply_to);
        stripped_legacy_copy.raw_headers =
            "From: maya@example.net\r\n" +
            "X-Mailficient-Draft-ID: %s\r\n".printf (snapshot.draft.id) +
            "X-Mailficient-Draft-Revision: %s\r\n".printf (
                snapshot.draft.revision.to_string ());
        provider_sync.messages.add (stripped_legacy_copy);
        // A sent copy may preserve the draft Message-ID. It is real sent mail,
        // not a provider Drafts mirror, and must never be hidden by discard.
        provider_sync.messages.add (new Message ("sent-with-draft-id", sent_box.id,
            "Alex", "alex@example.net", "maya@example.net", "Re: Provider draft",
            "Sent content", "Sent content", "Today", false, false, false, 1,
            false, account_id, "6191", snapshot.internet_message_id,
            snapshot.draft.in_reply_to, snapshot.draft.in_reply_to));
        cache.store_sync_result (provider_sync);
        assert (cache.find_cached_message ("cached-cancelled-reply") != null);
        assert (cache.find_cached_message ("cached-cancelled-all-mail") != null);
        var cached_stripped = cache.find_cached_message ("cached-stripped-all-mail");
        assert (cached_stripped != null);
        assert (cached_stripped.raw_headers.contains ("X-Mailficient-Draft-ID"));
        assert (cache.find_cached_message ("sent-with-draft-id") != null);

        // Simulate a row cached before managed_draft_identity was introduced.
        // Explicit Cancel must parse its bounded raw headers once and remove it
        // immediately, without waiting for another provider refresh.
        {
            Sqlite.Database legacy_cache;
            assert (Sqlite.Database.open (path, out legacy_cache) == Sqlite.OK);
            string? detail = null;
            assert (legacy_cache.exec ("UPDATE cached_messages SET " +
                "managed_draft_identity='' WHERE id='cached-stripped-all-mail'",
                null, out detail) == Sqlite.OK);
        }

        cache.delete_draft (snapshot.draft.id);
        assert (cache.load_draft (snapshot.draft.id) == null);
        assert (cache.find_cached_message ("cached-cancelled-reply") == null);
        assert (cache.find_cached_message ("cached-cancelled-all-mail") == null);
        assert (cache.find_cached_message ("cached-stripped-all-mail") == null);
        assert (cache.find_cached_message ("sent-with-draft-id") != null);

        // Both import paths can overlap the provider deletion. Neither may
        // resurrect the canceled reply while its deletion journal is pending.
        assert (!cache.import_remote_draft (snapshot, snapshot.draft));
        assert (cache.load_draft (snapshot.draft.id) == null);
        cache.store_sync_result (provider_sync);
        assert (cache.find_cached_message ("cached-cancelled-reply") == null);
        assert (cache.find_cached_message ("cached-cancelled-all-mail") == null);
        assert (cache.find_cached_message ("sent-with-draft-id") != null);

        // Successful provider deletion retires the network work, but keeps a
        // local identity tombstone. A snapshot fetched immediately before the
        // deletion completed still must not recreate the canceled reply.
        var pending = cache.list_pending_remote_draft_deletions (account_id);
        assert (pending.size == 1);
        cache.complete_remote_draft_deletion (pending[0].id);
        assert (cache.pending_remote_draft_deletion_count () == 0);
        cache.store_sync_result (provider_sync);
        assert (cache.find_cached_message ("cached-cancelled-reply") == null);
        assert (cache.find_cached_message ("cached-cancelled-all-mail") == null);
        assert (cache.find_cached_message ("sent-with-draft-id") != null);
        assert (!cache.import_remote_draft (snapshot, snapshot.draft));
        assert (cache.load_draft (snapshot.draft.id) == null);

        // If a provider strips Message-ID but preserves Mailficient's verified
        // draft headers, the RemoteDraftSnapshot supplies identity for this
        // batch only. That blocks the canceled copy without creating an unsafe
        // permanent UID-only rule.
        var stripped_sync = new MailSyncResult (account_id);
        stripped_sync.mailboxes.add (drafts_box);
        stripped_sync.mailboxes.add (all_mail_box);
        stripped_sync.messages.add (new Message ("stripped-id-cancelled", drafts_box.id,
            "Draft", "", "maya@example.net", "Re: Provider draft", "Canceled reply",
            "This reply was canceled", "Today", false, false, false, 1, false,
            account_id, snapshot.remote_uid, "", snapshot.draft.in_reply_to,
            snapshot.draft.in_reply_to));
        stripped_sync.messages.add (new Message ("stripped-id-all-mail",
            all_mail_box.id, "Draft", "", "maya@example.net", "Re: Provider draft",
            "Canceled reply", "This reply was canceled", "Today", false, false,
            false, 1, false, account_id, "stripped-all-mail-5191", "",
            snapshot.draft.in_reply_to, snapshot.draft.in_reply_to));
        stripped_sync.remote_drafts.add (new RemoteDraftSnapshot (snapshot.draft,
            "Drafts", snapshot.remote_uid, "", true,
            DraftFingerprint.calculate (snapshot.draft, snapshot.remote_uid)));
        // Archive identity metadata is filtering-only: it verifies the
        // provider's second view of the same managed draft without turning the
        // All Mail copy into another editable local draft.
        stripped_sync.verified_draft_copies.add (new RemoteDraftSnapshot (snapshot.draft,
            "[Gmail]/All Mail", "stripped-all-mail-5191", "", true,
            DraftFingerprint.calculate (snapshot.draft, "stripped-all-mail-5191")));
        cache.store_sync_result (stripped_sync);
        assert (cache.find_cached_message ("stripped-id-cancelled") == null);
        assert (cache.find_cached_message ("stripped-id-all-mail") == null);

        // A provider is allowed to reuse an old UID. A different, nonempty
        // Message-ID at that location is new mail and must survive the
        // canceled-draft tombstone.
        var replacement_sync = new MailSyncResult (account_id);
        replacement_sync.mailboxes.add (drafts_box);
        replacement_sync.messages.add (new Message ("uid-reuse-message", drafts_box.id,
            "Maya", "maya@example.net", "alex@example.net", "A different draft",
            "New provider content", "New provider content", "Today", false, false,
            false, 1, false, account_id, snapshot.remote_uid,
            "unrelated-message@example.net"));
        cache.store_sync_result (replacement_sync);
        assert (cache.find_cached_message ("uid-reuse-message") != null);

        var no_id_reuse_sync = new MailSyncResult (account_id);
        no_id_reuse_sync.mailboxes.add (drafts_box);
        no_id_reuse_sync.messages.add (new Message ("uid-reuse-without-id", drafts_box.id,
            "Maya", "maya@example.net", "alex@example.net", "No Message-ID",
            "A different no-ID provider message", "A different no-ID provider message",
            "Today", false, false, false, 1, false, account_id,
            snapshot.remote_uid, ""));
        cache.store_sync_result (no_id_reuse_sync);
        assert (cache.find_cached_message ("uid-reuse-without-id") != null);

        var unrelated = remote_snapshot (account_id, "unrelated-provider-draft",
            snapshot.remote_uid, 1, "This is a different provider draft");
        assert (cache.import_remote_draft (unrelated, unrelated.draft));
        assert (cache.load_draft (unrelated.draft.id) != null);
        var no_id_draft = new Draft (account_id, "unrelated-no-id-draft");
        no_id_draft.to = "maya@example.net"; no_id_draft.subject = "No Message-ID";
        no_id_draft.body_text = "This is unrelated to the canceled reply";
        var no_id_snapshot = new RemoteDraftSnapshot (no_id_draft, "Drafts",
            snapshot.remote_uid, "", false, DraftFingerprint.calculate (no_id_draft));
        assert (cache.import_remote_draft (no_id_snapshot, no_id_snapshot.draft));
        assert (cache.load_draft (no_id_draft.id) != null);
    } catch (Error error) {
        GLib.error ("Discarded provider draft tombstone test failed: %s", error.message);
    }
}

private void test_discard_during_remote_upload_claim () {
    string root = temporary_root ("mailficient-discard-upload-race");
    string path = Path.build_filename (root, "mail.sqlite");
    try {
        var cache = new CacheDatabase (path);
        var worker = new CacheDatabase (path);
        string account_id = "discard-upload-race-account";
        int64 lease_until = new DateTime.now_utc ().to_unix () + 300;

        // The provider append can finish after the user has closed and
        // discarded the composer. Its claimed revision gets a provisional
        // Message-ID tombstone before the local row is removed; recording the
        // eventual UID promotes that marker into actionable remote cleanup.
        var recorded = new Draft (account_id, "claimed-then-recorded");
        recorded.to = "maya@example.net"; recorded.subject = "Canceled reply";
        recorded.body_text = "This reply must not come back";
        cache.save_draft (recorded);
        var saved_recorded = cache.load_draft (recorded.id);
        assert (saved_recorded != null);
        int64 recorded_revision = saved_recorded.revision;
        assert (worker.claim_draft_upload (recorded.id, "upload-worker", lease_until));
        // The composer can autosave a newer revision while the worker is
        // appending the claimed one. Cancel must retain the identity of the
        // actual attempted revision, not merely the newest local revision.
        saved_recorded.body_text = "A newer local edit before cancel";
        saved_recorded.touch (); cache.save_draft (saved_recorded);
        assert (saved_recorded.revision > recorded_revision);
        cache.delete_draft (recorded.id);
        assert (cache.load_draft (recorded.id) == null);
        assert (cache.pending_remote_draft_deletion_count () == 0);
        var recorded_location = new RemoteDraftLocation ("Drafts", "upload-77");
        worker.record_remote_draft_uploaded (recorded.id, account_id,
            recorded_revision, recorded_location, "upload-worker", "fingerprint");
        var recorded_cleanup = cache.list_pending_remote_draft_deletions (account_id);
        assert (recorded_cleanup.size == 1);
        assert (recorded_cleanup[0].remote_uid == "upload-77");
        var recorded_snapshot = remote_snapshot (account_id, recorded.id, "upload-77",
            recorded_revision, recorded.body_text);
        assert (!cache.import_remote_draft (recorded_snapshot, recorded_snapshot.draft));
        assert (cache.load_draft (recorded.id) == null);

        // A folder refresh can win the same race before the upload worker has
        // persisted its UID. It must likewise promote the provisional marker
        // and reject the stale provider draft.
        var observed = new Draft (account_id, "claimed-then-observed");
        observed.to = "maya@example.net"; observed.subject = "Canceled reply";
        observed.body_text = "This canceled reply must stay gone";
        cache.save_draft (observed);
        var saved_observed = cache.load_draft (observed.id);
        assert (saved_observed != null);
        int64 observed_revision = saved_observed.revision;
        // Expiring/recovering the short ownership lease must not erase the
        // durable fact that an append of this revision was attempted.
        assert (worker.claim_draft_upload (observed.id, "second-worker",
            new DateTime.now_utc ().to_unix () - 1));
        assert (cache.list_pending_draft_uploads (account_id).size >= 1);
        cache.delete_draft (observed.id);
        var observed_snapshot = remote_snapshot (account_id, observed.id, "upload-88",
            observed_revision, observed.body_text);
        assert (!cache.import_remote_draft (observed_snapshot, observed_snapshot.draft));
        assert (cache.load_draft (observed.id) == null);
        var all_cleanup = cache.list_pending_remote_draft_deletions (account_id);
        assert (all_cleanup.size == 2);
        bool found_recorded = false; bool found_observed = false;
        foreach (var deletion in all_cleanup) {
            if (deletion.remote_uid == "upload-77") found_recorded = true;
            if (deletion.remote_uid == "upload-88") found_observed = true;
        }
        assert (found_recorded); assert (found_observed);

        // The opposite ordering is equally important: an expired rev-1 worker
        // reports its redundant UID after the user has saved rev 2, but just
        // before Cancel. Recording generic cleanup must retain enough identity
        // for the later explicit discard to upgrade it permanently.
        var reported_first = new Draft (account_id, "recorded-before-cancel");
        reported_first.to = "maya@example.net";
        reported_first.body_text = "Revision one";
        cache.save_draft (reported_first);
        var revision_one = cache.load_draft (reported_first.id);
        assert (revision_one != null);
        int64 attempted_revision = revision_one.revision;
        assert (worker.claim_draft_upload (reported_first.id, "expired-worker",
            new DateTime.now_utc ().to_unix () - 1));
        revision_one.body_text = "Revision two"; revision_one.touch ();
        cache.save_draft (revision_one);
        assert (cache.list_pending_draft_uploads (account_id).size >= 1);
        worker.record_remote_draft_uploaded (reported_first.id, account_id,
            attempted_revision, new RemoteDraftLocation ("Drafts", "upload-99"),
            "expired-worker", "rev-one-fingerprint");
        PendingDraftDeletion? generic_cleanup = null;
        foreach (var deletion in cache.list_pending_remote_draft_deletions (account_id))
            if (deletion.remote_uid == "upload-99") generic_cleanup = deletion;
        assert (generic_cleanup != null);
        // The provider cleanup can finish before the user's subsequent Cancel.
        // Its completed row must not erase the upload-attempt identity needed
        // to turn the later cancel into a permanent tombstone.
        cache.complete_remote_draft_deletion (generic_cleanup.id);
        cache.delete_draft (reported_first.id);
        var reported_snapshot = remote_snapshot (account_id, reported_first.id,
            "upload-99", attempted_revision, "Revision one");
        assert (!cache.import_remote_draft (reported_snapshot,
            reported_snapshot.draft));
        assert (cache.load_draft (reported_first.id) == null);
        bool found_reported = false;
        foreach (var deletion in cache.list_pending_remote_draft_deletions (account_id))
            if (deletion.remote_uid == "upload-99") found_reported = true;
        assert (found_reported);
    } catch (Error error) {
        GLib.error ("Discard-during-upload race test failed: %s", error.message);
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
    Test.add_func ("/draft-sync/no-message-id-discard-fingerprint",
        test_no_message_id_discard_uses_fingerprint_tombstone);
    Test.add_func ("/draft-sync/no-id-uid-reuse-between-batch-store-and-draft-import",
        test_no_id_uid_reuse_between_batch_store_and_draft_import);
    Test.add_func ("/draft-sync/legacy-discard-tombstone-migration",
        test_legacy_discard_tombstone_migration);
    Test.add_func ("/draft-sync/discard-tombstones-provider-copy",
        test_discard_tombstones_provider_copy);
    Test.add_func ("/draft-sync/discard-during-remote-upload-claim",
        test_discard_during_remote_upload_claim);
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
