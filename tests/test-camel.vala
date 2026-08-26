using GLib;

namespace Mailficient {
private class EmptyCredentialStore : Object, CredentialStore {
    public async void store_password (string account_id, string protocol, string password,
                                      Cancellable? cancellable = null) throws Error { }
    public async string? lookup_password (string account_id, string protocol,
                                          Cancellable? cancellable = null) throws Error { return null; }
    public async void clear_account (string account_id, Cancellable? cancellable = null) throws Error { }
}

private class DelayedCredentialStore : Object, CredentialStore {
    public int lookups;

    public async void store_password (string account_id, string protocol, string password,
                                      Cancellable? cancellable = null) throws Error { }
    public async string? lookup_password (string account_id, string protocol,
                                          Cancellable? cancellable = null) throws Error {
        lookups++;
        Timeout.add (25, () => { lookup_password.callback (); return Source.REMOVE; });
        yield;
        if (cancellable != null) cancellable.set_error_if_cancelled ();
        return null;
    }
    public async void clear_account (string account_id, Cancellable? cancellable = null) throws Error { }
}

private class FailingAttachmentData : Camel.DataWrapper {
    public override ssize_t decode_to_output_stream_sync (OutputStream output,
                                                           Cancellable? cancellable = null) throws Error {
        uint8[] partial = { 0x70, 0x61, 0x72, 0x74, 0x69, 0x61, 0x6c };
        size_t written;
        output.write_all (partial, out written, cancellable);
        throw new IOError.INVALID_DATA ("Synthetic truncated MIME part");
    }
}

private class MisreportedOversizedAttachmentData : Camel.DataWrapper {
    public override ssize_t decode_to_output_stream_sync (OutputStream output,
                                                           Cancellable? cancellable = null) throws Error {
        uint8[] chunk = new uint8[24];
        for (int index = 0; index < chunk.length; index++) chunk[index] = (uint8) (index + 1);
        size_t written;
        output.write_all (chunk, out written, cancellable);
        output.write_all (chunk, out written, cancellable);
        return 48;
    }
}

private void test_sync_memory_bounds () {
    assert (CamelMailEngine.SYNC_BATCH_SIZE > 0);
    assert (CamelMailEngine.INBOX_PREFETCH_LIMIT > 0);
    assert (CamelMailEngine.INBOX_PREFETCH_LIMIT <= CamelMailEngine.SYNC_BATCH_SIZE);
    assert (CamelMailEngine.UID_TRAVERSAL_TIME_SLICE_USEC > 0);
    assert (CamelMailEngine.UID_TRAVERSAL_TIME_SLICE_USEC < 16 * 1000);

    Error? failure = null;
    try {
        CamelMailEngine.decode_text (new MisreportedOversizedAttachmentData (), 32);
    } catch (Error error) { failure = error; }
    assert (failure is IOError.MESSAGE_TOO_LARGE);
}

private void test_inbox_prefetch_is_ordered_bounded_and_unique () {
    var source = new Gee.ArrayList<Mailbox> ();
    var archive = new Mailbox ("a:archive", "Archive", "folder-symbolic",
        MailboxRole.ARCHIVE, 0, "a", "Archive");
    var inbox = new Mailbox ("a:inbox", "Inbox", "mail-inbox-symbolic",
        MailboxRole.INBOX, 0, "a", "INBOX");
    var secondary_inbox = new Mailbox ("a:inbox-2", "Other Inbox",
        "mail-inbox-symbolic", MailboxRole.INBOX, 0, "a", "Inbox-2");
    var sent = new Mailbox ("a:sent", "Sent", "mail-sent-symbolic",
        MailboxRole.SENT, 0, "a", "Sent");
    source.add (archive); source.add (inbox); source.add (sent);
    source.add (secondary_inbox);
    var ordered = CamelMailEngine.inbox_first_mailboxes (source);
    assert (ordered.size == 4);
    assert (ordered[0] == inbox); assert (ordered[1] == secondary_inbox);
    assert (ordered[2] == archive); assert (ordered[3] == sent);
    // The provider-facing inventory order is not mutated merely to prioritize
    // network work.
    assert (source[0] == archive); assert (source[1] == inbox);

    var candidates = new Gee.ArrayList<string> ();
    for (int index = 0; index < 8; index++) candidates.add (index.to_string ());
    var prefetched = CamelMailEngine.take_inbox_prefetch_uids (candidates, 0);
    assert (prefetched.size == CamelMailEngine.INBOX_PREFETCH_LIMIT);
    assert (candidates.size == 8 - CamelMailEngine.INBOX_PREFETCH_LIMIT);
    assert (prefetched[0] == "7"); assert (prefetched[1] == "6");
    assert (candidates[0] == "0"); assert (candidates[candidates.size - 1] == "2");
    foreach (var uid in prefetched) assert (!candidates.contains (uid));
    assert (CamelMailEngine.bounded_inbox_prefetch_count (
        candidates.size, prefetched.size) == 0);

    var first_inbox = new Gee.ArrayList<string> ();
    first_inbox.add ("1"); first_inbox.add ("2"); first_inbox.add ("3");
    var second_inbox = new Gee.ArrayList<string> ();
    second_inbox.add ("10"); second_inbox.add ("11");
    second_inbox.add ("12"); second_inbox.add ("13");
    second_inbox.add ("14");
    var first_selected = CamelMailEngine.take_inbox_prefetch_uids (
        first_inbox, 0);
    var second_selected = CamelMailEngine.take_inbox_prefetch_uids (
        second_inbox, first_selected.size);
    assert (first_selected.size == 3); assert (second_selected.size == 2);
    assert (first_selected.size + second_selected.size ==
        CamelMailEngine.INBOX_PREFETCH_LIMIT);
    assert (second_selected[0] == "14"); assert (second_selected[1] == "13");

    // Prefetch consumes, rather than expands, the existing 250-message pass.
    int later = CamelMailEngine.bounded_folder_download_count (
        CamelMailEngine.MAX_MESSAGES_PER_SYNC_SESSION,
        prefetched.size);
    assert (prefetched.size + later ==
        CamelMailEngine.MAX_MESSAGES_PER_SYNC_SESSION);
}

private void test_uid_traversal_uses_elapsed_time_slice () {
    int64 started = 1000000;
    int64 slice = CamelMailEngine.UID_TRAVERSAL_TIME_SLICE_USEC;
    assert (!CamelMailEngine.uid_traversal_time_slice_expired (started, started));
    assert (!CamelMailEngine.uid_traversal_time_slice_expired (
        started, started + slice - 1));
    assert (CamelMailEngine.uid_traversal_time_slice_expired (
        started, started + slice));
    assert (CamelMailEngine.uid_traversal_time_slice_expired (
        started, started + (slice * 4)));
    assert (!CamelMailEngine.uid_traversal_time_slice_expired (started, started - 1));
}

private void test_cache_namespace_tracks_eds_branch () {
    assert (CamelCacheNamespace.leaf_for_version (3, 56) == "camel-cache-eds-3-56");
    assert (CamelCacheNamespace.leaf_for_version (3, 60) == "camel-cache-eds-3-60");
    assert (CamelCacheNamespace.leaf_for_version (-1, -1) == "camel-cache-eds-0-0");

    string root = Path.build_filename (Environment.get_tmp_dir (), "mailficient-cache-root");
    string path = CamelCacheNamespace.path_for (root);
    assert (Path.get_dirname (path) == root);
    assert (Path.get_basename (path) == CamelCacheNamespace.leaf_for_version (
        E.EDS_MAJOR_VERSION, E.EDS_MINOR_VERSION));
}

private void test_zero_byte_cache_repair_is_narrow () {
    string root = Path.build_filename (Environment.get_tmp_dir (),
        "mailficient-zero-cache-%s".printf (Uuid.string_random ()));
    string empty_path = Path.build_filename (root, "empty");
    string nonempty_path = Path.build_filename (root, "nonempty");
    string target_path = Path.build_filename (root, "target");
    string link_path = Path.build_filename (root, "link");
    string directory_path = Path.build_filename (root, "directory");
    try {
        assert (DirUtils.create_with_parents (directory_path, 0700) == 0);
        FileUtils.set_contents (empty_path, "");
        FileUtils.set_contents (nonempty_path, "mail");
        FileUtils.set_contents (target_path, "");
        File.new_for_path (link_path).make_symbolic_link (target_path);

        assert (CamelMailEngine.remove_zero_byte_cache_file (
            File.new_for_path (empty_path)));
        assert (!File.new_for_path (empty_path).query_exists ());

        assert (!CamelMailEngine.remove_zero_byte_cache_file (
            File.new_for_path (nonempty_path)));
        assert (File.new_for_path (nonempty_path).query_exists ());

        assert (!CamelMailEngine.remove_zero_byte_cache_file (
            File.new_for_path (link_path)));
        assert (File.new_for_path (link_path).query_exists ());
        assert (File.new_for_path (target_path).query_exists ());

        assert (!CamelMailEngine.remove_zero_byte_cache_file (
            File.new_for_path (directory_path)));
        assert (!CamelMailEngine.remove_zero_byte_cache_file (
            File.new_for_path (Path.build_filename (root, "missing"))));
    } catch (Error error) {
        GLib.error ("Zero-byte Camel cache repair test failed: %s", error.message);
    } finally {
        FileUtils.unlink (link_path);
        FileUtils.unlink (nonempty_path);
        FileUtils.unlink (target_path);
        DirUtils.remove (directory_path);
        DirUtils.remove (root);
    }
}

private void test_sync_result_can_forget_vanished_uid () {
    var result = new MailSyncResult ("vanished-account");
    var inbox = new Mailbox ("vanished-account:inbox", "Inbox",
        "mail-inbox-symbolic", MailboxRole.INBOX, 2,
        "vanished-account", "INBOX");
    result.record_remote_uid (inbox.id, "41");
    result.record_remote_uid (inbox.id, "42");
    var unread_uids = new Gee.HashSet<string> ();
    unread_uids.add ("41"); unread_uids.add ("42");
    CamelMailEngine.forget_vanished_uid (result, inbox, unread_uids, "41");
    result.forget_remote_uid ("vanished-account:missing", "1");
    var inventory = result.remote_uids_for (inbox.id);
    assert (inventory != null);
    assert (!inventory.contains ("41"));
    assert (inventory.contains ("42"));
    assert (inbox.unread_count == 1);
    // A vanished message which was already read must not change the unread
    // total, even when the provider repeats the disappearance.
    CamelMailEngine.forget_vanished_uid (result, inbox, unread_uids, "99");
    assert (inbox.unread_count == 1);
}

private void test_sync_session_message_limit_preserves_inventory () {
    var result = new MailSyncResult ("bounded-account");
    var inbox = new Mailbox ("bounded-account:inbox", "Inbox", "mail-inbox-symbolic",
        MailboxRole.INBOX, 249, "bounded-account", "INBOX");
    var archive = new Mailbox ("bounded-account:archive", "Archive", "package-x-generic-symbolic",
        MailboxRole.ARCHIVE, 12, "bounded-account", "Archive");
    result.mailboxes.add (inbox); result.mailboxes.add (archive);
    for (int index = 0; index < 249; index++) {
        string uid = index.to_string ();
        result.record_remote_uid (inbox.id, uid);
        result.states.add (new RemoteMessageState (inbox.id + ":" + uid, true, false));
    }
    for (int index = 0; index < 12; index++) {
        string uid = index.to_string ();
        result.record_remote_uid (archive.id, uid);
        result.states.add (new RemoteMessageState (archive.id + ":" + uid, false, false));
    }

    int target = CamelMailEngine.configure_download_budget (result, 261);
    assert (CamelMailEngine.MAX_MESSAGES_PER_SYNC_SESSION == 250);
    assert (target == 250); assert (result.messages_to_download == 261);
    assert (result.more_messages_available);

    int scheduled = CamelMailEngine.bounded_folder_download_count (249, 0);
    assert (scheduled == 249);
    scheduled += CamelMailEngine.bounded_folder_download_count (12, scheduled);
    assert (scheduled == 250);
    assert (CamelMailEngine.bounded_folder_download_count (20, scheduled) == 0);

    // Applying the MIME budget must not truncate the authoritative inventory
    // and remote state used by CacheDatabase to reconcile every folder.
    var inbox_uids = result.remote_uids_for (inbox.id);
    var archive_uids = result.remote_uids_for (archive.id);
    assert (result.mailboxes.size == 2); assert (result.states.size == 261);
    assert (inbox_uids != null && inbox_uids.size == 249);
    assert (archive_uids != null && archive_uids.size == 12);
}

private void test_top_level_html_body () {
    try {
        string source = "<!doctype html><html><body><table><tr><td>Full message</td></tr></table></body></html>";
        var message = new Camel.MimeMessage ();
        message.set_content (source.data, "text/html; charset=utf-8");
        var content = ((Camel.Medium) message).get_content ();
        assert (content != null);
        string plain = "";
        string html = "";
        CamelMailEngine.extract_leaf_text (content, ref plain, ref html);
        assert (plain == "");
        assert (html == source);
    } catch (Error error) {
        GLib.error ("Top-level HTML extraction test failed: %s", error.message);
    }
}

private void test_unnamed_inline_calendar_is_extracted () {
    string root = Path.build_filename (Environment.get_tmp_dir (),
        "mailficient-calendar-mime-%s".printf (Uuid.string_random ()));
    assert (DirUtils.create_with_parents (root, 0700) == 0);
    try {
        var multipart = new Camel.Multipart ();
        multipart.set_mime_type ("multipart/mixed");
        var body = new Camel.MimePart ();
        body.set_content ("Message body".data, "text/plain; charset=utf-8");
        multipart.add_part (body);
        var calendar = new Camel.MimePart ();
        string payload = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:REQUEST\r\n" +
            "BEGIN:VEVENT\r\nUID:mime@example.net\r\nDTSTART:20260910T130000Z\r\n" +
            "SUMMARY:MIME invitation\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
        calendar.set_content (payload.data, "text/calendar; method=REQUEST; charset=utf-8");
        // Deliberately omit Content-Disposition and filename: Outlook and
        // Exchange both emit this valid shape.
        multipart.add_part (calendar);

        var engine = new CamelMailEngine (new EmptyCredentialStore (),
            Path.build_filename (root, "data"), Path.build_filename (root, "cache"),
            Path.build_filename (root, "received"));
        string plain = ""; string html = ""; bool has_attachment = false;
        int attachment_index = 0;
        int64 remaining = AttachmentService.MAX_TOTAL_ATTACHMENT_SIZE;
        var attachments = new Gee.ArrayList<Attachment> ();
        engine.extract_content (multipart, ref plain, ref html, ref has_attachment,
            attachments, "mailbox:calendar", ref attachment_index, ref remaining, null);

        assert (plain == "Message body"); assert (html == "");
        assert (has_attachment); assert (attachment_index == 1);
        assert (attachments.size == 1);
        assert (attachments[0].name == "invitation.ics");
        assert (attachments[0].is_calendar_invitation ());
        assert (attachments[0].is_downloaded ());
        string staged; FileUtils.get_contents (attachments[0].path, out staged);
        // Camel normalizes decoded text line endings. The complete calendar
        // object and action metadata must otherwise survive extraction.
        assert (staged.replace ("\r\n", "\n") == payload.replace ("\r\n", "\n"));
    } catch (Error error) {
        GLib.error ("Inline calendar MIME extraction failed: %s", error.message);
    }
}

private void test_html_only_remote_draft_plain_fidelity () {
    string html = "<div>Hello <strong>provider draft</strong></div>";
    assert (CamelMailEngine.remote_draft_plain_body ("", html) ==
        "Hello provider draft");
    assert (CamelMailEngine.remote_draft_plain_body ("Exact plain", html) ==
        "Exact plain");
    assert (CamelMailEngine.remote_draft_plain_body ("", "") == "");
}

private void test_managed_remote_draft_identity_without_message_id () {
    string id = "8d3b6d0a-8ca1-4b44-a850-a8f86f6f4e42";
    string expected = Draft.remote_message_id_for (id, 7);
    int64 revision;
    assert (CamelMailEngine.is_managed_remote_draft_identity (
        id, "7", expected, out revision));
    assert (revision == 7);
    assert (CamelMailEngine.is_managed_remote_draft_identity (
        id, "7", "", out revision));
    assert (revision == 7);
    assert (!CamelMailEngine.is_managed_remote_draft_identity (
        id, "7", "different@example.net", out revision));
    assert (!CamelMailEngine.is_managed_remote_draft_identity (
        "not-a-uuid", "7", "", out revision));

    var stripped = new Camel.MimeMessage ();
    stripped.set_header ("X-Mailficient-Draft-ID", id);
    stripped.set_header ("X-Mailficient-Draft-Revision", "7");
    assert (CamelMailEngine.remote_draft_matches_expected_identity (
        stripped, expected));
    assert (!CamelMailEngine.remote_draft_matches_expected_identity (
        stripped, Draft.remote_message_id_for (id, 8)));
    stripped.set_message_id ("different@example.net");
    assert (!CamelMailEngine.remote_draft_matches_expected_identity (
        stripped, expected));

    var no_id_draft = new Draft ("fingerprint-account", "provider-no-id");
    no_id_draft.subject = "No Message-ID";
    no_id_draft.body_text = "Exact provider content";
    string fingerprint = DraftFingerprint.calculate (no_id_draft, "41");
    var no_id_snapshot = new RemoteDraftSnapshot (no_id_draft, "Drafts", "41",
        "", false, fingerprint);
    assert (CamelMailEngine.remote_draft_matches_expected_fingerprint (
        no_id_snapshot, fingerprint));
    assert (!CamelMailEngine.remote_draft_matches_expected_fingerprint (
        no_id_snapshot, "different-fingerprint"));
    var identified_snapshot = new RemoteDraftSnapshot (no_id_draft, "Drafts",
        "41", "present@example.net", false, fingerprint);
    assert (!CamelMailEngine.remote_draft_matches_expected_fingerprint (
        identified_snapshot, fingerprint));
}

private void test_malformed_text_charset_falls_back_safely () {
    try {
        string source = "Malformed bulk-mail body";
        var message = new Camel.MimeMessage ();
        message.set_content (source.data, "text/plain; charset=3DUTF-8");
        var content = ((Camel.Medium) message).get_content ();
        assert (content != null);
        assert (CamelMailEngine.decode_text (content) == source);
        unowned Camel.ContentType? content_type = content.get_mime_type_field ();
        assert (content_type != null);
        // Repair the label for decoding without mutating Camel's borrowed
        // MIME metadata object.
        assert (content_type.param ("charset").ascii_casecmp ("3DUTF-8") == 0);

        content_type.set_param ("charset", "definitely-not-a-real-charset");
        assert (CamelMailEngine.decode_text (content) == source);
        // Unsupported metadata must not be relabelled as UTF-8 without
        // converting the bytes. Valid UTF-8 content is still preserved.
        assert (content_type.param ("charset").ascii_casecmp (
            "definitely-not-a-real-charset") == 0);
    } catch (Error error) {
        GLib.error ("Malformed text charset fallback test failed: %s", error.message);
    }
}

private static string decode_raw_text (uint8[] bytes, string mime_type) throws Error {
    var message = new Camel.MimeMessage ();
    message.set_content (bytes, mime_type);
    var content = ((Camel.Medium) message).get_content ();
    assert (content != null);
    return CamelMailEngine.decode_text (content);
}

private void test_text_charsets_are_converted_to_utf8 () {
    try {
        uint8[] latin1 = { 'c', 'a', 'f', 0xe9 };
        assert (decode_raw_text (latin1,
            "text/plain; charset=iso-8859-1") == "café");

        uint8[] windows_mislabelled = {
            0x93, 'Q', 'u', 'o', 't', 'e', 'd', 0x94
        };
        assert (decode_raw_text (windows_mislabelled,
            "text/plain; charset=iso-8859-1") == "“Quoted”");

        // A supported, explicit MIME charset is authoritative even when its
        // bytes also happen to form valid UTF-8.
        uint8[] valid_utf8_but_windows = { 0xc3, 0xa9 };
        assert (decode_raw_text (valid_utf8_but_windows,
            "text/plain; charset=windows-1252") == "Ã©");

        // Invalid input in a supported charset must remain visible rather
        // than being silently dropped by a permissive streaming filter.
        uint8[] malformed_utf8 = { 'A', 0xc3, 'B' };
        assert (decode_raw_text (malformed_utf8,
            "text/plain; charset=utf-8") == "A�B");

        uint8[] utf16le = {
            0xff, 0xfe, 'H', 0x00, 'i', 0x00, ' ', 0x00, 0x13, 0x27
        };
        assert (decode_raw_text (utf16le,
            "text/plain; charset=us-ascii") == "Hi ✓");

        uint8[] nul_html = {
            '<', 'p', '>', 'A', 0x00, 'B', '<', '/', 'p', '>'
        };
        string nul_result = decode_raw_text (nul_html,
            "text/html; charset=utf-8");
        assert (nul_result == "<p>A�B</p>");
        assert (nul_result.length > 8);

        uint8[] meta_prefix = "<meta charset=windows-1252><p>caf".data;
        uint8[] meta_suffix = "</p>".data;
        var meta = new ByteArray ();
        meta.append (meta_prefix); uint8[] accent = { 0xe9 }; meta.append (accent);
        meta.append (meta_suffix);
        assert (decode_raw_text (meta.data,
            "text/html") == "<meta charset=windows-1252><p>café</p>");
    } catch (Error error) {
        GLib.error ("Text charset conversion test failed: %s", error.message);
    }
}

private void test_quoted_printable_charset_is_decoded_once () {
    try {
        string wire =
            "Content-Type: text/html; charset=iso-8859-1\r\n" +
            "Content-Transfer-Encoding: quoted-printable\r\n\r\n" +
            "<p>caf=E9</p><a href=3D\"https://example.net/read?a=3D1\">Open</a>";
        var parser = new Camel.MimeParser ();
        parser.init_with_bytes (new Bytes (wire.data));
        var part = new Camel.MimePart ();
        assert (part.construct_from_parser_sync (parser));
        var content = part.get_content ();
        assert (content != null);
        string decoded = CamelMailEngine.decode_text (content);
        assert (decoded ==
            "<p>café</p><a href=\"https://example.net/read?a=1\">Open</a>");
        assert (!decoded.contains ("=E9"));
        assert (!decoded.contains ("=3D"));
    } catch (Error error) {
        GLib.error ("Quoted-printable charset test failed: %s", error.message);
    }
}

private void test_sync_cooperatively_yields () {
    bool completed = false;
    Error? failure = null;
    var loop = new MainLoop ();
    CamelMailEngine.yield_to_main_context.begin (null, (object, result) => {
        try { CamelMailEngine.yield_to_main_context.end (result); }
        catch (Error error) { failure = error; }
        completed = true;
        loop.quit ();
    });
    // The helper must return control before completing; otherwise it cannot
    // prevent a MIME/UID loop from starving GTK rendering.
    assert (!completed);
    loop.run ();
    assert (completed);
    assert (failure == null);
}

private void test_cooperative_yield_honors_cancellation () {
    bool completed = false;
    Error? failure = null;
    var cancellable = new Cancellable ();
    cancellable.cancel ();
    var loop = new MainLoop ();
    CamelMailEngine.yield_to_main_context.begin (cancellable, (object, result) => {
        try { CamelMailEngine.yield_to_main_context.end (result); }
        catch (Error error) { failure = error; }
        completed = true;
        loop.quit ();
    });
    assert (!completed);
    loop.run ();
    assert (completed);
    assert (failure is IOError.CANCELLED);
}

private async void exercise_failed_retries (CamelMailEngine engine, AccountSettings account) {
    for (int attempt = 0; attempt < 2; attempt++) {
        Error? failure = null;
        try { yield engine.connect_account (account); } catch (Error error) { failure = error; }
        assert (failure is MailError.AUTHENTICATION);
    }
}

private void test_failed_connection_can_retry () {
    string root = Path.build_filename (Environment.get_tmp_dir (), "mailficient-camel-%s".printf (Uuid.string_random ()));
    assert (DirUtils.create_with_parents (root, 0700) == 0);
    var engine = new CamelMailEngine (new EmptyCredentialStore (), Path.build_filename (root, "data"),
        Path.build_filename (root, "cache"), Path.build_filename (root, "attachments"));
    var account = AccountSettings.for_email ("Test", "test@example.net"); account.id = "camel-retry";
    account.incoming_host = "imap.example.net"; account.outgoing_host = "smtp.example.net";
    var loop = new MainLoop ();
    exercise_failed_retries.begin (engine, account, (object, result) => {
        exercise_failed_retries.end (result); loop.quit ();
    });
    loop.run ();
    assert (engine.state_for (account.id).phase == SyncPhase.FAILED);
}

private void test_concurrent_connections_are_serialized () {
    string root = Path.build_filename (Environment.get_tmp_dir (),
        "mailficient-camel-concurrent-%s".printf (Uuid.string_random ()));
    assert (DirUtils.create_with_parents (root, 0700) == 0);
    var credentials = new DelayedCredentialStore ();
    var engine = new CamelMailEngine (credentials, Path.build_filename (root, "data"),
        Path.build_filename (root, "cache"), Path.build_filename (root, "attachments"));
    var account = AccountSettings.for_email ("Test", "test@example.net"); account.id = "camel-concurrent";
    account.incoming_host = "imap.example.net"; account.outgoing_host = "smtp.example.net";
    int completed = 0; Error? first_failure = null; Error? second_failure = null;
    var loop = new MainLoop ();
    engine.connect_account.begin (account, null, (object, result) => {
        try { engine.connect_account.end (result); } catch (Error error) { first_failure = error; }
        completed++; if (completed == 2) loop.quit ();
    });
    engine.connect_account.begin (account, null, (object, result) => {
        try { engine.connect_account.end (result); } catch (Error error) { second_failure = error; }
        completed++; if (completed == 2) loop.quit ();
    });
    loop.run ();
    assert (first_failure != null); assert (second_failure != null);
    // Only the owning attempt reaches Secret Service; the second call waits for
    // its result instead of creating a colliding Camel service pair.
    assert (credentials.lookups == 1);
    assert (engine.state_for (account.id).phase == SyncPhase.FAILED);
}

private void test_error_classification () {
    assert (CamelMailEngine.normalize_error (new Camel.ServiceError.CANT_AUTHENTICATE ("Denied")) is MailError.AUTHENTICATION);
    assert (CamelMailEngine.normalize_error (new IOError.TIMED_OUT ("Slow")) is MailError.TIMEOUT);
    assert (CamelMailEngine.normalize_error (new IOError.HOST_NOT_FOUND ("Missing")) is MailError.OFFLINE);
    assert (CamelMailEngine.normalize_error (new TlsError.BAD_CERTIFICATE ("Untrusted")) is MailError.TLS);
    assert (CamelMailEngine.normalize_error (new Camel.ServiceError.UNAVAILABLE (
        "Too many requests; account is temporarily throttled")) is MailError.RATE_LIMITED);
    assert (CamelMailEngine.is_rate_limit_error ("451 Temporarily deferred by provider policy"));
    assert (!CamelMailEngine.is_rate_limit_error ("Connection closed unexpectedly"));
    assert (CamelMailEngine.normalize_send_error (
        new Camel.ServiceError.UNAVAILABLE ("550 Recipient address rejected"), true)
        is MailError.SEND_REJECTED);
    assert (CamelMailEngine.normalize_send_error (
        new Camel.ServiceError.UNAVAILABLE ("450 Mailbox temporarily unavailable"), true)
        is MailError.SEND_FAILED);
    assert (CamelMailEngine.normalize_send_error (
        new Camel.ServiceError.UNAVAILABLE ("Connection ended"), false)
        is MailError.CONNECTION);
    assert (CamelMailEngine.normalize_send_error (
        new Camel.ServiceError.UNAVAILABLE ("451 Temporarily deferred by provider policy"), true)
        is MailError.RATE_LIMITED);
    assert (CamelMailEngine.is_permanent_smtp_rejection ("SMTP error 552 5.2.2 quota exceeded"));
    assert (!CamelMailEngine.is_permanent_smtp_rejection ("SMTP error 452 4.2.2 try later"));
}

private void test_certificate_failure_detail () {
    string detail = CamelMailEngine.certificate_failure_detail ("imap.example.net",
        TlsCertificateFlags.UNKNOWN_CA | TlsCertificateFlags.BAD_IDENTITY |
        TlsCertificateFlags.EXPIRED);
    assert (detail.contains ("imap.example.net"));
    assert (detail.contains ("issuer is not trusted"));
    assert (detail.contains ("does not match the server name"));
    assert (detail.contains ("expired"));
    var friendly = UserFacingError.from_error (new MailError.TLS (detail));
    assert (friendly.title == "Secure connection failed");
    assert (friendly.suggestion.contains ("Do not bypass"));
    assert (friendly.technical_detail == detail);
}

private void test_authentication_mechanism () {
    assert (CamelMailEngine.authentication_mechanism (AuthenticationMode.PASSWORD, true) == null);
    assert (CamelMailEngine.authentication_mechanism (AuthenticationMode.PASSWORD, false) == "PLAIN");
    assert (CamelMailEngine.authentication_mechanism (
        AuthenticationMode.GNOME_ONLINE_ACCOUNTS, true) == "XOAUTH2");
    assert (CamelMailEngine.authentication_mechanism (
        AuthenticationMode.GNOME_ONLINE_ACCOUNTS, false) == "XOAUTH2");
}

private void test_oauth_token_bridge () {
    try {
        string root = DirUtils.make_tmp ("mailficient-oauth-XXXXXX");
        var session = new PersonalCamelSession (Path.build_filename (root, "data"),
            Path.build_filename (root, "cache"));
        var service = session.add_service ("oauth-test-imap", "imapx", Camel.ProviderType.STORE);
        session.cache_oauth_token (service, new OAuthAccessToken ("short-lived-test-token", 2800));
        string? token;
        int expires_in;
        assert (session.get_oauth2_access_token_sync (service, out token, out expires_in));
        assert (token == "short-lived-test-token");
        assert (expires_in == 2800);
        session.clear_oauth_token (service);
        try {
            session.get_oauth2_access_token_sync (service, out token, out expires_in);
            assert_not_reached ();
        } catch (MailError.AUTHENTICATION error) {
            assert (error.message.contains ("OAuth access token"));
        }
        session.remove_service (service);
    } catch (Error error) {
        GLib.error ("OAuth token bridge test failed: %s", error.message);
    }
}

private void test_idle_configuration_and_change_filter () {
    var empty = new Camel.FolderChangeInfo ();
    assert (!CamelLiveMailWatch.change_requires_sync (empty));
    var changed_only = new Camel.FolderChangeInfo ();
    changed_only.change_uid ("1");
    assert (CamelLiveMailWatch.change_requires_sync (changed_only));
    var added = new Camel.FolderChangeInfo ();
    added.add_uid ("2");
    assert (CamelLiveMailWatch.change_requires_sync (added));
    var recent = new Camel.FolderChangeInfo ();
    recent.recent_uid ("3");
    assert (CamelLiveMailWatch.change_requires_sync (recent));
    var removed = new Camel.FolderChangeInfo ();
    removed.remove_uid ("4");
    assert (CamelLiveMailWatch.change_requires_sync (removed));

    try {
        string root = DirUtils.make_tmp ("mailficient-idle-settings-XXXXXX");
        // Keep this focused test independently runnable: Camel's provider
        // registry is initialized by the production engine constructor.
        var initializer = new CamelMailEngine (new EmptyCredentialStore (),
            Path.build_filename (root, "init-data"),
            Path.build_filename (root, "init-cache"),
            Path.build_filename (root, "init-attachments"));
        var session = new PersonalCamelSession (Path.build_filename (root, "data"),
            Path.build_filename (root, "cache"));
        // Mailficient has no client-side Camel rules. A null driver prevents
        // EDS from swallowing the first Inbox change for asynchronous filter
        // processing and avoids sharing a worker-owned driver instance.
        assert (session.client_filter_driver_for_testing () == null);
        var store = (Camel.Store) session.add_service (
            "idle-settings-imap", "imapx", Camel.ProviderType.STORE);
        var settings = store.ref_settings ();
        Value disabled = Value (typeof (bool));
        disabled.set_boolean (false);
        settings.set_property ("use-idle", disabled);
        assert (CamelLiveMailWatch.enable_idle (store));
        Value enabled = Value (typeof (bool));
        settings.get_property ("use-idle", ref enabled);
        assert (enabled.get_boolean ());
        session.remove_service (store);
    } catch (Error error) {
        GLib.error ("IMAP IDLE settings test failed: %s", error.message);
    }
}

private void test_folder_role_type_mask () {
    var subscribed = Camel.FolderInfoFlags.SUBSCRIBED;
    assert (CamelMailEngine.role_for_folder (Camel.FolderInfoFlags.TYPE_INBOX | subscribed,
        "Anything", "Anything") == MailboxRole.INBOX);
    assert (CamelMailEngine.role_for_folder (Camel.FolderInfoFlags.TYPE_TRASH | subscribed,
        "Anything", "Anything") == MailboxRole.TRASH);
    assert (CamelMailEngine.role_for_folder (Camel.FolderInfoFlags.TYPE_JUNK | subscribed,
        "Anything", "Anything") == MailboxRole.JUNK);
    assert (CamelMailEngine.role_for_folder (Camel.FolderInfoFlags.TYPE_SENT | subscribed,
        "Anything", "Anything") == MailboxRole.SENT);
    assert (CamelMailEngine.role_for_folder (Camel.FolderInfoFlags.TYPE_DRAFTS | subscribed,
        "Anything", "Anything") == MailboxRole.DRAFTS);
    assert (CamelMailEngine.role_for_folder (Camel.FolderInfoFlags.TYPE_ARCHIVE | subscribed,
        "Anything", "Anything") == MailboxRole.ARCHIVE);
    assert (CamelMailEngine.role_for_folder (Camel.FolderInfoFlags.TYPE_ALL | subscribed,
        "Anything", "Anything") == MailboxRole.ARCHIVE);

    // An explicit non-mail provider type must win over a misleading name.
    assert (CamelMailEngine.role_for_folder (Camel.FolderInfoFlags.TYPE_CONTACTS,
        "Inbox", "Inbox") == MailboxRole.CUSTOM);
}

private void test_folder_role_name_fallback () {
    var normal = Camel.FolderInfoFlags.TYPE_NORMAL | Camel.FolderInfoFlags.SUBSCRIBED;
    assert (CamelMailEngine.role_for_folder (normal, "Sent Items", "Sent Items") == MailboxRole.SENT);
    assert (CamelMailEngine.role_for_folder (normal, "Sent Messages", "Sent Messages") == MailboxRole.SENT);
    assert (CamelMailEngine.role_for_folder (normal, "", "[Gmail]/All Mail") == MailboxRole.ARCHIVE);
    assert (CamelMailEngine.role_for_folder (normal, "All Messages", "All Messages") == MailboxRole.ARCHIVE);
    assert (CamelMailEngine.role_for_folder (normal, "spam", "spam") == MailboxRole.JUNK);
    assert (CamelMailEngine.role_for_folder (normal, "Junk E-mail", "Junk E-mail") == MailboxRole.JUNK);
    assert (CamelMailEngine.role_for_folder (normal, "Deleted Items", "Deleted Items") == MailboxRole.TRASH);
    assert (CamelMailEngine.role_for_folder (normal, "Bin", "Bin") == MailboxRole.TRASH);
    assert (CamelMailEngine.role_for_folder (normal, "Drafts", "Account.Drafts") == MailboxRole.DRAFTS);
    assert (CamelMailEngine.role_for_folder (normal, "Sentinel", "Sentinel") == MailboxRole.CUSTOM);
    assert (CamelMailEngine.role_for_folder (normal, "Trash reports", "Trash reports") == MailboxRole.CUSTOM);
}

private void test_destination_uid_recovery () {
    var before = new Gee.HashSet<string> (); before.add ("10"); before.add ("11");
    var after = new Gee.HashMap<string, uint64?> ();
    after["10"] = 100; after["11"] = 101; after["12"] = 9001;
    assert (CamelMailEngine.choose_recovered_destination_uid (before, after, 9001) == "12");

    after["13"] = 42;
    assert (CamelMailEngine.choose_recovered_destination_uid (before, after, 9001) == "12");
    after["14"] = 9001;
    assert (CamelMailEngine.choose_recovered_destination_uid (before, after, 9001) == null);

    var one_new_unknown = new Gee.HashMap<string, uint64?> ();
    one_new_unknown["10"] = 100; one_new_unknown["20"] = 0;
    assert (CamelMailEngine.choose_recovered_destination_uid (before, one_new_unknown, 0) == "20");
}

private void test_failed_attachment_decode_is_atomic () {
    string root = Path.build_filename (Environment.get_tmp_dir (),
        "mailficient-attachment-failure-%s".printf (Uuid.string_random ()));
    string received = Path.build_filename (root, "received");
    assert (DirUtils.create_with_parents (root, 0700) == 0);
    var store = new ReceivedAttachmentStore (received);

    Error? failure = null;
    try {
        store.save (new FailingAttachmentData (), "report.txt", "text/plain",
            "mailbox:42", 1, null);
    } catch (Error error) { failure = error; }
    assert (failure is IOError.INVALID_DATA);

    try {
        var enumerator = File.new_for_path (received).enumerate_children (FileAttribute.STANDARD_NAME,
            FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        assert (enumerator.next_file () == null);
        enumerator.close ();
    } catch (Error error) {
        GLib.error ("Could not inspect attachment staging directory: %s", error.message);
    }
}

private void test_misreported_attachment_is_bounded () {
    string root = Path.build_filename (Environment.get_tmp_dir (),
        "mailficient-attachment-limit-%s".printf (Uuid.string_random ()));
    string received = Path.build_filename (root, "received");
    assert (DirUtils.create_with_parents (root, 0700) == 0);
    var store = new ReceivedAttachmentStore (received, 32);
    try {
        var saved = store.save (new MisreportedOversizedAttachmentData (), "oversized.bin",
            "application/octet-stream", "mailbox:limit", 1, null);
        assert (saved != null); assert (!saved.is_downloaded ());
        assert (saved.remote_part_index == 1); assert (saved.name == "oversized.bin");
        var enumerator = File.new_for_path (received).enumerate_children (FileAttribute.STANDARD_NAME,
            FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        assert (enumerator.next_file () == null);
        enumerator.close ();
    } catch (Error error) {
        GLib.error ("Bounded attachment test failed: %s", error.message);
    }
}

private void test_remote_attachment_part_addressing () {
    try {
        var multipart = new Camel.Multipart (); multipart.set_mime_type ("multipart/mixed");
        var first = new Camel.MimePart (); first.set_content ("first".data, "text/plain");
        first.set_filename ("first.txt"); multipart.add_part (first);
        var nested = new Camel.Multipart (); nested.set_mime_type ("multipart/mixed");
        var second = new Camel.MimePart (); second.set_content ("second".data, "text/plain");
        second.set_filename ("second.txt"); nested.add_part (second);
        var nested_part = new Camel.MimePart (); ((Camel.Medium) nested_part).set_content (nested);
        multipart.add_part (nested_part);
        var message = new Camel.MimeMessage (); ((Camel.Medium) message).set_content (multipart);
        int current = 0;
        var found = CamelMailEngine.attachment_content_at (message, 2, ref current);
        assert (found != null); assert (current == 2);
        var output = new MemoryOutputStream.resizable ();
        found.decode_to_output_stream_sync (output); output.close ();
        var bytes = output.steal_as_bytes (); unowned uint8[] data = bytes.get_data ();
        assert (data.length == 6);
        assert (data[0] == 's' && data[5] == 'd');
    } catch (Error error) {
        GLib.error ("Remote attachment addressing test failed: %s", error.message);
    }
}

private void test_received_inline_content_id () {
    string root = Path.build_filename (Environment.get_tmp_dir (),
        "mailficient-inline-part-%s".printf (Uuid.string_random ()));
    string received = Path.build_filename (root, "received");
    assert (DirUtils.create_with_parents (root, 0700) == 0);
    try {
        var part = new Camel.MimePart ();
        uint8[] png_header = { 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a };
        part.set_content (png_header, "image/png");
        var saved = new ReceivedAttachmentStore (received).save (part.get_content (), "logo.png",
            "image/png", "mailbox:43", 1, null, "<logo@example.net>");
        assert (saved != null); assert (saved.content_id == "<logo@example.net>");
        assert (saved.content_type == "image/png"); assert (saved.size == png_header.length);
        assert (FileUtils.test (saved.path, FileTest.IS_REGULAR));
    } catch (Error error) { GLib.error ("Inline MIME part test failed: %s", error.message); }
}

private async void exercise_mime_build (CamelMailEngine engine, AccountSettings account, string attachment_path) throws Error {
    var draft = new Draft (account.id);
    draft.to = "Maya Chen <maya@example.net>";
    draft.cc = "Noah <noah@example.org>";
    draft.bcc = "Private <private@example.com>";
    draft.subject = "MIME boundary test"; draft.body_text = "Hello from Mailficient";
    draft.in_reply_to = "<parent@example.net>"; draft.references = "<root@example.net> <parent@example.net>";
    draft.add_attachment (new Attachment ("binary", attachment_path, "payload.bin", 5, "application/octet-stream"));
    var message = yield engine.build_mime_message (draft, account);
    assert (message.get_header ("Bcc") == null);
    assert (message.get_header ("In-Reply-To") == draft.in_reply_to);
    assert (message.get_header ("References") == draft.references);
    assert (message.get_recipients (Camel.RECIPIENT_TYPE_TO).length () == 1);
    assert (message.get_recipients (Camel.RECIPIENT_TYPE_CC).length () == 1);
    var multipart = ((Camel.Medium) message).get_content () as Camel.Multipart;
    assert (multipart != null); assert (multipart.get_number () == 2);
    var attachment_part = multipart.get_part (1);
    assert (attachment_part != null); assert (attachment_part.get_filename () == "payload.bin");
    assert (attachment_part.get_encoding () == Camel.TransferEncoding.ENCODING_BASE64);
    var decoded = new MemoryOutputStream.resizable ();
    attachment_part.get_content ().decode_to_output_stream_sync (decoded); decoded.close ();
    var bytes = decoded.steal_as_bytes (); unowned uint8[] actual = bytes.get_data ();
    uint8[] expected = { 0x00, 0x41, 0xff, 0x0a, 0x42 };
    assert (actual.length == expected.length);
    for (int index = 0; index < expected.length; index++) assert (actual[index] == expected[index]);
}

private void test_mime_privacy_and_binary_attachment () {
    string root = Path.build_filename (Environment.get_tmp_dir (), "mailficient-mime-%s".printf (Uuid.string_random ()));
    assert (DirUtils.create_with_parents (root, 0700) == 0);
    string path = Path.build_filename (root, "payload.bin");
    try {
        var output = File.new_for_path (path).replace (null, false, FileCreateFlags.PRIVATE);
        uint8[] payload = { 0x00, 0x41, 0xff, 0x0a, 0x42 }; size_t written;
        output.write_all (payload, out written); output.close (); assert (written == payload.length);
        var engine = new CamelMailEngine (new EmptyCredentialStore (), Path.build_filename (root, "data"),
            Path.build_filename (root, "cache"), Path.build_filename (root, "received"));
        var account = AccountSettings.for_email ("Alex", "alex@example.net"); account.id = "mime-account";
        account.incoming_host = "imap.example.net"; account.outgoing_host = "smtp.example.net";
        Error? failure = null; var loop = new MainLoop ();
        exercise_mime_build.begin (engine, account, path, (object, result) => {
            try { exercise_mime_build.end (result); } catch (Error error) { failure = error; }
            loop.quit ();
        });
        loop.run (); assert (failure == null);
    } catch (Error error) { GLib.error ("MIME boundary test failed: %s", error.message); }
}

private async void exercise_mime_attachment_aggregate_limit (CamelMailEngine engine,
                                                               AccountSettings account) throws Error {
    var draft = new Draft (account.id);
    draft.to = "Maya <maya@example.net>";
    draft.subject = "Oversized aggregate";
    draft.body_text = "This message must be rejected before any attachment is read.";
    for (int index = 0; index < 5; index++) {
        draft.add_attachment (new Attachment ("aggregate-%d".printf (index),
            "/path-that-must-not-be-read/%d.bin".printf (index), "part-%d.bin".printf (index),
            AttachmentService.MAX_ATTACHMENT_SIZE, "application/octet-stream"));
    }
    yield engine.build_mime_message (draft, account);
}

private void test_mime_attachment_aggregate_limit () {
    string root = Path.build_filename (Environment.get_tmp_dir (),
        "mailficient-mime-limit-%s".printf (Uuid.string_random ()));
    assert (DirUtils.create_with_parents (root, 0700) == 0);
    var engine = new CamelMailEngine (new EmptyCredentialStore (), Path.build_filename (root, "data"),
        Path.build_filename (root, "cache"), Path.build_filename (root, "received"));
    var account = AccountSettings.for_email ("Alex", "alex@example.net");
    account.id = "mime-limit-account";
    Error? failure = null;
    var loop = new MainLoop ();
    exercise_mime_attachment_aggregate_limit.begin (engine, account, (object, result) => {
        try { exercise_mime_attachment_aggregate_limit.end (result); }
        catch (Error error) { failure = error; }
        loop.quit ();
    });
    loop.run ();
    assert (failure is MailError.ATTACHMENT);
    assert (failure.message.contains ("100 MB"));
}

private async void exercise_missing_mime_attachment (CamelMailEngine engine,
                                                      AccountSettings account) throws Error {
    var draft = new Draft (account.id);
    draft.to = "Maya <maya@example.net>"; draft.subject = "Missing attachment";
    draft.body_text = "Do not enter SMTP.";
    draft.add_attachment (new Attachment ("missing", "/definitely-not-present/mailficient.bin",
        "mailficient.bin", 12, "application/octet-stream"));
    yield engine.build_mime_message (draft, account);
}

private void test_missing_mime_attachment_is_local_failure () {
    string root = Path.build_filename (Environment.get_tmp_dir (),
        "mailficient-missing-mime-%s".printf (Uuid.string_random ()));
    assert (DirUtils.create_with_parents (root, 0700) == 0);
    var engine = new CamelMailEngine (new EmptyCredentialStore (), Path.build_filename (root, "data"),
        Path.build_filename (root, "cache"), Path.build_filename (root, "received"));
    var account = AccountSettings.for_email ("Alex", "alex@example.net");
    account.id = "missing-mime-account";
    Error? failure = null; var loop = new MainLoop ();
    exercise_missing_mime_attachment.begin (engine, account, (object, result) => {
        try { exercise_missing_mime_attachment.end (result); }
        catch (Error error) { failure = error; }
        loop.quit ();
    });
    loop.run ();
    assert (failure is MailError.ATTACHMENT);
    assert (failure.message.contains ("could not be read"));
}

private async void exercise_rich_mime_build (CamelMailEngine engine, AccountSettings account) throws Error {
    var draft = new Draft (account.id);
    draft.to = "Maya <maya@example.net>"; draft.subject = "Rich message";
    draft.body_text = "Hello from Mailficient";
    draft.body_html = "<div><strong>Hello</strong> from Mailficient</div>";
    var message = yield engine.build_mime_message (draft, account);
    var alternative = ((Camel.Medium) message).get_content () as Camel.Multipart;
    assert (alternative != null); assert (alternative.get_number () == 2);
    assert (alternative.get_mime_type () == "multipart/alternative");
    assert (alternative.get_part (0).get_content_type ().simple () == "text/plain");
    assert (alternative.get_part (1).get_content_type ().simple () == "text/html");
}

private void test_rich_multipart_alternative () {
    string root = Path.build_filename (Environment.get_tmp_dir (), "mailficient-rich-mime-%s".printf (Uuid.string_random ()));
    assert (DirUtils.create_with_parents (root, 0700) == 0);
    var engine = new CamelMailEngine (new EmptyCredentialStore (), Path.build_filename (root, "data"),
        Path.build_filename (root, "cache"), Path.build_filename (root, "received"));
    var account = AccountSettings.for_email ("Alex", "alex@example.net"); account.id = "rich-account";
    Error? failure = null; var loop = new MainLoop ();
    exercise_rich_mime_build.begin (engine, account, (object, result) => {
        try { exercise_rich_mime_build.end (result); } catch (Error error) { failure = error; }
        loop.quit ();
    });
    loop.run (); assert (failure == null);
}

private void test_junk_state_flags () {
    try {
        assert (CamelMailEngine.flags_for_state_field (MessageStateField.JUNK) == Camel.MessageFlags.JUNK);
        assert (CamelMailEngine.flags_for_state_field (MessageStateField.NOT_JUNK) == Camel.MessageFlags.NOTJUNK);
    } catch (Error error) { GLib.error ("junk flag mapping test failed: %s", error.message); }
}

private async void exercise_openpgp_round_trip () throws Error {
    string root = DirUtils.make_tmp ("mailficient-openpgp-XXXXXX");
    string keyring = Path.build_filename (root, "gnupg");
    assert (DirUtils.create_with_parents (keyring, 0700) == 0);
    string? previous_home = Environment.get_variable ("GNUPGHOME");
    Environment.set_variable ("GNUPGHOME", keyring, true);
    try {
        string standard_output; string standard_error; int exit_status;
        string[] command = { "gpg", "--batch", "--passphrase", "", "--quick-generate-key",
            "Mailficient Crypto Test <crypto-test@example.test>", "future-default", "default", "0" };
        Process.spawn_sync (null, command, null, SpawnFlags.SEARCH_PATH, null,
            out standard_output, out standard_error, out exit_status);
        if (!Process.if_exited (exit_status) || Process.exit_status (exit_status) != 0)
            throw new MailError.SEND_FAILED ("Could not create the isolated OpenPGP test key: " + standard_error);
        var engine = new CamelMailEngine (new EmptyCredentialStore (),
            Path.build_filename (root, "data"), Path.build_filename (root, "cache"),
            Path.build_filename (root, "received"));
        var account = AccountSettings.for_email ("Crypto Test", "crypto-test@example.test");
        var draft = new Draft (account.id); draft.to = "crypto-test@example.test";
        draft.subject = "Encrypted test"; draft.body_text = "signed and encrypted payload";
        draft.security_protocol = MessageSecurityProtocol.OPENPGP;
        draft.sign_message = true; draft.encrypt_message = true;
        var encrypted = yield engine.build_mime_message (draft, account);
        string encrypted_type = encrypted.get_content_type ().format ().down ();
        assert (encrypted_type.contains ("multipart/encrypted"));
        assert (encrypted_type.contains ("pgp-encrypted"));
        var context = new Camel.GpgContext (null);
        var clear = new Camel.MimePart ();
        yield context.decrypt (encrypted, clear, Priority.DEFAULT, null);
        string clear_type = clear.get_content_type ().format ().down ();
        assert (clear_type.contains ("multipart/signed"));
        assert (clear_type.contains ("pgp-signature"));
        var validity = yield context.verify (clear, Priority.DEFAULT, null);
        assert (validity.get_valid ());
    } finally {
        if (previous_home == null) Environment.unset_variable ("GNUPGHOME");
        else Environment.set_variable ("GNUPGHOME", previous_home, true);
    }
}

private void test_openpgp_round_trip () {
    var loop = new MainLoop (); Error? failure = null;
    exercise_openpgp_round_trip.begin ((object, result) => {
        try { exercise_openpgp_round_trip.end (result); }
        catch (Error error) { failure = error; }
        loop.quit ();
    });
    loop.run ();
    if (failure != null) GLib.error ("OpenPGP round-trip test failed: %s", failure.message);
}

private async void exercise_live_goa_connection () throws Error {
    var online_accounts = new GnomeOnlineAccountService ();
    var available = yield online_accounts.list_mail_accounts ();
    string? requested_provider = Environment.get_variable ("MAILFICIENT_TEST_GOA_PROVIDER");
    OnlineMailAccount? selected = null;
    foreach (var candidate in available) {
        if (requested_provider == null || requested_provider == "" ||
            candidate.provider_name.down ().contains (requested_provider.down ())) {
            selected = candidate;
            break;
        }
    }
    if (selected == null) {
        string provider = requested_provider == null || requested_provider == "" ? "" :
            " for provider " + requested_provider;
        throw new MailError.INVALID_ACCOUNT (
            "No mail-enabled GNOME Online Account is available%s".printf (provider));
    }
    var account = selected.to_settings ();
    account.id = "live-goa-connection-test";
    string root = DirUtils.make_tmp ("mailficient-live-goa-XXXXXX");
    var engine = new CamelMailEngine (new EmptyCredentialStore (),
        Path.build_filename (root, "data"), Path.build_filename (root, "cache"),
        Path.build_filename (root, "received"), online_accounts);
    var cancellable = new Cancellable ();
    uint timeout_id = Timeout.add_seconds (30, () => {
        cancellable.cancel ();
        return Source.REMOVE;
    });
    try {
        yield engine.connect_account (account, cancellable);
        yield engine.disconnect_account (account.id, cancellable);
    } catch (Error error) {
        // Do not expose the account address in optional integration-test logs.
        throw new MailError.CONNECTION (error.message.replace (account.email, "[account]"));
    } finally {
        if (timeout_id != 0) Source.remove (timeout_id);
    }
}

private void test_live_goa_connection () {
    Error? failure = null;
    var loop = new MainLoop ();
    exercise_live_goa_connection.begin ((object, result) => {
        try { exercise_live_goa_connection.end (result); }
        catch (Error error) { failure = error; }
        loop.quit ();
    });
    loop.run ();
    if (failure != null)
        GLib.error ("Live GOA mail connection failed: %s", failure.message);
}
}

int main (string[] args) {
    // Keep Camel tests independent of desktop portals and distribution proxy
    // helpers. IMAP and SMTP connect directly; GOA token discovery still uses
    // the session bus during the optional live test.
    bool live_goa = Environment.get_variable ("MAILFICIENT_TEST_LIVE_GOA") == "1";
    Environment.set_variable ("GIO_USE_PROXY_RESOLVER", "dummy", true);
    Environment.set_variable ("GIO_USE_NETWORK_MONITOR", "netlink", true);
    Test.init (ref args);
    if (live_goa)
        Log.set_always_fatal (LogLevelFlags.LEVEL_ERROR | LogLevelFlags.LEVEL_CRITICAL);
    Test.add_func ("/camel/failed-connection-can-retry", Mailficient.test_failed_connection_can_retry);
    Test.add_func ("/camel/concurrent-connections-are-serialized", Mailficient.test_concurrent_connections_are_serialized);
    Test.add_func ("/camel/error-classification", Mailficient.test_error_classification);
    Test.add_func ("/camel/certificate-failure-detail", Mailficient.test_certificate_failure_detail);
    Test.add_func ("/camel/authentication-mechanism", Mailficient.test_authentication_mechanism);
    Test.add_func ("/camel/oauth-token-bridge", Mailficient.test_oauth_token_bridge);
    Test.add_func ("/camel/idle-configuration-and-change-filter",
        Mailficient.test_idle_configuration_and_change_filter);
    Test.add_func ("/camel/folder-role-type-mask", Mailficient.test_folder_role_type_mask);
    Test.add_func ("/camel/folder-role-name-fallback", Mailficient.test_folder_role_name_fallback);
    Test.add_func ("/camel/destination-uid-recovery", Mailficient.test_destination_uid_recovery);
    Test.add_func ("/camel/failed-attachment-decode-is-atomic", Mailficient.test_failed_attachment_decode_is_atomic);
    Test.add_func ("/camel/misreported-attachment-is-bounded", Mailficient.test_misreported_attachment_is_bounded);
    Test.add_func ("/camel/sync-memory-bounds", Mailficient.test_sync_memory_bounds);
    Test.add_func ("/camel/inbox-prefetch-is-ordered-bounded-and-unique",
        Mailficient.test_inbox_prefetch_is_ordered_bounded_and_unique);
    Test.add_func ("/camel/uid-traversal-uses-elapsed-time-slice",
        Mailficient.test_uid_traversal_uses_elapsed_time_slice);
    Test.add_func ("/camel/cache-namespace-tracks-eds-branch",
        Mailficient.test_cache_namespace_tracks_eds_branch);
    Test.add_func ("/camel/zero-byte-cache-repair-is-narrow",
        Mailficient.test_zero_byte_cache_repair_is_narrow);
    Test.add_func ("/camel/sync-result-can-forget-vanished-uid",
        Mailficient.test_sync_result_can_forget_vanished_uid);
    Test.add_func ("/camel/sync-session-message-limit-preserves-inventory",
        Mailficient.test_sync_session_message_limit_preserves_inventory);
    Test.add_func ("/camel/top-level-html-body", Mailficient.test_top_level_html_body);
    Test.add_func ("/camel/unnamed-inline-calendar-is-extracted",
        Mailficient.test_unnamed_inline_calendar_is_extracted);
    Test.add_func ("/camel/html-only-remote-draft-plain-fidelity",
        Mailficient.test_html_only_remote_draft_plain_fidelity);
    Test.add_func ("/camel/managed-remote-draft-identity-without-message-id",
        Mailficient.test_managed_remote_draft_identity_without_message_id);
    Test.add_func ("/camel/malformed-text-charset-falls-back-safely", Mailficient.test_malformed_text_charset_falls_back_safely);
    Test.add_func ("/camel/text-charsets-are-converted-to-utf8",
        Mailficient.test_text_charsets_are_converted_to_utf8);
    Test.add_func ("/camel/quoted-printable-charset-decoded-once",
        Mailficient.test_quoted_printable_charset_is_decoded_once);
    Test.add_func ("/camel/sync-cooperatively-yields", Mailficient.test_sync_cooperatively_yields);
    Test.add_func ("/camel/cooperative-yield-honors-cancellation",
        Mailficient.test_cooperative_yield_honors_cancellation);
    Test.add_func ("/camel/remote-attachment-part-addressing", Mailficient.test_remote_attachment_part_addressing);
    Test.add_func ("/camel/received-inline-content-id", Mailficient.test_received_inline_content_id);
    Test.add_func ("/camel/mime-privacy-and-binary-attachment", Mailficient.test_mime_privacy_and_binary_attachment);
    Test.add_func ("/camel/mime-attachment-aggregate-limit", Mailficient.test_mime_attachment_aggregate_limit);
    Test.add_func ("/camel/missing-mime-attachment-is-local-failure", Mailficient.test_missing_mime_attachment_is_local_failure);
    Test.add_func ("/camel/rich-multipart-alternative", Mailficient.test_rich_multipart_alternative);
    Test.add_func ("/camel/openpgp-sign-encrypt-round-trip", Mailficient.test_openpgp_round_trip);
    Test.add_func ("/camel/junk-state-flags", Mailficient.test_junk_state_flags);
    if (live_goa)
        Test.add_func ("/camel/integration/live-goa-connection", Mailficient.test_live_goa_connection);
    return Test.run ();
}
