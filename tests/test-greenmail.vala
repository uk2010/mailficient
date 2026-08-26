using GLib;

namespace Mailficient {
private const string GREENMAIL_ACCOUNT_ID = "greenmail-e2e";
private const string GREENMAIL_EXTERNAL_ACCOUNT_ID = "greenmail-e2e-external";
private const string GREENMAIL_ADDRESS = "qa@example.com";
private const string GREENMAIL_PASSWORD = "mailficient-e2e";

private class GreenMailCredentialStore : Object, CredentialStore {
    private string fixture_account_id;

    public GreenMailCredentialStore (string fixture_account_id = GREENMAIL_ACCOUNT_ID) {
        this.fixture_account_id = fixture_account_id;
    }

    public async void store_password (string account_id, string protocol, string password,
                                      Cancellable? cancellable = null) throws Error {
        throw new IOError.NOT_SUPPORTED ("The isolated provider test never persists credentials");
    }

    public async string? lookup_password (string account_id, string protocol,
                                          Cancellable? cancellable = null) throws Error {
        if (cancellable != null) cancellable.set_error_if_cancelled ();
        if (account_id != fixture_account_id ||
            (protocol != "imap" && protocol != "smtp")) return null;
        return GREENMAIL_PASSWORD;
    }

    public async void clear_account (string account_id,
                                     Cancellable? cancellable = null) throws Error { }
}

// GreenMail's disposable TLS certificate and authentication advertisement are
// intentionally unlike a public provider. This session exists only in this
// test executable: it trusts that exact certificate on the exact loopback
// fixture ports. GreenMail's IMAP fixture accepts the protocol LOGIN command
// but advertises only XOAUTH2, so the seam clears PLAIN for that exact service;
// SMTP keeps production's TLS-protected PLAIN. No runtime flag can enable it.
private class GreenMailSession : PersonalCamelSession {
    private string fixture_account_id;
    private uint imaps_port;
    private uint smtps_port;

    public GreenMailSession (string data_dir, string cache_dir,
                             uint imaps_port, uint smtps_port,
                             string fixture_account_id = GREENMAIL_ACCOUNT_ID) {
        base (data_dir, cache_dir);
        this.fixture_account_id = fixture_account_id;
        this.imaps_port = imaps_port;
        this.smtps_port = smtps_port;
    }

    public override bool authenticate_sync (Camel.Service service, string? mechanism,
                                             Cancellable? cancellable = null) throws Error {
        string? effective = mechanism;
        if (is_exact_fixture_service (service) && mechanism == "PLAIN" &&
            service.get_uid () == fixture_account_id + "-imap") {
            var network = service.ref_settings () as Camel.NetworkSettings;
            if (network != null) network.set_auth_mechanism (null);
            // A null mechanism lets IMAPX use the protocol LOGIN command.
            effective = null;
        }
        return base.authenticate_sync (service, effective, cancellable);
    }

    public override Camel.CertTrust trust_prompt (Camel.Service service,
                                                   TlsCertificate certificate,
                                                   TlsCertificateFlags errors) {
        string subject = certificate.get_subject_name () ?? "";
        if (is_exact_fixture_service (service) &&
            subject.contains ("GreenMail selfsigned Test Certificate"))
            return Camel.CertTrust.TEMPORARY;
        return base.trust_prompt (service, certificate, errors);
    }

    private bool is_exact_fixture_service (Camel.Service service) {
        var network = service.ref_settings () as Camel.NetworkSettings;
        if (network == null || network.get_host () != "127.0.0.1") return false;
        string uid = service.get_uid ();
        uint port = network.get_port ();
        return (uid == fixture_account_id + "-imap" && port == imaps_port) ||
            (uid == fixture_account_id + "-smtp" && port == smtps_port);
    }
}

private class CapturedSync : Object {
    public MailSyncResult? snapshot;
    public Gee.ArrayList<Message> messages = new Gee.ArrayList<Message> ();
    public Gee.ArrayList<RemoteDraftSnapshot> remote_drafts =
        new Gee.ArrayList<RemoteDraftSnapshot> ();

    public void collect (MailSyncResult batch) {
        foreach (var message in batch.messages) messages.add (message);
        foreach (var draft in batch.remote_drafts) remote_drafts.add (draft);
    }

