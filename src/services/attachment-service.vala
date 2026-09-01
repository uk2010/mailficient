namespace Mailficient {
public class AttachmentService : Object {
    public const int64 MAX_ATTACHMENT_SIZE = 25 * 1024 * 1024;
    public const int64 MAX_TOTAL_ATTACHMENT_SIZE = 100 * 1024 * 1024;
    public const int64 MAX_RECEIVED_ATTACHMENT_SIZE = 50 * 1024 * 1024;
    private string storage_directory;

    public AttachmentService (string storage_directory) throws MailError {
        this.storage_directory = storage_directory;
        if (DirUtils.create_with_parents (storage_directory, 0700) != 0)
            throw new MailError.STORAGE ("Could not create private attachment storage");
        if (FileUtils.chmod (storage_directory, 0700) != 0)
            throw new MailError.STORAGE ("Could not secure private attachment storage");
    }

    public async Attachment import_file (File source, Cancellable? cancellable = null) throws Error {
        var info = yield source.query_info_async (
            FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_SIZE + "," +
            FileAttribute.STANDARD_TYPE + "," + FileAttribute.STANDARD_CONTENT_TYPE,
            FileQueryInfoFlags.NOFOLLOW_SYMLINKS, Priority.DEFAULT, cancellable);
        if (info.get_file_type () != FileType.REGULAR)
            throw new MailError.ATTACHMENT ("Only regular files can be attached");
        int64 size = (int64) info.get_size ();
        if (size > MAX_ATTACHMENT_SIZE)
            throw new MailError.ATTACHMENT ("The attachment is larger than the 25 MB safety limit");
        string id = Uuid.string_random ();
        string name = AttachmentSafety.safe_filename (info.get_name ());
        var destination = File.new_for_path (Path.build_filename (storage_directory, id + "-" + name));
        try {
            yield source.copy_async (destination, FileCopyFlags.NOFOLLOW_SYMLINKS,
                Priority.DEFAULT, cancellable, null);
            if (cancellable != null) cancellable.set_error_if_cancelled ();
            var copied = yield destination.query_info_async (
                FileAttribute.STANDARD_TYPE + "," + FileAttribute.STANDARD_SIZE,
                FileQueryInfoFlags.NOFOLLOW_SYMLINKS, Priority.DEFAULT,
                cancellable);
            int64 copied_size = (int64) copied.get_size ();
            if (copied.get_file_type () != FileType.REGULAR ||
                copied_size != size || copied_size > MAX_ATTACHMENT_SIZE)
                throw new MailError.ATTACHMENT (
                    "The attachment changed while it was being copied");
            string? destination_path = destination.get_path ();
            if (destination_path == null || FileUtils.chmod (destination_path, 0600) != 0)
                throw new MailError.STORAGE ("Could not secure the private attachment copy");
        } catch (Error error) {
            try { if (destination.query_exists ()) destination.delete (); } catch (Error ignored) { }
            throw error;
        }
        return new Attachment (id, destination.get_path (), name, size,
            info.get_content_type () ?? "application/octet-stream");
    }

    public async Attachment copy_received_for_draft (Attachment attachment,
                                                      Cancellable? cancellable = null) throws Error {
        if (attachment.path == "")
            throw new MailError.ATTACHMENT ("The source attachment has not been downloaded");
        File source;
        if (attachment.path.has_prefix ("resource:///com/local/Mailficient/"))
            source = File.new_for_uri (attachment.path);
        else if (attachment.path.contains ("://"))
            throw new MailError.ATTACHMENT ("The source attachment location is not trusted");
        else
            source = File.new_for_path (attachment.path);
        return yield import_file (source, cancellable);
    }

    public void remove_private_copy (Attachment attachment) throws Error {
        // Provider drafts retain a visible, blocking placeholder when an
        // attachment could not be copied safely. Removing that placeholder has
        // no local file to delete.
        if (!attachment.is_downloaded ()) return;
        if (!is_private_path (attachment.path))
            throw new MailError.ATTACHMENT (
                "The attachment is outside Mailficient's private draft storage");
        var file = File.new_for_path (attachment.path);
        if (file.query_exists ()) file.delete ();
    }

    internal bool is_private_path (string path) {
        if (path == "" || path.contains ("://")) return false;
        string parent = Path.get_dirname (path);
        return File.new_for_path (parent).equal (File.new_for_path (storage_directory));
    }

    public void validate_draft_attachments (Draft draft) throws MailError {
        int64 total = 0;
        foreach (var attachment in draft.attachments) {
            if (!attachment.is_downloaded ())
                throw new MailError.ATTACHMENT (
                    "A provider draft attachment is not available locally. Remove it or reattach it before sending");
            if (!is_private_path (attachment.path))
                throw new MailError.ATTACHMENT (
                    "A draft attachment is outside Mailficient's private storage");
            try {
                var info = File.new_for_path (attachment.path).query_info (
                    FileAttribute.STANDARD_TYPE + "," + FileAttribute.STANDARD_SIZE,
                    FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
                if (info.get_file_type () != FileType.REGULAR)
                    throw new MailError.ATTACHMENT (
                        "A draft attachment is no longer a regular file");
                int64 actual_size = (int64) info.get_size ();
                if (actual_size != attachment.size)
                    throw new MailError.ATTACHMENT (
                        "A draft attachment changed after it was added");
                if (actual_size > MAX_ATTACHMENT_SIZE)
                    throw new MailError.ATTACHMENT (
                        "A draft attachment exceeds the 25 MB safety limit");
                if (actual_size > MAX_TOTAL_ATTACHMENT_SIZE - total)
                    throw new MailError.ATTACHMENT (
                        "The draft's attachments exceed the 100 MB preparation limit");
                total += actual_size;
            } catch (MailError error) {
                throw error;
            } catch (Error error) {
                throw new MailError.ATTACHMENT (
                    "A private draft attachment could not be read: %s".printf (error.message));
            }
        }
    }

    internal static void validate_declared_total (Gee.Iterable<Attachment> attachments) throws MailError {
        int64 total = 0;
        foreach (var attachment in attachments) {
            if (attachment.size < 0 || attachment.size > MAX_ATTACHMENT_SIZE)
                throw new MailError.ATTACHMENT (
                    "A draft attachment exceeds the per-file safety limit");
            if (attachment.size > MAX_TOTAL_ATTACHMENT_SIZE - total)
                throw new MailError.ATTACHMENT (
                    "The draft's attachments exceed the 100 MB preparation limit");
            total += attachment.size;
        }
    }

    public async void save_received (Attachment attachment, File destination,
                                     Cancellable? cancellable = null) throws Error {
        if (attachment.path == "")
            throw new MailError.ATTACHMENT ("The attachment has not been downloaded");

        File source;
        if (attachment.path.has_prefix ("resource:///com/local/Mailficient/"))
            source = File.new_for_uri (attachment.path);
        else if (attachment.path.contains ("://"))
            throw new MailError.ATTACHMENT ("The attachment source is not trusted");
        else
            source = File.new_for_path (attachment.path);
        var info = yield source.query_info_async (
            FileAttribute.STANDARD_TYPE + "," + FileAttribute.STANDARD_SIZE,
            FileQueryInfoFlags.NOFOLLOW_SYMLINKS, Priority.DEFAULT, cancellable);
        if (info.get_file_type () != FileType.REGULAR)
            throw new MailError.ATTACHMENT ("The cached attachment is not a regular file");
        if ((int64) info.get_size () > MAX_RECEIVED_ATTACHMENT_SIZE)
            throw new MailError.ATTACHMENT ("The attachment exceeds the 50 MB download safety limit");

        yield source.copy_async (destination,
            FileCopyFlags.OVERWRITE | FileCopyFlags.NOFOLLOW_SYMLINKS,
            Priority.DEFAULT, cancellable, null);
    }
}
}
