namespace Mailficient {
public enum AttachmentPreviewKind {
    NONE,
    IMAGE,
    TEXT,
    PDF
}

public class AttachmentSafety : Object {
    public const int MAX_PREVIEW_IMAGE_DIMENSION = 16384;
    public const uint64 MAX_PREVIEW_IMAGE_PIXELS = 64 * 1024 * 1024;
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
            (type == "image/bmp" && name.has_suffix (".bmp")))
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

    public static bool preview_image_dimensions_are_safe (string content_type,
                                                          uint8[] prefix,
                                                          size_t length,
                                                          out int width,
                                                          out int height) {
        width = 0;
        height = 0;
        int available = (int) int64.min ((int64) length, (int64) prefix.length);
        string type = content_type.down ().split (";", 2)[0].strip ();
        if (type == "image/png" && available >= 24 &&
            bytes_at (prefix, length, 0,
                { 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a })) {
            width = (int) read_be32 (prefix, 16);
            height = (int) read_be32 (prefix, 20);
        } else if (type == "image/gif" && available >= 10) {
            width = read_le16 (prefix, 6);
            height = read_le16 (prefix, 8);
        } else if (type == "image/bmp" && available >= 26) {
            width = (int) read_le32 (prefix, 18);
            int signed_height = (int) read_le32 (prefix, 22);
            if (signed_height == int.MIN) return false;
            height = signed_height < 0 ? -signed_height : signed_height;
        } else if (type == "image/jpeg") {
            if (!jpeg_dimensions (prefix, available, out width, out height))
                return false;
        } else if (type == "image/webp" && available >= 30 &&
                   bytes_at (prefix, length, 0, { 'R', 'I', 'F', 'F' }) &&
                   bytes_at (prefix, length, 8, { 'W', 'E', 'B', 'P' })) {
            if (bytes_at (prefix, length, 12, { 'V', 'P', '8', 'X' })) {
                width = 1 + (int) read_le24 (prefix, 24);
                height = 1 + (int) read_le24 (prefix, 27);
            } else if (bytes_at (prefix, length, 12, { 'V', 'P', '8', 'L' }) &&
                       available >= 25 && prefix[20] == 0x2f) {
                width = 1 + prefix[21] + ((prefix[22] & 0x3f) << 8);
                height = 1 + (prefix[22] >> 6) + (prefix[23] << 2) +
                    ((prefix[24] & 0x0f) << 10);
            } else if (bytes_at (prefix, length, 12, { 'V', 'P', '8', ' ' }) &&
                       available >= 30 && prefix[23] == 0x9d &&
                       prefix[24] == 0x01 && prefix[25] == 0x2a) {
                width = read_le16 (prefix, 26) & 0x3fff;
                height = read_le16 (prefix, 28) & 0x3fff;
            } else return false;
        } else return false;

        return width > 0 && height > 0 &&
            width <= MAX_PREVIEW_IMAGE_DIMENSION &&
            height <= MAX_PREVIEW_IMAGE_DIMENSION &&
            (uint64) width * (uint64) height <= MAX_PREVIEW_IMAGE_PIXELS;
    }

    private static bool jpeg_dimensions (uint8[] data, int length,
                                         out int width, out int height) {
        width = 0;
        height = 0;
        if (length < 4 || data[0] != 0xff || data[1] != 0xd8) return false;
        int offset = 2;
        while (offset + 4 <= length) {
            while (offset < length && data[offset] == 0xff) offset++;
            if (offset >= length) return false;
            uint8 marker = data[offset++];
            if (marker == 0xd8 || marker == 0xd9 ||
                (marker >= 0xd0 && marker <= 0xd7)) continue;
            if (offset + 2 > length) return false;
            int segment_length = (data[offset] << 8) | data[offset + 1];
            if (segment_length < 2 || offset + segment_length > length)
                return false;
            bool start_of_frame = (marker >= 0xc0 && marker <= 0xc3) ||
                (marker >= 0xc5 && marker <= 0xc7) ||
                (marker >= 0xc9 && marker <= 0xcb) ||
                (marker >= 0xcd && marker <= 0xcf);
            if (start_of_frame) {
                if (segment_length < 7) return false;
                height = (data[offset + 3] << 8) | data[offset + 4];
                width = (data[offset + 5] << 8) | data[offset + 6];
                return true;
            }
            offset += segment_length;
        }
        return false;
    }

    private static uint32 read_be32 (uint8[] data, int offset) {
        return ((uint32) data[offset] << 24) |
            ((uint32) data[offset + 1] << 16) |
            ((uint32) data[offset + 2] << 8) | data[offset + 3];
    }

    private static uint32 read_le32 (uint8[] data, int offset) {
        return data[offset] | ((uint32) data[offset + 1] << 8) |
            ((uint32) data[offset + 2] << 16) |
            ((uint32) data[offset + 3] << 24);
    }

    private static uint32 read_le24 (uint8[] data, int offset) {
        return data[offset] | ((uint32) data[offset + 1] << 8) |
            ((uint32) data[offset + 2] << 16);
    }

    private static int read_le16 (uint8[] data, int offset) {
        return data[offset] | (data[offset + 1] << 8);
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
