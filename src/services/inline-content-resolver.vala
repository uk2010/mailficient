namespace Mailficient {
public class InlineContentResolver : Object {
    private const int64 MAX_INLINE_IMAGE_BYTES = 5 * 1024 * 1024;

    public static string resolve (string sanitized_html, Gee.Iterable<Attachment> attachments) {
        string resolved = sanitized_html;
        foreach (var attachment in attachments) {
            string content_id = normalize_content_id (attachment.content_id);
            if (content_id == "" || attachment.size <= 0 || attachment.size > MAX_INLINE_IMAGE_BYTES)
                continue;
            string? mime_type = safe_image_type (attachment.content_type);
            if (mime_type == null) continue;
            try {
                var file = trusted_local_file (attachment.path);
                if (file == null) continue;
                uint8[] contents; string? etag;
                file.load_contents (null, out contents, out etag);
                if (contents.length == 0 || contents.length > MAX_INLINE_IMAGE_BYTES ||
                    !matches_image_signature (mime_type, contents)) continue;
                string needle = "src=\"cid:%s\"".printf (Markup.escape_text (content_id));
                string data_uri = "data:%s;base64,%s".printf (mime_type, Base64.encode (contents));
                resolved = resolved.replace (needle, "src=\"%s\"".printf (data_uri));
            } catch (Error error) {
                debug ("Could not resolve an inline message image: %s", error.message);
            }
        }
        return resolved;
    }

    private static File? trusted_local_file (string path) throws Error {
        File file;
        if (path.has_prefix ("resource:///com/local/Mailficient/")) file = File.new_for_uri (path);
        else if (Path.is_absolute (path)) file = File.new_for_path (path);
        else return null;
        var info = file.query_info (FileAttribute.STANDARD_TYPE + "," + FileAttribute.STANDARD_SIZE,
            FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
        if (info.get_file_type () != FileType.REGULAR || info.get_size () > MAX_INLINE_IMAGE_BYTES)
            return null;
        return file;
    }

    private static string normalize_content_id (string value) {
        string normalized = value.strip ();
        if (normalized.length >= 2 && normalized.has_prefix ("<") && normalized.has_suffix (">"))
            normalized = normalized.substring (1, normalized.length - 2).strip ();
        return normalized;
    }

    private static string? safe_image_type (string value) {
        string normalized = value.split (";", 2)[0].strip ().down ();
        switch (normalized) {
        case "image/png": case "image/jpeg": case "image/gif": case "image/webp":
            return normalized;
        default:
            return null;
        }
    }

    private static bool matches_image_signature (string mime_type, uint8[] data) {
        if (mime_type == "image/png")
            return data.length >= 8 && data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4e &&
                data[3] == 0x47 && data[4] == 0x0d && data[5] == 0x0a && data[6] == 0x1a && data[7] == 0x0a;
        if (mime_type == "image/jpeg")
            return data.length >= 3 && data[0] == 0xff && data[1] == 0xd8 && data[2] == 0xff;
        if (mime_type == "image/gif")
            return data.length >= 6 && data[0] == 'G' && data[1] == 'I' && data[2] == 'F' &&
                data[3] == '8' && (data[4] == '7' || data[4] == '9') && data[5] == 'a';
        if (mime_type == "image/webp")
            return data.length >= 12 && data[0] == 'R' && data[1] == 'I' && data[2] == 'F' &&
                data[3] == 'F' && data[8] == 'W' && data[9] == 'E' && data[10] == 'B' && data[11] == 'P';
        return false;
    }
}
}
