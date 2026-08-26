namespace Mailficient {
public class DraftFingerprint : Object {
    public static string calculate (Draft draft, string unavailable_salt = "") {
        var checksum = new Checksum (ChecksumType.SHA256);
        foreach (var value in new string[] {
            draft.to, draft.cc, draft.bcc, draft.subject, draft.body_text,
            draft.body_html, draft.in_reply_to, draft.references
        }) append_value (checksum, value);
        foreach (var attachment in draft.attachments) {
            append_value (checksum, attachment.name);
            append_value (checksum, attachment.size.to_string ());
            append_value (checksum, attachment.content_type);
            append_value (checksum, attachment.content_id);
            uint8[] contents = {};
            try {
                if (attachment.path == "" || !FileUtils.get_data (attachment.path, out contents))
                    throw new FileError.NOENT ("Attachment content is unavailable");
                checksum.update (contents, contents.length);
            } catch (Error error) {
                // A new remote UID must not be considered an exact duplicate if
                // an oversized or unavailable part could not be compared.
                append_value (checksum, "unavailable:" + unavailable_salt);
            }
        }
        return checksum.get_string ();
    }

    private static void append_value (Checksum checksum, string value) {
        string framed = "%u:%s".printf (value.length, value);
        checksum.update (framed.data, framed.length);
    }
}
}
