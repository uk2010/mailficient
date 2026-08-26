namespace Mailficient {
public class DraftSyncService : Object {
    public const int64 UPLOAD_LEASE_SECONDS = 300;
    public signal void sync_warning (string account_id, string detail);
    private CacheDatabase cache;
    private MailEngine engine;
    private AttachmentService? attachments;

    public DraftSyncService (CacheDatabase cache, MailEngine engine,
                             AttachmentService? attachments = null) {
        this.cache = cache; this.engine = engine; this.attachments = attachments;
    }

    public async void synchronize_account (string account_id,
                                           Cancellable? cancellable = null) throws Error {
        Error? first_error = null;
        foreach (var candidate in cache.list_pending_draft_uploads (account_id)) {
            if (cancellable != null) cancellable.set_error_if_cancelled ();
            string owner = Uuid.string_random ();
            int64 lease_until = new DateTime.now_utc ().to_unix () + UPLOAD_LEASE_SECONDS;
            if (!cache.claim_draft_upload (candidate.id, owner, lease_until)) continue;
            try {
                // Reload after the claim so the MIME revision and its durable
                // idempotency key describe the exact version now owned.
                var claimed = cache.load_draft (candidate.id);
                if (claimed == null) {
                    cache.release_draft_upload (candidate.id, owner);
                    continue;
                }
                var location = yield engine.save_remote_draft (claimed, cancellable);
                if (location == null) {
                    cache.release_draft_upload (claimed.id, owner);
                    continue;
                }
                cache.record_remote_draft_uploaded (claimed.id, account_id,
                    claimed.revision, location, owner,
                    DraftFingerprint.calculate (claimed));
            } catch (Error error) {
                try { cache.release_draft_upload (candidate.id, owner); }
                catch (Error cleanup_error) {
                    warning ("Could not release remote draft claim: %s", cleanup_error.message);
                }
                if (first_error == null) first_error = error;
                sync_warning (account_id, error.message);
            }
        }

        foreach (var deletion in cache.list_pending_remote_draft_deletions (account_id)) {
            if (cancellable != null) cancellable.set_error_if_cancelled ();
            try {
                if (yield engine.delete_remote_draft (deletion, cancellable))
                    cache.complete_remote_draft_deletion (deletion.id);
            } catch (Error error) {
                if (first_error == null) first_error = error;
                sync_warning (account_id, error.message);
            }
        }
        if (first_error != null) throw first_error;
    }

    public async void import_remote_drafts (Gee.Iterable<RemoteDraftSnapshot> snapshots,
                                            Cancellable? cancellable = null) throws Error {
        Error? first_error = null;
        foreach (var snapshot in snapshots) {
            if (cancellable != null) cancellable.set_error_if_cancelled ();
            Draft? prior = null;
            try { prior = cache.load_draft (snapshot.draft.id); }
            catch (Error error) { if (first_error == null) first_error = error; continue; }
            var imported = copy_without_attachments (snapshot.draft);
            var private_copies = new Gee.ArrayList<Attachment> ();
            if (attachments != null) {
                int64 total = 0;
                foreach (var source in snapshot.draft.attachments) {
                    bool copied_safely = false;
                    if (source.is_downloaded () && source.size >= 0 &&
                        source.size <= AttachmentService.MAX_ATTACHMENT_SIZE &&
                        source.size <= AttachmentService.MAX_TOTAL_ATTACHMENT_SIZE - total) {
                        try {
                            var copied = yield attachments.copy_received_for_draft (source, cancellable);
                            var preserved = new Attachment (copied.id, copied.path, copied.name,
                                copied.size, copied.content_type, source.content_id,
                                source.remote_part_index);
                            private_copies.add (preserved); imported.attachments.add (preserved);
                            total += preserved.size; copied_safely = true;
                        } catch (Error error) {
                            sync_warning (snapshot.draft.account_id,
                                "A provider draft attachment could not be made editable: " + error.message);
                        }
                    }
                    if (!copied_safely) {
                        // Never make a provider draft appear complete after a
                        // bounded/failed attachment download. Empty path is a
                        // durable, visible placeholder; send validation blocks
                        // until the user removes it or a later import replaces it.
                        imported.attachments.add (new Attachment (source.id, "", source.name,
                            source.size, source.content_type, source.content_id,
                            source.remote_part_index));
                    }
                }
            } else {
                foreach (var source in snapshot.draft.attachments)
                    imported.attachments.add (new Attachment (source.id, "", source.name,
                        source.size, source.content_type, source.content_id,
                        source.remote_part_index));
            }
            try {
                bool stored = cache.import_remote_draft (snapshot, imported);
                if (!stored) {
                    remove_private_copies (private_copies);
                    continue;
                }
                if (prior != null && attachments != null)
                    remove_private_copies (prior.attachments);
            } catch (Error error) {
                remove_private_copies (private_copies);
                if (first_error == null) first_error = error;
                sync_warning (snapshot.draft.account_id, error.message);
            }
        }
        if (first_error != null) throw first_error;
    }

    public void reconcile_remote_deletions (MailSyncResult snapshot) throws Error {
        foreach (var removed in cache.reconcile_remote_draft_deletions (snapshot))
            remove_private_copies (removed.attachments);
    }

    private static Draft copy_without_attachments (Draft source) {
        var copy = new Draft (source.account_id, source.id);
        copy.to = source.to; copy.cc = source.cc; copy.bcc = source.bcc;
        copy.subject = source.subject; copy.body_text = source.body_text;
        copy.body_html = source.body_html; copy.body_format = source.body_format;
        copy.in_reply_to = source.in_reply_to; copy.references = source.references;
        copy.security_protocol = source.security_protocol; copy.sign_message = source.sign_message;
        copy.encrypt_message = source.encrypt_message; copy.security_identity = source.security_identity;
        copy.modified_at = source.modified_at; copy.revision = source.revision;
        copy.remote_mailbox = source.remote_mailbox; copy.remote_uid = source.remote_uid;
        copy.remote_revision = source.remote_revision;
        copy.remote_internet_message_id = source.remote_internet_message_id;
        copy.remote_content_fingerprint = source.remote_content_fingerprint;
        copy.remote_owned = source.remote_owned;
        return copy;
    }

    private void remove_private_copies (Gee.Iterable<Attachment> values) {
        if (attachments == null) return;
        foreach (var attachment in values) {
            try { attachments.remove_private_copy (attachment); }
            catch (Error error) {
                warning ("Could not remove superseded draft attachment: %s", error.message);
            }
        }
    }
}
}
