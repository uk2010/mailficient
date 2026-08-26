namespace Mailficient {
public class ReceivedAttachmentService : Object {
    private const int64 MAX_USER_DOWNLOAD_BYTES = (int64) 2 * 1024 * 1024 * 1024;
    public const int64 MAX_CALENDAR_INVITATION_BYTES = 2 * 1024 * 1024;
    private CacheDatabase cache;
    private AttachmentService local_files;
    private MailEngine? engine;

    public ReceivedAttachmentService (CacheDatabase cache, AttachmentService local_files,
                                      MailEngine? engine) {
        this.cache = cache;
        this.local_files = local_files;
        this.engine = engine;
    }

    public async void save (Message message, Attachment attachment, File destination,
                            Cancellable? cancellable = null) throws Error {
        if (attachment.is_downloaded ()) {
            yield local_files.save_received (attachment, destination, cancellable);
            return;
        }
        if (engine == null || message.account_id == "" || message.remote_uid == "" ||
            attachment.remote_part_index <= 0)
            throw new MailError.ATTACHMENT (
                "This attachment cannot be downloaded because its server location is unavailable");
        string mailbox_name = cache.remote_mailbox_for_message (message.id);
        var account = cache.find_account (message.account_id);
        if (account == null)
            throw new MailError.ATTACHMENT ("The attachment's mail account is no longer configured");
        yield engine.connect_incoming_account (account, cancellable);
        yield engine.save_remote_attachment (message.account_id, mailbox_name,
            message.remote_uid, attachment.remote_part_index, destination,
            MAX_USER_DOWNLOAD_BYTES, cancellable);
    }

    public async Attachment copy_for_draft (Message message, Attachment attachment,
                                            Cancellable? cancellable = null) throws Error {
        if (attachment.is_downloaded ())
            return yield local_files.copy_received_for_draft (attachment, cancellable);
        if (attachment.size > AttachmentService.MAX_ATTACHMENT_SIZE)
            throw new MailError.ATTACHMENT (
                "The attachment is larger than the 25 MB outgoing attachment limit");
        if (engine == null || message.account_id == "" || message.remote_uid == "" ||
            attachment.remote_part_index <= 0)
            throw new MailError.ATTACHMENT (
                "This attachment cannot be forwarded because its server location is unavailable");

        string mailbox_name = cache.remote_mailbox_for_message (message.id);
        var account = cache.find_account (message.account_id);
        if (account == null)
            throw new MailError.ATTACHMENT ("The attachment's mail account is no longer configured");

        FileIOStream temporary_stream;
        var temporary = File.new_tmp ("mailficient-forward-XXXXXX", out temporary_stream);
        try {
            temporary_stream.close (cancellable);
            yield engine.connect_incoming_account (account, cancellable);
            yield engine.save_remote_attachment (message.account_id, mailbox_name,
                message.remote_uid, attachment.remote_part_index, temporary,
                AttachmentService.MAX_ATTACHMENT_SIZE, cancellable);
            var downloaded = new Attachment (attachment.id, temporary.get_path (),
                attachment.name, attachment.size, attachment.content_type,
                attachment.content_id, attachment.remote_part_index);
            return yield local_files.copy_received_for_draft (downloaded, cancellable);
        } finally {
            try {
                if (temporary.query_exists ()) temporary.delete (null);
            } catch (Error ignored) { }
        }
    }

    public async File stage_calendar_invitation (Message message, Attachment attachment,
                                                  Cancellable? cancellable = null) throws Error {
        if (!attachment.is_calendar_invitation ())
            throw new MailError.ATTACHMENT ("The selected attachment is not an iCalendar invitation");
        if (attachment.size > MAX_CALENDAR_INVITATION_BYTES)
            throw new MailError.ATTACHMENT ("The calendar invitation is larger than the 2 MB safety limit");

        string temporary_path = Path.build_filename (Environment.get_tmp_dir (),
            "mailficient-calendar-%s.ics".printf (Uuid.string_random ()));
        var temporary = File.new_for_path (temporary_path);
        try {
            if (attachment.is_downloaded ()) {
                var source = attachment.path.has_prefix ("resource://") ?
                    File.new_for_uri (attachment.path) : File.new_for_path (attachment.path);
                var info = yield source.query_info_async (
                    FileAttribute.STANDARD_TYPE + "," + FileAttribute.STANDARD_SIZE,
                    FileQueryInfoFlags.NOFOLLOW_SYMLINKS, Priority.DEFAULT, cancellable);
                if (info.get_file_type () != FileType.REGULAR)
                    throw new MailError.ATTACHMENT ("The calendar invitation is not a regular file");
                if (info.get_size () > MAX_CALENDAR_INVITATION_BYTES)
                    throw new MailError.ATTACHMENT ("The calendar invitation is larger than the 2 MB safety limit");
                yield source.copy_async (temporary, FileCopyFlags.NONE,
                    Priority.DEFAULT, cancellable, null);
            } else {
                if (engine == null || message.account_id == "" || message.remote_uid == "" ||
                    attachment.remote_part_index <= 0)
                    throw new MailError.ATTACHMENT (
                        "This calendar invitation cannot be downloaded because its server location is unavailable");
                string mailbox_name = cache.remote_mailbox_for_message (message.id);
                var account = cache.find_account (message.account_id);
                if (account == null)
                    throw new MailError.ATTACHMENT (
                        "The calendar invitation's mail account is no longer configured");
                yield engine.connect_incoming_account (account, cancellable);
                yield engine.save_remote_attachment (message.account_id, mailbox_name,
                    message.remote_uid, attachment.remote_part_index, temporary,
                    MAX_CALENDAR_INVITATION_BYTES, cancellable);
            }
            return temporary;
        } catch (Error error) {
            try {
                if (temporary.query_exists ()) temporary.delete (null);
            } catch (Error ignored) { }
            throw error;
        }
    }
}
}
