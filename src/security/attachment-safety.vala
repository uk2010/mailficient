namespace Mailficient {
public enum AttachmentPreviewKind {
    NONE,
    IMAGE,
    TEXT,
    PDF
}

public class AttachmentSafety : Object {
    public static string safe_filename (string candidate) {
        string name = candidate.replace ("/", "_").replace ("\\", "_").strip ();
        while (name.has_prefix (".")) name = name.substring (1);
        if (name == "" || name == "." || name == "..") return "attachment";
        if (name.length <= 180) return name;

        // Vala string lengths and substring offsets are byte based. Back up
        // from the byte limit when it lands inside a multi-byte code point so
        // filenames passed to Gtk labels, tooltips, and file dialogs remain
        // valid UTF-8.
        int boundary = 180;
        while (boundary > 0 && ((((uint8) name[boundary]) & 0xc0) == 0x80))
            boundary--;
        return name.substring (0, boundary).make_valid ();
    }

    public static AttachmentPreviewKind preview_kind (string content_type, string filename) {
        string type = content_type.down ().split (";", 2)[0].strip ();
        string name = filename.down ();
        if (type == "application/pdf" && name.has_suffix (".pdf"))
            return AttachmentPreviewKind.PDF;
        if ((type == "image/png" && name.has_suffix (".png")) ||
            (type == "image/jpeg" && (name.has_suffix (".jpg") || name.has_suffix (".jpeg"))) ||
            (type == "image/gif" && name.has_suffix (".gif")) ||
            (type == "image/webp" && name.has_suffix (".webp")) ||
            (type == "image/bmp" && name.has_suffix (".bmp")) ||
            (type == "image/tiff" && (name.has_suffix (".tif") || name.has_suffix (".tiff"))))
            return AttachmentPreviewKind.IMAGE;
        if (type == "text/plain" || type == "text/csv" || type == "application/json" ||
            type == "application/xml" || type == "text/xml")
            return AttachmentPreviewKind.TEXT;
        return AttachmentPreviewKind.NONE;
    }

    public static bool preview_signature_matches (AttachmentPreviewKind kind,
                                                  string content_type,
                                                  uint8[] prefix,
                                                  size_t length) {
        string type = content_type.down ().split (";", 2)[0].strip ();
        switch (kind) {
            case AttachmentPreviewKind.PDF:
                return type == "application/pdf" && starts_with (prefix, length,
                    { '%', 'P', 'D', 'F', '-' });
            case AttachmentPreviewKind.IMAGE:
                if (type == "image/png")
                    return starts_with (prefix, length, { 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a });
                if (type == "image/jpeg")
                    return starts_with (prefix, length, { 0xff, 0xd8, 0xff });
                if (type == "image/gif")
                    return starts_with (prefix, length, { 'G', 'I', 'F', '8', '7', 'a' }) ||
                        starts_with (prefix, length, { 'G', 'I', 'F', '8', '9', 'a' });
                if (type == "image/webp")
                    return starts_with (prefix, length, { 'R', 'I', 'F', 'F' }) &&
                        bytes_at (prefix, length, 8, { 'W', 'E', 'B', 'P' });
                if (type == "image/bmp")
                    return starts_with (prefix, length, { 'B', 'M' });
                if (type == "image/tiff")
                    return starts_with (prefix, length, { 'I', 'I', 0x2a, 0x00 }) ||
                        starts_with (prefix, length, { 'M', 'M', 0x00, 0x2a });
                return false;
            case AttachmentPreviewKind.TEXT:
                if (!(type == "text/plain" || type == "text/csv" || type == "application/json" ||
                      type == "application/xml" || type == "text/xml")) return false;
                for (size_t index = 0; index < length; index++)
                    if (prefix[index] == 0) return false;
                return true;
            default:
                return false;
        }
    }

    private static bool starts_with (uint8[] data, size_t length, uint8[] expected) {
        return bytes_at (data, length, 0, expected);
    }

    private static bool bytes_at (uint8[] data, size_t length, size_t offset, uint8[] expected) {
        if (length < offset + expected.length || data.length < offset + expected.length) return false;
        for (size_t index = 0; index < expected.length; index++)
            if (data[offset + index] != expected[index]) return false;
        return true;
    }
}
}
