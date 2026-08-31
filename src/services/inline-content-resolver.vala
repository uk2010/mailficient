namespace Mailficient {
public class InlineContentResolver : Object {
    private const int64 MAX_INLINE_IMAGE_BYTES = 5 * 1024 * 1024;
    internal const int64 MAX_INLINE_TOTAL_BYTES = 10 * 1024 * 1024;
    internal const int MAX_INLINE_IMAGE_COUNT = 32;
    internal const int MAX_INLINE_REFERENCE_COUNT = 64;
    internal const int64 MAX_INLINE_RENDERED_HTML_BYTES = 24 * 1024 * 1024;

    public static string resolve (string sanitized_html, Gee.Iterable<Attachment> attachments) {
        string resolved = sanitized_html;
        int64 total_bytes = 0;
        int image_count = 0;
        int reference_count = 0;
        foreach (var attachment in attachments) {
            if (image_count >= MAX_INLINE_IMAGE_COUNT ||
                reference_count >= MAX_INLINE_REFERENCE_COUNT) break;
            string content_id = normalize_content_id (attachment.content_id);
            int64 remaining = MAX_INLINE_TOTAL_BYTES - total_bytes;
            if (content_id == "" || attachment.size <= 0 ||
                attachment.size > MAX_INLINE_IMAGE_BYTES || attachment.size > remaining)
                continue;
            string? mime_type = safe_image_type (attachment.content_type);
            if (mime_type == null) continue;
            string needle = "src=\"cid:%s\"".printf (Markup.escape_text (content_id));
            // Do not read or budget unreferenced MIME parts. In particular,
            // an email cannot put 32 unused images before the one it renders
            // and exhaust the count cap without adding any output.
            if (!resolved.contains (needle)) continue;
            try {
                var file = trusted_local_file (attachment.path);
                if (file == null) continue;
                uint8[] contents; string? etag;
                file.load_contents (null, out contents, out etag);
                if (contents.length == 0 || contents.length > MAX_INLINE_IMAGE_BYTES ||
                    contents.length > remaining ||
                    !matches_image_signature (mime_type, contents)) continue;
                int64 encoded_bytes = ((int64) contents.length + 2) / 3 * 4;
                int64 first_growth = "src=\"data:;base64,\"".length +
                    mime_type.length + encoded_bytes - needle.length;
                if (first_growth > 0 &&
                    resolved.length > MAX_INLINE_RENDERED_HTML_BYTES - first_growth)
                    continue;
                string data_uri = "data:%s;base64,%s".printf (mime_type, Base64.encode (contents));
                string replacement = "src=\"%s\"".printf (data_uri);
                int previous_reference_count = reference_count;
                resolved = replace_bounded (resolved, needle, replacement,
                    ref reference_count);
                if (reference_count == previous_reference_count) continue;
                total_bytes += contents.length;
                image_count++;
            } catch (Error error) {
                debug ("Could not resolve an inline message image: %s", error.message);
            }
        }
        return resolved;
    }

    private static string replace_bounded (string source, string needle,
                                           string replacement,
                                           ref int reference_count) {
        int offset = 0;
        int found = source.index_of (needle);
        if (found < 0) return source;
        int64 projected_bytes = source.length;
        int64 growth = replacement.length - needle.length;
        var output = new StringBuilder ();
        while (found >= 0 && reference_count < MAX_INLINE_REFERENCE_COUNT) {
            if (growth > 0 &&
                projected_bytes > MAX_INLINE_RENDERED_HTML_BYTES - growth)
                break;
            output.append (source.substring (offset, found - offset));
            output.append (replacement);
            offset = found + needle.length;
            projected_bytes += growth;
            reference_count++;
            found = source.index_of (needle, offset);
        }
        output.append (source.substring (offset));
        return output.str;
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