    public Mailbox? mailbox_for_role (MailboxRole role) {
        if (snapshot == null) return null;
        foreach (var mailbox in snapshot.mailboxes)
            if (mailbox.role == role) return mailbox;
        return null;
    }

    public Message? message_for_subject_and_role (string subject, MailboxRole role) {
        var mailbox = mailbox_for_role (role);
        if (mailbox == null) return null;
        foreach (var message in messages)
            if (message.mailbox_id == mailbox.id && message.subject == subject) return message;
        return null;
    }
}

private async void pause_milliseconds (uint milliseconds) {
    Timeout.add (milliseconds, () => {
        pause_milliseconds.callback ();
        return Source.REMOVE;
    });
    yield;
}

private async CapturedSync capture_sync (CamelMailEngine engine, string account_id,
                                         Gee.Set<string>? cached_ids = null,
                                         Cancellable? cancellable = null) throws Error {
    var capture = new CapturedSync ();
    ulong handler = engine.sync_batch_ready.connect ((batch) => {
        if (batch.account_id == account_id) capture.collect (batch);
    });
    try {
        capture.snapshot = yield engine.synchronize (account_id, cached_ids, cancellable);
        if (capture.snapshot != null) capture.collect (capture.snapshot);
        return capture;
    } finally {
        engine.disconnect (handler);
    }
}

private uint fixture_port (string variable) throws MailError {
    string? value = Environment.get_variable (variable);
    uint64 parsed = 0;
    if (value == null || !uint64.try_parse (value, out parsed) || parsed == 0 || parsed > 65535)
        throw new MailError.INVALID_ACCOUNT ("The GreenMail harness did not provide a valid loopback port");
    return (uint) parsed;
}

private AccountSettings greenmail_account (string account_id, uint imaps_port,
                                            uint smtps_port) {
    var account = AccountSettings.for_email ("Mailficient QA", GREENMAIL_ADDRESS);
    account.id = account_id;
    account.incoming_host = "127.0.0.1";
    account.incoming_port = imaps_port;
    account.incoming_encryption = EncryptionMode.TLS;
    account.incoming_username = GREENMAIL_ADDRESS;
    account.outgoing_host = "127.0.0.1";
    account.outgoing_port = smtps_port;
    account.outgoing_encryption = EncryptionMode.TLS;
    account.outgoing_username = GREENMAIL_ADDRESS;
    account.authentication = AuthenticationMode.PASSWORD;
    return account;
}

private async void exercise_greenmail_end_to_end () throws Error {
    uint imaps_port = fixture_port ("MAILFICIENT_TEST_GREENMAIL_IMAPS_PORT");
    uint smtps_port = fixture_port ("MAILFICIENT_TEST_GREENMAIL_SMTPS_PORT");
    string root = DirUtils.make_tmp ("mailficient-greenmail-XXXXXX");
    string data_dir = Path.build_filename (root, "camel-data");
    string cache_dir = Path.build_filename (root, "camel-cache");
    string received_dir = Path.build_filename (root, "received");
    var engine = new CamelMailEngine (new GreenMailCredentialStore (), data_dir,
        cache_dir, received_dir);
    engine.replace_session_for_testing (
        new GreenMailSession (data_dir, cache_dir, imaps_port, smtps_port));

    var account = greenmail_account (GREENMAIL_ACCOUNT_ID, imaps_port, smtps_port);

    var cancellable = new Cancellable ();
    uint timeout_source = Timeout.add_seconds (60, () => {
        cancellable.cancel ();
        return Source.REMOVE;
    });
    bool connected = false;
    CamelMailEngine? external_engine = null;
    bool external_connected = false;
    try {
        Test.message ("connecting to the isolated IMAPS service");
        yield engine.connect_incoming_account (account, cancellable);
        Test.message ("connecting to the isolated SMTPS service");
        yield engine.connect_account (account, cancellable);
        connected = true;
        Test.message ("creating and renaming provider folders");
        var initial_folders = yield capture_sync (engine, account.id, null, cancellable);
        if (initial_folders.mailbox_for_role (MailboxRole.DRAFTS) == null)
            yield engine.create_folder (account.id, "", "Drafts", cancellable);
        if (initial_folders.mailbox_for_role (MailboxRole.SENT) == null)
            yield engine.create_folder (account.id, "", "Sent", cancellable);
        if (initial_folders.mailbox_for_role (MailboxRole.ARCHIVE) == null)
            yield engine.create_folder (account.id, "", "Archive", cancellable);
        string qualification = "Qualification " + Uuid.string_random ();
        string qualification_complete = qualification + " Complete";
        yield engine.create_folder (account.id, "", qualification, cancellable);
        yield engine.rename_folder (account.id, qualification, qualification,
            qualification_complete, cancellable);
        yield engine.delete_folder (account.id, qualification_complete, cancellable);

        string attachment_path = Path.build_filename (root, "provider-attachment.txt");
        string attachment_payload = "GreenMail attachment round-trip " + Uuid.string_random ();
        FileUtils.set_contents (attachment_path, attachment_payload);
        var attachment = new Attachment (Uuid.string_random (), attachment_path,
            "provider-attachment.txt", attachment_payload.length, "text/plain");

        var remote_draft = new Draft (account.id);
        remote_draft.to = GREENMAIL_ADDRESS;
        remote_draft.cc = "Copy <" + GREENMAIL_ADDRESS + ">";
        remote_draft.bcc = "Hidden <" + GREENMAIL_ADDRESS + ">";
        remote_draft.subject = "GreenMail synchronized draft";
        remote_draft.body_text = "Editable provider draft";
        remote_draft.attachments.add (attachment);
        Test.message ("saving and identity-checking a remote draft");
        var draft_location = yield engine.save_remote_draft (remote_draft, cancellable);
        assert (draft_location != null);

        // A wrong identity means the exact cleanup target is already absent:
        // complete it without deleting the different UID occupant. The
        // idempotent save below proves that occupant remained untouched.
        assert (yield engine.delete_remote_draft (new PendingDraftDeletion (0,
            account.id, draft_location.mailbox_name, draft_location.remote_uid,
            "not-the-managed-message-id@example.test"), cancellable));
        var idempotent_location = yield engine.save_remote_draft (remote_draft, cancellable);
        assert (idempotent_location != null);
        assert (idempotent_location.mailbox_name == draft_location.mailbox_name);
        assert (idempotent_location.remote_uid == draft_location.remote_uid);

        Test.message ("synchronizing the provider draft");
        var first = yield capture_sync (engine, account.id, null, cancellable);
        assert (first.mailbox_for_role (MailboxRole.DRAFTS) != null);
        assert (first.mailbox_for_role (MailboxRole.SENT) != null);
        assert (first.mailbox_for_role (MailboxRole.ARCHIVE) != null);
        bool imported_managed_draft = false;
        foreach (var snapshot in first.remote_drafts) {
            if (snapshot.draft.id == remote_draft.id && snapshot.managed_by_mailficient &&
                snapshot.draft.bcc.contains (GREENMAIL_ADDRESS) &&
                snapshot.draft.attachments.size == 1)
                imported_managed_draft = true;
        }
        assert (imported_managed_draft);

        var cached_ids = new Gee.HashSet<string> ();
        foreach (var message in first.messages) cached_ids.add (message.id);

        int live_arrivals = 0;
        int live_unavailable = 0;
        ulong arrival_handler = engine.live_mail_changed.connect ((id) => {
            if (id == account.id) live_arrivals++;
        });
        ulong unavailable_handler = engine.live_mail_unavailable.connect ((id) => {
            if (id == account.id) live_unavailable++;
        });
        string sent_subject = "GreenMail delivery " + Uuid.string_random ();
        var outbound = new Draft (account.id);
        outbound.to = GREENMAIL_ADDRESS;
        outbound.subject = sent_subject;
        outbound.body_text = "SMTP, IMAP IDLE, and folder filing qualification";
        outbound.attachments.add (attachment);
        Test.message ("sending through SMTPS and filing the provider Sent copy");
        var send_result = yield engine.send (outbound, cancellable);
        assert (send_result.filed_to_sent);

        // A self-send on the watched engine necessarily interrupts its Inbox
        // IDLE command while that same IMAP store files the Sent copy. Deliver
        // a second message from an independent Camel session after the watched
        // engine is quiescent. This models another client/provider delivery and
        // proves that the production Inbox watch receives an unsolicited EXISTS.
        string external_root = Path.build_filename (root, "external-client");
        external_engine = new CamelMailEngine (
            new GreenMailCredentialStore (GREENMAIL_EXTERNAL_ACCOUNT_ID),
            Path.build_filename (external_root, "camel-data"),
            Path.build_filename (external_root, "camel-cache"),
            Path.build_filename (external_root, "received"));
        external_engine.replace_session_for_testing (new GreenMailSession (
            Path.build_filename (external_root, "camel-data"),
            Path.build_filename (external_root, "camel-cache"),
            imaps_port, smtps_port, GREENMAIL_EXTERNAL_ACCOUNT_ID));
        var external_account = greenmail_account (
            GREENMAIL_EXTERNAL_ACCOUNT_ID, imaps_port, smtps_port);
        yield external_engine.connect_account (external_account, cancellable);
        external_connected = true;

        // IMAPX deliberately waits two seconds after the last command before
        // issuing IDLE so it can coalesce follow-up work on the connection.
        yield pause_milliseconds (3000);
        int arrivals_before_external_delivery = live_arrivals;
        string external_subject = "GreenMail external arrival " + Uuid.string_random ();
        var external_message = new Draft (external_account.id);
        external_message.to = GREENMAIL_ADDRESS;
        external_message.subject = external_subject;
        external_message.body_text = "Independent-client IMAP IDLE qualification";
        Test.message ("delivering from an independent client and waiting for IMAP IDLE");
        var external_send_result = yield external_engine.send (external_message, cancellable);
        assert (external_send_result.filed_to_sent);
        for (int attempt = 0;
             attempt < 100 && live_arrivals == arrivals_before_external_delivery;
             attempt++)
            yield pause_milliseconds (100);
        assert (live_arrivals > arrivals_before_external_delivery);
        yield external_engine.disconnect_account (external_account.id, cancellable);
        external_connected = false;

        Test.message ("synchronizing Inbox and Sent attachment copies");
        var delivered = yield capture_sync (engine, account.id, cached_ids, cancellable);
        var inbox_message = delivered.message_for_subject_and_role (sent_subject, MailboxRole.INBOX);
        var sent_message = delivered.message_for_subject_and_role (sent_subject, MailboxRole.SENT);
        assert (inbox_message != null);
        assert (sent_message != null);
        assert (delivered.message_for_subject_and_role (
            external_subject, MailboxRole.INBOX) != null);
        assert (inbox_message.attachments.size == 1);
        assert (sent_message.attachments.size == 1);
        string received_payload;
        FileUtils.get_contents (inbox_message.attachments[0].path, out received_payload);
        assert (received_payload == attachment_payload);

        var inbox = delivered.mailbox_for_role (MailboxRole.INBOX);
        var archive = delivered.mailbox_for_role (MailboxRole.ARCHIVE);
        assert (inbox != null && archive != null);

        Test.message ("searching the provider Inbox with a bounded server expression");
        string search_expression = ServerSearchExpression.build (
            SearchQuery.parse ("subject:\"%s\"".printf (sent_subject)));
        assert (search_expression.has_prefix ("(match-all "));
        var remote_matches = yield engine.search_remote (inbox, search_expression, 10, cancellable);
        bool found_by_server = false;
        foreach (var candidate in remote_matches)
            if (candidate.subject == sent_subject) found_by_server = true;
        assert (found_by_server);
        assert (remote_matches.size <= 10);
        string missing_expression = ServerSearchExpression.build (SearchQuery.parse (
            "subject:\"mailficient-no-match-%s\"".printf (Uuid.string_random ())));
        var missing_matches = yield engine.search_remote (
            inbox, missing_expression, 10, cancellable);
        assert (missing_matches.size == 0);

        yield engine.set_message_state (account.id, inbox.remote_name,
            inbox_message.remote_uid, MessageStateField.READ, true, cancellable);
        yield engine.set_message_state (account.id, inbox.remote_name,
            inbox_message.remote_uid, MessageStateField.FLAGGED, true, cancellable);
        string? archive_uid = yield engine.transfer_message (account.id,
            inbox.remote_name, inbox_message.remote_uid, archive.remote_name, false, cancellable);
        assert (archive_uid != null && archive_uid != "");

        assert (yield engine.delete_remote_draft (new PendingDraftDeletion (0,
            account.id, draft_location.mailbox_name, draft_location.remote_uid,
            remote_draft.remote_message_id ()), cancellable));

        int unavailable_before_disconnect = live_unavailable;
        Test.message ("disconnecting and reconnecting the account");
        yield engine.disconnect_account (account.id, cancellable);
        connected = false;
        yield pause_milliseconds (250);
        // An intentional teardown detaches the watch before removing services.
        assert (live_unavailable == unavailable_before_disconnect);
        yield engine.connect_account (account, cancellable);
        connected = true;

        Test.message ("verifying the final provider state after reconnect");
        var after_reconnect = yield capture_sync (engine, account.id, null, cancellable);
        var archived = after_reconnect.message_for_subject_and_role (
            sent_subject, MailboxRole.ARCHIVE);
        assert (archived != null);
        assert (!archived.unread);
        assert (archived.flagged);
        foreach (var draft in after_reconnect.remote_drafts)
            assert (draft.draft.id != remote_draft.id);
        var drafts_mailbox = after_reconnect.mailbox_for_role (MailboxRole.DRAFTS);
        assert (drafts_mailbox != null);
        var remaining_draft_uids = after_reconnect.snapshot.remote_uids_for (drafts_mailbox.id);
        assert (remaining_draft_uids != null);
        assert (!remaining_draft_uids.contains (draft_location.remote_uid));

        engine.disconnect (arrival_handler);
        engine.disconnect (unavailable_handler);
    } finally {
        if (timeout_source != 0) Source.remove (timeout_source);
        if (external_connected && external_engine != null) {
            try { yield external_engine.disconnect_account (
                GREENMAIL_EXTERNAL_ACCOUNT_ID, null); }
            catch (Error ignored) { }
        }
        if (connected) {
            try { yield engine.disconnect_account (account.id, null); }
            catch (Error ignored) { }
        }
    }
}

private void test_greenmail_end_to_end () {
    Error? failure = null;
    var loop = new MainLoop ();
    exercise_greenmail_end_to_end.begin ((object, result) => {
        try { exercise_greenmail_end_to_end.end (result); }
        catch (Error error) { failure = error; }
        loop.quit ();
    });
    loop.run ();
    if (failure != null)
        GLib.error ("GreenMail provider qualification failed: %s", failure.message);
}

private void test_draft_uid_cap_converges () {
    const int draft_count = 501;
    var all_uids = new Gee.ArrayList<string> ();
    for (int index = 0; index < draft_count; index++)
        all_uids.add ((index + 1).to_string ());
    var tracker = new DraftRefreshTracker ();
    int passes = 0;
    int processed_total = 0;
    while (tracker.remaining_count ("draft-cap-account:drafts") > 0 || passes == 0) {
        var inventory = new MailSyncResult ("draft-cap-account");
        var drafts = new Mailbox ("draft-cap-account:drafts", "Drafts",
            "document-edit-symbolic", MailboxRole.DRAFTS, 0,
            "draft-cap-account", "Drafts");
        inventory.mailboxes.add (drafts);
        foreach (var uid in all_uids)
            inventory.record_remote_uid (drafts.id, uid);
        var candidates = tracker.plan (drafts.id, all_uids);
        int selected = CamelMailEngine.bounded_folder_download_count (candidates.size, 0);
        for (int index = 0; index < selected; index++) {
            tracker.complete (drafts.id, candidates[index]);
            processed_total++;
        }
        assert (inventory.remote_uids_for (drafts.id).size == draft_count);
        passes++;
        assert (passes <= 3);
    }
    assert (processed_total == draft_count);
    assert (passes == 3);
    assert (tracker.remaining_count ("draft-cap-account:drafts") == 0);

    // Completing a cycle allows the next periodic check to start a fresh one;
    // it does not leave a permanent "already refreshed" cache.
    assert (tracker.plan ("draft-cap-account:drafts", all_uids).size == draft_count);
}
}

int main (string[] args) {
    Environment.set_variable ("GIO_USE_PROXY_RESOLVER", "dummy", true);
    Environment.set_variable ("GIO_USE_NETWORK_MONITOR", "netlink", true);
    Test.init (ref args);
    Test.add_func ("/camel/draft-uid-cap-converges",
        Mailficient.test_draft_uid_cap_converges);
    if (Environment.get_variable ("MAILFICIENT_TEST_GREENMAIL") == "1") {
        Log.set_always_fatal (LogLevelFlags.LEVEL_ERROR | LogLevelFlags.LEVEL_CRITICAL);
        Test.add_func ("/camel/integration/greenmail-end-to-end",
            Mailficient.test_greenmail_end_to_end);
    }
    return Test.run ();
}
