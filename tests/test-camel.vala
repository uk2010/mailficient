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
    int remaining = CamelMailEngine.MAX_MESSAGE_DOWNLOADS_PER_SYNC;
    int selected = 0;
    for (int folder = 0; folder < 100; folder++) {
        int count = CamelMailEngine.bounded_download_count (1000, remaining);
        selected += count;
        remaining -= count;
    }
    assert (selected == CamelMailEngine.MAX_MESSAGE_DOWNLOADS_PER_SYNC);
    assert (remaining == 0);
    assert (CamelMailEngine.bounded_download_count (1000, remaining) == 0);
    assert (CamelMailEngine.SYNC_BATCH_SIZE < CamelMailEngine.MAX_MESSAGE_DOWNLOADS_PER_SYNC);
    assert (CamelMailEngine.UID_SCAN_YIELD_INTERVAL > CamelMailEngine.SYNC_BATCH_SIZE);

    Error? failure = null;
    try {
        CamelMailEngine.decode_text (new MisreportedOversizedAttachmentData (), 32);
    } catch (Error error) { failure = error; }
    assert (failure is IOError.MESSAGE_TOO_LARGE);
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
        assert (content_type.param ("charset").ascii_casecmp ("UTF-8") == 0);

        content_type.set_param ("charset", "definitely-not-a-real-charset");
        assert (CamelMailEngine.decode_text (content) == source);
        assert (content_type.param ("charset").ascii_casecmp ("UTF-8") == 0);
    } catch (Error error) {
        GLib.error ("Malformed text charset fallback test failed: %s", error.message);
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
    assert (CamelMailEngine.authentication_mechanism (AuthenticationMode.PASSWORD) == null);
    assert (CamelMailEngine.authentication_mechanism (
        AuthenticationMode.GNOME_ONLINE_ACCOUNTS) == "XOAUTH2");
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
    Test.add_func ("/camel/folder-role-type-mask", Mailficient.test_folder_role_type_mask);
    Test.add_func ("/camel/folder-role-name-fallback", Mailficient.test_folder_role_name_fallback);
    Test.add_func ("/camel/destination-uid-recovery", Mailficient.test_destination_uid_recovery);
    Test.add_func ("/camel/failed-attachment-decode-is-atomic", Mailficient.test_failed_attachment_decode_is_atomic);
    Test.add_func ("/camel/misreported-attachment-is-bounded", Mailficient.test_misreported_attachment_is_bounded);
    Test.add_func ("/camel/sync-memory-bounds", Mailficient.test_sync_memory_bounds);
    Test.add_func ("/camel/top-level-html-body", Mailficient.test_top_level_html_body);
    Test.add_func ("/camel/malformed-text-charset-falls-back-safely", Mailficient.test_malformed_text_charset_falls_back_safely);
    Test.add_func ("/camel/sync-cooperatively-yields", Mailficient.test_sync_cooperatively_yields);
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
