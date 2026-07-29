namespace Mailficient {
public class MessageExportService : Object {
    public void export_eml (Message message, File destination) throws Error {
        string source = message_source (message, false);
        string? etag;
        destination.replace_contents (source.data, null, false,
            FileCreateFlags.REPLACE_DESTINATION, out etag, null);
    }

    public void export_mbox (MailRepository repository, Mailbox mailbox,
                             File destination) throws Error {
        var stream = destination.replace (null, false, FileCreateFlags.REPLACE_DESTINATION, null);
        int total = repository.message_count (mailbox.id);
        for (int offset = 0; offset < total; offset += CacheDatabase.MESSAGE_LIST_LIMIT) {
            var messages = repository.list_messages (
                mailbox.id, "", CacheDatabase.MESSAGE_LIST_LIMIT, offset);
            if (messages.size == 0) break;
            foreach (var summary in messages) {
                var message = repository.find_message (summary.id) ?? summary;
                string sender = message.sender_address.replace ("\r", "").replace ("\n", "");
                string date = message.timestamp.replace ("\r", " ").replace ("\n", " ");
                write_string (stream, "From %s %s\n".printf (
                    sender == "" ? "MAILER-DAEMON" : sender,
                    date == "" ? "unknown-date" : date));
                foreach (var line in message_source (message, true).replace ("\r\n", "\n").split ("\n")) {
                    if (line.has_prefix ("From ")) write_string (stream, ">");
                    write_string (stream, line + "\n");
                }
                write_string (stream, "\n");
            }
        }
        stream.close ();
    }

    private string message_source (Message message, bool skip_unavailable) throws Error {
        string boundary = "mailficient-" + Uuid.string_random ();
        var output = new StringBuilder ();
        output.append ("From: %s <%s>\r\n".printf (header (message.sender_name), header (message.sender_address)));
        output.append ("To: %s\r\n".printf (header (message.recipients)));
        if (message.cc_recipients.strip () != "") output.append ("Cc: %s\r\n".printf (header (message.cc_recipients)));
        output.append ("Subject: %s\r\n".printf (header (message.subject)));
        if (message.internet_message_id != "") output.append ("Message-ID: %s\r\n".printf (header (message.internet_message_id)));
        output.append ("MIME-Version: 1.0\r\n");
        if (message.attachments.size == 0) {
            output.append ("Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n");
            output.append (message.body.replace ("\n", "\r\n"));
        } else {
            output.append ("Content-Type: multipart/mixed; boundary=\"").append (boundary).append ("\"\r\n\r\n");
            output.append ("--").append (boundary).append ("\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n");
            output.append (message.body.replace ("\n", "\r\n")).append ("\r\n");
            foreach (var attachment in message.attachments) {
                if (!attachment.is_downloaded ()) continue;
                uint8[] contents; string? etag;
                try {
                    var source = attachment.path.contains ("://") ?
                        File.new_for_uri (attachment.path) : File.new_for_path (attachment.path);
                    source.load_contents (null, out contents, out etag);
                } catch (Error error) {
                    if (skip_unavailable) continue;
                    throw error;
                }
                output.append ("--").append (boundary).append ("\r\nContent-Type: ").append (header (attachment.content_type));
                output.append ("; name=\"").append (header (attachment.name)).append ("\"\r\n");
                output.append ("Content-Disposition: attachment; filename=\"").append (header (attachment.name)).append ("\"\r\n");
                output.append ("Content-Transfer-Encoding: base64\r\n\r\n"); append_base64 (output, Base64.encode (contents));
            }
            output.append ("--").append (boundary).append ("--\r\n");
        }
        return output.str;
    }

    public void export_pdf (Message message, File destination) throws Error {
        string? path = destination.get_path ();
        if (path == null) throw new IOError.NOT_SUPPORTED ("Printing requires a local temporary file");
        var surface = new Cairo.PdfSurface (path, 595, 842); var context = new Cairo.Context (surface);
        var layout = Pango.cairo_create_layout (context); layout.set_width (515 * Pango.SCALE);
        layout.set_wrap (Pango.WrapMode.WORD_CHAR); layout.set_font_description (Pango.FontDescription.from_string ("Sans 10"));
        double y = 40;
        foreach (var line in printable_text (message).split ("\n")) {
            layout.set_text (line == "" ? " " : line, -1); int width; int height; layout.get_pixel_size (out width, out height);
            if (y + height > 802) { context.show_page (); y = 40; }
            context.move_to (40, y); Pango.cairo_show_layout (context, layout); y += height + 3;
        }
        surface.finish ();
    }

    public string printable_text (Message message) {
        return "Subject: %s\nFrom: %s <%s>\nTo: %s%s\nDate: %s\n\n%s".printf (message.subject,
            message.sender_name, message.sender_address, message.recipients,
            message.cc_recipients.strip () == "" ? "" : "\nCc: " + message.cc_recipients,
            message.timestamp, message.body);
    }

    private static string header (string value) { return value.replace ("\r", " ").replace ("\n", " "); }
    private static void write_string (OutputStream stream, string value) throws Error {
        size_t written;
        stream.write_all (value.data, out written, null);
    }
    private static void append_base64 (StringBuilder output, string encoded) {
        for (int offset = 0; offset < encoded.length; offset += 76)
            output.append (encoded.substring (offset, int.min (76, encoded.length - offset))).append ("\r\n");
    }
}
}
