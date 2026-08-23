namespace Mailficient {
internal class BoundedAttachmentOutputStream : FilterOutputStream {
    public int64 bytes_written { get; private set; }
    private int64 limit;

    public BoundedAttachmentOutputStream (OutputStream base_stream, int64 limit) {
        Object (base_stream: base_stream, close_base_stream: false);
        this.limit = limit;
    }

    public override ssize_t write (uint8[] buffer, Cancellable? cancellable = null) throws IOError {
        if ((int64) buffer.length > limit - bytes_written)
            throw new IOError.MESSAGE_TOO_LARGE ("The decoded attachment exceeds Mailficient's cache limit");
        ssize_t count = base_stream.write (buffer, cancellable);
        if (count > 0) bytes_written += count;
        return count;
    }

    public override bool close (Cancellable? cancellable = null) throws IOError {
        // The owning store closes the staging stream after it inspects the
        // decoder result; closing this guard must never close it early.
        return true;
    }
}

internal class ReceivedAttachmentStore : Object {
    private const int64 MAX_RECEIVED_ATTACHMENT_BYTES = 50 * 1024 * 1024;
    private string directory;
    private int64 maximum_bytes;

    public ReceivedAttachmentStore (string directory, int64 maximum_bytes = 50 * 1024 * 1024) {
        this.directory = directory;
        this.maximum_bytes = maximum_bytes;
        DirUtils.create_with_parents (directory, 0700);
    }

    public Attachment? save (Camel.DataWrapper content, string? original_name, string content_type,
                             string message_key, int index, Cancellable? cancellable = null,
                             string content_id = "", int64 remaining_message_bytes = -1) throws Error {
        string name = AttachmentSafety.safe_filename (original_name == null || original_name == "" ?
            "attachment-%d".printf (index) : original_name);
        string id = Checksum.compute_for_string (ChecksumType.SHA256,
            "%s:%d:%s".printf (message_key, index, name)).substring (0, 32);
        int64 size = (int64) content.calculate_decoded_size_sync (cancellable);
        var remote = new Attachment (id, "", name, size, content_type, content_id, index);
        int64 effective_limit = remaining_message_bytes < 0 ? maximum_bytes :
            int64.min (maximum_bytes, remaining_message_bytes);
        if (effective_limit <= 0 || size > effective_limit) return remote;
        string path = Path.build_filename (directory, id + "-" + name);
        var destination = File.new_for_path (path);
        var staging = File.new_for_path (path + ".part-" + Uuid.string_random ());
        OutputStream? output = null;
        try {
            output = staging.replace (null, false, FileCreateFlags.PRIVATE, cancellable);
            var bounded = new BoundedAttachmentOutputStream (output, effective_limit);
            ssize_t decoded = content.decode_to_output_stream_sync (bounded, cancellable);
            int64 written = bounded.bytes_written;
            output.close (cancellable);
            output = null;
            if (decoded < 0 || written > effective_limit) {
                try { staging.delete (); } catch (Error cleanup_error) {
                    debug ("Could not remove oversized attachment staging file: %s", cleanup_error.message);
                }
                return remote;
            }
            staging.move (destination, FileCopyFlags.OVERWRITE | FileCopyFlags.NOFOLLOW_SYMLINKS,
                cancellable, null);
            return new Attachment (id, path, name, written, content_type, content_id, index);
        } catch (Error error) {
            if (output != null) {
                try { output.close (); } catch (Error close_error) {
                    debug ("Could not close failed attachment write: %s", close_error.message);
                }
            }
            // Cancellation must not prevent cleanup of a partial decode.
            try { staging.delete (); } catch (Error cleanup_error) {
                if (!(cleanup_error is IOError.NOT_FOUND))
                    debug ("Could not remove failed attachment staging file: %s", cleanup_error.message);
            }
            if (error is IOError.MESSAGE_TOO_LARGE) return remote;
            throw error;
        }
    }
}
}
